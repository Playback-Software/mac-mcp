import AppKit
import Foundation

/// Runs AppleScript or JXA for agents, gated by policy.
///
/// Scripts reach apps through their scripting dictionaries, often far more reliable and cheaper than GUI clicks.
/// The policy names which apps a script may target. Shell access is out of scope for this tool (decision, Phase 1),
/// so `do shell script`, raw Apple events and the Objective-C bridges are refused, and AppleScript must name its target
/// apps literally so the policy can check them. JXA can't be filtered that way (computed property names reach
/// anything), so it runs only when the policy opts in (`script.jxa`). This is a filter, not a sandbox.
public enum Scripts {
    public enum Language: String, Sendable, CaseIterable {
        case applescript, jxa
        var osaName: String { self == .applescript ? "AppleScript" : "JavaScript" }
    }

    /// Apps a script addresses: `tell application "X"`, `application id "…"`, `Application("X")`.
    public static func targets(of source: String, language: Language) -> [String] {
        let patterns = language == .applescript
            ? [#"application\s+id\s+"([^"]+)""#, #"application\s+"([^"]+)""#, #"app\s+"([^"]+)""#]
            : [#"Application\(\s*["']([^"']+)["']\s*\)"#]
        var found: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let r = Range(m.range(at: 1), in: source) { found.append(String(source[r])) }
            }
        }
        return Array(Set(found)).sorted()
    }

    /// Constructs that would turn this into a shell or arbitrary-code tool, or reach an app the policy can't see.
    public static func forbiddenConstruct(in source: String, language: Language) -> String? {
        // Checked on code only (strings emptied, comments dropped), lowercased, with line continuations and runs of
        // whitespace collapsed, so `do  shell¬\n script` reads as `do shell script`.
        let code = code(of: source, language: language).lowercased()
            .replacingOccurrences(of: #"¬\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        switch language {
        case .applescript:
            for s in ["do shell script", "run script", "load script", "store script", "use framework"] where code.contains(s) {
                return s
            }
            // Raw syntax names any event or app by code: «event sysoexec» is do shell script, «class capp» is application.
            if code.contains("«event") || code.contains("«class capp") { return "«event» / «class capp» raw syntax" }
            // A target the policy can't read: tell application someVariable, application (a & b)'s window 1.
            let dynamicTarget = #"(?<!current )(?<!frontmost )\b(application|app) (?!"|id "|process|file|responses|support|«)[a-z0-9_(|]"#
            if code.range(of: dynamicTarget, options: .regularExpression) != nil {
                return "an app named by a variable or expression (name it literally: tell application \"Name\")"
            }
        case .jxa:
            for s in ["doshellscript", "objc.", "$.", "require("] where code.contains(s) { return s }
        }
        return nil
    }

    /// The script with string literals emptied and comments blanked, so checks see only code: a phrase in a string or
    /// comment doesn't trip them, and a quote inside a comment can't hide code from them.
    /// AppleScript: strings are "…" (may span lines); comments are `--` or `#` to the end of the line, and nestable
    /// `(* … *)`; `|…|` identifiers and `«…»` raw codes are kept as they are.
    /// JXA: strings are '…' or "…" (ending at a line break, as in JavaScript); template literals are kept as code;
    /// comments are `//` and `/* … */`. (A regular-expression literal can confuse this; JXA is opt-in for that reason.)
    public static func code(of source: String, language: Language) -> String {
        let c = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func at(_ k: Int) -> Unicode.Scalar? { k < c.count ? c[k] : nil }
        func skipString(_ quote: Unicode.Scalar, stopAtNewline: Bool) {
            out.append(quote); out.append(quote)
            i += 1
            while i < c.count, c[i] != quote {
                if stopAtNewline, c[i] == "\n" { return }
                i += c[i] == "\\" ? 2 : 1
            }
            i += 1
        }
        func skipLine() { while i < c.count, c[i] != "\n" { i += 1 } }
        func copy(until close: Unicode.Scalar) {
            out.append(c[i]); i += 1
            while i < c.count, c[i] != close { out.append(c[i]); i += 1 }
            if i < c.count { out.append(c[i]); i += 1 }
        }
        while i < c.count {
            let ch = c[i], next = at(i + 1)
            switch language {
            case .applescript:
                if ch == "\"" { skipString("\"", stopAtNewline: false) }
                else if ch == "-" && next == "-" || ch == "#" { out.append(" "); skipLine() }
                else if ch == "(" && next == "*" {
                    var depth = 0
                    while i < c.count {
                        if c[i] == "(", at(i + 1) == "*" { depth += 1; i += 2 }
                        else if c[i] == "*", at(i + 1) == ")" { depth -= 1; i += 2; if depth == 0 { break } }
                        else { i += 1 }
                    }
                    out.append(" ")
                }
                else if ch == "|" { copy(until: "|") }
                else if ch == "«" { copy(until: "»") }
                else { out.append(ch); i += 1 }
            case .jxa:
                if ch == "\"" || ch == "'" { skipString(ch, stopAtNewline: true) }
                else if ch == "`" { copy(until: "`") }
                else if ch == "/" && next == "/" { out.append(" "); skipLine() }
                else if ch == "/" && next == "*" {
                    i += 2
                    while i < c.count, !(c[i] == "*" && at(i + 1) == "/") { i += 1 }
                    i += 2
                    out.append(" ")
                }
                else { out.append(ch); i += 1 }
            }
        }
        return String(out)
    }

