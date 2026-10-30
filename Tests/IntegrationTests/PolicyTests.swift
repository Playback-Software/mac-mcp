import AppKit
import Foundation
import Testing
import MacMCPCore

/// Where `withPolicy` keeps the person's policy.json and approved policy (the login-keychain record in force, the
/// accounts of all the records, and the readable copy) while a test replaces them. A run that crashed leaves it
/// behind, and the next run puts it back before anything else.
let policyBackupDir = Paths.supportDir + "/integration-policy-backup"

private let policyFiles = [("policy.json", Paths.policyFile), ("policy.approved.json", Paths.approvedPolicyFile)]
private let approvalKeychain = PolicyStore.Locations.standard.keychain
private let recordBackup = "approval-record"
private let accountsBackup = "approval-accounts"

/// Puts back the policy a test (or a crashed run) replaced: the files first, then the keychain. The records added
/// since the backup are deleted, so the person's record is the newest again. One this process can't delete without
/// macOS asking (the agent made it) may still come after it: then the person's record is added again, after it.
func restorePolicyBackup() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: policyBackupDir) else { return }
    for (name, path) in policyFiles {
        let saved = policyBackupDir + "/" + name
        if let data = fm.contents(atPath: saved) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if path == Paths.approvedPolicyFile { chmod(path, 0o600) }
        } else if fm.fileExists(atPath: saved + ".absent") {
            try? fm.removeItem(atPath: path)
        }
    }
    if let saved = try? String(contentsOfFile: policyBackupDir + "/" + accountsBackup, encoding: .utf8),
       case let .success(ledger) = approvalKeychain.ledger() {
        let before = Set(saved.split(separator: "\n").map(String.init))
        _ = approvalKeychain.delete(ledger.accounts.filter { !before.contains($0) }, interactive: false)
    }
    let record = policyBackupDir + "/" + recordBackup
    if let data = fm.contents(atPath: record) {
        if case let .success(ledger) = approvalKeychain.ledger(), ledger.inForce?.stored.data != data,
           case var .success(saved) = ApprovalRecord.decode(data) {
            saved.sequence = ledger.nextSequence
            _ = try? approvalKeychain.add(saved.encoded, sequence: saved.sequence, interactive: false)
        }
    } else if fm.fileExists(atPath: record + ".absent"), case let .success(ledger) = approvalKeychain.ledger(), !ledger.isEmpty {
        // Nothing was approved before, and the test's records can't all be removed: approving the restored file is
        // what the agent's first run would have done.
        _ = try? PolicyStore.approve()
    }
    try? fm.removeItem(atPath: policyBackupDir)
}

/// SecurityAgent's windows on screen: keychain prompts, which MacMCP must never cause.
func keychainPrompts() -> [String] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { $0[kCGWindowOwnerName as String] as? String }.filter { $0 == "SecurityAgent" }
}

/// Runs a body with a temporary policy.json, approved as a person would (`mac-mcp policy approve`) unless
/// `approve` is false, and restores the person's policy and approval afterwards, even after a crash.
func withPolicy(_ json: String, approve: Bool = true, _ body: () throws -> Void) throws {
    restorePolicyBackup()
    let fm = FileManager.default
    // Back up into a scratch folder and move it into place whole, so a crash never leaves half a backup.
    let staging = policyBackupDir + ".partial-\(getpid())"
    try? fm.removeItem(atPath: staging)
    try fm.createDirectory(atPath: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for (name, path) in policyFiles {
        if let data = fm.contents(atPath: path) { try data.write(to: URL(fileURLWithPath: staging + "/" + name)) }
        else { fm.createFile(atPath: staging + "/" + name + ".absent", contents: nil) }
    }
    switch approvalKeychain.ledger() {
    case let .success(ledger) where ledger.inForce != nil || ledger.isEmpty:
        if let inForce = ledger.inForce { try inForce.stored.data.write(to: URL(fileURLWithPath: staging + "/" + recordBackup)) }
        else { fm.createFile(atPath: staging + "/" + recordBackup + ".absent", contents: nil) }
        try Data(ledger.accounts.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: staging + "/" + accountsBackup))
    case let .success(ledger):
        try? fm.removeItem(atPath: staging)
        throw KeychainFailure("can't back up the approved policy from the login keychain: its newest record is damaged "
            + "(\(ledger.damagedNewest?.why ?? "?")); run `mac-mcp policy approve`")
    case let .failure(why):
        try? fm.removeItem(atPath: staging)
        throw KeychainFailure("can't back up the approved policy from the login keychain: \(why)")
    }
    try fm.moveItem(atPath: staging, toPath: policyBackupDir)
    defer { restorePolicyBackup() }
    try Data(json.utf8).write(to: URL(fileURLWithPath: Paths.policyFile), options: .atomic)
    if approve { _ = try PolicyStore.approve() }
    try body()
}

/// Rewrites policy.json without approving it, as an agent editing it in TextEdit would.
func editPolicyWithoutApproval(_ json: String) throws {
    try Data(json.utf8).write(to: URL(fileURLWithPath: Paths.policyFile), options: .atomic)
}

