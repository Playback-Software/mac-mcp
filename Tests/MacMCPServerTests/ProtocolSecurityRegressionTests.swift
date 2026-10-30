import Foundation
import Testing
import MacMCPCore
@testable import MacMCPServer

private actor RPCGate {
    private var count = 0
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        count += 1
        let ready = countWaiters.filter { $0.0 <= count }
        countWaiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func started(_ n: Int = 1) async { if count < n { await withCheckedContinuation { countWaiters.append((n, $0)) } } }
    func open() { opened = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
}

private final class LimitedPeer: @unchecked Sendable {
    let fd: Int32
    let serverFD: Int32
    let connection: Connection
    let serving: Task<Void, Never>
    init(_ server: ServerDefinition, limits: Connection.Limits = .init()) throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        fd = fds[1]; serverFD = fds[0]
        let connection = Connection(fd: fds[0], server: server, limits: limits)
        self.connection = connection
        serving = Task { await connection.run() }
    }
    func send(_ message: Value) { sendRaw(String(decoding: message.jsonData(), as: UTF8.self)) }
    func sendRaw(_ line: String) { let data = Data((line + "\n").utf8); _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } }
    func close() { Darwin.close(fd); Darwin.close(serverFD) }
    func next(timeout: TimeInterval = 30) async -> Value? {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 1), line = Data()
                let end = StreamIO.now + timeout
                while StreamIO.now < end {
                    var p = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&p, 1, Int32(max(1, (end - StreamIO.now) * 1000))) > 0,
                          read(self.fd, &buffer, 1) == 1 else { c.resume(returning: nil); return }
                    if buffer[0] == 0x0A { c.resume(returning: try? Value.parse(line)); return }
                    line.append(buffer[0])
                }
                c.resume(returning: nil)
            }
        }
    }
}

