import Foundation

/// The relay's view of one MCP session, kept so the session can survive an agent restart. Pure state, no I/O:
/// feed it newline-delimited JSON-RPC lines (without the newline) and connection events, and write out what it
/// returns. Messages pass through unchanged; it only reads them to:
///   - remember the client's handshake (`initialize` + `notifications/initialized`) so it can be replayed to a
///     restarted agent, whose response is swallowed;
///   - track requests the agent hasn't answered, so a lost connection answers them with an error instead of
///     leaving the client waiting forever;
///   - hold the client's messages while the agent is away and deliver them once the handshake is replayed.
public struct RelaySession {
    public enum Phase: Equatable {
        /// Lines pass straight through.
        case connected
        /// The agent connection is gone; client messages are held.
        case reconnecting
        /// Reconnected and waiting for the replayed `initialize` to be answered; client messages are still held.
        case replaying
    }

    public struct Output: Equatable {
        public var toAgent: [Data] = []
        public var toClient: [Data] = []
        public init(toAgent: [Data] = [], toClient: [Data] = []) {
            self.toAgent = toAgent
            self.toClient = toClient
        }
    }

    /// JSON-RPC error code for answers the relay makes up: Internal error. (Spec 2026-07-28 asks new implementations
    /// not to use the old implementation-defined -32000…-32019 range.)
    public static let errorCode = -32603
    public static let lostMessage = "MacMCP agent connection lost (the agent restarted). The call may or may not "
        + "have run: check the current state, then retry."

    public private(set) var phase: Phase = .connected
    /// Ids of requests sent to the agent and not yet answered, as canonical JSON (`7`, `"abc"`), oldest first.
    public private(set) var inFlight: [String] = []
    /// Client lines waiting for the agent to come back.
    public private(set) var held: [Data] = []

    public private(set) var failure: String?
    public private(set) var reconnectDeadline: TimeInterval?
    private let reconnectWindow: TimeInterval
    private let maxQueuedBytes: Int
    private let maxRequests: Int
    private var heldBytes = 0
    private var negotiatedVersion: String?
    private var inFlightBatches: [String: UUID] = [:]
    private var initialize: [String: Any]?
    private var initializeID: String?
    private var handshakeDone = false
    private var initialized: Data?
    private var replayID: String?
    private var replays = 0

    public init(reconnectWindow: TimeInterval = 15, maxQueuedBytes: Int = StreamIO.queueLimit, maxRequests: Int = 256) {
        self.reconnectWindow = reconnectWindow
        self.maxQueuedBytes = maxQueuedBytes
        self.maxRequests = maxRequests
    }

    // MARK: events

    /// A line the client wrote to stdin.
    public mutating func fromClient(_ line: Data) -> Output {
        // The relay owns these labels. A client may never inject a new preamble, including during reconnect.
        if line.starts(with: Data("#mac-mcp".utf8)) { return Output() }
        if let failure { return errors(for: [line], message: failure) }
        guard line.count <= StreamIO.frameLimit else {
            failure = "MacMCP relay frame exceeds 16 MiB."
            return errors(for: [line], message: failure!)
        }
        var out = Output()
        switch phase {
        case .connected:
            send(line, into: &out)
        case .reconnecting, .replaying:
            if case .response = Message(line) { break }
            guard held.count < maxRequests, line.count <= maxQueuedBytes - heldBytes else {
                return errors(for: [line], message: "MacMCP relay reconnect queue limit exceeded.")
            }
            held.append(line)
            heldBytes += line.count
        }
        return out
    }

