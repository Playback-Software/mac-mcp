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
        // The work never resumes, so getting any answer at all means the deadline gave control back without it.
        let r: Int? = try await Deadline.run(0.3) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        }
        #expect(r == nil)
    }

    @Test func abandonedWorkIsCancelled() async throws {
        let (finished, sink) = AsyncStream.makeStream(of: String.self)
        let r: Int? = try await Deadline.run(0.2) {
            // Only cancellation ends this sleep early, so what it saw afterwards is what the deadline did to it.
            try? await Task.sleep(for: .seconds(30))
            sink.yield(Task.isCancelled ? "cancelled" : "not cancelled")
            return 1
        }
        #expect(r == nil)
        var seen: [String] = []
        for await outcome in finished { seen.append(outcome); break }
        #expect(seen == ["cancelled"])
    }

    @Test func errorsPropagate() async {
        await #expect(throws: ActionError.self) { try await Deadline.run(5) { () async throws -> Int in throw ActionError("boom") } }
    }

    @Test func callerCancellationEndsTheWait() async throws {
        let running = Signal()
        let task = Task { try await Deadline.run(60) { () async -> Int in
            running.fire()
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        } }
        await running.wait()
        let start = ContinuousClock.now
        task.cancel()
        // The deadline is 60 s, so a cancellation error (not nil) is the wait ending because of the caller.
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(30))
    }
}

@Suite struct ActionLockTests {
    @Test func runsOneAtATimeInArrivalOrder() async throws {
        let lock = ActionLock(), probe = Probe(), release = Signal()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try await lock.run("t\(i)") {
                        if i == 0 { await release.wait() }   // holds the lock until the others are queued
                        probe.add("start \(i)")
                        await Task.yield()
                        probe.add("end \(i)")
                    }
                }
                // Fix the arrival order: the first holds the lock, each later one is queued before the next is added.
                await waitUntil("t\(i) to hold or queue for the lock") {
                    let status = await lock.status
                    return status.holder != nil && status.waiting == i
                }
            }
            release.fire()
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
        await waitUntil("the wedged call to take the lock") { await lock.status.holder == "wedged" }
        // Had the lock stayed with the wedged holder, this would give up after its default 30 s wait and throw.
        try await lock.run("next", deadline: 5) { probe.add("next ran") }
        await #expect(throws: DeadlineExceeded.self) { try await wedged.value }
        #expect(probe.all == ["next ran"])
        let status = await lock.status
        #expect(status.holder == nil && status.abandoned == 1)
    }

    @Test func waitingIsBoundedAndTheCallDoesNotRun() async throws {
        let lock = ActionLock(), probe = Probe()
        // Holds far longer than the wait, until cancelled: the click can only get out by giving up.
        let holder = Task { try await lock.run("mac_type", deadline: 120) { try await Task.sleep(for: .seconds(60)) } }
        await waitUntil("mac_type to take the lock") { await lock.status.holder == "mac_type" }
        let start = ContinuousClock.now
        await #expect(throws: ActionLockBusy.self) {
            try await lock.run("mac_click", maxWait: 0.2) { probe.add("click ran") }
        }
        #expect(start.duration(to: .now) < .seconds(30))
        #expect(await lock.status.waiting == 0)
        holder.cancel()
        _ = try? await holder.value
        #expect(probe.all.isEmpty)
        // The lock is free again for the next caller.
        try await lock.run("mac_key") { probe.add("key ran") }
        #expect(probe.all == ["key ran"])
    }

    @Test func callsGivenUpWhileQueuedDoNotRunLate() async throws {
        let lock = ActionLock(), probe = Probe()
        let release = Signal()
        let holder = Task { try await lock.run("holder") { await release.wait() } }
        await waitUntil("the holder to take the lock") { await lock.status.holder == "holder" }
        let queued = Task { try await lock.run("queued") { probe.add("queued ran") } }
        await waitUntil("the call to queue behind it") { await lock.status.waiting == 1 }
        queued.cancel()
        release.fire()
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
