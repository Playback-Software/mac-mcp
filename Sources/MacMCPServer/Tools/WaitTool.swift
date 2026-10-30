import AppKit
import Foundation
import MacMCPCore

enum WaitTool {
    static let conditions = ["settled", "text", "element", "gone", "window", "app", "unlock"]

    /// How long a call may wait: unlock waits for a person, so it may wait longer than UI conditions.
    static func timeout(_ args: ToolArgs) -> TimeInterval {
        let unlock = args.string("until") == "unlock"
        return TimeInterval(min(max(args.int("timeout") ?? (unlock ? 300 : 10), 1), unlock ? 600 : 60))
    }

    static let spec = ToolSpec(
        name: "mac_wait",
        description: """
            Wait for a condition instead of sleeping. settled: the UI stops changing. text: an element's label or \
            value contains query. element: an interactive element matching query appears. gone: nothing matches \
            query (a spinner, a sheet). window: a window title contains query. app: an app whose name contains query \
            is frontmost. unlock: the screen is unlocked and awake (the person is alerted). Returns as soon as it \
            holds, with the matches; on timeout, says what's there.
            """,
        properties: [
            "until": Prop.string(enum: conditions),
            "query": Prop.string("Not for settled or unlock."),
            "app": Prop.string(),
            "timeout": Prop.integer("Seconds. Default 10, max 60 (unlock: 300, max 600)."),
            "ocr": Prop.boolean("until=text: search screenshots of the app's window, for text drawn in canvases or "
                + "custom UI (can misread). Needs Screen Recording."),
        ],
        required: ["until"],
        annotations: .readOnly,
        deadline: { timeout($0) + 5 }
    ) { args, _ in
        guard let until = args.string("until"), conditions.contains(until) else {
            return .error("until must be one of: \(conditions.joined(separator: ", ")).")
        }
        let query = args.string("query") ?? ""
        guard until == "settled" || until == "unlock" || !query.isEmpty else { return .error("query is required for until=\(until).") }
        let ocr = args.bool("ocr") ?? false
        guard !ocr || until == "text" else { return .error("ocr=true is supported only with until=text; OCR cannot reliably prove text is gone.") }
        let timeout = timeout(args)
        let started = Date()
        if until == "unlock" {
            guard let first = SessionState.current().actionBlocker else { return .text("The screen is already unlocked and awake.") }
            let who = CallInfo.who.map { " (\($0))" } ?? ""
            await Alerts.shared.notify(.session, "An agent\(who) is waiting up to \(Int(timeout / 60)) min for this Mac "
                + "to be unlocked via Remote Access: \(first)")
            while Date().timeIntervalSince(started) < timeout {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                if SessionState.current().actionBlocker == nil {
                    return .text("Unlocked after \(Int(Date().timeIntervalSince(started))) s; carry on.")
                }
            }
            return .error("Still not available after \(Int(timeout)) s: \(SessionState.current().actionBlocker ?? first) "
                + "Stop and tell the user; they unlock the Mac via Remote Access.")
        }
        if let blocked = await sessionGuard() { return blocked }
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        do {
            if until == "app" {
                while Date().timeIntervalSince(started) < timeout {
                    if let f = Apps.frontmost(), f.name.lowercased().contains(query.lowercased()) || f.bundleID?.lowercased() == query.lowercased() {
                        return .text("\(f.label) is frontmost (after \(elapsed()) ms).", auditDetail: "app matched")
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                return .error("Timed out after \(Int(timeout)) s: frontmost is \(Apps.frontmost().map { Untrusted.inline($0.label) } ?? "nothing"), not \"\(query)\".")
            }
            let app: AppInfo
            if let q = args.string("app") { app = try Apps.resolve(q) } else if let f = Apps.frontmost() { app = f } else { return .error("No frontmost app; pass app=.") }
            if let refused = await policyGuard(app) { return refused }
            if ocr { return await waitForOCR(app: app, query: query, timeout: timeout) }

            if until == "settled" {
                let r = await Settle.wait(pid: app.pid, quiet: 400, timeout: timeout)
                return r.settled ? .text("\(app.label) settled after \(r.milliseconds) ms.")
                                 : .error("\(app.label) was still changing after \(Int(timeout)) s (an animation or live content?).")
            }
            if until == "window" {
                while Date().timeIntervalSince(started) < timeout {
                    if let w = WindowControl.windows(of: app).first(where: { $0.title.lowercased().contains(query.lowercased()) }) {
                        return .text(windowText(app: app, window: w, elapsed: elapsed()), auditDetail: "window matched")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let titles = WindowControl.windows(of: app).map(\.line).joined(separator: "; ")
                return .error("Timed out after \(Int(timeout)) s: no \(app.name) window titled like \"\(query)\". Windows: \(titles.isEmpty ? "none" : Untrusted.inline(titles, limit: 600))")
            }

            var req = SnapshotRequest()
            req.pid = app.pid
            req.maxTokens = 600
            req.markShown = false   // polling samples never reach the agent; only the matches it gets back are marked
            var last: SnapshotResult?
            while Date().timeIntervalSince(started) < timeout {
                try Task.checkCancellation()
                if let blocked = await sessionGuard() { return blocked }
                if let refused = await policyGuard(app) { return refused }
                let s = try await Snapshotter.take(req)
                last = s
                let matches = matchingRows(s.rows, query: query, until: until)
                if conditionMet(until: until, matches: matches, stats: s.stats) {
                    let met = metResponse(sample: s, matches: matches, until: until, query: query, elapsed: elapsed())
                    await RefStore.shared.markShown(met.shownRows)
                    return .text(met.text, auditDetail: "\(matches.count) matching rows")
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            return .error("Timed out after \(Int(timeout)) s waiting for until=\(until) \"\(query)\".\n"
                + (last.map(timeoutDiagnostic) ?? "No accessibility sample completed. Take mac_snapshot to check the app."))
        } catch {
            return .error("\(error)")
        }
    }

    /// The response once the condition holds, and the rows it renders (the only ones the agent sees, so the only
    /// ones whose labels count as shown to it): the sentence, then the sample's header and the matching rows, marked.
    static func metResponse(sample: SnapshotResult, matches: [Row], until: String, query: String, elapsed: Int) -> (text: String, shownRows: [Row]) {
        let (body, omitted) = Snapshot.render(matches, frames: false, maxTokens: 600)
        let text = "Condition until=\(until) \"\(query)\" met after \(elapsed) ms.\n"
            + Untrusted.wrap(lines: Array(sample.lines.prefix(2)) + body.components(separatedBy: "\n"))
        return (text, Array(matches.prefix(matches.count - omitted)))
    }

    static func windowText(app: AppInfo, window: WindowEntry, elapsed: Int) -> String {
        "\(app.label) has window \(Untrusted.inline(window.line)) (after \(elapsed) ms)."
    }

    static func matchingRows(_ rows: [Row], query: String, until: String) -> [Row] {
        rows.filter { (until == "element" ? $0.kind == .interactive : $0.kind != .context) && $0.matches(query) }
    }

    /// `gone` needs a walk that read every node's text whole (`WalkStats.textComplete`): a cut, a node or label that
    /// failed to read, or a page still loading could hold the text. An identifier that failed to read can't.
    static func conditionMet(until: String, matches: [Row], stats: WalkStats) -> Bool {
        until == "gone" ? matches.isEmpty && stats.textComplete && stats.loadingPages == 0 : !matches.isEmpty
    }

    static func timeoutDiagnostic(_ sample: SnapshotResult) -> String {
        var notes = [sample.text]
        if !sample.stats.textComplete {
            notes.append("Accessibility was incomplete; missing text does not prove it is gone. Narrow the window or inspect mac_snapshot.")
        }
        if sample.stats.loadingPages > 0 { notes.append("The page is still loading; wait for it to finish before checking again.") }
        if sample.rows.filter({ $0.kind == .interactive }).count < 3 {
            notes.append("Few accessible controls were found. For canvas/custom UI, retry mac_wait until=text ocr=true, or inspect mac_screenshot ocr=true.")
        } else {
            notes.append("If the text is visible but absent from accessibility, retry mac_wait until=text ocr=true. Otherwise check app= and scroll to reveal it.")
        }
        return notes.joined(separator: "\n")
    }

    static func matchingOCR(_ lines: [OCR.Line], query: String) -> [OCR.Line] {
        lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    static func waitForOCR(app: AppInfo, query: String, timeout: TimeInterval) async -> ToolOutput {
        let started = Date()
        var last = "No OCR sample completed. The recognizer's first load can take about a minute; retry after it warms up."
        do {
            while Date().timeIntervalSince(started) < timeout {
                try Task.checkCancellation()
                if let blocked = await sessionGuard() { return blocked }
                if let refused = await policyGuard(app) { return refused }
                let remaining = timeout - Date().timeIntervalSince(started)
                guard remaining > 0, let sample = try await Deadline.run(remaining, {
                    var request = Capture.Request()
                    request.app = app
                    request.maxEdge = 2560
                    let shot = try await Capture.take(request)
                    try Task.checkCancellation()
                    return (shot, try await OCR.recognize(png: shot.png))
                }) else { break }
                try Task.checkCancellation()
                let (shot, lines) = sample
                if !matchingOCR(lines, query: query).isEmpty {
                    return .text("Condition until=text \"\(query)\" met after \(Int(Date().timeIntervalSince(started) * 1000)) ms (OCR).\n"
                        + ScreenshotTool.ocrReport(lines, shot: shot, find: query), auditDetail: "text matched by OCR")
                }
                last = "Last OCR sample recognized \(lines.count) lines."
                    + (lines.isEmpty ? "" : "\n" + Untrusted.wrap(lines: lines.prefix(6).map { "  " + String($0.text.prefix(120)) }))
                try await Task.sleep(for: .seconds(min(1, max(0, timeout - Date().timeIntervalSince(started)))))
            }
            return .error("Timed out after \(Int(timeout)) s waiting for OCR text \"\(query)\" in \(app.name).\n\(last)\n"
                + "Check the app's visible window with mac_screenshot ocr=true; region= can help read small text.")
        } catch {
            return .error("Could not wait for OCR text: \(error)")
        }
    }
}
