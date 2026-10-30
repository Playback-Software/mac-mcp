import Foundation
import Testing
@testable import MacMCPCore

/// Config editing on fixture text. Nothing here reads or writes a real client's config.
@Suite struct ClientConfigEditorTests {
    let entry = ConfigValue.object([("type", .string("stdio")), ("command", .string("/opt/mac/bin/mac-mcp")), ("args", .array([]))])

    func data(_ s: String) -> Data { Data(s.utf8) }
    func string(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    func upsert(_ s: String?, jsonc: Bool = false, container: String = "mcpServers", name: String = "mac") throws -> (text: String, outcome: ClientChange) {
        let r = try JSONConfigEditor.upsert(s.map(data), jsonc: jsonc, container: container, name: name, entry: entry)
        return (string(r.data), r.outcome)
    }

    func remove(_ s: String, jsonc: Bool = false, container: String = "mcpServers", name: String = "mac") throws -> (text: String, outcome: ClientChange) {
        let r = try JSONConfigEditor.remove(data(s), jsonc: jsonc, container: container, name: name)
        return (string(r.data), r.outcome)
    }

    /// The result must still be strict JSON, with `mac` in `container`.
    func servers(_ text: String, container: String = "mcpServers") throws -> [String: Any] {
        let object = try #require(try JSONSerialization.jsonObject(with: data(text)) as? [String: Any])
        return try #require(object[container] as? [String: Any])
    }

    // MARK: JSON, adding

    @Test func createsAFileWhenThereIsNone() throws {
        for input in [nil, "", "  \n"] {
            let r = try upsert(input)
            #expect(r.outcome == .added)
            #expect(r.text == """
                {
                  "mcpServers": {
                    "mac": {
                      "type": "stdio",
                      "command": "/opt/mac/bin/mac-mcp",
                      "args": []
                    }
                  }
                }

                """)
        }
    }

    @Test func addsAnEntryAndLeavesEveryOtherByteAlone() throws {
        let original = """
            {
              "theme":   "dark",
              "numbers": [1, 2.5e3, -0],
              "mcpServers": {
                "other": { "command": "x",   "args": ["a"] }
              },
              "zzz": null
            }

            """
        let r = try upsert(original)
        #expect(r.outcome == .added)
        let added = """
            ,
                "mac": {
                  "type": "stdio",
                  "command": "/opt/mac/bin/mac-mcp",
                  "args": []
                }
            """
        let expected = original.replacingOccurrences(of: "\"args\": [\"a\"] }\n", with: "\"args\": [\"a\"] }" + added + "\n")
        #expect(r.text == expected)
        let found = try servers(r.text)
        #expect(Set(found.keys) == ["other", "mac"])
    }

    @Test func addsTheContainerWhenTheFileHasNone() throws {
        let original = "{\n    \"theme\": \"dark\"\n}\n"
        let r = try upsert(original)
        #expect(r.text.hasPrefix("{\n    \"theme\": \"dark\",\n    \"mcpServers\": {\n        \"mac\": {\n"))
        #expect(r.text.hasSuffix("\n    }\n}\n"))
        _ = try servers(r.text)
    }

    @Test func fillsAnEmptyContainerAndAnEmptyFile() throws {
        let r = try upsert("{\n  \"mcpServers\": {}\n}\n")
        #expect(try servers(r.text).keys.sorted() == ["mac"])
        #expect(r.text.contains("\"mcpServers\": {\n    \"mac\": {"))
        let empty = try upsert("{}\n")
        #expect(empty.text.hasPrefix("{\n  \"mcpServers\": {\n    \"mac\""))
        _ = try servers(empty.text)
    }

    @Test func followsTabsAndWindowsLineEndings() throws {
        let tabs = try upsert("{\n\t\"mcpServers\": {\n\t\t\"other\": {}\n\t}\n}\n")
        #expect(tabs.text.contains(",\n\t\t\"mac\": {\n\t\t\t\"type\": \"stdio\""))
        let crlf = try upsert("{\r\n  \"mcpServers\": {\r\n    \"other\": {}\r\n  }\r\n}\r\n")
        #expect(crlf.text.contains(",\r\n    \"mac\": {\r\n"))
        #expect(!crlf.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func aSingleLineFileStaysOnOneLine() throws {
        let r = try upsert("{\"mcpServers\":{\"other\":{\"command\":\"x\"}}}")
        #expect(r.text == "{\"mcpServers\":{\"other\":{\"command\":\"x\"}, \"mac\": {\"type\": \"stdio\", \"command\": \"/opt/mac/bin/mac-mcp\", \"args\": []}}}")
        _ = try servers(r.text)
        let top = try upsert("{\"a\": 1}")
        _ = try servers(top.text)
        #expect(!top.text.contains("\n"))
    }

    // MARK: JSON, replacing and removing

    @Test func replacesOnlyTheNamedEntry() throws {
        let original = """
            {
              "mcpServers": {
                "before": { "command": "b" },
                "mac": {   "command": "old",
                  "args": ["--legacy"], "env": {"A": "1"} },
                "after": { "command": "a" }
              }
            }
            """
        let r = try upsert(original)
        #expect(r.outcome == .replaced)
        let prefix = original.components(separatedBy: "\"mac\": ")[0] + "\"mac\": "
        let suffix = "\n    \"after\"" + original.components(separatedBy: "\n    \"after\"")[1]
        #expect(r.text.hasPrefix(prefix) && r.text.hasSuffix(suffix.replacingOccurrences(of: "\n    \"after\"", with: ",\n    \"after\"").replacingOccurrences(of: ",\n,\n", with: ",\n")))
        let found = try servers(r.text)
        #expect((found["mac"] as? [String: Any])?["command"] as? String == "/opt/mac/bin/mac-mcp")
        #expect((found["mac"] as? [String: Any])?["env"] == nil)
        #expect(Set(found.keys) == ["before", "mac", "after"])
    }

    @Test func settingTheSameEntryAgainChangesNothing() throws {
        let first = try upsert("{\"theme\": 1}\n")
        let second = try upsert(first.text)
        #expect(second.outcome == .unchanged && second.text == first.text)
    }

    @Test func removesEachPositionAndKeepsTheJSONValid() throws {
        let body = { (members: [String]) in "{\n  \"keep\": 1,\n  \"mcpServers\": {\n" + members.joined(separator: ",\n") + "\n  }\n}\n" }
        let mac = "    \"mac\": {\n      \"command\": \"c\"\n    }"
        let a = "    \"a\": { \"command\": \"a\" }"
        let b = "    \"b\": { \"command\": \"b\" }"
        for (members, left) in [([mac, a, b], [a, b]), ([a, mac, b], [a, b]), ([a, b, mac], [a, b]), ([a, mac], [a]), ([mac, a], [a])] {
            let r = try remove(body(members))
            #expect(r.outcome == .removed)
            #expect(r.text == body(left), "removing from \(members.count)")
            _ = try servers(r.text)
        }
        let only = try remove(body([mac]))
        #expect(only.text == "{\n  \"keep\": 1,\n  \"mcpServers\": {\n  }\n}\n")
        #expect(try servers(only.text).isEmpty)
    }

    @Test func removesFromOneLineObjects() throws {
        #expect(try remove("{\"mcpServers\": {\"a\": 1, \"mac\": 2, \"b\": 3}}").text == "{\"mcpServers\": {\"a\": 1, \"b\": 3}}")
        #expect(try remove("{\"mcpServers\": {\"a\": 1, \"mac\": 2}}").text == "{\"mcpServers\": {\"a\": 1}}")
        #expect(try remove("{\"mcpServers\": {\"mac\": 2}}").text == "{\"mcpServers\": {}}")
    }

    @Test func removingWhatIsntThereChangesNothing() throws {
        for text in ["{}\n", "{\"mcpServers\": {\"a\": 1}}", "{\"servers\": {\"mac\": {}}}", "  "] {
            let r = try remove(text)
            #expect(r.outcome == .unchanged && r.text == text)
        }
    }

    // MARK: JSONC

    @Test func vsCodeFilesKeepTheirCommentsAndTrailingCommas() throws {
        let original = """
            // MCP servers
            {
              /* user servers */
              "servers": {
                // a note about other
                "other": { "command": "x", }, // trailing
              },
              "inputs": [],
            }
            """
        let added = try upsert(original, jsonc: true, container: "servers")
        #expect(added.outcome == .added)
        #expect(added.text.hasPrefix("// MCP servers\n{\n  /* user servers */\n  \"servers\": {\n    // a note about other\n    \"other\": { \"command\": \"x\", }"))
        #expect(added.text.hasSuffix("\n  },\n  \"inputs\": [],\n}"))
        #expect(added.text.contains("\"mac\": {\n      \"type\": \"stdio\""))
        // The edit can be taken out again, leaving the original file.
        let removed = try remove(added.text, jsonc: true, container: "servers")
        #expect(removed.outcome == .removed)
        let again = try remove(removed.text, jsonc: true, container: "servers")
        #expect(again.outcome == .unchanged)
        #expect(removed.text.contains("// a note about other") && removed.text.contains("\"other\": { \"command\": \"x\", }, // trailing"))
        #expect(removed.text.hasSuffix("\n  },\n  \"inputs\": [],\n}"))
    }

    @Test func removingAnEntryKeepsTheCommentOnTheNextOne() throws {
        let original = """
            {
              "servers": {
                "mac": { "command": "c" }, // mine
                // about b
                "b": { "command": "b" }
              }
            }
            """
        let r = try remove(original, jsonc: true, container: "servers")
        #expect(r.text == "{\n  \"servers\": {\n    // about b\n    \"b\": { \"command\": \"b\" }\n  }\n}")
    }

    @Test func plainJSONFilesMayNotHaveCommentsOrTrailingCommas() {
        #expect(throws: ConfigFormatError.self) { try upsert("{\n // no\n \"a\": 1\n}") }
        #expect(throws: ConfigFormatError.self) { try upsert("{\"a\": 1,}") }
        #expect(throws: ConfigFormatError.self) { try upsert("{\"a\": [1,]}") }
    }

    // MARK: JSON, refusing

    @Test func refusesFilesThatDontParse() {
        let bad = ["{", "{\"a\": }", "{\"a\": 1 \"b\": 2}", "[]", "\"x\"", "{\"a\": 01}", "{\"a\": \"x\ny\"}", "{\"a\": tru}", "{\"a\": 1} extra",
                   "{'a': 1}", "{\"a\": \"\\q\"}", "{\"a\": 1.}", "{\"mcpServers\": {\"mac\": {]}}", "{\"a\": \"unterminated}", "not json", "\u{1}"]
        for text in bad {
            #expect(throws: ConfigFormatError.self, "\(text)") { try upsert(text) }
            #expect(throws: ConfigFormatError.self, "\(text)") { try remove(text) }
        }
        #expect(throws: ConfigFormatError.self) { try JSONConfigEditor.upsert(Data([0xFF, 0xFE]), jsonc: false, container: "mcpServers", name: "mac", entry: entry) }
    }

    @Test func refusesAmbiguousOrWronglyShapedContainers() {
        #expect(throws: ConfigFormatError.self) { try upsert("{\"mcpServers\": []}") }
        #expect(throws: ConfigFormatError.self) { try upsert("{\"mcpServers\": null}") }
        #expect(throws: ConfigFormatError.self) { try upsert("{\"mcpServers\": {}, \"mcpServers\": {}}") }
        #expect(throws: ConfigFormatError.self) { try upsert("{\"mcpServers\": {\"mac\": {}, \"mac\": {}}}") }
        #expect(throws: ConfigFormatError.self) { try remove("{\"mcpServers\": {\"mac\": {}, \"mac\": {}}}") }
    }

    @Test func errorsSayWhere() throws {
        do { _ = try upsert("{\n  \"a\": 1,\n  \"b\": oops\n}"); Issue.record("should have thrown") }
        catch { #expect("\(error)".contains("line 3")) }
    }

    @Test func readsKeysAndStringsWithEscapes() throws {
        let original = "{\"mcpServers\": {\"m\\u0061c\": {\"command\": \"old \\\"quoted\\\" \\ud83d\\ude00\"}, \"x\\/y\": 1}}"
        let r = try upsert(original)
        #expect(r.outcome == .replaced)
        #expect(r.text.hasSuffix(", \"x\\/y\": 1}}"))
    }

    @Test func deeplyNestedValuesAreRefusedNotCrashedOn() {
        let deep = "{\"a\": " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000) + "}"
        #expect(throws: ConfigFormatError.self) { try upsert(deep) }
    }

    @Test func readsBackWhatItWrote() throws {
        let r = try upsert("{\"mcpServers\": {}}")
        let found = try JSONConfigEditor.entry(in: data(r.text), jsonc: false, container: "mcpServers", name: "mac") as? [String: Any]
        #expect(found?["command"] as? String == "/opt/mac/bin/mac-mcp")
        #expect(try JSONConfigEditor.entry(in: data(r.text), jsonc: false, container: "mcpServers", name: "nope") == nil)
    }

    // MARK: round trips

    /// A deterministic spread of layouts: indent, line endings, entry counts, neighbours, one-line files.
    @Test func addingThenRemovingGivesBackTheFileAcrossManyLayouts() throws {
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for round in 0..<300 {
            let indent = ["  ", "    ", "\t"][next(3)]
            let newline = next(4) == 0 ? "\r\n" : "\n"
            let multiline = next(5) != 0
            let count = 1 + next(4)
            let spots = ["a", "b", "c", "d"].prefix(count).map { "\"\($0)\": {\"command\": \"\($0)\", \"args\": [\"x\", 1, null, {\"k\": [true]}]}" }
            let before = next(2) == 0 ? ["\"first\": [1, 2.5e-3, \"é\\u00e9\"]"] : []
            let after = next(2) == 0 ? ["\"last\": {\"deep\": {\"deeper\": []}}"] : []
            func object(_ members: [String], depth: Int) -> String {
                guard multiline else { return "{" + members.joined(separator: ", ") + "}" }
                let inner = String(repeating: indent, count: depth + 1)
                return "{" + newline + members.map { inner + $0 }.joined(separator: "," + newline) + newline + String(repeating: indent, count: depth) + "}"
            }
            let container = "\"mcpServers\": " + object(Array(spots), depth: 1)
            let original = object(before + [container] + after, depth: 0) + (next(2) == 0 ? newline : "")
            let added = try upsert(original)
            let reparsed = try #require(try JSONSerialization.jsonObject(with: data(added.text)) as? [String: Any], "round \(round)")
            let originalObject = try #require(try JSONSerialization.jsonObject(with: data(original)) as? [String: Any])
            var expected = originalObject
            var servers = try #require(originalObject["mcpServers"] as? [String: Any])
            servers["mac"] = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: entry.foundation))
            expected["mcpServers"] = servers
            #expect(NSDictionary(dictionary: reparsed).isEqual(to: expected), "round \(round): \(added.text)")
            let removed = try remove(added.text)
            #expect(removed.text == original, "round \(round): \(added.text)")
        }
    }

    @Test func removalLeavesValidJSONWhateverTheLayout() throws {
        for text in ["{\"mcpServers\":{\"mac\":{}}}", "{\n\"mcpServers\":{\n\"mac\":{}\n}\n}", "{\"mcpServers\": {\"mac\": 1,\n \"b\": 2}}",
                     "{\"mcpServers\": {\"a\": 1,\n \"mac\": 2}, \"z\": 3}", "{\"mcpServers\": {\"mac\": [1,\n2]}}"] {
            let r = try remove(text)
            #expect(r.outcome == .removed)
            #expect((try servers(r.text)["mac"]) == nil, "\(text)")
        }
    }
}
