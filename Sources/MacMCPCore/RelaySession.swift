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

    private var initialize: [String: Any]?
    private var initializeID: String?
    private var handshakeDone = false
    private var initialized: Data?
    private var replayID: String?
    private var replays = 0

    public init() {}

    // MARK: events

    /// A line the client wrote to stdin.
    public mutating func fromClient(_ line: Data) -> Output {
        var out = Output()
        switch phase {
        case .connected:
            send(line, into: &out)
        case .reconnecting:
            // A response answers a request from the agent that's gone; the new one never asked.
            if case .response = Message(line) { break }
            held.append(line)
        case .replaying:
            held.append(line)
        }
        return out
    }

    /// A line the agent wrote to the socket.
    public mutating func fromAgent(_ line: Data) -> Output {
        var out = Output()
        guard case .response(let id, let isResult) = Message(line) else {
            out.toClient.append(line)
            return out
        }
        if phase == .replaying, id == replayID {
            // Our replayed handshake: the client already has its own initialize result.
            replayID = nil
            phase = .connected
            if let initialized { out.toAgent.append(initialized) }
            for line in held { send(line, into: &out) }
            held = []
            return out
        }
        inFlight.removeAll { $0 == id }
        if id == initializeID, isResult { handshakeDone = true }
        out.toClient.append(line)
        return out
    }

    /// The agent connection closed. Every request it hadn't answered is answered with an error now, so the
    /// client isn't left waiting; held messages stay held for the next connection.
    public mutating func agentLost() -> Output {
        phase = .reconnecting
        replayID = nil
        let out = Output(toClient: inFlight.map { Self.errorResponse(id: $0, message: Self.lostMessage) })
        inFlight = []
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
        for line in held { send(line, into: &out) }
        held = []
        return out
    }

    /// The agent isn't coming back: answer everything still outstanding.
    public mutating func giveUp(reason: String) -> Output {
        var ids = inFlight
        for line in held {
            if case .request(let id, _) = Message(line), let id { ids.append(id) }
        }
        inFlight = []
        held = []
        return Output(toClient: ids.map { Self.errorResponse(id: $0, message: reason) })
    }

    // MARK: helpers

    private mutating func send(_ line: Data, into out: inout Output) {
        switch Message(line) {
        case .request(let id, let method):
            if let id { inFlight.append(id) }
            if method == "initialize", let object = Message.object(line) {
                initialize = object
                initializeID = id
                handshakeDone = false
            }
        case .notification(let method, let cancelled):
            if method == "notifications/initialized" { initialized = line }
            // The agent won't answer a cancelled request.
            if let cancelled { inFlight.removeAll { $0 == cancelled } }
        case .response, .other:
            break
        }
        out.toAgent.append(line)
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
    case other  // not a JSON object (a batch, garbage): passed through untracked

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

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

/// Splits a byte stream into lines (without the newline). Blank lines are dropped.
public struct LineBuffer {
    private var pending = Data()
    public init() {}

    public mutating func append(_ bytes: some Collection<UInt8>) -> [Data] {
        pending.append(contentsOf: bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) { lines.append(Data(line)) }
        }
        return lines
    }

    public mutating func reset() { pending = Data() }
}
