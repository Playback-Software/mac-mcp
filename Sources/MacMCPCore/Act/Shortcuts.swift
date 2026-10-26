import Foundation

/// Runs the person's Shortcuts through `/usr/bin/shortcuts`, from the agent so they get its permissions and GUI
/// session. A shortcut is often the cheapest reliable route for a task the person already automated: one call
/// instead of a dozen clicks. Which shortcuts may run is the person's choice (`shortcuts.allowed` in the policy).
public enum Shortcuts {
    public struct Info: Sendable, Equatable {
        public let name: String
        public let identifier: String?
    }

    public struct RunResult: Sendable {
        public let output: String?
        public let status: Int32
        public let stderr: String
        public let timedOut: Bool
    }

    /// Runs the CLI: injectable so tests don't need real shortcuts.
    public typealias CLI = @Sendable (_ arguments: [String], _ timeout: TimeInterval) async throws -> Subprocess.Output

    public static let cli: CLI = { arguments, timeout in
        try await Subprocess.run("/usr/bin/shortcuts", arguments, timeout: timeout)
    }

    /// `shortcuts list --show-identifiers` lines: "Name (UUID)".
    static func parseList(_ text: String) -> [Info] {
        text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            if let m = line.firstMatch(of: /^(.*) \(([0-9A-Fa-f-]{36})\)$/) {
                return Info(name: String(m.1), identifier: String(m.2))
            }
            return Info(name: line, identifier: nil)
        }
    }

    public static func list(cli: CLI = cli) async throws -> [Info] {
        let out = try await cli(["list", "--show-identifiers"], 15)
        guard out.status == 0, !out.timedOut else {
            throw ActionError("Couldn't list shortcuts: \(out.timedOut ? "timed out" : out.stderr.isEmpty ? "exit \(out.status)" : out.stderr)")
        }
        return parseList(out.stdout)
    }

    /// The shortcut a query names: an identifier, else a name (case-insensitive, exact).
    public static func find(_ query: String, in all: [Info]) -> Info? {
        let q = query.lowercased()
        return all.first { $0.identifier?.lowercased() == q } ?? all.first { $0.name.lowercased() == q }
    }

    /// Runs a shortcut by identifier (or name), passing `input` as a text file and reading its result as plain text.
    public static func run(_ shortcut: Info, input: String?, timeout: TimeInterval, cli: CLI = cli) async throws -> RunResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-mcp-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var arguments = ["run", shortcut.identifier ?? shortcut.name]
        if let input {
            let inputFile = dir.appendingPathComponent("input.txt")
            try Data(input.utf8).write(to: inputFile)
            arguments += ["--input-path", inputFile.path]
        }
        let outputFile = dir.appendingPathComponent("output.txt")
        arguments += ["--output-path", outputFile.path, "--output-type", "public.plain-text"]
        let out = try await cli(arguments, timeout)
        let text = (try? String(contentsOf: outputFile, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
        return RunResult(output: text, status: out.status, stderr: out.stderr, timedOut: out.timedOut)
    }
}