    /// A line the agent wrote to the socket.
    public mutating func fromAgent(_ line: Data) -> Output {
        var out = Output()
        for message in Message.messages(line) {
            guard case .response(let id, let isResult) = message else { continue }
            if phase == .replaying, id == replayID {
                let object = Message.object(line)
                let result = object?["result"] as? [String: Any]
                guard isResult, object?["error"] == nil,
                      let version = result?["protocolVersion"] as? String, version == negotiatedVersion else {
                    let reason = "MacMCP agent replayed initialize failed or negotiated an incompatible protocol version. Reconnect the MCP client."
                    failure = reason
                    return giveUp(reason: reason)
                }
                replayID = nil
                phase = .connected
                reconnectDeadline = nil
                if let initialized { out.toAgent.append(initialized) }
                let waiting = held
                held = []
                heldBytes = 0
                for line in waiting { send(line, into: &out) }
                return out
            }
            inFlight.removeAll { $0 == id }
            inFlightBatches[id] = nil
            if id == initializeID, isResult, Message.object(line)?["error"] == nil,
               let result = Message.object(line)?["result"] as? [String: Any],
               let version = result["protocolVersion"] as? String {
                handshakeDone = true
                negotiatedVersion = version
            }
        }
        out.toClient.append(line)
        return out
    }

    /// The agent connection closed. Every request it hadn't answered is answered with an error now, so the
    /// client isn't left waiting; held messages stay held for the next connection.
    public mutating func agentLost(now: TimeInterval = StreamIO.now) -> Output {
        if reconnectDeadline == nil { reconnectDeadline = now + reconnectWindow }
        phase = .reconnecting
        replayID = nil
        let out = pendingErrors(message: Self.lostMessage)
        inFlight = []
        inFlightBatches = [:]
        return out
    }

    /// A new agent connection is up. Replays the client's handshake if it had completed one; otherwise the
    /// held messages (which may include the client's own `initialize`) go straight out.
    public mutating func agentReconnected() -> Output {
        var out = Output()
        if handshakeDone, var initialize {
            replays += 1
            let id = "mac-mcp-relay-reinit-\(replays)"
            initialize["id"] = id
            if let data = try? JSONSerialization.data(withJSONObject: initialize) {
                replayID = Self.canonical(id)
                phase = .replaying
                out.toAgent.append(data)
                return out
            }
        }
        phase = .connected
        reconnectDeadline = nil
        let waiting = held
        held = []
        heldBytes = 0
        for line in waiting { send(line, into: &out) }
        return out
    }

    /// The agent isn't coming back: answer everything still outstanding.
    public mutating func giveUp(reason: String) -> Output {
        var out = pendingErrors(message: reason)
        let waiting = errors(for: held, message: reason)
        out.toClient += waiting.toClient
        inFlight = []
        inFlightBatches = [:]
        held = []
        heldBytes = 0
        return out
    }

    /// One monotonic deadline covers connecting and replay; progress never extends it.
    public mutating func expire(now: TimeInterval = StreamIO.now) -> Output {
        guard let reconnectDeadline, now >= reconnectDeadline else { return Output() }
        let reason = "The MacMCP agent did not reconnect and complete initialize within \(Int(reconnectWindow)) s."
        failure = reason
        return giveUp(reason: reason)
    }

    // MARK: helpers

    private mutating func send(_ line: Data, into out: inout Output) {
        let messages = Message.messages(line)
        let ids = messages.compactMap { message -> String? in
            if case .request(let id, _) = message { return id }
            return nil
        }
        let bytes = inFlight.reduce(0) { $0 + $1.utf8.count }
        let incoming = ids.reduce(0) { $0 + $1.utf8.count }
        guard ids.count <= maxRequests - inFlight.count, incoming <= maxQueuedBytes - bytes else {
            out.toClient += errors(for: [line], message: "MacMCP relay outstanding request limit exceeded (\(maxRequests)).").toClient
            return
        }
        let group = Message.isBatch(line) ? UUID() : nil
        for message in messages {
            switch message {
            case .request(let id, let method):
                if let id { inFlight.append(id); inFlightBatches[id] = group }
                if method == "initialize", let object = Message.object(line) {
                    initialize = object
                    initializeID = id
                    handshakeDone = false
                }
            case .notification(let method, let cancelled):
                if method == "notifications/initialized" { initialized = line }
                if let cancelled {
                    inFlight.removeAll { $0 == cancelled }
                    inFlightBatches[cancelled] = nil
                }
            case .response, .other: break
            }
        }
        out.toAgent.append(line)
    }

