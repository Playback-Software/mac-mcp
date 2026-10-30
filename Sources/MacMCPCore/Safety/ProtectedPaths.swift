import Foundation

/// Files and folders agents must never open, write, rename into or select: MacMCP's own policy, logs and support
/// files, the keychains (the approved policy and the signing identity live there), what runs at login (LaunchAgents,
/// shell startup files, Git and shell configuration), SSH keys and other tools' credentials. Reading or writing them would expose credentials,
/// loosen policy or run code outside MacMCP, so every route that names a path (mac_app open=, typing into a file panel
/// or Finder, an item's URL under a click or drop) asks `isProtected` first.
public enum ProtectedPaths {
    /// Shell startup files: whatever they say runs in the person's next shell.
    static let shellStartupFiles = [".zshenv", ".zshrc", ".zprofile", ".zlogin", ".zlogout", ".bash_profile", ".bashrc",
                                    ".bash_login", ".profile"]

    // The tables below are relative to the home folder; to protect another tool, add its path to the right one.

    /// Other tools' credential folders, protected with everything in them.
    static let credentialFolders = [
        ".config/gh", ".aws", ".kube", ".gnupg", ".config/gcloud", ".azure", ".password-store",
        ".config/op", ".op",                                      // 1Password CLI (current and v1)
        ".config/rclone", ".oci", ".config/configstore",          // cloud storage and Node CLIs' stored logins
        ".gemini", ".config/github-copilot",                      // AI assistants' logins
        ".config/doctl", ".wrangler",                             // DigitalOcean and Cloudflare, where they use XDG or the home folder
        "Library/Application Support/doctl", "Library/Preferences/.wrangler", "Library/Application Support/com.vercel.cli",
    ]

    /// Other tools' credential files outside those folders.
    static let credentialFiles = [
        ".netrc", ".git-credentials", ".config/git/credentials", ".docker/config.json", ".npmrc", ".pypirc", ".config/hub",
        ".terraform.d/credentials.tfrc.json",
        ".cargo/credentials.toml", ".cargo/credentials", ".gem/credentials",                   // package registries
        ".m2/settings.xml", ".m2/settings-security.xml", ".gradle/gradle.properties",          // build tools' repository logins
        ".vault-token", ".pgpass", ".my.cnf", ".s3cfg", ".boto",                               // secrets, databases, object storage
    ]

    /// Folders and files that run code like a shell startup file does: Git's `core.pager`, `core.fsmonitor`, `alias.!…`,
    /// and fish's and zsh's configuration run commands the next time the person uses Git or a shell. AI clients'
    /// settings do the same: an MCP server entry, a hook or a configured command in Claude Code, Codex, Cursor or Claude
    /// Desktop runs whatever it names when the client next starts, outside MacMCP's policy (and they hold logins too).
    static let codeRunningFolders = [".config/fish", ".config/zsh", ".claude", ".codex", ".cursor",
                                     "Library/Application Support/Claude"]
    static let codeRunningFiles = [".gitconfig", ".config/git/config", ".claude.json"]

    /// Folders protected with everything in them.
    static func folders(home: String) -> [String] {
        [home + "/.config/mac-mcp", home + "/Library/Application Support/MacMCP", home + "/Library/Logs/MacMCP",
         home + "/Library/LaunchAgents", home + "/.ssh", home + "/Library/Keychains", Paths.managedPolicyDir,
         home + "/Applications/MacMCP.app", home + "/Applications/MacMCP.app.previous",
         home + "/Applications/MacMCPTestHost.app"] + (credentialFolders + codeRunningFolders).map { home + "/" + $0 }
    }

    /// Single files outside those folders. The Services cache adds keys MacMCP refuses (`ServiceHotkeys`): rewritten,
    /// it could take them away.
    static func files(home: String) -> [String] {
        [home + "/Library/Keychains/mac-mcp-signing.keychain-db", home + "/.local/bin/mac-mcp",
         home + "/.local/bin/mac-mcp.previous", servicesCache(home: home)]
            + (credentialFiles + codeRunningFiles + shellStartupFiles).map { home + "/" + $0 }
    }

    static func servicesCache(home: String) -> String { home + "/Library/Caches/com.apple.nsservicescache.plist" }

    /// Whether `path` is, or is inside, a protected location. `~` is expanded, a relative path is taken against
    /// `base` (the home folder by default), `.` and `..` are resolved, symlinks are followed through the deepest part
    /// that exists (and a Finder alias at the end is resolved), and the comparison ignores case and Unicode form, as
    /// APFS does. Both the written and the resolved path are checked, so neither a link nor a `..` gets around it.
    public static func isProtected(_ path: String, relativeTo base: String? = nil, home: String = Paths.home) -> Bool {
        let candidates = forms(of: path, relativeTo: base ?? home)
        let roots = (folders(home: home) + files(home: home)).flatMap { forms(of: $0, relativeTo: "/") }
        if candidates.contains(where: { c in
            roots.contains { r in c == r || c.hasPrefix(r == "/" ? r : r + "/") } || isInstallStage(c, home: home)
        }) { return true }
        return hardLinkMatches(path, relativeTo: base ?? home, home: home)
    }

    /// Why an agent may not touch this path, or nil.
    public static func refusal(_ path: String, relativeTo base: String? = nil) -> String? {
        guard isProtected(path, relativeTo: base) else { return nil }
        return message(path)
    }

