import Foundation
import Testing
import MacMCPCore
@testable import MacMCPServer

/// The client end of a socket pair whose other end is served by a `Connection`.
final class Peer: @unchecked Sendable {
    let fd: Int32
    let serving: Task<Void, Never>
    private var framing = LineBuffer()
    private var pending: [Data] = []

    init(_ server: ServerDefinition) throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        fd = fds[1]
        let connection = Connection(fd: fds[0], server: server)
        let serverFD = fds[0]
        serving = Task { await connection.run(); Darwin.close(serverFD) }
        session = connection.session
    }

    let session: Session

    func send(_ message: Value) { sendRaw(String(decoding: message.jsonData(), as: UTF8.self)) }

    func sendRaw(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    /// The next message from the server, or nil if none arrives within `timeout`. The blocking wait runs on a GCD
    /// thread: tests blocking the cooperative pool would starve the very Connection they're talking to.
    func next(timeout: TimeInterval = 5) async -> Value? {
        await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: self.nextBlocking(timeout: timeout)) }
        }
    }

    private func nextBlocking(timeout: TimeInterval) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while pending.isEmpty {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(left * 1000)) > 0 else { return nil }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            pending += framing.append(buffer[0..<n])
        }
        return try? Value.parse(pending.removeFirst())
    }

    func close() {
        Darwin.close(fd)
    }
}

let modernMeta: Value = [
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "9"],
    "io.modelcontextprotocol/clientCapabilities": [:],
]

func request(_ id: Value, _ method: String, _ params: Value? = nil) -> Value {
    var m: [String: Value] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
    if let params { m["params"] = params }
    return .object(m)
}

/// A server with two tools: `echo` (returns its `text`, optionally repeated) and `block` (waits until cancelled).
func testServer(cancelled: Probe? = nil) -> ServerDefinition {
    let echo = Tool(name: "echo", description: "Echo", inputSchema: ["type": "object"], annotations: .init(readOnlyHint: true))
    let block = Tool(name: "block", description: "Block", inputSchema: ["type": "object"], annotations: .init(readOnlyHint: true))
    return ServerDefinition(name: "test", version: "1.0", instructions: "Test server.", tools: [echo, block]) { name, args, session in
        switch name {
        case "echo":
            let text = args["text"]?.stringValue ?? ""
            return CallResult(content: [.text(String(repeating: text, count: args["repeat"]?.intValue ?? 1))])
        case "block":
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            cancelled?.add("cancelled")
            return CallResult(content: [.text("late")])
        default:
            return CallResult(content: [.text("Unknown tool \(name).")], isError: true)
        }
    }
}

final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ v: String) { lock.withLock { values.append(v) } }
    var all: [String] { lock.withLock { values } }
}

@Suite struct LegacyEraTests {
    @Test func initializeNegotiatesTheVersion() async throws {
        for (asked, answered) in [("2025-11-25", "2025-11-25"), ("2024-11-05", "2024-11-05"), ("1999-01-01", "2025-11-25")] {
            let peer = try Peer(testServer())
            defer { peer.close() }
            peer.send(request(1, "initialize", ["protocolVersion": .string(asked), "capabilities": [:],
                                                "clientInfo": ["name": "claude-code", "version": "2.1"]]))
            let r = try #require(await peer.next()?["result"])
            #expect(r["protocolVersion"]?.stringValue == answered)
            #expect(r["serverInfo"] == ["name": "test", "version": "1.0"])
            #expect(r["capabilities"] == ["tools": ["listChanged": false]])
            #expect(r["instructions"]?.stringValue == "Test server.")
            #expect(r["resultType"] == nil && r["_meta"] == nil)   // legacy results stay as they were
        }
    }

    @Test func listCallAndErrors() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"]]))
        _ = await peer.next()
        peer.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(await peer.session.client == "c 1")

        peer.send(request(2, "tools/list"))
        let list = try #require(await peer.next())
        #expect(list["id"] == 2 && list["result"]?["tools"]?.arrayValue?.count == 2)
        #expect(list["result"]?["ttlMs"] == nil)

        peer.send(request("s", "tools/call", ["name": "echo", "arguments": ["text": "hi"]]))
        #expect(await peer.next() == ["jsonrpc": "2.0", "id": "s", "result": ["content": [["type": "text", "text": "hi"]], "isError": false]])

