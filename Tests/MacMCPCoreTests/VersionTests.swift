import Foundation
import Testing

/// VERSION is the one place the version is set: scripts/build.sh reads it for the app bundle, and the CLI's
/// `cliVersion` (in a main.swift that tests can't import) is a literal that has to match.
@Suite struct VersionTests {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func cliVersionMatchesVersionFile() throws {
        let file = try String(contentsOf: repo.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(file.wholeMatch(of: /\d+\.\d+\.\d+/) != nil, "VERSION holds '\(file)', not a version like 0.1.1")
        let source = try String(contentsOf: repo.appendingPathComponent("Sources/mac-mcp/main.swift"), encoding: .utf8)
        let literal = source.firstMatch(of: /let cliVersion = "([^"]*)"/)?.1
        #expect(literal.map(String.init) == file, "cliVersion in Sources/mac-mcp/main.swift (\(literal ?? "not found")) differs from VERSION (\(file))")
    }
}
