import CoreGraphics
import Foundation
import Testing
import MacMCPCore

/// TestHost appends every user-visible state change to this log; actions are verified against it.
let eventsLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MacMCPTestHost/events.jsonl")

func events() -> [(kind: String, detail: String)] {
    guard let text = try? String(contentsOf: eventsLog, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return (o["kind"] as? String ?? "", o["detail"] as? String ?? "")
    }
}

func refFor(_ line: String, _ extra: [String: Any] = [:]) throws -> String {
    try #require(ref(of: line, in: try hostSnapshot(extra)), "no row containing \(line)")
}

extension Integration {
@Suite struct ActionTests {
    init() throws {
        try closeMenus()
        try hostURL("dismiss")
        try hostURL("reset")
        try? FileManager.default.removeItem(at: eventsLog)
    }

    @Test func typeVerifiesTheFieldValue() throws {
        let r = try agent().call("mac_type", ["ref": try refFor("textfield \"Name\""), "text": "Ada Lovelace"])
        #expect(!r.isError, "\(r.text)")
        #expect(r.text.contains("field value verified"))
        #expect(r.text.contains("value \"\" → \"Ada Lovelace\""), "\(r.text)")
        #expect(events().last { $0.kind == "name" }?.detail == "Ada Lovelace")
    }

    @Test func passwordTextNeverAppearsInResponses() throws {
        let r = try agent().call("mac_type", ["ref": try refFor("password \"Password\""), "text": "s3cret-typed"])
        #expect(!r.isError, "\(r.text)")
        #expect(!r.text.contains("s3cret-typed") && r.text.contains("password field"))
    }

    @Test func clickTogglesCheckboxAndReportsDiff() throws {
        let r = try agent().call("mac_click", ["ref": try refFor("checkbox \"Bacon\"")])
        #expect(!r.isError && r.text.contains("states +checked -unchecked"), "\(r.text)")
        #expect(events().contains { $0 == ("bacon", "true") })
    }

    @Test func popupMenuItemsAppearAndCanBeChosen() throws {
        let opened = try agent().call("mac_click", ["ref": try refFor("popup \"Size\"")])
        let medium = try #require(ref(of: "menuitem \"Medium\"", in: opened.text), "menu items not in diff:\n\(opened.text)")
        let chosen = try agent().call("mac_click", ["ref": medium])
        #expect(chosen.text.contains("value \"Small\" → \"Medium\""), "\(chosen.text)")
        #expect(events().contains { $0 == ("size", "Medium") })
    }

    @Test func submitShowsStatusChange() throws {
        let r = try agent().call("mac_click", ["ref": try refFor("button \"Submit\"")])
        #expect(r.text.contains("+ text \"Submitted:"), "\(r.text)")
        #expect(events().contains { $0.kind == "submit" })
    }

    @Test func openMenuIsReportedAndClosedForMenuCommands() throws {
        let opened = try agent().call("mac_click", ["ref": try refFor("popup \"Size\"")])
        #expect(opened.text.contains("a menu is open"), "\(opened.text)")
        let ok = try agent().call("mac_menu", ["app": hostApp, "path": "Test > Say Hello"])
        #expect(ok.text.contains("Menu: Say Hello") && ok.text.contains("blockers: none"), "\(ok.text)")
    }

    @Test func menuByPathAndHelpfulErrors() throws {
        let ok = try agent().call("mac_menu", ["app": hostApp, "path": "Test > Say Hello"])
        #expect(!ok.isError && ok.text.contains("+ text \"Menu: Say Hello\""), "\(ok.text)")
        let bad = try agent().call("mac_menu", ["app": hostApp, "path": ["Test", "Nope"]])
        #expect(bad.isError && unmarked(bad.text).contains("Available: \"Say Hello\""), "\(bad.text)")
    }

    @Test func keyboardShortcut() throws {
        _ = try agent().call("mac_app", ["action": "activate", "app": hostApp])
        let r = try agent().call("mac_key", ["keys": "cmd+shift+h", "app": hostApp])
        #expect(!r.isError && r.text.contains("Menu: Say Hello"), "\(r.text)")
    }

    @Test func sheetAppearsInResponseAndCanBeAnswered() throws {
        let opened = try agent().call("mac_click", ["ref": try refFor("button \"Show Sheet\"")])
        #expect(opened.text.contains("blockers: sheet") && opened.text.contains("current state:"), "\(opened.text)")
        let save = try #require(ref(of: "button \"Save\"", in: opened.text))
        let saved = try agent().call("mac_click", ["ref": save])
        #expect(saved.text.contains("blockers: none"), "\(saved.text)")
        #expect(events().contains { $0 == ("sheet", "save") })
    }

    /// Accessibility presses reach controls behind a sheet; MacMCP refuses them the way the sheet refuses a person.
    @Test func controlBehindASheetIsRefused() throws {
        let bacon = try refFor("checkbox \"Bacon\"")
        let opened = try agent().call("mac_click", ["ref": try refFor("button \"Show Sheet\"")])
        #expect(opened.text.contains("blockers: sheet"), "\(opened.text)")
        let r = try agent().call("mac_click", ["ref": bacon])
        #expect(r.isError && r.text.contains("has to be answered first"), "\(r.text)")
        #expect(!events().contains { $0.kind == "bacon" })
    }

    @Test func staleRefIsReportedNotClickedBlindly() throws {
        let opened = try agent().call("mac_click", ["ref": try refFor("button \"Show Sheet\"")])
        let cancel = try #require(ref(of: "button \"Cancel\"", in: opened.text))
        try hostURL("dismiss")   // the sheet goes away behind the agent's back
        let r = try agent().call("mac_click", ["ref": cancel])
        #expect(r.isError && r.text.contains("no longer exists"), "\(r.text)")
    }

