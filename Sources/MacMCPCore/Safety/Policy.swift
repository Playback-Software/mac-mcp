import AppKit
import Foundation

/// `~/.config/mac-mcp/policy.json`: what agents may touch. Re-read on every check, so edits apply immediately.
/// Missing keys take their defaults, so older files keep working.
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

        enum CodingKeys: String, CodingKey { case allowedApps = "allowed_apps", timeoutSeconds = "timeout_seconds", jxa }

        public init(allowedApps: [String], timeoutSeconds: Int, jxa: Bool = false) {
            self.allowedApps = allowedApps
            self.timeoutSeconds = timeoutSeconds
            self.jxa = jxa
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allowedApps = try c.decodeIfPresent([String].self, forKey: .allowedApps) ?? []
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
            jxa = try c.decodeIfPresent(Bool.self, forKey: .jxa) ?? false
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

        /// Whether a shortcut (by name or identifier) is on the list.
        public func allows(name: String, identifier: String? = nil) -> Bool {
            let entries = Set(allowed.map { $0.lowercased() })
            return entries.contains(name.lowercased()) || identifier.map { entries.contains($0.lowercased()) } == true
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
            let dots = CharacterSet(charactersIn: ".")
            let host = host.lowercased().trimmingCharacters(in: dots)
            return entries.map { entry -> String in
                let e = entry.lowercased().trimmingCharacters(in: .whitespaces)
                return (e.contains("://") ? URL(string: e)?.host ?? e : e).trimmingCharacters(in: dots)
            }
            .contains { !$0.isEmpty && (host == $0 || host.hasSuffix("." + $0)) }
        }

        /// Why web_* may not open or act on this URL, or nil if it may. Only http(s) and about:blank are allowed:
        /// file: and data: URLs would let a page tool read local files or run arbitrary content.
        public func refusal(url string: String) -> String? {
            guard enabled else { return "Refused by policy: web tools are turned off (web.enabled in \(Paths.policyFile))." }
            if string == "about:blank" { return nil }
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else {
                return "Refused: web tools only open http(s) URLs (got \(string.prefix(80)))."
            }
            if WebPolicy.covers(denyHosts, host: host) {
                return "Refused by policy: \(host) is on web.deny_hosts (\(Paths.policyFile))."
            }
            if !allowPrivateHosts, WebPolicy.isPrivate(host: host), !WebPolicy.covers(allowHosts, host: host) {
                return "Refused by policy: \(host) is this Mac or a private-network address. A person can allow it with "
                    + "web.allow_private_hosts, or by listing it in web.allow_hosts (\(Paths.policyFile))."
            }
            if !allowHosts.isEmpty, !WebPolicy.covers(allowHosts, host: host) {
                return "Refused by policy: \(host) is not in web.allow_hosts (\(Paths.policyFile))."
            }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case denyApps = "deny_apps", allowApps = "allow_apps", script, web, shortcuts, clipboardRead = "clipboard_read"
        case rateLimitPerSecond = "rate_limit_per_second", alertWebhook = "alert_webhook", alertCooldownMinutes = "alert_cooldown_minutes"
    }

    /// Apps that would hand an agent what the other tools withhold: a shell (Terminal, iTerm2, Script Editor,
    /// Automator, the Shortcuts editor), stored secrets (Keychain Access, Passwords), or this Mac's security settings.
    /// A person who wants agents in one of them removes it from deny_apps.
    public static let defaultDenyApps = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2", "com.apple.Automator",
        "com.apple.shortcuts", "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences",
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
        public var description: String {
            switch self {
            case let .invalid(path, why):
                "POLICY INVALID: \(path) could not be read (\(why)). Agents are blocked until a person fixes it; "
                    + "`mac-mcp doctor` shows the details."
            }
        }
    }

    /// The current policy. A missing file means the defaults; an unreadable one is an error rather than a silent
    /// fallback, so a typo can't quietly drop someone's deny list.
    public static func current(path: String = Paths.policyFile) -> Result<Policy, LoadError> {
        guard let data = FileManager.default.contents(atPath: path) else {
            // Only a file that isn't there means the defaults; one that exists but can't be read must not fail open.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .success(defaults) }
            return .failure(.invalid(path, isDirectory.boolValue ? "it is a directory" : "it exists but can't be read"))
        }
        do { return .success(try JSONDecoder().decode(Policy.self, from: data)) } catch {
            let why: String
            switch error {
            case let DecodingError.dataCorrupted(ctx): why = ctx.debugDescription + (ctx.underlyingError.map { ": \($0.localizedDescription)" } ?? "")
            case let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx): why = "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            default: why = "\(error)"
            }
            return .failure(.invalid(path, why))
        }
    }

    /// The current policy, or the defaults if invalid (for non-gating uses such as reading timeouts).
    public static func load(path: String = Paths.policyFile) -> Policy {
        (try? current(path: path).get()) ?? defaults
    }

    /// Writes the default policy if none exists. Returns true if it wrote one.
    @discardableResult
    public static func writeDefaultIfMissing(path: String = Paths.policyFile) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try encoder.encode(defaults).write(to: URL(fileURLWithPath: path))
        return true
    }

    /// Whether an app (bundle ID and/or name) matches any entry in a list (bundle IDs or names, case-insensitive).
    public static func matches(_ list: [String], bundleID: String?, name: String?) -> Bool {
        let entries = Set(list.map { $0.lowercased() })
        return [bundleID, name].compactMap { $0?.lowercased() }.contains(where: entries.contains)
    }

    /// Why agents may not see or drive this app, or nil if they may.
    public func refusal(bundleID: String?, name: String?) -> String? {
        let label = name ?? bundleID ?? "this app"
        if SessionSafety.isSessionApp(bundleID: bundleID, name: name) { return SessionSafety.refusal }
        if Policy.matches(denyApps, bundleID: bundleID, name: name) {
            return "Refused by policy: \(label) is on the deny list (\(Paths.policyFile))."
        }
        if !allowApps.isEmpty, !Policy.matches(allowApps, bundleID: bundleID, name: name) {
            return "Refused by policy: \(label) is not in allow_apps (\(Paths.policyFile))."
        }
        return nil
    }

    /// Whether an app may be seen and driven.
    public func permits(bundleID: String?, name: String?) -> Bool { refusal(bundleID: bundleID, name: name) == nil }
}
