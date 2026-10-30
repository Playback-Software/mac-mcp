import AppKit
import ApplicationServices
import Foundation
import MachO

/// App automation with a source preflight and an Apple-event gate in a disposable signed host.
public enum Scripts {
    public enum Language: String, Sendable, CaseIterable {
        case applescript, jxa
        var osaName: String { self == .applescript ? "AppleScript" : "JavaScript" }
    }

    enum Token: Equatable {
        case word(String), string(String), symbol(String), raw(String)
    }

    /// A single lexer feeds both target discovery and command checks. Comments and continuations separate tokens;
    /// strings retain their decoded values, but never contribute command words.
    static func lex(_ source: String, language: Language) -> (tokens: [Token], code: String) {
        let c = Array(source.unicodeScalars)
        var tokens: [Token] = [], code = "", i = 0
        func at(_ n: Int) -> Unicode.Scalar? { n < c.count ? c[n] : nil }
        func wordCharacter(_ ch: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(ch) || ch == "_" || ch == "$"
        }
        func lineComment() {
            while i < c.count, c[i] != "\n", c[i] != "\r" { i += 1 }
            code += " "
        }
        while i < c.count {
            let ch = c[i], next = at(i + 1)
            if language == .applescript, ch == "¬" { code += " "; i += 1; continue }
            if language == .applescript, (ch == "-" && next == "-" || ch == "#") { lineComment(); continue }
            if language == .jxa, ch == "/", next == "/" { lineComment(); continue }
            let block = language == .applescript ? (ch == "(" && next == "*") : (ch == "/" && next == "*")
            if block {
                var depth = 1
                var quoted = false
                i += 2
                while i < c.count, depth > 0 {
                    if language == .applescript, c[i] == "\\", quoted { i += min(2, c.count - i) }
                    else if language == .applescript, c[i] == "\"" { quoted.toggle(); i += 1 }
                    else if !quoted, language == .applescript, c[i] == "(", at(i + 1) == "*" { depth += 1; i += 2 }
                    else if !quoted, c[i] == "*", at(i + 1) == (language == .applescript ? ")" : "/") { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                code += " "
                continue
            }
            if ch == "\"" || language == .jxa && ch == "'" {
                let quote = ch
                var value = ""
                i += 1
                while i < c.count, c[i] != quote {
                    if language == .jxa, c[i] == "\n" || c[i] == "\r" { break }
                    if c[i] == "\\", let escaped = at(i + 1) {
                        value.unicodeScalars.append(escaped); i += 2
                    } else { value.unicodeScalars.append(c[i]); i += 1 }
                }
                if at(i) == quote { i += 1 }
                tokens.append(.string(value)); code += String(quote) + String(quote)
                continue
            }
            if language == .applescript, ch == "<", next == "<" {
                var value = "<<"
                i += 2
                while i < c.count {
                    if c[i] == ">", at(i + 1) == ">" { value += ">>"; i += 2; break }
                    value.unicodeScalars.append(c[i]); i += 1
                }
                tokens.append(.raw(value.lowercased())); code += value
                continue
            }
            if language == .applescript, ch == ">", next == ">" {
                tokens.append(.raw(">>")); code += ">>"; i += 2
                continue
            }
            if ch == "«" || ch == "|" && language == .applescript || ch == "`" && language == .jxa {
                let close: Unicode.Scalar = ch == "«" ? "»" : ch
                var value = String(ch)
                i += 1
                var decoded = ""
                while i < c.count, c[i] != close {
                    if ch == "|", c[i] == "\\", let escaped = at(i + 1) {
                        value += "\\" + String(escaped); decoded.unicodeScalars.append(escaped); i += 2
                    } else {
                        value.unicodeScalars.append(c[i]); decoded.unicodeScalars.append(c[i]); i += 1
                    }
                }
                if i < c.count { value.unicodeScalars.append(c[i]); i += 1 }
                code += value
                if ch == "|" { tokens.append(.word(decoded.lowercased())) }
                else { tokens.append(.raw(value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " "))) }
                continue
            }
            if wordCharacter(ch) {
                var value = ""
                while i < c.count, wordCharacter(c[i]) { value.unicodeScalars.append(c[i]); i += 1 }
                tokens.append(.word(value.lowercased())); code += value
            } else {
                if !CharacterSet.whitespacesAndNewlines.contains(ch) { tokens.append(.symbol(String(ch))) }
                code.unicodeScalars.append(ch); i += 1
            }
        }
        return (tokens, code)
    }

    static func contains(_ words: [String], in tokens: [Token]) -> Bool {
        guard tokens.count >= words.count else { return false }
        let wanted = words.map(Token.word)
        return (0...(tokens.count - wanted.count)).contains { Array(tokens[$0..<($0 + wanted.count)]) == wanted }
    }

    public static func targets(of source: String, language: Language) -> [String] {
        let t = lex(source, language: language).tokens
        var found: Set<String> = []
        for i in t.indices {
            if language == .applescript, t[i] == .word("application") || t[i] == .word("app") {
                var j = i + 1
                if j < t.count, t[j] == .word("id") { j += 1 }
                if j < t.count, case let .string(name) = t[j] { found.insert(name) }
            }
            if language == .jxa, t[i] == .word("application"), i + 2 < t.count, t[i + 1] == .symbol("("),
               case let .string(name) = t[i + 2] { found.insert(name) }
        }
        return found.sorted()
    }

    static func processTargets(_ t: [Token]) -> [String] {
        t.indices.compactMap { i in
            guard t[i] == .word("process"), i + 1 < t.count, case let .string(name) = t[i + 1] else { return nil }
            return name
        }
    }

    /// Source checks are an early refusal; the host also checks actual events, including events sent to itself.
    public static func forbiddenConstruct(in source: String, language: Language) -> String? {
        let t = lex(source, language: language).tokens
        if language == .applescript {
            for phrase in ["do shell script", "run script", "load script", "store script",
                           "open for access", "set eof", "get eof", "close access", "open location",
                           "display dialog", "display alert", "system attribute", "info for", "list folder", "mount volume"] {
                if contains(phrase.components(separatedBy: " "), in: t) { return phrase }
            }
            for token in t {
                if case let .raw(raw) = token,
                   raw.hasPrefix("<<") || raw == ">>" || raw.hasPrefix("«event") || raw.hasPrefix("«data")
                    || ["capp", "pcap", "prcs", "pcda"].contains(where: { raw.hasPrefix("«class " + $0) }) {
                    return "raw data, event or app/process syntax"
                }
            }
            for i in t.indices {
                if t[i] == .word("use") {
                    if i + 3 < t.count, t[i + 1] == .word("applescript"), t[i + 2] == .word("version"), case .string = t[i + 3] { continue }
                    if i + 2 < t.count, t[i + 1] == .word("scripting"), t[i + 2] == .word("additions") { continue }
                    return i + 1 < t.count && t[i + 1] == .word("framework") ? "use framework" : "use (only AppleScript version and scripting additions are allowed)"
                }
                if t[i] == .word("script"), i + 1 < t.count {
                    if case .string = t[i + 1] { return "script library specifier" }
                    if t[i + 1] == .word("id") || t[i + 1] == .symbol("(") || i > 0 && t[i - 1] == .word("tell") {
                        return "script library specifier"
                    }
                }
                if t[i] == .word("current"), i + 1 < t.count,
                   [.word("application"), .word("app")].contains(t[i + 1]) {
                    return "current application native access"
                }
                if t[i] == .word("processes") { return "process collections (name each process literally)" }
            }
            for i in t.indices where t[i] == .word("application") || t[i] == .word("app") || t[i] == .word("process") {
                if i > 0, [.word("current"), .word("frontmost")].contains(t[i - 1]) { continue }
                if t[i] == .word("process"), i > 0 {
                    let j = t[i - 1] == .word("application") ? i - 2 : i - 1
                    if j >= 0, [.word("every"), .word("each")].contains(t[j]) {
                        return "process collections (name each process literally)"
                    }
                }
                var j = i + 1
                if j < t.count, t[j] == .word("id") { j += 1 }
                if j < t.count, case .string = t[j] { continue }
                if t[i] != .word("process"), j < t.count,
                   [.word("process"), .word("processes"), .word("file"), .word("files"), .word("responses"), .word("support")].contains(t[j]) { continue }
                return "an app or process named by an expression (name it literally: tell application \"Name\")"
            }
        } else {
            for (words, label) in [(["doshellscript"], "doshellscript"), (["objc"], "objc."), (["$"], "$."),
                                   (["require"], "require("), (["clipboard"], "clipboard"), (["systemattribute"], "system attribute"),
                                   (["includeStandardAdditions".lowercased()], "Standard Additions")] {
                if contains(words, in: t) { return label }
            }
            for i in t.indices where t[i] == .word("application") {
                if i + 2 < t.count, t[i + 1] == .symbol("."), t[i + 2] == .word("currentapplication") { continue }
                guard i + 3 < t.count, t[i + 1] == .symbol("("), case .string = t[i + 2], t[i + 3] == .symbol(")") else {
                    return "an app named by an expression (use Application(\"Name\"))"
                }
            }
            if t.contains(where: { if case .raw = $0 { true } else { false } }) { return "template literals or raw syntax" }
        }
        return nil
    }

    public static func code(of source: String, language: Language) -> String { lex(source, language: language).code }

    /// Bundle ID for a script target ("TextEdit", "com.apple.finder"), or nil if no such app is installed.
    public static func bundleID(for target: String) -> String? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) ?? Apps.bundleURL(for: target)
        return url.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Checks a script against the policy. Returns nil if allowed, else why not.
    public static func refusal(source: String, language: Language, policy: Policy) -> String? {
        if language == .jxa, !policy.script.jxa {
            return "Refused: JXA is off. Use AppleScript, or ask a person to enable script.jxa."
        }
        let tokens = lex(source, language: language).tokens
        if let bad = forbiddenConstruct(in: source, language: language) {
            return "Refused: `\(bad)` is not allowed in mac_script (no shell or arbitrary code; AppleScript/JXA app automation only)."
        }
        if let refusal = SessionSafety.refusal(script: source, language: language) { return refusal }
        if policy.script.allowedApps.isEmpty {
            // Scripting is off until a person allows an app, including scripts that name no app at all.
            return "Refused: mac_script is off. A person can turn it on by listing the apps scripts may control in "
                + "script.allowed_apps in \(Paths.policyFile). Until then, use the GUI tools."
        }
        let targets = targets(of: source, language: language)
        guard !targets.isEmpty else { return "Refused: name the app: tell application \"Name\"." }
        for target in targets {
            let bundleID = bundleID(for: target)
            if WindowServer.isPromptProcess(bundleID: bundleID, executablePath: nil, name: target) {
                return "Refused: mac_script cannot control a macOS security or permission prompt process. Use the GUI tools."
            }
            if let refusal = policy.refusal(bundleID: bundleID, name: target) { return refusal }
            if isSystemEvents(bundleID: bundleID, name: target), !policy.script.allowSystemEvents {
                return "Refused: System Events needs script.allow_system_events: true as well as script.allowed_apps. Use the GUI tools."
            }
            if !Policy.matches(policy.script.allowedApps, bundleID: bundleID, name: target) {
                return "Refused: mac_script may not control \(target). A person can allow it in script.allowed_apps. Use the GUI tools."
            }
        }
        for target in processTargets(tokens) {
            if WindowServer.isPromptProcess(bundleID: bundleID(for: target), executablePath: nil, name: target) {
                return "Refused: mac_script cannot control a macOS security or permission prompt process. Use the GUI tools."
            }
            if let refusal = policy.refusal(bundleID: bundleID(for: target), name: target) { return refusal }
        }
        return nil
    }

