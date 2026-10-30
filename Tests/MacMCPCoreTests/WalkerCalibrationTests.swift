import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import MacMCPCore

/// A synthetic accessibility tree walked by the real `Walker` through an injected source, with its own clock, so
/// time truncation is deterministic and no app is needed.
private final class SyntheticTree: Sendable {
    private let attrs: Mutex<[AXElement: [String: any Sendable]]>
    private let children = Mutex<[AXElement: [AXElement]]>([:])   // AXUIElement itself isn't Sendable; AXElement is
    private let clock = Mutex<Date>(Date(timeIntervalSince1970: 1000))
    private let reads = Mutex(0)
    /// How long every node read takes on the synthetic clock.
    let secondsPerRead: TimeInterval
    var readCount: Int { reads.withLock { $0 } }

    init(secondsPerRead: TimeInterval = 0) {
        self.secondsPerRead = secondsPerRead
        attrs = Mutex([:])
    }

    static func element(_ n: Int32) -> AXElement { AXElement.application(pid: 300_000 + n) }

    func add(_ n: Int32, role: String = "AXButton", title: String? = nil, children: [Int32] = []) {
        var v: [String: any Sendable] = ["AXRole": role, "AXPosition": CGPoint(x: 0, y: 0), "AXSize": CGSize(width: 10, height: 10)]
        if let title { v["AXTitle"] = title }
        attrs.withLock { $0[Self.element(n)] = v }
        self.children.withLock { $0[Self.element(n)] = children.map(Self.element) }
    }

    var source: Walker.Source {
        Walker.Source(read: { [self] el, _ in
            reads.withLock { $0 += 1 }
            clock.withLock { $0 = $0.addingTimeInterval(secondsPerRead) }
            guard var dict = attrs.withLock({ $0[el] }).map({ $0.mapValues { $0 as Any } }) else { return nil }
            dict["AXChildren"] = children.withLock { $0[el] }?.map(\.raw) ?? []
            return dict
        }, attribute: { _, _ in nil }, elements: { _, _ in [] }, now: { [self] in clock.withLock { $0 } })
    }

    func walk(maxNodes: Int, timeLimit: TimeInterval) -> (RawNode, WalkStats) {
        var options = Walker.Options()
        options.maxNodes = maxNodes
        options.timeLimit = timeLimit
        options.source = source
        return Walker.walk(Self.element(0), options: options)
    }

    /// What `Settle.signature` hashes from a walk: the rendered rows.
    func signature(maxNodes: Int, timeLimit: TimeInterval) -> (hash: Int, walk: WalkStats?) {
        let (tree, stats) = walk(maxNodes: maxNodes, timeLimit: timeLimit)
        var h = Hasher()
        for row in Snapshot.rows(from: tree, pid: 1) { h.combine(row.render(frames: true)) }
        return (h.finalize(), stats)
    }

    /// A chain `depth` nodes long: node i's only child is node i + 1. Levels are `role`s (buttons by default; groups
    /// nest context rows instead).
    static func chain(_ depth: Int32, role: String = "AXButton") -> SyntheticTree {
        let t = SyntheticTree()
        t.add(0, role: "AXWindow", children: [1])
        for i in 1..<depth { t.add(i, role: role, title: "Level \(i)", children: [i + 1]) }
        t.add(depth, role: role, title: "Level \(depth)")
        return t
    }

    /// A window with `count` buttons under it, each read taking `secondsPerRead`.
    static func wide(_ count: Int32, secondsPerRead: TimeInterval) -> SyntheticTree {
        let t = SyntheticTree(secondsPerRead: secondsPerRead)
        t.add(0, role: "AXWindow", children: Array(1...count))
        for i in 1...count { t.add(i, title: "Button \(i)") }
        return t
    }
}

@Suite struct FinalSettleWalkTests {
    private func capture(_ tree: SyntheticTree, options: Walker.Options = Walker.Options()) -> Walker.Capture {
        var options = options
        options.source = tree.source
        let root = SyntheticTree.element(0)
        let (raw, stats) = Walker.walk(root, options: options)
        return Walker.Capture(root: root, options: options, tree: raw, stats: stats)
    }

