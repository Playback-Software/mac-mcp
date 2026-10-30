import Foundation
import Testing
@testable import MacMCPCore

/// Codex's config.toml, edited as fixture text.
@Suite struct ClientConfigTOMLTests {
    func upsert(_ s: String?, name: String = "mac", command: String = "/opt/mac/bin/mac-mcp", args: [String] = []) throws -> (text: String, outcome: ClientChange) {
        let r = try TOMLConfigEditor.upsert(s.map { Data($0.utf8) }, name: name, command: command, args: args)
        return (String(decoding: r.data, as: UTF8.self), r.outcome)
    }

    func remove(_ s: String, name: String = "mac") throws -> (text: String, outcome: ClientChange) {
        let r = try TOMLConfigEditor.remove(Data(s.utf8), name: name)
        return (String(decoding: r.data, as: UTF8.self), r.outcome)
    }

    let table = "[mcp_servers.mac]\ncommand = \"/opt/mac/bin/mac-mcp\"\nargs = []\n"

    @Test func createsTheFileOrAppendsAfterABlankLine() throws {
        #expect(try upsert(nil).text == table)
        #expect(try upsert("").text == table)
        let existing = "model = \"x\"  # keep\n\n[projects.\"/tmp/a\"]\ntrust_level = \"trusted\"\n"
        let r = try upsert(existing)
        #expect(r.outcome == .added)
        #expect(r.text == existing + "\n" + table)
        // No newline at the end, or already a blank line there.
        #expect(try upsert("a = 1").text == "a = 1\n\n" + table)
        #expect(try upsert("a = 1\n\n").text == "a = 1\n\n" + table)
    }

    @Test func writesTheArgsOfARemoteEntry() throws {
        let r = try upsert(nil, command: "ssh", args: ["-o", "ServerAliveInterval=30", "me@host", "~/.local/bin/mac-mcp"])
        #expect(r.text == "[mcp_servers.mac]\ncommand = \"ssh\"\nargs = [\"-o\", \"ServerAliveInterval=30\", \"me@host\", \"~/.local/bin/mac-mcp\"]\n")
        let tricky = try upsert(nil, command: "/a \"b\"\\c", args: ["tab\there"])
        #expect(try TOMLConfigEditor.entry(in: Data(tricky.text.utf8), name: "mac")?.command == "/a \"b\"\\c")
        #expect(try TOMLConfigEditor.entry(in: Data(tricky.text.utf8), name: "mac")?.args == ["tab\there"])
    }

