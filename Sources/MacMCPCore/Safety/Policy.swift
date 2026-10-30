import AppKit
import Foundation

/// `~/.config/mac-mcp/policy.json`: what agents may touch. Re-read whenever it changes; edits that tighten it apply
/// at once, and edits that loosen it wait until a person approves them (`PolicyStore`). Missing keys take their
/// defaults, so older files keep working.
public struct Policy: Codable, Sendable, Equatable {
    /// Apps (bundle ID or name) agents may not see or drive. Default: `defaultDenyApps` (banking/crypto apps go here too).
    public var denyApps: [String]
    /// If non-empty, agents may only see and drive these apps.
    public var allowApps: [String]
    public var script: ScriptPolicy
    public var web: WebPolicy
    public var shortcuts: ShortcutsPolicy
    /// Whether mac_clipboard may read the clipboard (it can hold secrets copied by a person).
    public var clipboardRead: Bool
    /// Maximum actions per second (each action waits for its turn). Guards against runaway loops.
    public var rateLimitPerSecond: Double
    /// Optional URL to POST a plain-text alert to when work is blocked on a person (screen locked, a macOS prompt,
    /// a missing permission). ntfy.sh-compatible; any endpoint that accepts a text body works.
    public var alertWebhook: String?
    /// Minimum minutes between two alerts of the same kind.
    public var alertCooldownMinutes: Int

    public struct ScriptPolicy: Codable, Sendable, Equatable {
        /// Apps (bundle ID or name) that mac_script may target. Empty: mac_script can't control any app.
        public var allowedApps: [String]
        public var timeoutSeconds: Int
        /// Whether JXA may run. Off by default: JavaScript reaches the shell and the Objective-C bridge through
        /// computed names no filter can see, so allowing it gives scripts the agent's full power.
        public var jxa: Bool
        /// System Events exposes other apps and the filesystem; listing it alone must not enable that access.
        public var allowSystemEvents: Bool

        enum CodingKeys: String, CodingKey { case allowedApps = "allowed_apps", timeoutSeconds = "timeout_seconds", jxa, allowSystemEvents = "allow_system_events" }

        public init(allowedApps: [String], timeoutSeconds: Int, jxa: Bool = false, allowSystemEvents: Bool = false) {
            self.allowedApps = allowedApps
            self.timeoutSeconds = timeoutSeconds
            self.jxa = jxa
            self.allowSystemEvents = allowSystemEvents
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allowedApps = try c.decodeIfPresent([String].self, forKey: .allowedApps) ?? []
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
            jxa = try c.decodeIfPresent(Bool.self, forKey: .jxa) ?? false
            allowSystemEvents = try c.decodeIfPresent(Bool.self, forKey: .allowSystemEvents) ?? false
        }
    }

    /// mac_shortcut: which Shortcuts agents may run. A shortcut can do anything its actions allow (shell scripts,
    /// files, messages), so the person names each one; empty means none may run.
    public struct ShortcutsPolicy: Codable, Sendable, Equatable {
        /// Shortcut names (case-insensitive) or identifiers agents may run.
        public var allowed: [String]
        public var timeoutSeconds: Int

        enum CodingKeys: String, CodingKey { case allowed, timeoutSeconds = "timeout_seconds" }

        public init(allowed: [String] = [], timeoutSeconds: Int = 60) {
            self.allowed = allowed
            self.timeoutSeconds = timeoutSeconds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allowed = try c.decodeIfPresent([String].self, forKey: .allowed) ?? []
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        }

        static func matchingKey(_ value: String) -> String { value.lowercased().precomposedStringWithCanonicalMapping }

        /// Whether a shortcut (by name or identifier) is on the list.
        public func allows(name: String, identifier: String? = nil) -> Bool {
            let entries = Set(allowed.map(Self.matchingKey))
            return entries.contains(Self.matchingKey(name)) || identifier.map { entries.contains(Self.matchingKey($0)) } == true
        }
    }

