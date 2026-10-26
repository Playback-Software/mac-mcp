import Foundation
import Testing
import MacMCPCore

/// End-to-end tests against the installed agent and the TestHost fixture app.
///   scripts/build.sh && scripts/build-testhost.sh && MAC_MCP_INTEGRATION=1 swift test --filter IntegrationTests
/// Needs a logged-in, unlocked GUI session and both permissions granted to MacMCP.
let integrationEnabled = ProcessInfo.processInfo.environment["MAC_MCP_INTEGRATION"] == "1" && guiFree
/// These tests drive the real GUI (some through `open`, past the agent), so they stand down while someone else holds
/// the GUI lease. scripts/integration.sh takes the lease for the run and passes its token in MAC_MCP_LEASE.
let guiFree: Bool = {
    guard let lease = LeaseStore.current(), lease.token != LeaseStore.ownToken else { return true }
    print("Integration tests skipped: the GUI is leased by \(lease.summary).")
    return false
}()
let hostApp = "MacMCPTestHost"

/// Every integration test drives the same GUI, so all suites nest here and run strictly one at a time.
@Suite(.serialized, .enabled(if: integrationEnabled)) struct Integration {}

/// 90 s: the first web_* call after an agent restart starts a new automation Safari, which can take over 30 s.
func agent() throws -> AgentClient { try AgentClient(clientName: "integration-tests", version: "1", timeout: 90) }

func hostSnapshot(_ extra: [String: Any] = [:]) throws -> String {
    let r = try agent().call("mac_snapshot", ["app": hostApp].merging(extra) { $1 })
    #expect(!r.isError, "mac_snapshot failed: \(r.text)")
    return r.text
}

/// A menu left open by a failed test would block the next one.
func closeMenus() throws {
    if try agent().call("mac_snapshot", ["app": hostApp, "max_tokens": 200]).text.contains("a menu is open") {
        _ = try agent().call("mac_key", ["keys": "esc", "app": hostApp])
    }
}

/// Opens a macmcp-testhost:// URL in the host (launching it if needed) and gives SwiftUI a moment to update.
func hostURL(_ command: String) throws {
    let r = try agent().call("mac_app", ["action": "launch", "app": "com.playbacksoftware.macmcp.testhost",
                                          "open": "macmcp-testhost://\(command)"])
    #expect(!r.isError, "launch failed: \(r.text)")
    // Wait for TestHost to apply it (a fixed sleep raced with SwiftUI's update).
    Thread.sleep(forTimeInterval: 0.2)
    _ = try agent().call("mac_wait", ["app": hostApp, "until": "settled", "timeout": 5])
}

/// The ref on the first line containing `line`, in a snapshot or a diff ("+ e30 menuitem …").
func ref(of line: String, in snapshot: String) -> String? {
    snapshot.split(separator: "\n").first { $0.contains(line) }?
        .split(separator: " ").map(String.init).first { $0.range(of: #"^e\d+$"#, options: .regularExpression) != nil }
}

extension Integration {
@Suite struct PerceptionTests {
    init() throws { try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

    @Test func toolSurface() throws {
        let tools = try agent().listTools()
        for t in ["mac_snapshot", "mac_screenshot", "mac_app", "mac_window", "mac_doctor"] { #expect(tools.contains(t)) }
    }

    @Test func snapshotShowsKnownControlsAndHidesSecrets() throws {
        let s = try hostSnapshot()
        #expect(s.contains("window \"MacMCP Test Host\""))
        #expect(s.contains("blockers: none"))
        for expected in ["heading \"Order Form\"", "textfield \"Name\" = \"\"", "password \"Password\"",
                         "checkbox \"Bacon\" [unchecked]", "popup \"Size\" = \"Small\"", "heading \"Toppings\"", "button \"Submit\"",
                         "text \"Nothing submitted yet.\""] {
            #expect(s.contains(expected), "missing \(expected) in:\n\(s)")
        }
        #expect(!s.contains("hunter2"))
        #expect(!s.contains("text \"Size\""), "the popup's label shouldn't be repeated as text")
    }

    @Test func refsAreStableAcrossSnapshots() throws {
        let a = try hostSnapshot(), b = try hostSnapshot()
        let ra = ref(of: "button \"Submit\"", in: a), rb = ref(of: "button \"Submit\"", in: b)
        #expect(ra != nil && ra == rb)
        #expect(ra?.hasPrefix("e") == true)
    }

    @Test func rawSnapshotAlsoHidesPasswordValues() throws {
        let raw = try hostSnapshot(["raw": true])
        #expect(!raw.contains("hunter2"), "Raw snapshots must apply secure-field masking")
    }

    @Test func queryFiltersRows() throws {
        let s = try hostSnapshot(["query": "bacon"])
        let rows = s.split(separator: "\n").filter { $0.contains("checkbox") || $0.contains("button") || $0.contains("textfield") }
        #expect(rows.count == 1 && rows[0].contains("Bacon"))
    }

    @Test func offscreenRowsAreSkippedUnlessAsked() throws {
        let clipped = try hostSnapshot(["max_tokens": 4000])
        #expect(clipped.contains("offscreen elements skipped"))
        #expect(!clipped.contains("\"Item 60\""))
        let full = try hostSnapshot(["offscreen": true, "max_tokens": 6000])
        #expect(full.contains("\"Item 60\""))
    }

    @Test func sheetIsReportedAsBlockerAndBecomesTheRoot() throws {
        try hostURL("sheet")
        let s = try hostSnapshot()
        #expect(s.contains("blockers: sheet"), "no sheet blocker in:\n\(s)")
        #expect(s.contains("Save changes before closing?"))
        #expect(s.contains("button \"Save\"") && s.contains("button \"Cancel\""))
        #expect(!s.contains("button \"Submit\""), "the blocked window's controls should not be listed")
        let dialog = try agent().call("mac_snapshot", ["app": hostApp, "scope": "dialog"])
        #expect(!dialog.isError && dialog.text.contains("button \"Save\""))
        try hostURL("dismiss")
        #expect(try hostSnapshot().contains("blockers: none"))
    }

    @Test func alertIsReportedAsBlocker() throws {
        try hostURL("alert")
        let s = try hostSnapshot()
        #expect(!s.contains("blockers: none"), "alert not reported:\n\(s)")
        #expect(s.contains("Delete everything?"))
        try hostURL("dismiss")
    }

    @Test func dialogScopeFailsClearlyWithoutDialog() throws {
        let r = try agent().call("mac_snapshot", ["app": hostApp, "scope": "dialog"])
        #expect(r.isError && r.text.contains("no sheet or dialog"))
    }

    @Test func screenshotOfHostWindow() throws {
        let r = try agent().call("mac_screenshot", ["app": hostApp, "max_edge": 640])
        #expect(!r.isError, "\(r.text)")
        #expect(r.text.contains("screenshot c") && r.text.contains("MacMCPTestHost window"))
        let png = try #require(r.images.first)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func windowListAndResize() throws {
        let list = try agent().call("mac_window", ["action": "list", "app": hostApp])
        #expect(list.text.contains("\"MacMCP Test Host\""))
        let r = try agent().call("mac_window", ["action": "resize", "app": hostApp, "width": 600, "height": 720])
        #expect(!r.isError && r.text.contains("600x720"), "\(r.text)")
    }

    @Test func unknownAppGivesActionableError() throws {
        let r = try agent().call("mac_snapshot", ["app": "NoSuchApp12345"])
        #expect(r.isError && r.text.contains("No running app matches") && r.text.contains("mac_app action=launch"))
    }
}
}
