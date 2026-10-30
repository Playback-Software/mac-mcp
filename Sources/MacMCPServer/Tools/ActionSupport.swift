import AppKit
import Foundation
import MacMCPCore

/// The shared shape of every action: guard → before snapshot (refreshes refs) → resolve → act → settle → after
/// snapshot → diff. Runs under the action lock: there is one keyboard and one mouse.
func runAction(
    name: String,
    app: String?,
    target: Target?,
    deadline: TimeInterval = actionDeadline,
    _ body: @escaping @Sendable (_ resolved: Resolved?, _ pid: pid_t) async throws -> ActionSummary
) async -> ToolOutput {
    do {
        return try await ActionLock.shared.run(name, deadline: deadline) {
            await perform(name: name, app: app, target: target, body)
        }
    } catch is DeadlineExceeded {
        return abandoned("mac_" + name, deadline)
    } catch {
        return .error("\(error)", audit: (error as? ActionError)?.audit)   // includes ActionLockBusy: it waited its turn and didn't run
    }
}

/// Runs a GUI-changing call that isn't a `runAction` (window and app management) under the action lock, so it can't
/// land in the middle of a parallel call's typing or clicking.
func underActionLock(_ name: String, deadline: TimeInterval = actionDeadline,
                     _ body: @escaping @Sendable () async -> ToolOutput) async -> ToolOutput {
    do {
        return try await ActionLock.shared.run(name, deadline: deadline, body)
    } catch is DeadlineExceeded {
        return abandoned(name, deadline)
    } catch {
        return .error("\(error)", audit: (error as? ActionError)?.audit)
    }
}

/// Default time an action may hold the lock: resolve, act, settle and the after-snapshot together.
let actionDeadline: TimeInterval = 20
/// How long a call waits for the action lock before giving up without running (`ActionLock.run`'s default).
let lockWait: TimeInterval = 30
/// A lock-taking tool's dispatcher deadline: waiting for the lock, then holding it, plus slack.
func lockedDeadline(_ hold: TimeInterval) -> TimeInterval { lockWait + hold + 5 }

private func perform(
    name: String,
    app: String?,
    target: Target?,
    _ body: @escaping @Sendable (_ resolved: Resolved?, _ pid: pid_t) async throws -> ActionSummary
) async -> ToolOutput {
    if let blocked = await sessionGuard() { return blocked }
    do {
        let pid = try await Actions.pid(for: target, app: app)
        if WindowServer.isSystemPrompt(pid: pid) {
            await Alerts.shared.notify(.prompt, "An agent tried to act on a macOS security/permission prompt; it needs a person.")
            return .error("Refused: that is a macOS security or permission prompt. A person must answer it "
                + "(via Remote Access); MacMCP never clicks or types into these.")
        }
        let policy: Policy
        switch await currentPolicy() { case let .success(p): policy = p; case let .failure(out): return out }
        if let running = NSRunningApplication(processIdentifier: pid),
           let refusal = policy.refusal(bundleID: running.bundleIdentifier, name: running.localizedName) {
            return .error(refusal)
        }
        await RateLimiter.shared.acquire(rate: policy.rateLimitPerSecond)

        let req = bookkeepingSnapshot(pid: pid)
        let before = try await actionSnapshot(req, allowMenubar: name == "menu")
        var resolved: Resolved?
        if let target { resolved = try await Actions.resolve(target, currentSnapshot: before.snapshot) }
        // A point meant for app= that lands in another app's window: bring app= forward, then insist.
        if app != nil, let r = resolved, r.point != nil, r.pid != 0, r.pid != pid, let target {
            if let running = NSRunningApplication(processIdentifier: pid) { _ = await AppControl.activate(AppInfo(running)) }
            resolved = try await Actions.resolve(target, currentSnapshot: before.snapshot)
            if let r = resolved, r.pid != 0, r.pid != pid {
                let other = NSRunningApplication(processIdentifier: r.pid)?.localizedName ?? "another app"
                return .error("Refused: \(r.describe) is covered by \(other), not \(app!), even with \(app!) "
                    + "in front. Take a new mac_screenshot or use a ref from mac_snapshot.")
            }
        }
        if let r = resolved, let refusal = try await Input.guardWork(pool: .route, timeout: Input.routeTimeout, { targetRefusal(r, checkedPid: pid, policy: policy) }) {
            return .error(refusal, audit: "Refused: target route")
        }
        let summary = try await ActionRoute.$check.withValue({ step in try await RouteGuards.check(step) }) {
            try await body(resolved, pid)
        }
        let settle = await Settle.wait(pid: pid)
        // A successful action can close the final window (Escape in an Open panel, a close button, cmd+w).
        let after = try await actionSnapshot(req, allowMenubar: true)
        let out = report(summary: summary.text, settle: settle, before: before, after: after)
        await RefStore.shared.markShown(out.shownRows)
        return .text(out.text, auditDetail: actionAudit(resolved, app: app, summary))
    } catch {
        return .error("\(error)", audit: (error as? ActionError)?.audit)
    }
}

