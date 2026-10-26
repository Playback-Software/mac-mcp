import Foundation
import MacMCPCore

/// What a connection serves.
public struct ServerDefinition: Sendable {
    public let name: String
    public let version: String
    public let instructions: String
    public let tools: [Tool]
    public let call: @Sendable (_ name: String, _ arguments: [String: Value], _ session: Session) async -> CallResult

    public init(name: String, version: String, instructions: String, tools: [Tool],
                call: @escaping @Sendable (String, [String: Value], Session) async -> CallResult) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.call = call
    }
}

public struct CallResult: Sendable {
    public var content: [Tool.Content]
    public var isError: Bool
    public init(content: [Tool.Content], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

/// What a connection knows about its client.
public actor Session {
    public private(set) var client = "unknown"
    /// The protocol revision in use: from `initialize`, or the latest `_meta` protocol version a request carried.
    public private(set) var protocolVersion: String?
    /// The GUI lease token this connection presented (`#mac-mcp lease=<token>`), if any.
    public private(set) var leaseToken: String?
    /// Who holds that lease (an eval run, the integration tests), when it was the active lease on presentation.
    public private(set) var leaseHolder: String?
    /// `local` or `ssh:<address>`, as the relay reported it; nil for clients that connect without the relay.
    public private(set) var origin: String?
    /// The relay's session id (stable across agent restarts), else one for this connection.
    public private(set) var id = AgentClient.newSessionID()

    public init() {}

    func setClient(_ info: Value?) {
        guard let info, let name = info["name"]?.stringValue else { return }
        client = [name, info["version"]?.stringValue].compactMap { $0 }.joined(separator: " ")
    }

    func setProtocolVersion(_ v: String) { protocolVersion = v }

    /// A `#mac-mcp key=value …` line sent before (or between) JSON-RPC messages.
    func apply(directive line: String) {
        for field in line.dropFirst("#mac-mcp".count).split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "lease":
                leaseToken = parts[1]
                if let lease = LeaseStore.current(), lease.token == parts[1] { leaseHolder = lease.holder }
            case "origin": origin = parts[1]
            case "session": id = parts[1]
            default: break
            }
        }
    }
}

/// One MCP session over a stream socket: newline-delimited JSON-RPC 2.0, tools only.
///
/// Built to avoid what went wrong with swift-sdk 0.12.1:
/// - **Writes are whole and ordered by construction.** One serial queue does blocking writes of complete lines, so
///   two responses can never interleave (the SDK's non-blocking writer slept mid-message and let another in).
/// - **Reads block on a dedicated thread**, not a polling loop on the cooperative pool.
/// - **Calls are cancellable.** Each `tools/call` runs as its own task; `notifications/cancelled` cancels it (and,
///   per the spec, no response is sent). The deadline machinery then abandons any stuck work.
///
/// Serves both protocol eras on one connection, as the 2026-07-28 spec allows:
/// - **Legacy (2025-11-25 and older):** an `initialize` handshake, with the version negotiated down.
/// - **Modern (2026-07-28):** stateless. Every request carries `_meta` with its protocol version and client
///   capabilities, and `server/discover` replaces the handshake. Results carry `resultType` and the server's info in
///   `_meta`; list results say how long they may be cached.
///
/// Claude Code (2.1.285+) probes with `server/discover` first and falls back to `initialize` on a plain
/// "Method not found". A -32601 whose message mentions a protocol version confuses that fallback, so ours never does.
public final class Connection: @unchecked Sendable {
    public static let latestHandshakeVersion = "2025-11-25"
    public static let handshakeVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let statelessVersions = ["2026-07-28"]
    static let metaVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let metaClientInfoKey = "io.modelcontextprotocol/clientInfo"
    static let metaClientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let metaServerInfoKey = "io.modelcontextprotocol/serverInfo"
    static let unsupportedVersion = -32022
    /// How long modern clients may cache the tool list (it only changes when the agent is upgraded).
    static let listTTL = 3_600_000

