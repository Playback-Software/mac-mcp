import AppKit
import Foundation
import MacMCPCore

enum ActionTools {
    static let click = ToolSpec(
        name: "mac_click",
        description: """
            Click by ref or x,y. Buttons, checkboxes, links and menu items are pressed through accessibility; other \
            targets get a mouse click after checking nothing covers them. Returns the diff.
            """,
        properties: targetProperties.merging([
            "button": Prop.string("Default left.", enum: Input.Button.allCases.map(\.rawValue)),
            "count": Prop.integer("2 for a double-click. Default 1."),
            "modifiers": Prop.string("Keys held, e.g. \"cmd+shift\"."),
        ]) { $1 },
        annotations: .action,
        deadline: { _ in lockedDeadline(actionDeadline) }
    ) { args, _ in
        let button = args.string("button").flatMap(Input.Button.init(rawValue:)) ?? .left
        let count = min(max(args.int("count") ?? 1, 1), 3)
        let modifiers: CGEventFlags
        do { modifiers = try KeySpec.modifiers(args.string("modifiers") ?? "") } catch { return .error("\(error)") }
        let t: Target?
        do { t = try await target(from: args) } catch { return .error("\(error)") }
        guard let t else { return .error("Pass ref (from mac_snapshot) or x and y.") }
        return await runAction(name: "click", app: args.string("app"), target: t) { r, _ in
            let how = try await Actions.click(r!, button: button, count: count, modifiers: modifiers)
            return ActionSummary("clicked \(r!.describe) (\(how))", audit: "clicked \(r!.auditName) (\(how))")
        }
    }

    static let type = ToolSpec(
        name: "mac_type",
        description: """
            Type text. With ref: focuses the field, types and reads the value back; mode=replace (default) replaces \
            its contents, append adds at the end. Without ref or mode: inserts at the caret, replacing only the \
            selection. If append can't place the caret through accessibility it refuses: click where to type and \
            retry without mode. Newlines press Return.
            """,
        properties: [
            "text": Prop.string(),
            "ref": Prop.string("Default: the focused element."),
            "mode": Prop.string(enum: ["replace", "append"]),
            "submit": Prop.boolean("Press Return after; not if a readable field's value doesn't match."),
            "app": Prop.string("Without ref."),
        ],
        required: ["text"],
        annotations: .action,
        secretArguments: ["text"],   // may be a password; never written to the audit log
        deadline: { lockedDeadline(typeDeadline($0.string("text") ?? "")) }
    ) { args, _ in
        guard let text = args.string("text") else { return .error("text is required.") }
        let ref = args.string("ref")
        let mode = Actions.typingMode(args.string("mode"), hasRef: ref != nil)
        let submit = args.bool("submit") ?? false
        return await runAction(name: "type", app: args.string("app"), target: ref.map { .ref($0) },
                                     deadline: typeDeadline(text)) { r, pid in
            let note = try await Actions.type(r, pid: pid, text: text, mode: mode, submit: submit)
            return ActionSummary((r.map { "into \($0.describe): " } ?? "at the focused element: ") + note,
                                 audit: (r.map { "into \($0.auditName): " } ?? "at the focused element: ") + note)
        }
    }

    static let key = ToolSpec(
        name: "mac_key",
        description: """
            Press keys in the frontmost app (or app=, brought to the front): "cmd+s", "shift+tab", "cmd+a, delete" \
            (a sequence), "down down", "cmd+," (the comma key), or a list ["cmd+,", "return"]. Prefer mac_menu for \
            menu commands. In Finder, a file panel or an open menu, a key that acts on the selection (Return, Space, \
            Tab, Delete, cmd+…) must come first in its call: send it separately, after mac_snapshot. After a key \
            that may open a panel or menu (cmd+s, cmd+o, Return), send Return or Space in another call.
            """,
        properties: [
            "keys": Prop.string("Punctuation key names: comma, period, slash, semicolon, quote, bracketleft, "
                + "bracketright, minus, equal, backslash, grave."),
            "repeat": Prop.integer("Times to press the whole sequence (max 50)."),
            "app": Prop.string(),
        ],
        required: ["keys"],
        annotations: .action,
        deadline: { _ in lockedDeadline(actionDeadline) }
    ) { args, _ in
        let list = args.raw["keys"]?.arrayValue?.compactMap(\.stringValue)
        let specs: [KeySpec]
        do { specs = try list.map(KeySpec.parseSequence) ?? KeySpec.parseSequence(args.string("keys") ?? "") } catch { return .error("\(error)") }
        let shown = list?.joined(separator: ", ") ?? args.string("keys") ?? ""
        if let refusal = SessionSafety.refusal(keys: specs) { return .error(refusal) }
        if let refused = await RouteGuards.keys(specs, app: args.string("app"), repeat: args.int("repeat") ?? 1) { return refused }
        let count = min(max(args.int("repeat") ?? 1, 1), 50)
        // About 50 ms per press: keep the whole call inside its deadline instead of being abandoned mid-way.
        guard specs.count * count <= 300 else {
            return .error("That is \(specs.count * count) key presses; the limit is 300 per call. Split it into several calls.")
        }
        let app = args.string("app")
        return await runAction(name: "key", app: app, target: nil) { _, pid in
            try await Actions.keys(specs, repeat: count, pid: pid)
            return ActionSummary("pressed \(shown)" + (count > 1 ? " ×\(count)" : ""))
        }
    }

