import Foundation
import Testing
@testable import MacMCPCore

private actor AdmissionGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; let all = waiting; waiting = []; all.forEach { $0.resume() } }
}

@Suite struct AdmissionRegressionTests {
    private func path() -> String { NSTemporaryDirectory() + "admission-\(UUID())/lease.json" }
    private func remove(_ path: String) { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

    @Test func aDuplicatedDescriptorCannotKeepAFinishedAdmissionLocked() async throws {
        let path = path()
        defer { remove(path) }
        let admission = try await LeaseStore.admit(path: path)
        var target = stat()
        #expect(stat(path + ".admission", &target) == 0)
        var duplicate: Int32 = -1
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            guard let fd = Int32(name) else { continue }
            var info = stat()
            if fstat(fd, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino {
                duplicate = dup(fd)
                break
            }
        }
        #expect(duplicate >= 0)
        defer { if duplicate >= 0 { close(duplicate) } }
        admission.release()
        // Like a child between spawn and exec, the duplicate is still open when the owner releases its guard.
        _ = try LeaseStore.acquire(holder: "next", reason: "released duplicate", minutes: 5, pid: 0, path: path)
    }

    @Test func releasedLeaseTokenMustClaimAgain() async throws {
        let path = path()
        defer { remove(path) }
        let claims = Claims(maxWait: 0)
        let lease = try LeaseStore.acquire(holder: "eval", reason: "test", minutes: 5, pid: 0, path: path)
        _ = await claims.tryBegin("gui", session: "a", client: "a", origin: nil)
        let admission = try await claims.admit("gui", session: "b", client: "b", origin: nil, token: lease.token, leasePath: path)
        #expect(LeaseStore.release(token: lease.token, path: path))
        await #expect(throws: ActionError.self) { try await claims.recheck(admission) }
        await claims.finish(admission)
        #expect(await claims.holder("gui")?.session == "a")
        await #expect(throws: ActionError.self) {
            try await claims.admit("gui", session: "b", client: "b", origin: nil, token: lease.token, leasePath: path)
        }
    }

