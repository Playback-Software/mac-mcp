import Foundation
import Testing
@testable import MacMCPCore

/// Thread-safe flags and counters for observing abandoned work.
final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ v: String) { lock.withLock { values.append(v) } }
    var all: [String] { lock.withLock { values } }
}

@Suite struct DeadlineTests {
    @Test func fastWorkReturnsItsValue() async throws {
        #expect(try await Deadline.run(5) { 42 } == 42)
    }

    /// The case a task group gets wrong: work stuck in an await that ignores cancellation (an NSWorkspace
    /// completion that never fires). The caller must still get control back on time.
    @Test func stuckUncancellableWorkIsAbandonedOnTime() async throws {
        let start = Date()
        let r: Int? = try await Deadline.run(0.3) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never resumes
            return 1
        }
        #expect(r == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func abandonedWorkIsCancelled() async throws {
        let probe = Probe()
        let r: Int? = try await Deadline.run(0.2) {
            try? await Task.sleep(for: .seconds(1))
            probe.add(Task.isCancelled ? "cancelled" : "not cancelled")
            return 1
        }
        #expect(r == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe.all == ["cancelled"])
    }

    @Test func errorsPropagate() async {
        await #expect(throws: ActionError.self) { try await Deadline.run(5) { () async throws -> Int in throw ActionError("boom") } }
    }

    @Test func callerCancellationEndsTheWait() async throws {
        let task = Task { try await Deadline.run(10) { () async -> Int in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let start = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

@Suite struct ActionLockTests {
    @Test func runsOneAtATimeInArrivalOrder() async throws {
        let lock = ActionLock(), probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try await lock.run("t\(i)") {
                        probe.add("start \(i)")
                        try await Task.sleep(for: .milliseconds(20))
                        probe.add("end \(i)")
                    }
                }
                try await Task.sleep(for: .milliseconds(5))   // fix the arrival order
            }
            try await group.waitForAll()
        }
        #expect(probe.all == (0..<5).flatMap { ["start \($0)", "end \($0)"] })
    }

    /// A wedged holder must not freeze everyone behind it, and its late release must not free someone else's hold.
    @Test func wedgedHolderIsAbandonedAndTheLockMovesOn() async throws {
        let lock = ActionLock(), probe = Probe()
        let wedged = Task {
            try await lock.run("wedged", deadline: 0.3) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        try await lock.run("next", deadline: 5) { probe.add("next ran") }
        #expect(Date().timeIntervalSince(start) < 2)
        await #expect(throws: DeadlineExceeded.self) { try await wedged.value }
        #expect(probe.all == ["next ran"])
        let status = await lock.status
        #expect(status.holder == nil && status.abandoned == 1)
    }

    @Test func waitingIsBoundedAndTheCallDoesNotRun() async throws {
        let lock = ActionLock(), probe = Probe()
        let holder = Task { try await lock.run("mac_type") { try await Task.sleep(for: .milliseconds(800)) } }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        await #expect(throws: ActionLockBusy.self) {
            try await lock.run("mac_click", maxWait: 0.2) { probe.add("click ran") }
        }
        #expect(Date().timeIntervalSince(start) < 0.6)
        #expect(await lock.status.waiting == 0)
        _ = try await holder.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.all.isEmpty)
        // The lock is free again for the next caller.
        try await lock.run("mac_key") { probe.add("key ran") }
        #expect(probe.all == ["key ran"])
    }

    @Test func callsGivenUpWhileQueuedDoNotRunLate() async throws {
        let lock = ActionLock(), probe = Probe()
        let holder = Task { try await lock.run("holder") { try await Task.sleep(for: .milliseconds(300)) } }
        try await Task.sleep(for: .milliseconds(50))
        let queued = Task { try await lock.run("queued") { probe.add("queued ran") } }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        _ = try await holder.value
        _ = try? await queued.value
        #expect(probe.all.isEmpty)
    }
}

@Suite struct LeaseTests {
    func tempPath() -> String { NSTemporaryDirectory() + "lease-\(UUID().uuidString).json" }

    @Test func acquireReleaseAndRefuseOthers() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".lock") }
        #expect(LeaseStore.current(path: path) == nil)
        let lease = try LeaseStore.acquire(holder: "eval", reason: "M6 test", minutes: 5, pid: getpid(), path: path)
        #expect(LeaseStore.current(path: path) == lease)
        #expect(throws: LeaseError.self) { try LeaseStore.acquire(holder: "other", reason: "x", minutes: 5, pid: getpid(), path: path) }
        #expect(LeaseStore.refusal(token: lease.token, path: path) == nil)
        #expect(LeaseStore.refusal(token: nil, path: path)?.contains("leased by eval (M6 test)") == true)
        #expect(LeaseStore.refusal(token: "wrong", path: path) != nil)
        #expect(!LeaseStore.release(token: "wrong", path: path))
        #expect(LeaseStore.release(token: lease.token, path: path))
        #expect(LeaseStore.refusal(token: nil, path: path) == nil)
    }

    @Test func expiredAndOrphanedLeasesLapse() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".lock") }
        _ = try LeaseStore.acquire(holder: "short", reason: "x", minutes: -1, pid: getpid(), path: path)
        #expect(LeaseStore.current(path: path) == nil)
        // A pid that no longer exists: the harness crashed.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        while gone.isRunning { usleep(10_000) }
        _ = try LeaseStore.acquire(holder: "crashed", reason: "x", minutes: 60, pid: gone.processIdentifier, path: path)
        #expect(LeaseStore.current(path: path) == nil)
    }
}

@Suite struct WatchdogTests {
    let limits = Watchdog.Limits()

    @Test func healthyAgentIsLeftAlone() {
        #expect(Watchdog.stall(now: 1000, lastMain: 995, lastPool: 996, lockHeldFor: 10, lockHolder: "mac_click", limits: limits) == nil)
    }

    @Test func eachKindOfStallIsNamed() {
        #expect(Watchdog.stall(now: 1000, lastMain: 900, lastPool: 999, lockHeldFor: nil, lockHolder: nil, limits: limits)?
            .hasPrefix("main thread") == true)
        #expect(Watchdog.stall(now: 1000, lastMain: 999, lastPool: 900, lockHeldFor: nil, lockHolder: nil, limits: limits)?
            .hasPrefix("task pool") == true)
        #expect(Watchdog.stall(now: 1000, lastMain: 999, lastPool: 999, lockHeldFor: 400, lockHolder: "mac_type", limits: limits)?
            .contains("mac_type") == true)
    }
}