    static let menu = ToolSpec(
        name: "mac_menu",
        description: """
            Run a menu-bar command by path through accessibility, without opening menus: the most reliable way to run \
            app commands. Reports the available items when a step doesn't match, and disabled items.
            """,
        properties: [
            "app": Prop.string(),
            "path": Prop.string("\"Format > Make Plain Text\" or [\"File\", \"Save As…\"]; ignores case and ellipses."),
        ],
        required: ["path"],
        annotations: .action,
        deadline: { _ in lockedDeadline(actionDeadline) }
    ) { args, _ in
        let raw = args.raw["path"]
        let path: [String] = raw?.arrayValue?.compactMap(\.stringValue)
            ?? (args.string("path") ?? "").components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !path.isEmpty else { return .error("path is required, e.g. \"File > Save As…\".") }
        if let refusal = SessionSafety.refusal(menuPath: path) { return .error(refusal) }
        if let refused = await RouteGuards.menu(path, app: args.string("app")) { return refused }
        return await runAction(name: "menu", app: args.string("app"), target: nil) { _, pid in
            // Menu commands act on the app's key window; if the app isn't active, some (Electron) open a new window.
            if NSRunningApplication(processIdentifier: pid).map({ !$0.isActive }) ?? false,
               let running = NSRunningApplication(processIdentifier: pid) {
                _ = await AppControl.activate(AppInfo(running))
            }
            let chosen = try await Actions.menu(pid: pid, path: path)
            // The titles are the app's own text; the log keeps the depth (the path is in the call's arguments).
            return ActionSummary("chose " + Untrusted.inline(chosen), audit: "chose a menu item \(path.count) levels deep")
        }
    }

    static let scroll = ToolSpec(
        name: "mac_scroll",
        description: """
            Scroll ref or x,y (default: the window's center) by amount in direction, or until to_ref is visible \
            (refs from mac_snapshot offscreen=true). Returns newly visible elements.
            """,
        properties: targetProperties.merging([
            "direction": Prop.string("Default down.", enum: Actions.Direction.allCases.map(\.rawValue)),
            "amount": Prop.integer("Default 5 lines (a page is about 10–15), or 100 pixels."),
            "unit": Prop.string("Default line (wheel notches); pixel is continuous, like a trackpad.",
                                enum: Input.ScrollUnit.allCases.map(\.rawValue)),
            "modifiers": Prop.string("Keys held; cmd or ctrl zoom in many apps."),
            "to_ref": Prop.string(),
        ]) { $1 },
        annotations: .action,
        deadline: { _ in lockedDeadline(actionDeadline) }
    ) { args, _ in
        if let toRef = args.string("to_ref"), !toRef.isEmpty {
            return await runAction(name: "scroll", app: nil, target: .ref(toRef)) { r, _ in try await Actions.scrollIntoView(r!) }
        }
        let t: Target?
        do { t = try await target(from: args) } catch { return .error("\(error)") }
        let direction = args.string("direction").flatMap(Actions.Direction.init(rawValue:)) ?? .down
        let unit = args.string("unit").flatMap(Input.ScrollUnit.init(rawValue:)) ?? .line
        let amount = args.int("amount") ?? (unit == .line ? 5 : 100)
        let modifiers: CGEventFlags
        do { modifiers = try KeySpec.modifiers(args.string("modifiers") ?? "") } catch { return .error("\(error)") }
        return await runAction(name: "scroll", app: args.string("app"), target: t) { r, pid in
            ActionSummary(try await Actions.scroll(r, pid: pid, direction: direction, amount: amount, unit: unit, modifiers: modifiers))
        }
    }

