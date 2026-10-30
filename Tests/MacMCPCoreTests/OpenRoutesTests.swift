import AppKit
import Foundation
import Testing
@testable import MacMCPCore

/// A scratch folder for files the checks look at; removed afterwards.
private struct Scratch {
    let dir: String
    init() throws {
        dir = NSTemporaryDirectory() + "open-routes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, mode: Int = 0o644, contents: String = "x") -> URL {
        let path = dir + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8), attributes: [.posixPermissions: mode])
        return URL(fileURLWithPath: path)
    }

    func folder(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(atPath: dir + "/" + name, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir + "/" + name)
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: dir) }
}

@Suite struct ProtectedPathTests {
    @Test func otherToolsCredentialStoresAreProtected() {
        for folder in [".config/gh", ".aws", ".kube", ".gnupg", ".config/gcloud", ".azure", ".password-store", ".config/op"] {
            for path in ["~/" + folder, "~/" + folder + "/nested/credentials"] {
                #expect(ProtectedPaths.isProtected(path), "\(path)")
                #expect(ProtectedPaths.isProtectedFromMutation(path), "\(path)")
            }
        }
        for file in [".netrc", ".git-credentials", ".docker/config.json", ".npmrc", ".pypirc", ".config/hub",
                     ".terraform.d/credentials.tfrc.json"] {
            #expect(ProtectedPaths.isProtected("~/" + file), "\(file)")
            #expect(ProtectedPaths.isProtectedFromMutation("~/" + file), "\(file)")
            #expect(!ProtectedPaths.isProtectedFromMutation("~/" + file + ".bak"), "\(file)")
        }
        #expect(ProtectedPaths.isProtected("hosts.yml", relativeTo: Paths.home + "/.config/gh"))
        #expect(ProtectedPaths.isProtected("~/.CONFIG/GH/hosts.yml"))
        #expect(ProtectedPaths.isProtected("~/Documents/../.aws/credentials"))
    }

    @Test func credentialStoreAncestorsStayBrowsableWithoutAllowingMutation() {
        for path in ["~", "~/.config", "~/.docker", "~/.terraform.d"] {
            #expect(!ProtectedPaths.isProtected(path), "\(path)")
            #expect(ProtectedPaths.isProtectedFromMutation(path), "\(path)")
        }
        for path in ["~/Documents/notes.txt", "~/.config/editor/settings.json", "~/.config/gh-other/hosts.yml",
                     "~/.aws-other/credentials", "~/.docker/contexts/meta", "~/.terraform.d/plugin-cache/plugin"] {
            #expect(!ProtectedPaths.isProtected(path), "\(path)")
            #expect(!ProtectedPaths.isProtectedFromMutation(path), "\(path)")
        }
        #expect(!ProtectedPaths.isProtectedFromMutation("editor", relativeTo: Paths.home + "/.config"))
        #expect(ProtectedPaths.isProtectedFromMutation("gh", relativeTo: Paths.home + "/.config"))
    }

    @Test func credentialStoreSymlinksProtectTheirTargetsAndAlternateRoutes() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let home = try scratch.folder("home").path
        try FileManager.default.createDirectory(atPath: home + "/.config", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.docker", withIntermediateDirectories: true)
        let credentials = try scratch.folder("credentials")
        try FileManager.default.createSymbolicLink(atPath: home + "/.config/gh", withDestinationPath: credentials.path)
        #expect(ProtectedPaths.isProtected(credentials.path + "/hosts.yml", home: home))
        let link = scratch.dir + "/innocent"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/.config/gh")
        #expect(ProtectedPaths.isProtected(link + "/hosts.yml", home: home))
        let config = scratch.file("docker.json")
        try FileManager.default.createSymbolicLink(atPath: home + "/.docker/config.json", withDestinationPath: config.path)
        #expect(ProtectedPaths.isProtected(config.path, home: home))
        #expect(!ProtectedPaths.isProtected(scratch.dir + "/ordinary.txt", home: home))
    }

    @Test func macMCPsOwnFilesAndWhatRunsAtLoginAreProtected() {
        for path in ["~/.config/mac-mcp/policy.json", "~/.config/mac-mcp", "~/.config/mac-mcp/signing-keychain.pass",
                     "~/Library/Application Support/MacMCP/policy.approved.json", "~/Library/Logs/MacMCP/audit.jsonl",
                     "~/Library/LaunchAgents/evil.plist", "~/Library/Keychains/mac-mcp-signing.keychain-db",
                     "~/Library/Keychains", "~/Library/Keychains/login.keychain-db",
                     "~/.ssh", "~/.ssh/authorized_keys", "~/.zshrc", "~/.zshenv", "~/.zprofile", "~/.zlogin",
                     "~/.bash_profile", "~/.bashrc", "~/.profile", "/Library/Application Support/MacMCP/policy.json"] {
            #expect(ProtectedPaths.isProtected(path), "\(path)")
        }
        for path in ["~", "~/Documents/notes.txt", "~/.config", "~/.config/mac-mcp-other/x", "~/Library",
                     "~/Library/Application Support/MacMCPish", "~/.zshrc.bak", "/tmp/.zshrc"] {
            #expect(!ProtectedPaths.isProtected(path), "\(path)")
        }
    }