    @Test func replacesTheTableAndItsSubTablesInPlace() throws {
        let original = """
            # top comment
            [mcp_servers.first]
            command = "one"

            [mcp_servers.mac]   # mine
            command = "old"
            args = ["--legacy"]
            startup_timeout_sec = 20

            [mcp_servers.mac.env]
            TOKEN = "x"

            # about the next table
            [mcp_servers.last]
            command = "two"

            """
        let r = try upsert(original)
        #expect(r.outcome == .replaced)
        #expect(r.text == """
            # top comment
            [mcp_servers.first]
            command = "one"

            \(table)
            # about the next table
            [mcp_servers.last]
            command = "two"

            """)
    }

    @Test func settingTheSameEntryAgainChangesNothing() throws {
        let first = try upsert("a = 1\n")
        let second = try upsert(first.text)
        #expect(second.outcome == .unchanged && second.text == first.text)
        let noNewline = try upsert(String(table.dropLast()))
        #expect(noNewline.outcome == .unchanged)
    }

    @Test func removesTheTableAndKeepsTheRest() throws {
        let original = """
            a = 1

            [mcp_servers.first]
            command = "one"

            [mcp_servers.mac]
            command = "c"
            args = ["x"]

            [mcp_servers.mac.env]
            K = "v"

            # about last
            [mcp_servers.last]
            command = "two"
            """
        let r = try remove(original)
        #expect(r.outcome == .removed)
        #expect(r.text == """
            a = 1

            [mcp_servers.first]
            command = "one"

            # about last
            [mcp_servers.last]
            command = "two"
            """)
        #expect(try remove("a = 1\n").outcome == .unchanged)
        #expect(try remove("[mcp_servers.other]\ncommand = \"x\"\n").outcome == .unchanged)
        #expect(try remove("").outcome == .unchanged)
    }

    @Test func recognisesQuotedNames() throws {
        let original = "[mcp_servers.\"mac\"]\ncommand = \"old\"\n"
        let r = try upsert(original)
        #expect(r.outcome == .replaced && r.text == table)
        #expect(try remove(original).outcome == .removed)
    }

    @Test func acceptsTheFullRangeOfTOMLValues() throws {
        let original = """
            title = "TOML \\u00e9 \\"quoted\\""
            literal = 'C:\\path'
            multi = \"\"\"
            first "quote" line \\
               continued
            \"\"\"
            raw = '''
            # not a comment
            [not.a.table]
            '''
            ints = [1, +2, 0xFF, 0o7, 0b1, 1_000, -0]
            floats = [1.5, -2e10, 3.14e-2, inf, -inf, nan]
            flags = { a = true, b = false, "c d" = [1, [2, 3], { e = 1 }] }
            when = 1979-05-27T07:32:00Z
            at = 1979-05-27 07:32:00
            day = 1979-05-27
            time = 07:32:00.5
            a.b.c = 1
            "quoted key" = 2
            'literal key' = 3
            nested = [
              "a",   # comment inside
              "b",
            ]

            [servers."x.y".z]
            ok = true
            [[array.of.tables]]
            n = 1
            [[array.of.tables]]
            n = 2
            """
        let r = try upsert(original)
        #expect(r.outcome == .added)
        #expect(r.text.hasPrefix(original + "\n\n[mcp_servers.mac]"))
    }

    @Test func worksWithWindowsLineEndings() throws {
        let original = "a = 1\r\n\r\n[x]\r\nb = \"2\"  # c\r\n"
        let r = try upsert(original)
        #expect(r.text == original + "\r\n[mcp_servers.mac]\r\ncommand = \"/opt/mac/bin/mac-mcp\"\r\nargs = []\r\n")
        #expect(try remove(r.text).text.replacingOccurrences(of: "\r\n\r\n", with: "\r\n") == original.replacingOccurrences(of: "\r\n\r\n", with: "\r\n"))
    }

    @Test func refusesFilesThatDontParse() {
        let bad = ["a = ", "a = 1 2", "a == 1", "= 1", "[unclosed", "[a]]", "a = \"unterminated", "a = 'unterminated", "a = [1, 2", "a = { b = 1",
                   "a = tru", "a = 01", "a = 1__0", "a = \"bad \\q escape\"", "a = \"\"\"never closed", "a = 1.", "a = 2024-13", "[a] b = 1",
                   "a = 1 # ok\nb", "[[a]", "a = \"line\nbreak\"", "a.= 1", "a = [1,, 2]"]
        for text in bad {
            #expect(throws: ConfigFormatError.self, "\(text)") { try upsert(text) }
            #expect(throws: ConfigFormatError.self, "\(text)") { try remove(text) }
        }
        #expect(throws: ConfigFormatError.self) { try TOMLConfigEditor.upsert(Data([0xFF, 0xFE]), name: "mac", command: "x", args: []) }
    }

    @Test func refusesEntriesWrittenInAFormItWontRewrite() {
        let inline = "[mcp_servers]\nmac = { command = \"x\" }\n"
        let dotted = "[mcp_servers]\nmac.command = \"x\"\n"
        let rootInline = "mcp_servers = { mac = { command = \"x\" } }\n"
        let rootDotted = "mcp_servers.mac.command = \"x\"\n"
        let arrayOfTables = "[[mcp_servers.mac]]\ncommand = \"x\"\n"
        let twice = "[mcp_servers.mac]\ncommand = \"x\"\n[mcp_servers.mac]\ncommand = \"y\"\n"
        for text in [inline, dotted, rootInline, rootDotted, arrayOfTables, twice] {
            #expect(throws: ConfigFormatError.self, "\(text)") { try upsert(text) }
            #expect(throws: ConfigFormatError.self, "\(text)") { try remove(text) }
        }
        // Another server written that way doesn't stop ours being added.
        #expect(throws: Never.self) { try upsert("[mcp_servers]\nother = { command = \"x\" }\n") }
        #expect(throws: ConfigFormatError.self) { try upsert("mcp_servers.other.command = \"x\"\n") }
    }

    @Test func errorsSayWhere() {
        do { _ = try upsert("a = 1\nb = 2\nc = nope\n"); Issue.record("should have thrown") }
        catch { #expect("\(error)".contains("line 3")) }
    }

    @Test func addingThenRemovingGivesBackTheFile() throws {
        let files = [
            "model = \"x\"\n",
            "model = \"x\"",
            "# only a comment\n",
            "[a]\nb = 1\n\n[c]\nd = \"\"\"\nmulti\n\n[mcp_servers.mac]\n\"\"\"\n",
            "[mcp_servers.one]\ncommand = \"1\"\n\n# note\n[mcp_servers.two]\ncommand = \"2\"\nargs = [\n  \"a\",\n]\n",
            "[[tools]]\nname = \"t\"\n[[tools]]\nname = \"u\"\n",
        ]
        for original in files {
            let added = try upsert(original)
            #expect(added.outcome == .added)
            let removed = try remove(added.text)
            #expect(removed.outcome == .removed)
            // A file without a final newline gains one when something is appended.
            #expect(removed.text == original || removed.text == original + "\n", "\(original.debugDescription) -> \(removed.text.debugDescription)")
        }
    }
}
