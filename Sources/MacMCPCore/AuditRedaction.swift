import CryptoKit
import Foundation

/// What the audit log may keep of a call's arguments and detail. The log records what was done, not what was typed,
/// scripted or read: anything that could be a secret is reduced to a length (and, for code, a short hash).
public enum AuditRedaction {
    /// "[script: 482 chars, sha256:3fa9c1d2]": enough to tell two runs apart without keeping the code.
    public static func summary(_ label: String, of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "[\(label): \(text.count) chars, sha256:\(digest)]"
    }

    // MARK: Keys

    /// Modifier-free (or shift-only) presses of a character key. Typed one at a time they can spell a password, so the
    /// log keeps shortcuts (cmd+s) and named keys (return, tab, arrows, function keys) and drops the characters.
    /// Anything it can't recognise is dropped too.
    public static func redactKeys(_ spec: String) -> String {
        var kept: [String] = [], hidden = 0
        func flush() {
            if hidden > 0 { kept.append("[\(hidden) printable key\(hidden == 1 ? "" : "s") redacted]"); hidden = 0 }
        }
        for token in keyTokens(spec) {
            if isPrintableOrUnknown(token) { hidden += 1 } else { flush(); kept.append(token) }
        }
        flush()
        return kept.joined(separator: ", ")
    }

    /// The same splitting `KeySpec.parseSequence` does: spaces and commas separate, except a comma right after "+".
    public static func keyTokens(_ spec: String) -> [String] {
        var parts: [String] = [], current = ""
        for ch in spec {
            if ch == " " || (ch == "," && !current.hasSuffix("+")) {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Named keys that produce no character.
    private static let namedKeys: Set<String> = Set([
        "return", "enter", "tab", "delete", "backspace", "esc", "escape", "forwarddelete", "home", "end", "pageup",
        "pagedown", "left", "right", "up", "down", "arrowleft", "arrowright", "arrowup", "arrowdown",
    ] + (1...20).map { "f\($0)" })

    /// Keys that type a character: single characters, `space`, and the punctuation names.
    private static let characterNames: Set<String> = [
        "space", "comma", "period", "slash", "semicolon", "quote", "apostrophe", "bracketleft", "bracketright", "minus",
        "equal", "equals", "backslash", "grave", "backtick",
    ]

    private static let heldModifiers: Set<String> = [
        "cmd", "command", "⌘", "alt", "opt", "option", "⌥", "ctrl", "control", "⌃", "fn",
    ]
    private static let shiftNames: Set<String> = ["shift", "⇧"]

    static func isPrintableOrUnknown(_ token: String) -> Bool {
        let lower = token.lowercased().trimmingCharacters(in: .whitespaces)
        // "+" and "cmd++" are the plus key.
        let (modifierText, name): (String, String)
        if lower == "+" { (modifierText, name) = ("", "+") }
        else if lower.hasSuffix("++") { (modifierText, name) = (String(lower.dropLast(2)), "+") }
        else {
            let parts = lower.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard let last = parts.last, !last.isEmpty else { return true }
            (modifierText, name) = (parts.dropLast().joined(separator: "+"), last)
        }
        let modifiers = modifierText.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard modifiers.allSatisfy({ heldModifiers.contains($0) || shiftNames.contains($0) }) else { return true }
        let known = namedKeys.contains(name) || characterNames.contains(name) || name.count == 1
        guard known else { return true }
        if namedKeys.contains(name) { return false }
        // A character key: hidden unless a modifier other than shift is held (a shortcut, not typing).
        return !modifiers.contains { heldModifiers.contains($0) }
    }

    // MARK: URLs

    /// Whether a value is a URL (has a scheme: a letter, then letters, digits, `+`, `-` or `.`, in any case) rather
    /// than a path. `mac_app open=` takes either.
    public static func looksLikeURL(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: /^[A-Za-z][A-Za-z0-9+.\-]*:\S/) != nil
    }

    /// A URL of any scheme without credentials, query or fragment: those carry tokens and session ids. Marks what was
    /// removed. Credentials are the part of the authority before its last `@`; the authority ends at the first `/`,
    /// `\`, `?` or `#`, as a browser reads it.
    public static func redactURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        var fragment = false, query = false
        if let i = rest.firstIndex(of: "#") { fragment = true; rest = rest[..<i] }
        if let i = rest.firstIndex(of: "?") { query = true; rest = rest[..<i] }
        if let colon = rest.firstIndex(of: ":"), rest[..<colon].wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*/) != nil {
            // Slashes (either kind, any number: browsers accept `https:/\host`) introduce an authority.
            let afterColon = rest.index(after: colon)
            let authorityStart = rest[afterColon...].firstIndex { $0 != "/" && $0 != "\\" } ?? rest.endIndex
            if authorityStart > afterColon {
                let authorityEnd = rest[authorityStart...].firstIndex { $0 == "/" || $0 == "\\" } ?? rest.endIndex
                if let at = rest[authorityStart..<authorityEnd].lastIndex(of: "@") {
                    rest = rest[..<authorityStart] + rest[rest.index(after: at)...]
                }
            }
        }
        return String(rest) + (query ? "?…" : "") + (fragment ? "#…" : "")
    }

    /// Every URL in free text, of any scheme and in any case, cleaned with `redactURL`: `scheme://…` and `scheme:…`
    /// forms (`mailto:`, app-specific schemes). Text that merely has a colon in it is left as it is by `redactURL`
    /// unless it also carries a `?` or `#`.
    public static func redactURLs(in text: String) -> String {
        guard text.contains(":") else { return text }
        return text.replacing(/\b[A-Za-z][A-Za-z0-9+.\-]*:[^\s"'<>)\]]+/) { redactURL(String($0.output)) }
    }

    // MARK: Detail

    /// Text longer than this is cut: stderr and Safari replies can echo what was typed or scripted.
    public static let errorDetailLimit = 120
    public static let detailLimit = 200

    /// The audit detail for a call: text read from the screen (marked as untrusted) left out, known secrets removed
    /// wherever they appear, URLs cleaned, one line, capped.
    /// `secrets` are the call's secret argument values (typed text, script source…); short ones are ignored so the
    /// replacement can't mangle ordinary words. `replacing` are exact rewrites applied first, whatever their length.
    public static func detail(_ detail: String?, secrets: [String] = [], replacing: [String: String] = [:],
                              isError: Bool) -> String? {
        guard var text = detail else { return nil }
        text = Untrusted.strip(text)   // anything the screen said stays out of the log
        for (from, to) in replacing { text = text.replacingOccurrences(of: from, with: to) }
        for secret in secrets.sorted(by: { $0.count > $1.count }) where secret.count >= 3 {
            text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        text = redactURLs(in: text)
        text = text.map { $0.isNewline ? " " : String($0) }.joined()
        let limit = isError ? errorDetailLimit : detailLimit
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
