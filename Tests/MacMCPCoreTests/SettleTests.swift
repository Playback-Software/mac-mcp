import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

/// D4: the settle loop, its window filter and its deterministic sampling, without a live UI.
@Suite struct SettleTests {
    @Test func settlesOnceTheSignatureHolds() async {
        // Settling is the only way out before the timeout, so a generous one makes the load irrelevant.
        let r = await Settle.wait(quiet: 100, timeout: 60) { 42 }
        #expect(r.settled)
        #expect(r.milliseconds < 30_000, "a quiet UI settles in about quiet + two sample gaps, not the full timeout")
    }

    @Test func aChangingSignatureRunsOutTheTimeout() async {
        var n = 0
        let r = await Settle.wait(quiet: 100, timeout: 0.5) { n += 1; return n }
        #expect(!r.settled)
        #expect(r.milliseconds >= 500)
    }

    @Test func anIncomparableSampleRestartsTheQuietPeriod() async {
        // Every other sample is discarded (a walk cut short): the signature never holds long enough.
        var n = 0
        let r = await Settle.wait(quiet: 150, timeout: 0.6) { n += 1; return n % 2 == 0 ? nil : 7 }
        #expect(!r.settled)
    }

    @Test func cancellationStopsTheWaitPromptly() async {
        let sampled = Signal()
        let task = Task { () -> Settle.Result in
            var n = 0
            return await Settle.wait(quiet: 250, timeout: 60) { n += 1; sampled.fire(); return n }   // never settles on its own
        }
        await sampled.wait()   // the wait is under way
        let cancelled = ContinuousClock.now
        task.cancel()
        let r = await task.value
        #expect(!r.settled)
        #expect(cancelled.duration(to: .now) < .seconds(30), "a cancelled wait must not keep sampling until the 60 s timeout")
    }

    @Test func onlyTheAppsWindowsAndPopUpMenusCount() {
        func window(pid: pid_t, layer: Int) -> WindowInfo {
            WindowInfo(id: 1, pid: pid, owner: "x", title: "", layer: layer, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)
        }
        #expect(Settle.counts(window(pid: 7, layer: 0), pid: 7))
        #expect(Settle.counts(window(pid: 7, layer: 101), pid: 7), "the app's own menus")
        #expect(Settle.counts(window(pid: 9, layer: Settle.popUpMenuLevel), pid: 7), "a pop-up menu from anywhere")
        #expect(!Settle.counts(window(pid: 9, layer: 0), pid: 7), "another app's window")
        #expect(!Settle.counts(window(pid: 9, layer: 25), pid: 7), "a menu-bar item or notification banner")
        #expect(!Settle.counts(window(pid: 9, layer: 20), pid: 7), "the Dock")
    }

    @Test func windowSignatureIgnoresOtherAppsChanges() {
        let mine = WindowInfo(id: 1, pid: 7, owner: "app", title: "", layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), alpha: 1)
        let banner = WindowInfo(id: 2, pid: 9, owner: "NotificationCenter", title: "", layer: 18, bounds: CGRect(x: 1000, y: 0, width: 300, height: 80), alpha: 1)
        var a = Hasher(), b = Hasher()
        Settle.combineWindows([mine], pid: 7, into: &a)
        Settle.combineWindows([mine, banner], pid: 7, into: &b)
        #expect(a.finalize() == b.finalize())
        var moved = mine
        moved = WindowInfo(id: 1, pid: 7, owner: "app", title: "", layer: 0, bounds: mine.bounds.offsetBy(dx: 10, dy: 0), alpha: 1)
        var c = Hasher()
        Settle.combineWindows([moved], pid: 7, into: &c)
        #expect(a.finalize() != c.finalize())
    }

    @Test func aWalkCutShortByTimeShrinksTheBudgetAndIsDiscarded() {
        var byCount = WalkStats()
        byCount.visited = 1500
        byCount.truncation = .nodes
        #expect(Settle.shrunkBudget(after: byCount, budget: 1500) == nil, "stopped by node count: deterministic")
        var byDepth = WalkStats()
        byDepth.visited = 60
        byDepth.truncation = .depth
        #expect(Settle.shrunkBudget(after: byDepth, budget: 1500) == nil, "stopped at the depth limit: the same node next time")
        var cancelled = WalkStats()
        cancelled.visited = 10
        cancelled.truncation = .cancelled
        #expect(Settle.shrunkBudget(after: cancelled, budget: 1500) == nil, "a cancelled walk says nothing about the app's speed")
        var complete = WalkStats()
        complete.visited = 300
        #expect(Settle.shrunkBudget(after: complete, budget: 1500) == nil, "walked the whole tree")
        #expect(Settle.shrunkBudget(after: nil, budget: 1500) == nil, "no focused window: nothing to walk")
        var byTime = WalkStats()
        byTime.visited = 900
        byTime.truncation = .time
        #expect(Settle.shrunkBudget(after: byTime, budget: 1500) == 675)
        var nearFloor = WalkStats()
        nearFloor.visited = 120
        nearFloor.truncation = .time
        #expect(Settle.shrunkBudget(after: nearFloor, budget: 1500) == Settle.minNodes, "delivered at least the floor: cut to the floor")
        var tiny = WalkStats()
        tiny.visited = 20
        tiny.truncation = .time
        #expect(Settle.shrunkBudget(after: tiny, budget: 1500) == 15, "an app that can't reach the floor gets what it delivered")
        var one = WalkStats()
        one.visited = 1
        one.truncation = .time
        #expect(Settle.shrunkBudget(after: one, budget: 1500) == 1, "never a budget of nothing")
    }

    @Test func aCancelledSampleIsDiscardedWithoutChangingTheBudget() {
        let pid: pid_t = 400_001
        var cancelled = WalkStats()
        cancelled.visited = 10
        cancelled.truncation = .cancelled
        #expect(Settle.calibratedSample(pid: pid) { _, _ in (1, cancelled) } == nil)
        #expect(Settle.budget(for: pid) == nil)
    }
}