    /// Bundle ID for a script target ("TextEdit", "com.apple.finder"), or nil if no such app is installed.
    public static func bundleID(for target: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) != nil ? target
            : Apps.bundleURL(for: target).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Checks a script against the policy. Returns nil if allowed, else why not.
    public static func refusal(source: String, language: Language, policy: Policy) -> String? {
        if let bad = forbiddenConstruct(in: source, language: language) {
            return "Refused: `\(bad)` is not allowed in mac_script (no shell or arbitrary code; AppleScript/JXA app automation only)."
        }
        if let refusal = SessionSafety.refusal(script: source, language: language) { return refusal }
        if policy.script.allowedApps.isEmpty {
            // Scripting is off until a person allows an app, including scripts that name no app at all.
            return "Refused: mac_script is off. A person can turn it on by listing the apps scripts may control in "
                + "script.allowed_apps in \(Paths.policyFile). Until then, use the GUI tools."
        }
        if language == .jxa, !policy.script.jxa {
            return "Refused: JXA is off (its computed property names can reach anything, so it can't be filtered). Use "
                + "AppleScript, or a person can set script.jxa to true in \(Paths.policyFile)."
        }
        if !policy.clipboardRead, code(of: source, language: language).lowercased().contains("the clipboard") {
            return "Refused by policy: clipboard_read is false, and this script uses the clipboard."
        }
        for target in targets(of: source, language: language) {
            let bundleID = bundleID(for: target)
            if let refusal = policy.refusal(bundleID: bundleID, name: target) { return refusal }
            if !Policy.matches(policy.script.allowedApps, bundleID: bundleID, name: target) {
                return "Refused: mac_script may not control \(target). A person can allow it by adding \"\(bundleID ?? target)\" "
                    + "to script.allowed_apps in \(Paths.policyFile). Until then, use the GUI tools."
            }
        }
        return nil
    }

    /// Whether macOS lets MacMCP send Apple events to an app: the Automation grant (TCC), which belongs to the agent
    /// (MacMCP.app) as the responsible process for the osascript children it runs.
    public enum AutomationGrant: Equatable, Sendable {
        case granted, denied, notAsked, notRunning
        /// macOS didn't answer in time (seen with Notes just after a background launch).
        case undetermined
        case unknown(OSStatus)

        public init(status: OSStatus) {
            switch Int(status) {
            case Int(noErr): self = .granted
            case errAEEventNotPermitted: self = .denied
            case errAEEventWouldRequireUserConsent: self = .notAsked
            case procNotFound: self = .notRunning
            default: self = .unknown(status)
            }
        }