    /// The web_* tools (Safari's automation browser, driven through Safari's own MCP server).
    public struct WebPolicy: Codable, Sendable, Equatable {
        /// Whether web_* tools may run at all.
        public var enabled: Bool
        /// Whether web_eval may run JavaScript in pages (it can read anything the page can, including form contents).
        public var evalAllowed: Bool
        /// Hosts web_* may not open or act on. An entry matches the host and its subdomains ("bank.com" covers
        /// "www.bank.com").
        public var denyHosts: [String]
        /// If non-empty, web_* may only open and act on these hosts (and their subdomains).
        public var allowHosts: [String]
        /// Whether web_* may open loopback, link-local and private-network addresses (localhost, 10.x, 192.168.x,
        /// router admin pages, cloud metadata at 169.254.169.254, *.local). Off by default; a host listed in
        /// allow_hosts is allowed either way.
        public var allowPrivateHosts: Bool

        enum CodingKeys: String, CodingKey {
            case enabled, evalAllowed = "eval_allowed", denyHosts = "deny_hosts", allowHosts = "allow_hosts"
            case allowPrivateHosts = "allow_private_hosts"
        }

        public init(enabled: Bool = true, evalAllowed: Bool = false, denyHosts: [String] = [], allowHosts: [String] = [],
                    allowPrivateHosts: Bool = false) {
            self.enabled = enabled
            self.evalAllowed = evalAllowed
            self.denyHosts = denyHosts
            self.allowHosts = allowHosts
            self.allowPrivateHosts = allowPrivateHosts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = WebPolicy()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            evalAllowed = try c.decodeIfPresent(Bool.self, forKey: .evalAllowed) ?? d.evalAllowed
            denyHosts = try c.decodeIfPresent([String].self, forKey: .denyHosts) ?? d.denyHosts
            allowHosts = try c.decodeIfPresent([String].self, forKey: .allowHosts) ?? d.allowHosts
            allowPrivateHosts = try c.decodeIfPresent(Bool.self, forKey: .allowPrivateHosts) ?? d.allowPrivateHosts
        }

