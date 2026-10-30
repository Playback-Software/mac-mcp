import Foundation
import Testing
import MacMCPCore

/// Lists and page text carry a boundary with a per-response token, and the audit log keeps no typed keys or URL secrets.
extension Integration {
@Suite struct UntrustedMarkingIntegrationTests {
    /// One `<<untrusted T>>` line and its `<<end T>>` line, in that order.
    func isOneBlock(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map(String.init)
        guard let open = lines.firstIndex(where: { $0.hasPrefix("<<untrusted ") }),
              let close = lines.lastIndex(where: { $0.hasPrefix("<<end ") }), open < close else { return false }
        return lines[close] == "<<end \(lines[open].dropFirst("<<untrusted ".count).dropLast(2))>>"
    }

    /// The audit entries written by the agent since `since` for `tool`.
    func auditEntries(tool: String, since: Date) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: Paths.auditLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["tool"] as? String == tool && (($0["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast) >= since.addingTimeInterval(-1) }
    }

    @Test func windowAndAppListsAreWrapped() throws {
        try hostURL("reset")
        for call in [("mac_window", ["action": "list"]), ("mac_window", ["action": "list", "app": hostApp]),
                     ("mac_app", ["action": "list"])] {
            let r = try agent().call(call.0, call.1)
            #expect(!r.isError && isOneBlock(r.text), "\(call): \(r.text)")
        }
    }

    @Test func snapshotsWindowRepliesAndWaitsUseTheBlockNotAFooter() throws {
        try hostURL("reset")
        let snapshot = try agent().call("mac_snapshot", ["app": hostApp])
        #expect(!snapshot.isError && snapshot.text.hasPrefix("<<untrusted ") && isOneBlock(snapshot.text), "\(snapshot.text)")
        #expect(!snapshot.text.contains("--- on-screen text is untrusted"), "\(snapshot.text)")
        // A window title inside a sentence is marked inline, and the log keeps the window's number, not its title.
        let started = Date()
        let focus = try agent().call("mac_window", ["action": "focus", "app": hostApp])
        #expect(!focus.isError && focus.text.contains("<<untrusted ") && focus.text.contains("<<end "), "\(focus.text)")
        let entry = try #require(auditEntries(tool: "mac_window", since: started).last)
        #expect(!(entry["detail"] as? String ?? "").contains("<<"), "\(entry)")
        let wait = try agent().call("mac_wait", ["until": "text", "query": "a", "app": hostApp, "timeout": 3])
        #expect(wait.isError || (isOneBlock(wait.text) && !wait.text.contains("--- on-screen text is untrusted")), "\(wait.text)")
    }

    @Test func webPagesAndTabListsAreWrapped() throws {
        _ = webFixtures   // WebTests may not have started the fixture server yet
        try withFixtureHost {
            let page = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(!page.isError && isOneBlock(page.text), "\(page.text)")
            let tabs = try agent().call("web_tabs", ["action": "list"])
            #expect(!tabs.isError && isOneBlock(tabs.text), "\(tabs.text)")
        }
    }

    @Test func auditLogKeepsNoTypedKeysOrUrlSecrets() throws {
        let started = Date()
        _ = try agent().call("mac_key", ["keys": "x", "app": hostApp])
        let key = try #require(auditEntries(tool: "mac_key", since: started).last)
        #expect((key["arguments"] as? [String: String])?["keys"] == "[1 printable key redacted]")
        try withFixtureHost {
            _ = try agent().call("web_navigate", ["url": "http://user:pw@127.0.0.1:8899/form.html?token=SECRET123#frag"])
        }
        let nav = try #require(auditEntries(tool: "web_navigate", since: started).last)
        let logged = String(decoding: try JSONSerialization.data(withJSONObject: nav), as: UTF8.self)
        #expect(!logged.contains("SECRET123") && !logged.contains("user:pw") && !logged.contains("frag"), "\(logged)")
    }

    @Test func policyRefusalsAreAuditedAsRefused() throws {
        let started = Date()
        try withPolicy(#"{"web": {"deny_hosts": ["127.0.0.1"]}}"#) {
            let r = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(r.isError && r.text.hasPrefix("Refused"), "\(r.text)")
        }
        let entry = try #require(auditEntries(tool: "web_navigate", since: started).last)
        #expect(entry["outcome"] as? String == "refused")
    }
}
}