    static let drag = ToolSpec(
        name: "mac_drag",
        description: """
            Drag from from_ref or from_x,from_y to to_ref or to_x,to_y, or onto an app's Dock icon (to_dock_app, to \
            open a dragged file with it). If the drag doesn't start (a selection rectangle appears) or the drop isn't \
            accepted, raise hold_ms or dwell_ms.
            """,
        properties: [
            "from_ref": Prop.string(), "from_x": Prop.integer(), "from_y": Prop.integer(),
            "to_ref": Prop.string(), "to_x": Prop.integer(), "to_y": Prop.integer(),
            "to_dock_app": Prop.string("Bundle ID or Dock name."),
            "screenshot_id": Prop.string(),
            "app": Prop.string("With coordinates."),
            "hold_ms": Prop.integer("Press held before moving. Default 150, max 3000."),
            "steps": Prop.integer("Pointer moves. Default 20, max 200."),
            "dwell_ms": Prop.integer("Pause before release. Default 150 (Dock: 600), max 5000."),
            "modifiers": Prop.string("Keys held, e.g. \"alt\" (copy)."),
        ],
        annotations: .action,
        deadline: { _ in lockedDeadline(actionDeadline) }
    ) { args, _ in
        let from: Target?, to: Target?
        do { from = try await target(from: args, prefix: "from_"); to = try await target(from: args, prefix: "to_") } catch { return .error("\(error)") }
        let dockApp = args.string("to_dock_app").flatMap { $0.isEmpty ? nil : $0 }
        guard let from, to != nil || dockApp != nil else {
            return .error("Pass from_ref or from_x/from_y, and to_ref, to_x/to_y or to_dock_app.")
        }
        var timing = Input.DragTiming()
        timing.holdMs = min(max(args.int("hold_ms") ?? timing.holdMs, 0), 3000)
        timing.steps = min(max(args.int("steps") ?? timing.steps, 1), 200)
        timing.dwellMs = min(max(args.int("dwell_ms") ?? (dockApp != nil ? 600 : timing.dwellMs), 0), 5000)
        do { timing.modifiers = try KeySpec.modifiers(args.string("modifiers") ?? "") } catch { return .error("\(error)") }
        return await runAction(name: "drag", app: args.string("app"), target: from) { [timing] r, pid in
            // runAction vetted the source; the drop point gets the same checks before anything is pressed.
            let policy: Policy
            switch await Policy.current() { case let .success(p): policy = p; case let .failure(e): throw ActionError(e.description) }
            if let dockApp {
                let dock = try Actions.dockItem(dockApp)
                if dock.bundleID != nil, let refusal = policy.refusal(bundleID: dock.bundleID, name: dock.name) {
                    throw ActionError(refusal)   // the dropped file would open in that app
                }
                let dragged = try await Actions.drag(from: r!, to: dock.target, timing: timing)
                return ActionSummary(dragged + " (\(Untrusted.inline(dock.name)) in the Dock)", audit: dragged + " (onto a Dock icon)")
            }
            // The agent never sees this snapshot, so it must not update what the drop target's ref was last shown as.
            let current = try await Snapshotter.take(bookkeepingSnapshot(pid: r!.pid))
            let dest = try await Actions.resolve(to!, currentSnapshot: current.snapshot)
            if let refusal = try await Input.guardWork(pool: .route, timeout: Input.routeTimeout, { targetRefusal(dest, checkedPid: pid, policy: policy) }) { throw ActionError(refusal, audit: "Refused: drop target route") }
            return ActionSummary(try await Actions.drag(from: r!, to: dest, timing: timing))
        }
    }

    static let hover = ToolSpec(
        name: "mac_hover",
        description: """
            Move the pointer onto ref or x,y without clicking, to reveal tooltips and hover UI. After wait_ms, \
            reports the help text, any tooltip and the diff.
            """,
        properties: targetProperties.merging([
            "wait_ms": Prop.integer("Default 1500, max 5000."),
        ]) { $1 },
        annotations: .action,
        deadline: { _ in lockedDeadline(actionDeadline) }
    ) { args, _ in
        let t: Target?
        do { t = try await target(from: args) } catch { return .error("\(error)") }
        guard let t else { return .error("Pass ref (from mac_snapshot) or x and y.") }
        let wait = min(max(args.int("wait_ms") ?? 1500, 0), 5000)
        return await runAction(name: "hover", app: args.string("app"), target: t) { r, _ in
            try await Actions.hover(r!, waitMs: wait)
        }
    }
}

/// Typing goes out in 20-character chunks a few milliseconds apart, so long text needs more time.
func typeDeadline(_ text: String) -> TimeInterval { actionDeadline + Double(text.count) / 500 }
