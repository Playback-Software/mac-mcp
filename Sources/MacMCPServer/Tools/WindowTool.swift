import AppKit
import Foundation
import MacMCPCore

enum WindowTool {
    static let actions = ["list", "focus", "move", "resize", "minimize", "restore", "close"]

    /// On-screen windows of processes without a Dock icon (an osascript `display dialog`, an agent's helper panel):
    /// invisible to the app list above, but often exactly the dialog an agent is looking for (M10, N7).
    static func otherWindows(listed: Set<pid_t>, policy: Policy) -> [String] {
        let me = getpid()
        let quiet: Set<String> = ["Window Server", "Dock", "Control Center", "SystemUIServer", "Notification Center",
                                  "WindowManager", "Spotlight", "TextInputMenuAgent", "loginwindow"]
        var lines: [String] = []
        for w in WindowServer.onScreenWindows() where (0...8).contains(w.layer) && w.alpha > 0 && w.pid != me
            && !listed.contains(w.pid) && !quiet.contains(w.owner) {
            let running = NSRunningApplication(processIdentifier: w.pid)
            guard policy.permits(bundleID: running?.bundleIdentifier, name: w.owner) else { continue }
            let what = WindowServer.isSystemPrompt(pid: w.pid) ? " [macOS prompt: a person must answer it]"
                : " → mac_snapshot app=\"\(w.owner)\""
            lines.append("  \(w.owner) (pid \(w.pid)): \"\(w.title)\" @\(w.bounds.minX.safeInt),\(w.bounds.minY.safeInt) "
                + "\(w.bounds.width.safeInt)x\(w.bounds.height.safeInt)\(what)")
        }
        return lines.isEmpty ? [] : ["Other windows on screen (processes without a Dock icon):"] + lines
    }

    static let spec = ToolSpec(
        name: "mac_window",
        description: """
            Manage windows. list: an app's windows (or every app's, if app is omitted) with index, title and frame. \
            focus: raise a window and bring its app to the front. move / resize: set the position (x,y) or size \
            (width,height) in screen points. minimize / restore. close: press the close button (the app may ask to \
            save; check blockers with mac_snapshot). Pick a window with window= (1-based index or title text); \
            default is the focused window.
            """,
        properties: [
            "action": Prop.string("What to do.", enum: actions),
            "app": Prop.string("App name or bundle ID. Default: the frontmost app (list: all apps)."),
            "window": Prop.string("1-based index from list, or part of the title."),
            "x": Prop.integer("move: left edge in screen points."), "y": Prop.integer("move: top edge in screen points."),
            "width": Prop.integer("resize: width in points."), "height": Prop.integer("resize: height in points."),
        ],
        required: ["action"],
        annotations: .action,
        deadline: { ($0.string("action") ?? "list") == "list" ? 30 : lockedDeadline(actionDeadline) },
        mutates: { ($0.string("action") ?? "list") != "list" }
    ) { args, _ in
        guard let action = args.string("action"), actions.contains(action) else {
            return .error("action must be one of: \(actions.joined(separator: ", ")).")
        }
        if action == "list", args.string("app") == nil {
            var out: [String] = []
            let policy: Policy
            switch await currentPolicy() { case let .success(p): policy = p; case let .failure(out): return out }
            for app in Apps.running().sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
            where policy.permits(bundleID: app.bundleID, name: app.name) {
                let ws = WindowControl.windows(of: app)
                if ws.isEmpty { continue }
                out.append("\(app.label):")
                out += ws.map { "  " + $0.line }
            }
            out += otherWindows(listed: Set(Apps.running().map(\.pid)), policy: policy)
            return .text(out.isEmpty ? "No windows." : out.joined(separator: "\n"))
        }
        let app: AppInfo
        do {
            if let q = args.string("app") { app = try Apps.resolve(q) }
            else if let f = Apps.frontmost() { app = f }
            else { return .error("No frontmost app; pass app=.") }
        } catch { return .error("\(error)") }
        if let refused = await policyGuard(app) { return refused }

        if action == "list" {
            let ws = WindowControl.windows(of: app)
            return .text(ws.isEmpty ? "\(app.label) has no windows." : "\(app.label):\n" + ws.map(\.line).joined(separator: "\n"))
        }
        return await underActionLock("mac_window") {
            if let blocked = await sessionGuard() { return blocked }
            guard let w = WindowControl.find(app, args.string("window")) else {
                let list = WindowControl.windows(of: app).map(\.line)
                return .error("No matching window in \(app.label)."
                    + (list.isEmpty ? " It has no windows." : " Windows:\n" + list.joined(separator: "\n")))
            }
            let detail = "\(app.label) window \(w.index) \"\(w.title)\""
            switch action {
            case "focus":
                let ok = await WindowControl.focus(app, w)
                return ok ? .text("Focused \(detail).", auditDetail: detail)
                          : .error("Raised \(detail), but it is not the focused window (a dialog or another app may hold focus).")
            case "move", "resize":
                let origin = action == "move" ? args.int("x").flatMap { x in args.int("y").map { CGPoint(x: x, y: $0) } } : nil
                let size = action == "resize" ? args.int("width").flatMap { w in args.int("height").map { CGSize(width: w, height: $0) } } : nil
                guard origin != nil || size != nil else {
                    return .error(action == "move" ? "move needs x and y." : "resize needs width and height.")
                }
                if let refusal = WindowControl.frameRefusal(w.frame, origin: origin, size: size,
                                                            displays: Displays.all().map(\.bounds)) {
                    return .error("Can't \(action) \(detail): \(refusal)")
                }
                guard let f = WindowControl.setFrame(w, origin: origin, size: size) else { return .error("Could not read back \(detail).") }
                return .text("\(detail) is now at \(f.minX.safeInt),\(f.minY.safeInt) \(f.width.safeInt)x\(f.height.safeInt)"
                    + " (apps may clamp to their minimum size or the screen).", auditDetail: detail)
            case "minimize", "restore":
                return WindowControl.minimize(w, action == "minimize") ? .text("\(action == "minimize" ? "Minimized" : "Restored") \(detail).", auditDetail: detail)
                                                                       : .error("Could not \(action) \(detail).")
            default:   // close
                guard WindowControl.close(w) else { return .error("\(detail) has no close button.") }
                try? await Task.sleep(for: .milliseconds(400))
                let stillOpen = WindowControl.windows(of: app).contains { $0.element == w.element }
                return .text(stillOpen ? "Pressed close on \(detail); it is still open, likely asking to save. Check mac_snapshot scope=dialog."
                                       : "Closed \(detail).", auditDetail: detail)
            }
        }
    }
}
