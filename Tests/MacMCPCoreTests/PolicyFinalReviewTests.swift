import Foundation
import Testing
@testable import MacMCPCore

/// The 0.1.1 final review of the policy store: a busy approval lock, an add macOS holds up, and evaluations that must
/// never hold Swift's cooperative pool.
@Suite struct PolicyFinalReviewTests {
    /// While a person's `policy approve` holds the lock (at a keychain prompt, say), a deny they add to policy.json is
    /// enforced at once, in memory; a loosening still waits; and the tightening is recorded once the lock is free.
    @Test func aTighteningAppliesWhileAnotherProcessHoldsTheApprovalLock() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        let store = box.store()
        _ = await store.status()
        var person: ApprovalTransaction? = try ApprovalTransaction(path: box.locations.approvalLock, agent: false)
        try box.write(#"{"deny_apps":["a","b"]}"#)
        let busy = await store.status()
        #expect(try busy.enforced.get().denyApps == ["a", "b"])
        #expect(busy.source == .user)
        #expect(busy.problems.contains { $0.contains("Could not record") })
        #expect(busy.notices.contains { $0.contains("couldn't start an approval transaction") })
        #expect(box.keychain.writes == 1)

        try box.write(#"{"deny_apps":["b"]}"#)   // drops a: looser than the tightening in force
        let loose = await store.status()
        #expect(loose.pending.contains { $0.key == "deny_apps" })
        #expect(try loose.enforced.get().denyApps == ["a", "b"])
        #expect(box.keychain.writes == 1)

        try box.write(#"{"deny_apps":["a","b"]}"#)
        withExtendedLifetime(person) {}
        person = nil
        let free = await store.status()
        #expect(try free.enforced.get().denyApps == ["a", "b"])
        #expect(free.problems.isEmpty)
        #expect(box.keychain.writes == 2 && box.keychain.approvedPolicy == #"{"deny_apps":["a","b"]}"#)
        #expect(box.keychain.prompts == 0)
    }

    /// Putting the file back while the lock is still held doesn't undo a tightening held only in memory, and nothing is
    /// appended without the lock.
    @Test func revertingTheFileWhileTheLockIsHeldCountsAsALoosening() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        let store = box.store()
        _ = await store.status()
        let person = try ApprovalTransaction(path: box.locations.approvalLock, agent: false)
        try box.write(#"{"deny_apps":["a","b"]}"#)
        _ = await store.status()
        try box.write(#"{"deny_apps":["a"]}"#)
        let reverted = await store.status()
        #expect(reverted.pending.contains { $0.key == "deny_apps" })
        #expect(try reverted.enforced.get().denyApps == ["a", "b"])
        #expect(box.keychain.writes == 1)
        withExtendedLifetime(person) {}
    }

    /// A busy lock names its holder: the agent's tells the person to restart it, the CLI's to finish that command.
    @Test func aBusyLockSaysWhoHoldsItAndWhatToDo() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        let path = box.locations.approvalLock
        let since = Date(timeIntervalSinceNow: -90)
        var agent: ApprovalTransaction? = try ApprovalTransaction(path: path, agent: true, now: since)
        do {
            _ = try ApprovalTransaction(path: path)
            Issue.record("took a held lock")
        } catch let busy as ApprovalTransaction.Busy {
            #expect(busy.holder == ApprovalTransaction.Holder(pid: getpid(), since: busy.holder?.since ?? since, agent: true))
            #expect(abs((busy.holder?.since ?? .distantPast).timeIntervalSince(since)) < 0.01)
            #expect(busy.description.contains("agent (pid \(getpid()))") && busy.description.contains("`mac-mcp restart`"))
            #expect(busy.description.contains("since \(ApprovalTransaction.Busy.time(since))"))
        }
        try box.write(#"{}"#)
        do {
            _ = try PolicyStore.approve(box.locations)
            Issue.record("approved while the lock was held")
        } catch let error as PolicyStore.ApprovalError {
            guard case .busy = error else { Issue.record("not reported as busy: \(error)"); return }
            #expect(error.description.contains("pid \(getpid())") && error.description.contains("`mac-mcp restart`"))
            #expect(!error.description.contains("Unlock the keychain"))
        }
        withExtendedLifetime(agent) {}
        agent = nil
        #expect(FileManager.default.contents(atPath: path)?.isEmpty == true)   // a released lock names nobody

        var cli: ApprovalTransaction? = try ApprovalTransaction(path: path, agent: false)
        do {
            _ = try ApprovalTransaction(path: path)
            Issue.record("took a held lock")
        } catch let busy as ApprovalTransaction.Busy {
            #expect(busy.holder?.agent == false)
            #expect(busy.description.contains("`mac-mcp` command (pid \(getpid()))") && !busy.description.contains("restart"))
        }
        // A holder that's gone (the file left over from a crash, say) isn't named.
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: JSONEncoder().encode(ApprovalTransaction.Holder(pid: 99_999_999, since: since, agent: true)))
        try handle.close()
        do {
            _ = try ApprovalTransaction(path: path)
            Issue.record("took a held lock")
        } catch let busy as ApprovalTransaction.Busy {
            #expect(busy.holder == nil && busy.description.contains("another approval transaction is still running"))
        }
        withExtendedLifetime(cli) {}
        cli = nil
    }

    /// An add macOS holds up keeps the lock: `policy approve` names the agent's pid, the store still applies
    /// tightenings, and after about a minute the held-up call is a problem (alerted, and in mac_doctor).
    @Test func anAddThatHangsIsNamedAndTighteningsStillApply() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        let store = box.store()
        _ = await store.status()
        try box.write(#"{"deny_apps":["a"],"rate_limit_per_second":2}"#)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        box.keychain.timeOutNextAdd(before: { _ = release.wait(timeout: .now() + 20) }, finished: {})
        let timedOut = await store.status()
        #expect(timedOut.problems.contains { $0.contains("didn't answer in time") })
        #expect(box.keychain.heldUp != nil)

        do {
            _ = try PolicyStore.approve(box.locations)
            Issue.record("approved while the add held the lock")
        } catch let error as PolicyStore.ApprovalError {
            #expect(error.description.contains("pid \(getpid())"))
        }

        try box.write(#"{"deny_apps":["a","b"],"rate_limit_per_second":2}"#)
        let meanwhile = await store.status()
        #expect(try meanwhile.enforced.get().denyApps == ["a", "b"])
        #expect(!meanwhile.problems.contains { $0.contains("hasn't returned since") })   // not a minute yet

        let call = KeychainCall(what: "adding an approval record", since: Date(timeIntervalSinceNow: -75))
        box.keychain.heldUp = call
        try box.write(#"{"deny_apps":["a","b","c"],"rate_limit_per_second":2}"#)
        let late = await store.status()
        #expect(late.problems.contains(call.message))
        #expect(call.message.contains("`mac-mcp restart`"))
        #expect(try late.enforced.get().denyApps == ["a", "b", "c"])
        box.keychain.heldUp = nil
    }

    /// The keychain thread reports a call still running after `alertAfter`, once, and shows it until it returns.
    @Test func aHeldUpKeychainCallIsShownAndReportedOnce() async throws {
        let reports = PolicyReports()
        let thread = KeychainThread(alertAfter: 0.2) { reports.add($0.message) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        #expect(thread.run(timeout: 0.05, what: "adding an approval record") { gate.wait(); return 1 } == nil)
        // Held up counts from when the keychain thread starts the call, which can be after its caller started waiting.
        for _ in 0..<100 where thread.heldUp() == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(thread.heldUp()?.what == "adding an approval record")
        for _ in 0..<100 where reports.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.all.count == 1)
        #expect(reports.all.first?.contains("adding an approval record") == true)
        gate.signal()
        for _ in 0..<100 where thread.heldUp() != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(thread.heldUp() == nil)
        // One that returns in time is never reported.
        #expect(thread.run(timeout: 1) { 2 } == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.all.count == 1)
    }

    /// Many concurrent tool calls during a slow keychain read: the evaluation holds its own thread, the callers hold
    /// none, so other work on the cooperative pool still runs at once, and every caller gets the new policy.
    @Test(.timeLimit(.minutes(1))) func concurrentCallsDuringASlowKeychainReadDontStallThePool() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        // Callers that held threads would hold them for the 30 s patience, far past the 10 s this allows for a busy
        // machine.
        let store = PolicyStore(locations: box.locations, recheck: 0, patience: 30)
        _ = await store.status()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let (started, signal) = AsyncStream<Void>.makeStream()
        box.keychain.beforeNextRead {
            signal.yield(); signal.finish()
            _ = gate.wait(timeout: .now() + 40)
        }
        try box.write(#"{"deny_apps":["a","b"]}"#)
        let first = Task { await store.status() }
        for await _ in started { break }
        // Far more callers than the pool has threads. Timed from here: a pool they filled would hold up this test's
        // own sleep too.
        let start = ContinuousClock.now
        let callers = (0..<max(64, ProcessInfo.processInfo.activeProcessorCount * 8)).map { _ in
            Task { await store.status() }
        }
        try await Task.sleep(for: .milliseconds(100))
        let probe = await Task.detached { 42 }.value
        #expect(probe == 42)
        let cached = store.recentStatus()   // non-gating reads take the status found before at once
        #expect(try cached.enforced.get().denyApps == ["a"])
        #expect(start.duration(to: .now) < .seconds(10), "the pool waited for the policy evaluation")
        gate.signal()
        #expect(try await first.value.enforced.get().denyApps == ["a", "b"])
        for caller in callers { #expect(try await caller.value.enforced.get().denyApps == ["a", "b"]) }
    }
}