    @Test func spellingsThatReachTheSameFileAreProtectedToo() {
        let home = Paths.home
        for path in ["~/Documents/../.zshrc", "~/./.ssh/../.ssh/id_ed25519", "~/.CONFIG/Mac-MCP/policy.json",
                     "/System/Volumes/Data" + home + "/.ssh/config", "file://" + home + "/.ssh/config",
                     home + "//Library///LaunchAgents/", "  ~/.zshrc\n"] {
            #expect(ProtectedPaths.isProtected(path), "\(path)")
        }
        #expect(ProtectedPaths.isProtected(".zshrc", relativeTo: home))
        #expect(ProtectedPaths.isProtected("../.ssh/id_rsa", relativeTo: home + "/Documents"))
        #expect(ProtectedPaths.isProtected("policy.json", relativeTo: home + "/.config/mac-mcp"))
        #expect(!ProtectedPaths.isProtected("policy.json", relativeTo: home + "/Documents"))
    }

    @Test func linksAndAliasesAreFollowed() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let home = scratch.dir + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/dotfiles", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home + "/dotfiles/zshrc", contents: Data())
        // A dotfiles manager's ~/.zshrc → ~/dotfiles/zshrc: editing the target edits the startup file.
        try FileManager.default.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: home + "/dotfiles/zshrc")
        #expect(ProtectedPaths.isProtected(home + "/dotfiles/zshrc", home: home))
        // A link elsewhere into a protected folder, and a `..` that climbs out of a link's target.
        try FileManager.default.createSymbolicLink(atPath: scratch.dir + "/keys", withDestinationPath: home + "/.ssh")
        #expect(ProtectedPaths.isProtected(scratch.dir + "/keys/id_rsa", home: home))
        try FileManager.default.createDirectory(atPath: home + "/a/b", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: scratch.dir + "/deep", withDestinationPath: home + "/a/b")
        #expect(ProtectedPaths.isProtected(scratch.dir + "/deep/../../.zshrc", home: home))
        // A Finder alias to the protected folder.
        let alias = URL(fileURLWithPath: scratch.dir + "/alias")
        let bookmark = try URL(fileURLWithPath: home + "/.ssh").bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: alias)
        #expect(ProtectedPaths.isProtected(alias.path, home: home))
        #expect(!ProtectedPaths.isProtected(home + "/a/b/notes.txt", home: home))
    }

    @Test func refusalsSayWhatIsProtectedAndWhoCanChangeIt() {
        let r = ProtectedPaths.refusal("~/.ssh/id_ed25519")
        #expect(r.map { Untrusted.strip($0) }?.contains("… is protected") == true && r?.contains("Terminal") == true)
        #expect(ProtectedPaths.refusal("~/Documents/x") == nil)
    }
}

@Suite struct OpenTargetTests {
    @Test func onlyWebMailAndFileTargetsAreAccepted() throws {
        #expect(try OpenRoutes.parse("https://example.com/a").get() == .web(URL(string: "https://example.com/a")!))
        #expect(try OpenRoutes.parse("HTTP://example.com").get().url.host == "example.com")
        #expect(try OpenRoutes.parse("mailto:ada@example.com").get() == .mail(URL(string: "mailto:ada@example.com")!))
        #expect(try OpenRoutes.parse("~").get() == .file(URL(fileURLWithPath: Paths.home)))
        #expect(try OpenRoutes.parse("file://" + Paths.home).get() == .file(URL(fileURLWithPath: Paths.home)))
        for refused in ["x-apple.systempreferences:com.apple.preference.security", "shortcuts://run-shortcut?name=X",
                        "vnc://127.0.0.1", "ssh://host", "javascript:alert(1)", "terminal://", "com.apple.TextEdit:x"] {
            guard case let .failure(r) = OpenRoutes.parse(refused) else { Issue.record("accepted \(refused)"); continue }
            #expect(r.description.hasPrefix("Refused: open= takes"), "\(refused): \(r)")
        }
        guard case let .failure(missing) = OpenRoutes.parse("~/no-such-file-\(UUID().uuidString)") else { Issue.record("missing file"); return }
        #expect(missing.description.contains("existing file path"))
        guard case .failure = OpenRoutes.parse("https:///nohost") else { Issue.record("a URL without a host"); return }
    }