extension Integration {
@Suite struct PolicyTests {
    init() throws { restorePolicyBackup(); try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

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
        try withPolicy("{ this is not json", approve: false) {
            let click = try agent().call("mac_click", ["ref": submit])
            #expect(click.isError && click.text.contains("POLICY INVALID"), "\(click.text)")
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("POLICY INVALID"))
            #expect(try agent().call("mac_doctor").text.contains("!!  POLICY INVALID"))
        }
    }

    /// An edit that loosens policy.json (here, TestHost taken off deny_apps) changes nothing until a person approves
    /// it; refusals and mac_doctor say so.
    @Test func looseningWaitsForAPersonsApproval() throws {
        try withPolicy(#"{"deny_apps": ["com.playbacksoftware.macmcp.testhost"]}"#) {
            try editPolicyWithoutApproval(#"{"deny_apps": []}"#)
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("deny list") && snap.text.contains("mac-mcp policy approve"), "\(snap.text)")
            let doctor = try agent().call("mac_doctor").text
            #expect(doctor.contains("in force: the last approved policy") && doctor.contains("deny_apps: no longer lists"), "\(doctor)")
            _ = try PolicyStore.approve()
            #expect(!(try agent().call("mac_snapshot", ["app": hostApp])).isError)
        }
    }

    /// The readable copy beside the agent is an ordinary file. Rewriting it, as an agent reaching it through an
    /// unchecked route might, loosens nothing; the agent puts it back from the keychain.
    @Test func editingTheReadableCopyChangesNothing() throws {
        try withPolicy(#"{"deny_apps": ["com.playbacksoftware.macmcp.testhost"]}"#) {
            try Data(#"{"deny_apps": []}"#.utf8).write(to: URL(fileURLWithPath: Paths.approvedPolicyFile), options: .atomic)
            try editPolicyWithoutApproval(#"{"deny_apps": []}"#)
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("deny list"), "\(snap.text)")
            let copy = FileManager.default.contents(atPath: Paths.approvedPolicyFile).map { String(decoding: $0, as: UTF8.self) }
            #expect(copy?.contains("testhost") == true, "\(copy ?? "missing")")
        }
    }

    /// A record nobody can read, newer than the approved one, loosens nothing: the agent keeps enforcing the policy it
    /// read and says a person must approve it again. It changes, adds and deletes nothing in the keychain, so macOS
    /// never asks anyone anything; the calls answer at once. A person's approval then applies.
    @Test func aDamagedApprovalRecordIsReportedAndDoesntLoosen() throws {
        try withPolicy(#"{"deny_apps": ["com.playbacksoftware.macmcp.testhost"]}"#) {
            _ = try agent().call("mac_doctor")   // the agent reads the record
            guard case let .success(before) = approvalKeychain.ledger() else { Issue.record("can't read the records"); return }
            let garbage = try approvalKeychain.add(Data("garbage".utf8), sequence: before.nextSequence, interactive: false)
            try editPolicyWithoutApproval(#"{"deny_apps": []}"#)   // a file change makes the agent look again now
            let start = Date()
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("deny list"), "\(snap.text)")
            let doctor = try agent().call("mac_doctor").text
            #expect(doctor.contains("is damaged") && doctor.contains("mac-mcp policy approve"), "\(doctor)")
            #expect(Date().timeIntervalSince(start) < 5, "took \(Date().timeIntervalSince(start)) s")
            #expect(keychainPrompts().isEmpty)
            guard case let .success(after) = approvalKeychain.ledger() else { Issue.record("can't read the records"); return }
            #expect(Set(after.accounts) == Set(before.accounts + [garbage]), "the agent changed the keychain")
            // The approval comes after it, and deletes it: this process made it, so macOS lets it without asking.
            _ = try PolicyStore.approve()
            #expect(!(try agent().call("mac_snapshot", ["app": hostApp])).isError)
            #expect(!(try agent().call("mac_doctor").text.contains("damaged")))
            guard case let .success(approved) = approvalKeychain.ledger() else { Issue.record("can't read the records"); return }
            #expect(!approved.accounts.contains(garbage) && approved.inForce?.record.byPerson == true)
            #expect(keychainPrompts().isEmpty)
        }
    }

    /// Deleting policy.json (in Finder, say) keeps the approved policy, not the built-in defaults.
    @Test func aMissingPolicyKeepsTheApprovedOne() throws {
        try withPolicy(#"{"deny_apps": ["com.playbacksoftware.macmcp.testhost"]}"#) {
            try FileManager.default.removeItem(atPath: Paths.policyFile)
            let snap = try agent().call("mac_snapshot", ["app": hostApp])
            #expect(snap.isError && snap.text.contains("deny list"), "\(snap.text)")
            #expect(try agent().call("mac_doctor").text.contains("is missing"))
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
            #expect(d.contains("deny_apps: com.bank.app") && d.contains("in force: \(Paths.policyFile), as approved"))
            #expect(d.contains("webhook to ntfy.example") && !d.contains("secret-topic"))
        }
    }

    /// open= takes only web, mail and plain files: no other schemes, launchers or MacMCP's own files. Each is refused
    /// before anything launches.
    @Test func openRefusesSchemesLaunchersAndProtectedFiles() throws {
        for (target, expected) in [("x-apple.systempreferences:com.apple.preference.security", "open= takes"),
                                   ("shortcuts://run-shortcut?name=x", "open= takes"),
                                   (Paths.policyFile, "protected"), (Paths.approvedPolicyFile, "protected"),
                                   (Paths.home + "/Library/Keychains/login.keychain-db", "protected")] {
            let r = try agent().call("mac_app", ["action": "launch", "app": "TextEdit", "open": target])
            #expect(r.isError && r.text.contains(expected), "\(target): \(r.text)")
        }
        let command = NSTemporaryDirectory() + "macmcp-\(UUID().uuidString).command"
        FileManager.default.createFile(atPath: command, contents: Data("#!/bin/sh\necho hi\n".utf8), attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: command) }
        let r = try agent().call("mac_app", ["action": "launch", "app": "Finder", "open": command])
        #expect(r.isError && r.text.contains("doesn't open it"), "\(r.text)")
    }