        peer.send(request(3, "tools/call", ["name": "nope"]))   // legacy: unknown tool is a tool error
        #expect(await peer.next()?["result"]?["isError"] == true)

        peer.send(request(4, "ping"))
        #expect(await peer.next()?["result"] == [:])

        peer.send(request(5, "subscriptions/listen"))
        let notFound = try #require(await peer.next()?["error"])
        #expect(notFound["code"] == -32601)
        let message = notFound["message"]?.stringValue ?? ""
        #expect(message == "Method not found: subscriptions/listen")   // no protocol version: would derail Claude Code's fallback

        peer.send(request(6, "tools/call"))
        #expect(await peer.next()?["error"]?["code"] == -32602)
        peer.send(request(7, "tools/call", ["name": "echo", "arguments": "not an object"]))
        #expect(await peer.next()?["error"]?["code"] == -32602)

        peer.sendRaw("{not json")
        #expect(await peer.next() == ["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "Parse error: not valid JSON"]])
        peer.sendRaw("[1, 2]")
        #expect(await peer.next()?["error"]?["code"] == -32600)

        // A response to nothing and an unknown notification get no reply; the next request still does.
        peer.send(["jsonrpc": "2.0", "id": 99, "result": [:]])
        peer.send(["jsonrpc": "2.0", "method": "notifications/whatever"])
        peer.send(request(8, "ping"))
        #expect(await peer.next()?["id"] == 8)
    }
}

@Suite struct ModernEraTests {
    @Test func discoverDescribesTheServer() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request("server-discover-probe-1", "server/discover", ["_meta": modernMeta]))
        let r = try #require(await peer.next()?["result"])
        #expect(r["resultType"] == "complete")
        #expect(r["supportedVersions"]?.arrayValue?.contains("2026-07-28") == true)
        #expect(r["supportedVersions"]?.arrayValue?.contains("2025-11-25") == true)
        #expect(r["capabilities"]?["tools"] != nil)
        #expect(r["ttlMs"]?.intValue ?? -1 >= 0 && r["cacheScope"] == "public")
        #expect(r["_meta"]?["io.modelcontextprotocol/serverInfo"] == ["name": "test", "version": "1.0"])
        #expect(r["protocolVersion"] == nil && r["serverInfo"] == nil)
    }

    @Test func statelessRequestsWithoutHandshake() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request(1, "tools/list", ["_meta": modernMeta]))
        let list = try #require(await peer.next()?["result"])
        #expect(list["resultType"] == "complete" && list["cacheScope"] == "public" && list["ttlMs"] != nil)
        #expect(list["tools"]?.arrayValue?.count == 2)
        #expect(await peer.session.client == "test-client 9")
        #expect(await peer.session.protocolVersion == "2026-07-28")

        peer.send(request(2, "tools/call", ["_meta": modernMeta, "name": "echo", "arguments": ["text": "x"]]))
        let call = try #require(await peer.next()?["result"])
        #expect(call["resultType"] == "complete" && call["content"] == [["type": "text", "text": "x"]])

        peer.send(request(3, "tools/call", ["_meta": modernMeta, "name": "nope"]))   // modern: protocol error
        #expect(await peer.next()?["error"]?["code"] == -32602)
    }

    @Test func badMetaIsRejected() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request(1, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01",
                                                      "io.modelcontextprotocol/clientCapabilities": [:]]]))
        let e = try #require(await peer.next()?["error"])
        #expect(e["code"] == -32022 && e["data"]?["requested"] == "1900-01-01")
        #expect(e["data"]?["supported"]?.arrayValue?.contains("2026-07-28") == true)
        peer.send(request(2, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]))
        #expect(await peer.next()?["error"]?["code"] == -32602)   // clientCapabilities is required
    }
}