    static func isSystemEvents(bundleID: String?, name: String?) -> Bool {
        bundleID?.lowercased() == "com.apple.systemevents" || name?.lowercased() == "system events"
    }

    public static func broadAccessWarning(for target: String) -> String? {
        let id = bundleID(for: target)?.lowercased() ?? target.lowercased()
        let risky = ["com.apple.finder", "finder", "com.apple.systemevents", "system events", "com.apple.terminal", "terminal",
                     "com.googlecode.iterm2", "iterm2", "com.apple.scripteditor2", "script editor", "com.apple.safari", "safari"]
        return risky.contains(id) ? "\(target) can reach any file or app, equivalent to a shell. Allow it only if you trust that access." : nil
    }

    /// Whether macOS lets MacMCP send Apple events to an app: the Automation grant (TCC), which belongs to the agent
    /// (MacMCP.app), whose executable also runs the disposable script host.
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

    private static let permissionThreads = DedicatedThreads(name: "automation-permission", count: 2)
    private static let permissionTimer = DedicatedThreads(name: "automation-permission-timeout")

    /// Asks TCC, without ever prompting, whether MacMCP may send Apple events to the app. Must run in the agent.
    ///
    /// `AEDeterminePermissionToAutomateTarget` can block indefinitely: it waits on a semaphore inside AE (seen with
    /// Notes right after a background launch). Two native threads bound the cost of stuck calls; a separate timer
    /// returns an undetermined grant even when both are occupied. Expired queued checks never start.
    public static func automationGrant(bundleID: String, timeout: TimeInterval = 3) async -> AutomationGrant {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var isPending: Bool { lock.withLock { !done } }
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            permissionThreads.async {
                guard once.isPending else { return }
                let grant = automationGrantBlocking(bundleID: bundleID)
                if once.claim() { continuation.resume(returning: grant) }
            }
            permissionTimer.async(after: timeout) {
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

    struct RunningApplication {
        let pid: pid_t
        let finishedLaunching: Bool
    }

    static func runningApplications(bundleID: String) -> [RunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }.map {
            RunningApplication(pid: $0.processIdentifier, finishedLaunching: $0.isFinishedLaunching)
        }
    }

    static func runningRefusal(_ apps: [RunningApplication]) -> String? {
        guard apps.count == 1, apps.allSatisfy(\.finishedLaunching) else {
            return "Refused: the target app must already be running and finished launching in a single process. A person must open it before mac_script can control it."
        }
        return nil
    }

    /// Checks Automation without launching apps: restoration must finish before the document gate can inspect it.
    public static func automationRefusal(source: String, language: Language, requestConsent: Bool) async -> String? {
        for target in targets(of: source, language: language) {
            guard let bundleID = bundleID(for: target) else { continue }   // not installed: the script host reports it
            if let refusal = runningRefusal(runningApplications(bundleID: bundleID)) { return refusal }
            let grant = await automationGrant(bundleID: bundleID)
            if grant == .notRunning { return ScriptDocuments.Check.unavailable.refusal }
            if grant == .notAsked, requestConsent { continue }   // the host raises the prompt for the person
            let name = (try? Apps.resolve(bundleID).name) ?? target
            if let refusal = grant.refusal(app: name) { return refusal }
        }
        return nil
    }

    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
        public let timedOut: Bool
    }