    @Test func launchersAppsAndExecutablesAreNeverOpened() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let policy = Policy()
        for name in ["run.command", "Run.TERMINAL", "x.workflow", "x.scpt", "x.applescript", "x.sh", "x.tool",
                     "x.webloc", "x.inetloc", "x.fileloc", "x.pkg", "x.mobileconfig", "x.shortcut", "x.prefPane"] {
            #expect(OpenRoutes.fileRefusal(scratch.file(name), explicitApp: nil, policy: policy)?.contains("Refused") == true, "\(name)")
        }
        let script = scratch.file("deploy", mode: 0o755)
        #expect(OpenRoutes.fileRefusal(script, explicitApp: nil, policy: policy)?.contains("executable") == true)
        let pdfOnFAT = scratch.file("report.pdf", mode: 0o777)   // every file on a FAT volume has the bit
        #expect(OpenRoutes.fileRefusal(pdfOnFAT, explicitApp: nil, policy: Policy(denyApps: [])) == nil)
        // A harmless name that links to a launcher is the launcher.
        let link = scratch.dir + "/notes.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: scratch.dir + "/run.command")
        #expect(OpenRoutes.fileRefusal(URL(fileURLWithPath: link), explicitApp: nil, policy: policy) != nil)
        #expect(OpenRoutes.fileRefusal(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), explicitApp: nil, policy: policy) != nil)
        #expect(OpenRoutes.fileRefusal(URL(fileURLWithPath: Paths.policyFile), explicitApp: nil, policy: policy)?.contains("protected") == true)
    }

    @Test func theAppThatWillOpenTheFileMustBeAllowed() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let doc = scratch.file("notes.txt")
        let handler = try #require(NSWorkspace.shared.urlForApplication(toOpen: doc))
        let handlerID = try #require(Bundle(url: handler)?.bundleIdentifier)
        let denied = Policy(denyApps: [handlerID])
        #expect(OpenRoutes.fileRefusal(doc, explicitApp: nil, policy: denied)?.contains("would open in") == true)
        #expect(OpenRoutes.fileRefusal(doc, explicitApp: nil, policy: Policy(denyApps: [])) == nil)
        // Through Finder the default handler decides; any other app opens it itself.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        #expect(OpenRoutes.refusal(opening: .file(doc), with: finder, policy: denied) != nil)
        let other = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"))
        #expect(OpenRoutes.refusal(opening: .file(doc), with: other, policy: denied) == nil)
        #expect(OpenRoutes.refusal(opening: .file(doc), with: other, policy: Policy(denyApps: ["Preview"])) != nil)
    }

    @Test func webTargetsHonorDenyHosts() {
        let policy = Policy(web: Policy.WebPolicy(denyHosts: ["bank.example"]))
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        #expect(OpenRoutes.refusal(opening: .web(URL(string: "https://www.bank.example/login")!), with: safari, policy: policy)?
            .contains("web.deny_hosts") == true)
        #expect(OpenRoutes.refusal(opening: .web(URL(string: "https://example.com")!), with: safari, policy: policy) == nil)
    }
}

@Suite struct OpenElementTests {
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    @Test func dockTilesAndAppIconsOpenTheAppTheyStandFor() throws {
        let policy = Policy()
        #expect(OpenRoutes.elementRefusal(url: terminal, owner: OpenRoutes.dock, policy: policy)?.contains("deny list") == true)
        #expect(OpenRoutes.elementRefusal(url: textEdit, owner: OpenRoutes.dock, policy: policy) == nil)
        #expect(OpenRoutes.elementRefusal(url: terminal, owner: OpenRoutes.finder, policy: policy) != nil)   // a drop on it
        #expect(OpenRoutes.elementRefusal(url: URL(fileURLWithPath: Paths.home), owner: OpenRoutes.dock, policy: policy) == nil)
        #expect(OpenRoutes.elementRefusal(url: URL(string: "shortcuts://run-shortcut?name=x")!, owner: OpenRoutes.dock, policy: policy) != nil)
        let web = Policy(web: Policy.WebPolicy(denyHosts: ["bank.example"]))
        #expect(OpenRoutes.elementRefusal(url: URL(string: "https://bank.example/")!, owner: OpenRoutes.dock, policy: web) != nil)
        // A link with an app's scheme opens that app (Shortcuts and System Settings are denied by default).
        #expect(OpenRoutes.elementRefusal(url: URL(string: "x-apple.systempreferences:com.apple.preference.security")!, owner: "com.apple.Safari", policy: policy) != nil)
        #expect(OpenRoutes.elementRefusal(url: URL(string: "https://example.com/a")!, owner: "com.apple.Safari", policy: policy) == nil)
        #expect(OpenRoutes.elementRefusal(url: URL(string: "javascript:void(0)")!, owner: "com.apple.Safari", policy: policy) == nil)
        // Protected files are off limits in any app (a panel's file list, Finder, a link in a page).
        let approved = URL(fileURLWithPath: Paths.approvedPolicyFile)
        #expect(OpenRoutes.elementRefusal(url: approved, owner: "com.apple.TextEdit", policy: policy)?.contains("protected") == true)
    }