    static func message(_ path: String) -> String {
        "Refused: \(Untrusted.inline(display(path), limit: 200)) is protected. Agents can't open, change or select MacMCP's install, settings and "
            + "logs, keychains, LaunchAgents, SSH keys, shell startup files, Git configuration or other tools' credentials; a person does that in Terminal."
    }

    /// Opening a containing directory is harmless. Renaming, moving, deleting or replacing it would also replace
    /// protected entries, so mutation routes check ancestors separately instead of protecting all their contents.
    public static func isProtectedFromMutation(_ path: String, relativeTo base: String? = nil, home: String = Paths.home) -> Bool {
        if isProtected(path, relativeTo: base, home: home) { return true }
        let candidates = forms(of: path, relativeTo: base ?? home)
        let roots = (folders(home: home) + files(home: home)).flatMap { forms(of: $0, relativeTo: "/") }
        return candidates.contains { c in roots.contains { $0.hasPrefix(c == "/" ? c : c + "/") } }
    }

    public static func mutationRefusal(_ path: String, relativeTo base: String? = nil) -> String? {
        isProtectedFromMutation(path, relativeTo: base) ? message(path) : nil
    }

    static func isInstallStage(_ path: String, home: String) -> Bool {
        for (directory, prefix) in [(home + "/Applications", ".macmcp-stage."), (home + "/.local/bin", ".mac-mcp.new.")] {
            for base in forms(of: directory, relativeTo: "/") where path.hasPrefix(base + "/") {
                if path.dropFirst(base.count + 1).split(separator: "/").first?.hasPrefix(prefix) == true { return true }
            }
        }
        return false
    }

    /// Only multiply-linked regular files need the more expensive identity walk. No file contents are read, and
    /// identities are fetched anew so an atomic replacement cannot leave an outdated cache authorizing a link.
    static func hardLinkMatches(_ path: String, relativeTo base: String, home: String) -> Bool {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: p), url.isFileURL { p = url.path }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = base + "/" + p }
        p = aliasTarget(physical(p)) ?? physical(p)
        var candidate = stat()
        guard stat(p, &candidate) == 0, candidate.st_mode & S_IFMT == S_IFREG, candidate.st_nlink > 1 else { return false }
        func matches(_ protected: String) -> Bool {
            var info = stat()
            return stat(protected, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                && info.st_dev == candidate.st_dev && info.st_ino == candidate.st_ino
        }
        if files(home: home).contains(where: matches) { return true }
        var directories = folders(home: home)
        for directory in [home + "/Applications", home + "/.local/bin"] {
            directories += ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .map { directory + "/" + $0 }.filter { isInstallStage(comparable($0), home: home) }
        }
        for directory in directories {
            if matches(directory) { return true }
            guard let entries = FileManager.default.enumerator(atPath: directory) else { continue }
            var count = 0
            while let entry = entries.nextObject() as? String {
                count += 1
                if count > 20000 { return true } // cannot finish checking a hard link: fail closed
                if matches(directory + "/" + entry) { return true }
            }
        }
        return false
    }

    static func display(_ path: String) -> String {
        let p = String(path.prefix(200))
        return p.hasPrefix(Paths.home + "/") ? "~" + p.dropFirst(Paths.home.count) : p
    }

    /// The comparable forms of a path: as written (lexically normalized) and with links resolved; lowercased,
    /// precomposed, and without the /System/Volumes/Data firmlink prefix.
    static func forms(of path: String, relativeTo base: String) -> Set<String> {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.lowercased().hasPrefix("file:"), let url = URL(string: p), url.isFileURL { p = url.path }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = base + "/" + p }
        var out: Set<String> = [comparable(lexical(p)), comparable(physical(p))]
        let resolved = physical(p)
        if let alias = aliasTarget(resolved) { out.insert(comparable(physical(alias))) }
        return out
    }

    static func comparable(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping.lowercased()
        if p.hasPrefix("/system/volumes/data/") { p.removeFirst("/system/volumes/data".count) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `.` and `..` resolved by name alone.
    static func lexical(_ absolute: String) -> String {
        var parts: [Substring] = []
        for c in absolute.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves symlinks component by component as the kernel would, so a `..` after a link climbs out of its
    /// target. Components past the deepest one that exists are kept as written.
    static func physical(_ absolute: String) -> String {
        var resolved: [String] = []
        var pending = absolute.split(separator: "/").map(String.init)
        var hops = 0
        var exists = true
        while !pending.isEmpty {
            let c = pending.removeFirst()
            if c == "." { continue }
            if c == ".." { _ = resolved.popLast(); continue }
            guard exists else { resolved.append(c); continue }
            let candidate = "/" + (resolved + [c]).joined(separator: "/")
            var st = stat()
            guard lstat(candidate, &st) == 0 else { exists = false; resolved.append(c); continue }
            if st.st_mode & S_IFMT == S_IFLNK, hops < 40, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                if target.hasPrefix("/") { resolved = [] }
                pending = target.split(separator: "/").map(String.init) + pending
                continue
            }
            resolved.append(c)
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// Where a Finder alias file points, if `path` is one. Never mounts a volume or shows UI.
    static func aliasTarget(_ path: String) -> String? {
        // An alias is a regular file (a symlink also reports isAliasFile). Most paths checked don't exist, and this
        // skips the error the resource lookup would throw for each of them.
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
              let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
        return target.path
    }
}