    /// The same signed executable runs a hidden host mode before agent startup (no agent services, prompts or monitors).
    /// The parent owns the hard deadline and kills the host on timeout or cancellation.
    public static func run(_ source: String, language: Language, timeout: TimeInterval, policy: Policy? = nil,
                           requestConsent: Bool = false) async throws -> Output {
        guard let host = hostExecutable else { throw CocoaError(.executableNotLoadable) }
        let start = ContinuousClock.now
        var request = ScriptHost.Request(source: source, language: language.rawValue, policy: policy ?? Policy(), requestConsent: requestConsent)
        if language == .applescript {
            request.phase = .compile
            let compiled = try await Subprocess.run(host.path, [ScriptHost.argument], input: try JSONEncoder().encode(request), timeout: timeout)
            guard compiled.status == 0, !compiled.timedOut else { return hostOutput(compiled) }
            let canonical = try JSONDecoder().decode(ScriptHost.Compilation.self, from: Data(compiled.stdout.utf8)).source
            if let refusal = ScriptHost.sourceRefusal(canonical, language: language) {
                return Output(stdout: "", stderr: refusal, status: ScriptHost.refusalStatus, timedOut: false)
            }
            request = ScriptHost.Request(source: canonical, language: language.rawValue, policy: policy ?? Policy(), requestConsent: requestConsent)
        }
        try Task.checkCancellation()
        let documents = try ScriptDocumentGate()
        defer { documents.stop() }
        for target in targets(of: request.source, language: language) + processTargets(lex(request.source, language: language).tokens) {
            guard let id = bundleID(for: target) else { continue } // The event gate refuses unresolved targets.
            if let refusal = await documents.checkBeforeExecution(bundleID: id).refusal {
                return Output(stdout: "", stderr: refusal, status: ScriptHost.refusalStatus, timedOut: false)
            }
        }
        request.documentGatePath = documents.path
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).components
        let remaining = timeout - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
        guard remaining > 0 else { return Output(stdout: "", stderr: "", status: 1, timedOut: true) }
        let r = try await Subprocess.run(host.path, [ScriptHost.argument], input: try JSONEncoder().encode(request), timeout: remaining)
        return hostOutput(r)
    }

    /// Resolve once from dyld, never from argv[0]. The agent eagerly initializes this before serving requests.
    public static let hostExecutable: URL? = {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            .resolvingSymlinksInPath()
        if executable.lastPathComponent == "MacMCPAgent" { return executable }
        return developmentHostExecutable()
    }()

    static func developmentHostExecutable() -> URL? {
        // SwiftPM's debug runner may live outside the build directory. Release builds never infer a host path.
        #if DEBUG
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/MacMCPAgent")
        #else
        return nil
        #endif
    }

    static func hostOutput(_ r: Subprocess.Output) -> Output {
        if r.status == ScriptHost.refusalStatus {
            let finalLine = r.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let refusal = finalLine.hasPrefix(ScriptHost.refusalMarker)
                ? String(finalLine.dropFirst(ScriptHost.refusalMarker.count)) : "Refused Apple event. Use the GUI tools."
            return Output(stdout: "", stderr: refusal, status: r.status, timedOut: r.timedOut)
        }
        return Output(stdout: r.stdout, stderr: r.stderr, status: r.status, timedOut: r.timedOut)
    }
}

