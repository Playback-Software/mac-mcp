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
            "since": Prop.string("Only changes since a snapshot from this connection, e.g. s123; omit for the full state."),
            "max_tokens": Prop.integer("Output budget. Default 1500."),
            "frames": Prop.boolean("Include frames (x,y w×h in screen points)."),
            "text": Prop.boolean("Include static text. Default true."),
            "offscreen": Prop.boolean("Include elements scrolled out of view."),
        ],
        annotations: .readOnly
    ) { args, context in
        if let blocked = await sessionGuard() { return blocked }
        let app: AppInfo
        do { app = try targetApp(args.string("app")) } catch { return .error("\(error)") }
        if let refused = await policyGuard(app) { return refused }
        var req = SnapshotRequest()
        req.pid = app.pid
        req.markShown = args.string("since") == nil
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
        let baseline: SnapshotHistory.View?
        if let since = args.string("since") {
            guard !req.raw, since.first == "s", let id = Int(since.dropFirst()), id > 0,
                  let view = await SnapshotHistory.shared.baseline(id, owner: context.connectionID) else {
                return .error("since must name a retained snapshot from this connection. Take a full mac_snapshot first.")
            }
            baseline = view
        } else { baseline = nil }
        do {
            let result = try await Snapshotter.take(req)
            if let prompt = result.blockers.first(where: { $0.hasPrefix("macOS prompt") }) {
                await Alerts.shared.notify(.prompt, "A macOS prompt is waiting on screen: \(prompt)")
            }
            let text: String
            if let baseline {
                let rendered = SnapshotHistory.render(baseline, after: result, request: req)
                await RefStore.shared.markShown(rendered.shown)
                text = rendered.text
            } else { text = result.text }
            await SnapshotHistory.shared.remember(result, request: req, owner: context.connectionID)
            return ToolOutput(content: [.text(text)], auditDetail: "s\(result.snapshot) \(result.app.label) \(result.rows.count) rows",
                data: ["snapshot": .string("s\(result.snapshot)"), "pid": .int(Int(result.app.pid)),
                       "rows": .int(result.rows.count), "complete": .bool(result.stats.textComplete)])
        } catch {
            return .error("\(error)")
        }
    }
}