    @Test func aCompleteWalkIsReusedWithoutReadingOrCountingItTwice() async {
        let tree = SyntheticTree.wide(30, secondsPerRead: 0)
        var options = Walker.Options()
        options.maxNodes = 1500
        let final = capture(tree, options: options)
        let reads = tree.readCount
        let metrics = ActionMetrics.Recorder()
        let (_, stats) = await ActionMetrics.$current.withValue(metrics) {
            await ActionMetrics.during(.after) {
                var next = Walker.Options()
                next.source = tree.source
                return Walker.walk(SyntheticTree.element(0), options: next, reusing: final)
            }
        }
        #expect(tree.readCount == reads && stats.complete && stats.visited == 31)
        let report = metrics.finish(tool: "mac_click", session: "fixture", isError: false)
        #expect(report.walks == 0 && report.reusedWalks == 1 && report.phases["after"]?.reusedWalks == 1)
    }

    @Test func reusePreservesTheDiffRefsAndWhatWasShown() async throws {
        let tree = SyntheticTree.wide(3, secondsPerRead: 0)
        let refs = RefStore()
        var before = Snapshot.rows(from: capture(tree).tree, pid: 1)
        _ = try await refs.record(&before, pid: 1)
        await refs.markShown(before)
        tree.add(1, title: "Renamed button")
        let final = capture(tree)
        var options = Walker.Options()
        options.source = tree.source
        let (reused, _) = Walker.walk(SyntheticTree.element(0), options: options, reusing: final)
        var after = Snapshot.rows(from: reused, pid: 1)
        _ = try await refs.record(&after, pid: 1)
        var fresh = Snapshot.rows(from: capture(tree).tree, pid: 1)
        _ = try await refs.record(&fresh, pid: 1)
        #expect(after == fresh)
        let diff = Diff.compute(before: before, after: after)
        #expect(!diff.lines.isEmpty && diff.lines == Diff.compute(before: before, after: fresh).lines)
        let ref = try #require(after.first?.ref)
        let entry = try #require(await refs.entry(ref))
        #expect(entry.shown?.label == before.first?.label, "bookkeeping still doesn't mark new labels shown")
        #expect(RefStore.changeMessage(ref: ref, role: entry.row.role, shown: entry.shown,
                                      label: entry.row.label, identifier: entry.row.identifier) != nil)
    }

    @Test func cutsAndReadFailuresAlwaysRequireAFreshWalk() {
        let tree = SyntheticTree.wide(30, secondsPerRead: 0)
        let whole = capture(tree)
        let root = SyntheticTree.element(0)
        var options = Walker.Options()
        options.source = tree.source
        var badStats: [WalkStats] = []
        for cut in [WalkStats.Truncation.nodes, .depth, .time, .cancelled] {
            var stats = whole.stats
            stats.truncation = cut
            badStats.append(stats)
        }
        var unread = whole.stats; unread.readFailures = 1; badStats.append(unread)
        var identity = whole.stats; identity.identityReadFailures = 1; badStats.append(identity)
        var text = whole.stats; text.textReadFailures = 1; badStats.append(text)
        for stats in badStats {
            let partial = Walker.Capture(root: root, options: options, tree: whole.tree, stats: stats)
            let reads = tree.readCount
            let result = Walker.walk(root, options: options, reusing: partial)
            #expect(tree.readCount > reads && result.1.complete && result.1.visited == 31)
        }
    }

    @Test func aNewRootViewportMenuPolicyOrSmallerBudgetCannotReuseTheWalk() {
        let tree = SyntheticTree.wide(30, secondsPerRead: 0)
        let whole = capture(tree)
        let root = SyntheticTree.element(0)
        #expect(!whole.matches(SyntheticTree.element(1), options: Walker.Options()), "a new window, sheet, dialog or menu bar")
        var offscreen = Walker.Options()
        offscreen.clip = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clipped = capture(tree, options: offscreen)
        #expect(!clipped.matches(root, options: Walker.Options()), "offscreen=true needs an unclipped walk")
        offscreen.clip = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(!clipped.matches(root, options: offscreen), "a display change")
        var menus = Walker.Options(); menus.descendMenus = true
        #expect(!whole.matches(root, options: menus))
        var smaller = Walker.Options(); smaller.maxNodes = 10
        #expect(!whole.matches(root, options: smaller))
        #expect(whole.matches(root, options: Walker.Options()))
        #expect(!whole.matches(root, options: Walker.Options(), now: .now + Walker.Capture.maxAge), "a walk too old to trust")
    }

    @Test func settleOffersOnlyItsLastSampleAndNeverAnUnsettledWalk() async {
        let tree = SyntheticTree.wide(3, secondsPerRead: 0)
        let first = capture(tree)
        tree.add(1, title: "Final button")
        let last = capture(tree)
        var samples = 0
        let settled = await Settle.wait(pid: 410_010, quiet: 0, timeout: 60) { _, _ in
            samples += 1
            return (42, last.stats, samples == 1 ? first : last)
        }
        #expect(settled.settled && samples >= 2)
        #expect(settled.finalWalk?.tree.children.first?.title == "Final button")
        let timedOut = await Settle.wait(pid: 410_011, quiet: 250, timeout: 0) { _, _ in (42, last.stats, last) }
        #expect(!timedOut.settled && timedOut.finalWalk == nil)
    }

    @Test func aWindowlessFinalSampleCannotOfferAnEarlierWindow() async {
        let final = capture(.wide(3, secondsPerRead: 0))
        var samples = 0
        let result = await Settle.wait(pid: 410_012, quiet: 0, timeout: 60) { _, _ in
            samples += 1
            return samples == 1 ? (42, final.stats, final) : (42, nil, nil)
        }
        #expect(result.settled && result.finalWalk == nil)
    }
}

