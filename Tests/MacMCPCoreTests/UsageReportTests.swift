import Foundation
import Testing
@testable import MacMCPCore

@Suite struct UsageReportTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func entry(_ tool: String, _ outcome: String = "ok", detail: String? = nil, ms: Int = 100, client: String = "claude-code 2.1.294",
               session: String? = "s1", origin: String? = "local", lease: String? = nil, args: [String: String] = [:],
               at offset: TimeInterval = 60) -> AuditEntry {
        AuditEntry(time: t0.addingTimeInterval(offset), client: client, tool: tool, arguments: args, outcome: outcome,
                   detail: detail, durationMs: ms, session: session, origin: origin, lease: lease)
    }

    @Test func classifiesRealUseApartFromEvalsTestsAndOldEntries() {
        #expect(UsageReport.kind(entry("mac_click")) == .real)
        #expect(UsageReport.kind(entry("mac_click", lease: "eval-run")) == .leased)
        #expect(UsageReport.kind(entry("mac_click", client: "integration-tests 1")) == .test)
        #expect(UsageReport.kind(entry("mac_click", client: "soak-0 soak")) == .test)
        #expect(UsageReport.kind(entry("mac_doctor", client: "mac-mcp-cli 0.1.0")) == .cli)
        #expect(UsageReport.kind(entry("mac_click", session: nil, origin: nil)) == .legacy)
    }

    @Test func routesSeparateGUIInputFromDirectPathsAndLooking() {
        #expect(UsageReport.route(entry("mac_click")) == .gui)
        #expect(UsageReport.route(entry("mac_menu")) == .direct)
        #expect(UsageReport.route(entry("web_act")) == .direct)
        #expect(UsageReport.route(entry("web_read")) == .perception)
        #expect(UsageReport.route(entry("mac_window", args: ["action": "list"])) == .perception)
        #expect(UsageReport.route(entry("mac_window", args: ["action": "move"])) == .other)
    }

    @Test func similarErrorsClusterTogether() {
        let a = UsageReport.cluster("Ref e293 (button \"OK\") no longer exists: the UI changed. Call mac_snapshot.")
        let b = UsageReport.cluster("Ref e17 (button \"Cancel\") no longer exists: the UI changed. Call mac_snapshot.")
        #expect(a == b && a.contains("eN") && !a.contains("Call mac_snapshot"))
    }

    @Test func reportSummarisesOnlyRealSessions() {
        let entries = [
            entry("mac_snapshot"), entry("mac_click"), entry("mac_menu", ms: 2500),
            entry("mac_click", "error", detail: "Ref e5 (button \"OK\") no longer exists: the UI changed."),
            entry("mac_click", "error", detail: "Ref e9 (button \"Go\") no longer exists: the UI changed."),
            entry("mac_type", "error", detail: "Refused by policy: Keychain Access is on the deny list."),
            entry("mac_snapshot", session: "s2", origin: "ssh:10.0.0.18"),
            entry("mac_click", lease: "eval-run"), entry("mac_click", client: "integration-tests 1"),
            entry("mac_click", at: -86400 * 30),   // outside the window
        ]
        let text = UsageReport.render(entries, since: t0, now: t0.addingTimeInterval(3600))
        #expect(text.contains("Real use: 7 calls in 2 sessions (1 local, 1 ssh:10.0.0.18)"))
        #expect(text.contains("Excluded: 1 leased, 1 test (lease holders: eval-run)"))
        #expect(text.contains("2× mac_click: Ref eN (button \"…\") no longer exists: the UI changed"))
        #expect(text.contains("Refusals (1):"))
        #expect(text.contains("gui 57%") && text.contains("direct 14%") && text.contains("perception 29%"))
        #expect(text.contains("2.5 s  mac_menu ok"))
    }

    @Test func intervalSpecs() {
        #expect(UsageReport.interval("7d") == 7 * 86400 && UsageReport.interval("90m") == 5400)
        #expect(UsageReport.interval("x") == nil && UsageReport.interval("0d") == nil)
    }

    @Test func directiveCarriesOriginAndSession() {
        let line = String(decoding: AgentClient.directive(lease: nil, origin: "ssh:10.0.0.2", session: "ab12cd34")!, as: UTF8.self)
        #expect(line == "#mac-mcp origin=ssh:10.0.0.2 session=ab12cd34\n")
        #expect(AgentClient.directive(lease: nil) == nil)
        let ssh = ["SSH_CONNECTION": "10.0.0.18 52144 10.0.0.5 22"]
        // `ssh mini mac-mcp` from another machine: sshd runs the relay through the login shell.
        #expect(AgentClient.origin(environment: ssh, ancestors: ["zsh", "sshd-session", "sshd"]) == "ssh:10.0.0.18")
        // Claude Code started on this Mac from an SSH terminal: the relay's parent is the client.
        #expect(AgentClient.origin(environment: ssh, ancestors: ["claude", "-zsh", "sshd-session"]) == "local")
        #expect(AgentClient.origin(environment: [:], ancestors: ["sshd"]) == "local")
        #expect(!AgentClient.processAncestors().isEmpty)
    }
}
