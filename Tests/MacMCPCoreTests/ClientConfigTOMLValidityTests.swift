import Foundation
import Testing
@testable import MacMCPCore

/// What the TOML scanner refuses beyond syntax: keys and tables defined twice, and dates that don't exist.
@Suite struct ClientConfigTOMLValidityTests {
    func parses(_ text: String) -> String? {
        do { _ = try TOMLScanner(Array(text.utf8)).parse(); return nil } catch { return "\(error)" }
    }

    @Test func refusesKeysAndTablesDefinedTwice() {
        let bad: [(String, String)] = [
            ("a = 1\na = 2\n", "duplicate key `a`"),
            ("a = 1\n\"a\" = 2\n", "duplicate key"),
            ("[x]\ny = 1\ny = 2\n", "duplicate key `y`"),
            ("[x]\na = 1\n[x]\nb = 2\n", "defined more than once"),
            ("[mcp_servers.mac]\ncommand = \"a\"\n[mcp_servers.mac]\nargs = []\n", "defined more than once"),
            ("a = 1\n[a]\n", "defined more than once, or redefines a key"),
            ("[a]\nb = 1\n[a.b]\n", "defined more than once, or redefines a key"),
            ("[a]\nb = 1\n[a.b.c]\n", "value, not a table"),
            ("a.b = 1\n[a]\n", "redefines a key"),
            ("a.b = 1\na.b = 2\n", "duplicate key `a.b`"),
            ("a = 1\na.b = 2\n", "redefines `a`"),
            ("[a.b]\nx = 1\n[a]\nb.c = 2\n", "redefines `b`"),
            ("[[a]]\n[a]\n", "redefines a key"),
            ("[a]\n[[a]]\n", "already defined"),
            ("a = [1, 2]\n[[a]]\n", "already defined"),
            ("a = {b = 1, b = 2}\n", "duplicate key `b`"),
            ("a = {b = 1}\n[a.c]\n", "value, not a table"),
            ("a = {b = {c = 1, c = 2}}\n", "duplicate key `c`"),
        ]
        for (text, why) in bad {
            let error = parses(text)
            #expect(error?.contains(why) == true, "\(text.debugDescription): \(error ?? "accepted")")
        }
        #expect(parses("a = 1\na = 2\n")?.contains("line 2") == true)
    }

    @Test func acceptsWhatTOMLAllows() {
        let good = [
            "[a.b]\nx = 1\n[a]\ny = 2\n",
            "[[a]]\nx = 1\n[a.b]\ny = 1\n[[a]]\nx = 2\n[a.b]\ny = 2\n",
            "a.b = 1\na.c = 2\n",
            "[x]\na.b = 1\n[x.a.c]\nd = 1\n",
            "[a]\nx = 1\n[b]\nx = 2\n",
            "a = {b = 1}\nc = {b = 2}\n",
            "[mcp_servers.one]\ncommand = \"x\"\n[mcp_servers.one.env]\nK = \"v\"\n[mcp_servers.two]\ncommand = \"y\"\n",
            "[a]\n[b]\n[a.c]\n",
            "\"a.b\" = 1\n[a]\nb = 2\n",
        ]
        for text in good { #expect(parses(text) == nil, "\(text.debugDescription): \(parses(text) ?? "")") }
    }

    @Test func refusesDatesAndTimesThatDontExist() {
        for value in ["2024-13-01", "2024-00-10", "2023-02-29", "2024-02-30", "2024-04-31", "2024-01-32", "2024-01-00",
                      "24:00:00", "12:60:00", "12:00:61", "2024-01-01T25:00:00Z", "2024-01-01T12:61:00", "2024-01-01T12:00:00+24:00",
                      "2024-01-01T12:00:00+01:60"] {
            #expect(parses("x = \(value)\n")?.contains("invalid date or time") == true, "\(value)")
        }
        for value in ["2024-02-29", "2000-02-29", "1900-03-01", "07:32:00", "23:59:60", "1979-05-27T07:32:00Z", "1979-05-27 07:32:00.999-07:00",
                      "1979-05-27T07:32", "2024-12-31T23:59:59+23:59"] {
            #expect(parses("x = \(value)\n") == nil, "\(value): \(parses("x = \(value)\n") ?? "")")
        }
        #expect(parses("x = [2024-13-01]\n") != nil && parses("x = {d = 2023-02-29}\n") != nil)
    }

    @Test func malformedInputIsRefusedBeforeAnythingIsBackedUpOrWritten() throws {
        typealias Home = ClientInstallerTests.Home
        let home = try Home()
        let bad = "[mcp_servers.mac]\ncommand = \"a\"\ncommand = \"b\"\n"
        try home.write(".codex/config.toml", bad)
        var env = home.environment
        env.variables["PATH"] = "/nonexistent"
        for entry in [ServerEntry(command: "/opt/mac/bin/mac-mcp"), nil] {
            let request = ClientInstaller.Request(client: .codex, entry: entry, environment: env)
            do { _ = try ClientInstaller.run(request, runCommand: { _, _ in (1, "") }); Issue.record("should refuse") }
            catch { #expect("\(error)".contains("duplicate key") && "\(error)".contains("Nothing was changed")) }
        }
        #expect(home.read(".codex/config.toml") == bad && home.backups.isEmpty && home.files(in: ".codex") == ["config.toml"])
    }

    @Test func editedOutputIsValidatedToo() throws {
        // Every edit the editor makes parses again, including when a name needs quoting.
        let r = try TOMLConfigEditor.upsert(Data("a = 1\n".utf8), name: "x.y", command: "c\"d", args: ["é", "\t"])
        #expect(parses(String(decoding: r.data, as: UTF8.self)) == nil)
        let removed = try TOMLConfigEditor.remove(r.data, name: "x.y")
        #expect(String(decoding: removed.data, as: UTF8.self) == "a = 1\n")
    }
}