        /// Why a script for `app` must not run, or nil if it may. Running it anyway would raise a consent prompt that
        /// nobody answers on an unattended Mac, and the script would time out.
        public func refusal(app: String) -> String? {
            let settings = "System Settings ▸ Privacy & Security ▸ Automation ▸ MacMCP"
            switch self {
            case .denied:
                return "MacMCP is not authorized to control \(app). A person must approve it once: enable \(app) in \(settings) "
                    + "(macOS won't ask again once denied). Until then, use the GUI tools."
            case .notAsked:
                return "MacMCP is not authorized to control \(app): macOS has never asked for consent, and asking would raise "
                    + "a prompt that a person must answer at the screen. A person must approve it once: while someone is at the "
                    + "screen, run any mac_script for \(app) with request_consent: true and approve the prompt; it then "
                    + "appears in \(settings). Until then, use the GUI tools."
            case .granted, .notRunning, .undetermined, .unknown:
                return nil
            }
        }

        /// Short state for mac_doctor.
        public var summary: String {
            switch self {
            case .granted: "granted"
            case .denied: "NOT GRANTED — enable it in System Settings ▸ Privacy & Security ▸ Automation ▸ MacMCP"
            case .notAsked: "not yet asked — a person must approve the first mac_script (request_consent: true) at the screen"
            case .notRunning: "not running (can't check until it is)"
            case .undetermined: "couldn't check (macOS didn't answer within 3 s)"
            case let .unknown(status): "unknown (OSStatus \(status))"
            }
        }

        public var isProblem: Bool { self == .denied || self == .notAsked }
    }

    /// Asks TCC, without ever prompting, whether MacMCP may send Apple events to the app. Must run in the agent.
    ///
    /// `AEDeterminePermissionToAutomateTarget` can block indefinitely: it waits on a semaphore inside AE (seen with
    /// Notes right after a background launch). It runs on a GCD thread and is given up on after `timeout`, so a stuck
    /// call costs one GCD thread instead of a cooperative-pool thread for good.
    public static func automationGrant(bundleID: String, timeout: TimeInterval = 3) async -> AutomationGrant {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let grant = automationGrantBlocking(bundleID: bundleID)
                if once.claim() { continuation.resume(returning: grant) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .undetermined) }
            }
        }
    }

    static func automationGrantBlocking(bundleID: String) -> AutomationGrant {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown(OSStatus(paramErr)) }
        return AutomationGrant(status: AEDeterminePermissionToAutomateTarget(
            desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false))
    }

    /// Checks the Automation grant for every app a script targets, launching (in the background) any that isn't
    /// running so it can be checked; osascript would launch it anyway. Returns the first refusal, or nil.
    public static func automationRefusal(source: String, language: Language, requestConsent: Bool) async -> String? {
        for target in targets(of: source, language: language) {
            guard let bundleID = bundleID(for: target) else { continue }   // not installed: osascript reports it
            var grant = await automationGrant(bundleID: bundleID)
            if grant == .notRunning, await launchQuietly(bundleID: bundleID) {
                for _ in 0..<20 where grant == .notRunning {
                    grant = await automationGrant(bundleID: bundleID)
                    if grant == .notRunning { try? await Task.sleep(for: .milliseconds(100)) }
                }
            }
            if grant == .notAsked, requestConsent { continue }   // osascript raises the prompt for the person
            let name = (try? Apps.resolve(bundleID).name) ?? target
            if let refusal = grant.refusal(app: name) { return refusal }
        }
        return nil
    }

    /// Starts an app without activating it and waits (≤5 s) for it to finish launching. Returns whether it's running.
    static func launchQuietly(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        _ = try? await withDeadline(10) {
            let c = NSWorkspace.OpenConfiguration()
            c.activates = false
            try Task.checkCancellation()
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: c)
            return true
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: \.isFinishedLaunching) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
        public let timedOut: Bool
    }

    /// Runs via /usr/bin/osascript (a child of the agent, so Automation consent is attributed to MacMCP) with a hard timeout.
    public static func run(_ source: String, language: Language, timeout: TimeInterval) async throws -> Output {
        let r = try await Subprocess.run("/usr/bin/osascript", ["-l", language.osaName, "-"], input: Data(source.utf8), timeout: timeout)
        return Output(stdout: r.stdout, stderr: r.stderr, status: r.status, timedOut: r.timedOut)
    }
}
