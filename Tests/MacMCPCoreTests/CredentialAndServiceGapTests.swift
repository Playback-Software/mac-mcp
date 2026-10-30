import Foundation
import Testing
@testable import MacMCPCore

@Suite struct MoreProtectedPathsTests {
    private let folders = [".op", ".config/rclone", ".oci", ".config/configstore", ".gemini", ".config/github-copilot", ".config/fish",
                           ".config/zsh", ".config/doctl", ".wrangler", "Library/Application Support/doctl",
                           "Library/Preferences/.wrangler", "Library/Application Support/com.vercel.cli",
                           ".claude", ".codex", ".cursor", "Library/Application Support/Claude"]
    private let files = [".config/git/credentials", ".cargo/credentials.toml", ".cargo/credentials", ".gem/credentials", ".m2/settings.xml",
                         ".m2/settings-security.xml", ".gradle/gradle.properties", ".vault-token", ".pgpass", ".my.cnf", ".s3cfg", ".boto",
                         ".claude.json", ".gitconfig", ".config/git/config"]

    @Test func credentialStoresAndFilesThatRunCodeAreProtected() {
        for folder in folders {
            for path in ["~/" + folder, "~/" + folder + "/nested/token.json"] {
                #expect(ProtectedPaths.isProtected(path), "\(path)")
                #expect(ProtectedPaths.isProtectedFromMutation(path), "\(path)")
            }
        }
        for file in files {
            #expect(ProtectedPaths.isProtected("~/" + file), "\(file)")
            #expect(ProtectedPaths.isProtected("~/" + file.uppercased()), "\(file)")
            #expect(ProtectedPaths.isProtectedFromMutation("~/" + file), "\(file)")
            #expect(OpenRoutes.typedPathRefusal("~/" + file)?.contains("protected") == true, "\(file)")
            #expect(!ProtectedPaths.isProtectedFromMutation("~/" + file + ".bak"), "\(file)")
        }
    }

    @Test func theirAncestorsStayBrowsableButCannotBeMutated() {
        for path in ["~/.cargo", "~/.gem", "~/.m2", "~/.gradle", "~/.config/git", "~/Library/Preferences"] {
            #expect(!ProtectedPaths.isProtected(path), "\(path)")
            #expect(ProtectedPaths.isProtectedFromMutation(path), "\(path)")
        }
    }

    @Test func neighboursOfTheNewEntriesStayUsable() {
        for path in ["~/.cargo/bin/cargo", "~/.cargo/registry/index", "~/.gem/specs", "~/.m2/repository/a/b.jar", "~/.gradle/caches/x",
                     "~/.codexrc", "~/.claude-other/x", "~/.config/git/ignore", "~/.config/git/attributes", "~/.gitignore", "~/.gitconfig-work",
                     "~/.config/zsh-other/x", "~/.config/fishy", "~/.opt/x", "~/.oci-other", "~/Library/Preferences/com.apple.finder.plist",
                     "~/Library/Application Support/Code/settings.json", "~/Library/Application Support/doctl-other"] {
            #expect(!ProtectedPaths.isProtected(path), "\(path)")
            #expect(!ProtectedPaths.isProtectedFromMutation(path), "\(path)")
        }
    }

    @Test func linksAndRelativeRoutesReachTheNewEntriesToo() throws {
        let dir = NSTemporaryDirectory() + "protected-more-\(UUID().uuidString)"
        let home = dir + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.config/git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: home + "/.gitconfig", contents: Data("[alias]\n".utf8))
        FileManager.default.createFile(atPath: home + "/.config/git/credentials", contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: home + "/.gitconfig")
        try FileManager.default.linkItem(atPath: home + "/.config/git/credentials", toPath: dir + "/hard")
        #expect(ProtectedPaths.isProtected(dir + "/link", home: home))
        #expect(ProtectedPaths.isProtected(dir + "/hard", home: home))
        #expect(ProtectedPaths.isProtected("../.gitconfig", relativeTo: home + "/Documents", home: home))
        #expect(ProtectedPaths.isProtected("credentials", relativeTo: home + "/.config/git", home: home))
        #expect(!ProtectedPaths.isProtected("ignore", relativeTo: home + "/.config/git", home: home))
    }
}

@Suite struct IncompleteServiceInventoryTests {
    private func key(_ spec: String) throws -> KeySpec { try KeySpec.parse(spec) }

    /// An installed third-party Service declares ⇧⌘J as its default, with no override in pbs and no place in
    /// `knownDefaults`. If the scan ran out of time before its folder, nothing named the key and it went through.
    private let thirdParty: [[String: Any]] = [["NSMenuItem": ["default": "Do Thing"], "NSMessage": "doThing", "NSKeyEquivalent": ["default": "J"]]]

    @Test func anIncompleteScanRefusesTheChordsAnUnknownServiceCouldOwn() throws {
        let scan = (entries: [[String: Any]](), complete: false)
        let inventory = ServiceHotkeys.inventory(status: [:], scan: scan, registered: [])
        #expect(!inventory.complete)
        let snapshot = ServiceHotkeys.Snapshot(keys: inventory.keys, complete: inventory.complete, expires: .infinity)
        for text in ["shift+cmd+j", "shift+cmd+k", "shift+alt+cmd+q", "shift+ctrl+cmd+x", "shift+cmd+8", "shift+cmd+m"] {
            #expect(ServiceHotkeys.refusal(try key(text), in: snapshot) != nil, "\(text)")
        }
        // Ordinary keys and chords no Service can use stay available.
        for text in ["cmd+s", "cmd+j", "alt+cmd+j", "ctrl+cmd+f", "cmd+comma", "shift+j", "ctrl+j", "alt+j", "return", "tab", "shift+tab",
                     "cmd+shift", "f5", "shift+f5", "cmd+1", "shift+alt+j"] {
            guard let spec = try? key(text) else { continue }
            #expect(ServiceHotkeys.refusal(spec, in: snapshot) == nil, "\(text)")
        }
    }

