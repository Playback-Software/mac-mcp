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
        let start = ContinuousClock.now
        let r = try await Scripts.run("delay 20", language: .applescript, timeout: 1)
        #expect(r.timedOut)
        #expect(start.duration(to: .now) < .seconds(15), "the child was stopped, not waited out")
    }

    @Test func childIgnoringSigtermIsKilled() async throws {
        let start = ContinuousClock.now
        let r = try await Subprocess.run("/bin/sh", ["-c", "trap '' TERM; sleep 20"], timeout: 1)
        #expect(r.timedOut && r.status != 0)
        #expect(start.duration(to: .now) < .seconds(15), "the child was killed, not waited out")
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
        // A session name launchd reported, or "unknown" when it couldn't be asked; never empty or padded.
        let session = launchdSessionType()
        #expect(!session.isEmpty && session == session.trimmingCharacters(in: .whitespacesAndNewlines), "\(session)")
        let r = try Subprocess.runBlocking("/bin/echo", ["hi"], timeout: 5)
        #expect(r.stdout == "hi" && r.status == 0)
    }

    @Test func largeStdinAndBothOutputPipesAreDrained() async throws {
        let input = Data(repeating: 120, count: 1_000_000)
        let r = try await Subprocess.run("/bin/sh", ["-c", "cat; head -c 300000 /dev/zero >&2"], input: input, timeout: 5)
        #expect(!r.timedOut && r.status == 0)
        #expect(r.stdout == String(decoding: input, as: UTF8.self))
        #expect(r.stderr.utf8.count == 300_000)
    }

    @Test func earlyExitWhileWritingStdinDoesNotRaiseSigpipe() async throws {
        let r = try await Subprocess.run("/bin/echo", ["done"], input: Data(repeating: 120, count: 1_000_000), timeout: 5)
        #expect(r.stdout == "done" && r.status == 0 && !r.timedOut)
    }

    @Test func missingExecutableThrows() async {
        for _ in 0..<20 {
            await #expect(throws: (any Error).self) {
                try await Subprocess.run("/does/not/exist", [], timeout: 1)
            }
        }
    }

    @Test func cancellationStopsAndReapsChild() async throws {
        let task = Task { try await Subprocess.run("/bin/sleep", ["20"], timeout: 30) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        let r = try await task.value
        #expect(r.status != 0 && !r.timedOut)
        #expect(start.duration(to: .now) < .seconds(4))
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test(.timeLimit(.minutes(1))) func runawayStdoutIsCappedAndStopped() async throws {
        let start = ContinuousClock.now
        let r = try await Subprocess.run("/usr/bin/yes", [], timeout: 30, outputLimit: 1 << 20)
        #expect(r.truncated && !r.timedOut && r.status != 0)
        #expect((1 << 20) - 2...(1 << 20) ~= r.stdout.utf8.count)
        #expect(r.stderr.contains("stdout exceeded 1 MiB"))
        #expect(start.duration(to: .now) < .seconds(10), "the child was stopped, not waited out")
    }

    @Test(.timeLimit(.minutes(1))) func runawayStderrIsCappedToo() async throws {
        let r = try await Subprocess.run("/bin/sh", ["-c", "echo ok; exec yes >&2"], timeout: 30, outputLimit: 1 << 20)
        #expect(r.truncated && r.stdout == "ok")
        #expect(r.stderr.hasSuffix("stderr exceeded 1 MiB; the process was stopped and its output is cut off]"))
        #expect(r.stderr.utf8.count < (1 << 20) + 200)
    }

    @Test func outputAtExactlyTheLimitIsNotTruncated() async throws {
        let r = try await Subprocess.run("/bin/sh", ["-c", "head -c 4096 /dev/zero | tr '\\0' x"], timeout: 10, outputLimit: 4096)
        #expect(!r.truncated && r.status == 0 && r.stdout.utf8.count == 4096 && r.stderr.isEmpty)
        #expect(Subprocess.outputLimit == 16 * 1024 * 1024)
    }

    @Test func truncatedOutputNeverLooksLikeASuccess() async throws {
        // The child may finish before the reactor stops it; the result still can't read as complete.
        let r = try await Subprocess.run("/bin/sh", ["-c", "head -c 3000 /dev/zero | tr '\\0' x"], timeout: 10, outputLimit: 1000)
        #expect(r.truncated && r.status != 0 && r.stdout.utf8.count == 1000 && !r.stderr.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func timeoutKillsGrandchildrenToo() async throws {
        let r = try await Subprocess.run("/bin/sh", ["-c", "sleep 60 & echo $!; wait"], timeout: 1)
        #expect(r.timedOut)
        let grandchild = try #require(pid_t(r.stdout))
        for _ in 0..<300 where alive(grandchild) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!alive(grandchild), "the whole process group was signalled")
    }

    @Test(.timeLimit(.minutes(1))) func outputCapKillsDescendantsAfterTheirParentHasExited() async throws {
        // Reap the short-lived leader before draining its buffered output, reproducing this ordering deterministically.
        let r = try await Subprocess.run("/bin/sh", ["-c", "sleep 60 & echo $!; head -c 3000 /dev/zero | tr '\\0' x"],
                                         timeout: 10, outputLimit: 1000, reap: { pid, raw in waitpid(pid, raw, 0) })
        let grandchild = try #require(r.stdout.split(separator: "\n").first.flatMap { pid_t($0) })
        defer { if alive(grandchild) { kill(grandchild, SIGKILL) } }
        #expect(r.truncated && r.status != 0)
        for _ in 0..<300 where alive(grandchild) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!alive(grandchild), "output truncation cleans up descendants even when the leader was already reaped")
    }

    @Test(.timeLimit(.minutes(1))) func cancellationKillsGrandchildrenToo() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("mac-mcp-grandchild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task { try await Subprocess.run("/bin/sh", ["-c", "sleep 60 & echo $! > \(pidFile.path); wait"], timeout: 30) }
        var grandchild: pid_t?
        for _ in 0..<300 where grandchild == nil {
            try await Task.sleep(for: .milliseconds(10))
            grandchild = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let pid = try #require(grandchild)
        task.cancel()
        _ = try await task.value
        for _ in 0..<300 where alive(pid) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!alive(pid))
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }

    /// `waitpid` fails with ECHILD when something else already reaped the child (a SIGCHLD handler, a stray wait).
    @Test(.timeLimit(.minutes(1))) func aChildReapedBySomeoneElseCountsAsExited() async throws {
        let once = Once()
        let start = ContinuousClock.now
        let r = try await Subprocess.run("/bin/sleep", ["30"], timeout: 60, reap: { pid, _ in
            if once.first() { kill(pid, SIGKILL); var raw: Int32 = 0; waitpid(pid, &raw, 0) }
            errno = ECHILD
            return -1
        })
        #expect(r.status == -1 && !r.timedOut)
        #expect(start.duration(to: .now) < .seconds(10), "the call returned instead of waiting out its timeout")
    }

    @Test func aCallCancelledBeforeItSpawnsNeverSpawns() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("mac-mcp-spawned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate {}
            return try await Subprocess.run("/usr/bin/touch", [marker.path], timeout: 5)
        }
        task.cancel()
        open.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