    private func pendingErrors(message: String) -> Output {
        var sent: Set<UUID> = []
        var lines: [Data] = []
        for id in inFlight {
            if let group = inFlightBatches[id] {
                guard sent.insert(group).inserted else { continue }
                let errors = inFlight.filter { inFlightBatches[$0] == group }.map { Self.errorResponse(id: $0, message: message) }
                lines.append(Self.batch(errors))
            } else { lines.append(Self.errorResponse(id: id, message: message)) }
        }
        return Output(toClient: lines)
    }

    private func errors(for lines: [Data], message: String) -> Output {
        Output(toClient: lines.flatMap { line -> [Data] in
            let responses = Message.messages(line).compactMap { item -> Data? in
                guard case .request(let id?, _) = item else { return nil }
                return Self.errorResponse(id: id, message: message)
            }
            if responses.isEmpty { return [] }
            return Message.isBatch(line) ? [Self.batch(responses)] : responses
        })
    }

    private static func batch(_ responses: [Data]) -> Data {
        Data("[".utf8) + responses.enumerated().reduce(into: Data()) { data, item in
            if item.offset > 0 { data.append(0x2C) }
            data.append(item.element)
        } + Data("]".utf8)
    }

    /// The JSON text of a JSON-RPC id, used as its identity so `7` and `"7"` stay distinct and round-trip.
    static func canonical(_ id: Any) -> String? {
        guard id is String || id is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func errorResponse(id: String, message: String) -> Data {
        let text = (try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"error\""
        return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(errorCode),"message":\#(text)}}"#.utf8)
    }
}

/// Just enough of a JSON-RPC message to route it.
private enum Message {
    case request(id: String?, method: String)  // id is nil only for an unusable id (null, object)
    case notification(method: String, cancelled: String?)
    case response(id: String, isResult: Bool)
    case other  // not a JSON-RPC object: passed through untracked

    init(_ line: Data) {
        guard let object = Self.object(line) else { self = .other; return }
        let id = object["id"].flatMap(RelaySession.canonical)
        if let method = object["method"] as? String {
            if object["id"] == nil {
                let params = object["params"] as? [String: Any]
                self = .notification(method: method, cancelled: method == "notifications/cancelled"
                    ? params?["requestId"].flatMap(RelaySession.canonical) : nil)
            } else {
                self = .request(id: id, method: method)
            }
        } else if let id {
            self = .response(id: id, isResult: object["result"] != nil)
        } else {
            self = .other
        }
    }

    static func messages(_ line: Data) -> [Message] {
        guard let array = (try? JSONSerialization.jsonObject(with: line)) as? [Any] else { return [Message(line)] }
        return array.compactMap { value in
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return Message(data)
        }
    }

    static func isBatch(_ line: Data) -> Bool {
        line.first(where: { ![0x20, 0x09, 0x0D].contains($0) }) == 0x5B
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

/// Splits a byte stream into lines (without the newline). Blank lines are dropped.
public struct LineBuffer {
    private var pending = Data()
    public private(set) var exceededLimit = false
    public let maxBytes: Int
    public init(maxBytes: Int = StreamIO.frameLimit) { self.maxBytes = maxBytes }

    public mutating func append(_ bytes: some Collection<UInt8>) -> [Data] {
        guard !exceededLimit else { return [] }
        var lines: [Data] = []
        var rest = bytes[...]
        while !rest.isEmpty {
            let end = rest.firstIndex(of: 0x0A) ?? rest.endIndex
            let part = rest[..<end]
            guard part.count <= maxBytes - pending.count else {
                exceededLimit = true
                pending = Data()
                return []
            }
            pending.append(contentsOf: part)
            guard end != rest.endIndex else { break }
            if pending.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) { lines.append(pending) }
            pending = Data()
            rest = rest[rest.index(after: end)...]
        }
        return lines
    }

    public mutating func reset() { pending = Data(); exceededLimit = false }
}
