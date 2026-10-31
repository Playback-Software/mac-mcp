import Testing
@testable import MacMCPCore

@Suite struct BackgroundMenuTests {
    @Test(arguments: ["toggleFullScreen:", "performMiniaturize:", "performZoom:", "miniaturizeAll:", "arrangeInFront:",
                      "hide:", "hideOtherApplications:", "terminate:", "performClose:", "forceQuit:", "copy:", "cut:"])
    func commandMetadataRefusesInAnyLanguage(_ command: String) {
        for item in [BackgroundMode.MenuIdentity(identifier: command, title: "Localized command"),
                     .init(identifier: "application.command", actions: [command], title: "Localized command")] {
            #expect(BackgroundMode.menuRefusal([item])?.contains("background mode") == true)
        }
    }

    @Test func windowMenuAncestryCoversDynamicMoveTileAndWindowSelection() {
        for command in ["Move & Resize", "Move to Display", "Tile Window to Left of Screen", "Document 1"] {
            #expect(BackgroundMode.menuRefusal([.init(identifier: "dynamic.item", title: command),
                                               .init(identifier: "_NS:WindowMenu", title: "Localized menu")]) != nil)
            #expect(BackgroundMode.menuRefusal([.init(title: command), .init(title: "Window")]) != nil)
        }
        for identifier in ["com.apple.moveWindowToDisplay:", "_tileWindowLeft:", "moveToActiveSpace:"] {
            #expect(BackgroundMode.menuRefusal([.init(identifier: identifier, title: "Localized command")]) != nil)
        }
    }

    @Test func titlesAreOnlyAFallbackForMissingIdentifiers() {
        for title in ["Minimize", "Zoom", "Enter Full Screen", "Exit Full Screen", "Hide TestHost", "Hide Others",
                      "Quit TestHost…", "Force Quit…", "Copy", "Cut", "Close Window"] {
            #expect(BackgroundMode.menuRefusal([.init(title: title)]) != nil)
            #expect(BackgroundMode.menuRefusal([.init(identifier: "custom.harmless", title: title)]) == nil)
        }
        #expect(BackgroundMode.menuRefusal([.init(identifier: " ", title: "Copy")]) != nil)
        #expect(BackgroundMode.menuRefusal([.init(identifier: "safe.parent", title: "Formatting", submenu: true)])?.contains("mac_menu") == true)
    }

    @Test func harmlessAXCommandDoesNotInheritItsKeyEquivalentRefusal() throws {
        for key in ["shift+cmd+h", "f5", "ctrl+cmd+f"] {
            #expect(BackgroundMode.keyRefusal(try KeySpec.parse(key)) != nil)
            #expect(BackgroundMode.menuRefusal([.init(actions: ["AXPress"], title: "Say Hello"), .init(title: "Test")]) == nil)
        }
        #expect(BackgroundMode.menuRefusal([.init(identifier: "sayHello:", actions: ["AXPress"], title: "Say Hello")]) == nil)
    }
}