    @Test func doubleClickingAFinderItemOpensIt() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let policy = Policy()
        #expect(OpenRoutes.openingRefusal(url: terminal, policy: policy) != nil)
        #expect(OpenRoutes.openingRefusal(url: textEdit, policy: policy) == nil)
        #expect(OpenRoutes.openingRefusal(url: scratch.file("go.command"), policy: policy) != nil)
        #expect(OpenRoutes.openingRefusal(url: try scratch.folder("Projects"), policy: policy) == nil)
        #expect(OpenRoutes.openingRefusal(url: URL(fileURLWithPath: Paths.supportDir), policy: policy)?.contains("protected") == true)
    }

    @Test func finderMayNotMoveCopyRenameOrDeleteProtectedItems() throws {
        for spec in ["cmd+delete", "cmd+c", "cmd+d", "cmd+i", "return", "space", "alt+cmd+v"] {
            #expect(OpenRoutes.actsOnSelection(try KeySpec.parse(spec)), "\(spec)")
        }
        for spec in ["down", "up", "tab", "a"] { #expect(!OpenRoutes.actsOnSelection(try KeySpec.parse(spec)), "\(spec)") }
        #expect(!OpenRoutes.leavesSelectionAlone(menuPath: ["View", "as Columns"]))
        #expect(OpenRoutes.leavesSelectionAlone(menuPath: ["Go", "Home"]))
        #expect(!OpenRoutes.leavesSelectionAlone(menuPath: ["File", "Move to Trash"]))
        #expect(!OpenRoutes.leavesSelectionAlone(menuPath: ["Move to Trash"]))   // the context menu
        let approved = URL(fileURLWithPath: Paths.approvedPolicyFile)
        #expect(OpenRoutes.protectedSelectionRefusal([URL(fileURLWithPath: Paths.home + "/Documents"), approved]) != nil)
        #expect(OpenRoutes.protectedSelectionRefusal([URL(fileURLWithPath: Paths.home + "/Documents")]) == nil)
        #expect(OpenRoutes.protectedSelectionRefusal(nil) == nil)
    }

    @Test func openingFindersSelectionIsCheckedLikeADoubleClick() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        for spec in ["cmd+o", "cmd+down", "alt+cmd+down"] { #expect(OpenRoutes.opensSelection(try KeySpec.parse(spec)), "\(spec)") }
        for spec in ["o", "down", "cmd+shift+o", "cmd+up"] { #expect(!OpenRoutes.opensSelection(try KeySpec.parse(spec)), "\(spec)") }
        #expect(OpenRoutes.opensSelection(menuPath: ["File", "Open"]) == (true, nil))
        #expect(OpenRoutes.opensSelection(menuPath: ["File", "Open With", "TextEdit"]) == (true, "TextEdit"))
        #expect(OpenRoutes.opensSelection(menuPath: ["File", "New Folder"]).opens == false)
        let policy = Policy()
        #expect(OpenRoutes.selectionRefusal([scratch.file("notes.md")], explicitApp: nil, policy: Policy(denyApps: [])) == nil)
        #expect(OpenRoutes.selectionRefusal([scratch.file("notes.md"), scratch.file("go.terminal")], explicitApp: nil, policy: policy) != nil)
        #expect(OpenRoutes.selectionRefusal([URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")], explicitApp: nil, policy: policy) != nil)
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        #expect(OpenRoutes.selectionRefusal([scratch.file("go.command")], explicitApp: textEdit, policy: policy) != nil)
        #expect(OpenRoutes.selectionRefusal([scratch.file("a.txt")], explicitApp: textEdit, policy: Policy(denyApps: ["TextEdit"])) != nil)
        #expect(OpenRoutes.selectionRefusal(nil, explicitApp: nil, policy: policy)?.contains("can't read what's selected") == true)
    }

    @Test func servicesAndQuickActionsRunOnlyThroughMacShortcut() {
        #expect(OpenRoutes.menuRefusal(path: ["TextEdit", "Services", "New Terminal at Folder"])?.contains("mac_shortcut") == true)
        #expect(OpenRoutes.menuRefusal(path: ["File", "Quick Actions", "Rotate Left"]) != nil)
        #expect(OpenRoutes.menuRefusal(path: ["File", "quick actions…", "x"]) != nil)
        #expect(OpenRoutes.menuRefusal(path: ["File", "Save As…"]) == nil)
    }

    /// The titles come from AppKit's and Finder's own localizations, so a Mac set to another language is covered.
    @Test func servicesAndQuickActionsAreKnownInEveryLanguage() {
        let started = ContinuousClock.now
        _ = OpenRoutes.shortcutMenus.count + OpenRoutes.servicesMenuItems.count
        #expect(started.duration(to: .now) < .seconds(30), "loading the localizations took \(started.duration(to: .now))")
        #expect(OpenRoutes.shortcutMenus.count > 30 && OpenRoutes.servicesMenuItems.count > 60)
        for path in [["TextEdit", "Dienste"], ["TextEdit", "サービス", "x"], ["Archivo", "Servicios"], ["Fichier", "Services"],
                     ["Файл", "Службы"], ["Ablage", "Schnellaktionen", "Nach links drehen"], ["ファイル", "クイックアクション"],
                     ["Archivo", "Acciones rápidas"], ["文件", "快速操作"]] {
            #expect(OpenRoutes.menuRefusal(path: path) != nil, "\(path)")
        }
        for path in [["Ablage", "Sichern unter …"], ["Format", "Schrift"], ["Edit", "Service Status"]] {
            #expect(OpenRoutes.menuRefusal(path: path) == nil, "\(path)")
        }
    }

    /// A menu that ends with AppKit's "Services Settings…" is a Services menu, whatever its own title says.
    @Test func aServicesMenuIsKnownByItsLastItems() {
        #expect(OpenRoutes.isServicesMenu(["Neues Terminal beim Ordner", "", "Dienste-Einstellungen\u{00A0}…"]))
        #expect(OpenRoutes.isServicesMenu(["Keine Dienste verfügbar", "", "サービス設定…"]))
        #expect(OpenRoutes.isServicesMenu(["", "Services Settings…"]) && OpenRoutes.isServicesMenu(["Ajustes de los servicios…"]))
        #expect(!OpenRoutes.isServicesMenu(["Copy", "Paste", "Settings…"]))
        #expect(!OpenRoutes.isServicesMenu([]))
    }
}

@Suite struct LauncherKeyTests {
    @Test func pasteKeysAndItems() throws {
        for spec in ["cmd+v", "alt+shift+cmd+v", "shift+cmd+v"] { #expect(OpenRoutes.isPaste(try KeySpec.parse(spec)), "\(spec)") }
        for spec in ["v", "ctrl+v", "cmd+c"] { #expect(!OpenRoutes.isPaste(try KeySpec.parse(spec)), "\(spec)") }
        for title in ["Paste", "Paste and Match Style", "Paste Style", "paste…"] { #expect(OpenRoutes.isPasteTitle(title)) }
        #expect(!OpenRoutes.isPasteTitle("Copy"))
    }

    @Test func keysAfterAnAppSwitchAreRefused() throws {
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("cmd+tab, e, c, h, o"), repeat: 1)?.contains("after cmd+tab") == true)
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("cmd+q, return"), repeat: 1) != nil)
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("ctrl+right, x"), repeat: 1) != nil)
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("x, cmd+tab"), repeat: 2) != nil)
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("cmd+tab"), repeat: 3) == nil)   // switching alone
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("x, y, cmd+tab"), repeat: 1) == nil)
        #expect(OpenRoutes.appSwitchRefusal(try KeySpec.parseSequence("cmd+a, cmd+c, right, cmd+s"), repeat: 1) == nil)
    }

    @Test func spotlightHotkeysComeFromThePersonsSettings() throws {
        #expect(OpenRoutes.spotlightHotkeys(nil) == [KeySpec(key: 49, flags: .maskCommand), KeySpec(key: 49, flags: [.maskCommand, .maskAlternate])])
        let custom: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": [32, 49, 262_144], "type": "standard"]],   // ctrl+space
            "65": ["enabled": false],
        ]
        #expect(OpenRoutes.spotlightHotkeys(custom) == [KeySpec(key: 49, flags: .maskControl)])
    }

    @Test func spotlightKeysAreRefusedWhileSpotlightIsDenied() throws {
        let hotkeys = OpenRoutes.spotlightHotkeys(nil)
        #expect(OpenRoutes.launcherKeyRefusal([try KeySpec.parse("cmd+space")], policy: Policy(), hotkeys: hotkeys, serviceKeys: [])?.contains("Spotlight") == true)
        #expect(OpenRoutes.launcherKeyRefusal(try KeySpec.parseSequence("esc, alt+cmd+space"), policy: Policy(), hotkeys: hotkeys, serviceKeys: []) != nil)
        #expect(OpenRoutes.launcherKeyRefusal([try KeySpec.parse("shift+cmd+space")], policy: Policy(), hotkeys: hotkeys, serviceKeys: []) == nil)
        #expect(OpenRoutes.launcherKeyRefusal([try KeySpec.parse("cmd+space")], policy: Policy(denyApps: []), hotkeys: hotkeys, serviceKeys: []) == nil)
    }
}

