import AppKit
import Foundation
import MacMCPCore

enum ActionTools {
    static let click = ToolSpec(
        name: "mac_click",
        description: """
            Click an element by ref (preferred) or at x,y. Buttons, checkboxes, links and menu items are pressed through \
            accessibility; other targets get a real mouse click, but only after checking nothing else covers them. \
            Returns what changed (diff) or, if a sheet/dialog appeared or the window changed, the new UI.
            """,
        properties: targetProperties.merging([
            "button": Prop.string("left (default), right or middle.", enum: Input.Button.allCases.map(\.rawValue)),
            "count": Prop.integer("2 for double-click. Default 1."),
            "modifiers": Prop.string("Keys held during the click, e.g. \"cmd\" or \"cmd+shift\"."),
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
            return "clicked \(r!.describe) (\(how))"
        }
    }

    static let type = ToolSpec(
        name: "mac_type",
        description: """
            Type text. With ref: focuses that field, confirms the focus landed, types, and reads the value back to \
            verify (mode=replace, the default, replaces the field's contents; append adds to it). Without ref: types \
            into whatever has keyboard focus. submit=true presses Return afterwards. Newlines in text press Return.
            """,
        properties: [
            "text": Prop.string("The text to type."),
            "ref": Prop.string("The field to type into (from mac_snapshot). Default: the focused element."),
            "mode": Prop.string("replace (default with ref) or append (default without ref).", enum: ["replace", "append"]),
            "submit": Prop.boolean("Press Return after typing."),
            "app": Prop.string("App to type into when no ref is given. Default: the frontmost app."),
        ],
        required: ["text"],
        annotations: .action,
        secretArguments: ["text"],   // may be a password; never written to the audit log
        deadline: { lockedDeadline(typeDeadline($0.string("text") ?? "")) }
    ) { args, _ in
        guard let text = args.string("text") else { return .error("text is required.") }
        let ref = args.string("ref")
        let mode = args.string("mode").flatMap(Actions.TypeMode.init(rawValue:)) ?? (ref == nil ? .append : .replace)
        let submit = args.bool("submit") ?? false
        return await runAction(name: "type", app: args.string("app"), target: ref.map { .ref($0) },
                                     deadline: typeDeadline(text)) { r, pid in
            let note = try await Actions.type(r, pid: pid, text: text, mode: mode, submit: submit)
            return (r.map { "into \($0.describe): " } ?? "at the focused element: ") + note
        }
    }

    static let key = ToolSpec(
        name: "mac_key",
        description: """
            Press keys or shortcuts in the frontmost app (or app=, brought to the front first). Examples: "cmd+s", \
            "esc", "return", "shift+tab", "cmd+a, delete" (a sequence), "down down return", "cmd+," (a comma right \
            after + is the comma key; also "cmd+comma"). keys may also be a list: ["cmd+,", "return"]. Prefer mac_menu \
            for menu commands (it doesn't depend on the right window having focus).
            """,
        properties: [
            "keys": Prop.string("Key spec, comma/space-separated sequence, or a list of key specs. Punctuation names: "
                + "comma, period, slash, semicolon, quote, bracketleft, bracketright, minus, equal, backslash, grave."),
            "repeat": Prop.integer("Press the whole sequence this many times (max 50). Default 1."),
            "app": Prop.string("Bring this app to the front first."),
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
        let count = min(max(args.int("repeat") ?? 1, 1), 50)
        // About 50 ms per press: keep the whole call inside its deadline instead of being abandoned mid-way.
        guard specs.count * count <= 300 else {
            return .error("That is \(specs.count * count) key presses; the limit is 300 per call. Split it into several calls.")
        }
        let app = args.string("app")
        return await runAction(name: "key", app: app, target: nil) { _, pid in
            if NSRunningApplication(processIdentifier: pid).map({ !$0.isActive }) ?? false,
               let running = NSRunningApplication(processIdentifier: pid), !(await AppControl.activate(AppInfo(running))) {
                throw ActionError("\(running.localizedName ?? "The app") would not come to the front; keys would go elsewhere.")
            }
            Actions.keys(specs, repeat: count)
            return "pressed \(shown)" + (count > 1 ? " ×\(count)" : "")
        }
    }

    static let menu = ToolSpec(
        name: "mac_menu",
        description: """
            Choose a menu-bar command by path, e.g. path="Format > Make Plain Text" or ["File", "Save As…"]. Works \
            through accessibility, without opening menus or clicking; reports the available items when a step \
            doesn't match, and disabled items. The most reliable way to run app commands.
            """,
        properties: [
            "app": Prop.string("App name or bundle ID. Default: the frontmost app."),
            "path": Prop.string("Menu path (or a list of steps): \"File > Save As…\" (\" > \" separated). Matching ignores case and ellipses."),
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
        return await runAction(name: "menu", app: args.string("app"), target: nil) { _, pid in
            // Menu commands act on the app's key window; if the app isn't active, some (Electron) open a new window.
            if NSRunningApplication(processIdentifier: pid).map({ !$0.isActive }) ?? false,
               let running = NSRunningApplication(processIdentifier: pid) {
                _ = await AppControl.activate(AppInfo(running))
            }
            return "chose " + (try await Actions.menu(pid: pid, path: path))
        }
    }

    static let scroll = ToolSpec(
        name: "mac_scroll",
        description: """
            Scroll. to_ref scrolls until that element is visible (use refs from a snapshot with offscreen=true). \
            Otherwise scrolls the element at ref / x,y (default: the focused window's center) by amount in direction: \
            lines like a mouse wheel, or unit=pixel for continuous trackpad-style deltas. modifiers holds keys during \
            the scroll (cmd or ctrl for zoom in many apps, shift, alt). Returns newly visible elements.
            """,
        properties: targetProperties.merging([
            "direction": Prop.string("down (default), up, left or right.", enum: Actions.Direction.allCases.map(\.rawValue)),
            "amount": Prop.integer("Lines to scroll, default 5 (a page is roughly 10–15); with unit=pixel, pixels (default 100)."),
            "unit": Prop.string("line (default, mouse wheel notches) or pixel (continuous, like a trackpad).",
                                enum: Input.ScrollUnit.allCases.map(\.rawValue)),
            "modifiers": Prop.string("Keys held during the scroll, e.g. \"cmd\" or \"ctrl\"."),
            "to_ref": Prop.string("Scroll until this element is in view."),
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
            try await Actions.scroll(r, pid: pid, direction: direction, amount: amount, unit: unit, modifiers: modifiers)
        }
    }

    static let drag = ToolSpec(
        name: "mac_drag",
        description: """
            Drag from one element or point to another (from_ref/from_x,from_y → to_ref/to_x,to_y), or onto an app's \
            Dock icon with to_dock_app (opens a dragged file with that app). The press is held hold_ms before moving \
            and the pointer dwells dwell_ms over the target before release; raise them if a drag doesn't start (a \
            selection rectangle appears instead) or the target doesn't accept the drop.
            """,
        properties: [
            "from_ref": Prop.string("Drag source ref."), "from_x": Prop.integer("Source x."), "from_y": Prop.integer("Source y."),
            "to_ref": Prop.string("Drop target ref."), "to_x": Prop.integer("Target x."), "to_y": Prop.integer("Target y."),
            "to_dock_app": Prop.string("Drop on this app's Dock icon instead (bundle ID or Dock name)."),
            "screenshot_id": Prop.string("Interpret x,y as pixels of this screenshot."),
            "app": Prop.string("App, when using coordinates."),
            "hold_ms": Prop.integer("Hold the press this long before moving. Default 150, max 3000."),
            "steps": Prop.integer("Intermediate pointer positions along the way. Default 20, max 200."),
            "dwell_ms": Prop.integer("Pause over the target before releasing. Default 150 (600 onto the Dock), max 5000."),
            "modifiers": Prop.string("Keys held during the drag, e.g. \"alt\" (copy) or \"cmd\"."),
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
            switch Policy.current() { case let .success(p): policy = p; case let .failure(e): throw ActionError(e.description) }
            if let dockApp {
                let dock = try Actions.dockItem(dockApp)
                if dock.bundleID != nil, let refusal = policy.refusal(bundleID: dock.bundleID, name: dock.name) {
                    throw ActionError(refusal)   // the dropped file would open in that app
                }
                return try await Actions.drag(from: r!, to: dock.target, timing: timing) + " (\(dock.name) in the Dock)"
            }
            var req = SnapshotRequest()
            req.pid = r!.pid
            let current = try await Snapshotter.take(req)
            let dest = try await Actions.resolve(to!, currentSnapshot: current.snapshot)
            if let refusal = targetRefusal(dest, checkedPid: pid, policy: policy) { throw ActionError(refusal) }
            return try await Actions.drag(from: r!, to: dest, timing: timing)
        }
    }

    static let hover = ToolSpec(
        name: "mac_hover",
        description: """
            Move the pointer onto an element by ref or to x,y without clicking, and leave it there, to reveal \
            tooltips, hover menus and toolbars that appear on hover. Waits wait_ms (default 1500: tooltips take about \
            a second), then reports the element's help text and any tooltip shown, plus what changed (diff).
            """,
        properties: targetProperties.merging([
            "wait_ms": Prop.integer("How long to wait on the target before reporting. Default 1500, max 5000."),
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
