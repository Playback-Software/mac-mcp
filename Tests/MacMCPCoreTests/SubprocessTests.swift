import Foundation
import Testing
@testable import MacMCPCore

@Suite struct SubprocessTests {
    /// The M5 hang: back-to-back scripts from async code; `waitUntilExit()` could block forever after one of them.
    @Test(.timeLimit(.minutes(1))) func manyScriptsFromAsyncCodeAllReturn() async throws {
        for i in 0..<40 {
            let r = try await Scripts.run("return \(i)", language: .applescript, timeout: 10)
            #expect(r.stdout == "\(i)" && r.status == 0 && !r.timedOut)
        }
    }

    @Test func timeoutStopsTheChild() async throws {
        let start = Date()
        let r = try await Scripts.run("delay 20", language: .applescript, timeout: 1)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func childIgnoringSigtermIsKilled() async throws {
        let start = Date()
        let r = try await Subprocess.run("/bin/sh", ["-c", "trap '' TERM; sleep 20"], timeout: 1)
        #expect(r.timedOut && r.status != 0)
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test func largeOutputDoesNotStallThePipe() async throws {
        let r = try await Scripts.run(#"'x'.repeat(300000)"#, language: .jxa, timeout: 20)
        #expect(!r.timedOut && r.stdout.count == 300_000)
    }

    @Test func errorsComeBackOnStderr() async throws {
        let r = try await Scripts.run("error \"boom\"", language: .applescript, timeout: 10)
        #expect(r.status != 0 && r.stderr.contains("boom"))
    }

    @Test func blockingVariantWorksForSyncCallers() throws {
        #expect(["Aqua", "Background", "unknown"].contains(launchdSessionType()) || !launchdSessionType().isEmpty)
        let r = try Subprocess.runBlocking("/bin/echo", ["hi"], timeout: 5)
        #expect(r.stdout == "hi" && r.status == 0)
    }
}
