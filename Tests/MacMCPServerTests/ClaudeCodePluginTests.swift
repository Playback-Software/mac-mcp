import Foundation
import Testing
@testable import MacMCPServer

/// The Claude Code plugin under integrations/claude-code ships with the repo: its manifests must parse, and its skill
/// may only name tools, parameters and choices the server really has.
@Suite struct ClaudeCodePluginTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(path) is not a JSON object")
    }

    /// Marketplace plugin entries as (name, plugin directory relative to the repo).
    func plugins() throws -> [(name: String, dir: String)] {
        let entries = try #require(try json(".claude-plugin/marketplace.json")["plugins"] as? [[String: Any]])
        return try entries.map { entry in
            let name = try #require(entry["name"] as? String)
            let source = try #require(entry["source"] as? String)
            #expect(source.hasPrefix("./") && !source.contains(".."), "\(name): source must be ./relative without ..")
            return (name, String(source.dropFirst(2)))
        }
    }

    /// Every Markdown file in the plugin's skills.
    func skillFiles(_ dir: String) throws -> [URL] {
        let skills = Self.root.appendingPathComponent(dir).appendingPathComponent("skills")
        let files = FileManager.default.enumerator(at: skills, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        return files.sorted { $0.path < $1.path }
    }

    @Test func marketplaceManifestParses() throws {
        let market = try json(".claude-plugin/marketplace.json")
        #expect((market["name"] as? String)?.isEmpty == false)
        #expect(((market["owner"] as? [String: Any])?["name"] as? String)?.isEmpty == false)
        #expect(try !plugins().isEmpty)
    }

    @Test func pluginManifestsParseAndMatchTheMarketplace() throws {
        for plugin in try plugins() {
            let manifest = try json(plugin.dir + "/.claude-plugin/plugin.json")
            #expect(manifest["name"] as? String == plugin.name)
            let servers = try #require(manifest["mcpServers"] as? [String: [String: Any]], "\(plugin.name): mcpServers")
            for (name, server) in servers {
                let command = try #require(server["command"] as? String, "\(name): command")
                // Claude Code expands ${VAR} in a server's command but documents no ~ expansion.
                #expect(!command.hasPrefix("~"), "\(name): use ${HOME}, not ~")
                #expect(!command.contains("/Users/"), "\(name): no personal paths")
            }
        }
    }

    @Test func skillsHaveFrontmatter() throws {
        for plugin in try plugins() {
            let skills = try skillFiles(plugin.dir).filter { $0.lastPathComponent == "SKILL.md" }
            #expect(!skills.isEmpty, "\(plugin.name) has no skills")
            for file in skills {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                let end = try #require(lines.dropFirst().firstIndex(of: "---"), "\(file.path): no frontmatter")
                #expect(lines.first == "---")
                var fields: [String: String] = [:]
                for line in lines[1..<end] {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                #expect(fields["name"] == file.deletingLastPathComponent().lastPathComponent)
                let description = try #require(fields["description"])
                // Claude Code truncates longer descriptions in its skill listing.
                #expect(!description.isEmpty && description.count <= 1536)
            }
        }
    }

    /// Code spans in the skills (`mac_type ref=e1 text="Ada"`): tool names, then key=value arguments.
    @Test func skillsNameRealToolsAndParameters() throws {
        let schemas = Dictionary(uniqueKeysWithValues: MacMCPServer.tools.map {
            ($0.tool.name, $0.tool.inputSchema["properties"]?.objectValue ?? [:])
        })
        func choices(_ property: Value?) -> Set<String>? {
            property?["enum"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
        }
        let anyTool = /\b(?:mac|web)_[a-z]+\b/
        let argument = /(?:^|[^\w.])([a-z_]+)=([a-z]+\b)?/
        var checked = 0
        for plugin in try plugins() {
            for file in try skillFiles(plugin.dir) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let name = file.lastPathComponent
                for match in text.matches(of: anyTool) {
                    #expect(schemas[String(match.output)] != nil, "\(name): no tool \(match.output)")
                }
                let spans = text.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                for span in spans {
                    // Arguments belong to the tool named before them in the span; spans without one (`query=`) are
                    // checked against every tool.
                    var tool: String?
                    var rest = Substring(span)
                    while !rest.isEmpty {
                        let next = rest.firstMatch(of: anyTool)
                        let segment = next.map { rest[..<$0.range.lowerBound] } ?? rest
                        for arg in segment.matches(of: argument) {
                            let key = String(arg.output.1), value = arg.output.2.map(String.init)
                            let candidates = tool.map { [$0] } ?? schemas.keys.filter { schemas[$0]?[key] != nil }
                            #expect(!candidates.isEmpty && candidates.allSatisfy { schemas[$0]?[key] != nil },
                                    "\(name): `\(span)`: \(tool.map { "\($0) has no" } ?? "no tool has a") parameter \(key)")
                            if let value {
                                let allowed = candidates.compactMap { choices(schemas[$0]?[key]) }
                                if !allowed.isEmpty {
                                    #expect(allowed.contains { $0.contains(value) }, "\(name): `\(span)`: \(key)=\(value) is not a choice")
                                }
                            }
                            checked += 1
                        }
                        guard let next else { break }
                        tool = String(next.output)
                        rest = rest[next.range.upperBound...]
                    }
                }
            }
        }
        #expect(checked > 20, "the skill's examples should use real arguments")
    }
}
