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

    /// The protected locations of one check, resolved: each folder and file in every comparable form, and the
    /// install staging directories. Resolving costs a few `lstat` calls per location, so a check that covers many
    /// paths (a selection, a paste) or asks two questions of one path builds it once and passes it along. It is made
    /// per check and never kept: the next check resolves the links again, so a link swapped in between can't leave
    /// an outdated answer.
    struct Roots {
        let home: String
        let all: [String]
        /// Where install staging entries (`.macmcp-stage.*`, `.mac-mcp.new.*`) sit, and their name prefixes.
        let stages: [(directory: String, prefix: String)]

        init(home: String = Paths.home) {
            resolutions?.record()
            self.home = home
            all = (folders(home: home) + files(home: home)).flatMap { forms(of: $0, relativeTo: "/") }
            stages = [(home + "/Applications", ".macmcp-stage."), (home + "/.local/bin", ".mac-mcp.new.")]
                .flatMap { directory, prefix in forms(of: directory, relativeTo: "/").map { ($0, prefix) } }
        }

        func covers(_ candidate: String) -> Bool {
            all.contains { r in candidate == r || candidate.hasPrefix(r == "/" ? r : r + "/") } || isStage(candidate)
        }

        /// Whether a protected location sits inside `candidate`.
        func holds(inside candidate: String) -> Bool {
            all.contains { $0.hasPrefix(candidate == "/" ? candidate : candidate + "/") }
        }

        func isStage(_ path: String) -> Bool {
            for (base, prefix) in stages where path.hasPrefix(base + "/") {
                if path.dropFirst(base.count + 1).split(separator: "/").first?.hasPrefix(prefix) == true { return true }
            }
            return false
        }
    }

    /// Tests count how many times a check resolves the locations.
    final class ResolutionCount: Sendable {
        private let n = Locked(0)
        var value: Int { n.withLock { $0 } }
        init() {}
        fileprivate func record() { n.withLock { $0 += 1 } }
    }

    @TaskLocal static var resolutions: ResolutionCount?

    /// Whether `path` is, or is inside, a protected location. `~` is expanded, a relative path is taken against
    /// `base` (the home folder by default), `.` and `..` are resolved, symlinks are followed through the deepest part
    /// that exists (and a Finder alias at the end is resolved), and the comparison ignores case and Unicode form, as
    /// APFS does. Both the written and the resolved path are checked, so neither a link nor a `..` gets around it.
    public static func isProtected(_ path: String, relativeTo base: String? = nil, home: String = Paths.home) -> Bool {
        isProtected(path, relativeTo: base, roots: Roots(home: home))
    }

    static func isProtected(_ path: String, relativeTo base: String? = nil, roots: Roots) -> Bool {
        isProtected(path, candidates: forms(of: path, relativeTo: base ?? roots.home), relativeTo: base, roots: roots)
    }

    private static func isProtected(_ path: String, candidates: Set<String>, relativeTo base: String?, roots: Roots) -> Bool {
        if candidates.contains(where: roots.covers) { return true }
        return hardLinkMatches(path, relativeTo: base ?? roots.home, home: roots.home, roots: roots)
    }

    /// Why an agent may not touch this path, or nil.
    public static func refusal(_ path: String, relativeTo base: String? = nil) -> String? {
        firstRefusal([path], relativeTo: base, roots: nil)
    }

    /// The message for the first of `paths` that is protected, or nil. The locations are resolved once for all of them.
    public static func firstRefusal(_ paths: some Sequence<String>, relativeTo base: String? = nil) -> String? {
        firstRefusal(paths, relativeTo: base, roots: nil)
    }

    static func firstRefusal(_ paths: some Sequence<String>, relativeTo base: String? = nil, roots: Roots?) -> String? {
        var roots = roots
        for path in paths {
            let r = roots ?? Roots()
            roots = r
            if isProtected(path, relativeTo: base, roots: r) { return message(path) }
        }
        return nil
    }

    static func message(_ path: String) -> String {
        "Refused: \(Untrusted.inline(display(path), limit: 200)) is protected. Agents can't open, change or select MacMCP's install, settings and "
            + "logs, keychains, LaunchAgents, SSH keys, shell startup files, Git configuration or other tools' credentials; a person does that in Terminal."
    }

    /// Opening a containing directory is harmless. Renaming, moving, deleting or replacing it would also replace
    /// protected entries, so mutation routes check ancestors separately instead of protecting all their contents.
    public static func isProtectedFromMutation(_ path: String, relativeTo base: String? = nil, home: String = Paths.home) -> Bool {
        isProtectedFromMutation(path, relativeTo: base, roots: Roots(home: home))
    }

    static func isProtectedFromMutation(_ path: String, relativeTo base: String? = nil, roots: Roots) -> Bool {
        let candidates = forms(of: path, relativeTo: base ?? roots.home)
        if isProtected(path, candidates: candidates, relativeTo: base, roots: roots) { return true }
        return candidates.contains(where: roots.holds)
    }

    public static func mutationRefusal(_ path: String, relativeTo base: String? = nil) -> String? {
        firstMutationRefusal([path], relativeTo: base, roots: nil)
    }

    /// Like `firstRefusal`, for routes that move, rename, delete or replace.
    public static func firstMutationRefusal(_ paths: some Sequence<String>, relativeTo base: String? = nil) -> String? {
        firstMutationRefusal(paths, relativeTo: base, roots: nil)
    }

    static func firstMutationRefusal(_ paths: some Sequence<String>, relativeTo base: String? = nil, roots: Roots?) -> String? {
        var roots = roots
        for path in paths {
            let r = roots ?? Roots()
            roots = r
            if isProtectedFromMutation(path, relativeTo: base, roots: r) { return message(path) }
        }
        return nil
    }

    /// Only multiply-linked regular files need the more expensive identity walk. No file contents are read, and
    /// identities are fetched anew so an atomic replacement cannot leave an outdated cache authorizing a link.
    static func hardLinkMatches(_ path: String, relativeTo base: String, home: String, roots: Roots) -> Bool {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: p), url.isFileURL { p = url.path }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = base + "/" + p }
        let physicalPath = physical(p)
        p = aliasTarget(physicalPath) ?? physicalPath
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
                .map { directory + "/" + $0 }.filter { roots.isStage(comparable($0)) }
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
