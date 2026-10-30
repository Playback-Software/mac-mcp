import Foundation
import Testing
import MacMCPCore

/// Refs, snapshot ids and screenshot ids must mean one thing for as long as a client's session lasts, including
/// across an agent restart (the relay keeps the session), and a screenshot click must be checked against the screen
/// at the moment it runs.
extension Integration {
@Suite struct RefLifetimeTests {
    init() throws {
        try closeMenus(); try hostURL("dismiss"); try hostURL("reset")
        // Earlier suites click Submit; their events must not count as a click here.
        try? FileManager.default.removeItem(at: eventsLog)
    }

    func number(_ id: String) -> Int? { Int(id.dropFirst()) }

    /// The ids in a snapshot header ("snapshot s12") and a screenshot line ("screenshot c3: …").
    func snapshotID(_ text: String) throws -> String { try #require(text.firstMatch(of: /snapshot (s\d+)/).map { String($0.1) }) }
    func screenshotID(_ text: String) throws -> String { try #require(text.firstMatch(of: /screenshot (c\d+)/).map { String($0.1) }) }

    @Test func idsFromBeforeARestartAreRefusedNotRemapped() throws {
        let (client, relay) = try RelayTests().relaySession()
        defer { relay.terminate() }
        let snap = try client.call("mac_snapshot", ["app": hostApp])
        #expect(!snap.isError, "\(snap.text)")
        let oldRef = try #require(ref(of: "button \"Submit\"", in: snap.text))
        let oldSnapshot = try snapshotID(snap.text)
        let shot = try client.call("mac_screenshot", ["app": hostApp, "max_edge": 400])
        let oldShot = try screenshotID(shot.text)

        // Restart the agent under the same relay session.
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/sh")
        kick.arguments = ["-c", "launchctl kickstart -k gui/$(id -u)/\(Paths.launchAgentLabel)"]
        try kick.run()
        kick.waitUntilExit()
        #expect(kick.terminationStatus == 0)
        var doctor = try client.call("mac_doctor")
        for _ in 0..<20 where doctor.text.hasPrefix("protocol error") || doctor.isError {
            Thread.sleep(forTimeInterval: 0.5)
            doctor = try client.call("mac_doctor")
        }

        // New ids continue above the old ones, so nothing a client still holds can be reused.
        let again = try client.call("mac_snapshot", ["app": hostApp])
        #expect(!again.isError, "\(again.text)")
        let newRef = try #require(ref(of: "button \"Submit\"", in: again.text))
        #expect(try #require(number(newRef)) > (number(oldRef) ?? 0), "\(oldRef) → \(newRef)")
        #expect(try #require(number(try snapshotID(again.text))) > (number(oldSnapshot) ?? 0))
        let newShot = try client.call("mac_screenshot", ["app": hostApp, "max_edge": 400])
        #expect(try #require(number(try screenshotID(newShot.text))) > (number(oldShot) ?? 0))

        // The old ids are refused with a reason, never resolved to something else.
        let click = try client.call("mac_click", ["ref": oldRef])
        #expect(click.isError && click.text.contains("before the agent restarted"), "\(click.text)")
        let pixel = try client.call("mac_click", ["x": 1, "y": 1, "screenshot_id": oldShot, "app": hostApp])
        #expect(pixel.isError && pixel.text.contains("before the agent restarted"), "\(pixel.text)")
        #expect(!events().contains { $0.kind == "submit" }, "nothing may have been clicked")
    }

    @Test func aScreenshotClickIsCheckedAgainstTheWindowWhenItRuns() throws {
        let shot = try agent().call("mac_screenshot", ["app": hostApp, "max_edge": 400])
        let id = try screenshotID(shot.text)
        let list = try agent().call("mac_window", ["action": "list", "app": hostApp]).text
        let frame = try #require(list.firstMatch(of: /@(-?\d+),(-?\d+) (\d+)x(\d+)/))
        let x = Int(frame.1)!, y = Int(frame.2)!
        defer { _ = try? agent().call("mac_window", ["action": "move", "app": hostApp, "x": x, "y": y]) }
        let moved = try agent().call("mac_window", ["action": "move", "app": hostApp, "x": x + 40, "y": y])
        #expect(!moved.isError, "\(moved.text)")
        // The pixels still parse; it's the click that must notice the window moved after the screenshot was taken.
        let r = try agent().call("mac_click", ["x": 10, "y": 10, "screenshot_id": id, "app": hostApp])
        #expect(r.isError && r.text.contains("moved or resized"), "\(r.text)")
    }
}

/// D1: snapshots an action takes for itself must not launder a stale ref. The agent saw "Submit"; the button was
/// renamed; a drag's destination snapshot and a wait's polling both see the new title, and neither may count as
/// having shown it to the agent.
@Suite struct InternalSnapshotGuardTests {
    init() throws {
        try closeMenus(); try hostURL("dismiss"); try hostURL("reset")
        try? FileManager.default.removeItem(at: eventsLog)
    }

    @Test func aDragOntoARenamedDestinationIsRefused() throws {
        let snap = try hostSnapshot()
        let source = try #require(ref(of: "button \"Move Me\"", in: snap))
        let destination = try #require(ref(of: "button \"Submit\"", in: snap))
        try hostURL("rename")
        let r = try agent().call("mac_drag", ["from_ref": source, "to_ref": destination, "hold_ms": 50, "dwell_ms": 50])
        #expect(r.isError && unmarked(r.text).contains("was Submit but now reads Send Order"), "\(r.text)")
        #expect(!events().contains { $0.kind == "submit" || $0.kind == "move" }, "nothing may have been dragged or pressed")
    }

    @Test func aWaitsPollingDoesNotMakeARenamedRefAcceptable() throws {
        let snap = try hostSnapshot()
        let submit = try #require(ref(of: "button \"Submit\"", in: snap))
        try hostURL("rename")
        // The wait polls the whole window (which now shows "Send Order") but returns only the Bacon row.
        let waited = try agent().call("mac_wait", ["app": hostApp, "until": "element", "query": "Bacon", "timeout": 5])
        #expect(!waited.isError && waited.text.contains("checkbox \"Bacon\"") && !waited.text.contains("Send Order"), "\(waited.text)")
        let click = try agent().call("mac_click", ["ref": submit])
        #expect(click.isError && unmarked(click.text).contains("was Submit but now reads Send Order"), "\(click.text)")
        #expect(!events().contains { $0.kind == "submit" })
        // A fresh snapshot shows the new title, after which the ref is usable again.
        let again = try hostSnapshot()
        #expect(ref(of: "button \"Send Order\"", in: again) == submit, "a renamed button keeps its ref")
        let ok = try agent().call("mac_click", ["ref": submit])
        #expect(!ok.isError, "\(ok.text)")
        #expect(events().contains { $0.kind == "submit" })
    }
}
}