        /// Whether a host is this Mac or on a private network: a local name, or an IP address (in any form a browser
        /// accepts, such as 2130706433 for 127.0.0.1) in a loopback, link-local, private or shared range. Names that
        /// merely resolve to such an address aren't caught.
        static func isPrivate(host: String) -> Bool {
            let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
            if h == "localhost" || [".localhost", ".local", ".internal", ".home.arpa"].contains(where: h.hasSuffix) { return true }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, h, &v6) == 1 {
                let b = withUnsafeBytes(of: &v6) { Array($0) }
                if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {   // ::ffff:a.b.c.d
                    return isPrivate(v4: UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
                }
                return b.allSatisfy { $0 == 0 } || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1)   // :: and ::1
                    || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)               // fc00::/7, fe80::/10
            }
            // inet_aton takes the legacy forms browsers do too: 127.1, 0x7f.0.0.1, 2130706433.
            guard h.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }) else { return false }
            var v4 = in_addr()
            guard inet_aton(h, &v4) != 0 else { return false }
            return isPrivate(v4: UInt32(bigEndian: v4.s_addr))
        }

        static func isPrivate(v4 a: UInt32) -> Bool {
            let ranges: [(UInt32, Int)] = [(0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8),
                                           (0xA9FE_0000, 16), (0xAC10_0000, 12), (0xC0A8_0000, 16)]
            return ranges.contains { base, bits in a >> (32 - bits) == base >> (32 - bits) }
        }

        /// Whether a host is one of the entries or a subdomain of one. Both sides drop trailing dots ("bank.com." is
        /// the same site as "bank.com"), and an entry written as a URL ("https://bank.com/") counts as its host.
        static func covers(_ entries: [String], host: String) -> Bool {
            let host = normalizedHost(host)
            return entries.map(normalizedHost).contains { !$0.isEmpty && (host == $0 || host.hasSuffix("." + $0)) }
        }

        /// A host-list entry as the host it names: lowercased, without trailing dots, and the host of a URL entry.
        static func normalizedHost(_ entry: String) -> String {
            let e = entry.lowercased().trimmingCharacters(in: .whitespaces)
            return (e.contains("://") ? URL(string: e)?.host ?? e : e).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        /// Why web_* may not open or act on this URL, or nil if it may. Only http(s) and about:blank are allowed:
        /// file: and data: URLs would let a page tool read local files or run arbitrary content.
        public func refusal(url string: String) -> String? {
            guard enabled else { return "Refused by policy: web tools are turned off (web.enabled in \(Policy.fileRef))." }
            if string == "about:blank" { return nil }
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else {
                return "Refused: web tools only open http(s) URLs (got \(string.prefix(80)))."
            }
            if WebPolicy.covers(denyHosts, host: host) {
                return "Refused by policy: \(host) is on web.deny_hosts (\(Policy.fileRef))."
            }
            if !allowPrivateHosts, WebPolicy.isPrivate(host: host), !WebPolicy.covers(allowHosts, host: host) {
                return "Refused by policy: \(host) is this Mac or a private-network address. A person can allow it with "
                    + "web.allow_private_hosts, or by listing it in web.allow_hosts (\(Policy.fileRef))."
            }
            if !allowHosts.isEmpty, !WebPolicy.covers(allowHosts, host: host) {
                return "Refused by policy: \(host) is not in web.allow_hosts (\(Policy.fileRef))."
            }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case denyApps = "deny_apps", allowApps = "allow_apps", script, web, shortcuts, clipboardRead = "clipboard_read"
        case rateLimitPerSecond = "rate_limit_per_second", alertWebhook = "alert_webhook", alertCooldownMinutes = "alert_cooldown_minutes"
    }

    /// Apps that would hand an agent what the other tools withhold: a shell (Terminal, iTerm2 and the other terminals,
    /// Script Editor, Automator, the Shortcuts editor), something that runs commands, scripts, shortcuts or macros for
    /// it (Spotlight, Raycast, Alfred, Keyboard Maestro, Hammerspoon, Script Debugger, the Script menu), stored secrets
    /// (Keychain Access, Passwords and the common password managers), or this Mac's security settings. A person who
    /// wants agents in one of them removes it from deny_apps.
    ///
    /// Each bundle ID was checked against the app itself (on this Mac, or the vendor's download), its source, or its
    /// App Store or Homebrew listing. Older and helper IDs are listed too: an app that changed its ID (Alacritty,
    /// KeePassXC, Alfred) or is versioned in it (Script Debugger, whose versions 5 to 8 also share the name "Script
    /// Debugger") is still caught.
    public static let defaultDenyApps = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview", "dev.warp.WarpOss", "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty",
        "net.kovidgoyal.kitty-quick-access", "com.github.wez.wezterm", "co.zeit.hyper",
        // Scripting and automation
        "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts", "com.apple.ScriptMenuApp",
        "com.apple.AppleScriptUtility", "com.latenightsw.ScriptDebugger", "com.latenightsw.ScriptDebugger5",
        "com.latenightsw.ScriptDebugger6", "com.latenightsw.ScriptDebugger7", "com.latenightsw.ScriptDebugger8",
        "Script Debugger",
        // Launchers and macro tools
        "com.apple.Spotlight", "com.raycast.macos", "com.raycast.macos.palette", "com.raycast-x.macos",
        "com.runningwithcrayons.Alfred", "com.runningwithcrayons.Alfred-Preferences", "com.runningwithcrayons.Alfred-3",
        "com.runningwithcrayons.Alfred-Preferences-3", "com.runningwithcrayons.Alfred-2",
        "com.stairways.keyboardmaestro.editor", "com.stairways.keyboardmaestro.engine", "org.hammerspoon.Hammerspoon",
        // Stored secrets
        "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.1password.safari", "2BUA8C4S2C.com.1password.browser-helper",
        "com.agilebits.onepassword7", "2BUA8C4S2C.com.agilebits.onepassword7-helper", "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4", "com.bitwarden.desktop", "com.bitwarden.beta.desktop", "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "org.keepassx.keepassxc",
        "com.lastpass.lastpassmacdesktop", "com.lastpass.LastPass", "com.lastpass.lastpassforsafari",
        "me.proton.pass.electron", "me.proton.pass.catalyst", "in.sinew.Enpass-Desktop.App", "in.sinew.Enpass-Desktop",
        // Security settings
        "com.apple.systempreferences",
    ]

    public init(denyApps: [String] = Policy.defaultDenyApps, allowApps: [String] = [], script: ScriptPolicy = .init(allowedApps: [], timeoutSeconds: 30),
                web: WebPolicy = WebPolicy(), shortcuts: ShortcutsPolicy = ShortcutsPolicy(), clipboardRead: Bool = true, rateLimitPerSecond: Double = 10, alertWebhook: String? = nil, alertCooldownMinutes: Int = 10) {
        self.denyApps = denyApps
        self.allowApps = allowApps
        self.script = script
        self.web = web
        self.shortcuts = shortcuts
        self.clipboardRead = clipboardRead
        self.rateLimitPerSecond = rateLimitPerSecond
        self.alertWebhook = alertWebhook
        self.alertCooldownMinutes = alertCooldownMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Policy()
        denyApps = try c.decodeIfPresent([String].self, forKey: .denyApps) ?? d.denyApps
        allowApps = try c.decodeIfPresent([String].self, forKey: .allowApps) ?? d.allowApps
        script = try c.decodeIfPresent(ScriptPolicy.self, forKey: .script) ?? d.script
        web = try c.decodeIfPresent(WebPolicy.self, forKey: .web) ?? d.web
        shortcuts = try c.decodeIfPresent(ShortcutsPolicy.self, forKey: .shortcuts) ?? d.shortcuts
        clipboardRead = try c.decodeIfPresent(Bool.self, forKey: .clipboardRead) ?? d.clipboardRead
        rateLimitPerSecond = try c.decodeIfPresent(Double.self, forKey: .rateLimitPerSecond) ?? d.rateLimitPerSecond
        alertWebhook = try c.decodeIfPresent(String.self, forKey: .alertWebhook).flatMap { $0.isEmpty ? nil : $0 }
        alertCooldownMinutes = try c.decodeIfPresent(Int.self, forKey: .alertCooldownMinutes) ?? d.alertCooldownMinutes
        guard rateLimitPerSecond > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .rateLimitPerSecond, in: c, debugDescription: "must be > 0")
        }
    }

    public static let defaults = Policy()

    public enum LoadError: Error, CustomStringConvertible {
        case invalid(String, String)
        /// The approved policy can't be established (its keychain record is missing, damaged or unreadable), so
        /// there is nothing safe to compare policy.json with.
        case blocked(String)
        public var description: String {
            switch self {
            case let .invalid(path, why):
                "POLICY INVALID: \(path) could not be read (\(why)). Agents are blocked until a person fixes it; "
                    + "`mac-mcp doctor` shows the details."
            case let .blocked(why):
                "POLICY BLOCKED: \(why) Agents are blocked until a person runs `mac-mcp policy approve` in Terminal."
            }
        }
    }

    /// The policy in force: the managed policy if there is one, else policy.json once it's no looser than the policy a
    /// person approved (kept in the login keychain), else that approved policy (`PolicyStore`). An invalid file, or an
    /// approval that can't be read, is an error rather than a silent fallback, so neither can quietly drop someone's
    /// deny list.
    public static func current() async -> Result<Policy, LoadError> { await PolicyStore.shared.status().enforced }

    /// The same, for synchronous code (the CLI, dedicated threads); it blocks its thread while the policy is evaluated.
    public static func current() -> Result<Policy, LoadError> { PolicyStore.shared.status().enforced }

    /// The policy in force, or the last approved one (else the defaults) when it's invalid: for non-gating uses such
    /// as timeouts and the alert webhook, which a broken file mustn't switch off. Once one evaluation has finished it
    /// never waits for another (`PolicyStore.recentStatus`), so synchronous code on any thread may call it.
    public static func load() -> Policy { PolicyStore.shared.recentStatus().policy }

    /// What one file says on its own, without the approval check. A missing file means the defaults; an unreadable
    /// one is an error.
    public static func current(path: String) -> Result<Policy, LoadError> {
        switch read(path: path) {
        case .missing: .success(defaults)
        case let .invalid(e): .failure(e)
        case let .valid(p, _): .success(p)
        }
    }

    /// One file on its own, or the defaults if it's invalid.
    public static func load(path: String) -> Policy {
        (try? current(path: path).get()) ?? defaults
    }

    public enum FileRead {
        case missing
        case invalid(LoadError)
        case valid(Policy, Data)
    }

    /// Reads and validates one policy file.
    public static func read(path: String) -> FileRead {
        guard let data = FileManager.default.contents(atPath: path) else {
            // Only a file that isn't there is missing; one that exists but can't be read must not fail open.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
            return .invalid(.invalid(path, isDirectory.boolValue ? "it is a directory" : "it exists but can't be read"))
        }
        switch decode(data) {
        case let .success(p): return .valid(p, data)
        case let .failure(f): return .invalid(.invalid(path, f.why))
        }
    }

    /// Parses policy JSON, or says what's wrong with it.
    public static func decode(_ data: Data) -> Result<Policy, DecodeFailure> {
        do {
            try PolicyJSON.validate(data)
            return .success(try JSONDecoder().decode(Policy.self, from: data))
        } catch {
            let why: String
            switch error {
            case let DecodingError.dataCorrupted(ctx): why = ctx.debugDescription + (ctx.underlyingError.map { ": \($0.localizedDescription)" } ?? "")
            case let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx): why = "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            default: why = "\(error)"
            }
            return .failure(DecodeFailure(why: why))
        }
    }

    public struct DecodeFailure: Error, CustomStringConvertible {
        public let why: String
        public var description: String { why }
    }

    /// The policy file named in refusals: the one in force, plus a note when policy.json has changes waiting for a
    /// person's approval (the agent would otherwise conclude the file doesn't say what it says).
    public static var fileRef: String { PolicyStore.shared.refusalReference }

    /// Writes the default policy if none exists. Returns true if it wrote one.
    @discardableResult
    public static func writeDefaultIfMissing(path: String = Paths.policyFile) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try encodedDefaults.write(to: URL(fileURLWithPath: path))
        return true
    }

    static func appKey(_ value: String, trimmingWhitespace: Bool = false) -> String {
        let key = value.lowercased().precomposedStringWithCanonicalMapping
        return trimmingWhitespace ? key.trimmingCharacters(in: .whitespaces) : key
    }

    /// Whether an app (bundle ID and/or name) matches any entry in a list (bundle IDs or names, case-insensitive).
    public static func matches(_ list: [String], bundleID: String?, name: String?) -> Bool {
        let entries = Set(list.map { appKey($0) })
        return [bundleID, name].compactMap { $0.map { appKey($0) } }.contains(where: entries.contains)
    }

    /// Whether an app matches any entry by any of its identifiers (bundle ID, bundle, display or file name).
    public static func matches(_ list: [String], _ app: AppIdentity) -> Bool {
        let entries = Set(list.map { appKey($0, trimmingWhitespace: true) })
        return ([app.bundleID].compactMap { $0 } + app.names).contains { entries.contains(appKey($0, trimmingWhitespace: true)) }
    }

    /// Why agents may not see or drive this app, or nil if they may. The app's installed bundle is looked up, so an
    /// entry written as a name catches the app by bundle ID and the reverse ("Terminal" denies com.apple.Terminal).
    public func refusal(bundleID: String?, name: String?) -> String? {
        refusal(AppIdentity.of(bundleID: bundleID, name: name))
    }

    /// Why agents may not see, drive or open with the app at this bundle URL, or nil if they may.
    public func refusal(appAt url: URL) -> String? {
        refusal(AppIdentity(bundleURL: url))
    }

    public func refusal(_ app: AppIdentity) -> String? {
        let label = app.label
        if SessionSafety.isSessionApp(bundleID: app.bundleID, name: nil)
            || app.names.contains(where: { SessionSafety.isSessionApp(bundleID: nil, name: $0) }) {
            return SessionSafety.refusal
        }
        if app.bundleID?.lowercased() == Paths.bundleID.lowercased() {
            return "Refused: that is MacMCP itself. A person controls it with the mac-mcp command."
        }
        if Policy.matches(denyApps, app) {
            return "Refused by policy: \(label) is on the deny list (\(Policy.fileRef))."
        }
        if !allowApps.isEmpty, !Policy.matches(allowApps, app) {
            return "Refused by policy: \(label) is not in allow_apps (\(Policy.fileRef))."
        }
        return nil
    }

    /// Whether an app may be seen and driven.
    public func permits(bundleID: String?, name: String?) -> Bool { refusal(bundleID: bundleID, name: name) == nil }
}

