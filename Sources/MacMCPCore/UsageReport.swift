import Foundation

/// A summary of real use from the audit log (`mac-mcp report`): which tools agents call, how often they fail and
/// why, how slow they are, and how much of the work goes through the GUI rather than a direct route. Calls from
/// evals, tests and the CLI are counted separately, so the numbers describe real sessions.
public enum UsageReport {
    public enum Kind: String, CaseIterable, Sendable {
        case real
        /// Ran under a GUI lease: eval runs and the integration tests hold one.
        case leased
        /// A test or tooling client (soak, integration tests without a lease, the protocol probe).
        case test
        /// The `mac-mcp call` CLI.
        case cli
        /// Written before sessions were recorded (M11), so it can't be told apart.
        case legacy
    }

    static let testClients = ["integration-tests", "soak", "outsider", "protocol-probe"]

    public static func kind(_ e: AuditEntry) -> Kind {
        if e.lease != nil { return .leased }
        let client = e.client.lowercased()
        if testClients.contains(where: client.hasPrefix) { return .test }
        if client.hasPrefix("mac-mcp-cli") { return .cli }
        if e.session == nil { return .legacy }
        return .real
    }

    /// Where a call's work went.
    public enum Route: String, CaseIterable, Sendable {
        /// Synthesized input on the GUI: clicks, typing, keys, scrolling, dragging.
        case gui
        /// A route that skips GUI input: menu commands by path, scripts, the Safari pass-through, Shortcuts.
        case direct
        /// Looking: snapshots, screenshots, waits, window and app lists.
        case perception
        /// Everything else (doctor, clipboard, app launch/quit).
        case other
    }

    public static func route(_ e: AuditEntry) -> Route {
        switch e.tool {
        case "mac_click", "mac_type", "mac_key", "mac_scroll", "mac_drag", "mac_hover": return .gui
        case "mac_menu", "mac_script", "mac_shortcut": return .direct
        case "web_read", "web_tabs": return .perception
        case "mac_snapshot", "mac_screenshot", "mac_wait": return .perception
        case "mac_window": return e.arguments["action"] == "list" ? .perception : .other
        default: return e.tool.hasPrefix("web_") ? .direct : .other
        }
    }

    /// An error detail with its specifics (refs, numbers, quoted names) replaced, so similar errors group together.
    public static func cluster(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "(no detail)" }
        var s = detail.replacingOccurrences(of: #""[^"]*""#, with: "\"…\"", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\be\d+\b"#, with: "eN", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\d+"#, with: "N", options: .regularExpression)
        let firstSentence = s.split(separator: ".", maxSplits: 1).first.map(String.init) ?? s
        return String(firstSentence.prefix(110))
    }