/// Menu commands remain usable when an app has no document windows (File > New/Open, for example). A busy app
/// that still has windows raises `notResponding`, not `noWindow`, and must keep failing instead of acting blindly.
func actionSnapshot(_ request: SnapshotRequest, allowMenubar: Bool,
                    take: (SnapshotRequest) async throws -> SnapshotResult = { try await Snapshotter.take($0) }) async throws -> SnapshotResult {
    do {
        return try await take(request)
    } catch SnapshotError.noWindow(_) where allowMenubar {
        var menubar = request
        menubar.scope = .menubar
        return try await take(menubar)
    }
}

/// A snapshot an action takes for itself (before/after, a drag's drop target). The agent sees the report, not the
/// snapshot, so it must not mark what it rendered as shown: `report` says which rows the agent actually saw.
func bookkeepingSnapshot(pid: pid_t) -> SnapshotRequest {
    var req = SnapshotRequest()
    req.pid = pid
    req.markShown = false
    return req
}

/// The log's line for an action: the element's role and ref and what was done, never what the screen said about it.
func actionAudit(_ resolved: Resolved?, app: String?, _ summary: ActionSummary) -> String {
    "\(resolved?.auditName ?? app ?? "") → \(summary.audit)"
}

/// Why an action may not land on this resolved target, or nil. Applies to every point an action touches (a drag's
/// drop point too), so a coordinate can't reach what the app check refused. `checkedPid` already passed policy.
func targetRefusal(_ r: Resolved, checkedPid pid: pid_t, policy: Policy) -> String? {
    if r.pid != 0, WindowServer.isSystemPrompt(pid: r.pid) {
        return "Refused: the target is part of a macOS security or permission prompt. A person must answer it."
    }
    if let element = r.element, let blocked = Actions.modalBlocker(of: element, pid: r.pid) { return blocked }
    let ownerPid = r.pid != 0 ? r.pid : pid
    if let element = r.element ?? r.point.flatMap({ AXElement.application(pid: ownerPid).element(at: $0) }) {
        if let refusal = SessionSafety.refusal(element: element) { return refusal }
        // What the element stands for: a Dock tile or app icon opens that app (a click, or a file dropped on it),
        // and a protected file or folder is off limits whatever the action.
        if let refusal = OpenRoutes.elementRefusal(element, pid: ownerPid, policy: policy) { return refusal }
    }
    if r.pid != 0, r.pid != pid, let running = NSRunningApplication(processIdentifier: r.pid),
       let refusal = policy.refusal(bundleID: running.bundleIdentifier, name: running.localizedName) {
        return refusal   // a coordinate target that lands in a denied app's window
    }
    return nil
}

