import Foundation
import Testing
@testable import MacMCPCore

@Suite struct ThreadStarvationTests {
    @Test(.timeLimit(.minutes(1))) func globalWorkersCannotStarveProcessesOrGuards() async throws {
        // Deliberate global-pool exhaustion must be isolated from other tests' timing and GCD-based fixtures.
        if ProcessInfo.processInfo.environment["MAC_MCP_STARVATION_CHILD"] != "1" {
            let index = try #require(CommandLine.arguments.firstIndex(of: "--test-bundle-path"))
            let bundle = CommandLine.arguments[index + 1]
            // env is SIP-protected and drops inherited DYLD settings; explicitly forward the test runner's paths.
            let loader = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("DYLD_") }.map { "\($0.key)=\($0.value)" }
            let result = try await Subprocess.run("/usr/bin/env", loader + [
                "MAC_MCP_STARVATION_CHILD=1", CommandLine.arguments[0], "--test-bundle-path", bundle,
                "--filter", "ThreadStarvationTests/globalWorkersCannotStarveProcessesOrGuards", bundle,
                "--testing-library", "swift-testing",
            ], timeout: 30)
            #expect(result.status == 0 && !result.timedOut, "\(result.stdout)\n\(result.stderr)")
            return
        }
        let pressure = GlobalPressure()
        defer { pressure.release() }
        // Give the global queues time to fill before posting any of the probes. A native watchdog releases them
        // after eight seconds so the regression also terminates against the old implementation.
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        async let process: Void = checkAsyncProcess()
        async let blocking: Void = checkBlockingProcess()
        async let guardRead: Void = checkGuard()
        try await process
        try await blocking
        try await guardRead
        #expect(start.duration(to: .now) < .seconds(2), "completion must not wait for the global queues to unblock")
    }

    private func checkAsyncProcess() async throws {
        let start = ContinuousClock.now
        let output = try await Subprocess.run("/bin/echo", ["async"], timeout: 1)
        #expect(output.stdout == "async" && output.status == 0 && !output.timedOut)
        #expect(start.duration(to: .now) < .seconds(2))
    }

    private func checkBlockingProcess() async throws {
        let start = ContinuousClock.now
        let output = try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(with: Result { try Subprocess.runBlocking("/bin/echo", ["sync"], timeout: 1) })
            }.start()
        }
        #expect(output.stdout == "sync" && output.status == 0 && !output.timedOut)
        #expect(start.duration(to: .now) < .seconds(2))
    }

    private func checkGuard() async throws {
        let start = ContinuousClock.now
        let value = try await Untrusted.scope(token: "starvation42") {
            try await Input.guardWork { Untrusted.inline("checked") }
        }
        #expect(value == "<<untrusted starvation42>>checked<<end starvation42>>")
        #expect(start.duration(to: .now) < .seconds(1))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let timeoutStart = ContinuousClock.now
        await #expect(throws: ActionError.self) {
            try await Input.guardWork(timeout: 0.05) { gate.wait(); return 0 }
        }
        #expect(timeoutStart.duration(to: .now) < .seconds(1), "the guard timeout also needs an independent thread")
    }

    private final class GlobalPressure: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let condition = NSCondition()
        private var released = false
        private let count = 240

        init() {
            for qos in [DispatchQoS.QoSClass.userInitiated, .default, .utility] {
                for _ in 0..<80 {
                    DispatchQueue.global(qos: qos).async { [gate] in gate.wait() }
                }
            }
            Thread { [self] in
                condition.lock()
                let deadline = Date().addingTimeInterval(8)
                while !released && condition.wait(until: deadline) {}
                condition.unlock()
                release()
            }.start()
        }

        func release() {
            condition.lock()
            let first = !released
            released = true
            condition.broadcast()
            condition.unlock()
            if first { for _ in 0..<count { gate.signal() } }
        }
    }
}