@Suite struct PanelTypingTests {
    let home = Paths.home

    @Test func pathsAndNamesThatReachProtectedFilesAreRefused() {
        func refused(_ text: String, bases: [String] = []) -> Bool { OpenRoutes.typingRefusal(text, bases: bases, scan: { [] }) != nil }
        #expect(refused("~/.ssh"))
        #expect(refused("~/Library/LaunchAgents\n"))
        #expect(refused("/Users/Shared/../" + (home as NSString).lastPathComponent + "/.config/mac-mcp"))
        #expect(refused(".zshrc"))
        #expect(refused("policy.approved.json"))
        #expect(refused("login.keychain-db"))
        #expect(refused("Keychains/login.keychain-db", bases: [home + "/Library"]))
        #expect(refused("policy.json", bases: [home + "/.config/mac-mcp"]))
        #expect(refused("../.ssh/config", bases: [home + "/Documents"]))
        #expect(!refused("policy.json", bases: [home + "/Documents"]))
        #expect(!refused("~/Documents"))
        #expect(!refused("Quarterly report.txt", bases: [home + "/Documents"]))
    }

    @Test func outsidePanelsOnlyPathsToProtectedFilesCount() {
        func refused(_ text: String) -> Bool { OpenRoutes.typingRefusal(text, bases: [], names: false, scan: { [] }) != nil }
        #expect(refused("~/.ssh/id_ed25519") && refused("file://" + Paths.home + "/.config/mac-mcp/policy.json"))
        #expect(!refused(".zshrc") && !refused("run.command") && !refused("Edit ~/.zshrc to add it to your PATH."))
    }