/// The parent holds Accessibility permission; hosts ask it before and after every app event.
/// Only a bundle ID, decision, PID and window/tab counts cross this socket, never document names, URLs or contents.
enum ScriptDocuments {
    enum Check: String, Codable, Sendable {
        case safe, protected, unavailable

        static let unavailableMessage = "Refused: the target app's open documents could not be checked completely through Accessibility. The app must already be running and finished launching, with every window and tab readable. Use the GUI tools."

        var refusal: String? {
            switch self {
            case .safe: nil
            case .protected: "Refused: the target app has a protected document open. A person must close it before mac_script can control the app."
            case .unavailable: Self.unavailableMessage
            }
        }
    }

    struct Inventory: Codable, Equatable, Sendable {
        let pid: pid_t
        let tabsPerWindow: [Int]

        var documentCount: Int { tabsPerWindow.reduce(0) { $0 + max(1, $1) } }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let check: Check
        let inventory: Inventory?

        init(_ check: Check, inventory: Inventory? = nil) { self.check = check; self.inventory = inventory }
    }

    static func check(values: [String]) -> Check {
        for value in values {
            if let paths = ScriptHost.textPaths(value) {
                if paths.contains(where: ScriptEventPolicy.protectedAccess) { return .protected }
            } else if value.hasPrefix("/") || value.hasPrefix("~") || value.lowercased().hasPrefix("file:") {
                return .unavailable
            }
        }
        return .safe
    }

