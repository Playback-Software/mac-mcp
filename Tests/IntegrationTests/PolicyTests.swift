import Foundation
import Testing
import MacMCPCore

/// Runs a body with a temporary policy.json, restoring the person's real policy afterwards (even on failure).
func withPolicy(_ json: String, _ body: () throws -> Void) throws {
    let path = Paths.policyFile
    let saved = FileManager.default.contents(atPath: path)
    defer {
        if let saved { FileManager.default.createFile(atPath: path, contents: saved) } else { try? FileManager.default.removeItem(atPath: path) }
    }
    FileManager.default.createFile(atPath: path, contents: Data(json.utf8))
    try body()
}

extension Integration {
@Suite struct PolicyTests {
    init() throws { try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

    @Test func deniedAppIsInvisibleAndUntouchable() throws {
        let submit = try refFor("button \"Submit\"")
        try withPolicy(#"{"deny_apps": ["com.playbacksoftware.macmcp.testhost"]}"#) {
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("deny list"), "\(snap.text)")
            let click = try agent().call("mac_click", ["ref": submit])
            #expect(click.isError && click.text.contains("deny list"), "\(click.text)")
            let shot = try agent().call("mac_screenshot", ["app": hostApp])
            #expect(shot.isError)
            let display = try agent().call("mac_screenshot", ["max_edge": 400])
            #expect(!display.isError && display.text.contains("hidden by policy"), "\(display.text)")
            let list = try agent().call("mac_app", ["action": "list"])
            #expect(list.text.contains("MacMCPTestHost") && list.text.contains("[off-limits by policy]"))
        }
        #expect(!(try agent().call("mac_snapshot", ["app": hostApp])).isError, "policy restore failed")
    }

    @Test func allowListLimitsAgentsToNamedApps() throws {
        try withPolicy(#"{"allow_apps": ["Finder"]}"#) {
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("not in allow_apps"), "\(snap.text)")
            #expect(!(try agent().call("mac_snapshot", ["app": "Finder"])).isError)
        }
    }

    @Test func invalidPolicyBlocksActionsAndDoctorExplains() throws {
        let submit = try refFor("button \"Submit\"")
        try withPolicy("{ this is not json") {
            let click = try agent().call("mac_click", ["ref": submit])
            #expect(click.isError && click.text.contains("POLICY INVALID"), "\(click.text)")
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("POLICY INVALID"))
            #expect(try agent().call("mac_doctor").text.contains("!!  POLICY INVALID"))
        }
    }

    /// MacMCP has never sent Apple events to TestHost, so a script for it must fail at once instead of raising the
    /// Automation consent prompt and timing out. (If a person has granted it by hand, the script simply runs.)
    @Test func scriptWithoutAutomationGrantFailsFast() throws {
        try withPolicy(#"{"script": {"allowed_apps": ["com.playbacksoftware.macmcp.testhost"]}}"#) {
            let start = Date()
            let r = try agent().call("mac_script", ["source": "tell application id \"com.playbacksoftware.macmcp.testhost\" to get name",
                                                    "timeout": 20])
            #expect(Date().timeIntervalSince(start) < 5, "took \(Date().timeIntervalSince(start)) s: \(r.text)")
            #expect(!r.isError || r.text.contains("not authorized to control \(hostApp)"), "\(r.text)")
            let d = try agent().call("mac_doctor").text
            #expect(d.contains("Automation (mac_script") && d.contains("com.playbacksoftware.macmcp.testhost: "), "\(d)")
        }
    }

    @Test func doctorShowsPolicy() throws {
        try withPolicy(#"{"deny_apps": ["com.bank.app"], "alert_webhook": "https://ntfy.example/secret-topic"}"#) {
            let d = try agent().call("mac_doctor").text
            #expect(d.contains("deny_apps: com.bank.app"))
            #expect(d.contains("webhook to ntfy.example") && !d.contains("secret-topic"))
        }
    }
}
}
