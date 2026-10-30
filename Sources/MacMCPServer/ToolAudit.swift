import Foundation
import MacMCPCore

/// What the audit log keeps of one tool call. Per-tool rules live here, in one place, so a new tool with a secret
/// argument has one list to join (`ToolSpec.secretArguments` covers the plain "never log this value" case).
enum ToolAudit {
    /// Arguments by tool: code is reduced to a length and hash, typed keys to their non-printable part, URLs to
    /// scheme, host and path.
    static func arguments(tool: String, raw: [String: Value], secretKeys: Set<String>) -> [String: String] {
        var args = raw
        var secret = secretKeys
        switch tool {
        case "mac_key":
            if let keys = raw["keys"] { args["keys"] = .string(AuditRedaction.redactKeys(keysText(keys))) }
        case "mac_script":
            if let s = raw["source"]?.stringValue { args["source"] = .string(AuditRedaction.summary("script", of: s)) }
        case "web_eval":
            if let s = raw["expression"]?.stringValue { args["expression"] = .string(AuditRedaction.summary("code", of: s)) }
        case "mac_shortcut":
            secret.insert("input")   // whatever the shortcut is fed is the person's data
        case "web_navigate", "web_tabs":
            if let u = raw["url"]?.stringValue { args["url"] = .string(AuditRedaction.redactURL(u)) }
        case "mac_app":   // a URL of any scheme, or a file path
            if let o = raw["open"]?.stringValue, AuditRedaction.looksLikeURL(o) { args["open"] = .string(AuditRedaction.redactURL(o)) }
        default: break
        }
        // Whatever else holds a URL (a query, a menu path, a note) loses its credentials, query and fragment too.
        // Secret values are only measured, and a URL is cleaned whole, before the log cuts long values.
        let strings = ToolArgs(args).auditStrings.reduce(into: [String: String]()) { out, pair in
            let isSecret = secret.contains(pair.key) || AuditLog.secretKeys.contains(pair.key.lowercased())
            out[pair.key] = isSecret ? pair.value : AuditRedaction.redactURLs(in: pair.value)
        }
        return AuditLog.redact(strings, secretValueKeys: secret)
    }

    /// Values that must not survive in the detail either (stderr and Safari replies can echo them).
    static func secrets(tool: String, raw: [String: Value], secretKeys: Set<String>) -> [String] {
        var out: [String] = []
        for key in secretKeys { if let v = raw[key]?.stringValue { out.append(v) } }
        func code(_ text: String?) {
            guard let text else { return }
            out.append(text)
            out += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 8 }
        }
        switch tool {
        case "mac_key":   // "Unknown key …" errors echo a token that isn't a key name, which may be a typed word
            if let keys = raw["keys"] { out += AuditRedaction.keyTokens(keysText(keys)).filter { (try? KeySpec.parse($0)) == nil } }
        case "mac_script": code(raw["source"]?.stringValue)
        case "web_eval": code(raw["expression"]?.stringValue)
        case "mac_shortcut": if let v = raw["input"]?.stringValue { out.append(v) }
        case "web_act":
            for step in raw["actions"]?.arrayValue ?? [] where step["do"]?.stringValue == "type" {
                if let v = step["value"]?.stringValue { out.append(v) }
            }
        default: break
        }
        return out
    }

    /// Exact rewrites for the detail: `mac_key` says "pressed <keys>", so those keys get the argument's redaction.
    static func replacements(tool: String, raw: [String: Value]) -> [String: String] {
        guard tool == "mac_key", let keys = raw["keys"] else { return [:] }
        let text = keysText(keys)
        // Only after "pressed ": a one-key spec like "a" would otherwise be replaced all over the detail.
        return text.isEmpty ? [:] : ["pressed \(text)": "pressed \(AuditRedaction.redactKeys(text))"]
    }

    /// The `keys` argument as the tool prints it back: a list is joined with ", ".
    static func keysText(_ keys: Value) -> String {
        if let list = keys.arrayValue { return list.map { $0.stringValue ?? ToolArgs(["k": $0]).auditStrings["k"] ?? "" }.joined(separator: ", ") }
        return keys.stringValue ?? ToolArgs(["k": keys]).auditStrings["k"] ?? ""
    }

    /// `refused` for the calls the policy and safety layers turned down (their messages start "Refused"), `error` for
    /// the other failures.
    static func outcome(_ output: ToolOutput) -> String {
        guard output.isError else { return "ok" }
        for case let .text(text) in output.content where text.hasPrefix("Refused") { return "refused" }
        return "error"
    }

    static func detail(tool: String, raw: [String: Value], secretKeys: Set<String>, output: ToolOutput) -> String? {
        AuditRedaction.detail(output.auditDetail, secrets: secrets(tool: tool, raw: raw, secretKeys: secretKeys),
                              replacing: replacements(tool: tool, raw: raw), isError: output.isError)
    }
}
