import Foundation
import Testing
@testable import MacMCPCore

/// Planning and writing client configs, and the install flow, in temporary folders standing in for the home folder.
/// Nothing here touches a real client's config or runs a real `claude`.
@Suite struct ClientInstallerTests {
    final class Home {
        let root: String
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("client-config-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
        var environment: ClientEnvironment { .init(home: root, variables: [:]) }
        func path(_ relative: String) -> String { root + "/" + relative }
        func write(_ relative: String, _ text: String, permissions: Int = 0o644) throws {
            let full = path(relative)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: full, contents: Data(text.utf8), attributes: [.posixPermissions: permissions])
        }
        func read(_ relative: String) -> String? { FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) } }
        func files(in relative: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: path(relative))) ?? []).sorted() }
    }

    let local = ServerEntry(command: "/opt/mac/bin/mac-mcp")
    let none: ClientInstaller.CommandRunner = { _, _ in Issue.record("no program should run"); return (1, "") }

    func request(_ client: McpClient, _ home: Home, entry: ServerEntry? = ServerEntry(command: "/opt/mac/bin/mac-mcp"), name: String = "mac",
                 dryRun: Bool = false, create: Bool = false) -> ClientInstaller.Request {
        .init(client: client, name: name, entry: entry, dryRun: dryRun, createFolder: create, environment: home.environment)
    }

    // MARK: where each client keeps its config

    @Test func eachClientHasItsOwnFileUnderTheHome() {
        let env = ClientEnvironment(home: "/h")
        #expect(McpClient.claudeCode.configPath(in: env) == "/h/.claude.json")
        #expect(McpClient.claudeDesktop.configPath(in: env) == "/h/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(McpClient.codex.configPath(in: env) == "/h/.codex/config.toml")
        #expect(McpClient.cursor.configPath(in: env) == "/h/.cursor/mcp.json")
        #expect(McpClient.vscode.configPath(in: env) == "/h/Library/Application Support/Code/User/mcp.json")
        let moved = ClientEnvironment(home: "/h", variables: ["CODEX_HOME": "/c", "CLAUDE_CONFIG_DIR": "/cl"])
        #expect(McpClient.codex.configPath(in: moved) == "/c/config.toml")
        #expect(McpClient.claudeCode.configPath(in: moved) == "/cl/.claude.json")
        #expect(McpClient.codex.configPath(in: ClientEnvironment(home: "/h", variables: ["CODEX_HOME": ""])) == "/h/.codex/config.toml")
    }

    @Test func clientNamesParseLeniently() {
        #expect(McpClient(argument: "Claude_Code") == .claudeCode)
        #expect(McpClient(argument: "vscode") == .vscode)
        #expect(McpClient(argument: "emacs") == nil)
    }

    @Test func serverNamesAreChecked() throws {
        for good in ["mac", "mac-2", "Mac_mini", "-x"] { try ClientConfig.validate(name: good) }
        for bad in ["", "a b", "a.b", "a\"b", "é", String(repeating: "a", count: 65), "a/b", "a\nb"] {
            #expect(throws: ClientConfigError.self, "\(bad)") { try ClientConfig.validate(name: bad) }
        }
    }

    @Test func remoteEntriesRunSSHLikeRemoteSetup() throws {
        let entry = try ServerEntry.remote("me@my-mac.local")
        #expect(entry.command == "ssh")
        #expect(entry.args == ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "me@my-mac.local", "~/.local/bin/mac-mcp"])
        _ = try ServerEntry.remote("my-mac")
        _ = try ServerEntry.remote("me@192.168.1.5")
        for bad in ["", "-oProxyCommand=x", "me@", "me host", "me@host;rm", "a b@c", "me@host $(x)", "@host", "me@ho\nst"] {
            #expect(throws: ClientConfigError.self, "\(bad)") { try ServerEntry.remote(bad) }
        }
    }

    // MARK: each client end to end

    @Test func addsToEveryClientAndRemovesAgain() throws {
        let cases: [(McpClient, String, String)] = [
            (.claudeDesktop, "Library/Application Support/Claude/claude_desktop_config.json", "{\n  \"globalShortcut\": \"Ctrl+Space\"\n}\n"),
            (.cursor, ".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"other\": { \"url\": \"https://example.com/mcp\" }\n  }\n}\n"),
            (.vscode, "Library/Application Support/Code/User/mcp.json", "// my servers\n{\n  \"servers\": {},\n  \"inputs\": []\n}\n"),
            (.codex, ".codex/config.toml", "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"),
            (.claudeCode, ".claude.json", "{\n  \"numStartups\": 3,\n  \"projects\": {}\n}\n"),
        ]
        for (client, file, original) in cases {
            let home = try Home()
            try home.write(file, original)
            var env = home.environment
            env.variables["PATH"] = "/nonexistent"
            let added = try ClientInstaller.run(.init(client: client, entry: local, environment: env), runCommand: none)
            #expect(added.change == .added, "\(client)")
            let text = try #require(home.read(file))
            #expect(text != original)
            #expect(try ClientConfig.registered(client, name: "mac", in: Data(text.utf8)) == local, "\(client)")
            let dir = (file as NSString).deletingLastPathComponent
            let backups = home.files(in: dir).filter { $0.contains(".macmcp-backup-") }
            #expect(backups.count == 1, "\(client)")
            #expect(home.read(dir + "/" + backups[0]) == original)
            #expect(added.lines.contains { $0.contains("Backup of the original") })
            #expect(added.lines.contains { $0.contains("~/") && $0.contains("added") })
            #expect(!added.lines.contains { $0.contains(home.root) })

            let removed = try ClientInstaller.run(.init(client: client, entry: nil, environment: env), runCommand: none)
            #expect(removed.change == .removed)
            #expect(try ClientConfig.registered(client, name: "mac", in: Data(try #require(home.read(file)).utf8)) == nil)
        }
    }

    @Test func installThenUninstallRestoresTheOriginalBytes() throws {
        let originals: [(McpClient, String, String)] = [
            (.cursor, ".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"other\": { \"command\": \"x\" }\n  }\n}\n"),
            (.claudeDesktop, "Library/Application Support/Claude/claude_desktop_config.json", "{\n\t\"mcpServers\": {\n\t\t\"a\": {}\n\t},\n\t\"z\": 1\n}\n"),
            (.vscode, "Library/Application Support/Code/User/mcp.json", "{\n  // c\n  \"servers\": {\n    \"a\": { \"command\": \"x\" },\n  },\n}\n"),
            (.codex, ".codex/config.toml", "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"),
        ]
        for (client, file, original) in originals {
            let home = try Home()
            try home.write(file, original)
            _ = try ClientInstaller.run(request(client, home), runCommand: none)
            _ = try ClientInstaller.run(request(client, home, entry: nil), runCommand: none)
            #expect(home.read(file) == original, "\(client)")
        }
    }

    @Test func replacesAnEntryAndSaysSo() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", "{\"mcpServers\": {\"mac\": {\"command\": \"old\"}}}")
        let r = try ClientInstaller.run(request(.cursor, home), runCommand: none)
        #expect(r.change == .replaced && r.lines[0].contains("replaced"))
        #expect(try ClientConfig.registered(.cursor, name: "mac", in: Data(home.read(".cursor/mcp.json")!.utf8)) == local)
        let again = try ClientInstaller.run(request(.cursor, home), runCommand: none)
        #expect(again.change == .unchanged)
        #expect(home.files(in: ".cursor").filter { $0.contains("backup") }.count == 1)
    }

    @Test func aDifferentNameLeavesTheDefaultEntryAlone() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", "{\"mcpServers\": {\"mac\": {\"command\": \"mine\"}}}")
        _ = try ClientInstaller.run(request(.cursor, home, name: "work-mac"), runCommand: none)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(home.read(".cursor/mcp.json")!.utf8)) as? [String: Any])
        let servers = json["mcpServers"] as? [String: Any]
        #expect(Set((servers ?? [:]).keys) == ["mac", "work-mac"])
        #expect((servers?["mac"] as? [String: Any])?["command"] as? String == "mine")
    }

    @Test func aRemoteEntryRunsSSH() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "")
        let entry = try ServerEntry.remote("me@host")
        _ = try ClientInstaller.run(request(.codex, home, entry: entry), runCommand: none)
        #expect(try ClientConfig.registered(.codex, name: "mac", in: Data(home.read(".codex/config.toml")!.utf8)) == entry)
    }

    // MARK: safety

    @Test func dryRunPrintsTheChangeAndWritesNothing() throws {
        let home = try Home()
        let original = "{\n  \"mcpServers\": {\n    \"a\": {}\n  }\n}\n"
        try home.write(".cursor/mcp.json", original)
        let r = try ClientInstaller.run(request(.cursor, home, dryRun: true), runCommand: none)
        #expect(r.change == .added)
        #expect(home.read(".cursor/mcp.json") == original)
        #expect(home.files(in: ".cursor") == ["mcp.json"])
        let text = r.lines.joined(separator: "\n")
        #expect(text.contains("would add") && text.contains("Nothing was written"))
        #expect(text.contains("+     \"mac\": {") && text.contains("+       \"command\": \"/opt/mac/bin/mac-mcp\""))
        // A file that doesn't exist yet is not created either.
        let fresh = try Home()
        _ = try ClientInstaller.run(request(.codex, fresh, dryRun: true, create: true), runCommand: none)
        #expect(!FileManager.default.fileExists(atPath: fresh.path(".codex")))
    }

    @Test func dryRunRemoveShowsWhatGoes() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "a = 1\n\n[mcp_servers.mac]\ncommand = \"x\"\nargs = []\n")
        let r = try ClientInstaller.run(request(.codex, home, entry: nil, dryRun: true), runCommand: none)
        let text = r.lines.joined(separator: "\n")
        #expect(text.contains("would remove") && text.contains("- [mcp_servers.mac]") && text.contains("- command = \"x\""))
        #expect(home.read(".codex/config.toml")?.contains("[mcp_servers.mac]") == true)
    }

    @Test func refusesAFileThatDoesntParseAndLeavesItAlone() throws {
        let home = try Home()
        let bad = "{\n  \"mcpServers\": {\n    \"a\": {,}\n  }\n}\n"
        try home.write(".cursor/mcp.json", bad)
        #expect(throws: ClientConfigError.self) { try ClientInstaller.run(request(.cursor, home), runCommand: none) }
        #expect(throws: ClientConfigError.self) { try ClientInstaller.run(request(.cursor, home, entry: nil), runCommand: none) }
        #expect(home.read(".cursor/mcp.json") == bad)
        #expect(home.files(in: ".cursor") == ["mcp.json"])
        try home.write(".codex/config.toml", "a = [1,\n")
        #expect(throws: ClientConfigError.self) { try ClientInstaller.run(request(.codex, home), runCommand: none) }
        #expect(home.files(in: ".codex") == ["config.toml"])
        do { _ = try ClientInstaller.run(request(.cursor, home), runCommand: none) } catch { #expect("\(error)".contains("Nothing was changed")) }
    }

    @Test func aMissingFolderMeansTheClientIsntInstalledUnlessAskedToCreateIt() throws {
        let home = try Home()
        do { _ = try ClientInstaller.run(request(.cursor, home), runCommand: none); Issue.record("should refuse") }
        catch { #expect("\(error)".contains("--create")) }
        #expect(!FileManager.default.fileExists(atPath: home.path(".cursor")))
        let r = try ClientInstaller.run(request(.cursor, home, create: true), runCommand: none)
        #expect(r.change == .added)
        #expect(home.files(in: ".cursor") == ["mcp.json"])
        #expect(!r.lines.contains { $0.contains("Backup") })
        // With the folder but no file, a file is simply created; removing from no file does nothing.
        let codex = try Home()
        try FileManager.default.createDirectory(atPath: codex.path(".codex"), withIntermediateDirectories: true)
        _ = try ClientInstaller.run(request(.codex, codex), runCommand: none)
        #expect(codex.read(".codex/config.toml") == "[mcp_servers.mac]\ncommand = \"/opt/mac/bin/mac-mcp\"\nargs = []\n")
        let empty = try Home()
        #expect(try ClientInstaller.run(request(.cursor, empty, entry: nil), runCommand: none).change == .unchanged)
    }

    @Test func keepsTheFilesPermissionsAndFollowsSymlinks() throws {
        let home = try Home()
        try home.write("dotfiles/claude.json", "{\"a\": 1}\n", permissions: 0o600)
        try FileManager.default.createSymbolicLink(atPath: home.path(".claude.json"), withDestinationPath: home.path("dotfiles/claude.json"))
        var env = home.environment
        env.variables["PATH"] = "/nonexistent"   // no `claude` to run
        _ = try ClientInstaller.run(.init(client: .claudeCode, entry: local, environment: env), runCommand: none)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.path("dotfiles/claude.json"))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.path(".claude.json"))) == home.path("dotfiles/claude.json"))
        #expect(home.read("dotfiles/claude.json")?.contains("\"mac\"") == true)
        let backup = try #require(home.files(in: "dotfiles").first { $0.contains("backup") })
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: home.path("dotfiles/" + backup))
        #expect((backupAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!home.files(in: "dotfiles").contains { $0.hasSuffix(".tmp") })
    }

    @Test func refusesToWriteOverAFileThatChangedAfterItWasRead() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", "{}\n")
        let plan = try ClientConfig.plan(.cursor, name: "mac", entry: local, environment: home.environment)
        try home.write(".cursor/mcp.json", "{\"mcpServers\": {\"new\": {}}}\n")
        #expect(throws: ClientConfigError.self) { try ClientConfig.apply(plan) }
        #expect(home.read(".cursor/mcp.json") == "{\"mcpServers\": {\"new\": {}}}\n")
        #expect(home.files(in: ".cursor") == ["mcp.json"])
    }

    @Test func backupsNeverOverwriteEachOther() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", "{}\n")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(try ClientConfig.apply(try ClientConfig.plan(.cursor, name: "a", entry: local, environment: home.environment), now: now))
        let second = try #require(try ClientConfig.apply(try ClientConfig.plan(.cursor, name: "b", entry: local, environment: home.environment), now: now))
        #expect(first != second && first.contains(".macmcp-backup-"))
        #expect(FileManager.default.contents(atPath: first) == Data("{}\n".utf8))
    }

    @Test func aRealRunWritesExactlyWhatTheDryRunShowed() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "model = \"x\"\n")
        let plan = try ClientConfig.plan(.codex, name: "mac", entry: local, environment: home.environment)
        _ = try ClientInstaller.run(request(.codex, home), runCommand: none)
        #expect(home.read(".codex/config.toml") == String(decoding: plan.updated, as: UTF8.self))
    }

    // MARK: Claude Code's CLI

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String]] = []
        var all: [[String]] { lock.withLock { items } }
        func add(_ call: [String]) { lock.withLock { items.append(call) } }
    }

    /// An environment whose PATH holds a (never run) `claude`.
    func withClaude(_ home: Home, _ body: (ClientEnvironment) throws -> Void) throws {
        let bin = home.path("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin + "/claude", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try body(ClientEnvironment(home: home.root, variables: ["PATH": "/nonexistent:" + bin]))
    }

    @Test func claudeCodeUsesTheCLIWhenItIsOnPATH() throws {
        let home = try Home()
        try withClaude(home) { env in
            let calls = Calls()
            let r = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: local, environment: env), runCommand: { exe, args in
                calls.add([exe] + args)
                return (0, "Added stdio MCP server mac")
            })
            #expect(calls.all == [[home.path("bin/claude"), "mcp", "add", "--scope", "user", "mac", "--", "/opt/mac/bin/mac-mcp"]])
            #expect(r.change == .added && r.lines.contains("Added stdio MCP server mac"))
            #expect(!FileManager.default.fileExists(atPath: home.path(".claude.json")))
        }
    }

    @Test func claudeCodeReplacesByRemovingThenAdding() throws {
        let home = try Home()
        try withClaude(home) { env in
            let calls = Calls()
            let remote = try ServerEntry.remote("me@host")
            let r = try ClientInstaller.run(.init(client: .claudeCode, name: "work", entry: remote, environment: env), runCommand: { _, args in
                calls.add(args)
                return calls.all.count == 1 ? (1, "MCP server work already exists in user config") : (0, "ok")
            })
            #expect(calls.all.map { Array($0.prefix(2)) } == [["mcp", "add"], ["mcp", "remove"], ["mcp", "add"]])
            #expect(calls.all[1] == ["mcp", "remove", "--scope", "user", "work"])
            #expect(calls.all[2] == ["mcp", "add", "--scope", "user", "work", "--", "ssh", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "me@host", "~/.local/bin/mac-mcp"])
            #expect(r.change == .replaced)
        }
    }

    @Test func claudeCodeFailuresAreReportedWithTheirOutput() throws {
        let home = try Home()
        try withClaude(home) { env in
            do {
                _ = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: local, environment: env), runCommand: { _, _ in (1, "boom") })
                Issue.record("should have failed")
            } catch { #expect("\(error)".contains("boom")) }
            let calls = Calls()
            do {
                _ = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: local, environment: env), runCommand: { _, args in
                    calls.add(args)
                    return args[1] == "add" ? (1, "already exists") : (1, "cannot remove")
                })
                Issue.record("should have failed")
            } catch { #expect("\(error)".contains("cannot remove")) }
            #expect(calls.all.count == 2)   // it didn't go on to add
        }
    }

    @Test func claudeCodeUninstallAndDryRun() throws {
        let home = try Home()
        try withClaude(home) { env in
            let calls = Calls()
            let removed = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: nil, environment: env),
                                                  runCommand: { _, args in calls.add(args); return (0, "Removed MCP server mac") })
            #expect(calls.all == [["mcp", "remove", "--scope", "user", "mac"]] && removed.change == .removed)
            let missing = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: nil, environment: env),
                                                  runCommand: { _, _ in (1, "No MCP server found with name: mac") })
            #expect(missing.change == .unchanged)
            let dry = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: local, dryRun: true, environment: env), runCommand: none)
            #expect(dry.lines.joined().contains("would run `claude mcp add --scope user mac -- /opt/mac/bin/mac-mcp`"))
            let dryRemove = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: nil, dryRun: true, environment: env), runCommand: none)
            #expect(dryRemove.lines.joined().contains("would run `claude mcp remove --scope user mac`"))
        }
    }

    @Test func withoutTheCLIClaudeCodeEditsItsConfigFile() throws {
        let home = try Home()
        try home.write(".claude.json", "{\n  \"mcpServers\": {}\n}\n")
        var env = home.environment
        env.variables["PATH"] = "/nonexistent"
        let r = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: local, environment: env), runCommand: none)
        #expect(r.change == .added)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(home.read(".claude.json")!.utf8)) as? [String: Any])
        let entry = (json["mcpServers"] as? [String: Any])?["mac"] as? [String: Any]
        #expect(entry?["type"] as? String == "stdio" && entry?["command"] as? String == "/opt/mac/bin/mac-mcp")
        #expect(r.lines.contains { $0.contains("Quit Claude Code") })
    }

    // MARK: helpers

    @Test func quotesCommandsForDisplay() {
        #expect(ClientInstaller.shellQuote("ssh") == "ssh")
        #expect(ClientInstaller.shellQuote("me@host:2222") == "me@host:2222")
        #expect(ClientInstaller.shellQuote("a b") == "'a b'")
        #expect(ClientInstaller.shellQuote("it's") == "'it'\\''s'")
        #expect(ClientInstaller.shellQuote("") == "''")
    }

    @Test func locatesProgramsOnPATH() throws {
        let home = try Home()
        try home.write("a/tool", "x", permissions: 0o644)
        try home.write("b/tool", "x", permissions: 0o755)
        #expect(ClientInstaller.locate("tool", path: "\(home.path("a")):\(home.path("b"))") == home.path("b/tool"))
        #expect(ClientInstaller.locate("tool", path: home.path("a")) == nil)
        #expect(ClientInstaller.locate("tool", path: nil) == nil && ClientInstaller.locate("tool", path: "") == nil)
    }

    @Test func showsTheHomeFolderAsATilde() {
        #expect(ClientInstaller.display("/h/.codex/config.toml", home: "/h") == "~/.codex/config.toml")
        #expect(ClientInstaller.display("/hx/y", home: "/h") == "/hx/y")
        #expect(ClientInstaller.display("/h", home: "/h") == "~")
    }
}
