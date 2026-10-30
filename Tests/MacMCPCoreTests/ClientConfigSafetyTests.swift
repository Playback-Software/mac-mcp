import Foundation
import Testing
@testable import MacMCPCore

/// How `ClientConfig.apply` treats a config that other programs may be saving at the same time, and where it keeps its
/// backups. Everything runs in temporary folders standing in for the home folder.
@Suite struct ClientConfigSafetyTests {
    typealias Home = ClientInstallerTests.Home
    let local = ServerEntry(command: "/opt/mac/bin/mac-mcp")
    let original = "{\n  \"mcpServers\": {\n    \"other\": { \"command\": \"x\", \"env\": { \"TOKEN\": \"secret\" } }\n  }\n}\n"
    let theirs = "{\"mcpServers\": {\"theirs\": {}}}\n"

    func plan(_ home: Home, _ client: McpClient = .cursor, entry: ServerEntry? = ServerEntry(command: "/opt/mac/bin/mac-mcp")) throws -> ClientPlan {
        try ClientConfig.plan(client, name: "mac", entry: entry, environment: home.environment, createFolder: true)
    }

    func message(_ body: () throws -> Void) -> String {
        do { try body(); return "" } catch { return "\(error)" }
    }

    // MARK: where backups go

    @Test func backupsGoToTheProtectedSupportFolderNotBesideTheConfig() throws {
        let home = try Home()
        try home.write(".claude.json", original, permissions: 0o600)
        let path = try #require(try ClientConfig.apply(try plan(home, .claudeCode)))
        let folder = home.path(Home.backupFolder)
        #expect(path.hasPrefix(folder + "/claude-code-") && path.hasSuffix("-claude.json"))
        #expect(FileManager.default.contents(atPath: path) == Data(original.utf8))
        #expect(ProtectedPaths.isProtected(path, home: home.root))
        #expect(ProtectedPaths.isProtectedFromMutation(path, home: home.root))
        #expect(ProtectedPaths.isProtected(folder, home: home.root))
        #expect(home.files(in: "") .filter { $0.contains("backup") }.isEmpty)
        let mode = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue }
        #expect(mode(folder) == 0o700 && mode(path) == 0o600)
    }

    @Test func aLooseBackupFolderIsTightenedAndALinkedOneRefused() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        try FileManager.default.createDirectory(atPath: home.path(Home.backupFolder), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        _ = try ClientConfig.apply(try plan(home))
        let attributes = try FileManager.default.attributesOfItem(atPath: home.path(Home.backupFolder))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let linked = try Home()
        try linked.write(".cursor/mcp.json", original)
        try FileManager.default.createDirectory(atPath: linked.path("Library/Application Support/MacMCP"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: linked.path("elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.path(Home.backupFolder), withDestinationPath: linked.path("elsewhere"))
        #expect(message { _ = try ClientConfig.apply(try plan(linked)) }.contains("isn't a plain folder"))
        #expect(linked.read(".cursor/mcp.json") == original && linked.files(in: "elsewhere").isEmpty)
    }

    @Test func theReportNamesTheBackup() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        let r = try ClientInstaller.run(.init(client: .cursor, entry: local, environment: home.environment), runCommand: { _, _ in (1, "") })
        let line = try #require(r.lines.first { $0.hasPrefix("Backup of the original") })
        #expect(line.contains("~/Library/Application Support/MacMCP/client-backups/cursor-"))
    }

    // MARK: files are created exclusively and without following links

    @Test func aPlantedBackupNameIsSkippedNotFollowed() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        try home.write("victim", "precious")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try ClientBackups.open(home: home.root)
        let first = folder.path + "/" + ClientBackups.fileName(client: .cursor, label: "mcp.json", now: now, attempt: 0)
        try FileManager.default.createSymbolicLink(atPath: first, withDestinationPath: home.path("victim"))
        let made = try #require(try ClientConfig.apply(try plan(home), now: now))
        #expect(made == folder.path + "/" + ClientBackups.fileName(client: .cursor, label: "mcp.json", now: now, attempt: 1))
        #expect(made.contains("-2-mcp.json") && home.read("victim") == "precious")
        // And a dangling link is no better a place to write.
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/" + ClientBackups.fileName(client: .cursor, label: "mcp.json", now: now, attempt: 2),
                                                   withDestinationPath: home.path("not-there"))
        _ = try ClientConfig.apply(try plan(home, entry: ServerEntry(command: "/other")), now: now)
        #expect(!FileManager.default.fileExists(atPath: home.path("not-there")))
    }

    @Test func aPlantedTemporaryNameIsSkippedNotFollowed() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        try home.write("victim", "precious")
        try FileManager.default.createSymbolicLink(atPath: home.path(".cursor/.planted.tmp"), withDestinationPath: home.path("victim"))
        var hooks = ApplyHooks.none
        hooks.temporaryName = { $0 == 0 ? ".planted.tmp" : nil }
        _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks)
        #expect(home.read("victim") == "precious")
        #expect(home.read(".cursor/mcp.json")?.contains("\"mac\"") == true)
        #expect(home.files(in: ".cursor") == [".planted.tmp", "mcp.json"])   // the planted link is still there, untouched
    }

    // MARK: a client saving while mac-mcp works

    @Test func aSaveBeforeTheRenameIsNotOverwritten() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        let path = home.path(".cursor/mcp.json"), theirs = theirs
        var hooks = ApplyHooks.none
        hooks.beforeRename = { try? Data(theirs.utf8).write(to: URL(fileURLWithPath: path)) }
        let text = message { _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks) }
        #expect(text.contains("changed while mac-mcp was working") && text.contains("Quit Cursor"))
        #expect(home.read(".cursor/mcp.json") == theirs)
        #expect(home.files(in: ".cursor") == ["mcp.json"] && home.backups.isEmpty)
    }

    @Test func aFileThatAppearsBeforeTheRenameIsNotReplacedEither() throws {
        let home = try Home()
        try FileManager.default.createDirectory(atPath: home.path(".cursor"), withIntermediateDirectories: true)
        let path = home.path(".cursor/mcp.json"), theirs = theirs
        var hooks = ApplyHooks.none
        hooks.beforeRename = { try? Data(theirs.utf8).write(to: URL(fileURLWithPath: path)) }
        #expect(message { _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks) }.contains("changed while"))
        #expect(home.read(".cursor/mcp.json") == theirs && home.files(in: ".cursor") == ["mcp.json"])
        // Even if it shows up in the instant after the check, the rename for a new file never overwrites.
        let folder = try PinnedDirectory(path: home.path(".cursor"))
        try home.write(".cursor/new.tmp", "x")
        #expect(folder.rename("new.tmp", to: "mcp.json", replacing: false) == EEXIST)
        #expect(home.read(".cursor/mcp.json") == theirs)
    }

    @Test func aSaveAfterTheRenameIsKeptNotRolledBack() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        let path = home.path(".cursor/mcp.json"), theirs = theirs
        var hooks = ApplyHooks.none
        hooks.afterRename = { try? Data(theirs.utf8).write(to: URL(fileURLWithPath: path)) }
        hooks.check = { _ in false }   // would roll back, if the file were still ours
        let text = message { _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks) }
        #expect(text.contains("changed by something else") && text.contains("did not put the original back"))
        #expect(text.contains("client-backups/cursor-"))
        #expect(home.read(".cursor/mcp.json") == theirs)
        #expect(home.backups.count == 1)
    }

    @Test func aNewFileThatSomeoneElseReplacedIsNotDeleted() throws {
        let home = try Home()
        try FileManager.default.createDirectory(atPath: home.path(".cursor"), withIntermediateDirectories: true)
        let path = home.path(".cursor/mcp.json"), theirs = theirs
        var hooks = ApplyHooks.none
        hooks.afterRename = { try? FileManager.default.removeItem(atPath: path); try? Data(theirs.utf8).write(to: URL(fileURLWithPath: path)) }
        hooks.check = { _ in false }
        #expect(message { _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks) }.contains("changed by something else"))
        #expect(home.read(".cursor/mcp.json") == theirs)
    }

    // MARK: rollback

    @Test func aBadWriteIsRolledBackAndCheckedAndSaysSo() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original, permissions: 0o640)
        var hooks = ApplyHooks.none
        hooks.check = { _ in false }
        let text = message { _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks) }
        #expect(text.contains("original was put back and checked") && text.contains("client-backups/cursor-"))
        #expect(home.read(".cursor/mcp.json") == original)
        let mode = ((try FileManager.default.attributesOfItem(atPath: home.path(".cursor/mcp.json")))[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o640)
        #expect(home.files(in: ".cursor") == ["mcp.json"])

        // A file that didn't exist is removed again.
        let fresh = try Home()
        try FileManager.default.createDirectory(atPath: fresh.path(".cursor"), withIntermediateDirectories: true)
        #expect(message { _ = try ClientConfig.apply(try plan(fresh), now: Date(), hooks: hooks) }.contains("put back"))
        #expect(fresh.files(in: ".cursor").isEmpty)
    }

    @Test func aRollbackThatFailsIsReportedAsAFailureWithTheBackupAndTheState() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        let folder = home.path(".cursor")
        var hooks = ApplyHooks.none
        hooks.afterRename = { chmod(folder, 0o500) }   // nothing can be created in the folder now
        hooks.check = { _ in false }
        let text = message { _ = try ClientConfig.apply(try plan(home), now: Date(), hooks: hooks) }
        chmod(folder, 0o755)
        #expect(text.contains("could NOT be put back") && !text.contains("original was put back"))
        #expect(text.contains("still holds the new contents") && text.contains("client-backups/cursor-"))
        #expect(home.read(".cursor/mcp.json")?.contains("\"mac\"") == true)
        #expect(home.backups.count == 1)
    }

    // MARK: owner, group and ACLs

    @Test func theGroupAndTheAccessListSurviveTheReplacement() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original, permissions: 0o640)
        let file = home.path(".cursor/mcp.json")
        var groups = [gid_t](repeating: 0, count: 64)
        let count = Int(getgroups(64, &groups))
        let other = groups.prefix(max(count, 0)).first { $0 != getegid() }
        if let other { #expect(chown(file, uid_t.max, other) == 0) }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,readattr", file]
        try chmod.run()
        chmod.waitUntilExit()
        let before = try fingerprint(file)
        #expect(before.acl?.contains("allow") == true)
        _ = try ClientConfig.apply(try plan(home))
        let after = try fingerprint(file)
        #expect(after.acl == before.acl && after.gid == before.gid && after.uid == before.uid && after.mode == before.mode)
        if let other { #expect(after.gid == other) }
        #expect(home.read(".cursor/mcp.json")?.contains("\"mac\"") == true)
    }

    private func fingerprint(_ path: String) throws -> (uid: uid_t, gid: gid_t, mode: mode_t, acl: String?) {
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        return (info.st_uid, info.st_gid, info.st_mode & 0o7777, ClientFiles.aclText(fd))
    }

    @Test func metadataThatCantBeCopiedStopsTheCopy() throws {
        #expect(throws: ClientConfigError.self) { try ClientFiles.copySecurity(from: -1, to: -1) }
    }

    // MARK: names and advice

    @Test func optionLikeNamesAreRefusedForEveryClientBeforeAnythingRuns() throws {
        for client in McpClient.allCases {
            let home = try Home()
            for name in ["--help", "-h", "--scope", "a b"] {
                let request = ClientInstaller.Request(client: client, name: name, entry: local, environment: home.environment)
                #expect(throws: ClientConfigError.self, "\(client) \(name)") {
                    try ClientInstaller.run(request, runCommand: { _, _ in Issue.record("nothing should run"); return (0, "") })
                }
            }
        }
    }

    @Test func aNameWithADotIsKeptWholeInCodexsToml() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"x\"\n")
        var env = home.environment
        env.variables["PATH"] = "/nonexistent"
        _ = try ClientInstaller.run(.init(client: .codex, name: "a.b", entry: local, environment: env), runCommand: { _, _ in (1, "") })
        let text = try #require(home.read(".codex/config.toml"))
        #expect(text.contains("[mcp_servers.\"a.b\"]") && text.contains("[mcp_servers.a]\ncommand = \"x\""))
        #expect(try ClientConfig.registered(.codex, name: "a.b", in: Data(text.utf8)) == local)
        #expect(try ClientConfig.registered(.codex, name: "a", in: Data(text.utf8))?.command == "x")
    }

    @Test func dryRunsTellThePersonToQuitTheClientFirst() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", original)
        let r = try ClientInstaller.run(.init(client: .cursor, entry: local, dryRun: true, environment: home.environment), runCommand: { _, _ in (1, "") })
        #expect(r.lines.contains { $0.contains("Quit Cursor first") && $0.contains("don't lock") })
        #expect(ClientInstaller.quitAdvice(for: .claudeCode).contains("Quit Claude Code first"))
    }
}
