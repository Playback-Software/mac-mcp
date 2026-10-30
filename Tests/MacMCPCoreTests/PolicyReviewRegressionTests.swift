import AppKit
import Foundation
import Testing
@testable import MacMCPCore

@Suite struct PolicyReviewRegressionTests {
    @Test(arguments: ["true,false", "false,true"])
    func duplicateKeysNeverBecomeApproved(_ order: String) throws {
        let values = order.split(separator: ",")
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"script":{"allowed_apps":["com.apple.systemevents"],"allow_system_events":false}}"#)
        let store = box.store()
        _ = store.status()
        let original = box.keychain.record
        for json in [
            "{\"script\":{\"allowed_apps\":[\"com.apple.systemevents\"],\"allow_system_events\":\(values[0]),\"allow_system_events\":\(values[1])}}",
            #"{"clipboard_read":false,"\u0063lipboard_read":true}"#,
            #"{"unknown":[{"flag":true,"flag":false}]}"#,
            #"{"web":{},"web":{"eval_allowed":true}}"#,
        ] {
            try box.write(json)
            let status = store.status()
            #expect(throws: Policy.LoadError.self) { try status.enforced.get() }
            #expect(!status.policy.script.allowSystemEvents)
            #expect(status.problems.contains { $0.contains("duplicate JSON key") })
            #expect(box.keychain.record == original)
            #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations) }
        }
    }

    @Test func allKnownSettingsUseDecodedValuesAndRejectWrongTypes() throws {
        var candidate = Policy()
        candidate.script.allowSystemEvents = true
        #expect(PolicyDiff.loosenings(from: Policy(), to: candidate).map(\.key) == ["script.allow_system_events"])
        for json in [#"{"script":{"allow_system_events":1}}"#, #"{"web":{"enabled":"true"}}"#,
                     #"{"shortcuts":{"allowed":[1]}}"#, #"{"deny_apps":null}"#, #"{"script":null}"#,
                     #"{"script":{"allow_system_events":null}}"#, "{broken", "[]"] {
            #expect(throws: Policy.DecodeFailure.self) { try Policy.decode(Data(json.utf8)).get() }
        }
    }

    @Test func comparisonUsesTheSameKeysAsAppAndShortcutEnforcement() {
        for (old, new, equivalent) in [(" com.apple.finder ", "com.apple.finder", false),
                                       ("COM.APPLE.FINDER", "com.apple.finder", true),
                                       ("Café", "Cafe\u{301}", true), ("Finder", "Fіnder", false),
                                       ("Resize ", "Resize", false), ("Ａpp", "App", false)] {
            let oldScript = Policy(script: .init(allowedApps: [old], timeoutSeconds: 30))
            let newScript = Policy(script: .init(allowedApps: [new], timeoutSeconds: 30))
            #expect(Policy.matches([old], bundleID: new, name: nil) == equivalent)
            let guiEquivalent = Policy.appKey(old, trimmingWhitespace: true) == Policy.appKey(new, trimmingWhitespace: true)
            #expect(Policy.matches([old], AppIdentity(bundleID: new, names: [])) == guiEquivalent)
            #expect(PolicyDiff.loosenings(from: oldScript, to: newScript).isEmpty == equivalent)
            let oldShortcut = Policy(shortcuts: .init(allowed: [old]))
            let newShortcut = Policy(shortcuts: .init(allowed: [new]))
            #expect(oldShortcut.shortcuts.allows(name: new) == equivalent)
            #expect(PolicyDiff.loosenings(from: oldShortcut, to: newShortcut).isEmpty == equivalent)
            let oldDeny = Policy(denyApps: [old]), newDeny = Policy(denyApps: [new])
            #expect(PolicyDiff.loosenings(from: oldDeny, to: newDeny).isEmpty == guiEquivalent)
            let oldAllow = Policy(allowApps: [old]), newAllow = Policy(allowApps: [new])
            #expect(PolicyDiff.loosenings(from: oldAllow, to: newAllow).isEmpty == guiEquivalent)
        }
    }

    @Test func paddedGUIDenyEntriesKeepTheirExistingProtection() {
        #expect(Policy(denyApps: [" com.apple.Terminal "]).refusal(AppIdentity(bundleID: "com.apple.Terminal", names: [])) != nil)
    }

    @Test func comparisonUsesHostCoverageIncludingCaseWhitespaceAndUnicode() {
        for (old, new, equivalent) in [(" https://EXAMPLE.com/ ", "example.com", true),
                                       ("café.example", "cafe\u{301}.example", true),
                                       ("bank.example", "bаnk.example", false)] {
            let a = Policy(web: .init(allowHosts: [old])), c = Policy(web: .init(allowHosts: [new]))
            #expect(Policy.WebPolicy.covers([old], host: new) == equivalent)
            #expect(PolicyDiff.loosenings(from: a, to: c).isEmpty == equivalent)
        }
    }

    private func setACL(_ path: String, right: acl_perm_t, allow: Bool = true) throws {
        var mutable = acl_init(1)
        defer { if let acl = mutable { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        #expect(acl_create_entry(&mutable, &entry) == 0)
        let ace = try #require(entry)
        #expect(acl_set_tag_type(ace, allow ? ACL_EXTENDED_ALLOW : ACL_EXTENDED_DENY) == 0)
        var identity = UUID().uuid
        #expect(withUnsafeMutableBytes(of: &identity) { acl_set_qualifier(ace, $0.baseAddress!) } == 0)
        var permissions: acl_permset_t?
        #expect(acl_get_permset(ace, &permissions) == 0)
        let perms = try #require(permissions)
        #expect(acl_add_perm(perms, right) == 0)
        let acl = try #require(mutable)
        #expect(acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0)
    }

    @Test func managedPolicyRejectsACLWritesDeletesAndWritableAncestors() throws {
        for right in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
            for target in ["file", "folder", "ancestor"] {
                let box = try PolicySandbox()
                defer { box.cleanUp() }
                try box.write("{}", to: box.locations.managed)
                chmod(box.locations.managed, 0o644)
                #expect(PolicyStore.managedTrust(box.locations) == .trusted)
                let path = target == "file" ? box.locations.managed : target == "folder" ? box.dir + "/managed" : box.dir
                try setACL(path, right: right)
                #expect(PolicyStore.managedTrust(box.locations) != .trusted, "\(target), \(right)")
                #expect(box.store().status().problems.contains { $0.contains("ACL") })
            }
        }
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write("{}", to: box.locations.managed)
        chmod(box.locations.managed, 0o644)
        chmod(box.dir, 0o777)
        #expect(PolicyStore.managedTrust(box.locations) != .trusted)
        chmod(box.dir, 0o755)
        try setACL(box.locations.managed, right: ACL_WRITE_DATA, allow: false)
        #expect(PolicyStore.managedTrust(box.locations) == .trusted, "\(PolicyStore.managedTrust(box.locations))")
        try setACL(box.locations.managed, right: ACL_READ_DATA)
        #expect(PolicyStore.managedTrust(box.locations) == .trusted)
    }

    @Test func managedReadUsesTheCheckedDescriptorAndRejectsSymlinks() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"clipboard_read":false}"#, to: box.locations.managed)
        chmod(box.locations.managed, 0o644)
        let read = PolicyStore.readManaged(box.locations) {
            try box.write(#"{"clipboard_read":true}"#, to: box.locations.managed)
        }
        guard case let .trusted(data) = read else { Issue.record("trusted descriptor wasn't read: \(PolicyStore.managedTrust(box.locations))"); return }
        #expect(try !Policy.decode(data).get().clipboardRead)
        box.remove(box.locations.managed)
        try box.write("{}")
        try FileManager.default.createSymbolicLink(atPath: box.locations.managed, withDestinationPath: box.locations.user)
        #expect(PolicyStore.managedTrust(box.locations) != .trusted)
        box.remove(box.dir + "/managed")
        try FileManager.default.createSymbolicLink(atPath: box.dir + "/managed", withDestinationPath: box.dir)
        #expect(PolicyStore.managedTrust(box.locations) != .trusted)
    }

    @Test func aCachedManagedPolicyNoticesAncestorPermissionChanges() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write("{}", to: box.locations.managed)
        chmod(box.locations.managed, 0o644)
        let store = PolicyStore(locations: box.locations, recheck: 3600)
        #expect(store.status().source == .managed)
        chmod(box.dir, 0o777)
        #expect(store.status().source != .managed)
    }

    @Test func aCachedManagedPolicyNoticesAncestorACLChanges() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write("{}", to: box.locations.managed)
        chmod(box.locations.managed, 0o644)
        let store = PolicyStore(locations: box.locations, recheck: 3600)
        #expect(store.status().source == .managed)
        try setACL(box.dir, right: ACL_DELETE_CHILD)
        #expect(store.status().source != .managed)
    }

    @Test(arguments: ["return", "enter", "space"])
    func highlightedLocalizedServicesCommandsUseTheSharedMenuGuard(_ key: String) throws {
        struct Item {
            var role: String
            var title: String
            var children: [Int] = []
            var parent: Int?
        }
        #expect(OpenRoutes.activatesMenuItem(try KeySpec.parse(key)))
        for (title, marker) in [("Dienste", ""), ("サービス", ""), ("Schnellaktionen", ""), ("クイックアクション", ""),
                                ("Custom menu", "サービス設定…"),
                                ("Custom menu", "Ajustes de los servicios…"), ("Custom menu", "Keine Dienste verfügbar")] {
            let nodes = [Item(role: kAXMenuItemRole, title: "Run workflow", parent: 1),
                         Item(role: kAXMenuRole, title: "", children: [0, 3], parent: 2),
                         Item(role: kAXMenuItemRole, title: title), Item(role: kAXMenuItemRole, title: marker, parent: 1)]
            let refusal = OpenRoutes.menuRefusal(element: 0, role: { nodes[$0].role }, title: { nodes[$0].title },
                                                 children: { nodes[$0].children }, parent: { nodes[$0].parent })
            #expect(refusal?.contains("mac_shortcut") == true)
        }
    }
}
