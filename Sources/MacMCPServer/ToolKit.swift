import Foundation
import MacMCPCore

/// Arguments of one tool call, with typed accessors.
public struct ToolArgs: Sendable {
    public let raw: [String: Value]

    public init(_ raw: [String: Value]?) { self.raw = raw ?? [:] }

    public func string(_ key: String) -> String? { raw[key]?.stringValue }
    /// Clamped to ±1e9 so huge or fractional JSON numbers can neither trap the conversion nor overflow later math.
    public func int(_ key: String) -> Int? {
        guard let d = raw[key]?.doubleValue, d.isFinite else { return nil }
        return Int(min(max(d, -1e9), 1e9))
    }
    public func bool(_ key: String) -> Bool? { raw[key]?.boolValue }

    /// Flattened string form for the audit log.
    var auditStrings: [String: String] {
        raw.mapValues { value in
            if let s = value.stringValue { return s }
            if let data = try? JSONEncoder().encode(value) { return String(decoding: data, as: UTF8.self) }
            return "\(value)"
        }
    }
}

/// What a tool handler returns.
public struct ToolOutput: Sendable {
    public var content: [Tool.Content]
    public var isError: Bool
    /// Short note for the audit log (e.g. what was clicked), so the log stays readable without full output.
    public var auditDetail: String?

    public init(content: [Tool.Content], isError: Bool = false, auditDetail: String? = nil) {
        self.content = content
        self.isError = isError
        self.auditDetail = auditDetail
    }

    public static func text(_ text: String, auditDetail: String? = nil) -> ToolOutput {
        ToolOutput(content: [.text(text)], auditDetail: auditDetail)
    }

    /// A tool-execution error the model should see and act on: say what went wrong and what to do next. `audit` is
    /// what the log keeps; by default the message with its marked screen text left out.
    public static func error(_ text: String, audit: String? = nil) -> ToolOutput {
        // Uncapped here: the audit log removes secrets from the detail first and caps it after (a secret cut in half
        // by an early cap would survive as a fragment).
        ToolOutput(content: [.text(text)], isError: true, auditDetail: audit ?? Untrusted.strip(text))
    }
}

public struct ToolContext: Sendable {
    public let client: String
    /// The call's deadline in seconds (from its ToolSpec), for tools that bound their own work by it.
    public var deadline: TimeInterval = 30
}

/// A tool definition plus its handler.
public struct ToolSpec: Sendable {
    public let tool: Tool
    /// Argument names whose values must never reach the audit log for this tool.
    public let secretArguments: Set<String>
    /// Rewrites the arguments before they reach the audit log, for tools where only part of an argument is secret.
    public let scrubArguments: (@Sendable ([String: Value]) -> [String: Value])?
    /// How long a call may take before it's abandoned and reported (the dispatcher adds a few seconds of slack, so
    /// a tool's own, more specific deadline error normally wins). Kept under about 60 s, Codex's client timeout,
    /// unless the caller asked for longer (mac_wait, mac_script).
    public let deadline: @Sendable (ToolArgs) -> TimeInterval
    /// Whether a call changes something (input, apps, windows, clipboard, scripts). Such calls are refused while
    /// another client holds the GUI lease. Defaults to the tool's annotations; tools that mix looking and changing
    /// (mac_app list vs launch) decide per call.
    public let mutates: @Sendable (ToolArgs) -> Bool
    public let handler: @Sendable (ToolArgs, ToolContext) async -> ToolOutput

    public init(name: String, description: String, properties: [String: Value] = [:], required: [String] = [],
                annotations: Tool.Annotations, secretArguments: Set<String> = [],
                scrubArguments: (@Sendable ([String: Value]) -> [String: Value])? = nil,
                deadline: @escaping @Sendable (ToolArgs) -> TimeInterval = { _ in 30 },
                mutates: (@Sendable (ToolArgs) -> Bool)? = nil,
                handler: @escaping @Sendable (ToolArgs, ToolContext) async -> ToolOutput) {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        tool = Tool(name: name, description: description, inputSchema: .object(schema), annotations: annotations)
        self.secretArguments = secretArguments
        self.scrubArguments = scrubArguments
        self.deadline = deadline
        let changes = annotations.readOnlyHint != true
        self.mutates = mutates ?? { _ in changes }
        self.handler = handler
    }
}

/// What to tell the model when a call was abandoned at its deadline.
func abandoned(_ tool: String, _ seconds: TimeInterval) -> ToolOutput {
    .error("\(tool) did not finish within \(Int(seconds.rounded())) s and was abandoned; no new input or accessibility "
        + "actions will be started. A request already sent to the app may still finish. The target app may be hung "
        + "or busy: check with mac_snapshot (or mac_app action=list) before retrying, to avoid repeating an action.")
}

/// JSON-schema property helpers.
public enum Prop {
    public static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var p: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { p["enum"] = .array(values.map { .string($0) }) }
        return .object(p)
    }
    public static func integer(_ description: String) -> Value { .object(["type": "integer", "description": .string(description)]) }
    public static func boolean(_ description: String) -> Value { .object(["type": "boolean", "description": .string(description)]) }
}

/// Explicit annotations on every tool: some clients (Codex) treat missing hints as destructive.
public extension Tool.Annotations {
    static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    static let action = Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
}

/// Refuses to act (or to read a screen nobody can see) when the session can't be driven: locked screen, no console
/// session, sleeping display, or missing Accessibility. Alerts a person (policy alert_webhook), since only they can
/// fix it. Returns nil when the tool may proceed.
func sessionGuard() async -> ToolOutput? {
    guard let blocker = SessionState.current().actionBlocker else { return nil }
    let waiting = CallInfo.who.map { " An agent is waiting: \($0)." } ?? ""
    await Alerts.shared.notify(blocker.hasPrefix("ACCESSIBILITY") ? .permission : .session, blocker + waiting)
    return .error(blocker)
}

/// Who is making the current tool call, for messages to a person (alerts).
enum CallInfo {
    @TaskLocal static var who: String?
}

enum PolicyCheck {
    case success(Policy)
    case failure(ToolOutput)
}

/// The current policy, or the refusal to return when it's invalid (agents are blocked until a person fixes it).
func currentPolicy() async -> PolicyCheck {
    switch await Policy.current() {
    case let .success(p): return .success(p)
    case let .failure(e):
        await Alerts.shared.notify(.policy, e.description)
        return .failure(.error(e.description))
    }
}

/// Refuses when policy forbids seeing or driving this app (or is invalid). Returns nil when allowed.
func policyGuard(_ app: AppInfo) async -> ToolOutput? {
    switch await currentPolicy() {
    case let .failure(out): return out
    case let .success(p): return p.refusal(bundleID: app.bundleID, name: app.name).map { .error($0) }
    }
}

/// The app a read-only tool targets: app= or the frontmost app.
func targetApp(_ query: String?) throws -> AppInfo {
    if let query { return try Apps.resolve(query) }
    guard let front = Apps.frontmost() else { throw ActionError("No frontmost app; pass app=.") }
    return front
}
