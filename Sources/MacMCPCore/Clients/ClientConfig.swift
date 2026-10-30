import Foundation

/// What registering (or unregistering) MacMCP changed in a client.
public enum ClientChange: Sendable, Equatable { case added, replaced, removed, unchanged }

/// The AI clients `mac-mcp install --client` can register MacMCP with.
public enum McpClient: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codex
    case cursor
    case vscode

    public init?(argument: String) {
        self.init(rawValue: argument.lowercased().replacingOccurrences(of: "_", with: "-"))
    }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        }
    }

    /// The user-level config file. Claude Code's lives in `$CLAUDE_CONFIG_DIR` when that's set, Codex's in `$CODEX_HOME`.
    public func configPath(in environment: ClientEnvironment) -> String {
        let home = environment.home
        switch self {
        case .claudeCode: return (environment.variables["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home) + "/.claude.json"
        case .claudeDesktop: return home + "/Library/Application Support/Claude/claude_desktop_config.json"
        case .codex: return (environment.variables["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex") + "/config.toml"
        case .cursor: return home + "/.cursor/mcp.json"
        case .vscode: return home + "/Library/Application Support/Code/User/mcp.json"
        }
    }

    /// Where the file keeps its servers, and whether it's JSONC (VS Code's mcp.json allows comments).
    var jsonLayout: (container: String, jsonc: Bool, typed: Bool)? {
        switch self {
        case .claudeCode: return ("mcpServers", false, true)
        case .claudeDesktop, .cursor: return ("mcpServers", false, false)
        case .vscode: return ("servers", true, true)
        case .codex: return nil
        }
    }

    /// What to do once it's registered.
    public func nextStep(name: String) -> String {
        switch self {
        case .claudeCode: return "Start a new Claude Code session; /mcp should list \"\(name)\" as connected."
        case .claudeDesktop: return "Quit and reopen Claude Desktop to load it."
        case .codex: return "Start a new Codex session; `codex mcp list` should show \"\(name)\"."
        case .cursor: return "Restart Cursor, or switch the server on in its MCP settings."
        case .vscode: return "In VS Code, run \"MCP: List Servers\" and start \"\(name)\"; it asks you to trust it the first time."
        }
    }
}

/// The parts of the process environment that decide where client configs live.
public struct ClientEnvironment: Sendable {
    public var home: String
    public var variables: [String: String]

    public init(home: String, variables: [String: String] = [:]) {
        self.home = home
        self.variables = variables
    }

    public static var current: ClientEnvironment { .init(home: Paths.home, variables: ProcessInfo.processInfo.environment) }
}

/// The command a client runs to talk to MacMCP.
public struct ServerEntry: Sendable, Equatable {
    public let command: String
    public let args: [String]

    public init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }

    /// The relay on this Mac.
    public static func local(cli: String = Paths.cli) -> ServerEntry { .init(command: cli) }

    /// Where `scripts/build.sh` installs the relay, as the remote shell reads it.
    public static let remoteCLI = "~/.local/bin/mac-mcp"

    /// The relay on another Mac over SSH, as `mac-mcp remote-setup` suggests. `target` is `user@host` or an SSH alias.
    public static func remote(_ target: String, cli: String = remoteCLI) throws -> ServerEntry {
        let pattern = "^([A-Za-z0-9._+-]+@)?[A-Za-z0-9._:%-]+$"
        guard target.range(of: pattern, options: .regularExpression) != nil, !target.hasPrefix("-"), target.count <= 255 else {
            throw ClientConfigError("`\(target)` isn't a user@host to SSH to")
        }
        return .init(command: "ssh", args: ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", target, cli])
    }

    var value: ConfigValue {
        .object([("command", .string(command)), ("args", .array(args.map { .string($0) }))])
    }
}

public struct ClientConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Reads and edits one client's config file.
public enum ClientConfig {
    /// Server names the clients accept everywhere.
    public static func validate(name: String) throws {
        guard name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ClientConfigError("`\(name)` isn't a usable server name: use letters, digits, - and _ (up to 64)")
        }
    }

    /// `data` after adding `entry` (or, with nil, removing the entry) for `name`. Pure: no files are touched.
    static func edit(_ client: McpClient, name: String, entry: ServerEntry?, original: Data?) throws -> (data: Data, change: ClientChange) {
        do {
            if let layout = client.jsonLayout {
                if let entry {
                    var fields: [(key: String, value: ConfigValue)] = layout.typed ? [("type", .string("stdio"))] : []
                    if case let .object(pairs) = entry.value { fields += pairs }
                    let r = try JSONConfigEditor.upsert(original, jsonc: layout.jsonc, container: layout.container, name: name, entry: .object(fields))
                    return (r.data, r.outcome)
                }
                let r = try JSONConfigEditor.remove(original, jsonc: layout.jsonc, container: layout.container, name: name)
                return (r.data, r.outcome)
            }
            if let entry {
                let r = try TOMLConfigEditor.upsert(original, name: name, command: entry.command, args: entry.args)
                return (r.data, r.outcome)
            }
            let r = try TOMLConfigEditor.remove(original, name: name)
            return (r.data, r.outcome)
        } catch let error as ConfigFormatError {
            throw ClientConfigError("\(error.description). Nothing was changed.")
        }
    }

    /// The entry a config file holds for `name`, or nil. Used to check a write.
    static func registered(_ client: McpClient, name: String, in data: Data) throws -> ServerEntry? {
        if let layout = client.jsonLayout {
            guard let object = try JSONConfigEditor.entry(in: data, jsonc: layout.jsonc, container: layout.container, name: name) as? [String: Any],
                  let command = object["command"] as? String else { return nil }
            return ServerEntry(command: command, args: object["args"] as? [String] ?? [])
        }
        return try TOMLConfigEditor.entry(in: data, name: name).map { ServerEntry(command: $0.command, args: $0.args) }
    }
}

// MARK: - plan and apply

/// An edit to a client's config file, worked out but not yet written.
public struct ClientPlan: Sendable {
    public let client: McpClient
    public let name: String
    /// The file to write, with symlinks resolved.
    public let path: String
    public let change: ClientChange
    public let original: Data?
    public let updated: Data
    let entry: ServerEntry?
    let createFolder: Bool

    /// The lines that change, with a little context.
    public var diff: String { LineDiff.render(old: original.map { String(decoding: $0, as: UTF8.self) } ?? "", new: String(decoding: updated, as: UTF8.self)) }
}

extension ClientConfig {
    /// Reads the client's config and works out the edit. Never writes. `createFolder` allows making the folder a new
    /// file would go in; otherwise a missing folder means the client isn't installed, and that's an error.
    public static func plan(_ client: McpClient, name: String, entry: ServerEntry?, environment: ClientEnvironment,
                            createFolder: Bool = false) throws -> ClientPlan {
        try validate(name: name)
        let path = URL(fileURLWithPath: client.configPath(in: environment)).resolvingSymlinksInPath().path
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        var original: Data?
        if fm.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw ClientConfigError("\(path) is a folder, not a file") }
            guard let data = fm.contents(atPath: path) else { throw ClientConfigError("cannot read \(path)") }
            original = data
        } else if entry != nil {
            let folder = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: folder), !createFolder {
                throw ClientConfigError("\(folder) doesn't exist, so \(client.displayName) may not be installed. "
                    + "Run it once, or pass --create to make the folder and the file anyway.")
            }
        }
        if original == nil, entry == nil { return ClientPlan(client: client, name: name, path: path, change: .unchanged, original: nil, updated: Data(), entry: nil, createFolder: false) }
        let edited = try edit(client, name: name, entry: entry, original: original)
        return ClientPlan(client: client, name: name, path: path, change: edited.change, original: original, updated: edited.data,
                          entry: entry, createFolder: createFolder)
    }

    /// Writes a plan: copies the original aside first, replaces the file in one step, then reads it back and puts the
    /// original back if the result isn't what the plan said. Returns the backup's path, if there was a file to back up.
    @discardableResult
    public static func apply(_ plan: ClientPlan, now: Date = Date()) throws -> String? {
        guard plan.change != .unchanged else { return nil }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: plan.path)
        let current = fm.contents(atPath: plan.path)
        guard current == plan.original else {
            throw ClientConfigError("\(plan.path) changed while mac-mcp was working on it; nothing was written. Run the command again.")
        }
        let attributes = try? fm.attributesOfItem(atPath: plan.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        var backup: String?
        if let original = plan.original {
            let path = backupPath(for: plan.path, now: now)
            guard fm.createFile(atPath: path, contents: original, attributes: [.posixPermissions: permissions]),
                  fm.contents(atPath: path) == original else { throw ClientConfigError("cannot write a backup to \(path); nothing was changed") }
            backup = path
        } else if plan.createFolder {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            try replace(plan.path, with: plan.updated, permissions: permissions)
            guard fm.contents(atPath: plan.path) == plan.updated, try check(plan) else {
                throw ClientConfigError("the file read back differently from what was written")
            }
        } catch {
            if let original = plan.original { try? replace(plan.path, with: original, permissions: permissions) } else { try? fm.removeItem(atPath: plan.path) }
            throw ClientConfigError("writing \(plan.path) failed (\(error)); the original was put back" + (backup.map { " (a copy is at \($0))" } ?? ""))
        }
        return backup
    }

    private static func check(_ plan: ClientPlan) throws -> Bool {
        let found = try registered(plan.client, name: plan.name, in: plan.updated)
        return plan.entry.map { found == $0 } ?? (found == nil)
    }

    static func backupPath(for path: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = path + ".macmcp-backup-" + formatter.string(from: now)
        var candidate = base
        var n = 1
        while FileManager.default.fileExists(atPath: candidate) { n += 1; candidate = "\(base)-\(n)" }
        return candidate
    }

    /// Writes `data` to a sibling file and renames it over `path`, so a reader never sees half a file.
    private static func replace(_ path: String, with data: Data, permissions: Int) throws {
        let temporary = (path as NSString).deletingLastPathComponent + "/.macmcp-\(UUID().uuidString.prefix(8)).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw ClientConfigError("cannot write \(temporary)")
        }
        if rename(temporary, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: temporary)
            throw ClientConfigError("cannot replace \(path): \(reason)")
        }
    }
}

// MARK: - diff

enum LineDiff {
    /// The changed lines with `context` lines around them: ` ` unchanged, `-` removed, `+` added. Edits to these configs
    /// are one contiguous block, so the shared start and end of the two files are cut away.
    static func render(old: String, new: String, context: Int = 2) -> String {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        var lines: [String] = []
        for line in a[max(0, head - context)..<head] { lines.append("  " + line) }
        for line in a[head..<(a.count - tail)] { lines.append("- " + line) }
        for line in b[head..<(b.count - tail)] { lines.append("+ " + line) }
        for line in a[(a.count - tail)..<min(a.count, a.count - tail + context)] { lines.append("  " + line) }
        return lines.joined(separator: "\n")
    }
}