/// Action result: what was done, how the UI settled, the new header, and what changed. Also which rows the text
/// shows, as rendered, so `RefStore` can remember the labels the agent has now seen. `summary` is the tool's
/// sentence; screen text in it (a label, a tooltip) is already marked inline. Everything below it is read from the
/// screen and goes in one marked block.
func report(summary: String, settle: Settle.Result, before: SnapshotResult, after: SnapshotResult) -> (text: String, shownRows: [Row]) {
    let head = summary + (settle.settled ? " · settled in \(settle.milliseconds) ms" : " · UI still changing after \(settle.milliseconds) ms")
    var lines: [String] = []
    lines += after.lines.prefix(2)   // header + blockers
    if let front = Apps.frontmost(), front.pid != after.app.pid {
        lines.append("note: the frontmost app is now \(front.label); snapshot it with app=\"\(front.name)\"")
    }
    // Structural change (window, sheet, dialog, prompt) → show the new state; notes like secure input don't count.
    func structural(_ b: [String]) -> [String] { b.filter { !$0.hasPrefix("secure input") && !$0.hasPrefix("a menu is open") } }
    let windowChanged = before.windowTitle != after.windowTitle || structural(before.blockers) != structural(after.blockers)
    // A walk that stopped early, or failed to read a node or its text, can't tell a row that went away from one it
    // never reached or couldn't name.
    let incomplete = !after.stats.textComplete
    let diff = Diff.compute(before: before.rows, after: after.rows, showDisappeared: !incomplete)
    var shownRows: [Row]
    if windowChanged || diff.lines.count > 25 {
        // A sheet appeared, the window changed, or most of it did: show the new state rather than a long diff.
        lines.append("--- the UI changed substantially; current state:")
        lines += after.lines.dropFirst(3)   // rows, without the repeated header
        lines += after.notes.map { "… " + $0 }
        shownRows = after.shownRows
    } else {
        lines.append(diff.lines.isEmpty ? "changes: none visible in this window" : "changes:")
        lines += diff.lines
        if incomplete {
            lines.append("… the walk after the action was incomplete (" + incompleteReason(after.stats) + "), "
                + "so rows that disappeared aren't listed; take mac_snapshot to confirm the state")
        }
        let shown = Set(diff.refs)
        shownRows = after.rows.filter { $0.ref.map(shown.contains) ?? false }
    }
    return (head + "\n" + Untrusted.wrap(lines: lines), shownRows)
}

/// Why a walk can't vouch for absence, for the diff's note: the first of a cut, unread elements, unread text.
func incompleteReason(_ stats: WalkStats) -> String {
    if stats.truncated { return "it stopped early" }
    if stats.readFailures > 0 { return "\(stats.readFailures) elements could not be read" }
    return "the labels or values of \(stats.textReadFailures) elements could not be read"
}

/// Shared argument parsing for targets.
func target(from args: ToolArgs, prefix: String = "") async throws -> Target? {
    let ref = args.string(prefix + "ref"), x = args.int(prefix + "x"), y = args.int(prefix + "y")
    if ref == nil, x == nil, y == nil { return nil }
    return try Actions.target(ref: ref, x: x, y: y, screenshotID: args.string("screenshot_id"))
}

let targetProperties: [String: Value] = [
    "ref": Prop.string("Element ref from mac_snapshot (e.g. e12). Preferred."),
    "x": Prop.integer("Instead of ref: x in screen points, or a pixel x in the screenshot given by screenshot_id."),
    "y": Prop.integer("Instead of ref: y in screen points, or a pixel y in the screenshot given by screenshot_id."),
    "screenshot_id": Prop.string("Interpret x,y as pixels of this mac_screenshot (e.g. c3)."),
    "app": Prop.string("App name or bundle ID, when the target isn't a ref. Default: the frontmost app. With x,y: "
        + "the app the point is in; it's brought to the front, and the action is refused if another app covers the point."),
]