@Suite struct ProtocolSecurityRegressionTests {
    @Test func directivesAreIgnoredAfterAnyJSONRPCMessage() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.sendRaw("#mac-mcp origin=ssh:trusted session=trusted lease=original")
        peer.send(request(1, "ping"))
        #expect(await peer.next()?["id"] == 1)
        peer.sendRaw("#mac-mcp origin=local session=victim lease=spoofed")
        peer.send(request(2, "ping"))
        #expect(await peer.next()?["id"] == 2)
        #expect(await peer.session.id == "trusted")
        #expect(await peer.session.origin == "ssh:trusted")
        #expect(await peer.session.leaseToken == "original")
    }

    @Test func sessionLeaseOwnershipIsNeverLatched() async throws {
        let directory = NSTemporaryDirectory() + "session-lease-\(UUID())", path = directory + "/lease.json"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = Session(leasePath: path)
        let lease = try LeaseStore.acquire(holder: "test", reason: "ownership", minutes: 5, pid: 0, path: path)
        await session.apply(directive: "#mac-mcp lease=\(lease.token)")
        #expect(await session.leaseHolder == "test")
        #expect(LeaseStore.release(token: lease.token, path: path))
        #expect(await session.leaseHolder == nil)
        _ = try LeaseStore.acquire(holder: "other", reason: "ownership", minutes: 5, pid: 0, path: path)
        #expect(await session.leaseHolder == nil)
    }

    @Test func pipelinedModernRequestsHaveIndependentIdentity() async throws {
        let gate = RPCGate()
        let tool = Tool(name: "identity", description: "identity", inputSchema: [:], annotations: .init(readOnlyHint: true))
        let server = ServerDefinition(name: "test", version: "1", instructions: "", tools: [tool]) { _, _, context in
            await gate.enter()
            return CallResult(content: [.text("\(context.client)|\(context.protocolVersion ?? "nil")")])
        }
        let peer = try Peer(server)
        defer { peer.close() }
        for (id, name) in [(1, "a"), (2, "b"), (3, "")] {
            var meta = modernMeta.objectValue!
            if name.isEmpty { meta[Connection.metaClientInfoKey] = nil }
            else { meta[Connection.metaClientInfoKey] = ["name": .string(name)] }
            peer.send(request(.int(id), "tools/call", ["name": "identity", "_meta": .object(meta)]))
        }
        await gate.started(3)
        peer.send(request(4, "ping"))
        #expect(await peer.next()?["id"] == 4)
        await gate.open()
        var identities: [Int: String] = [:]
        for _ in 0..<3 {
            let result = try #require(await peer.next())
            identities[result["id"]!.intValue!] = result["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }
        #expect(await peer.session.client == "a")
        #expect(identities == [1: "a|2026-07-28", 2: "b|2026-07-28", 3: "unknown|2026-07-28"])
    }

    @Test func modernIdentityDoesNotReplaceNegotiatedLegacyIdentity() async throws {
        let tool = Tool(name: "identity", description: "identity", inputSchema: [:], annotations: .init(readOnlyHint: true))
        let server = ServerDefinition(name: "test", version: "1", instructions: "", tools: [tool]) { _, _, context in
            CallResult(content: [.text(context.client)])
        }
        let peer = try Peer(server)
        defer { peer.close() }
        peer.send(request(1, "initialize", ["protocolVersion": "2025-03-26", "clientInfo": ["name": "legacy"]]))
        _ = await peer.next()
        peer.send(request(2, "tools/call", ["name": "identity", "_meta": modernMeta]))
        #expect(await peer.next()?["result"]?["content"]?.arrayValue?.first?["text"] == "test-client 9")
        peer.send(.array([request(3, "tools/call", ["name": "identity"])]))
        let batch = try #require(await peer.next()?.arrayValue)
        #expect(batch.first?["result"]?["content"]?.arrayValue?.first?["text"] == "legacy")
        #expect(await peer.session.client == "legacy")
    }

    @Test func concurrentCallLimitRejectsWithoutDispatchingMoreWork() async throws {
        var limits = Connection.Limits(); limits.concurrentCalls = 1
        let peer = try LimitedPeer(testServer(), limits: limits)
        defer { peer.close() }
        peer.send(request(1, "tools/call", ["name": "block"]))
        peer.send(request(2, "tools/call", ["name": "echo"]))
        let refused = try #require(await peer.next())
        #expect(refused["id"] == 2 && refused["error"]?["code"] == -32603)
        #expect(refused["error"]?["message"]?.stringValue?.contains("limit 1") == true)
        shutdown(peer.fd, SHUT_RDWR)
        await peer.serving.value
    }

    @Test func oversizedInputClosesTheConnection() async throws {
        var limits = Connection.Limits(); limits.frameBytes = 32
        let peer = try LimitedPeer(testServer(), limits: limits)
        defer { peer.close() }
        peer.sendRaw(String(repeating: "x", count: 33))
        #expect(await peer.next() == nil)
        await peer.serving.value
    }

    @Test func oversizedResponseReturnsAnErrorAndKeepsOtherCallsAlive() async throws {
        var limits = Connection.Limits(); limits.frameBytes = 1024
        let peer = try LimitedPeer(testServer(), limits: limits)
        defer { peer.close() }
        peer.send(request(1, "tools/call", ["name": "echo", "arguments": ["text": "x", "repeat": 4096]]))
        let response = try #require(await peer.next())
        #expect(response["id"] == 1 && response["error"]?["code"] == -32603)
        #expect(response["error"]?["message"]?.stringValue?.contains("response too large") == true)
        #expect(response["error"]?["message"]?.stringValue?.contains("max_tokens") == true)
        peer.send(request(2, "ping"))
        #expect(await peer.next()?["id"] == 2)
    }

    @Test func batchOverflowReplacesEntriesAndFitsOneFrame() async throws {
        var limits = Connection.Limits(); limits.frameBytes = 2048
        let peer = try LimitedPeer(testServer(), limits: limits)
        defer { peer.close() }
        peer.send(request(1, "initialize", ["protocolVersion": "2025-03-26"]))
        _ = await peer.next()
        peer.send(.array((2...5).map { id in
            request(.int(id), "tools/call", ["name": "echo", "arguments": ["text": "x", "repeat": id == 5 ? 4096 : 700]])
        }))
        let response = try #require(await peer.next())
        let entries = try #require(response.arrayValue)
        #expect(entries.map { $0["id"]! } == [2, 3, 4, 5])
        #expect(response.jsonData().count + 1 <= limits.frameBytes)
        #expect(entries.contains { $0["result"] != nil })
        #expect(entries.filter { $0["error"]?["code"] == -32603 }.count >= 2)
        #expect(entries.last?["error"]?["message"]?.stringValue?.contains("response too large") == true)
        peer.send(request(6, "ping"))
        #expect(await peer.next()?["id"] == 6)
    }

    @Test func jsonrpcVersionIsRequiredOnRequestsAndNotifications() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        for version: Value? in [nil, "1.0", 2, .null] {
            var message: [String: Value] = ["id": 1, "method": "ping"]
            message["jsonrpc"] = version
            peer.send(.object(message))
            let response = try #require(await peer.next())
            #expect(response["error"]?["code"] == -32600 && response["id"] == .null)
        }
        peer.send(["method": "notifications/initialized"])
        #expect(await peer.next()?["error"]?["code"] == -32600)
        peer.send(request(2, "ping"))
        #expect(await peer.next()?["id"] == 2)
    }

    @Test func frameCountAndByteBoundsPauseTheReaderUntilConsumption() async throws {
        for size in [1, 8] {
            let (waiting, notify) = AsyncStream<Void>.makeStream()
            let input = FrameBackpressure(maxFrames: size == 1 ? 1 : 64, maxBytes: 8, onWait: { notify.yield(()) })
            #expect(input.admit(size))
            let next = Task {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: input.admit(size)) }
                }
            }
            for await _ in waiting { break }
            input.remove(size)
            #expect(await next.value)
            input.close()
            #expect(!input.admit(1))
            notify.finish()
        }
    }

    @Test func teardownWakesAReaderWaitingForFrameSpace() async {
        let (waiting, notify) = AsyncStream<Void>.makeStream()
        let input = FrameBackpressure(maxFrames: 1, maxBytes: 8, onWait: { notify.yield(()) })
        #expect(input.admit(1))
        let next = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: input.admit(1)) }
            }
        }
        for await _ in waiting { break }
        input.close()
        #expect(await next.value == false)
        notify.finish()
    }

    @Test func burstOfNotificationsDoesNotDropTheConnection() async throws {
        var limits = Connection.Limits(); limits.queuedFrames = 1
        let peer = try LimitedPeer(testServer(), limits: limits)
        defer { peer.close() }
        let lines = Array(repeating: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999}}"#, count: 128)
        peer.sendRaw((lines + [String(decoding: request(1, "ping").jsonData(), as: UTF8.self)]).joined(separator: "\n"))
        #expect(await peer.next()?["id"] == 1)
    }

    @Test func lateCompletionCannotWriteToAReusedDescriptor() async throws {
        let gate = RPCGate(), finished = RPCGate()
        let server = ServerDefinition(name: "test", version: "1", instructions: "", tools: []) { _, _, _ in
            await gate.enter()   // deliberately ignores cancellation, like a wedged framework call
            await finished.open()
            return CallResult(content: [.text("late")])
        }
        let peer = try LimitedPeer(server)
        defer { peer.close() }
        peer.send(request(1, "tools/call", ["name": "late"]))
        await gate.started()
        shutdown(peer.fd, SHUT_RDWR)
        await peer.serving.value
        var replacement: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &replacement) == 0)
        defer { close(replacement[0]); close(replacement[1]) }
        #expect(dup2(replacement[0], peer.serverFD) == peer.serverFD)
        await gate.open()
        await finished.enter()
        let replacementPeer = replacement[1]
        let leaked = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                var p = pollfd(fd: replacementPeer, events: Int16(POLLIN), revents: 0)
                c.resume(returning: poll(&p, 1, 100) > 0)
            }
        }
        #expect(!leaked)
    }

    @Test func marchBatchesReturnOneArrayAndExcludeNotifications() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request(1, "initialize", ["protocolVersion": "2025-03-26"]))
        #expect(await peer.next()?["result"]?["protocolVersion"] == "2025-03-26")
        peer.send(.array([request("a", "tools/call", ["name": "echo", "arguments": ["text": "batch"]]),
                          ["jsonrpc": "2.0", "method": "notifications/initialized"],
                          request(2, "ping"), 123, request(3, "unknown")]))
        let responses = try #require(await peer.next()?.arrayValue)
        #expect(responses.count == 4)
        #expect(responses.map { $0["id"]! } == ["a", 2, .null, 3])
        #expect(responses[0]["result"]?["content"]?.arrayValue?.first?["text"] == "batch")
        #expect(responses[2]["error"]?["code"] == -32600)
        #expect(responses[3]["error"]?["code"] == -32601)
        peer.send(.array([["jsonrpc": "2.0", "method": "notifications/initialized"]]))
        peer.send(request(4, "ping"))
        #expect(await peer.next()?["id"] == 4)
        peer.send(.array([]))
        #expect(await peer.next()?["error"]?["code"] == -32600)
    }

    @Test func cancelledBatchCallDoesNotHoldUpOtherResponses() async throws {
        let peer = try Peer(testServer())
        defer { peer.close() }
        peer.send(request(1, "initialize", ["protocolVersion": "2025-03-26"]))
        _ = await peer.next()
        peer.send(.array([request(2, "tools/call", ["name": "block"]), request(3, "ping")]))
        peer.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]])
        let batch = try #require(await peer.next()?.arrayValue)
        #expect(batch.count == 1 && batch.first?["id"] == 3)
    }

    @Test func shortcutExposesItsFullHoldDeadline() {
        let args = ToolArgs(["action": "run", "timeout": 300])
        #expect(ShortcutTool.holdDeadline(args, policy: Policy()) == 305)
    }
}