/// D4: the walker tells truncation reasons apart, and the settle calibration treats only a stop by time as
/// incomparable, so a tree that stops at the depth limit or delivers fewer than the floor still settles.
@Suite struct WalkerCalibrationTests {
    @Test func theWalkerReportsWhyItStopped() {
        let chain = SyntheticTree.chain(80)
        let (_, byDepth) = chain.walk(maxNodes: 1500, timeLimit: 3)
        #expect(byDepth.truncation == .depth && byDepth.visited == 60)
        #expect(byDepth.truncated && !byDepth.complete)
        let (_, byNodes) = chain.walk(maxNodes: 20, timeLimit: 3)
        #expect(byNodes.truncation == .nodes && byNodes.visited == 20)
        let slow = SyntheticTree.wide(300, secondsPerRead: 0.03)
        let (_, byTime) = slow.walk(maxNodes: 1500, timeLimit: 0.4)
        #expect(byTime.truncation == .time && byTime.visited == 64, "the clock is checked every 64 nodes")
        let (_, whole) = SyntheticTree.wide(30, secondsPerRead: 0).walk(maxNodes: 1500, timeLimit: 3)
        #expect(whole.truncation == nil && whole.complete && whole.visited == 31)
    }

    @Test func aTreeThatHitsTheDepthLimitIsComparableAtOnce() {
        let pid: pid_t = 410_001
        let chain = SyntheticTree.chain(80)
        let first = Settle.calibratedSample(pid: pid) { budget, limit in chain.signature(maxNodes: budget, timeLimit: limit) }
        #expect(first != nil, "a stop at the depth limit stops at the same node every time")
        #expect(Settle.budget(for: pid) == nil, "nothing about the app's speed was learned, so nothing shrinks")
        let second = Settle.calibratedSample(pid: pid) { budget, limit in chain.signature(maxNodes: budget, timeLimit: limit) }
        #expect(second == first)
    }

    /// 0.03 s a node: 64 nodes in 1.92 s, so the uncalibrated 0.4 s limit and the calibrated 1.5 s limit both cut
    /// the walk at 64. Under the old floor of 100 the budget could never be met, and every sample was discarded.
    @Test func aSlowTreeGetsABudgetItCanMeetBelowTheFloor() {
        let pid: pid_t = 410_002
        let slow = SyntheticTree.wide(300, secondsPerRead: 0.03)
        func sample() -> Int? { Settle.calibratedSample(pid: pid) { budget, limit in slow.signature(maxNodes: budget, timeLimit: limit) } }
        #expect(sample() == nil, "the calibrating walk was cut by time")
        #expect(Settle.budget(for: pid) == 48, "three quarters of the 64 nodes delivered, below the floor of \(Settle.minNodes)")
        let a = sample()
        #expect(a != nil, "with a budget it can meet, the walk stops by node count and is comparable")
        #expect(Settle.budget(for: pid) == 48)
        #expect(sample() == a, "an unchanged tree hashes the same")
        slow.add(5, title: "Button 5 (renamed)")
        #expect(sample() != a, "a change inside the budget is still seen")
    }

