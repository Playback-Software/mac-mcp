import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One keyboard, one mouse: actions run one at a time, in arrival order.
///
/// Each hold has a deadline. When it passes, the holder is abandoned (cancelled, see `Deadline`), the lock moves on
/// to the next waiter after its input has stopped. Wedged AX requests can be abandoned without overlapping input.
/// Waiting is bounded too: a call that can't get the lock within `maxWait` gives up without running.
public actor ActionLock {
    public static let shared = ActionLock()

    public struct Status: Sendable {
        public let holder: String?
        /// How long the current holder has had the lock, by system uptime (which doesn't count time asleep).
        public let heldFor: TimeInterval?
        public let deadline: TimeInterval?
        public let waiting: Int
        public let abandoned: Int
    }

    private var generation: UInt64 = 0
    private var holder: (generation: UInt64, name: String, since: TimeInterval, deadline: TimeInterval?)?
    private var waiters: [(id: UInt64, name: String, continuation: CheckedContinuation<UInt64?, Never>)] = []
    private var nextWaiter: UInt64 = 0
    private var abandoned = 0

    public init() {}

    /// Runs `body` holding the lock. Throws `ActionLockBusy` if the lock isn't free within `maxWait`, and
    /// `DeadlineExceeded` if `body` outlives `deadline` (waiting doesn't count toward it).
    public func run<T: Sendable>(_ name: String = "action", deadline: TimeInterval = 20, maxWait: TimeInterval = 30,
                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let mine = await acquire(name, maxWait: maxWait) else {
            throw ActionLockBusy(name: name, holder: holder?.name, waited: maxWait)
        }
        let input = Input.Session()
        let result: T?
        do {
            try Task.checkCancellation()   // gave up while queued: don't act late
            holder?.deadline = ProcessInfo.processInfo.systemUptime + deadline
            result = try await Deadline.run(deadline) {
                try await ActionAdmission.check?()
                try Task.checkCancellation()
                return try await Input.$session.withValue(input) { try await body() }
            }
        } catch {
            await finishInput(input, generation: mine)
            throw error
        }
        await finishInput(input, generation: mine)
        guard let result else {
            abandoned += 1
            throw DeadlineExceeded(name, seconds: deadline)
        }
        return result
    }

    private func finishInput(_ input: Input.Session, generation: UInt64) async {
        input.revoke()
        // Cleanup is independent of the caller's cancellation. If an AX guard is wedged, keep the lock held
        // rather than let a later action overlap its eventual release. The caller's wait is still bounded.
        let drained = await Task.detached {
            for _ in 0..<300 {
                if input.drained { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return input.drained
        }.value
        if drained { release(generation) }
        else {
            // A wedged AX guard deliberately keeps the lock past deadline + 15 s so the watchdog restarts us.
            Task {
                while !input.drained { try? await Task.sleep(for: .milliseconds(100)) }
                self.release(generation)
            }
        }
    }

    public var status: Status {
        Status(holder: holder?.name, heldFor: holder.map { ProcessInfo.processInfo.systemUptime - $0.since },
               deadline: holder?.deadline, waiting: waiters.count, abandoned: abandoned)
    }

    /// The lock's generation, or nil if it didn't come free within `maxWait`.
    private func acquire(_ name: String, maxWait: TimeInterval) async -> UInt64? {
        if holder == nil { return take(name) }
        nextWaiter &+= 1
        let id = nextWaiter
        Task {
            try? await Task.sleep(for: .milliseconds(Int(maxWait * 1000)))
            self.expire(id)
        }
        return await withCheckedContinuation { waiters.append((id, name, $0)) }
    }

    private func expire(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }   // already holds it
        waiters.remove(at: i).continuation.resume(returning: nil)
    }

    private func take(_ name: String) -> UInt64 {
        generation &+= 1
        holder = (generation, name, ProcessInfo.processInfo.systemUptime, nil)
        return generation
    }

    /// Hands the lock straight to the next waiter: it's never free in between, where a newcomer could jump the queue.
    private func release(_ g: UInt64) {
        guard holder?.generation == g else { return }   // a stale holder; the lock already moved on
        holder = nil
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.continuation.resume(returning: take(next.name))
    }
}

/// A request installs its admission check here so queued actions revalidate after taking the action lock.
public enum ActionAdmission {
    @TaskLocal public static var check: (@Sendable () async throws -> Void)?
}

/// A call gave up waiting for the action lock; it did not run.
public struct ActionLockBusy: Error, CustomStringConvertible {
    public let name: String
    public let holder: String?
    public let waited: TimeInterval
    public var description: String {
        "\(name) waited \(Int(waited)) s for its turn (another action, \(holder ?? "?"), had the keyboard and mouse) "
            + "and did not run. Retry; if this keeps happening, another client may be driving this Mac (see mac_doctor)."
    }
}

public struct ActionError: Error, CustomStringConvertible {
    public let description: String
    public let audit: String?
    public init(_ d: String, audit: String? = nil) { description = d; self.audit = audit }
}

/// Where an action should land: a ref from a snapshot, a point in screen points, or pixels of a screenshot.
public enum Target: Sendable {
    case ref(String)
    case point(CGPoint)
    /// Converted to a point only when the action runs (under the action lock), so the screenshot is checked against
    /// the screen as it is then, not as it was while the call waited its turn.
    case pixel(screenshot: String, CGPoint)
}

/// Pixels of a screenshot, kept with a resolved target so the conversion can be redone after its app is activated.
public struct PixelTarget: Sendable, Equatable {
    public let screenshot: String
    public let pixel: CGPoint
    public init(screenshot: String, pixel: CGPoint) { self.screenshot = screenshot; self.pixel = pixel }
}

/// A resolved target, ready to act on.
public struct Resolved: Sendable {
    public let pid: pid_t
    public let element: AXElement?
    public let row: Row?
    /// For a screenshot target, the point as of resolution; the action converts the pixels again after activating
    /// the app (`actionPoint`), since activation can move or resize the window.
    public let point: CGPoint?
    public let pixel: PixelTarget?

    public init(pid: pid_t, element: AXElement?, row: Row?, point: CGPoint?, pixel: PixelTarget? = nil) {
        self.pid = pid
        self.element = element
        self.row = row
        self.point = point
        self.pixel = pixel
    }

    /// For the agent: the label is the app's own text, so it is marked.
    public var describe: String {
        if let row { return [row.ref, row.role, row.label.isEmpty ? nil : Untrusted.inline(row.label)].compactMap { $0 }.joined(separator: " ") }
        if let point { return "point \(point.x.safeInt),\(point.y.safeInt)" }
        return "target"
    }

    /// For the audit log: which element was acted on (ref and role), without anything read from the screen.
    public var auditName: String {
        if let row { return [row.ref, row.role].compactMap { $0 }.joined(separator: " ") }
        if let point { return "point \(point.x.safeInt),\(point.y.safeInt)" }
        return "target"
    }
}

/// What an action did. `text` goes to the agent and marks any screen text in it; `audit` is the same fact for the
/// log, with the role and ref of what was touched but nothing read from the screen (tooltips, labels, titles).
public struct ActionSummary: Sendable {
    public let text: String
    public let audit: String
    public init(_ text: String, audit: String? = nil) { self.text = text; self.audit = audit ?? text }
}

public enum Actions {
    // MARK: Targets

    /// Turns tool arguments into a target. x,y are screen points, or pixels of `screenshotID` when given. Pixels are
    /// kept as such: `resolve` converts and validates them at action time.
    public static func target(ref: String?, x: Int?, y: Int?, screenshotID: String?) throws -> Target {
        if let ref, !ref.isEmpty { return .ref(ref) }
        guard let x, let y else { throw ActionError("Pass ref (from mac_snapshot) or x and y.") }
        if let id = screenshotID, !id.isEmpty { return .pixel(screenshot: id, CGPoint(x: x, y: y)) }
        return .point(CGPoint(x: x, y: y))
    }

    /// The screen point under a screenshot pixel, if the screenshot still maps to what's on screen. `windows` is
    /// the current on-screen list (injectable for tests). An action queued behind another one can find the window
    /// moved or resized by the time it runs, so this is called when the action runs, never when it is parsed.
    public static func point(ofPixel px: CGPoint, screenshot id: String, store: ScreenshotStore = .shared,
                             windows: [WindowInfo]? = nil) async throws -> CGPoint {
        guard let m = await store.mapping(id) else { throw ActionError(await store.missingMessage(id)) }
        if let stale = m.staleReason(id: id, windows: windows ?? WindowServer.onScreenWindows()) { throw ActionError(stale) }
        guard m.contains(pixel: px) else {
            throw ActionError("Pixel \(px.x.safeInt),\(px.y.safeInt) is outside screenshot \(id) "
                + "(\(m.pixelSize.width.safeInt)x\(m.pixelSize.height.safeInt) px).")
        }
        return m.point(forPixel: px)
    }

    /// The process an action will affect, for the before/after snapshots.
    public static func pid(for target: Target?, app: String?) async throws -> pid_t {
        if case let .ref(r)? = target {
            guard let e = await RefStore.shared.entry(r) else { throw ActionError(await RefStore.shared.missingMessage(r)) }
            return e.pid
        }
        // For a point, app= names the app the point is meant to be in (checked once resolved); without it, the
        // point's own app.
        if let app { return try Apps.resolve(app).pid }
        if case let .point(p)? = target, let owner = pointOwner(p) { return owner }
        if case let .pixel(id, px)? = target, let owner = pointOwner(try await point(ofPixel: px, screenshot: id)) { return owner }
        guard let front = Apps.frontmost() else { throw ActionError("No frontmost app; pass app=.") }
        return front.pid
    }

    /// Who a click at `p` would reach: the window server's answer, else accessibility's.
    static func pointOwner(_ p: CGPoint) -> pid_t? {
        WindowServer.owner(at: p) ?? AXElement.systemWide.element(at: p)?.pid
    }

    /// Resolves a target against the UI as it is now. Call after a fresh snapshot of the target's app: a ref that the
    /// snapshot re-found is current; one it didn't is stale unless its element still exists (e.g. scrolled offscreen).
    /// Either way the element must still read as the agent last saw it: a reused list row or a renamed control is
    /// refused rather than acted on (`RefStore.changeMessage`). Each row records whether its own read was cut short
    /// or lost a label source (`Row.identityUncertain`); that, not the whole walk's completeness, decides whether an
    /// empty label can be trusted, so a snapshot truncated elsewhere in a large app doesn't refuse every unnamed
    /// control.
    public static func resolve(_ target: Target, currentSnapshot: Int) async throws -> Resolved {
        switch target {
        case let .point(p):
            // Off every display nothing owns the point, which later checks would misreport as the app having quit.
            var displays: UInt32 = 0
            guard CGGetDisplaysWithPoint(p, 0, nil, &displays) == .success, displays > 0 else {
                throw ActionError("Point \(p.x.safeInt),\(p.y.safeInt) is off every display. Use coordinates from a "
                    + "mac_screenshot or a frame from mac_snapshot.")
            }
            return Resolved(pid: pointOwner(p) ?? 0, element: nil, row: nil, point: p)
        case let .pixel(id, px):
            let p = try await point(ofPixel: px, screenshot: id)
            return Resolved(pid: pointOwner(p) ?? 0, element: nil, row: nil, point: p, pixel: PixelTarget(screenshot: id, pixel: px))
        case let .ref(r):
            guard let entry = await RefStore.shared.entry(r) else { throw ActionError(await RefStore.shared.missingMessage(r)) }
            if entry.snapshot == currentSnapshot, let el = entry.element {
                // The snapshot just re-read this element, so its row is current.
                if let changed = RefStore.changeMessage(ref: r, role: entry.row.role, shown: entry.shown,
                                                        label: entry.row.label, identifier: entry.row.identifier,
                                                        complete: !entry.row.identityUncertain) {
                    throw ActionError(changed)
                }
                return Resolved(pid: entry.pid, element: el, row: entry.row, point: nil)
            }
            if let el = entry.element, el.isAlive {
                guard let now = currentIdentity(of: el) else {
                    throw ActionError("Ref \(r)'s app isn't answering accessibility requests right now (busy or hung). "
                        + "Wait, then retry or take a new mac_snapshot.")
                }
                if now.role == entry.row.role {
                    if let changed = RefStore.changeMessage(ref: r, role: now.role, shown: entry.shown,
                                                            label: now.label, identifier: now.identifier, complete: now.complete) {
                        throw ActionError(changed)
                    }
                    return Resolved(pid: entry.pid, element: el, row: entry.row, point: nil)   // exists, just not in view
                }
            }
            throw ActionError("Ref \(r) (\(entry.row.role) \(Untrusted.inline(entry.row.label))) no longer exists: the UI changed. "
                + "Call mac_snapshot and use the new refs.")
        }
    }

    /// How an element reads right now, the way a snapshot would label it, or nil if it can't be read (gone, or its
    /// app isn't answering). A row's label is the text of its cells, so this walks a small subtree rather than
    /// reading one element. `complete` is false when that walk stopped early, some of it failed to read, or a label
    /// source or identifier failed to read: the label or identifier may then be missing or cut, which
    /// `RefStore.changeMessage` treats as unknown rather than unchanged.
    static func currentIdentity(of element: AXElement) -> (role: String, label: String, identifier: String?, complete: Bool)? {
        var options = Walker.Options()
        options.maxNodes = 60
        options.timeLimit = 1
        let (tree, stats) = Walker.walk(element, options: options)
        guard tree.element != nil else { return nil }   // the root read failed
        let node = Snapshot.sanitized(tree)
        return (Snapshot.shortRole(node.role, subrole: node.subrole), Snapshot.label(node), node.identifier,
                stats.complete && !node.identityUncertain)
    }

    /// The screen point a point target means now. A screenshot target is converted from its pixels again here,
    /// after the app was activated: resolution converted them before, and activation can move or resize the window
    /// (an app that restores its window position on activation), which the staleness check must see.
    static func actionPoint(_ r: Resolved, store: ScreenshotStore = .shared, windows: [WindowInfo]? = nil) async throws -> CGPoint {
        if let px = r.pixel { return try await point(ofPixel: px.pixel, screenshot: px.screenshot, store: store, windows: windows) }
        guard let p = r.point else { throw ActionError("Nothing to act on.") }
        return p
    }

    /// Activates, then converts: the order matters, so it is one step. `activate` brings the target's app forward.
    static func activatedPoint(_ r: Resolved, store: ScreenshotStore = .shared, windows: () -> [WindowInfo]? = { nil },
                               activate: () async throws -> Void) async throws -> CGPoint {
        try await activate()
        return try await actionPoint(r, store: store, windows: windows())
    }

    /// Brings a point target's app forward (a ref target's app is raised by `bringForward`).
    static func activateOwner(of r: Resolved) async {
        if r.pid != 0, NSWorkspace.shared.frontmostApplication?.processIdentifier != r.pid,
           let running = NSRunningApplication(processIdentifier: r.pid) {
            _ = await AppControl.activate(AppInfo(running))
        }
    }

    // MARK: Focus

    /// Brings the target's app (and window) to the front before synthesized input.
    static func bringForward(_ r: Resolved) async throws {
        guard let running = NSRunningApplication(processIdentifier: r.pid), !running.isTerminated else {
            throw ActionError("The target app quit. Open it and take a new mac_snapshot before sending input.")
        }
        if let el = r.element, let window = el.element(kAXWindowAttribute) {
            if window.attribute(kAXMinimizedAttribute) as? Bool == true { window.set(kAXMinimizedAttribute, kCFBooleanFalse as Any) }
            window.perform(kAXRaiseAction)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != r.pid {
            guard await AppControl.activate(AppInfo(running)) else {
                throw ActionError("\(running.localizedName ?? "The app") would not come to the front, so input would go "
                    + "elsewhere. Check mac_snapshot blockers (a modal dialog in another app?).")
            }
        }
    }

    // MARK: Modal guard

    /// Why an element can't be acted on because a sheet or modal dialog of its app blocks it, or nil. Accessibility
    /// presses reach controls behind a sheet (a person's clicks don't), and doing so can wedge the app: a pop-up
    /// opened behind an alert left the alert unable to close (M10, L11).
    public static func modalBlocker(of element: AXElement, pid: pid_t) -> String? {
        guard let window = element.element(kAXWindowAttribute) else { return nil }
        let app = AXElement.application(pid: pid)
        var blocker: AXElement?
        if window.role != "AXSheet", let sheet = window.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSheet" }) {
            blocker = sheet
        } else if let modal = app.elements(kAXWindowsAttribute).first(where: { w in
            w != window && w.attribute("AXModal") as? Bool == true && w.attribute(kAXMinimizedAttribute) as? Bool != true
        }) {
            blocker = modal
        }
        guard let blocker, !isWithin(element, blocker) else { return nil }
        let name = blocker.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? Snapshotter.sheetHeading(blocker)
        return modalRefusal(name)
    }

    /// The dialog's title is the app's own text, so it's marked.
    static func modalRefusal(_ name: String?) -> String {
        "Refused: \(name.map { Untrusted.inline($0) } ?? "a dialog") is open in front of that control and has to be answered first "
            + "(a person couldn't click behind it either). Take mac_snapshot to see its buttons."
    }

    // MARK: Hit-test guard

    /// Is `hit` the target itself or inside it?
    static func isWithin(_ hit: AXElement, _ target: AXElement) -> Bool {
        var e: AXElement? = hit
        for _ in 0..<512 {
            guard let cur = e else { return false }
            if cur == target { return true }
            e = cur.element(kAXParentAttribute)
        }
        return false
    }

    public enum PressOutcome: Equatable, Sendable { case pressed, unanswered, failed }

    /// What an AXPress result means. A press that opens a sheet, a menu or a popover runs the app's modal loop, so the
    /// app often doesn't answer before the timeout (`cannotComplete`) although the press took effect. Clicking again
    /// with the mouse would then press twice (two New Folder sheets), so only a real failure falls through to it.
    public static func pressOutcome(_ result: AXError, cancelled: Bool) -> PressOutcome {
        if result == .success { return .pressed }
        if result == .cannotComplete, !cancelled { return .unanswered }
        return .failed
    }

    /// Ancestors whose hit-test result still counts against a control inside them. Any other ancestor in the same
    /// window says nothing against it: accessibility often reports the sheet or split view around a button, or the
    /// view hosting a web page (WebKit's hit test doesn't always descend into the page), and a container can't cover
    /// its own descendant. Viewports are different: a row scrolled out of one is hit as the viewport itself. The
    /// application is above every window.
    static let coveringAncestorRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXApplication"]

    static let clippingRoles: Set<String> = [
        "AXScrollArea", "AXWebArea", "AXWindow",
    ]

    static func visibleRect(_ target: CGRect, clips: [CGRect]) -> CGRect {
        clips.reduce(target) { $0.intersection($1) }
    }

    static func frameOf(_ element: AXElement) -> CGRect? {
        let values = element.read([kAXPositionAttribute, kAXSizeAttribute]) ?? [:]
        return frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute])
    }

    /// Structural groups can have visible overflow or empty frames; only viewports clip their descendants.
    static func clippingAncestors<Node: Hashable>(of node: Node, parent: (Node) -> Node?, role: (Node) -> String?) -> [Node] {
        var clips: [Node] = [], content: [Node] = [], current = parent(node), seen: Set<Node> = [node]
        for _ in 0..<512 {
            guard let e = current, seen.insert(e).inserted else { break }
            let role = role(e) ?? ""
            if ["AXList", "AXTable", "AXOutline"].contains(role) { content.append(e) }
            if role == "AXScrollArea" { clips += content; content.removeAll() }
            if clippingRoles.contains(role) { clips.append(e) }
            current = parent(e)
        }
        return clips
    }

    struct ClipChain: Sendable {
        let elements: [AXElement]
        init(_ element: AXElement) {
            elements = clippingAncestors(of: element, parent: { $0.element(kAXParentAttribute) }, role: { $0.role })
        }
        func visible(_ frame: CGRect) -> CGRect {
            var clips = [Walker.screenBounds]
            for element in elements {
                guard let f = frameOf(element) else { return .null }
                clips.append(f)
            }
            return visibleRect(frame, clips: clips)
        }
    }

    static func visibleFrame(of element: AXElement, frame: CGRect) -> CGRect {
        ClipChain(element).visible(frame)
    }

    static func pointerReaches(targetPID: pid_t, targetWindow: pid_t?, owner: pid_t?, hitPID: pid_t?, hitWindow: pid_t?, remoteOwner: Bool) -> Bool {
        let host = targetWindow ?? targetPID
        let hitHost = hitWindow ?? hitPID
        guard hitHost == host else { return false }
        return owner == host || owner == targetPID || (remoteOwner && owner == hitPID)
    }

    static func pointerReaches(_ hit: AXElement, _ target: AXElement?, pid: pid_t, at point: CGPoint, windows: [WindowInfo]) -> Bool {
        let owner = WindowServer.owner(at: point, in: windows)
        return pointerReaches(targetPID: pid, targetWindow: target.flatMap { Input.windowOwner(of: $0) }, owner: owner,
                              hitPID: hit.pid, hitWindow: Input.windowOwner(of: hit),
                              remoteOwner: owner.map { Input.isRemoteService($0) } ?? false)
    }

    static func hitReaches(hitWithinTarget: Bool, targetWithinHit: Bool, hitRole: String, point: CGPoint, visible: CGRect) -> Bool {
        visible.contains(point) && (hitWithinTarget || (targetWithinHit && !coveringAncestorRoles.contains(hitRole)))
    }

    static func reaches(_ hit: AXElement, _ target: AXElement, at point: CGPoint, visible: CGRect) -> Bool {
        hitReaches(hitWithinTarget: isWithin(hit, target), targetWithinHit: isWithin(target, hit),
                   hitRole: hit.role ?? "", point: point, visible: visible)
    }

    /// A point inside the element where a click would land on it (not on something covering it).
    static func clickPoint(for element: AXElement, row: Row?, pid: pid_t) async throws -> CGPoint {
        var f = try await Input.guardWork { frameOf(element) }
        // Off every display, or partly above the top of the desktop (scrolled up out of view). Not `minY < 0`: a
        // display arranged above the main one has negative y throughout.
        if let frame0 = f, !frame0.intersects(Walker.screenBounds) || frame0.minY < Walker.screenBounds.minY {
            element.perform("AXScrollToVisible")
            try await Task.sleep(for: .milliseconds(150))
            f = try await Input.guardWork { frameOf(element) }
        }
        guard let frame = f, frame.width > 0, frame.height > 0 else {
            throw ActionError("\(row.map { "\($0.role) \(Untrusted.inline($0.label))" } ?? "The element") has no on-screen frame; it may be hidden or collapsed.")
        }
        return try await Input.guardWork { try clickPointNow(for: element, row: row, frame: frame, pid: pid) }
    }

    static func clickPointNow(for element: AXElement, row: Row?, frame: CGRect, pid: pid_t) throws -> CGPoint {
        let windows = WindowServer.onScreenWindows()
        if !WindowServer.systemPrompts(in: windows).isEmpty { throw ActionError(Input.promptRefusal) }
        let visible = visibleFrame(of: element, frame: frame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            throw ActionError("\(row.map { "\($0.role) \(Untrusted.inline($0.label))" } ?? "The element") is off screen and couldn't be scrolled into view. "
                + "Try mac_scroll to_ref first.")
        }
        let candidates = [CGPoint(x: visible.midX, y: visible.midY),
                          CGPoint(x: visible.minX + visible.width * 0.25, y: visible.midY),
                          CGPoint(x: visible.minX + visible.width * 0.75, y: visible.midY),
                          CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.3),
                          CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.7)]
        var blocker: AXElement?
        for p in candidates {
            guard let hit = Input.systemElement().element(at: p) else { continue }
            if pointerReaches(hit, element, pid: pid, at: p, windows: windows),
               reaches(hit, element, at: p, visible: visible) { return p }
            blocker = blocker ?? hit
        }
        let what = blocker.map { b -> String in
            let v = b.read(["AXRole", "AXTitle", "AXDescription"]) ?? [:]
            let app = NSRunningApplication(processIdentifier: b.pid)?.localizedName ?? "another app"
            return "\(Snapshot.shortRole(v["AXRole"] as? String ?? "?", subrole: nil)) "
                + "\(Untrusted.inline((v["AXTitle"] ?? v["AXDescription"]) as? String ?? "")) of \(app)"
        } ?? "something else"
        throw ActionError("Not clicking: \(row.map { "\($0.ref ?? "") \($0.role) \(Untrusted.inline($0.label))" } ?? "the target") is covered by \(what). "
            + "Close or move what's on top, or check mac_snapshot blockers.")
    }

    // MARK: Primitives

    static let synthesizeRoles: Set<String> = ["AXRow", "AXCell", "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXGroup"]

    /// Clicks. Prefers the accessibility press (no cursor movement, works when partly covered); falls back to a mouse
    /// click at a hit-tested point. Returns how it clicked.
    public static func click(_ r: Resolved, button: Input.Button, count: Int, modifiers: CGEventFlags) async throws -> String {
        try await Input.check(pid: r.pid)
        if let el = r.element {
            let role = el.role ?? ""
            if button == .left, count == 1, modifiers.isEmpty, !synthesizeRoles.contains(role), el.actionNames.contains(kAXPressAction) {
                try await Input.check(pid: r.pid, route: .target(el, point: nil, pid: r.pid, opens: false))
                let result = el.perform(kAXPressAction)
                switch pressOutcome(result, cancelled: Task.isCancelled) {
                case .pressed: return "accessibility press"
                case .unanswered:
                    return "accessibility press (the app didn't reply in time; it may be showing a sheet or menu, so check the "
                        + "snapshot before pressing again)"
                case .failed: break
                }
            }
            if button == .right, modifiers.isEmpty, el.actionNames.contains(kAXShowMenuAction) {
                try await Input.check(pid: r.pid, route: .target(el, point: nil, pid: r.pid, opens: false))
                if el.perform(kAXShowMenuAction) == .success { return "accessibility show-menu" }
            }
            try await bringForward(r)
            let p = try await clickPoint(for: el, row: r.row, pid: r.pid)
            try await Input.click(at: p, button: button, count: count, modifiers: modifiers, pid: r.pid)
            return "mouse \(button.rawValue)\(count > 1 ? " ×\(count)" : "") at \(p.x.safeInt),\(p.y.safeInt)"
        }
        guard r.point != nil else { throw ActionError("Nothing to click.") }
        let p = try await activatedPoint(r) { await activateOwner(of: r) }
        try await Input.click(at: p, button: button, count: count, modifiers: modifiers, pid: r.pid)
        return "mouse \(button.rawValue)\(count > 1 ? " ×\(count)" : "") at \(p.x.safeInt),\(p.y.safeInt)"
    }

    public enum TypeMode: String, Sendable { case replace, append, insert }

    public static func typingMode(_ mode: String?, hasRef: Bool) -> TypeMode {
        mode.flatMap(TypeMode.init(rawValue:)) ?? (hasRef ? .replace : .insert)
    }

    /// Focuses the field (if given), types, and reads the value back. Returns a note for the response.
    public static func type(_ r: Resolved?, pid: pid_t, text: String, mode: TypeMode, submit: Bool) async throws -> String {
        let app = AXElement.application(pid: pid)
        var field = r?.element
        if let r, let el = r.element {
            try await bringForward(r)
            el.set(kAXFocusedAttribute, kCFBooleanTrue as Any)
            try await Task.sleep(for: .milliseconds(80))
            let focused = app.element(kAXFocusedUIElementAttribute)
            if focused.map({ !isWithin($0, el) && !isWithin(el, $0) }) ?? true {
                let p = try await clickPoint(for: el, row: r.row, pid: r.pid)   // some fields only take focus from a click
                try await Input.click(at: p, pid: pid)
                try await Task.sleep(for: .milliseconds(120))
            }
            let nowFocused = app.element(kAXFocusedUIElementAttribute)
            guard let nowFocused, isWithin(nowFocused, el) || isWithin(el, nowFocused) else {
                throw ActionError("Could not focus \(r.describe); typing would go elsewhere. Click it first or check blockers.")
            }
            field = nowFocused
        } else {
            // Keystrokes go to the frontmost app, so the app whose focus was read must be the one in front.
            try await bringForward(Resolved(pid: pid, element: nil, row: nil, point: nil))
            field = app.element(kAXFocusedUIElementAttribute)
        }
        try await Input.check(pid: pid, keyboard: true)
        let secure = field?.subrole == "AXSecureTextField"
        let hidden = field.map(hidesItsText) ?? false
        let original = secure || hidden ? nil : field?.attribute(kAXValueAttribute) as? String
        try await ActionRoute.validate(.typing(text, mode: mode, pid: pid))
        if mode == .replace {
            // ⌘A and the text's own newlines and tabs are one run of keys to the checks.
            let sequence = OpenRoutes.typedKeys(text, replacing: true).map { ActionRoute.KeySequence(keys: $0, index: 0, typed: true) }
            try await ActionRoute.$keySequence.withValue(sequence) { try await Input.press(try KeySpec.parse("cmd+a"), pid: pid) }
        } else if mode == .append {
            // Selected text ranges use UTF-16 offsets, including for emoji and composed characters.
            var range = CFRange(location: original?.utf16.count ?? 0, length: 0)
            let placed = original != nil && field.map { field in
                guard let value = AXValueCreate(.cfRange, &range) else { return false }
                return field.set(kAXSelectedTextRangeAttribute, value) == .success
            } == true
            try requireAppendCaret(placed)
        }
        let selection = mode == .insert ? field?.attribute(kAXSelectedTextRangeAttribute) as? CFRange : nil
        let expected = expectedTypedValue(original: original, text: text, mode: mode, selection: selection)
        try await Input.type(text, pid: pid, replacing: mode == .replace)
        try await Task.sleep(for: .milliseconds(100))
        let value = secure || hidden ? nil : field?.attribute(kAXValueAttribute) as? String
        let verified = try await verifyAndSubmit(value: value, expected: expected, typedCount: text.count, submit: submit, previouslyReadable: original != nil) {
            try await Input.press(try KeySpec.parse("return"), pid: pid)
        }
        if !verified {
            let reason: String
            if secure { reason = "password field" }
            else if hidden { reason = "this editor hides its text from accessibility" }
            else if expected == nil, original != nil { reason = "the caret position isn't readable" }
            else { reason = "the field's value isn't readable" }
            return "typed \(text.count) characters" + (submit ? " and submitted unverified" : " unverified") + " (\(reason))"
                + (hidden ? "; check with mac_screenshot ocr=true before typing again" : "")
        }
        let hint = field.flatMap { savePanelNameHint(fieldLabel: $0.string(kAXTitleAttribute), typed: text) }
        return "typed \(text.count) characters; field value verified" + (submit ? "; pressed Return" : "")
            + (hint.map { ". " + $0 } ?? "")
    }

    static func requireAppendCaret(_ placed: Bool) throws {
        guard placed else {
            throw ActionError("Can't place the caret at the end of this field; click where to type, then call mac_type without mode.")
        }
    }

    public static func expectedTypedValue(original: String?, text: String, mode: TypeMode, selection: CFRange? = nil) -> String? {
        switch mode {
        case .replace: return text
        case .append: return original.map { $0 + text }
        case .insert:
            guard let original, let selection, selection.location >= 0, selection.length >= 0,
                  selection.location <= original.utf16.count, selection.length <= original.utf16.count - selection.location else { return nil }
            return (original as NSString).replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text)
        }
    }

    /// Verification must finish before Return can commit a value or dismiss the field.
    static func verifyAndSubmit(value: String?, expected: String?, typedCount: Int, submit: Bool, previouslyReadable: Bool = false,
                                pressReturn: () async throws -> Void) async throws -> Bool {
        if previouslyReadable, value == nil {
            throw ActionError("The field could not be read back to verify typing. Return was not pressed. Check mac_snapshot before retrying.")
        }
        let verified: Bool
        if let value, let expected {
            try verifyTypedValue(value, expected: expected, mode: .replace, typedCount: typedCount)
            verified = true
        } else { verified = false }
        if submit { try await pressReturn() }
        return verified
    }

    /// A Save dialog's name field is a file name, not a path: macOS turns each "/" into ":" when saving, so typing a
    /// full path there creates a file literally named ":Users:you:Desktop:x.txt" (agents did this in evaluations).
    static func savePanelNameHint(fieldLabel: String?, typed: String) -> String? {
        guard typed.contains("/"), let label = fieldLabel?.lowercased(),
              label.hasPrefix("save as") || label.hasPrefix("name") else { return nil }
        return "Note: this looks like a Save dialog's name field. macOS turns \"/\" in a file name into \":\", so a path "
            + "typed here becomes one odd file name. Clear it, choose the folder with ⇧⌘G (Go to Folder) or the "
            + "sidebar, then type only the file name."
    }

    static func verifyTypedValue(_ value: String, expected text: String, mode: TypeMode, original: String? = nil,
                                 typedCount: Int? = nil) throws {
        let expected = expectedTypedValue(original: original, text: text, mode: mode)
        guard let expected, norm(value) == norm(expected) else {
            throw ActionError("Typed \(typedCount ?? text.count) characters, but the field value did not match the expected text. "
                + "Some characters may have been dropped or autocorrected; check and retry.")
        }
    }

    /// Editors whose accessible value isn't their text: VS Code / Monaco without screen-reader mode, which labels
    /// its textarea "The editor is not accessible at this time…".
    static func hidesItsText(_ field: AXElement) -> Bool {
        let v = field.read([kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]) ?? [:]
        return v.values.contains { ($0 as? String)?.localizedCaseInsensitiveContains("editor is not accessible") == true }
    }

    // AX text controls can report CR or CRLF for Return. Spaces and boundary newlines remain meaningful.
    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }

    public static func keys(_ specs: [KeySpec], repeat count: Int, pid: pid_t) async throws {
        if let refusal = OpenRoutes.keySequenceRefusal(specs, repeat: count) { throw ActionError(refusal, audit: "Refused: key sequence") }
        try await bringForward(Resolved(pid: pid, element: nil, row: nil, point: nil))
        try await press(specs, repeat: count, pid: pid)
    }

    /// Each key's route check sees the whole call, so a later key that needs its own call is refused before the first.
    static func press(_ specs: [KeySpec], repeat count: Int, pid: pid_t) async throws {
        let sequence = Array(repeating: specs, count: max(count, 0)).flatMap { $0 }
        for (index, spec) in sequence.enumerated() {
            try await ActionRoute.$keySequence.withValue(ActionRoute.KeySequence(keys: sequence, index: index)) {
                try await Input.press(spec, pid: pid)
            }
        }
    }

    /// Injectable event sink lets tests verify sequence order without sending input to the desktop.
    static func keys(_ specs: [KeySpec], repeat count: Int, press: (KeySpec) -> Void) {
        for _ in 0..<max(count, 0) {
            for spec in specs {
                guard !Task.isCancelled else { return }
                press(spec)
            }
        }
    }

    /// Picks a menu item by path, through accessibility only. Lists the available items when a step doesn't match.
    public static func menu(pid: pid_t, path: [String]) async throws -> String {
        let app = AXElement.application(pid: pid)
        // While another menu is open (a pop-up left open), macOS is tracking it and menu-bar commands don't run.
        for _ in 0..<3 where Snapshotter.menuIsOpen(app) {
            try await Input.press(KeySpec(key: 53, flags: []), pid: pid)   // esc
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let bar = app.element(kAXMenuBarAttribute) else { throw ActionError("This app has no menu bar.") }
        func matches(_ el: AXElement, _ name: String) -> Bool {
            let t = (el.string(kAXTitleAttribute) ?? "").lowercased()
                .replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
            let q = name.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
            return t == q
        }
        func titles(_ items: [AXElement]) -> String {
            Untrusted.inline(items.compactMap { $0.string(kAXTitleAttribute) }.filter { !$0.isEmpty }.map { "\"\($0)\"" }.joined(separator: ", "),
                             limit: 600)
        }
        var level = bar.elements(kAXChildrenAttribute)
        var current: AXElement?
        var walked: [String] = []
        for (i, name) in path.enumerated() {
            guard let item = level.first(where: { matches($0, name) }) else {
                throw ActionError("No menu item \"\(name)\" under \(walked.isEmpty ? "the menu bar" : Untrusted.inline(walked.joined(separator: " > "))). "
                    + "Available: \(titles(level)).")
            }
            walked.append(item.string(kAXTitleAttribute) ?? name)
            current = item
            if i < path.count - 1 {
                var submenu = item.elements(kAXChildrenAttribute).first
                var items = submenu?.elements(kAXChildrenAttribute) ?? []
                if items.isEmpty {   // menus some apps build only when opened
                    try await Input.check(pid: pid, route: .target(item, point: nil, pid: pid, opens: false))
                    item.perform(kAXPressAction)
                    try await Task.sleep(for: .milliseconds(250))
                    submenu = item.elements(kAXChildrenAttribute).first
                    items = submenu?.elements(kAXChildrenAttribute) ?? []
                }
                level = items
            }
        }
        guard let target = current else { throw ActionError("Empty menu path.") }
        // The path was checked by title before; what it led to is checked again, so a Services menu titled in a
        // language the check didn't know, or by its app, is still caught.
        if let refusal = OpenRoutes.menuRefusal(element: target) {
            AXElement.application(pid: pid).element(kAXMenuBarAttribute)?.elements(kAXChildrenAttribute).first?.perform(kAXCancelAction)
            throw ActionError(refusal, audit: "Refused: menu route")
        }
        if target.attribute(kAXEnabledAttribute) as? Bool == false {
            AXElement.application(pid: pid).element(kAXMenuBarAttribute)?.elements(kAXChildrenAttribute).first?.perform(kAXCancelAction)
            throw ActionError("Menu item \(Untrusted.inline(walked.joined(separator: " > "))) is disabled right now.")
        }
        try await Input.check(pid: pid, route: .target(target, point: nil, pid: pid, opens: false))
        guard target.perform(kAXPressAction) == .success else {
            throw ActionError("Could not choose \(Untrusted.inline(walked.joined(separator: " > "))).")
        }
        return walked.joined(separator: " > ")
    }

    public enum Direction: String, Sendable, CaseIterable { case up, down, left, right }

    static func wheelReaches(receiverMatches: Bool, insideArea: Bool) -> Bool {
        receiverMatches && insideArea
    }

    static func validateScroll(at point: CGPoint, pid: pid_t, area: AXElement?, clips: ClipChain?) throws {
        let hit = Input.systemElement().element(at: point)
        let inside = area.map { area in
            guard let f = frameOf(area), clips?.visible(f).contains(point) == true, let hit else { return false }
            return isWithin(hit, area)
        } ?? true
        guard let hit, wheelReaches(receiverMatches: pointerReaches(hit, area, pid: pid, at: point, windows: Input.guardWindows ?? []), insideArea: inside) else {
            throw ActionError("Not scrolling: another window is on top or outside the intended scroll area. Close or move it and retry.")
        }
    }

    public static func scroll(_ r: Resolved?, pid: pid_t, direction: Direction, amount: Int,
                              unit: Input.ScrollUnit = .line, modifiers: CGEventFlags = []) async throws -> String {
        try await bringForward(r ?? Resolved(pid: pid, element: nil, row: nil, point: nil))
        // After bringForward, so a screenshot target is checked against the activated window.
        let given: CGPoint? = if let r, r.element == nil, r.point != nil { try await actionPoint(r) } else { nil }
        let (point, area, clips) = try await Input.guardWork {
            let point: CGPoint
            let area: AXElement?
            let clips: ClipChain?
            if let el = r?.element {
                guard let f = frameOf(el) else { throw ActionError("The target has no frame to scroll.") }
                let chain = ClipChain(el), v = chain.visible(f)
                guard !v.isNull, v.width >= 1, v.height >= 1 else {
                    throw ActionError("The target is off screen. Use mac_scroll to_ref first.")
                }
                point = CGPoint(x: v.midX, y: v.midY)
                area = el
                clips = chain
            } else if let p = given {
                point = p
                area = nil
                clips = nil
            } else {
                let window = AXElement.application(pid: pid, timeout: Input.focusTimeout).element(kAXFocusedWindowAttribute)
                guard let window, let f = frameOf(window) else { throw ActionError("No window to scroll; pass ref= or x,y.") }
                point = CGPoint(x: f.midX, y: f.midY)
                area = window
                clips = ClipChain(window)
            }
            return (point, area, clips)
        }
        let n = max(1, min(amount, unit == .line ? 100 : 4000))
        let dx = direction == .right ? n : direction == .left ? -n : 0
        let dy = direction == .down ? n : direction == .up ? -n : 0
        try await Input.scroll(at: point, dx: dx, dy: dy, unit: unit, modifiers: modifiers, pid: pid) {
            try validateScroll(at: point, pid: pid, area: area, clips: clips)
        }
        return "scrolled \(direction.rawValue) \(n) \(unit.rawValue)s"
            + (modifiers.isEmpty ? "" : " holding \(KeySpec.describe(modifiers))") + " at \(point.x.safeInt),\(point.y.safeInt)"
    }

    /// Scroll the axis preventing the target's center from entering the current viewport.
    static func scrollDisplacement(target: CGRect, viewport: CGRect) -> CGPoint {
        let x = target.midX < viewport.minX ? target.midX - viewport.minX
            : target.midX >= viewport.maxX ? target.midX - viewport.maxX + 1 : 0
        let y = target.midY < viewport.minY ? target.midY - viewport.minY
            : target.midY >= viewport.maxY ? target.midY - viewport.maxY + 1 : 0
        return abs(x) / max(1, viewport.width) > abs(y) / max(1, viewport.height)
            ? CGPoint(x: x, y: 0) : CGPoint(x: 0, y: y)
    }

    private static func scrolled(_ r: Resolved) -> ActionSummary {
        ActionSummary("scrolled \(r.describe) into view", audit: "scrolled \(r.auditName) into view")
    }

    public static func scrollIntoView(_ r: Resolved) async throws -> ActionSummary {
        guard let el = r.element else { throw ActionError("to_ref needs a ref.") }
        try await Input.check(pid: r.pid)
        let area = try await Input.guardWork { () -> AXElement? in
            var current = el.element(kAXParentAttribute), seen = Set<AXElement>()
            for _ in 0..<512 {
                guard let e = current, seen.insert(e).inserted else { break }
                if e.role == "AXScrollArea" { return e }
                current = e.element(kAXParentAttribute)
            }
            return nil as AXElement?
        }
        guard let area else {
            if el.perform("AXScrollToVisible") == .success {
                let visible = try await Input.guardWork {
                    guard let f = frameOf(el) else { return false }
                    return visibleFrame(of: el, frame: f).contains(CGPoint(x: f.midX, y: f.midY))
                }
                if visible { return scrolled(r) }
            }
            throw ActionError("The target isn't inside a scrollable area.")
        }
        let clips = try await Input.guardWork { ClipChain(area) }
        @Sendable func viewport() -> CGRect? {
            guard let f = frameOf(area) else { return nil }
            let v = clips.visible(f)
            return !v.isNull && v.width >= 1 && v.height >= 1 ? v : nil
        }
        @Sendable func visible() async throws -> Bool {
            try await Input.guardWork {
                guard let v = viewport(), let f = frameOf(el) else { return false }
                return v.contains(CGPoint(x: f.midX, y: f.midY))
            }
        }
        if try await visible() { return ActionSummary("\(r.describe) is already in view", audit: "\(r.auditName) is already in view") }
        if el.perform("AXScrollToVisible") == .success {
            try await Task.sleep(for: .milliseconds(200))
            if try await visible() { return scrolled(r) }
        }
        try await bringForward(r)
        var lastOffset: CGPoint?
        var stuck = 0
        for _ in 0..<60 {
            try Task.checkCancellation()
            let geometry = try await Input.guardWork { (frameOf(el), viewport()) }
            guard let f = geometry.0, let v = geometry.1 else { break }
            if v.contains(CGPoint(x: f.midX, y: f.midY)) { return scrolled(r) }
            let offset = CGPoint(x: f.midX - v.midX, y: f.midY - v.midY)
            if let lastOffset, hypot(offset.x - lastOffset.x, offset.y - lastOffset.y) < 1 {
                stuck += 1
                if stuck >= 3 { break }
            } else { stuck = 0 }
            lastOffset = offset
            let distance = scrollDisplacement(target: f, viewport: v)
            func lines(_ d: CGFloat) -> Int { d == 0 ? 0 : (d > 0 ? 1 : -1) * max(1, min((abs(d) / 20).safeInt, 15)) }
            let center = CGPoint(x: v.midX, y: v.midY)
            try await Input.scroll(at: center, dx: lines(distance.x), dy: lines(distance.y), pid: r.pid) {
                try validateScroll(at: center, pid: r.pid, area: area, clips: clips)
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw ActionError("Could not scroll the target into view (the list stopped moving). Try mac_scroll with direction= and amount=.")
    }

    /// Where to press to drag an element, or to drop onto one. A list row's blank area starts a selection rectangle
    /// in Finder, not a file drag, and takes a drop for the window's folder rather than the row's, so rows and cells
    /// are grabbed and dropped onto by their icon or name.
    static func grabPoint(for element: AXElement, row: Row?, pid: pid_t) async throws -> CGPoint {
        if ["AXRow", "AXCell", "AXOutlineRow"].contains(element.role ?? "") {
            var queue = [(element, 0)], handles: [AXElement] = []
            while !queue.isEmpty {
                let (e, depth) = queue.removeFirst()
                if e != element, ["AXImage", "AXTextField", "AXStaticText"].contains(e.role ?? "") { handles.append(e) }
                if depth < 3 { queue += e.elements(kAXChildrenAttribute).map { ($0, depth + 1) } }
            }
            for handle in handles.sorted(by: { ($0.role == "AXImage" ? 0 : 1) < ($1.role == "AXImage" ? 0 : 1) }) {
                if let p = try? await clickPoint(for: handle, row: row, pid: pid) { return p }
            }
        }
        return try await clickPoint(for: element, row: row, pid: pid)
    }

    public static func drag(from a: Resolved, to b: Resolved, timing: Input.DragTiming = Input.DragTiming()) async throws -> String {
        func point(_ r: Resolved) async throws -> CGPoint {
            if r.point != nil { return try await actionPoint(r) }   // after bringForward, so screenshot pixels see the activated window
            guard let el = r.element else { throw ActionError("Nothing to drag.") }
            return try await grabPoint(for: el, row: r.row, pid: r.pid)
        }
        try await bringForward(a)
        let pa = try await point(a), pb = try await point(b)
        try await Input.drag(from: pa, to: pb, timing: timing, pid: a.pid) {
            try Input.checkBlocking(pid: b.pid, keyboard: false, windows: Input.guardWindows ?? [])
        }
        return "dragged from \(pa.x.safeInt),\(pa.y.safeInt) to \(pb.x.safeInt),\(pb.y.safeInt)"
            + (timing.modifiers.isEmpty ? "" : " holding \(KeySpec.describe(timing.modifiers))")
    }

    // MARK: Dock

    /// The Dock icon of an app (by bundle ID or name), as a drop target. Dropping a file on it opens the file with
    /// that app. Fails when the app isn't in the Dock or the Dock is hidden.
    /// The Dock icon to drop onto, with the bundle ID of the app it stands for (nil for folders and files).
    public static func dockItem(_ app: String) throws -> (target: Resolved, name: String, bundleID: String?) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw ActionError("The Dock isn't running.")
        }
        let items = AXElement.application(pid: dock.processIdentifier).elements(kAXChildrenAttribute)
            .filter { $0.role == "AXList" }.flatMap { $0.elements(kAXChildrenAttribute) }
        let q = app.lowercased()
        let match = items.first { item in
            if let url = item.attribute(kAXURLAttribute) as? URL, Bundle(url: url)?.bundleIdentifier?.lowercased() == q { return true }
            return item.string(kAXTitleAttribute)?.lowercased() == q
        }
        guard let match else {
            let names = items.filter { $0.subrole == "AXApplicationDockItem" }.compactMap { $0.string(kAXTitleAttribute) }
            throw ActionError("No Dock icon for \"\(app)\". Dock apps: \(Untrusted.inline(names.map { "\"\($0)\"" }.joined(separator: ", "), limit: 600)).")
        }
        guard let f = frame(position: match.attribute(kAXPositionAttribute), size: match.attribute(kAXSizeAttribute)),
              Walker.screenBounds.contains(CGPoint(x: f.midX, y: f.midY)) else {
            throw ActionError("The Dock icon for \"\(app)\" isn't on screen (is the Dock hidden?).")
        }
        let bundleID = (match.attribute(kAXURLAttribute) as? URL).flatMap { Bundle(url: $0)?.bundleIdentifier }
        return (Resolved(pid: dock.processIdentifier, element: nil, row: nil, point: CGPoint(x: f.midX, y: f.midY)),
                match.string(kAXTitleAttribute) ?? app, bundleID)
    }

    // MARK: Hover

    /// Moves the pointer onto the target without clicking, waits, and reports any tooltip: the help text of the
    /// element under the pointer and any help-tag window the app shows.
    public static func hover(_ r: Resolved, waitMs: Int) async throws -> ActionSummary {
        let p: CGPoint
        if let el = r.element {
            try await bringForward(r)
            p = try await clickPoint(for: el, row: r.row, pid: r.pid)
        } else if r.point != nil {
            p = try await activatedPoint(r) { await activateOwner(of: r) }
        } else {
            throw ActionError("Nothing to hover over.")
        }
        try await Input.hover(at: p, pid: r.pid)
        try await Task.sleep(for: .milliseconds(max(0, waitMs)))
        var help: String?
        if let hit = AXElement.systemWide.element(at: p) {
            var e: AXElement? = hit
            for _ in 0..<4 {
                if let text = e?.string(kAXHelpAttribute), !text.isEmpty { help = text; break }
                e = e?.element(kAXParentAttribute)
            }
        }
        let tip = tooltipText(pid: r.pid != 0 ? r.pid : AXElement.systemWide.element(at: p)?.pid ?? 0)
        return hoverSummary(r, at: p, help: help, tooltip: tip)
    }

    /// Help and tooltip text is the app's own and can be long and multi-line: marked, on one line, and capped. The
    /// log keeps the element's role and ref and the point, never the text.
    static func hoverSummary(_ r: Resolved, at p: CGPoint, help: String?, tooltip: String?) -> ActionSummary {
        let at = "at \(p.x.safeInt),\(p.y.safeInt)"
        var notes = ["hovered \(r.describe) \(at)"]
        if let help { notes.append("help text: \(Untrusted.inline(help, limit: 300))") }
        if let tooltip { notes.append("tooltip: \(Untrusted.inline(tooltip, limit: 300))") }
        return ActionSummary(notes.joined(separator: "; "), audit: "hovered \(r.auditName) \(at)")
    }

    /// The text of a tooltip (help tag) window the app is showing, if any.
    static func tooltipText(pid: pid_t) -> String? {
        guard pid != 0 else { return nil }
        let app = AXElement.application(pid: pid)
        for w in app.elements(kAXChildrenAttribute) + app.elements(kAXWindowsAttribute)
        where w.role == "AXHelpTag" || w.subrole == "AXHelpTag" {
            var texts: [String] = []
            var queue = [w]
            while let e = queue.popLast(), texts.count < 5 {
                if let v = e.string(kAXValueAttribute) ?? e.string(kAXDescriptionAttribute) ?? e.string(kAXTitleAttribute), !v.isEmpty {
                    texts.append(v)
                }
                queue += e.elements(kAXChildrenAttribute)
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        return nil
    }
}