    @Test func theFrontmostAppsOwnEnabledCommandStillTakesTheChord() throws {
        let inventory = ServiceHotkeys.inventory(status: [:], scan: ([], false), registered: [])
        let snapshot = ServiceHotkeys.Snapshot(keys: inventory.keys, complete: false, expires: .infinity)
        let redo = try key("shift+cmd+z"), unclaimed = try key("shift+cmd+j")
        func refusal(_ spec: KeySpec) -> String? {
            OpenRoutes.launcherKeyRefusal([spec], policy: Policy(denyApps: []), hotkeys: [],
                                          serviceRefusal: { ServiceHotkeys.refusal($0, in: snapshot) }, appDefines: { $0 == redo })
        }
        #expect(refusal(redo) == nil)
        #expect(refusal(unclaimed) == ServiceHotkeys.incompleteRefusal)
    }

    @Test func aCompleteInventoryRefusesOnlyWhatIsRegistered() throws {
        let inventory = ServiceHotkeys.inventory(status: [:], scan: (thirdParty, true), registered: [])
        #expect(inventory.complete)
        let snapshot = ServiceHotkeys.Snapshot(keys: inventory.keys, complete: true, expires: .infinity)
        #expect(ServiceHotkeys.refusal(try key("shift+cmd+j"), in: snapshot) == ServiceHotkeys.keyRefusal)
        #expect(ServiceHotkeys.refusal(try key("shift+cmd+k"), in: snapshot) == nil)
    }

    // MARK: pbs's cache

    private func cache(build: String = "26A434") -> [String: Any] {
        ["NSServicesBuildVersion": build,
         "ServicesCache": ["/Applications/Third Party.app": ["bundle_id": "com.example.third", "service_dicts": thirdParty],
                           "/Applications/Removed.app": ["service_dicts": [["NSMenuItem": ["default": "Gone"], "NSMessage": "gone",
                                                                            "NSKeyEquivalent": ["default": "G"]]]]]]
    }

    @Test func theRegisteredServicesAddTheirKeysToAScanThatRanOutOfTime() throws {
        let registered = ServiceHotkeys.registeredServices(cache()) { $0 != "/Applications/Removed.app" }
        let inventory = ServiceHotkeys.inventory(status: [:], scan: ([], false), registered: registered)
        #expect(!inventory.complete)
        #expect(inventory.keys.contains(try key("shift+cmd+j")))
        #expect(!inventory.keys.contains(try key("shift+cmd+g")))   // the provider that is gone adds nothing
        #expect(inventory.keys.contains(try key("shift+cmd+m")))    // the fallbacks still apply
        let snapshot = ServiceHotkeys.Snapshot(keys: inventory.keys, complete: inventory.complete, expires: .infinity)
        #expect(ServiceHotkeys.refusal(try key("shift+cmd+j"), in: snapshot) == ServiceHotkeys.keyRefusal)
        #expect(ServiceHotkeys.refusal(try key("shift+cmd+k"), in: snapshot) == ServiceHotkeys.incompleteRefusal)
    }

    /// The cache sits in the person's Caches folder. A fresh one listing no Services (written through a GUI route, or
    /// by anyone else) used to stand in for the scan and lift the refusal of chords an undiscovered Service could own.
    @Test func aCacheListingNoServicesNeverCompletesAScanCutShort() throws {
        let empty = ServiceHotkeys.registeredServices(["NSServicesBuildVersion": "26A434", "ServicesCache": [String: Any]()]) { _ in true }
        let inventory = ServiceHotkeys.inventory(status: [:], scan: ([], false), registered: empty)
        #expect(!inventory.complete)
        let snapshot = ServiceHotkeys.Snapshot(keys: inventory.keys, complete: inventory.complete, expires: .infinity)
        for text in ["shift+cmd+k", "shift+alt+cmd+q"] {
            #expect(ServiceHotkeys.refusal(try key(text), in: snapshot) == ServiceHotkeys.incompleteRefusal, "\(text)")
        }
        // Agents can't write it.
        let path = Paths.home + "/Library/Caches/com.apple.nsservicescache.plist"
        #expect(ServiceHotkeys.servicesCachePath == path)
        #expect(ProtectedPaths.isProtected(path))
        #expect(OpenRoutes.typedPathRefusal("~/Library/Caches/com.apple.nsservicescache.plist") != nil)
        #expect(!ProtectedPaths.isProtected(Paths.home + "/Library/Caches/com.apple.Safari"))
    }

    @Test func theCacheFileIsReadOnlyWhenItIsTheUsersOwnPlainFile() throws {
        let dir = NSTemporaryDirectory() + "services-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/Third Party.app", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let provider = dir + "/Third Party.app"
        let plist: [String: Any] = ["NSServicesBuildVersion": "26A434", "ServicesCache": [provider: ["service_dicts": thirdParty]]]
        let path = dir + "/cache.plist"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
        #expect(ServiceHotkeys.registeredServices(path: path).count == 1)
        // Writable by others: not trusted.
        chmod(path, 0o666)
        #expect(ServiceHotkeys.registeredServices(path: path).isEmpty)
        chmod(path, 0o600)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.plist", withDestinationPath: path)
        #expect(ServiceHotkeys.registeredServices(path: dir + "/link.plist").isEmpty)
        #expect(ServiceHotkeys.registeredServices(path: dir + "/missing.plist").isEmpty)
    }
}