    @Test func anAppThatDeliversMoreThanTheFloorIsCutToTheFloorAndConverges() {
        let pid: pid_t = 410_003
        // 0.004 s a node: 128 nodes in 0.512 s. The calibrating walk (0.4 s) stops at 128; calibrated (1.5 s) walks
        // the floor of 100 by node count.
        let tree = SyntheticTree.wide(300, secondsPerRead: 0.004)
        func sample() -> Int? { Settle.calibratedSample(pid: pid) { budget, limit in tree.signature(maxNodes: budget, timeLimit: limit) } }
        #expect(sample() == nil)
        #expect(Settle.budget(for: pid) == Settle.minNodes)
        let a = sample()
        #expect(a != nil && sample() == a)
    }
}

/// Runs `body` on a thread with the 512 KB stack of a cooperative-pool or GCD worker, in whatever build this is: a
/// recursive pass over a 60-level tree overflowed it in a debug build.
private func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    let result = Mutex<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result.withLock { $0 = body() }
        done.signal()
    }
    thread.stackSize = 512 << 10
    thread.start()
    done.wait()
    return result.withLock { $0! }
}

/// The walker and every pass over its tree are iterative, so a tree at the depth limit, or a very wide one, can't
/// overflow a small worker-thread stack.
@Suite struct DeepTreeStackTests {
    /// Walks, then runs each pass that reads a walked tree (rows, raw dump, opaque regions) and returns what they saw.
    private static func everything(_ tree: SyntheticTree, maxNodes: Int = 5000) -> (visited: Int, truncation: WalkStats.Truncation?,
                                                                                   deepest: Int, rows: Int, dump: Int, opaque: Int) {
        onSmallStack {
            let (raw, stats) = tree.walk(maxNodes: maxNodes, timeLimit: 3)
            var deepest = 1, node = raw
            while let child = node.children.first { deepest += 1; node = child }
            let rows = Snapshot.rows(from: raw, pid: 1)
            _ = Snapshot.render(rows, frames: true, maxTokens: 100_000)
            return (stats.visited, stats.truncation, deepest, rows.count, Snapshot.rawDump(raw, maxLines: 10_000).split(separator: "\n").count,
                    Snapshot.opaqueRegions(raw).count)
        }
    }

    @Test func aTreeAtTheDepthLimitWalksAndRendersOnASmallStack() {
        let r = Self.everything(.chain(59))
        #expect(r.visited == 60 && r.truncation == nil, "depths 0...59 are all inside the limit")
        #expect(r.deepest == 60)
        #expect(r.rows == 59, "every button below the window is a row")
        #expect(r.dump == 60)
    }

    @Test func aTreeBeyondTheDepthLimitStopsAtItOnASmallStack() {
        let r = Self.everything(.chain(200))
        #expect(r.visited == 60 && r.truncation == .depth && r.deepest == 60)
    }

    @Test func nestedContainersRenderOnASmallStack() {
        let r = Self.everything(.chain(59, role: "AXGroup"))
        #expect(r.deepest == 60 && r.rows == 59, "each titled group is a context row")
    }

    @Test func aVeryWideTreeWalksAndRendersOnASmallStack() {
        let r = Self.everything(.wide(4000, secondsPerRead: 0))
        #expect(r.visited == 4001 && r.truncation == nil && r.deepest == 2)
        #expect(r.rows == 4000)
    }

    @Test func aTreeCutByTheNodeBudgetKeepsWhatItReached() {
        let r = Self.everything(.chain(60), maxNodes: 25)
        #expect(r.visited == 25 && r.truncation == .nodes && r.deepest == 25)
    }
}
