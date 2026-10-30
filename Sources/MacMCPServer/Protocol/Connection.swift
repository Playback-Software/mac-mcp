import Foundation
import MacMCPCore

/// Captured before dispatch; modern requests cannot change the identity or lease token of an earlier call.
public struct RequestContext: Sendable {
    public let client: String
    public let protocolVersion: String?
    public let leaseToken: String?
    public let origin: String?
    public let id: String
    let leasePath: String

    public var leaseHolder: String? {
        get async {
            guard let lease = await LeaseStore.currentAsync(path: leasePath), lease.token == leaseToken else { return nil }
            return lease.holder
        }
    }
}

/// What a connection serves.
public struct ServerDefinition: Sendable {
    public let name: String
    public let version: String
    public let instructions: String
    public let tools: [Tool]
    public let call: @Sendable (_ name: String, _ arguments: [String: Value], _ session: RequestContext) async -> CallResult

    public init(name: String, version: String, instructions: String, tools: [Tool],
                call: @escaping @Sendable (String, [String: Value], RequestContext) async -> CallResult) {
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
    /// Current lease ownership is derived each time; a released or expired token grants no bypass.
    public var leaseHolder: String? {
        get async {
            guard let lease = await LeaseStore.currentAsync(path: leasePath), lease.token == leaseToken else { return nil }
            return lease.holder
        }
    }
    /// `local` or `ssh:<address>`, as the relay reported it; nil for clients that connect without the relay.
    public private(set) var origin: String?
    /// The relay's session id (stable across agent restarts), else one for this connection.
    public private(set) var id = AgentClient.newSessionID()

    private let leasePath: String
    private var labeled = false
    private var legacyClient = "unknown"
    private var legacyVersion: String?
    public init(leasePath: String = LeaseStore.defaultPath) { self.leasePath = leasePath }

    /// Snapshot before dispatch. Modern requests never inherit the identity of an earlier request.
    func snapshot(version: String?, info: Value?) -> RequestContext {
        RequestContext(client: version == nil ? legacyClient : Self.clientLabel(info), protocolVersion: version ?? legacyVersion,
                leaseToken: leaseToken, origin: origin, id: id, leasePath: leasePath)
    }

    private static func clientLabel(_ info: Value?) -> String {
        guard let name = info?["name"]?.stringValue else { return "unknown" }
        return [name, info?["version"]?.stringValue].compactMap { $0 }.joined(separator: " ")
    }

    func negotiate(version: String, info: Value?) {
        legacyClient = Self.clientLabel(info)
        legacyVersion = version
        client = legacyClient
        labeled = true
        protocolVersion = version
    }

    func identifyOnce(_ info: Value?) {
        guard !labeled else { return }
        client = Self.clientLabel(info)
        labeled = true
    }

    func setProtocolVersion(_ v: String) { protocolVersion = v }
    var supportsBatches: Bool { legacyVersion == "2025-03-26" }

    /// A `#mac-mcp key=value …` preamble, accepted only before the first JSON-RPC message.
    func apply(directive line: String) {
        for field in line.dropFirst("#mac-mcp".count).split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "lease":
                leaseToken = parts[1]
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
    public struct Limits: Sendable {
        public var frameBytes = StreamIO.frameLimit
        public var queuedBytes = StreamIO.queueLimit
        public var queuedFrames = 64
        public var concurrentCalls = 32
        public var batchSize = 128
        public var writeTimeout: TimeInterval = 10
        public init() {}
    }
    private let limits: Limits
    private let writer: StreamWriter
    private var closed = false
    private var receivedMessage = false
    private let input: FrameBackpressure
    private var bufferedResponseBytes = 0
    private var callBytes = 0
    private let lock = NSLock()
    private var calls: [String: Task<Void, Never>] = [:]   // in-flight tools/call by canonical request id
    private var cancelled: Set<String> = []
    private var readEnd = "?"   // how the reader stopped (read result and errno), for the log

    public init(fd: Int32, server: ServerDefinition, limits: Limits = Limits()) {
        self.fd = fd
        self.server = server
        self.limits = limits
        self.input = FrameBackpressure(maxFrames: limits.queuedFrames, maxBytes: limits.queuedBytes)
        self.writer = StreamWriter(fd: fd, maxBytes: limits.queuedBytes, timeout: limits.writeTimeout)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))   // a vanished client is EPIPE, not a signal
    }

