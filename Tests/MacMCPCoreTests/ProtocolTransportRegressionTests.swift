import Foundation
import Testing
@testable import MacMCPCore

private func transportPair() throws -> [Int32] {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
    return fds
}

private func transportThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in DispatchQueue.global().async { c.resume(with: Result(catching: body)) } }
}

@Suite struct ProtocolTransportRegressionTests {
    @Test func unterminatedAndTerminatedFramesHaveTheSameBound() {
        var buffer = LineBuffer(maxBytes: 8)
        #expect(buffer.append(Array("12345678".utf8)).isEmpty)
        #expect(!buffer.exceededLimit)
        #expect(buffer.append(Array("9".utf8)).isEmpty)
        #expect(buffer.exceededLimit)
        buffer.reset()
        #expect(buffer.append(Array("123456789\n".utf8)).isEmpty)
        #expect(buffer.exceededLimit)
        buffer.reset()
        #expect(buffer.append(Array("12345678\na\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["12345678", "a"])
    }

    @Test func writerRejectsOverflowAndEverySendAfterItsBarrier() async throws {
        let fds = try transportPair()
        defer { close(fds[0]); close(fds[1]) }
        try StreamIO.configure(fds[0])
        let writer = StreamWriter(fd: fds[0], maxBytes: 8)
        #expect(!writer.send(Data(repeating: 1, count: 9)))
        await writer.finish()
        #expect(!writer.send(Data("late\n".utf8)))
    }

    @Test func repeatedAbortCannotShutdownAReusedDescriptor() async throws {
        let old = try transportPair(), replacement = try transportPair()
        defer { close(old[0]); close(old[1]); close(replacement[0]); close(replacement[1]) }
        try StreamIO.configure(old[0])
        let writer = StreamWriter(fd: old[0])
        await writer.finish()
        #expect(dup2(replacement[0], old[0]) == old[0])
        writer.abort()
        #expect(!writer.send(Data([1])))
        try StreamIO.configure(old[0])
        try await transportThread { try StreamIO.writeAll(old[0], Data([0x41]), deadline: StreamIO.now + 30) }
        let value = try await transportThread {
            var byte: UInt8 = 0
            try StreamIO.wait(replacement[1], events: Int16(POLLIN), deadline: StreamIO.now + 30)
            guard read(replacement[1], &byte, 1) == 1 else { throw POSIXError(.EIO) }
            return byte
        }
        #expect(value == 0x41)
    }

    @Test func writeLoopRetriesEINTRAndEAGAINWithoutLosingBytes() throws {
        var attempts = 0, waits = 0, received: [UInt8] = []
        try StreamIO.writeAll(Data([1, 2, 3, 4]), waitForWrite: { _ in waits += 1 }, writeChunk: { pointer, count in
            attempts += 1
            if attempts <= 2 { errno = attempts == 1 ? EINTR : EAGAIN; return -1 }
            received.append(pointer.load(as: UInt8.self))
            return min(1, count)
        })
        #expect(received == [1, 2, 3, 4])
        #expect(attempts == 6 && waits == 6)
    }

    @Test func steadilyDrainingReaderCanTakeLongerThanTheProgressTimeout() async throws {
        let fds = try transportPair()
        defer { close(fds[0]); close(fds[1]) }
        let received = try await transportThread {
            var clock: TimeInterval = 0, received = Data()
            try StreamIO.writeAll(Data([1, 2, 3, 4]), progressTimeout: 10, now: { clock }, waitForWrite: { deadline in
                // The gated reader accepts one byte every four seconds of injected time.
                clock += 4
                guard clock < deadline else { throw POSIXError(.ETIMEDOUT) }
            }, writeChunk: { pointer, _ in
                let n = write(fds[0], pointer, 1)
                var byte: UInt8 = 0
                if n == 1, read(fds[1], &byte, 1) == 1 { received.append(byte) }
                return n
            })
            #expect(clock == 16)
            return received
        }
        #expect(received == Data([1, 2, 3, 4]))
    }