    public static func render(_ entries: [AuditEntry], since: Date, now: Date = Date(), top: Int = 8) -> String {
        let window = entries.filter { $0.time >= since && $0.time <= now }
        let byKind = Dictionary(grouping: window, by: kind)
        let real = byKind[.real] ?? []
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = ["MacMCP usage, \(f.string(from: since)) → \(f.string(from: now))", ""]

        let sessions = Dictionary(grouping: real, by: { $0.session ?? "?" })
        let origins = Dictionary(grouping: sessions.values.compactMap(\.first), by: { $0.origin ?? "direct socket" })
            .map { "\($0.value.count) \($0.key)" }.sorted()
        out.append("Real use: \(real.count) calls in \(sessions.count) sessions"
            + (origins.isEmpty ? "" : " (" + origins.joined(separator: ", ") + ")"))
        let clients = Dictionary(grouping: real, by: \.client).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        if !clients.isEmpty { out.append("Clients: " + clients.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")) }
        let excluded = Kind.allCases.dropFirst().compactMap { k in byKind[k].map { "\($0.count) \(k.rawValue)" } }
        if !excluded.isEmpty {
            let holders = Set((byKind[.leased] ?? []).compactMap(\.lease)).sorted()
            out.append("Excluded: " + excluded.joined(separator: ", ")
                + (holders.isEmpty ? "" : " (lease holders: " + holders.joined(separator: ", ") + ")"))
        }
        guard !real.isEmpty else {
            out.append("")
            out.append("No real sessions in this window.")
            return out.joined(separator: "\n")
        }

        out.append("")
        out.append("Routes: " + Route.allCases.map { r in
            let n = real.filter { route($0) == r }.count
            return "\(r.rawValue) \(percent(n, real.count))"
        }.joined(separator: " · "))
        out.append("  gui = click/type/key/scroll/drag · direct = menu, script, web_* actions, shortcuts · "
            + "perception = snapshot, screenshot, wait, lists")

        out.append("")
        out.append("Tools:")
        out.append(pad("tool", 16) + pad("calls", 7) + pad("errors", 8) + pad("p50", 8) + "p95")
        let byTool = Dictionary(grouping: real, by: \.tool).sorted { $0.value.count > $1.value.count }
        for (tool, calls) in byTool {
            let errors = calls.filter { $0.outcome != "ok" }.count
            let ms = calls.map(\.durationMs).sorted()
            out.append(pad(tool, 16) + pad("\(calls.count)", 7) + pad(errors == 0 ? "–" : "\(errors) (\(percent(errors, calls.count)))", 8)
                + pad(duration(ms[ms.count / 2]), 8) + duration(ms[min(ms.count - 1, ms.count * 95 / 100)]))
        }

        let failures = real.filter { $0.outcome != "ok" }
        func refused(_ e: AuditEntry) -> Bool { (e.detail ?? "").hasPrefix("Refused") || e.outcome == "refused" }
        let refusals = failures.filter(refused)
        let errors = failures.filter { !refused($0) }
        for (title, list) in [("Top errors", errors), ("Refusals", refusals)] where !list.isEmpty {
            out.append("")
            out.append("\(title) (\(list.count)):")
            let groups = Dictionary(grouping: list, by: { "\($0.tool): \(cluster($0.detail))" })
                .sorted { $0.value.count > $1.value.count }.prefix(top)
            for (key, group) in groups { out.append("  \(group.count)× \(key)") }
        }

        out.append("")
        out.append("Slowest calls:")
        for e in real.sorted(by: { $0.durationMs > $1.durationMs }).prefix(5) {
            out.append("  \(duration(e.durationMs))  \(e.tool) \(e.outcome)  \(f.string(from: e.time))"
                + (e.detail.map { "  " + String($0.prefix(80)) } ?? ""))
        }

        out.append("")
        out.append("Sessions (most calls first):")
        for (id, calls) in sessions.sorted(by: { $0.value.count > $1.value.count }).prefix(top) {
            let first = calls.map(\.time).min()!, last = calls.map(\.time).max()!
            let errors = calls.filter { $0.outcome != "ok" }.count
            out.append("  \(id)  \(calls[0].origin ?? "direct socket")  \(calls[0].client)  \(calls.count) calls, "
                + "\(errors) errors  \(f.string(from: first))–\(f.string(from: last).suffix(5))")
        }
        return out.joined(separator: "\n")
    }

    /// Reads the audit log and its rotated predecessor, skipping lines that don't parse.
    public static func load(path: String = Paths.auditLog) -> [AuditEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return [path + ".1", path].flatMap { p -> [AuditEntry] in
            guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(AuditEntry.self, from: Data($0.utf8)) }
        }
    }

    /// "7d", "24h", "90m" → seconds.
    public static func interval(_ spec: String) -> TimeInterval? {
        guard let unit = spec.last, let n = Double(spec.dropLast()), n > 0 else { return nil }
        switch unit {
        case "d": return n * 86400
        case "h": return n * 3600
        case "m": return n * 60
        default: return nil
        }
    }

    static func percent(_ n: Int, _ total: Int) -> String { total == 0 ? "0%" : "\(Int((Double(n) / Double(total) * 100).rounded()))%" }
    static func duration(_ ms: Int) -> String { ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000) }
    static func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count) }
}
