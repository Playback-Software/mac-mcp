import Foundation
import MacMCPCore

enum SnapshotTool {
    static let spec = ToolSpec(
        name: "mac_snapshot",
        description: """
            See an app's UI as a compact list of elements. Interactive elements get refs (e12) that the action tools \
            take; refs stay stable across snapshots while the element exists. Defaults to the frontmost app's focused \
            window, or the sheet/dialog blocking it. The header names the app, window, focused element and any \
            blockers (sheets, modal dialogs, macOS prompts, secure input). Offscreen content is skipped; scroll to \
            reveal it. Use query= to find specific elements cheaply.
            """,
        properties: [
            "app": Prop.string("App name or bundle ID. Default: the frontmost app."),
            "scope": Prop.string("window (default): focused window or the sheet/dialog blocking it. app: all windows "
                + "and top-level menus. menubar: the menu bar. dialog: only the open sheet/dialog.",
                enum: SnapshotScope.allCases.map(\.rawValue)),
            "query": Prop.string("Only rows whose label or value contains this text (case-insensitive)."),
            "max_tokens": Prop.integer("Output budget, default 1500. Rows beyond it are summarized."),
            "frames": Prop.boolean("Include each element's frame (x,y w×h in screen points). Default false."),
            "text": Prop.boolean("Include static text and headings. Default true."),
            "offscreen": Prop.boolean("Also include elements scrolled out of view (more tokens). Default false."),
        ],
        annotations: .readOnly
    ) { args, _ in
        if let blocked = await sessionGuard() { return blocked }
        let app: AppInfo
        do { app = try targetApp(args.string("app")) } catch { return .error("\(error)") }
        if let refused = await policyGuard(app) { return refused }
        var req = SnapshotRequest()
        req.pid = app.pid
        req.markShown = true   // the only snapshot the agent sees as rendered
        if let s = args.string("scope") {
            guard let scope = SnapshotScope(rawValue: s) else {
                return .error("scope must be one of: \(SnapshotScope.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            req.scope = scope
        }
        req.query = args.string("query")
        req.maxTokens = args.int("max_tokens") ?? 1500
        req.frames = args.bool("frames") ?? false
        req.includeText = args.bool("text") ?? true
        req.includeOffscreen = args.bool("offscreen") ?? false
        req.raw = args.bool("raw") ?? false   // undocumented debug switch
        do {
            let result = try await Snapshotter.take(req)
            if let prompt = result.blockers.first(where: { $0.hasPrefix("macOS prompt") }) {
                await Alerts.shared.notify(.prompt, "A macOS prompt is waiting on screen: \(prompt)")
            }
            return .text(result.text, auditDetail: "s\(result.snapshot) \(result.app.label) \(result.rows.count) rows")
        } catch {
            return .error("\(error)")
        }
    }
}