    @Test func launcherNamesAreRefused() {
        for name in ["run.command", "x.TERMINAL", "~/Desktop/a.webloc", "Start.app", "server.vncloc"] {
            #expect(OpenRoutes.typingRefusal(name, bases: [], scan: { [] })?.contains("would run or install") == true, "\(name)")
        }
        // Editors save scripts and source all the time; opening them is what's refused.
        for name in ["main.py", "build.sh", "Notes.scpt"] { #expect(OpenRoutes.typingRefusal(name, bases: [], scan: { [] }) == nil, "\(name)") }
    }

    @Test func thePanelIsOnlyScannedForBareNames() {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let scan: () -> [String] = { count.n += 1; return [Paths.home + "/.config/mac-mcp"] }
        #expect(OpenRoutes.typingRefusal("~/Documents", bases: [], scan: scan) == nil && count.n == 0)
        #expect(OpenRoutes.typingRefusal("policy.json", bases: [], scan: scan) != nil && count.n == 1)
    }
}

@Suite struct ClipboardSafetyTests {
    @Test func passwordManagerSecretsAreNeverReadOrPasted() {
        let policy = Policy()
        for marker in [ClipboardSafety.concealedType, ClipboardSafety.transientType] {
            let info = ClipboardInfo(types: ["public.utf8-plain-text", marker], changeCount: 4)
            #expect(ClipboardSafety.secretRefusal(info, policy: policy)?.contains("secret") == true)
            #expect(ClipboardSafety.pasteRefusal(info, policy: policy, ownChangeCount: 4) != nil)   // even if it was ours
        }
        let fromPasswords = ClipboardInfo(types: ["public.utf8-plain-text", ClipboardSafety.sourceType], source: "com.apple.Passwords")
        #expect(ClipboardSafety.secretRefusal(fromPasswords, policy: policy)?.contains("which the policy denies") == true)
        let unreadable = ClipboardInfo(types: [ClipboardSafety.sourceType], sourceUnread: true)
        #expect(ClipboardSafety.secretRefusal(unreadable, policy: policy) != nil)
        let fromTextEdit = ClipboardInfo(types: ["public.utf8-plain-text"], source: "com.apple.TextEdit")
        #expect(ClipboardSafety.secretRefusal(fromTextEdit, policy: policy) == nil)
    }

    @Test func withReadingOffOnlyMacMCPsOwnTextMayBePasted() {
        let off = Policy(clipboardRead: false)
        let copied = ClipboardInfo(types: ["public.utf8-plain-text"], changeCount: 9)
        #expect(ClipboardSafety.pasteRefusal(copied, policy: off, ownChangeCount: 8)?.contains("clipboard_read") == true)
        #expect(ClipboardSafety.pasteRefusal(copied, policy: off, ownChangeCount: 9) == nil)
        #expect(ClipboardSafety.pasteRefusal(copied, policy: Policy(), ownChangeCount: nil) == nil)
        #expect(ClipboardSafety.pasteRefusal(ClipboardInfo(types: []), policy: off, ownChangeCount: nil) == nil)
    }

    /// Finder's copy bumps the change count once: while it reads one more than when MacMCP sent ⌘C, the clipboard
    /// holds the files Finder had selected, so a paste is checked against them without reading the clipboard.
    @Test func aFinderCopyIsKnownUntilAnythingElseIsCopied() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("finder-copy-" + UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        ClipboardSafety.noteFinderCopy([file], changeCount: 40)
        let copied = ClipboardInfo(types: ["public.file-url", "NSFilenamesPboardType", "public.utf8-plain-text"], changeCount: 41)
        #expect(ClipboardSafety.pastedFiles(copied)?.contains(file) == true)
        #expect(ClipboardSafety.holdsFinderCopy(copied))
        #expect(ClipboardSafety.holdsFiles(copied))
        #expect(ClipboardSafety.pastedFiles(ClipboardInfo(types: copied.types, changeCount: 42)) == nil)
        #expect(ClipboardSafety.pastedFiles(ClipboardInfo(types: copied.types, changeCount: 40)) == nil)
        #expect(ClipboardSafety.pastedFiles(ClipboardInfo(types: ["public.utf8-plain-text"], changeCount: 41)) == nil)
        #expect(!ClipboardSafety.holdsFiles(ClipboardInfo(types: ["public.utf8-plain-text"])))
        // Files the clipboard can be read for without asking are taken as they are.
        let read = ClipboardInfo(types: copied.types, changeCount: 99, fileURLs: [URL(fileURLWithPath: "/tmp/two.txt")])
        #expect(ClipboardSafety.pastedFiles(read) == [URL(fileURLWithPath: "/tmp/two.txt")])
        // The agent's own Finder copy pastes with clipboard reading off: it shows nothing new.
        #expect(ClipboardSafety.pasteRefusal(copied, policy: Policy(clipboardRead: false), ownChangeCount: nil) == nil)
        ClipboardSafety.noteFinderCopy([], changeCount: -10)
    }

