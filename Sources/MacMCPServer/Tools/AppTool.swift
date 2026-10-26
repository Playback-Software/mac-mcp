import AppKit
import Foundation
import MacMCPCore

enum AppTool {
    static let actions = ["list", "launch", "activate", "quit", "hide"]

    static let spec = ToolSpec(
        name: "mac_app",
        description: """
            Manage apps. list: running apps (frontmost marked). launch: start an app, or bring it up if running; with \
            open= it opens a URL or file in that app; waits until a window appears. activate: bring an app to the \
            front. quit: quit gracefully (reports a blocking save dialog instead of hanging); force=true kills it. \
            hide: hide the app.
            """,
        properties: [
            "action": Prop.string("What to do.", enum: actions),
            "app": Prop.string("App name (\"TextEdit\") or bundle ID (\"com.apple.TextEdit\"). Required except for list."),
            "open": Prop.string("launch only: a URL (https://…) or file path to open in the app."),
            "force": Prop.boolean("quit only: force-quit (unsaved work is lost)."),
        ],
        required: ["action"],
        annotations: .action,
        deadline: { ($0.string("action") ?? "list") == "list" ? 30 : lockedDeadline(appDeadline) },
        mutates: { ($0.string("action") ?? "list") != "list" }
    ) { args, _ in
        guard let action = args.string("action"), actions.contains(action) else {
            return .error("action must be one of: \(actions.joined(separator: ", ")).")
        }
        if action == "list" {
            let front = Apps.frontmost()?.pid
            let policy = Policy.load()
            let lines = Apps.running().sorted { $0.name.lowercased() < $1.name.lowercased() }.map { a in
                "\(a.label) pid \(a.pid)" + (a.pid == front ? " [frontmost]" : "") + (a.isHidden ? " [hidden]" : "")
                    + (Apps.isAutomationSession(a.pid) ? " [automation browser: use the web_* tools]" : "")
                    + (policy.permits(bundleID: a.bundleID, name: a.name) ? "" : " [off-limits by policy]")
            }
            return .text("\(lines.count) apps running:\n" + lines.joined(separator: "\n"))
        }
        return await underActionLock("mac_app", deadline: appDeadline) {
            if let blocked = await sessionGuard() { return blocked }
            guard let query = args.string("app"), !query.isEmpty else { return .error("app is required for action=\(action).") }

            switch action {
            case "launch":
                let bundleID = Apps.bundleURL(for: query).flatMap { Bundle(url: $0)?.bundleIdentifier }
                switch await currentPolicy() {
                case let .failure(out): return out
                case let .success(p): if let refusal = p.refusal(bundleID: bundleID ?? query, name: query) { return .error(refusal) }
                }
                do {
                    let app = try await AppControl.launch(query, open: args.string("open"))
                    let front = await AppControl.activate(app)
                    let windows = WindowControl.windows(of: app).map(\.line)
                    return .text("\(app.label) is running\(front ? " and frontmost" : " (could not bring it to the front)").\n"
                        + (windows.isEmpty ? "No windows yet." : "Windows:\n" + windows.joined(separator: "\n"))
                        + "\nNext: mac_snapshot app=\"\(app.name)\" to see its UI.", auditDetail: app.label)
                } catch {
                    return .error("\(error)")
                }
            default:
                let app: AppInfo
                do { app = try Apps.resolve(query) } catch { return .error("\(error)") }
                if let refused = await policyGuard(app) { return refused }
                switch action {
                case "activate":
                    let ok = await AppControl.activate(app)
                    return ok ? .text("\(app.label) is frontmost.", auditDetail: app.label)
                              : .error("\(app.label) did not come to the front. It may be showing a modal dialog elsewhere; try mac_window action=list.")
                case "quit":
                    switch await AppControl.quit(app, force: args.bool("force") ?? false) {
                    case .quit:
                        return .text("\(app.label) quit.", auditDetail: app.label)
                    case let .blocked(what):
                        return .error("\(app.label) is still running: quitting is waiting on \(what). Answer it "
                            + "(mac_snapshot app=\"\(app.name)\" scope=dialog) or quit with force=true to discard changes.")
                    case .stillRunning:
                        return .error("\(app.label) did not quit within 5 s. Retry, or use force=true.")
                    }
                default:   // hide
                    let ok = AppControl.hide(app)
                    return ok ? .text("\(app.label) hidden.") : .error("Could not hide \(app.label).")
                }
            }
        }
    }
}

/// How long launching or quitting may hold the action lock: a launch waits up to 15 s for the app, then for a window.
let appDeadline: TimeInterval = 25