    /// A password a password manager copied (marked concealed) can't be read, or pasted and read back. Text MacMCP put
    /// on the clipboard itself pastes as before. Needs this process to share the GUI session's pasteboard.
    @Test func copiedPasswordsAreNeitherReadNorPasted() throws {
        let pb = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pb.declareTypes([.string, concealed], owner: nil)
        pb.setString("correct horse battery staple", forType: .string)
        pb.setData(Data(), forType: concealed)
        defer { pb.clearContents() }
        let get = try agent().call("mac_clipboard", ["action": "get"])
        #expect(get.isError && get.text.contains("secret") && !get.text.contains("correct horse"), "\(get.text)")
        let key = try agent().call("mac_key", ["keys": "cmd+v", "app": hostApp])
        #expect(key.isError && key.text.contains("secret"), "\(key.text)")
        let menu = try agent().call("mac_menu", ["app": hostApp, "path": "Edit > Paste"])
        #expect(menu.isError && menu.text.contains("secret"), "\(menu.text)")
        #expect(!(try agent().call("mac_clipboard", ["action": "set", "text": "hello"])).isError)
        let own = try agent().call("mac_key", ["keys": "cmd+v", "app": hostApp])
        #expect(!own.text.contains("Refused"), "\(own.text)")
    }

    @Test func servicesAndSpotlightAreRefused() throws {
        let services = try agent().call("mac_menu", ["app": hostApp, "path": [hostApp, "Services"]])
        #expect(services.isError && services.text.contains("mac_shortcut"), "\(services.text)")
        let german = try agent().call("mac_menu", ["app": hostApp, "path": [hostApp, "Dienste"]])
        #expect(german.isError && german.text.contains("mac_shortcut"), "\(german.text)")
        // The hotkey is refused while Spotlight is denied. It is by default, but a deny_apps list the person wrote
        // replaces the defaults and may leave it out.
        try withPolicy(#"{"deny_apps": ["com.apple.Spotlight"]}"#) {
            let spotlight = try agent().call("mac_key", ["keys": "cmd+space"])
            #expect(spotlight.isError && spotlight.text.contains("Spotlight"), "\(spotlight.text)")
        }
        let switched = try agent().call("mac_key", ["keys": "cmd+tab, x", "app": hostApp])
        #expect(switched.isError && switched.text.contains("after cmd+tab"), "\(switched.text)")
    }

    /// A Dock tile launches its app: clicking System Settings' tile is refused like launching it.
    @Test func dockTilesOfDeniedAppsAreRefused() throws {
        try withPolicy(#"{"deny_apps": ["com.apple.systempreferences"]}"#) {
            let dock = try agent().call("mac_snapshot", ["app": "Dock"]).text
            guard let tile = ref(of: "\"System Settings\"", in: dock) else { return }   // not in this Dock
            let r = try agent().call("mac_click", ["ref": tile])
            #expect(r.isError && r.text.contains("deny list"), "\(r.text)")
        }
    }

    /// A file panel can't be pointed at MacMCP's own files or name a file as a launcher. Use the controlled panel
    /// fixture: a running TextEdit may have no document window, so its File > Open command cannot be assumed to run.
    @Test func filePanelsCantReachProtectedFolders() throws {
        try hostURL("save-panel")
        defer { try? hostURL("dismiss") }
        let go = try agent().call("mac_key", ["keys": "cmd+shift+g", "app": hostApp])
        try #require(!go.isError, "Could not open Go to Folder: \(go.text)")
        let path = try agent().call("mac_type", ["text": "~/.config/mac-mcp", "mode": "replace", "app": hostApp])
        #expect(path.isError && path.text.contains("protected"), "\(path.text)")
        let dismissed = try agent().call("mac_key", ["keys": "esc", "app": hostApp])
        try #require(!dismissed.isError, "Could not dismiss Go to Folder: \(dismissed.text)")
        let name = try refFor("textfield \"Save As:")
        let launcher = try agent().call("mac_type", ["text": "run.terminal", "mode": "replace", "ref": name])
        #expect(launcher.isError && launcher.text.contains("would run"), "\(launcher.text)")
    }
}
}
