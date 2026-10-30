import Foundation
import MacMCPCore

enum SnapshotTool {
    static let spec = ToolSpec(
        name: "mac_snapshot",
        description: """
            See an app's UI as rows; interactive elements get refs (e12) that stay the same while the element exists. \
            Default: the focused window, or the sheet/dialog blocking it. The header lists blockers (sheets, dialogs, \
            macOS prompts, secure input). Offscreen rows are skipped; scroll to reveal them.
            """,
        properties: [
            "app": Prop.string(),
            "scope": Prop.string("window (default): the focused window or the sheet/dialog blocking it. app: all "
                + "windows and menus. dialog: only the sheet/dialog.",
                enum: SnapshotScope.allCases.map(\.rawValue)),
            "query": Prop.string("Only rows whose label or value contains this (case-insensitive): the cheap way to find an element."),
            "max_tokens": Prop.integer("Output budget. Default 1500."),
            "frames": Prop.boolean("Include frames (x,y w×h in screen points)."),
            "text": Prop.boolean("Include static text. Default true."),
            "offscreen": Prop.boolean("Include elements scrolled out of view."),
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
