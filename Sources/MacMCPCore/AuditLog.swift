import Foundation

/// One tool call, as recorded in the append-only audit log.
public struct AuditEntry: Codable, Sendable, Equatable {
    public var time: Date
    public var client: String
    public var tool: String
    public var arguments: [String: String]
    public var outcome: String   // "ok" | "error" | "refused"
    public var detail: String?
    public var durationMs: Int
    /// The session (one relay or connection), where it came from (`local`, `ssh:<address>`), and the GUI lease
    /// holder it presented (eval and test runs hold one). Absent in entries written before M11.
    public var session: String?
    public var origin: String?
    public var lease: String?

    public init(time: Date = Date(), client: String, tool: String, arguments: [String: String],
                outcome: String, detail: String? = nil, durationMs: Int,
                session: String? = nil, origin: String? = nil, lease: String? = nil) {
        self.session = session
        self.origin = origin
        self.lease = lease
        self.time = time
        self.client = client
        self.tool = tool
        self.arguments = arguments
        self.outcome = outcome
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Append-only JSONL log of every tool call (`~/Library/Logs/MacMCP/audit.jsonl`).
public actor AuditLog {
    private let url: URL
    private let encoder: JSONEncoder

    private let maxBytes: Int

    public init(path: String = Paths.auditLog, maxBytes: Int = 20_000_000) {
        url = URL(fileURLWithPath: path)
        self.maxBytes = maxBytes
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func record(_ entry: AuditEntry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        // Rotate at 20 MB, keeping one previous file.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Argument names whose values are never written to the log.
    static let secretKeys: Set<String> = ["password", "passphrase", "secret", "token", "api_key", "apikey"]

    /// Redacts secret-looking arguments and truncates long values so the log stays useful and safe to share.
    /// `secretValueKeys` names arguments that are secret for this particular call (e.g. text typed into a
    /// secure field).
    public static func redact(_ arguments: [String: String], secretValueKeys: Set<String> = [],
                              maxLength: Int = 200) -> [String: String] {
        arguments.reduce(into: [:]) { result, pair in
            let key = pair.key.lowercased()
            if secretKeys.contains(key) || secretValueKeys.contains(pair.key) {
                result[pair.key] = "[REDACTED \(pair.value.count) chars]"
            } else if pair.value.count > maxLength {
                result[pair.key] = String(pair.value.prefix(maxLength)) + "… [\(pair.value.count) chars]"
            } else {
                result[pair.key] = pair.value
            }
        }
    }
}