    static func check(bundleID: String) -> Check {
        snapshot(bundleID: bundleID).check
    }

    static func snapshot(bundleID: String) -> Snapshot {
        snapshot(bundleID: bundleID, source: Source<AXElement>(
            applications: { Scripts.runningApplications(bundleID: $0) }, trusted: AXIsProcessTrusted,
            windowCount: { pid in
                guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
                return windows.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }.count
            }, windows: { pid in
                let read = AXElement.application(pid: pid, timeout: 0.2).attribute(reporting: kAXWindowsAttribute)
                guard read.error == nil, let windows = read.value as? [AXUIElement] else { return nil }
                return windows.map(AXElement.init)
            }, read: { element in
                AXUIElementSetMessagingTimeout(element.raw, 0.2)
                return element.read(reporting: [kAXDocumentAttribute, kAXURLAttribute, kAXRoleAttribute, kAXChildrenAttribute, kAXTabsAttribute])
            }, elements: { ($0 as? [AXUIElement])?.map(AXElement.init) }))
    }

    struct Source<Element: Hashable> {
        let applications: (String) -> [Scripts.RunningApplication]
        let trusted: () -> Bool
        let windowCount: (pid_t) -> Int?
        let windows: (pid_t) -> [Element]?
        let read: (Element) -> AXElement.Read?
        let elements: (Any) -> [Element]?
    }

    static func check<Element>(bundleID: String, source: Source<Element>) -> Check {
        snapshot(bundleID: bundleID, source: source).check
    }

    static func snapshot<Element>(bundleID: String, source: Source<Element>) -> Snapshot {
        let apps = source.applications(bundleID)
        guard Scripts.runningRefusal(apps) == nil, source.trusted() else { return Snapshot(.unavailable) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var tabsPerWindow: [Int] = []
        for app in apps {
            guard let windows = source.windows(app.pid), windows.count <= 128,
                  source.windowCount(app.pid) == windows.count else { return Snapshot(.unavailable) }
            for window in windows {
                var queue = [(window, false)], seen: Set<Element> = [], tabs: Set<Element> = [], visited = 0
                while !queue.isEmpty {
                    guard ContinuousClock.now < deadline, visited < 512 else { return Snapshot(.unavailable) }
                    visited += 1
                    let (element, tab) = queue.removeFirst()
                    // A tab may also occur in AXChildren. Recheck it in tab context rather than losing its URL requirement.
                    if !seen.insert(element).inserted, !tab { continue }
                    guard let read = source.read(element), read.errors.isEmpty else { return Snapshot(.unavailable) }
                    var values: [String] = []
                    for key in [kAXDocumentAttribute, kAXURLAttribute] {
                        guard let value = read.values[key] else { continue }
                        if let url = value as? URL { values.append(url.absoluteString) }
                        else if let string = value as? String { values.append(string) }
                        else { return Snapshot(.unavailable) }
                    }
                    if tab, values.isEmpty || values.allSatisfy(\.isEmpty) { return Snapshot(.unavailable) }
                    let result = check(values: values)
                    if result != .safe { return Snapshot(result) }
                    for key in [kAXChildrenAttribute, kAXTabsAttribute] {
                        guard let value = read.values[key] else { continue }
                        guard let children = source.elements(value), children.count <= 512 else { return Snapshot(.unavailable) }
                        let isTab = key == kAXTabsAttribute || read.values[kAXRoleAttribute] as? String == kAXTabGroupRole
                        if isTab { tabs.formUnion(children) }
                        queue += children.map { ($0, isTab) }
                    }
                }
                // Safari's AXDocument only describes its active tab. No readable tab inventory is not proof of safety.
                if bundleID.lowercased() == "com.apple.safari", tabs.isEmpty { return Snapshot(.unavailable) }
                tabsPerWindow.append(tabs.count)
            }
            guard ContinuousClock.now < deadline, source.windowCount(app.pid) == windows.count else { return Snapshot(.unavailable) }
        }
        return Snapshot(.safe, inventory: Inventory(pid: apps[0].pid, tabsPerWindow: tabsPerWindow))
    }
}