    /// Serves until the client closes the connection. In-flight calls are then cancelled.
    public func run() async {
        do { try StreamIO.configure(fd) } catch { return }
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let readerDone = DispatchGroup()
        readerDone.enter()
        let fd = fd
        let reader = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var framing = LineBuffer(maxBytes: limits.frameBytes)
            defer { continuation.finish(); readerDone.leave() }
            while !lock.withLock({ closed }) {
                do { try StreamIO.wait(fd, events: Int16(POLLIN), deadline: .infinity) }
                catch { break }
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                if n <= 0 {
                    lock.withLock { readEnd = "read=\(n) errno=\(n < 0 ? errno : 0)" }
                    closeAdmission()
                    break
                }
                let framed = framing.append(buffer[0..<n])
                if framing.exceededLimit { closeAdmission(); break }
                for line in framed {
                    guard input.admit(line.count) else { closeAdmission(); return }
                    if case .terminated = continuation.yield(line) { return }
                }
            }
        }
        reader.name = "mac-mcp.connection.reader"
        reader.start()
        for await line in lines {
            input.remove(line.count)
            guard !lock.withLock({ closed }) else { break }
            await handle(line)
        }
        closeAdmission()
        let (inFlight, why) = lock.withLock { (calls.count, readEnd) }
        if inFlight > 0 {
            log("connection \(await session.id) (\(await session.client)) ended with \(inFlight) call(s) in flight: \(why)")
        }
        await Claims.shared.release(session: session.id)
        await withCheckedContinuation { c in readerDone.notify(queue: .global()) { c.resume() } }
        await writer.finish()   // asynchronous barrier: the caller may now close/reuse the descriptor
    }

    private func closeAdmission() {
        lock.withLock {
            closed = true
            calls.values.forEach { $0.cancel() }
        }
        input.close()
        writer.abort()
    }

    // MARK: messages

    private typealias Reply = @Sendable (Value?) -> Void

    func handle(_ line: Data) async {
        if line.starts(with: Data("#mac-mcp".utf8)) {
            if !receivedMessage { await session.apply(directive: String(decoding: line, as: UTF8.self)) }
            return
        }
        receivedMessage = true
        guard let message = try? Value.parse(line) else {
            return send(error: RPCError.parse, "Parse error: not valid JSON", id: .null, reply: directReply)
        }
        if case let .array(batch) = message {
            guard await session.supportsBatches, !batch.isEmpty, batch.count <= limits.batchSize else {
                return send(error: RPCError.invalidRequest, "Invalid request: empty, oversized or unsupported batch", id: .null, reply: directReply)
            }
            guard let responses = BatchResponses(entries: batch, frameBytes: limits.frameBytes, reserve: { [self] bytes in
                lock.withLock {
                    guard bytes <= limits.queuedBytes - bufferedResponseBytes else { return false }
                    bufferedResponseBytes += bytes
                    return true
                }
            }, release: { [self] bytes in lock.withLock { bufferedResponseBytes -= bytes } }, send: { [self] in write($0) }) else {
                return send(error: -32603, "Batch response ids exceed the response buffer; narrow the request",
                            id: .null, reply: directReply)
            }
            for (index, entry) in batch.enumerated() {
                await handle(entry, reply: { responses.finish(index, response: $0) })
            }
            return
        }
        await handle(message, reply: directReply)
    }

    private var directReply: Reply { { [self] in if let message = $0 { write(message) } } }

    private func handle(_ message: Value, reply: @escaping Reply) async {
        guard case let .object(m) = message else {
            return send(error: RPCError.invalidRequest, "Invalid request: expected a JSON-RPC object", id: .null, reply: reply)
        }
        guard m["jsonrpc"] == "2.0" else {
            return send(error: RPCError.invalidRequest, "Invalid request: jsonrpc must be 2.0", id: .null, reply: reply)
        }
        let id = m["id"]
        guard let method = m["method"]?.stringValue else {
            if id != nil, m["result"] != nil || m["error"] != nil { reply(nil); return }   // a response to a request we never send
            return send(error: RPCError.invalidRequest, "Invalid request: no method", id: id ?? .null, reply: reply)
        }
        let params = m["params"]?.objectValue ?? [:]
        let meta = params["_meta"]?.objectValue ?? [:]
        let modern = meta[Self.metaVersionKey]?.stringValue
        if let modern { await session.setProtocolVersion(modern) }
        if modern != nil { await session.identifyOnce(meta[Self.metaClientInfoKey]) }
        guard let id, id.stringValue != nil || id.intValue != nil else {
            if id != nil { return send(error: RPCError.invalidRequest, "Invalid request: id must be a string or number", id: .null, reply: reply) }
            await notification(method, params)
            reply(nil)
            return
        }
        if let modern {
            guard Self.statelessVersions.contains(modern) else {
                return send(error: Self.unsupportedVersion, "Unsupported protocol version", id: id,
                            data: ["supported": supportedVersions, "requested": .string(modern)], reply: reply)
            }
            guard meta[Self.metaClientCapabilitiesKey] != nil else {
                return send(error: RPCError.invalidParams,
                            "Invalid params: _meta must include \(Self.metaClientCapabilitiesKey)", id: id, reply: reply)
            }
        }
        let context = await session.snapshot(version: modern, info: meta[Self.metaClientInfoKey])
        await request(method, params, id: id, modern: modern != nil || method == "server/discover", context: context, reply: reply)
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

    private func request(_ method: String, _ params: [String: Value], id: Value, modern: Bool, context: RequestContext, reply: @escaping Reply) async {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.handshakeVersions.contains(requested) ? requested : Self.latestHandshakeVersion
            await session.negotiate(version: version, info: params["clientInfo"])
            send(result: [
                "protocolVersion": .string(version),
                "capabilities": capabilities,
                "serverInfo": serverInfo,
                "instructions": .string(server.instructions),
            ], id: id, reply: reply)
        case "server/discover":
            send(result: [
                "supportedVersions": supportedVersions,
                "capabilities": ["tools": [:]],
                "instructions": .string(server.instructions),
                "ttlMs": .int(Self.listTTL),
                "cacheScope": "public",
            ], id: id, modern: true, reply: reply)
        case "ping":   // legacy only (removed in 2026-07-28); harmless to answer either way
            send(result: [:], id: id, modern: modern, reply: reply)
        case "tools/list":
            var result: [String: Value] = ["tools": .array(server.tools.map(\.json))]
            if modern { result["ttlMs"] = .int(Self.listTTL); result["cacheScope"] = "public" }
            send(result: result, id: id, modern: modern, reply: reply)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return send(error: RPCError.invalidParams, "Invalid params: tools/call needs a string \"name\"", id: id, reply: reply)
            }
            guard let arguments = params["arguments"].map({ $0.objectValue }) ?? [:] else {
                return send(error: RPCError.invalidParams, "Invalid params: \"arguments\" must be an object", id: id, reply: reply)
            }
            if modern, !server.tools.contains(where: { $0.name == name }) {
                // 2026-07-28: an unknown tool is a protocol error (legacy clients get an isError result instead).
                return send(error: RPCError.invalidParams, "Invalid params: unknown tool \(name)", id: id, reply: reply)
            }
            startCall(name, arguments, id: id, modern: modern, context: context,
                      bytes: Value.object(params).jsonData().count + id.jsonData().count, reply: reply)
        default:
            send(error: RPCError.methodNotFound, "Method not found: \(method)", id: id, reply: reply)
        }
    }

    private func startCall(_ name: String, _ arguments: [String: Value], id: Value, modern: Bool,
                           context: RequestContext, bytes: Int, reply: @escaping Reply) {
        let key = Self.key(id)
        let rejection: String? = lock.withLock {
            guard !closed else { return "Connection closed" }
            guard calls[key] == nil else { return "Request id already in flight" }
            guard calls.count < limits.concurrentCalls else { return "Too many concurrent tool calls (limit \(limits.concurrentCalls))" }
            guard bytes <= limits.queuedBytes - callBytes else { return "In-flight request byte limit exceeded" }
            callBytes += bytes
            calls[key] = Task {
                defer {
                    self.lock.withLock {
                        self.calls[key] = nil
                        self.callBytes -= bytes
                        self.cancelled.remove(key)
                    }
                }
                let result = await server.call(name, arguments, context)
                let suppressed = self.lock.withLock {
                    self.cancelled.contains(key) || self.closed || Task.isCancelled
                }
                guard !suppressed else { reply(nil); return }
                self.send(result: ["content": .array(result.content.map(\.json)), "isError": .bool(result.isError)],
                          id: id, modern: modern, reply: reply)
            }
            return nil
        }
        if let rejection { send(error: -32603, rejection, id: id, reply: reply) }
    }

    private var capabilities: Value { ["tools": ["listChanged": false]] }
    private var serverInfo: Value { ["name": .string(server.name), "version": .string(server.version)] }
    private var supportedVersions: Value { .array((Self.statelessVersions + [Self.latestHandshakeVersion]).map(Value.string)) }

    // MARK: output

    /// Modern results say they're complete (not a multi-round-trip `input_required`) and who answered.
    private func send(result: [String: Value], id: Value, modern: Bool = false, reply: Reply) {
        var result = result
        if modern {
            result["resultType"] = "complete"
            result["_meta"] = [Self.metaServerInfoKey: serverInfo]
        }
        reply(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    private func send(error code: Int, _ message: String, id: Value, data: Value? = nil, reply: Reply) {
        var error: [String: Value] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        reply(["jsonrpc": "2.0", "id": id, "error": .object(error)])
    }

    private func write(_ message: Value) {
        var data = message.jsonData()
        if data.count + 1 > limits.frameBytes {
            data = Self.responseTooLarge(id: message["id"] ?? .null, bytes: data.count + 1).jsonData()
        }
        data.append(0x0A)
        guard data.count <= limits.frameBytes, writer.send(data) else { closeAdmission(); return }
    }

    static func responseTooLarge(id: Value, bytes: Int) -> Value {
        let megabytes = String(format: "%.2f", Double(bytes) / (1024 * 1024))
        return ["jsonrpc": "2.0", "id": id, "error": ["code": -32603,
            "message": .string("response too large (\(megabytes) MB); narrow the request, e.g. a smaller region or max_tokens")]]
    }

    /// Request ids compare by JSON value: 7 and "7" are different requests.
    static func key(_ id: Value) -> String { String(decoding: id.jsonData(), as: UTF8.self) }
}

/// Only the dedicated reader waits here. Consumers and teardown wake it without blocking the cooperative pool.
final class FrameBackpressure: @unchecked Sendable {
    private let condition = NSCondition()
    private let maxFrames: Int
    private let maxBytes: Int
    private var frames = 0
    private var bytes = 0
    private var closed = false
    private let onWait: @Sendable () -> Void

    init(maxFrames: Int, maxBytes: Int, onWait: @escaping @Sendable () -> Void = {}) {
        self.maxFrames = maxFrames
        self.maxBytes = maxBytes
        self.onWait = onWait
    }

    func admit(_ size: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard size <= maxBytes, maxFrames > 0 else { return false }
        while !closed, frames >= maxFrames || size > maxBytes - bytes {
            onWait()
            condition.wait()   // lint:allow-blocking dedicated socket reader, woken by consumption or teardown
        }
        guard !closed else { return false }
        frames += 1
        bytes += size
        return true
    }

    func remove(_ size: Int) {
        condition.lock()
        defer { condition.unlock() }
        frames -= 1
        bytes -= size
        condition.signal()
    }

    func close() {
        condition.lock()
        defer { condition.unlock() }
        closed = true
        condition.broadcast()
    }
}

/// Reserve an error slot for every entry before accepting larger results, including array framing. The final
/// array therefore fits one frame even when every remaining call needs an oversized-response error.
private final class BatchResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var responses: [Int: Value] = [:]
    private var sizes: [Int]
    private var bytes: Int
    private let frameBytes: Int
    private let reserve: @Sendable (Int) -> Bool
    private let release: @Sendable (Int) -> Void
    private let send: @Sendable (Value) -> Void

    init?(entries: [Value], frameBytes: Int, reserve: @escaping @Sendable (Int) -> Bool,
          release: @escaping @Sendable (Int) -> Void, send: @escaping @Sendable (Value) -> Void) {
        remaining = entries.count
        self.frameBytes = frameBytes
        self.reserve = reserve
        self.release = release
        self.send = send
        // Int.max reserves the longest size label a replacement error can need.
        sizes = entries.map { Connection.responseTooLarge(id: $0["id"] ?? .null, bytes: Int.max).jsonData().count + 1 }
        bytes = sizes.reduce(2, +)   // '[' and ']\n', less the final comma
        guard bytes <= frameBytes, reserve(bytes) else { bytes = 0; return nil }
    }

    deinit { release(bytes) }

    func finish(_ index: Int, response: Value?) {
        lock.withLock {
            let oldSize = sizes[index]
            var response = response
            var size = response.map { $0.jsonData().count + 1 } ?? 0
            if size > oldSize {
                if size <= frameBytes - bytes + oldSize, reserve(size - oldSize) {
                    bytes += size - oldSize
                } else if let original = response {
                    response = Connection.responseTooLarge(id: original["id"] ?? .null, bytes: size)
                    size = response!.jsonData().count + 1
                }
            }
            if size < oldSize { release(oldSize - size); bytes -= oldSize - size }
            sizes[index] = size
            if let response { responses[index] = response }
            remaining -= 1
            if remaining == 0 {
                if !responses.isEmpty { send(.array(responses.keys.sorted().compactMap { responses[$0] })) }
                release(bytes)
                bytes = 0
                responses = [:]
            }
        }
    }
}
