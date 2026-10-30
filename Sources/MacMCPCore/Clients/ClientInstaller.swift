import Foundation

/// Registers MacMCP with an AI client, or takes it out again: `mac-mcp install --client` and `uninstall --client`.
public enum ClientInstaller {
    public struct Request: Sendable {
        public var client: McpClient
        public var name: String
        /// What the client should run. Nil removes the entry.
        public var entry: ServerEntry?
        public var dryRun: Bool
        public var createFolder: Bool
        public var environment: ClientEnvironment

        public init(client: McpClient, name: String = "mac", entry: ServerEntry?, dryRun: Bool = false, createFolder: Bool = false,
                    environment: ClientEnvironment = .current) {
            self.client = client
            self.name = name
            self.entry = entry
            self.dryRun = dryRun
            self.createFolder = createFolder
            self.environment = environment
        }
    }

    public struct Report: Sendable {
        public var lines: [String]
        public var change: ClientChange
    }

    /// Runs a program and returns how it ended. The CLI supplies one that waits on the child; tests supply fakes.
    public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)

    public static func run(_ request: Request, runCommand: CommandRunner) throws -> Report {
        try ClientConfig.validate(name: request.name)
        if request.client == .claudeCode, let claude = locate("claude", path: request.environment.variables["PATH"]) {
            return try viaClaudeCLI(request, claude: claude, runCommand: runCommand)
        }
        return try editingFile(request)
    }

    // MARK: config files

    private static func editingFile(_ request: Request) throws -> Report {
        let client = request.client
        let plan = try ClientConfig.plan(client, name: request.name, entry: request.entry, environment: request.environment,
                                         createFolder: request.createFolder)
        let shown = display(plan.path, home: request.environment.home)
        var lines: [String] = []
        let removing = request.entry == nil
        switch plan.change {
        case .unchanged:
            lines.append(removing ? "\(client.displayName): \"\(request.name)\" isn't in \(shown); nothing to remove."
                : "\(client.displayName): \"\(request.name)\" is already set up in \(shown); nothing to change.")
        case .added, .replaced, .removed:
            let verb = plan.change == .added ? "add" : plan.change == .replaced ? "replace" : "remove"
            lines.append(request.dryRun ? "\(client.displayName): would \(verb) \"\(request.name)\" in \(shown). Nothing was written."
                : "\(client.displayName): \(verb == "add" ? "added" : verb == "replace" ? "replaced" : "removed") \"\(request.name)\" in \(shown).")
            if request.dryRun {
                lines.append("")
                lines.append(plan.diff)
                lines.append("")
            } else {
                if let backup = try ClientConfig.apply(plan) { lines.append("Backup of the original: \(display(backup, home: request.environment.home))") }
                if client == .claudeCode {
                    lines.append("Quit Claude Code sessions that are open first: one that saves its settings later can undo this edit.")
                }
            }
        }
        if !request.dryRun, plan.change == .added || plan.change == .replaced { lines.append(client.nextStep(name: request.name)) }
        return Report(lines: lines, change: plan.change)
    }

    // MARK: claude CLI

    private static func viaClaudeCLI(_ request: Request, claude: String, runCommand: CommandRunner) throws -> Report {
        let name = request.name
        let remove = ["mcp", "remove", "--scope", "user", name]
        guard let entry = request.entry else {
            var lines = ["Claude Code: `claude mcp remove --scope user \(name)`"]
            if request.dryRun { return Report(lines: ["Claude Code: would run `claude " + remove.joined(separator: " ") + "`. Nothing was changed."], change: .removed) }
            let result = runCommand(claude, remove)
            if result.status == 0 { lines.append(result.output); return Report(lines: lines.filter { !$0.isEmpty }, change: .removed) }
            if result.output.lowercased().contains("no mcp server found") {
                return Report(lines: ["Claude Code: \"\(name)\" isn't set up in your user config; nothing to remove."], change: .unchanged)
            }
            throw ClientConfigError("`claude mcp remove` failed: \(result.output)")
        }
        let add = ["mcp", "add", "--scope", "user", name, "--", entry.command] + entry.args
        let shownAdd = "claude " + add.map(shellQuote).joined(separator: " ")
        if request.dryRun {
            return Report(lines: ["Claude Code: would run `\(shownAdd)`.",
                                   "If \"\(name)\" is already in your user config, it is removed first (`claude \(remove.joined(separator: " "))`) and added again.",
                                   "Nothing was changed."], change: .added)
        }
        var result = runCommand(claude, add)
        var change = ClientChange.added
        if result.status != 0, result.output.lowercased().contains("already exists") {
            let removed = runCommand(claude, remove)
            guard removed.status == 0 else { throw ClientConfigError("`claude mcp remove` failed: \(removed.output)") }
            result = runCommand(claude, add)
            change = .replaced
        }
        guard result.status == 0 else { throw ClientConfigError("`claude mcp add` failed: \(result.output)") }
        return Report(lines: ["Claude Code: ran `\(shownAdd)`."] + (result.output.isEmpty ? [] : [result.output])
                      + [request.client.nextStep(name: name)], change: change)
    }

    // MARK: helpers

    /// The first executable file called `name` in a PATH-style list.
    public static func locate(_ name: String, path: String?) -> String? {
        for directory in (path ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = String(directory) + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.isExecutableFile(atPath: candidate), FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue { return candidate }
        }
        return nil
    }

    /// A path with the home folder written as `~`.
    public static func display(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// An argument as a shell would need it written, for showing a command.
    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: "^[A-Za-z0-9_@%+=:,./~-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