    @Test func retriesWithoutAcceptedBytesDoNotResetProgressTimeout() {
        var clock: TimeInterval = 0, attempts = 0
        #expect(throws: POSIXError.self) {
            try StreamIO.writeAll(Data([1]), progressTimeout: 10, now: { clock }, waitForWrite: { deadline in
                clock += 4
                guard clock < deadline else { throw POSIXError(.ETIMEDOUT) }
            }, writeChunk: { _, _ in attempts += 1; errno = attempts == 1 ? EINTR : EAGAIN; return -1 })
        }
        #expect(clock == 12 && attempts == 2)
    }

    @Test func overallDeadlineStillBoundsProgressForAgentClient() {
        var clock: TimeInterval = 0, accepted = 0
        #expect(throws: POSIXError.self) {
            try StreamIO.writeAll(Data([1, 2, 3, 4]), deadline: 10, progressTimeout: 10, now: { clock }, waitForWrite: { deadline in
                clock += 4
                guard clock < deadline else { throw POSIXError(.ETIMEDOUT) }
            }, writeChunk: { _, _ in accepted += 1; return 1 })
        }
        #expect(clock == 12 && accepted == 2)
    }

    /// A reader that accepts one byte just inside each progress timeout keeps the progress timer alive for ever. The
    /// write budget ends such a write all the same, while a steadily draining slow link still fits inside it.
    @Test func aReaderBarelyKeepingTheProgressTimerAliveCannotHoldAWriterForEver() {
        let data = Data(repeating: 0, count: 100)
        let budget = StreamIO.writeBudget(bytes: data.count)
        var clock: TimeInterval = 0, accepted = 0
        #expect(throws: POSIXError.self) {
            try StreamIO.writeAll(data, progressTimeout: 10, maxDuration: budget, now: { clock }, waitForWrite: { deadline in
                clock += 9.9   // one byte just inside each progress timeout
                guard clock < deadline else { throw POSIXError(.ETIMEDOUT) }
            }, writeChunk: { _, _ in accepted += 1; return 1 })
        }
        #expect(accepted < data.count && clock < budget + 10, "the write outlived its budget: \(clock) s for \(accepted) bytes")
        #expect(StreamIO.writeBudget(bytes: 0) == 600 && StreamIO.writeBudget(bytes: 16 * 1024 * 1024) == 600 + 1024)
        // A slow link that is genuinely moving finishes inside the budget.
        clock = 0
        accepted = 0
        try? StreamIO.writeAll(Data(repeating: 0, count: 50), progressTimeout: 10, maxDuration: StreamIO.writeBudget(bytes: 50),
                               now: { clock }, waitForWrite: { deadline in
            clock += 9.9
            guard clock < deadline else { throw POSIXError(.ETIMEDOUT) }
        }, writeChunk: { _, _ in accepted += 1; return 1 })
        #expect(accepted == 50)
    }

    @Test func unlimitedWritesHaveNoClientOutputDeadline() throws {
        var clock: TimeInterval = 0, accepted = 0
        try StreamIO.writeAll(Data([1, 2]), now: { clock }, waitForWrite: { deadline in
            clock += 60
            #expect(deadline == .infinity)
        }, writeChunk: { _, _ in accepted += 1; return 1 })
        #expect(clock == 120 && accepted == 2)
    }

    @Test func queuedBytesIncludeTheWriteBlockedOnThePeer() async throws {
        let fds = try transportPair()
        defer { close(fds[0]); close(fds[1]) }
        try StreamIO.configure(fds[0])
        var size: Int32 = 1024
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let budget = 1024 * 1024
        let writer = StreamWriter(fd: fds[0], maxBytes: budget)
        #expect(writer.send(Data(repeating: 0x41, count: budget)))
        #expect(!writer.send(Data([1])))
        await writer.finish()
    }

    @Test func writerMakesProgressAcrossPartialWrites() async throws {
        let fds = try transportPair()
        defer { close(fds[0]); close(fds[1]) }
        try StreamIO.configure(fds[0])
        var size: Int32 = 1024
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let data = Data(repeating: 0x41, count: 512 * 1024)
        async let received: Data = transportThread {
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while result.count < data.count {
                let n = read(fds[1], &buffer, buffer.count)
                guard n > 0 else { throw POSIXError(.EIO) }
                result.append(contentsOf: buffer[0..<n])
            }
            return result
        }
        try await transportThread { try StreamIO.writeAll(fds[0], data, deadline: StreamIO.now + 30) }
        #expect(try await received == data)
    }

    @Test func stalledWriterTimesOutAndTheBarrierReturns() async throws {
        let fds = try transportPair()
        defer { close(fds[0]); close(fds[1]) }
        try StreamIO.configure(fds[0])
        var size: Int32 = 1024
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let writer = StreamWriter(fd: fds[0], timeout: 0.05)
        #expect(writer.send(Data(repeating: 1, count: 1024 * 1024)))
        let ended = try await transportThread {
            var p = pollfd(fd: fds[0], events: Int16(POLLHUP), revents: 0)
            return poll(&p, 1, 30_000) > 0
        }
        #expect(ended)
        await writer.finish()
        #expect(!writer.send(Data([1])))
    }

    @Test func agentClientInitializesListsAndCallsOverATemporarySocket() async throws {
        let fds = try transportPair()
        async let server: Bool = transportThread {
            defer { close(fds[1]) }
            try StreamIO.configure(fds[1])
            var lines = LineBuffer(), buffer = [UInt8](repeating: 0, count: 4096)
            let deadline = StreamIO.now + 30
            while true {
                try StreamIO.wait(fds[1], events: Int16(POLLIN), deadline: deadline)
                let n = read(fds[1], &buffer, buffer.count)
                guard n > 0 else { throw POSIXError(.EIO) }
                for line in lines.append(buffer[0..<n]) {
                    let message = try JSONSerialization.jsonObject(with: line) as! [String: Any]
                    guard let id = message["id"] as? Int else { continue }
                    let result: [String: Any]
                    switch id {
                    case 1: result = ["protocolVersion": "2025-11-25"]
                    case 2: result = ["tools": [["name": "echo"]]]
                    default: result = ["content": [["type": "text", "text": "hello"]], "isError": false]
                    }
                    let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
                    try StreamIO.writeAll(fds[1], data + [0x0A], deadline: deadline)
                    if id == 3 { return true }
                }
            }
        }
        let text = try await transportThread {
            let client = try AgentClient(clientName: "test", version: "1", input: fds[0], output: fds[0], timeout: 30)
            guard try client.listTools() == ["echo"] else { throw POSIXError(.EIO) }
            return try client.call("echo").text
        }
        #expect(text == "hello")
        #expect(try await server)
    }

    @Test func agentClientRejectsInvalidTimeoutsBeforeConnecting() {
        for timeout in [0, -1, Double.infinity, Double.nan, Double(Int32.max)] {
            #expect(throws: SocketError.self) {
                try AgentClient(clientName: "test", version: "1", path: "/unused", timeout: timeout)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func agentClientSendingHasAnOverallDeadlineAndSuppressesSIGPIPE() async throws {
        let fds = try transportPair()
        defer { close(fds[1]) }
        var size: Int32 = 1024
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let started = StreamIO.now
        let failed = try await transportThread {
            do {
                _ = try AgentClient(clientName: String(repeating: "x", count: 1024 * 1024), version: "1",
                                    input: fds[0], output: fds[0], timeout: 0.1)
                return false
            } catch { return true }   // throwing initialization also runs deinit and closes the owned descriptor
        }
        #expect(failed && StreamIO.now - started < 30)   // a deadline that never fired would hang, not run long
        let broken = try transportPair()
        close(broken[1])
        let refused = try await transportThread {
            do { _ = try AgentClient(clientName: "test", version: "1", input: broken[0], output: broken[0], timeout: 0.1); return false }
            catch { return true }   // AgentClient already closed broken[0]
        }
        #expect(refused)
    }

    @Test func failedInitializeClosesItsOwnedDescriptor() async throws {
        let fds = try transportPair()
        defer { close(fds[1]) }
        // EOF on initialize makes construction throw; the other direction remains open to observe its cleanup.
        shutdown(fds[1], SHUT_WR)
        let closed = try await transportThread {
            do {
                _ = try AgentClient(clientName: "test", version: "1", input: fds[0], output: fds[0], timeout: 30)
                return false
            } catch {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    try StreamIO.wait(fds[1], events: Int16(POLLIN), deadline: StreamIO.now + 30)
                    let n = read(fds[1], &buffer, buffer.count)
                    if n == 0 { return true }
                    guard n > 0 else { throw POSIXError(.EIO) }
                }
            }
        }
        #expect(closed)
    }

    @Test(.timeLimit(.minutes(1))) func trickledInitializeCannotExtendTheReceiveDeadline() async throws {
        let fds = try transportPair()
        try StreamIO.configure(fds[1])
        defer { close(fds[1]) }
        // Keep delivering incomplete JSON beyond the client's total budget. The peer uses SO_NOSIGPIPE too.
        let writer = StreamWriter(fd: fds[1])
        let drip = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        drip.schedule(deadline: .now(), repeating: .milliseconds(20))
        drip.setEventHandler { writer.send(Data([0x20])) }
        drip.resume()

        let started = StreamIO.now
        let failed = try await transportThread {
            do { _ = try AgentClient(clientName: "test", version: "1", input: fds[0], output: fds[0], timeout: 0.1); return false }
            catch { return true }
        }
        drip.cancel()
        await writer.finish()
        #expect(failed && StreamIO.now - started < 30)   // a deadline that never fired would hang, not run long
    }
}