/// Foundation validates syntax; this walk rejects ambiguous objects before either parser's values are trusted.
/// Policy files are UTF-8. Object keys are decoded, so escaped spellings and Unicode forms cannot hide duplicates.
private struct PolicyJSON {
    let bytes: [UInt8]
    var index = 0

    static func validate(_ data: Data) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        guard String(data: data, encoding: .utf8) != nil else { throw Policy.DecodeFailure(why: "policy JSON must be UTF-8") }
        var scanner = PolicyJSON(bytes: Array(data))
        if scanner.bytes.starts(with: [0xef, 0xbb, 0xbf]) { scanner.index = 3 }
        try scanner.value()
        // decodeIfPresent treats null like an absent key. Only the optional webhook may explicitly be null.
        func checkNulls(_ object: Any, path: String = "") throws {
            guard let object = object as? [String: Any] else { return }
            for (key, value) in object {
                let field = path.isEmpty ? key : path + "." + key
                if value is NSNull, field != "alert_webhook",
                   PolicyDiff.modelled.contains(field) || ["script", "web", "shortcuts"].contains(field) {
                    throw Policy.DecodeFailure(why: "\(field): null is not a valid setting")
                }
                try checkNulls(value, path: field)
            }
        }
        try checkNulls(json)
    }

    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw Policy.DecodeFailure(why: "expected a JSON string") }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 { index += 1 }
            else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
        }
        throw Policy.DecodeFailure(why: "unterminated JSON string")
    }

    mutating func value() throws {
        whitespace()
        guard index < bytes.count else { throw Policy.DecodeFailure(why: "missing JSON value") }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 || bytes[index] == 91 {
            let object = bytes[index] == 123
            let end: UInt8 = object ? 125 : 93
            var keys = Set<String>()
            index += 1
            whitespace()
            if index < bytes.count, bytes[index] == end { index += 1; return }
            while index < bytes.count {
                if object {
                    whitespace()
                    let key = try string()
                    guard keys.insert(key).inserted else { throw Policy.DecodeFailure(why: "duplicate JSON key: \(key)") }
                    whitespace()
                    index += 1 // colon (syntax was already validated)
                }
                try value()
                whitespace()
                if index < bytes.count, bytes[index] == end { index += 1; return }
                index += 1 // comma
            }
        } else {
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        }
    }
}
