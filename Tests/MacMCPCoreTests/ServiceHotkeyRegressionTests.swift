import Foundation
import SQLite3
import Testing
@testable import MacMCPCore

@Suite struct ServiceHotkeyRegressionTests {
    @Test func declaredTerminalDefaultsAndUserServicesOverridesAreBlockedWithoutSpotlightPolicy() throws {
        let declarations: [[String: Any]] = [
            ["NSMenuItem": ["default": "Open man Page in Terminal"], "NSMessage": "openManPage", "NSKeyEquivalent": ["default": "M"]],
            ["NSMenuItem": ["default": "Disabled"], "NSMessage": "disabled", "NSKeyEquivalent": ["default": "D"]],
            ["NSMenuItem": ["default": "Reassigned"], "NSMessage": "reassigned", "NSKeyEquivalent": ["default": "R"]],
        ]
        let status: [String: Any] = [
            "provider - Disabled - disabled": ["enabled_services_menu": false, "enabled_context_menu": false],
            "provider - Reassigned - reassigned": ["key_equivalent": "^~@r"],
            "custom workflow": ["key_equivalent": "@$j"],
        ]
        let keys = ServiceHotkeys.equivalents(status: status, services: declarations)
        #expect(keys.contains(try KeySpec.parse("shift+cmd+m")))
        #expect(keys.contains(try KeySpec.parse("ctrl+alt+cmd+r")))
        #expect(keys.contains(try KeySpec.parse("shift+cmd+j")))
        #expect(!keys.contains(try KeySpec.parse("shift+cmd+d")))
        #expect(!keys.contains(try KeySpec.parse("shift+cmd+r")))
        for text in ["shift+cmd+m", "ctrl+alt+cmd+r", "shift+cmd+j"] {
            #expect(OpenRoutes.launcherKeyRefusal([try KeySpec.parse(text)], policy: Policy(denyApps: []), hotkeys: [], serviceKeys: keys) != nil)
        }
        #expect(OpenRoutes.launcherKeyRefusal([try KeySpec.parse("cmd+s")], policy: Policy(), hotkeys: [], serviceKeys: keys) == nil)
    }

    @Test func emptyServiceOverrideRemovesDefaultAndLocalizedEquivalentsAreCollected() throws {
        let declarations: [[String: Any]] = [["NSMenuItem": ["default": "Example"], "NSMessage": "example",
                                             "NSKeyEquivalent": ["default": "E", "fr": "F"]]]
        let status: [String: Any] = ["provider - Example - example": ["key_equivalent": ""]]
        #expect(ServiceHotkeys.equivalents(status: status, services: declarations).isEmpty)
        #expect(ServiceHotkeys.equivalents(status: [:], services: declarations).contains(try KeySpec.parse("cmd+shift+f")))
        #expect(ServiceHotkeys.equivalent("^~@m") == (try KeySpec.parse("ctrl+alt+cmd+m")))
        #expect(ServiceHotkeys.equivalent("") == nil)
        #expect(!ServiceHotkeys.enabled(["presentation_modes": ["ServicesMenu": false, "ContextMenu": false]]))
        // A similarly named service must not suppress a provider's default key equivalent.
        let unrelated: [String: Any] = ["provider - Other Example - example": ["key_equivalent": ""]]
        #expect(ServiceHotkeys.equivalents(status: unrelated, services: declarations).contains(try KeySpec.parse("cmd+shift+e")))
    }

    @Test func readableGlobalShortcutRecordsAndPlistBlobsAreCollected() throws {
        let record: [String: Any] = ["keyCode": 40, "modifierFlags": 1 << 20 | 1 << 19]
        let prefs: [String: Any] = ["WFKeyboardShortcuts": [record]]
        let blob = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
        for value: Any in [prefs, blob] {
            let keys = ServiceHotkeys.shortcutEquivalents(value)
            #expect(keys == [try KeySpec.parse("cmd+alt+k")])
            #expect(OpenRoutes.launcherKeyRefusal(keys, policy: Policy(denyApps: []), hotkeys: [], serviceKeys: keys) != nil)
        }
        #expect(ServiceHotkeys.shortcutEquivalents(["keyCode": -1, "modifierFlags": 0]).isEmpty)
        #expect(ServiceHotkeys.shortcutEquivalents(["name": "cmd+o"]).isEmpty)
    }

    @Test func readableShortcutsDatabaseColumnsIncludeQuickActionConfiguration() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let plist: [String: Any] = ["WFWorkflowQuickActionKeyboardShortcut": ["keyCode": 40, "modifierFlags": 1 << 20 | 1 << 19]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        for column in ["ZKEYBOARDSHORTCUT", "ZQUICKACTIONCONFIGURATION"] {
            #expect(sqlite3_exec(db, "CREATE TABLE ZWORKFLOW (" + column + " BLOB)", nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(db, "INSERT INTO ZWORKFLOW VALUES (X'" + hex + "')", nil, nil, nil) == SQLITE_OK)
            let keys = ServiceHotkeys.databaseKeys(db, deadline: ProcessInfo.processInfo.systemUptime + 1)
            #expect(keys == [try KeySpec.parse("cmd+alt+k")])
            #expect(sqlite3_exec(db, "DROP TABLE ZWORKFLOW", nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func discoveryIsCachedBrieflyAndThenReloaded() {
        let cache = ServiceHotkeys.Cache()
        var reads = 0
        func load(_ expiry: TimeInterval) -> ServiceHotkeys.Snapshot {
            reads += 1
            return ServiceHotkeys.Snapshot(keys: [], complete: true, expires: expiry)
        }
        _ = cache.get(now: 10) { load(12) }
        _ = cache.get(now: 11) { load(13) }
        #expect(reads == 1)
        _ = cache.get(now: 12) { load(14) }
        #expect(reads == 2)
    }
}