@Suite struct RelayProtocolRegressionTests {
    private let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8)
    private let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test"}}"#.utf8)
    private func handshaken() -> RelaySession {
        var relay = RelaySession()
        _ = relay.fromClient(initialize)
        _ = relay.fromAgent(Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        return relay
    }

    @Test func clientDirectivesNeverReachTheAgentInAnyPhase() {
        var relay = handshaken()
        let spoof = Data("#mac-mcp session=victim origin=local lease=stolen".utf8)
        #expect(relay.fromClient(spoof).toAgent.isEmpty)
        _ = relay.agentLost(now: 100)
        #expect(relay.fromClient(spoof).toAgent.isEmpty && relay.held.isEmpty)
        _ = relay.agentReconnected()
        #expect(relay.fromClient(spoof).toAgent.isEmpty && relay.held.isEmpty)
    }

    @Test func reconnectDeadlineIncludesAnAcceptedButSilentAgent() {
        var relay = handshaken()
        _ = relay.agentLost(now: 100)
        _ = relay.fromClient(call)
        _ = relay.agentReconnected()
        #expect(relay.phase == .replaying)
        #expect(relay.expire(now: 114.999).toClient.isEmpty)
        let expired = relay.expire(now: 115)
        #expect(expired.toClient.count == 1)
        #expect(relay.failure?.contains("complete initialize") == true)
        #expect(relay.held.isEmpty)
    }

    @Test func failedOrChangedReplayIsReportedAndHeldCallsNeverRun() throws {
        for response in [#""error":{"code":-32602,"message":"bad"}"#, #""result":{"protocolVersion":"2025-06-18"}"#, #""result":{}"#] {
            var relay = handshaken()
            _ = relay.agentLost(now: 100)
            _ = relay.fromClient(call)
            let replay = try #require(relay.agentReconnected().toAgent.first)
            let object = try #require(JSONSerialization.jsonObject(with: replay) as? [String: Any])
            let id = try #require(object["id"] as? String)
            let result = relay.fromAgent(Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\(response)}".utf8))
            #expect(result.toAgent.isEmpty && result.toClient.count == 1)
            #expect(relay.failure?.contains("incompatible protocol") == true)
        }
    }

    @Test func repeatedFailedConnectionsDoNotResetTheDeadline() {
        var relay = handshaken()
        _ = relay.agentLost(now: 100)
        _ = relay.agentReconnected()
        _ = relay.agentLost(now: 110)
        #expect(relay.reconnectDeadline == 115)
        _ = relay.expire(now: 116)
        #expect(relay.failure != nil)
    }

    @Test func relayBoundsHeldBytesAndOutstandingRequests() {
        var relay = RelaySession(maxQueuedBytes: call.count, maxRequests: 1)
        _ = relay.agentLost(now: 100)
        #expect(relay.fromClient(call).toClient.isEmpty)
        #expect(relay.fromClient(call).toClient.count == 1)
        #expect(relay.held.count == 1)
        _ = relay.agentReconnected()
        #expect(relay.fromClient(call).toClient.count == 1)
        #expect(relay.inFlight.count == 1)
    }

    @Test func batchRequestsRemainTrackedAndRestartErrorsAreABatch() throws {
        var relay = RelaySession()
        let batch = Data("[\(String(decoding: call, as: UTF8.self)),{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}]".utf8)
        #expect(relay.fromClient(batch).toAgent == [batch])
        #expect(relay.inFlight == ["2", "3"])
        let lost = relay.agentLost(now: 100)
        #expect(lost.toClient.count == 1)
        let errors = try #require(JSONSerialization.jsonObject(with: lost.toClient[0]) as? [[String: Any]])
        #expect(errors.count == 2)
    }
}