    public let session = Session()
    private let fd: Int32
    private let server: ServerDefinition
    private let writer = DispatchQueue(label: "mac-mcp.connection.writer")
    private let lock = NSLock()
    private var calls: [String: Task<Void, Never>] = [:]   // in-flight tools/call by canonical request id
    private var cancelled: Set<String> = []
    private var readEnd = "?"   // how the reader stopped (read result and errno), for the log

    public init(fd: Int32, server: ServerDefinition) {
        self.fd = fd
        self.server = server
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))   // a vanished client is EPIPE, not a signal
    }

    /// Serves until the client closes the connection. In-flight calls are then cancelled.
    public func run() async {
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let fd = fd
        let reader = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var framing = LineBuffer()
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    let why = "read=\(n) errno=\(n < 0 ? errno : 0)"
                    lock.withLock { readEnd = why }
                    break
                }
                for line in framing.append(buffer[0..<n]) { continuation.yield(line) }
            }
            continuation.finish()
        }
        reader.name = "mac-mcp.connection.reader"
        reader.start()
        for await line in lines { await handle(line) }
        let (inFlight, why) = lock.withLock { () -> (Int, String) in
            calls.values.forEach { $0.cancel() }
            return (calls.count, readEnd)
        }
        if inFlight > 0 {   // the client vanished mid-call: say how the socket ended, since no one asked to cancel
            log("connection \(await session.id) (\(await session.client)) ended with \(inFlight) call(s) in flight: \(why)")
        }
        await Claims.shared.release(session: session.id)   // a gone client (a dropped SSH link) frees the GUI at once
        writer.sync {}   // flush what's queued before the caller closes the socket
    }

    // MARK: messages

    func handle(_ line: Data) async {
        if line.starts(with: Data("#mac-mcp".utf8)) {
            await session.apply(directive: String(decoding: line, as: UTF8.self))
            return
        }
        guard let message = try? Value.parse(line) else {
            return send(error: RPCError.parse, "Parse error: not valid JSON", id: .null)
        }
        guard case let .object(m) = message else {
            return send(error: RPCError.invalidRequest, "Invalid request: expected a JSON-RPC object (batches aren't supported)", id: .null)
        }
        let id = m["id"]
        guard let method = m["method"]?.stringValue else {
            if id != nil, m["result"] != nil || m["error"] != nil { return }   // a response to a request we never send
            return send(error: RPCError.invalidRequest, "Invalid request: no method", id: id ?? .null)
        }
        let params = m["params"]?.objectValue ?? [:]
        let meta = params["_meta"]?.objectValue ?? [:]
        let modern = meta[Self.metaVersionKey]?.stringValue
        if let modern { await session.setProtocolVersion(modern) }
        if let info = meta[Self.metaClientInfoKey] { await session.setClient(info) }
        guard let id, id.stringValue != nil || id.intValue != nil else {
            if id != nil { return send(error: RPCError.invalidRequest, "Invalid request: id must be a string or number", id: .null) }
            return await notification(method, params)
        }
        if let modern {
            guard Self.statelessVersions.contains(modern) else {
                return send(error: Self.unsupportedVersion, "Unsupported protocol version", id: id,
                            data: ["supported": supportedVersions, "requested": .string(modern)])
            }
            guard meta[Self.metaClientCapabilitiesKey] != nil else {
                return send(error: RPCError.invalidParams,
                            "Invalid params: _meta must include \(Self.metaClientCapabilitiesKey)", id: id)
            }
        }
        await request(method, params, id: id, modern: modern != nil || method == "server/discover")
    }

    private func notification(_ method: String, _ params: [String: Value]) async {
        switch method {
        case "notifications/cancelled":
            guard let target = params["requestId"] else { return }
            let key = Self.key(target)
            let task: Task<Void, Never>? = lock.withLock {
                guard let t = calls[key] else { return nil }
                cancelled.insert(key)
                return t
            }
            task?.cancel()
        default:
            break   // notifications/initialized and anything we don't act on
        }
    }

    private func request(_ method: String, _ params: [String: Value], id: Value, modern: Bool) async {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.handshakeVersions.contains(requested) ? requested : Self.latestHandshakeVersion
            await session.setProtocolVersion(version)
            await session.setClient(params["clientInfo"])
            send(result: [
                "protocolVersion": .string(version),
                "capabilities": capabilities,
                "serverInfo": serverInfo,
                "instructions": .string(server.instructions),
            ], id: id)
        case "server/discover":
            send(result: [
                "supportedVersions": supportedVersions,
                "capabilities": ["tools": [:]],
                "instructions": .string(server.instructions),
                "ttlMs": .int(Self.listTTL),
                "cacheScope": "public",
            ], id: id, modern: true)
        case "ping":   // legacy only (removed in 2026-07-28); harmless to answer either way
            send(result: [:], id: id, modern: modern)
        case "tools/list":
            var result: [String: Value] = ["tools": .array(server.tools.map(\.json))]
            if modern { result["ttlMs"] = .int(Self.listTTL); result["cacheScope"] = "public" }
            send(result: result, id: id, modern: modern)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return send(error: RPCError.invalidParams, "Invalid params: tools/call needs a string \"name\"", id: id)
            }
            guard let arguments = params["arguments"].map({ $0.objectValue }) ?? [:] else {
                return send(error: RPCError.invalidParams, "Invalid params: \"arguments\" must be an object", id: id)
            }
            if modern, !server.tools.contains(where: { $0.name == name }) {
                // 2026-07-28: an unknown tool is a protocol error (legacy clients get an isError result instead).
                return send(error: RPCError.invalidParams, "Invalid params: unknown tool \(name)", id: id)
            }
            startCall(name, arguments, id: id, modern: modern)
        default:
            send(error: RPCError.methodNotFound, "Method not found: \(method)", id: id)
        }
    }

    private func startCall(_ name: String, _ arguments: [String: Value], id: Value, modern: Bool) {
        let key = Self.key(id)
        let server = server, session = session
        lock.withLock {
            calls[key] = Task {
                let result = await server.call(name, arguments, session)
                let wasCancelled = self.lock.withLock {
                    self.calls[key] = nil
                    return self.cancelled.remove(key) != nil
                }
                guard !wasCancelled else { return }   // the client withdrew the request: no response
                self.send(result: ["content": .array(result.content.map(\.json)), "isError": .bool(result.isError)],
                          id: id, modern: modern)
            }
        }
    }

    private var capabilities: Value { ["tools": ["listChanged": false]] }
    private var serverInfo: Value { ["name": .string(server.name), "version": .string(server.version)] }
    private var supportedVersions: Value { .array((Self.statelessVersions + [Self.latestHandshakeVersion]).map(Value.string)) }

    // MARK: output

    /// Modern results say they're complete (not a multi-round-trip `input_required`) and who answered.
    private func send(result: [String: Value], id: Value, modern: Bool = false) {
        var result = result
        if modern {
            result["resultType"] = "complete"
            result["_meta"] = [Self.metaServerInfoKey: serverInfo]
        }
        write(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    private func send(error code: Int, _ message: String, id: Value, data: Value? = nil) {
        var error: [String: Value] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        write(["jsonrpc": "2.0", "id": id, "error": .object(error)])
    }

    private func write(_ message: Value) {
        var data = message.jsonData()
        data.append(0x0A)
        let fd = fd
        writer.async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { return }   // the client is gone; the reader will see EOF
                    offset += n
                }
            }
        }
    }

    /// Request ids compare by JSON value: 7 and "7" are different requests.
    static func key(_ id: Value) -> String { String(decoding: id.jsonData(), as: UTF8.self) }
}
