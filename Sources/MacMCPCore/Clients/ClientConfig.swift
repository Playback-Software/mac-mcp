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
    /// Server names every client accepts: letters, digits, `_`, `.` and `-` (up to 64), and not starting with `-` so
    /// that a client's CLI never reads a name as an option.
    public static func validate(name: String) throws {
        guard name.range(of: "^[A-Za-z0-9_.][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil, !name.allSatisfy({ $0 == "." }) else {
            throw ClientConfigError("`\(name)` isn't a usable server name: use letters, digits, - _ and . (up to 64), not starting with -")
        }
    }

    /// `data` after adding `entry` (or, with nil, removing the entry) for `name`. Pure: no files are touched. The result
    /// is read back before it's returned, so an edit that doesn't leave exactly the entry wanted is never written.
    static func edit(_ client: McpClient, name: String, entry: ServerEntry?, original: Data?) throws -> (data: Data, change: ClientChange) {
        let edited = try rawEdit(client, name: name, entry: entry, original: original)
        do {
            let found = edited.change == .unchanged ? entry : try registered(client, name: name, in: edited.data)
            guard found == entry else {
                throw ConfigFormatError(description: "the edited file doesn't hold exactly the entry wanted")
            }
        } catch let error as ConfigFormatError {
            throw ClientConfigError("\(error.description). Nothing was changed.")
        }
        return edited
    }

    private static func rawEdit(_ client: McpClient, name: String, entry: ServerEntry?, original: Data?) throws -> (data: Data, change: ClientChange) {
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
    /// The home folder whose support folder holds the backup.
    let home: String

    /// The lines that change, with a little context.
    public var diff: String { LineDiff.render(old: original.map { String(decoding: $0, as: UTF8.self) } ?? "", new: String(decoding: updated, as: UTF8.self)) }
}

/// Seams for tests to act between the steps of `ClientConfig.apply`, as a client saving its config would.
struct ApplyHooks: Sendable {
    /// After the temporary file is ready and before the file is read again and replaced.
    var beforeRename: (@Sendable () -> Void)?
    /// After the rename, before the result is checked.
    var afterRename: (@Sendable () -> Void)?
    /// Replaces the check that the written file holds the entry.
    var check: (@Sendable (ClientPlan) throws -> Bool)?
    /// Names to try for the temporary file, by attempt; nil means a random name.
    var temporaryName: (@Sendable (Int) -> String?)?