    @Test func scrollToOffscreenRef() throws {
        let item = try refFor("row \"Item 60\"", ["offscreen": true, "query": "Item 60"])
        let r = try agent().call("mac_scroll", ["to_ref": item])
        #expect(!r.isError, "\(r.text)")
        #expect(try hostSnapshot(["query": "Item 60"]).contains("row \"Item 60\""))
    }

    @Test func clickByScreenshotPixel() throws {
        let shot = try agent().call("mac_screenshot", ["app": hostApp, "max_edge": 2000])
        let id = try #require(shot.text.split(separator: " ").dropFirst().first.map { String($0).replacingOccurrences(of: ":", with: "") })
        // Submit's frame, mapped into the window screenshot: offset from the area it covers, divided by its scale.
        let snap = try hostSnapshot(["query": "Submit", "frames": true])
        let line = try #require(snap.split(separator: "\n").first { $0.contains("button \"Submit\"") })
        let nums = line.split(separator: "@")[1].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" }).compactMap { Int($0) }
        let covers = shot.text.components(separatedBy: "covers ")[1].split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        let ptPerPx = try #require(shot.text.firstMatch(of: /1 px = ([0-9.]+) pt/).flatMap { Double($0.1) })
        let px = Int(Double(nums[0] + nums[2] / 2 - covers[0]) / ptPerPx)
        let py = Int(Double(nums[1] + nums[3] / 2 - covers[1]) / ptPerPx)
        let r = try agent().call("mac_click", ["x": px, "y": py, "screenshot_id": id, "app": hostApp])
        #expect(r.text.contains("Submitted:"), "\(r.text)")
    }

    @Test func pointInAnotherAppIsRefused() throws {
        // Just beside the host's window: whatever is there (another window, the desktop) isn't the host. Earlier tests
        // move the window, so take whichever side is still on a display.
        let list = try agent().call("mac_window", ["action": "list", "app": hostApp]).text
        let frame = try #require(list.firstMatch(of: /@(-?\d+),(-?\d+) (\d+)x(\d+)/))
        let y = Int(frame.2)! + Int(frame.4)! / 2
        let right = Int(frame.1)! + Int(frame.3)! + 150, left = Int(frame.1)! - 150
        var displays: UInt32 = 0
        let x = CGGetDisplaysWithPoint(CGPoint(x: right, y: y), 0, nil, &displays) == .success && displays > 0 ? right : left
        let r = try agent().call("mac_click", ["x": x, "y": y, "app": hostApp])
        #expect(r.isError, "\(r.text)")
        #expect(r.text.contains("is covered by"), "\(r.text)")
    }

    @Test func waitForText() throws {
        _ = try agent().call("mac_click", ["ref": try refFor("button \"Submit\"")])
        let r = try agent().call("mac_wait", ["app": hostApp, "until": "text", "query": "Submitted", "timeout": 5])
        #expect(!r.isError && r.text.contains("met after"), "\(r.text)")
        let gone = try agent().call("mac_wait", ["app": hostApp, "until": "gone", "query": "Submitted", "timeout": 1])
        #expect(gone.isError && gone.text.contains("Timed out"))
    }

    @Test func clipboardRoundTrip() throws {
        _ = try agent().call("mac_clipboard", ["action": "set", "text": "from the clipboard"])
        #expect(try agent().call("mac_clipboard", ["action": "get"]).text.contains("from the clipboard"))
    }

    @Test func waitAndSnapshotFindTextBeyondTheDisplayLimit() throws {
        let tail = "UniqueAuditTail"
        let name = try refFor("textfield \"Name\"")
        let typed = try agent().call("mac_type", ["ref": name, "text": String(repeating: "x", count: 150) + tail])
        #expect(!typed.isError, "\(typed.text)")
        let snapshot = try hostSnapshot(["query": tail])
        #expect(snapshot.contains("textfield \"Name\""), "\(snapshot)")
        let found = try agent().call("mac_wait", ["app": hostApp, "until": "text", "query": tail, "timeout": 2])
        #expect(!found.isError, "\(found.text)")
        let gone = try agent().call("mac_wait", ["app": hostApp, "until": "gone", "query": tail, "timeout": 1])
        #expect(gone.isError && gone.text.contains("Timed out"), "\(gone.text)")
    }

    @Test func keyRepeatPreservesTheWholeSequence() throws {
        let name = try refFor("textfield \"Name\"")
        #expect(!(try agent().call("mac_type", ["ref": name, "text": "old"])).isError)
        #expect(!(try agent().call("mac_key", ["app": hostApp, "keys": "cmd+a"])).isError)
        let repeated = try agent().call("mac_key", ["app": hostApp, "keys": ["a", "b"], "repeat": 2])
        #expect(!repeated.isError, "\(repeated.text)")
        #expect(try hostSnapshot(["query": "Name"]).contains("= \"abab\""))
    }

    @Test func scriptPolicyRefusals() throws {
        let notAllowed = try agent().call("mac_script", ["source": "tell application \"\(hostApp)\" to get name"])
        #expect(notAllowed.isError && notAllowed.text.contains("allowed_apps"))
        let shell = try agent().call("mac_script", ["source": "do shell script \"id\""])
        #expect(shell.isError && shell.text.contains("do shell script"))
    }

    @Test func refusesUnknownRef() throws {
        let r = try agent().call("mac_click", ["ref": "e999999"])
        #expect(r.isError && r.text.contains("Unknown ref"))
    }
}
}