    @Test func leaseAcquiredWhileClaimantWaitsIsRechecked() async throws {
        let path = path()
        defer { remove(path) }
        let claims = Claims(maxWait: 30, pause: {
            _ = try LeaseStore.acquire(holder: "new lease", reason: "during wait", minutes: 5, pid: 0, path: path)
        })
        _ = await claims.tryBegin("gui", session: "a", client: "a", origin: nil)
        do {
            _ = try await claims.admit("gui", session: "b", client: "b", origin: nil, token: nil, leasePath: path)
            Issue.record("a foreign lease was ignored")
        } catch { #expect(String(describing: error).contains("new lease")) }
        #expect(await claims.holder("gui")?.session == "a")
    }

    @Test func leaseCanBeAcquiredDuringAnActionAndIsSeenByTheNextRecheck() async throws {
        let path = path()
        defer { remove(path) }
        let claims = Claims(maxWait: 0), started = AdmissionGate(), proceed = AdmissionGate()
        let admission = try await claims.admit("gui", session: "a", client: "a", origin: nil, token: nil, leasePath: path)
        let actionLock = ActionLock()
        let running = Task {
            try await actionLock.run("running", deadline: 305) {
                await started.open()
                await proceed.wait()
                return true
            }
        }
        await started.wait()
        let lease = try LeaseStore.acquire(holder: "eval", reason: "during action", minutes: 5, pid: 0, path: path)
        #expect(lease.holder == "eval")
        await #expect(throws: ActionError.self) { try await claims.recheck(admission) }
        await proceed.open()
        #expect(try await running.value)
        await claims.finish(admission)
    }

    @Test func leaseAcquiredWhileWaitingForActionLockPreventsExecution() async throws {
        let path = path()
        defer { remove(path) }
        let claims = Claims(maxWait: 0), actionLock = ActionLock(), started = AdmissionGate(), proceed = AdmissionGate()
        let admission = try await claims.admit("gui", session: "a", client: "a", origin: nil, token: nil, leasePath: path)
        let first = Task { try await actionLock.run("first", deadline: 5) { await started.open(); await proceed.wait(); return true } }
        await started.wait()
        let queued = AdmissionGate()
        let second = Task {
            try await ActionAdmission.$check.withValue({ try await claims.recheck(admission) }) {
                await queued.open()
                return try await actionLock.run("queued", deadline: 5) { Issue.record("foreign lease ignored"); return false }
            }
        }
        await queued.wait()
        _ = try LeaseStore.acquire(holder: "eval", reason: "before lock opens", minutes: 5, pid: 0, path: path)
        await proceed.open()
        #expect(try await first.value)
        await #expect(throws: ActionError.self) { try await second.value }
        await claims.finish(admission)
    }

    @Test func leaseAcquisitionRetriesOnlyContentionAndUsesABoundedClock() async throws {
        let path = path()
        defer { remove(path) }
        let admission = try await LeaseStore.admit(path: path)
        var clock: TimeInterval = 0, pauses = 0
        let lease = try LeaseStore.retryAcquisition(timeout: 60, now: { clock }, pause: { interval in
            clock += interval
            pauses += 1
            admission.release()
        }) { try LeaseStore.acquire(holder: "eval", reason: "retry", minutes: 5, pid: 0, path: path) }
        #expect(lease.holder == "eval" && pauses == 1 && clock == 0.25)
        clock = 0; pauses = 0
        #expect(throws: LeaseError.self) {
            try LeaseStore.retryAcquisition(timeout: 1, now: { clock }, pause: { clock += $0; pauses += 1 }) {
                try LeaseStore.acquire(holder: "other", reason: "bounded", minutes: 5, pid: 0, path: path)
            }
        }
        #expect(clock == 1 && pauses == 4)
        pauses = 0
        #expect(throws: LeaseError.self) {
            try LeaseStore.retryAcquisition(timeout: 60, now: { clock }, pause: { _ in pauses += 1 }) { throw LeaseError.io("broken") }
        }
        #expect(pauses == 0)
    }

    @Test func finishedAdmissionDoesNotPinTheLeaseThroughAnAbandonedContext() async throws {
        let path = path()
        defer { remove(path) }
        let claims = Claims(maxWait: 0)
        let admission = try await claims.admit("gui", session: "a", client: "a", origin: nil, token: nil, leasePath: path)
        await claims.finish(admission)
        _ = try LeaseStore.acquire(holder: "next", reason: "finished call", minutes: 5, pid: 0, path: path)
        await #expect(throws: CancellationError.self) { try await claims.recheck(admission) }
    }

    @Test func cancellationNeverTakesAClaim() async throws {
        let path = path()
        defer { remove(path) }
        let claims = Claims(maxWait: 0), ready = AdmissionGate(), proceed = AdmissionGate()
        let task = Task {
            await ready.open()
            await proceed.wait()
            return try await claims.admit("gui", session: "cancelled", client: "test", origin: nil, token: nil, leasePath: path)
        }
        await ready.wait()
        task.cancel()
        await proceed.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await claims.holder("gui") == nil)
    }

    @Test func actionLockRevalidatesImmediatelyBeforeItsBody() async throws {
        let actionLock = ActionLock(), started = AdmissionGate(), proceed = AdmissionGate()
        let first = Task { try await actionLock.run("first", deadline: 5) { await started.open(); await proceed.wait(); return true } }
        await started.wait()
        let second = Task {
            try await ActionAdmission.$check.withValue({ throw ActionError("admission changed") }) {
                try await actionLock.run("second", deadline: 5) { Issue.record("refused action executed"); return false }
            }
        }
        await proceed.open()
        #expect(try await first.value == true)
        await #expect(throws: ActionError.self) { try await second.value }
    }

    @Test func watchdogUsesTheActualLongActionDeadline() async throws {
        let actionLock = ActionLock(), started = AdmissionGate(), proceed = AdmissionGate()
        let task = Task { try await actionLock.run("mac_shortcut", deadline: 305) { await started.open(); await proceed.wait(); return true } }
        await started.wait()
        let status = await actionLock.status
        let deadline = try #require(status.deadline)
        let limits = Watchdog.Limits()
        #expect(Watchdog.stall(now: deadline - 1, lastMain: deadline - 1, lastPool: deadline - 1,
                              lockHeldFor: 304, lockHolder: status.holder, limits: limits, lockDeadline: deadline) == nil)
        // A wedged input guard may keep the holder alive, but it cannot extend the watchdog's grace.
        #expect(Watchdog.stall(now: deadline + 15, lastMain: deadline + 15, lastPool: deadline + 15,
                              lockHeldFor: 320, lockHolder: status.holder, limits: limits, lockDeadline: deadline) == nil)
        #expect(Watchdog.stall(now: deadline + 15.001, lastMain: deadline + 15.001, lastPool: deadline + 15.001,
                              lockHeldFor: 320.001, lockHolder: status.holder, limits: limits, lockDeadline: deadline)?.contains("mac_shortcut") == true)
        await proceed.open()
        #expect(try await task.value)
    }
}