@Suite struct ConnectionBehaviourTests {
    /// The M5 transport bug: a big response and a small one finishing together must both arrive whole.
    @Test func concurrentResponsesArriveWhole() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request(1, "tools/call", ["name": "echo", "arguments": ["text": "abcdefghij", "repeat": 300_000]]))
        for i in 2...20 { peer.send(request(.int(i), "tools/call", ["name": "echo", "arguments": ["text": "small"]])) }
        var ids: Set<Int> = []
        for _ in 1...20 {
            let m = try #require(await peer.next(timeout: 10), "a response was lost or corrupted")
            ids.insert(try #require(m["id"]?.intValue))
            if m["id"] == 1 {
                #expect(m["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.count == 3_000_000)
            }
        }
        #expect(ids == Set(1...20))
    }

    @Test func cancelledCallsStopAndGetNoResponse() async throws {
        let probe = Probe()
        let peer = try Peer(testServer(cancelled: probe))
        defer { peer.close() }
        peer.send(request("slow", "tools/call", ["name": "block"]))
        try await Task.sleep(for: .milliseconds(100))
        peer.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "slow", "reason": "user"]])
        peer.send(request(2, "ping"))
        #expect(await peer.next()?["id"] == 2)   // not the cancelled call
        #expect(await peer.next(timeout: 0.5) == nil)
        #expect(probe.all == ["cancelled"])
    }

    @Test func closingTheConnectionCancelsCalls() async throws {
        let probe = Probe()
        let peer = try Peer(testServer(cancelled: probe))
        peer.send(request(1, "tools/call", ["name": "block"]))
        try await Task.sleep(for: .milliseconds(100))
        peer.close()
        await peer.serving.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.all == ["cancelled"])
    }

    /// A dropped client (an SSH link gone) must not leave the GUI claimed for the claim's idle time.
    @Test func closingTheConnectionReleasesItsClaims() async throws {
        let peer = try Peer(testServer())
        let session = "t-\(UUID().uuidString.prefix(8))", resource = "test-\(UUID())"
        peer.sendRaw("#mac-mcp origin=ssh:10.0.0.9 session=\(session)")
        peer.send(request(1, "ping"))
        #expect(await peer.next()?["id"] == 1)
        let (id, origin) = (await peer.session.id, await peer.session.origin)
        #expect(id == session && origin == "ssh:10.0.0.9")
        #expect(await Claims.shared.tryBegin(resource, session: session, client: "t", origin: nil) == nil)
        peer.close()
        await peer.serving.value
        #expect(await Claims.shared.holder(resource) == nil)
    }

    @Test func directivesAreTakenOutOfTheStream() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.sendRaw("#mac-mcp lease=abc123 future=1")
        peer.send(request(1, "ping"))
        #expect(await peer.next()?["id"] == 1)   // the directive itself got no reply
        #expect(await peer.session.leaseToken == "abc123")
    }
}

@Suite struct CompatibilityTests {
    /// Clients built against the tool list recorded from swift-sdk 0.12.1 (before M7) must keep working: the same
    /// tools in the same order, with the same annotations, and every recorded parameter still there with the same
    /// schema. Tools may gain parameters (mac_screenshot ocr=, M9), parameters may gain enum values and reworded
    /// descriptions (mac_wait until=unlock, M12), and new tools follow the old ones (web_*, M8).
    @Test func toolListStaysCompatibleWithTheSDKRecording() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/protocol/sdk-0.12.1-responses.json")
        let recorded = try Value.parse(try Data(contentsOf: fixture))
        let sdkList = try #require(recorded["tools_list"]?.arrayValue?.last?["result"]?["tools"]?.arrayValue)
        let path = NSTemporaryDirectory() + "audit-\(UUID()).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ours = MacMCPServer.definition(audit: AuditLog(path: path)).tools.map(\.json)
        #expect(ours.prefix(sdkList.count).map { $0["name"] } == sdkList.map { $0["name"] })
        for (old, new) in zip(sdkList, ours) {
            let name = old["name"]?.stringValue ?? "?"
            #expect(new["annotations"] == old["annotations"], "\(name) annotations changed")
            #expect(new["inputSchema"]?["required"] == old["inputSchema"]?["required"], "\(name) required params changed")
            for (param, schema) in old["inputSchema"]?["properties"]?.objectValue ?? [:] {
                let now = new["inputSchema"]?["properties"]?[param]
                #expect(now?["type"] == schema["type"], "\(name).\(param) changed type or was removed")
                let oldEnum = Set((schema["enum"]?.arrayValue ?? []).compactMap(\.stringValue))
                let newEnum = Set((now?["enum"]?.arrayValue ?? []).compactMap(\.stringValue))
                #expect(oldEnum.isSubset(of: newEnum) && (oldEnum.isEmpty == newEnum.isEmpty), "\(name).\(param) lost enum values")
            }
        }
    }
}
