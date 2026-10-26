import Testing
@testable import MacMCPCore

@Suite struct SessionSafetyTests {
    @Test func appleMenuSessionItemsAreRefused() {
        for item in ["Log Out Ada Lovelace…", "Restart…", "Shut Down...", "Sleep", "Lock Screen"] {
            #expect(SessionSafety.refusal(menuPath: ["Apple", item]) != nil, "\(item)")
        }
        #expect(SessionSafety.refusal(menuPath: ["Apple", "About This Mac"]) == nil)
        #expect(SessionSafety.refusal(menuPath: ["Debug", "Restart"]) == nil)   // an app's own command
        #expect(SessionSafety.refusal(menuPath: ["File", "Save As…"]) == nil)
    }

    @Test func logOutAndLockShortcutsAreRefused() throws {
        for keys in ["cmd+shift+q", "cmd+opt+shift+q", "ctrl+cmd+q", "esc, cmd+shift+q"] {
            #expect(SessionSafety.refusal(keys: try KeySpec.parseSequence(keys)) != nil, "\(keys)")
        }
        for keys in ["cmd+q", "cmd+s", "shift+q", "q"] {
            #expect(SessionSafety.refusal(keys: try KeySpec.parseSequence(keys)) == nil, "\(keys)")
        }
    }

    @Test func sessionScriptsAreRefusedButStringsAreNot() {
        let bad = ["tell application \"System Events\" to log out", "tell application \"Finder\" to restart",
                   "tell app \"Finder\"\nshut down\nend tell", "tell application \"loginwindow\" to «event aevtrlgo»"]
        for s in bad { #expect(SessionSafety.refusal(script: s, language: .applescript) != nil, "\(s)") }
        #expect(SessionSafety.refusal(script: "Application('System Events').restart()", language: .jxa) != nil)
        let ok = ["tell application \"TextEdit\" to set text of document 1 to \"restart the server, then sleep\"",
                  "tell application \"Notes\" to get name of notes"]
        for s in ok { #expect(SessionSafety.refusal(script: s, language: .applescript) == nil, "\(s)") }
    }

    @Test func quotesInCommentsDontHideSessionCommands() {
        // AppleScript has no single-quoted strings: apostrophes used to blank everything between them.
        let sneaky = "-- don't\ntell application \"System Events\" to restart\n-- won't"
        #expect(SessionSafety.refusal(script: sneaky, language: .applescript) != nil)
        let jsSneaky = "// don't\nApplication('System Events').restart()\n// won't"
        #expect(SessionSafety.refusal(script: jsSneaky, language: .jxa) != nil)
        #expect(SessionSafety.refusal(script: "-- restart the server later\ntell application \"Notes\" to get name",
                                      language: .applescript) == nil)
    }

    @Test func loginwindowIsAlwaysOffLimits() {
        #expect(Policy().refusal(bundleID: "com.apple.loginwindow", name: "loginwindow") != nil)
        #expect(Policy(allowApps: ["com.apple.loginwindow"]).refusal(bundleID: "com.apple.loginwindow", name: nil) != nil)
    }
}