final class ScriptDocumentGate: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "com.playbacksoftware.macmcp.script-documents")
    private let inspect: @Sendable (String) -> ScriptDocuments.Snapshot

    convenience init(check: @escaping @Sendable (String) -> ScriptDocuments.Check) throws {
        try self.init(inspect: { ScriptDocuments.Snapshot(check($0)) })
    }

    init(inspect: @escaping @Sendable (String) -> ScriptDocuments.Snapshot = { ScriptDocuments.snapshot(bundleID: $0) }) throws {
        self.inspect = inspect
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mc-script-\(UUID())")
        path = directory.appendingPathComponent("gate").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd: Int32
        do { fd = try UnixSocket.listen(path: path, backlog: 4) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let deadline = StreamIO.now + 3
            guard (try? StreamIO.configure(client)) != nil,
                  let bundleID = try? Self.readLine(client, limit: 1024, deadline: deadline), !bundleID.isEmpty else { return }
            let result = self?.inspect(bundleID) ?? ScriptDocuments.Snapshot(.unavailable)
            guard var data = try? JSONEncoder().encode(result) else { return }
            data.append(10)
            try? StreamIO.writeAll(client, data, deadline: deadline)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func stop() {
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    func checkBeforeExecution(bundleID: String) async -> ScriptDocuments.Check {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.inspect(bundleID).check) }
        }
    }

    deinit { stop() }

    static func query(path: String?, bundleID: String) -> ScriptDocuments.Check {
        snapshot(path: path, bundleID: bundleID).check
    }

    static func snapshot(path: String?, bundleID: String) -> ScriptDocuments.Snapshot {
        guard let path else { return ScriptDocuments.Snapshot(.unavailable) }
        do {
            let deadline = StreamIO.now + 3
            let fd = try UnixSocket.connect(path: path, deadline: deadline)
            defer { close(fd) }
            try StreamIO.configure(fd)
            try StreamIO.writeAll(fd, Data((bundleID + "\n").utf8), deadline: deadline)
            let line = try readLine(fd, limit: 4096, deadline: deadline)
            return try JSONDecoder().decode(ScriptDocuments.Snapshot.self, from: Data(line.utf8))
        } catch { return ScriptDocuments.Snapshot(.unavailable) }
    }

    private static func readLine(_ fd: Int32, limit: Int, deadline: TimeInterval) throws -> String {
        var bytes: [UInt8] = []
        while bytes.count < limit {
            try StreamIO.wait(fd, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count == 1 else { throw CocoaError(.fileReadUnknown) }
            if byte == 10, let line = String(bytes: bytes, encoding: .utf8) { return line }
            bytes.append(byte)
        }
        throw CocoaError(.fileReadTooLarge)
    }
}