    /// With silent clipboard reads unavailable, a file copied as /tmp/…/payload.txt and renamed config.json before the
    /// paste is pasted by Finder under its new name: into ~/.docker it would replace the protected config.json.
    @Test func aCopiedFileRenamedBeforeThePasteIsCheckedUnderItsNewName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("finder-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = dir.appendingPathComponent("payload.txt"), renamed = dir.appendingPathComponent("config.json")
        try Data("x".utf8).write(to: payload)
        let reference = try #require(OpenRoutes.fileReference(payload))
        #expect(reference.absoluteString?.hasPrefix("file:///.file/") == true)
        let copied = [ClipboardSafety.CopiedFile(url: payload, reference: reference)]
        let docker = URL(fileURLWithPath: Paths.home + "/.docker")
        #expect(OpenRoutes.transferRefusal(try #require(ClipboardSafety.currentFiles(copied)), into: [docker]) == nil)
        try FileManager.default.moveItem(at: payload, to: renamed)
        let now = try #require(ClipboardSafety.currentFiles(copied))
        #expect(now.map(\.lastPathComponent).contains("config.json"))
        #expect(OpenRoutes.transferRefusal(now, into: [docker])?.contains("protected") == true)
        // Deleted since, or copied without an identity: the files can't be known.
        try FileManager.default.removeItem(at: renamed)
        #expect(ClipboardSafety.currentFiles(copied) == nil)
        #expect(ClipboardSafety.currentFiles([.init(url: payload, reference: nil)]) == nil)
    }
}

@Suite struct AppMatchingTests {
    @Test func entriesMatchByBundleIDOrAnyName() throws {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        #expect(Policy(denyApps: ["Terminal"]).refusal(bundleID: "com.apple.Terminal", name: nil) != nil)
        #expect(Policy(denyApps: ["terminal"]).refusal(appAt: terminal) != nil)
        #expect(Policy(denyApps: ["com.apple.terminal"]).refusal(appAt: terminal) != nil)
        #expect(Policy(denyApps: [], allowApps: ["Terminal"]).refusal(appAt: terminal) == nil)
        #expect(Policy().refusal(bundleID: Paths.bundleID, name: "MacMCP")?.contains("MacMCP itself") == true)
        let identity = AppIdentity(bundleURL: terminal)
        #expect(identity.bundleID == "com.apple.Terminal" && identity.identifiers.contains("terminal"))
    }

    @Test func launchersAndOtherTerminalsAreDeniedByDefault() {
        let p = Policy()
        for id in ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.mitchellh.ghostty",
                   "dev.warp.Warp-Stable", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
                   "com.stairways.keyboardmaestro.editor", "com.stairways.keyboardmaestro.engine",
                   "org.hammerspoon.Hammerspoon", "com.latenightsw.ScriptDebugger8"] {
            #expect(p.refusal(bundleID: id, name: nil)?.contains("deny list") == true, "\(id)")
        }
        #expect(p.refusal(bundleID: "com.example.unknown", name: "Script Debugger") != nil)
        for id in ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.TextEdit"] {
            #expect(p.permits(bundleID: id, name: nil), "\(id)")
        }
    }

    /// Password managers show stored secrets, and the Script menu runs whatever is in ~/Library/Scripts.
    @Test func passwordManagersAndTheScriptMenuAreDeniedByDefault() {
        let p = Policy()
        for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.dashlane.Dashlane",
                   "org.keepassxc.keepassxc", "com.lastpass.lastpassmacdesktop", "me.proton.pass.electron",
                   "in.sinew.Enpass-Desktop.App", "in.sinew.Enpass-Desktop", "com.apple.ScriptMenuApp",
                   // Versions and older IDs of apps already on the list.
                   "com.latenightsw.ScriptDebugger", "com.latenightsw.ScriptDebugger5", "com.latenightsw.ScriptDebugger6",
                   "io.alacritty", "com.runningwithcrayons.Alfred-3", "org.keepassx.keepassxc"] {
            #expect(p.refusal(bundleID: id, name: nil)?.contains("deny list") == true, "\(id)")
        }
    }

    @Test func theDefaultDenyListHasNoDuplicatesOrStrayEntries() {
        let lowered = Policy.defaultDenyApps.map { $0.lowercased() }
        #expect(Set(lowered).count == lowered.count)
        for entry in Policy.defaultDenyApps where entry != "Script Debugger" {
            #expect(entry.contains(".") && !entry.contains(" ") && entry == entry.trimmingCharacters(in: .whitespaces), "\(entry)")
        }
    }
}

