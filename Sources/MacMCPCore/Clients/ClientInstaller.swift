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

    /// What to tell a person before a real run: clients don't lock their configs, so one that is open can save its own
    /// copy over this edit.
    public static func quitAdvice(for client: McpClient) -> String {
        "Quit \(client.displayName) first if it is open: clients don't lock their configs, so one that saves its settings later can undo this change."
    }

    /// `notify` is told things a person needs at once, before the step that could fail (where a saved copy is, say).
    public static func run(_ request: Request, runCommand: CommandRunner, notify: @Sendable (String) -> Void = { _ in }) throws -> Report {
        try ClientConfig.validate(name: request.name)
        let path = request.environment.variables["PATH"]
        if request.client == .claudeCode, let claude = locate("claude", path: path) {
            return try viaClaudeCLI(request, claude: claude, runCommand: runCommand, notify: notify)
        }
        if request.client == .codex, let codex = locate("codex", path: path), let report = try viaCodexCLI(request, codex: codex, runCommand: runCommand) {
            return report
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
                lines.append(quitAdvice(for: client))
            } else if let backup = try ClientConfig.apply(plan) {
                lines.append("Backup of the original: \(display(backup, home: request.environment.home))")
            }
        }
        if !request.dryRun, plan.change == .added || plan.change == .replaced { lines.append(client.nextStep(name: request.name)) }
        return Report(lines: lines, change: plan.change)
    }

    // MARK: claude CLI

    private static func viaClaudeCLI(_ request: Request, claude: String, runCommand: CommandRunner, notify: @Sendable (String) -> Void) throws -> Report {
        let name = request.name
        let remove = ["mcp", "remove", "--scope", "user", "--", name]
        guard let entry = request.entry else {
            var lines = ["Claude Code: `claude mcp remove --scope user -- \(name)`"]
            if request.dryRun { return Report(lines: ["Claude Code: would run `claude " + remove.joined(separator: " ") + "`. Nothing was changed.", quitAdvice(for: .claudeCode)], change: .removed) }
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
                                   "If \"\(name)\" is already in your user config, its entry is saved to MacMCP's backup folder, removed (`claude \(remove.map(shellQuote).joined(separator: " "))`) and added again; "
                                   + "if the add fails, the saved entry is put back with `claude mcp add-json`.",
                                   "Nothing was changed.", quitAdvice(for: .claudeCode)], change: .added)
        }
        var result = runCommand(claude, add)
        guard result.status != 0, result.output.lowercased().contains("already exists") else {
            guard result.status == 0 else { throw ClientConfigError("`claude mcp add` failed: \(result.output)") }
            return Report(lines: ["Claude Code: ran `\(shownAdd)`."] + (result.output.isEmpty ? [] : [result.output]) + [request.client.nextStep(name: name)], change: .added)
        }

        // The name is taken. Replacing means remove, then add; keep the old entry so a failed add can't lose it.
        let previous = try existingClaudeEntry(request)
        let saved = try ClientBackups.write(previous.json, client: .claudeCode, label: "server-\(name).json", home: request.environment.home, now: Date())
        let recovery = restoreCommand(name: name, savedAt: saved.path)
        notify("Claude Code: the current \"\(name)\" entry is saved at \(saved.path). If this is interrupted, put it back with:\n  \(recovery)")
        let removed = runCommand(claude, remove)
        guard removed.status == 0 else { throw ClientConfigError("`claude mcp remove` failed: \(removed.output). The existing entry is unchanged.") }
        result = runCommand(claude, add)
        if result.status == 0 {
            return Report(lines: ["Claude Code: ran `\(shownAdd)`."] + (result.output.isEmpty ? [] : [result.output])
                          + ["The replaced entry is saved at \(display(saved.path, home: request.environment.home))."] + [request.client.nextStep(name: name)], change: .replaced)
        }
        let restore = runCommand(claude, ["mcp", "add-json", "--scope", "user", "--", name, previous.text])
        let back = restore.status == 0 && claudeEntry(request, name: name).map { $0.json == previous.json } == true
        if back { throw ClientConfigError("`claude mcp add` failed: \(result.output). The previous \"\(name)\" entry was put back and checked.") }
        throw ClientConfigError("`claude mcp add` failed: \(result.output). The previous \"\(name)\" entry could NOT be put back"
                                + (restore.status == 0 ? " (it didn't read back the same)" : " (`claude mcp add-json` failed: \(restore.output))")
                                + ". It is saved at \(saved.path). Put it back with:\n  \(recovery)")
    }

    /// What a person types to restore an entry saved by `ClientBackups.write` (the JSON isn't printed: it may hold secrets).
    private static func restoreCommand(name: String, savedAt path: String) -> String {
        "claude mcp add-json --scope user -- \(shellQuote(name)) \"$(cat \(shellQuote(path)))\""
    }

    /// The user-scope entry `claude mcp add` found, read from Claude Code's config file as JSON.
    private static func existingClaudeEntry(_ request: Request) throws -> (json: Data, text: String) {
        guard let found = claudeEntry(request, name: request.name) else {
            throw ClientConfigError("\"\(request.name)\" already exists, but its entry can't be read from \(display(McpClient.claudeCode.configPath(in: request.environment), home: request.environment.home)) "
                + "to keep a copy, so mac-mcp did not remove it. Remove it yourself (`claude mcp remove --scope user -- \(request.name)`) and run this again.")
        }
        return (found.json, String(decoding: found.json, as: UTF8.self))
    }

    private static func claudeEntry(_ request: Request, name: String) -> (json: Data, object: Any)? {
        guard let data = FileManager.default.contents(atPath: McpClient.claudeCode.configPath(in: request.environment)),
              let object = try? JSONConfigEditor.entry(in: data, jsonc: false, container: "mcpServers", name: name), JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return (json, object)
    }

    // MARK: codex CLI

    /// With `codex` on PATH, a new entry is added and an existing one removed with `codex mcp add` and `remove`.
    /// Replacing an entry that exists edits the file instead (nil here): that path keeps a checked backup and rollback.
    private static func viaCodexCLI(_ request: Request, codex: String, runCommand: CommandRunner) throws -> Report? {
        let name = request.name
        let path = McpClient.codex.configPath(in: request.environment)
        let existing: Data?
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path) else { throw ClientConfigError("cannot read \(path)") }
            existing = data
        } else { existing = nil }
        // The file is checked first, with the same rules as when it is edited by hand: a malformed one stops here.
        let present: Bool, found: ServerEntry?
        do {
            present = try existing.map { try TOMLConfigEditor.contains($0, name: name) } ?? false
            found = try existing.flatMap { try ClientConfig.registered(.codex, name: name, in: $0) }
        } catch let error as ConfigFormatError {
            throw ClientConfigError("\(error.description). Nothing was changed.")
        }
        guard let entry = request.entry else {
            guard present else { return Report(lines: ["Codex: \"\(name)\" isn't in \(display(path, home: request.environment.home)); nothing to remove."], change: .unchanged) }
            let remove = ["mcp", "remove", "--", name]
            if request.dryRun { return Report(lines: ["Codex: would run `codex \(remove.joined(separator: " "))`. Nothing was changed.", quitAdvice(for: .codex)], change: .removed) }
            let result = runCommand(codex, remove)
            guard result.status == 0 else { throw ClientConfigError("`codex mcp remove` failed: \(result.output)") }
            return Report(lines: ["Codex: ran `codex \(remove.joined(separator: " "))`."] + (result.output.isEmpty ? [] : [result.output]), change: .removed)
        }
        if found == entry { return Report(lines: ["Codex: \"\(name)\" is already set up in \(display(path, home: request.environment.home)); nothing to change."], change: .unchanged) }
        if present { return nil }
        let add = ["mcp", "add", name, "--", entry.command] + entry.args
        let shown = "codex " + add.map(shellQuote).joined(separator: " ")
        if request.dryRun { return Report(lines: ["Codex: would run `\(shown)`. Nothing was changed.", quitAdvice(for: .codex)], change: .added) }
        let result = runCommand(codex, add)
        guard result.status == 0 else { throw ClientConfigError("`codex mcp add` failed: \(result.output)") }
        var lines = ["Codex: ran `\(shown)`."] + (result.output.isEmpty ? [] : [result.output])
        let after = FileManager.default.contents(atPath: path).flatMap { try? ClientConfig.registered(.codex, name: name, in: $0) }
        if after != entry { lines.append("note: could not confirm the entry in \(display(path, home: request.environment.home)); check with `codex mcp list`.") }
        return Report(lines: lines + [McpClient.codex.nextStep(name: name)], change: .added)
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
