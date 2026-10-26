import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One keyboard, one mouse: actions run one at a time. (Actor methods alone don't serialize across awaits.)
/// One keyboard, one mouse: actions run one at a time, in arrival order.
///
/// Each hold has a deadline. When it passes, the holder is abandoned (cancelled, see `Deadline`), the lock moves on
/// to the next waiter, and the stale holder's eventual release is ignored, so one wedged action can't freeze the agent.
/// Waiting is bounded too: a call that can't get the lock within `maxWait` gives up without running.
public actor ActionLock {
    public static let shared = ActionLock()

    public struct Status: Sendable {
        public let holder: String?
        /// How long the current holder has had the lock, by system uptime (which doesn't count time asleep).
        public let heldFor: TimeInterval?
        public let waiting: Int
        public let abandoned: Int
    }

    private var generation: UInt64 = 0
    private var holder: (generation: UInt64, name: String, since: TimeInterval)?
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
        defer { release(mine) }
        try Task.checkCancellation()   // gave up while queued: don't act late
        guard let result = try await Deadline.run(deadline, body) else {
            abandoned += 1
            throw DeadlineExceeded(name, seconds: deadline)
        }
        return result
    }

    public var status: Status {
        Status(holder: holder?.name, heldFor: holder.map { ProcessInfo.processInfo.systemUptime - $0.since },
               waiting: waiters.count, abandoned: abandoned)
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
        holder = (generation, name, ProcessInfo.processInfo.systemUptime)
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
    public init(_ d: String) { description = d }
}

/// Where an action should land: a ref from a snapshot, or a point (screen points, or pixels of a screenshot).
public enum Target: Sendable {
    case ref(String)
    case point(CGPoint)
}

/// A resolved target, ready to act on.
public struct Resolved: Sendable {
    public let pid: pid_t
    public let element: AXElement?
    public let row: Row?
    public let point: CGPoint?

    public var describe: String {
        if let row { return [row.ref, row.role, row.label.isEmpty ? nil : "\"\(row.label)\""].compactMap { $0 }.joined(separator: " ") }
        if let point { return "point \(point.x.safeInt),\(point.y.safeInt)" }
        return "target"
    }
}

public enum Actions {
    // MARK: Targets

    /// Turns tool arguments into a target. x,y are screen points, or pixels of `screenshotID` when given.
    public static func target(ref: String?, x: Int?, y: Int?, screenshotID: String?) async throws -> Target {
        if let ref, !ref.isEmpty { return .ref(ref) }
        guard let x, let y else { throw ActionError("Pass ref (from mac_snapshot) or x and y.") }
        if let id = screenshotID {
            guard let m = await ScreenshotStore.shared.mapping(id) else {
                throw ActionError("Unknown screenshot_id \(id). Screenshot ids expire; take a new mac_screenshot.")
            }
            if let stale = m.staleReason(id: id, windows: WindowServer.onScreenWindows()) { throw ActionError(stale) }
            let px = CGPoint(x: x, y: y)
            guard m.contains(pixel: px) else {
                throw ActionError("Pixel \(x),\(y) is outside screenshot \(id) (\(m.pixelSize.width.safeInt)x\(m.pixelSize.height.safeInt) px).")
            }
            return .point(m.point(forPixel: px))
        }
        return .point(CGPoint(x: x, y: y))
    }

    /// The process an action will affect, for the before/after snapshots.
    public static func pid(for target: Target?, app: String?) async throws -> pid_t {
        if case let .ref(r)? = target {
            guard let e = await RefStore.shared.entry(r) else {
                throw ActionError("Unknown ref \(r). Refs come from mac_snapshot; take a snapshot first.")
            }
            return e.pid
        }
        // For a point, app= names the app the point is meant to be in (checked once resolved); without it, the
        // point's own app.
        if let app { return try Apps.resolve(app).pid }
        if case let .point(p)? = target, let owner = pointOwner(p) { return owner }
        guard let front = Apps.frontmost() else { throw ActionError("No frontmost app; pass app=.") }
        return front.pid
    }

    /// Who a click at `p` would reach: the window server's answer, else accessibility's.
    static func pointOwner(_ p: CGPoint) -> pid_t? {
        WindowServer.owner(at: p) ?? AXElement.systemWide.element(at: p)?.pid
    }

    /// Resolves a target against the UI as it is now. Call after a fresh snapshot of the target's app: a ref that the
    /// snapshot re-found is current; one it didn't is stale unless its element still exists (e.g. scrolled offscreen).
    public static func resolve(_ target: Target, currentSnapshot: Int) async throws -> Resolved {
        switch target {
        case let .point(p):
            return Resolved(pid: pointOwner(p) ?? 0, element: nil, row: nil, point: p)
        case let .ref(r):
            guard let entry = await RefStore.shared.entry(r) else { throw ActionError("Unknown ref \(r). Take a mac_snapshot first.") }
            if entry.snapshot == currentSnapshot, let el = entry.element {
                return Resolved(pid: entry.pid, element: el, row: entry.row, point: nil)
            }
            if let el = entry.element, el.isAlive, el.role.map({ Snapshot.shortRole($0, subrole: el.subrole) }) == entry.row.role {
                return Resolved(pid: entry.pid, element: el, row: entry.row, point: nil)   // exists, just not in view
            }
            throw ActionError("Ref \(r) (\(entry.row.role) \"\(entry.row.label)\") no longer exists: the UI changed. "
                + "Call mac_snapshot and use the new refs.")
        }
    }

    // MARK: Focus

    /// Brings the target's app (and window) to the front before synthesized input.
    static func bringForward(_ r: Resolved) async throws {
        guard let running = NSRunningApplication(processIdentifier: r.pid) else { return }
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
        return "Refused: \"\(name ?? "a dialog")\" is open in front of that control and has to be answered first "
            + "(a person couldn't click behind it either). Take mac_snapshot to see its buttons."
    }

    // MARK: Hit-test guard

    /// Is `hit` the target itself or inside it?
    static func isWithin(_ hit: AXElement, _ target: AXElement) -> Bool {
        var e: AXElement? = hit
        for _ in 0..<15 {
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

    /// Roles whose hit-test result says nothing against a control inside them: accessibility often reports the sheet or
    /// split view around a button rather than the button, and a container can't cover its own descendant. Scroll
    /// areas aren't here: a row scrolled out of one is hit as the scroll area itself.
    static let structuralRoles: Set<String> = ["AXSheet", "AXWindow", "AXSplitGroup"]

    /// Whether a hit-test result shows `target` is reachable at that point: the hit is the target, inside it, or a
    /// structural ancestor of it. Siblings, scroll areas and other apps' windows still count as covering.
    static func reaches(_ hit: AXElement, _ target: AXElement) -> Bool {
        isWithin(hit, target) || (structuralRoles.contains(hit.role ?? "") && isWithin(target, hit))
    }

    /// A point inside the element where a click would land on it (not on something covering it).
    static func clickPoint(for element: AXElement, row: Row?) async throws -> CGPoint {
        var f = frame(position: element.attribute(kAXPositionAttribute), size: element.attribute(kAXSizeAttribute))
        // Off every display, or partly above the top of the desktop (scrolled up out of view). Not `minY < 0`: a
        // display arranged above the main one has negative y throughout.
        if let frame0 = f, !frame0.intersects(Walker.screenBounds) || frame0.minY < Walker.screenBounds.minY {
            element.perform("AXScrollToVisible")
            try await Task.sleep(for: .milliseconds(150))
            f = frame(position: element.attribute(kAXPositionAttribute), size: element.attribute(kAXSizeAttribute))
        }
        guard let frame = f, frame.width > 0, frame.height > 0 else {
            throw ActionError("\(row.map { "\($0.role) \"\($0.label)\"" } ?? "The element") has no on-screen frame; it may be hidden or collapsed.")
        }
        let visible = frame.intersection(Walker.screenBounds)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            throw ActionError("\(row.map { "\($0.role) \"\($0.label)\"" } ?? "The element") is off screen and couldn't be scrolled into view. "
                + "Try mac_scroll to_ref first.")
        }
        let candidates = [CGPoint(x: visible.midX, y: visible.midY),
                          CGPoint(x: visible.minX + visible.width * 0.25, y: visible.midY),
                          CGPoint(x: visible.minX + visible.width * 0.75, y: visible.midY),
                          CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.3),
                          CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.7)]
        var blocker: AXElement?
        for p in candidates {
            guard let hit = AXElement.systemWide.element(at: p) else { continue }
            if reaches(hit, element) { return p }
            blocker = blocker ?? hit
        }
        let what = blocker.map { b -> String in
            let v = b.read(["AXRole", "AXTitle", "AXDescription"]) ?? [:]
            let app = NSRunningApplication(processIdentifier: b.pid)?.localizedName ?? "another app"
            return "\(Snapshot.shortRole(v["AXRole"] as? String ?? "?", subrole: nil)) \"\((v["AXTitle"] ?? v["AXDescription"]) as? String ?? "")\" of \(app)"
        } ?? "something else"
        throw ActionError("Not clicking: \(row.map { "\($0.ref ?? "") \($0.role) \"\($0.label)\"" } ?? "the target") is covered by \(what). "
            + "Close or move what's on top, or check mac_snapshot blockers.")
    }

    // MARK: Primitives

    static let synthesizeRoles: Set<String> = ["AXRow", "AXCell", "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXGroup"]

    /// Clicks. Prefers the accessibility press (no cursor movement, works when partly covered); falls back to a mouse
    /// click at a hit-tested point. Returns how it clicked.
    public static func click(_ r: Resolved, button: Input.Button, count: Int, modifiers: CGEventFlags) async throws -> String {
        if let el = r.element {
            let role = el.role ?? ""
            if button == .left, count == 1, modifiers.isEmpty, !synthesizeRoles.contains(role), el.actionNames.contains(kAXPressAction) {
                let result = el.perform(kAXPressAction)
                switch pressOutcome(result, cancelled: Task.isCancelled) {
                case .pressed: return "accessibility press"
                case .unanswered:
                    return "accessibility press (the app didn't reply in time; it may be showing a sheet or menu, so check the "
                        + "snapshot before pressing again)"
                case .failed: break
                }
            }
            if button == .right, modifiers.isEmpty, el.actionNames.contains(kAXShowMenuAction), el.perform(kAXShowMenuAction) == .success {
                return "accessibility show-menu"
            }
            try await bringForward(r)
            let p = try await clickPoint(for: el, row: r.row)
            Input.click(at: p, button: button, count: count, modifiers: modifiers)
            return "mouse \(button.rawValue)\(count > 1 ? " ×\(count)" : "") at \(p.x.safeInt),\(p.y.safeInt)"
        }
        guard let p = r.point else { throw ActionError("Nothing to click.") }
        if r.pid != 0, NSWorkspace.shared.frontmostApplication?.processIdentifier != r.pid,
           let running = NSRunningApplication(processIdentifier: r.pid) {
            _ = await AppControl.activate(AppInfo(running))
        }
        Input.click(at: p, button: button, count: count, modifiers: modifiers)
        return "mouse \(button.rawValue)\(count > 1 ? " ×\(count)" : "") at \(p.x.safeInt),\(p.y.safeInt)"
    }

    public enum TypeMode: String, Sendable { case replace, append }

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
                let p = try await clickPoint(for: el, row: r.row)   // some fields only take focus from a click
                Input.click(at: p)
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
            guard let focused = app.element(kAXFocusedUIElementAttribute) else {
                throw ActionError("Nothing has keyboard focus. Pass ref= for the field to type into.")
            }
            field = focused
        }
        let secure = field?.subrole == "AXSecureTextField"
        if mode == .replace { Input.press(try KeySpec.parse("cmd+a")) }
        Input.type(text)
        if submit { Input.press(try KeySpec.parse("return")) }
        try await Task.sleep(for: .milliseconds(100))

        if secure { return "typed \(text.count) characters into a password field (contents can't be read back)" }
        if submit { return "typed \(text.count) characters and pressed Return" }
        guard let value = field?.attribute(kAXValueAttribute) as? String else {
            return "typed \(text.count) characters (the field's value isn't readable to verify)"
        }
        if let field, hidesItsText(field) {
            // VS Code's editor (screen-reader mode off) reports "" whatever it holds: an "empty" readback is no
            // evidence the keys were lost, and saying so made an agent type everything twice (M10, N8).
            return "typed \(text.count) characters (this editor hides its text from accessibility, so it can't be "
                + "verified here; check with mac_screenshot ocr=true rather than typing again)"
        }
        try verifyTypedValue(value, expected: text, mode: mode)
        let hint = field.flatMap { savePanelNameHint(fieldLabel: $0.string(kAXTitleAttribute), typed: text) }
        return "typed \(text.count) characters; field value verified" + (hint.map { ". " + $0 } ?? "")
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

    static func verifyTypedValue(_ value: String, expected text: String, mode: TypeMode) throws {
        let ok = mode == .replace ? norm(value) == norm(text) : norm(value).hasSuffix(norm(text))
        if !ok {
            throw ActionError("Typed \(text.count) characters, but the field value did not match "
                + "\(mode == .replace ? "the replacement" : "the appended text"). "
                + "Some characters may have been dropped or autocorrected; check and retry.")
        }
    }

    /// Editors whose accessible value isn't their text: VS Code / Monaco without screen-reader mode, which labels
    /// its textarea "The editor is not accessible at this time…".
    static func hidesItsText(_ field: AXElement) -> Bool {
        let v = field.read([kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]) ?? [:]
        return v.values.contains { ($0 as? String)?.localizedCaseInsensitiveContains("editor is not accessible") == true }
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func keys(_ specs: [KeySpec], repeat count: Int) {
        keys(specs, repeat: count) { Input.press($0) }
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
            Input.press(KeySpec(key: 53, flags: []))   // esc
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
            items.compactMap { $0.string(kAXTitleAttribute) }.filter { !$0.isEmpty }.map { "\"\($0)\"" }.joined(separator: ", ")
        }
        var level = bar.elements(kAXChildrenAttribute)
        var current: AXElement?
        var walked: [String] = []
        for (i, name) in path.enumerated() {
            guard let item = level.first(where: { matches($0, name) }) else {
                throw ActionError("No menu item \"\(name)\" under \(walked.isEmpty ? "the menu bar" : walked.joined(separator: " > ")). "
                    + "Available: \(titles(level)).")
            }
            walked.append(item.string(kAXTitleAttribute) ?? name)
            current = item
            if i < path.count - 1 {
                var submenu = item.elements(kAXChildrenAttribute).first
                var items = submenu?.elements(kAXChildrenAttribute) ?? []
                if items.isEmpty {   // menus some apps build only when opened
                    item.perform(kAXPressAction)
                    try await Task.sleep(for: .milliseconds(250))
                    submenu = item.elements(kAXChildrenAttribute).first
                    items = submenu?.elements(kAXChildrenAttribute) ?? []
                }
                level = items
            }
        }
        guard let target = current else { throw ActionError("Empty menu path.") }
        if target.attribute(kAXEnabledAttribute) as? Bool == false {
            AXElement.application(pid: pid).element(kAXMenuBarAttribute)?.elements(kAXChildrenAttribute).first?.perform(kAXCancelAction)
            throw ActionError("Menu item \(walked.joined(separator: " > ")) is disabled right now.")
        }
        guard target.perform(kAXPressAction) == .success else {
            throw ActionError("Could not choose \(walked.joined(separator: " > ")).")
        }
        return walked.joined(separator: " > ")
    }

    public enum Direction: String, Sendable, CaseIterable { case up, down, left, right }

    public static func scroll(_ r: Resolved?, pid: pid_t, direction: Direction, amount: Int,
                              unit: Input.ScrollUnit = .line, modifiers: CGEventFlags = []) async throws -> String {
        var point: CGPoint
        if let r, let el = r.element {
            try await bringForward(r)
            guard let f = frame(position: el.attribute(kAXPositionAttribute), size: el.attribute(kAXSizeAttribute)) else {
                throw ActionError("\(r.describe) has no frame to scroll.")
            }
            let v = f.intersection(Walker.screenBounds)
            guard !v.isNull, v.width >= 1, v.height >= 1 else { throw ActionError("\(r.describe) is off screen; nothing visible to scroll.") }
            point = CGPoint(x: v.midX, y: v.midY)
        } else if let r, let p = r.point {
            point = p
        } else {
            let window = AXElement.application(pid: pid).element(kAXFocusedWindowAttribute)
            guard let f = window.flatMap({ frame(position: $0.attribute(kAXPositionAttribute), size: $0.attribute(kAXSizeAttribute)) }) else {
                throw ActionError("No window to scroll; pass ref= or x,y.")
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, let running = NSRunningApplication(processIdentifier: pid) {
                _ = await AppControl.activate(AppInfo(running))
            }
            point = CGPoint(x: f.midX, y: f.midY)
        }
        let n = max(1, min(amount, unit == .line ? 100 : 4000))
        switch direction {
        case .down: Input.scroll(at: point, dy: n, unit: unit, modifiers: modifiers)
        case .up: Input.scroll(at: point, dy: -n, unit: unit, modifiers: modifiers)
        case .right: Input.scroll(at: point, dx: n, dy: 0, unit: unit, modifiers: modifiers)
        case .left: Input.scroll(at: point, dx: -n, dy: 0, unit: unit, modifiers: modifiers)
        }
        return "scrolled \(direction.rawValue) \(n) \(unit.rawValue)s"
            + (modifiers.isEmpty ? "" : " holding \(KeySpec.describe(modifiers))") + " at \(point.x.safeInt),\(point.y.safeInt)"
    }

    /// Scrolls until the element is visible: the accessibility "scroll to visible" action where supported, otherwise
    /// wheel-scrolling its scroll area toward it until its frame is inside the visible area (SwiftUI lists, web pages).
    public static func scrollIntoView(_ r: Resolved) async throws -> String {
        guard let el = r.element else { throw ActionError("to_ref needs a ref.") }
        func frameOf(_ e: AXElement) -> CGRect? { frame(position: e.attribute(kAXPositionAttribute), size: e.attribute(kAXSizeAttribute)) }
        var area: AXElement? = el.element(kAXParentAttribute)
        for _ in 0..<20 where area != nil && area?.role != "AXScrollArea" { area = area?.element(kAXParentAttribute) }
        guard let area, let viewport = frameOf(area)?.intersection(Walker.screenBounds), !viewport.isNull else {
            if el.perform("AXScrollToVisible") == .success { return "scrolled \(r.describe) into view" }
            throw ActionError("\(r.describe) isn't inside a scrollable area.")
        }
        func visible() -> Bool { frameOf(el).map { viewport.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }
        if visible() { return "\(r.describe) is already in view" }
        if el.perform("AXScrollToVisible") == .success {
            try await Task.sleep(for: .milliseconds(200))
            if visible() { return "scrolled \(r.describe) into view" }
        }
        try await bringForward(r)
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        var lastY: CGFloat?
        var stuck = 0
        for _ in 0..<60 {
            guard let f = frameOf(el) else { break }
            if viewport.contains(CGPoint(x: f.midX, y: f.midY)) { return "scrolled \(r.describe) into view" }
            let distance = f.midY - viewport.midY   // positive: element is below the viewport
            let lines = max(1, min(Int(abs(distance) / 20), 15))
            Input.scroll(at: center, dy: distance > 0 ? lines : -lines)
            try await Task.sleep(for: .milliseconds(120))
            if let ly = lastY, abs(ly - f.midY) < 1 { stuck += 1; if stuck >= 3 { break } } else { stuck = 0 }
            lastY = f.midY
        }
        throw ActionError("Could not scroll \(r.describe) into view (the list stopped moving). Try mac_scroll with direction= and amount=.")
    }

    /// Where to press to drag an element. A list row's blank area starts a selection rectangle in Finder, not a
    /// file drag, so rows and cells are grabbed by their icon or name.
    static func grabPoint(for element: AXElement, row: Row?) async throws -> CGPoint {
        if ["AXRow", "AXCell", "AXOutlineRow"].contains(element.role ?? "") {
            var queue = [(element, 0)], handles: [AXElement] = []
            while !queue.isEmpty {
                let (e, depth) = queue.removeFirst()
                if e != element, ["AXImage", "AXTextField", "AXStaticText"].contains(e.role ?? "") { handles.append(e) }
                if depth < 3 { queue += e.elements(kAXChildrenAttribute).map { ($0, depth + 1) } }
            }
            for handle in handles.sorted(by: { ($0.role == "AXImage" ? 0 : 1) < ($1.role == "AXImage" ? 0 : 1) }) {
                if let p = try? await clickPoint(for: handle, row: row) { return p }
            }
        }
        return try await clickPoint(for: element, row: row)
    }

    public static func drag(from a: Resolved, to b: Resolved, timing: Input.DragTiming = Input.DragTiming()) async throws -> String {
        func point(_ r: Resolved, source: Bool) async throws -> CGPoint {
            if let p = r.point { return p }
            guard let el = r.element else { throw ActionError("Nothing to drag.") }
            return source ? try await grabPoint(for: el, row: r.row) : try await clickPoint(for: el, row: r.row)
        }
        try await bringForward(a)
        let pa = try await point(a, source: true), pb = try await point(b, source: false)
        Input.drag(from: pa, to: pb, timing: timing)
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
            throw ActionError("No Dock icon for \"\(app)\". Dock apps: \(names.map { "\"\($0)\"" }.joined(separator: ", ")).")
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
    public static func hover(_ r: Resolved, waitMs: Int) async throws -> String {
        let p: CGPoint
        if let el = r.element {
            try await bringForward(r)
            p = try await clickPoint(for: el, row: r.row)
        } else if let point = r.point {
            if r.pid != 0, NSWorkspace.shared.frontmostApplication?.processIdentifier != r.pid,
               let running = NSRunningApplication(processIdentifier: r.pid) {
                _ = await AppControl.activate(AppInfo(running))
            }
            p = point
        } else {
            throw ActionError("Nothing to hover over.")
        }
        Input.hover(at: p)
        try await Task.sleep(for: .milliseconds(max(0, waitMs)))
        var notes = ["hovered \(r.describe) at \(p.x.safeInt),\(p.y.safeInt)"]
        if let hit = AXElement.systemWide.element(at: p) {
            var e: AXElement? = hit
            for _ in 0..<4 {
                if let help = e?.string(kAXHelpAttribute), !help.isEmpty { notes.append("help text: \"\(help)\""); break }
                e = e?.element(kAXParentAttribute)
            }
        }
        if let tip = tooltipText(pid: r.pid != 0 ? r.pid : AXElement.systemWide.element(at: p)?.pid ?? 0) {
            notes.append("tooltip: \"\(tip)\"")
        }
        return notes.joined(separator: "; ")
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