@Suite struct PromptDetectionTests {
    @Test func promptProcessesAreKnownByBundleIDOrSystemExecutable() {
        for id in ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                   "com.apple.tcc.AuthorizationPromptService", "com.apple.LocalAuthentication.UIAgent",
                   "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent", "com.apple.BluetoothUIServer",
                   "com.apple.sharingd", "com.apple.Sharing.AirDropUI", "com.apple.screensharing.agent",
                   "com.apple.accessibility.universalAccessAuthWarn", "com.apple.SSMenuAgent", "com.apple.AppleVNCServer"] {
            #expect(WindowServer.isPromptProcess(bundleID: id, executablePath: nil, name: nil), "\(id)")
        }
        #expect(WindowServer.isPromptProcess(bundleID: nil, executablePath: "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd", name: nil))
        #expect(WindowServer.isPromptProcess(bundleID: nil, executablePath: "/usr/libexec/sharingd", name: "renamed"))
        // The same executable name outside the system volume is just an app.
        #expect(!WindowServer.isPromptProcess(bundleID: "com.example.fake", executablePath: "/Users/x/Applications/SecurityAgent.app/Contents/MacOS/SecurityAgent", name: nil))
        #expect(WindowServer.isPromptProcess(bundleID: nil, executablePath: nil, name: "coreautha"))   // the old fallback
        #expect(!WindowServer.isPromptProcess(bundleID: "com.apple.TextEdit", executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", name: "TextEdit"))
    }

    @Test func sliversAndMenuBarItemsArentPrompts() {
        let me = getpid()
        func window(_ w: CGFloat, _ h: CGFloat) -> WindowInfo {
            WindowInfo(id: 1, pid: me, owner: "SecurityAgent", title: "", layer: 0, bounds: CGRect(x: 0, y: 0, width: w, height: h), alpha: 1)
        }
        #expect(WindowServer.systemPrompts(in: [window(420, 240)]).count == 1)
        #expect(WindowServer.systemPrompts(in: [window(28, 22)]).isEmpty)   // a menu-bar item, not a prompt
    }

    /// Identifiers checked on macOS 26: the app bundles' Info.plist, and codesign for the daemons (sharingd in
    /// /usr/libexec, AuthenticationServicesAgent in the App cryptex).
    @Test func processesThatAlsoOwnOrdinaryWindowsCountOnlyForTheirDialogs() {
        for id in ["com.apple.sharingd", "com.apple.Sharing.AirDropUI", "com.apple.screensharing.agent", "com.apple.SSMenuAgent",
                   "com.apple.AppleVNCServer", "com.apple.loginwindow", "com.apple.SoftwareUpdate"] {
            #expect(WindowServer.promptKind(bundleID: id, executablePath: nil, name: nil) == .dialogs, "\(id)")
        }
        for id in ["com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine", "com.apple.BluetoothUIService"] {
            #expect(WindowServer.promptKind(bundleID: id, executablePath: nil, name: nil) == .all, "\(id)")
        }
        #expect(WindowServer.promptKind(bundleID: nil, executablePath: "/usr/libexec/sharingd", name: nil) == .dialogs)
        #expect(WindowServer.promptKind(bundleID: nil, executablePath: "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent", name: nil) == .dialogs)
        #expect(WindowServer.promptKind(bundleID: nil, executablePath: "/System/Cryptexes/App/usr/libexec/AuthenticationServicesAgent", name: nil) == .all)
        // The Screen Sharing viewer and the Finder's AirDrop window are ordinary apps.
        #expect(WindowServer.promptKind(bundleID: "com.apple.ScreenSharing", executablePath: "/System/Applications/Utilities/Screen Sharing.app/Contents/MacOS/Screen Sharing", name: "Screen Sharing") == .none)
        #expect(WindowServer.promptKind(bundleID: "com.apple.finder.Open-AirDrop", executablePath: nil, name: "AirDrop") == .none)

        let me = getpid()
        func window(_ owner: String, _ w: CGFloat, _ h: CGFloat, layer: Int = 0) -> WindowInfo {
            WindowInfo(id: 1, pid: me, owner: owner, title: "", layer: layer, bounds: CGRect(x: 0, y: 0, width: w, height: h), alpha: 1)
        }
        let display = [CGRect(x: 0, y: 0, width: 3024, height: 1964)]
        let ordinary = WindowServer.WindowTraits(role: "AXWindow", subrole: "AXStandardWindow", hasCloseButton: true)
        // A screen-sharing session's full-screen overlay doesn't block agents; its request dialog does.
        #expect(!WindowServer.isPrompt(window("ScreensharingAgent", 3024, 1964, layer: 1000), kind: .dialogs, displays: display) { nil })
        #expect(WindowServer.systemPrompts(in: [window("ScreensharingAgent", 420, 180, layer: 8)]).count == 1)
        #expect(WindowServer.systemPrompts(in: [window("AirDropUI", 360, 90)]).count == 1)   // nothing says it's ordinary
        #expect(!WindowServer.isPrompt(window("AirDropUI", 1280, 800), kind: .dialogs, displays: display) { ordinary })
        // The lock screen: the session check's job.
        #expect(!WindowServer.isPrompt(window("loginwindow", 3024, 1964, layer: 2_147_483_628), kind: .dialogs, displays: display) { nil })
        #expect(WindowServer.isSystemPrompt(window: window("ScreenSaverEngine", 3024, 1964)))
    }
}
