import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// Waits until the UI stops changing, instead of sleeping a fixed time.
///
/// A sample is a signature of what an agent would see: the frontmost app, the target app's windows (window server
/// ids and bounds), its focused element, and a hash of its focused window's rows. The UI is settled once the
/// signature holds for `quiet` milliseconds. Capped by `timeout`; a UI that keeps changing (a progress bar, a
/// clock) is reported as not settled rather than blocking forever.
///
/// Two samples of an unchanged UI must hash the same, so the tree walk is bounded by a node count only: a walk cut
/// off by time stops at a different node each sample (Xcode, VS Code and Chromium trees are slow), and every sample
/// would look like a change. When an app can't deliver the full budget in time, the budget shrinks to what it did
/// deliver and stays there for that process, so later samples hash the same prefix of the tree. A walk that stopped
/// at the node budget or the depth limit stopped at the same place it will stop next time, so it is comparable as
/// it is; only a stop by time (or cancellation) is discarded.
public enum Settle {
    public struct Result: Sendable {
        public let settled: Bool
        public let milliseconds: Int
    }

    /// Nodes a signature walk may visit when the app answers quickly enough, and the least a budget is cut to from
    /// a larger delivery. An app that delivers fewer nodes than that in time gets a budget below it rather than one
    /// it can never meet (every sample would be discarded and every action would wait out the timeout).
    static let maxNodes = 1500
    static let minNodes = 100
    /// Time a first, uncalibrated walk may take before its budget is cut; the ceiling once calibrated is a safety
    /// valve for an app that has slowed down since.
    static let calibrationTimeLimit: TimeInterval = 0.4
    static let calibratedTimeLimit: TimeInterval = 1.5

    /// Node budgets learned per process. Kept across calls: calibrating once per wait would spend most of the
    /// timeout on a big tree every time.
    private static let budgets = Mutex<[pid_t: Int]>([:])

    static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Whether a window belongs in the app's signature: its own windows (menus, popovers and sheets are windows of
    /// the app too) and pop-up menus from anywhere. Other apps' windows don't: a notification banner or a menu-bar
    /// item redrawing elsewhere would otherwise reset the quiet timer.
    static func counts(_ w: WindowInfo, pid: pid_t) -> Bool { w.pid == pid || w.layer == popUpMenuLevel }

    static func combineWindows(_ windows: [WindowInfo], pid: pid_t, into h: inout Hasher) {
        for w in windows where counts(w, pid: pid) {
            h.combine(w.id)
            h.combine(Int(w.bounds.minX)); h.combine(Int(w.bounds.minY))
            h.combine(Int(w.bounds.width)); h.combine(Int(w.bounds.height))
        }
    }

    /// One sample. `nodeBudget` bounds the tree walk; the stats say whether it stopped short of the budget (by time).
    static func signature(pid: pid_t, nodeBudget: Int, timeLimit: TimeInterval) -> (hash: Int, walk: WalkStats?) {
        var h = Hasher()
        h.combine(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        combineWindows(WindowServer.onScreenWindows(), pid: pid, into: &h)
        let app = AXElement.application(pid: pid, timeout: 0.5)
        if let focused = app.element(kAXFocusedUIElementAttribute) { h.combine(focused) }
        var walk: WalkStats?
        if let window = app.element(kAXFocusedWindowAttribute) {
            var options = Walker.Options()
            options.maxNodes = nodeBudget
            options.timeLimit = timeLimit
            options.clip = Walker.screenBounds
            let (tree, stats) = Walker.walk(window, options: options)
            walk = stats
            for row in Snapshot.rows(from: tree, pid: pid) { h.combine(row.render(frames: true)) }
        }
        return (h.finalize(), walk)
    }

    public static func wait(pid: pid_t, quiet: Int = 250, timeout: TimeInterval = 2.0) async -> Result {
        await wait(quiet: quiet, timeout: timeout) {
            calibratedSample(pid: pid) { budget, timeLimit in signature(pid: pid, nodeBudget: budget, timeLimit: timeLimit) }
        }
    }

    /// One sample under the process's learned budget, or nil when it isn't comparable (a walk cut short by time
    /// shrinks the budget for the next one; a cancelled walk changes nothing). `signature` takes the node budget and
    /// time limit to walk with; injectable so the calibration can be driven over a synthetic tree.
    static func calibratedSample(pid: pid_t, signature: (Int, TimeInterval) -> (hash: Int, walk: WalkStats?)) -> Int? {
        let known = budgets.withLock { $0[pid] }
        let budget = known ?? maxNodes
        let (hash, walk) = signature(budget, known == nil ? calibrationTimeLimit : calibratedTimeLimit)
        if walk?.truncation == .cancelled { return nil }
        if let smaller = shrunkBudget(after: walk, budget: budget) {
            budgets.withLock { $0[pid] = smaller }
            return nil
        }
        return hash
    }

    /// The learned budget for a process, if any (tests).
    static func budget(for pid: pid_t) -> Int? { budgets.withLock { $0[pid] } }

    /// A walk that stopped short of its node budget by time isn't comparable with any other sample: the budget to
    /// use from now on, three quarters of what the app answered in time. Nil when the sample is good: it stopped by
    /// node count or depth (the same node next time, for the same tree), walked everything, or was cancelled. The
    /// floor applies only to apps that delivered at least that much; a slower app gets what it can deliver, down to
    /// a single node, so its samples become comparable instead of never.
    static func shrunkBudget(after walk: WalkStats?, budget: Int) -> Int? {
        guard let walk, walk.truncation == .time, walk.visited < budget else { return nil }
        let usable = walk.visited * 3 / 4
        return walk.visited >= minNodes ? max(minNodes, usable) : max(1, usable)
    }

    /// The settle loop over any sampler, so it can be tested without a UI. A nil sample is "not comparable" and
    /// restarts the quiet period. Cancellation ends the wait at once, unsettled.
    static func wait(quiet: Int, timeout: TimeInterval, sample: () async -> Int?) async -> Result {
        let started = ContinuousClock.now
        func elapsed() -> Int { Int(started.duration(to: .now) / .milliseconds(1)) }
        func unsettled() -> Result { Result(settled: false, milliseconds: elapsed()) }
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return unsettled() }   // let the app start reacting
        var last = await sample()
        var stableSince = ContinuousClock.now
        while started.duration(to: .now) < .seconds(timeout) {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return unsettled() }
            if Task.isCancelled { return unsettled() }
            let now = await sample()
            if now == nil || now != last {
                last = now
                stableSince = .now
            } else if stableSince.duration(to: .now) >= .milliseconds(quiet) {
                return Result(settled: true, milliseconds: elapsed())
            }
        }
        return unsettled()
    }
}
