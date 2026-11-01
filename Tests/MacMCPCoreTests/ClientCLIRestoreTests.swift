import Foundation
import Testing
@testable import MacMCPCore

/// Replacing an entry through the `claude` and `codex` CLIs, with fake programs. Nothing real runs.
@Suite struct ClientCLIRestoreTests {
    typealias Home = ClientInstallerTests.Home
    let local = ServerEntry(command: "/opt/mac/bin/mac-mcp")
    let existing = "{\"mcpServers\": {\"mac\": {\"type\": \"stdio\", \"command\": \"old\", \"args\": [\"a\"], \"env\": {\"TOKEN\": \"secret\"}}}}\n"
    let savedJSON = "{\"args\":[\"a\"],\"command\":\"old\",\"env\":{\"TOKEN\":\"secret\"},\"type\":\"stdio\"}"

    func environment(_ home: Home, program: String) throws -> ClientEnvironment {
        let bin = home.path("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin + "/" + program, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return ClientEnvironment(home: home.root, variables: ["PATH": "/nonexistent:" + bin])
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String]] = []
        private var notes: [String] = []
        var calls: [[String]] { lock.withLock { items } }
        var told: [String] { lock.withLock { notes } }
        func record(_ args: [String]) -> Int { lock.withLock { items.append(args); return items.count } }
        func note(_ text: String) { lock.withLock { notes.append(text) } }
    }

    // MARK: Claude Code

    @Test func aFailedAddPutsThePreviousEntryBackWithAddJSON() throws {
        let home = try Home()
        try home.write(".claude.json", existing)
        let env = try environment(home, program: "claude")
        let script = Script()
        let message = {
            do {
                _ = try ClientInstaller.run(.init(client: .claudeCode, entry: local, environment: env), runCommand: { _, args in
                    switch (script.record(args), args[1]) {
                    case (1, _): return (1, "MCP server mac already exists in user config")
                    case (_, "remove"): return (0, "removed")
                    case (_, "add"): return (1, "boom")
                    default: return (0, "restored")   // add-json
                    }
                }, notify: { script.note($0) })
                return ""
            } catch { return "\(error)" }
        }()
        #expect(script.calls.map { $0[1] } == ["add", "remove", "add", "add-json"])
        #expect(script.calls[3] == ["mcp", "add-json", "--scope", "user", "--", "mac", savedJSON])
        #expect(message.contains("boom") && message.contains("put back and checked"))
        // The saved copy exists and a person was told where it is before anything was removed.
        let saved = try #require(home.backups.first)
        #expect(home.read(Home.backupFolder + "/" + saved) == savedJSON)
        #expect(script.told.first?.contains(Home.backupFolder) == true && script.told.first?.contains("add-json") == true)
    }

    @Test func aRestoreThatFailsGivesExactRecoveryInstructions() throws {
        let home = try Home()
        try home.write(".claude.json", existing)
        let env = try environment(home, program: "claude")
        let path = home.path(".claude.json")
        let script = Script()
        let text: String
        do {
            _ = try ClientInstaller.run(.init(client: .claudeCode, entry: local, environment: env), runCommand: { _, args in
                switch (script.record(args), args[1]) {
                case (1, _): return (1, "already exists")
                case (_, "remove"): try? Data("{}".utf8).write(to: URL(fileURLWithPath: path)); return (0, "")
                case (_, "add"): return (-1, "timed out")
                default: return (1, "cannot parse")
                }
            })
            text = ""
        } catch { text = "\(error)" }
        #expect(text.contains("could NOT be put back") && text.contains("timed out") && text.contains("cannot parse"))
        let saved = home.path(Home.backupFolder + "/" + (home.backups.first ?? "?"))
        #expect(text.contains("claude mcp add-json --scope user -- mac \"$(cat ") && text.contains(saved))
        #expect(!text.contains("secret"))   // the entry may hold credentials: it is never printed
    }

    @Test func aRestoreThatDoesntReadBackIsNotReportedAsDone() throws {
        let home = try Home()
        try home.write(".claude.json", existing)
        let env = try environment(home, program: "claude")
        let path = home.path(".claude.json")
        let script = Script()
        let text: String
        do {
            _ = try ClientInstaller.run(.init(client: .claudeCode, entry: local, environment: env), runCommand: { _, args in
                switch (script.record(args), args[1]) {
                case (1, _): return (1, "already exists")
                case (_, "remove"): try? Data("{}".utf8).write(to: URL(fileURLWithPath: path)); return (0, "")
                case (_, "add"): return (1, "boom")
                default: return (0, "")   // claims success, wrote nothing
                }
            })
            text = ""
        } catch { text = "\(error)" }
        #expect(text.contains("could NOT be put back") && text.contains("didn't read back the same") && !text.contains("put back and checked"))
    }

    @Test func anEntryThatCantBeCapturedIsNeverRemoved() throws {
        let home = try Home()   // no .claude.json to read the entry from
        let env = try environment(home, program: "claude")
        let script = Script()
        let text: String
        do {
            _ = try ClientInstaller.run(.init(client: .claudeCode, entry: local, environment: env), runCommand: { _, args in
                _ = script.record(args)
                return (1, "already exists")
            })
            text = ""
        } catch { text = "\(error)" }
        #expect(script.calls.map { $0[1] } == ["add"])
        #expect(text.contains("did not remove it") && text.contains("claude mcp remove --scope user -- mac"))
        #expect(home.backups.isEmpty)
    }

    @Test func aFailedRemoveLeavesTheEntryAndSaysSo() throws {
        let home = try Home()
        try home.write(".claude.json", existing)
        let env = try environment(home, program: "claude")
        let script = Script()
        let text: String
        do {
            _ = try ClientInstaller.run(.init(client: .claudeCode, entry: local, environment: env), runCommand: { _, args in
                switch (script.record(args), args[1]) {
                case (1, _): return (1, "already exists")
                default: return (1, "locked")
                }
            })
            text = ""
        } catch { text = "\(error)" }
        #expect(script.calls.map { $0[1] } == ["add", "remove"] && text.contains("locked") && text.contains("unchanged"))
    }

    @Test func positionalArgumentsFollowDoubleDashWhereTheCLIAllowsIt() throws {
        let home = try Home()
        let env = try environment(home, program: "claude")
        let script = Script()
        _ = try ClientInstaller.run(.init(client: .claudeCode, name: "mac", entry: nil, environment: env), runCommand: { _, args in _ = script.record(args); return (0, "") })
        #expect(script.calls == [["mcp", "remove", "--scope", "user", "--", "mac"]])
    }

    // MARK: Codex

    @Test func codexAddsANewEntryWithItsOwnCLI() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "model = \"x\"\n")
        let env = try environment(home, program: "codex")
        let script = Script()
        let r = try ClientInstaller.run(.init(client: .codex, entry: local, environment: env), runCommand: { _, args in _ = script.record(args); return (0, "Added global MCP server 'mac'.") })
        #expect(script.calls == [["mcp", "add", "mac", "--", "/opt/mac/bin/mac-mcp"]])
        #expect(r.change == .added && home.read(".codex/config.toml") == "model = \"x\"\n" && home.backups.isEmpty)
        let remote = try ServerEntry.remote("me@host")
        let again = Script()
        _ = try ClientInstaller.run(.init(client: .codex, name: "work", entry: remote, environment: env), runCommand: { _, args in _ = again.record(args); return (0, "") })
        #expect(again.calls == [["mcp", "add", "work", "--", "ssh", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "me@host", "~/.local/bin/mac-mcp"]])
    }

    @Test func codexReplacesAnExistingEntryInTheFileWithABackup() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "[mcp_servers.mac]\ncommand = \"old\"\nargs = []\n")
        let env = try environment(home, program: "codex")
        let r = try ClientInstaller.run(.init(client: .codex, entry: local, environment: env), runCommand: { _, _ in Issue.record("no CLI"); return (1, "") })
        #expect(r.change == .replaced && home.backups.count == 1)
        #expect(try ClientConfig.registered(.codex, name: "mac", in: Data(try #require(home.read(".codex/config.toml")).utf8)) == local)
        // Already as wanted: nothing runs and nothing changes.
        let same = try ClientInstaller.run(.init(client: .codex, entry: local, environment: env), runCommand: { _, _ in Issue.record("no CLI"); return (1, "") })
        #expect(same.change == .unchanged)
    }

    @Test func codexRemovesThroughItsCLIOnlyWhenTheEntryIsThere() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "[mcp_servers.mac]\ncommand = \"x\"\n")
        let env = try environment(home, program: "codex")
        let script = Script()
        let removed = try ClientInstaller.run(.init(client: .codex, entry: nil, environment: env), runCommand: { _, args in _ = script.record(args); return (0, "") })
        #expect(script.calls == [["mcp", "remove", "--", "mac"]] && removed.change == .removed)
        let other = try ClientInstaller.run(.init(client: .codex, name: "gone", entry: nil, environment: env), runCommand: { _, _ in Issue.record("no CLI"); return (1, "") })
        #expect(other.change == .unchanged)
        let dry = try ClientInstaller.run(.init(client: .codex, name: "fresh", entry: local, dryRun: true, environment: env), runCommand: { _, _ in Issue.record("no CLI"); return (1, "") })
        #expect(dry.change == .added && dry.lines.joined().contains("would run `codex mcp add fresh -- /opt/mac/bin/mac-mcp`"))
        #expect(dry.lines.contains { $0.contains("Quit Codex first") })
    }

    @Test func codexCLIFailuresAreReportedAndMalformedFilesStopBeforeTheCLIRuns() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "model = \"x\"\n")
        let env = try environment(home, program: "codex")
        do { _ = try ClientInstaller.run(.init(client: .codex, entry: local, environment: env), runCommand: { _, _ in (1, "nope") }); Issue.record("should fail") }
        catch { #expect("\(error)".contains("`codex mcp add` failed: nope")) }
        try home.write(".codex/config.toml", "a = 1\na = 2\n")
        do { _ = try ClientInstaller.run(.init(client: .codex, entry: local, environment: env), runCommand: { _, _ in Issue.record("no CLI"); return (0, "") }); Issue.record("should fail") }
        catch { #expect("\(error)".contains("duplicate key") && "\(error)".contains("Nothing was changed")) }
    }

    @Test func withoutCodexOnPATHTheFileIsEdited() throws {
        let home = try Home()
        try home.write(".codex/config.toml", "model = \"x\"\n")
        var env = home.environment
        env.variables["PATH"] = "/nonexistent"
        _ = try ClientInstaller.run(.init(client: .codex, entry: local, environment: env), runCommand: { _, _ in Issue.record("no CLI"); return (1, "") })
        #expect(home.read(".codex/config.toml")?.contains("[mcp_servers.mac]") == true && home.backups.count == 1)
    }
}