    static let none = ApplyHooks()
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
        if original == nil, entry == nil {
            return ClientPlan(client: client, name: name, path: path, change: .unchanged, original: nil, updated: Data(), entry: nil,
                              createFolder: false, home: environment.home)
        }
        let edited = try edit(client, name: name, entry: entry, original: original)
        return ClientPlan(client: client, name: name, path: path, change: edited.change, original: original, updated: edited.data,
                          entry: entry, createFolder: createFolder, home: environment.home)
    }

    /// Writes a plan. In order:
    /// 1. reads the file again and refuses if it isn't what the plan was made from;
    /// 2. copies it to the backup folder (`ClientBackups`);
    /// 3. writes the new contents to a temporary file beside it, with the original's owner, group, mode and ACL, and
    ///    refuses if those can't be kept;
    /// 4. reads the file once more right before the rename and refuses if a client saved meanwhile;
    /// 5. renames the temporary file over it (for a new file, only if still nothing is there), and reads it back.
    /// If the read-back isn't right, the original is put back, but only while the file still holds exactly what was
    /// written: a newer save by the client is left alone and reported. Returns the backup's path, if there was a file.
    ///
    /// Clients don't lock their configs, so a save in the instant between step 4 and the rename can still be lost.
    /// Quitting the client first is the only complete protection.
    @discardableResult
    public static func apply(_ plan: ClientPlan, now: Date = Date()) throws -> String? {
        try apply(plan, now: now, hooks: .none)
    }

    static func apply(_ plan: ClientPlan, now: Date, hooks: ApplyHooks) throws -> String? {
        guard plan.change != .unchanged else { return nil }
        let folderPath = (plan.path as NSString).deletingLastPathComponent
        let fileName = (plan.path as NSString).lastPathComponent
        let shown = ClientInstaller.display(plan.path, home: plan.home)
        let changed = ClientConfigError("\(shown) changed while mac-mcp was working on it; nothing was written. "
            + "Quit \(plan.client.displayName) and run the command again.")
        if plan.original == nil, plan.createFolder { try? FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true) }
        let folder = try PinnedDirectory(path: folderPath)

        // 1. The file as it is now.
        let originalFile = try folder.openFile(fileName)
        defer { if let originalFile { close(originalFile) } }
        let current = try originalFile.map { try ClientFiles.readAll($0, describing: shown) }
        guard current == plan.original else { throw changed }

        // 2. The backup.
        var backup: (path: String, name: String, folder: PinnedDirectory)?
        if let original = plan.original {
            backup = try ClientBackups.write(original, client: plan.client, label: fileName, home: plan.home, now: now)
        }
        func abandonBackup() { if let backup { backup.folder.remove(backup.name) } }

        // 3. The new contents, beside the file.
        let temporary: (name: String, fd: Int32)
        do {
            temporary = try folder.createExclusive(mode: 0o600) { attempt in
                hooks.temporaryName?(attempt) ?? ".\(fileName).macmcp-\(UUID().uuidString.prefix(8)).tmp"
            }
        } catch { abandonBackup(); throw error }
        var temporaryOpen = true
        func closeTemporary() { if temporaryOpen { close(temporary.fd); temporaryOpen = false } }
        func discardTemporary() { closeTemporary(); folder.remove(temporary.name) }
        var written = stat()
        do {
            try ClientFiles.writeAll(temporary.fd, plan.updated, describing: temporary.name)
            if let originalFile { try ClientFiles.copySecurity(from: originalFile, to: temporary.fd) }
            guard fsync(temporary.fd) == 0, fstat(temporary.fd, &written) == 0 else {
                throw ClientConfigError("cannot write \(temporary.name): \(ClientFiles.reason())")
            }
        } catch {
            discardTemporary(); abandonBackup()
            throw ClientConfigError("\(error); \(shown) was not changed")
        }
        closeTemporary()

        // 4. Once more, right before the rename.
        hooks.beforeRename?()
        let latest: Data?
        do { latest = try folder.read(fileName)?.data } catch { discardTemporary(); abandonBackup(); throw error }
        guard latest == plan.original else { discardTemporary(); abandonBackup(); throw changed }

        // 5. The rename.
        if let code = folder.rename(temporary.name, to: fileName, replacing: plan.original != nil) {
            discardTemporary(); abandonBackup()
            if code == EEXIST { throw changed }
            throw ClientConfigError("cannot replace \(shown): \(ClientFiles.reason(code)); it was not changed")
        }
        hooks.afterRename?()
        guard let landed = try? folder.read(fileName), landed.data == plan.updated, landed.info.st_ino == written.st_ino else {
            // It isn't what was written: another program saved right after the rename. Its version stays.
            throw ClientConfigError("\(shown) was changed by something else right after mac-mcp wrote it, so mac-mcp left it as it is "
                + "and did not put the original back. Check that it still has \"\(plan.name)\""
                + (backup.map { "; the original is saved at \(ClientInstaller.display($0.path, home: plan.home))" } ?? "")
                + ". Quit \(plan.client.displayName) and run the command again.")
        }
        let ok: Bool
        do { ok = try hooks.check?(plan) ?? check(plan) } catch { ok = false }
        if ok { return backup?.path }

        // The write is wrong. Put the original back, if the file is still exactly what was written.
        let outcome = rollback(plan, folder: folder, fileName: fileName, originalFile: originalFile, written: written, hooks: hooks)
        let tail = backup.map { " The original is saved at \($0.path)." } ?? ""
        switch outcome {
        case .restored:
            throw ClientConfigError("the file read back differently from what was written; the original was put back and checked." + tail)
        case let .left(state):
            throw ClientConfigError("the file read back differently from what was written, and the original could NOT be put back: \(state)." + tail
                + (plan.original != nil ? " To restore it yourself, quit \(plan.client.displayName) and copy the saved file over \(plan.path)." : ""))
        }
    }

    private enum Rollback { case restored, left(String) }

    /// Puts the original back (or removes a file that is new), but only while the file is still the one we wrote.
    /// Everything is checked: what is reported is what the file holds afterwards.
    private static func rollback(_ plan: ClientPlan, folder: PinnedDirectory, fileName: String, originalFile: Int32?, written: stat,
                                 hooks: ApplyHooks) -> Rollback {
        func state() -> String {
            guard let now = try? folder.read(fileName) else { return folder.exists(fileName) ? "the file can't be read" : "the file is missing" }
            if now.data == plan.original { return "the file holds the original contents" }
            if now.data == plan.updated { return "the file still holds the new contents mac-mcp wrote" }
            return "the file holds contents that are neither the original nor what mac-mcp wrote"
        }
        func stillOurs() -> Bool {
            guard let now = try? folder.read(fileName) else { return false }
            return now.data == plan.updated && now.info.st_ino == written.st_ino
        }
        guard stillOurs() else {
            return .left("it was changed by something else since, so mac-mcp left it alone; " + state())
        }
        guard let original = plan.original, let originalFile else {
            // A file that didn't exist before: take it away.
            folder.remove(fileName)
            if !folder.exists(fileName) { return .restored }
            return .left("removing it failed; " + state())
        }
        var restoring: (name: String, fd: Int32)?
        do {
            let created = try folder.createExclusive(mode: 0o600) { _ in ".\(fileName).macmcp-restore-\(UUID().uuidString.prefix(8)).tmp" }
            restoring = created
            try ClientFiles.writeAll(created.fd, original, describing: created.name)
            try ClientFiles.copySecurity(from: originalFile, to: created.fd)
            guard fsync(created.fd) == 0 else { throw ClientConfigError("cannot write \(created.name): \(ClientFiles.reason())") }
            close(created.fd)
            restoring = (created.name, -1)
            guard stillOurs() else { throw ClientConfigError("it was changed by something else just now, so mac-mcp left it alone") }
            if let code = folder.rename(created.name, to: fileName, replacing: true) {
                throw ClientConfigError("cannot rename over it: \(ClientFiles.reason(code))")
            }
            restoring = nil
        } catch {
            if let restoring {
                if restoring.fd >= 0 { close(restoring.fd) }
                folder.remove(restoring.name)
            }
            return .left("\(error); " + state())
        }
        guard (try? folder.read(fileName))?.data == original else { return .left("it didn't read back as the original; " + state()) }
        return .restored
    }

    private static func check(_ plan: ClientPlan) throws -> Bool {
        let found = try registered(plan.client, name: plan.name, in: plan.updated)
        return plan.entry.map { found == $0 } ?? (found == nil)
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
