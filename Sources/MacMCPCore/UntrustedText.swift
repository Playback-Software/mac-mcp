import Foundation

/// Marks text that came from the screen, a web page, a script or a clipboard as data, not instructions.
///
/// The boundary carries a random token, one per response (`scope`), so the text can't know it and can't print a
/// matching end line. Anything in the text that looks like a boundary is defused as well, so even a guessed token has
/// nothing to close.
///
///     <<untrusted k3j9x2>>
///     …text…
///     <<end k3j9x2>>
///
/// Short values inside a sentence (a dialog title in an error) use the same marks on one line. Every string a tool
/// did not write itself goes through `wrap` or `inline`, wherever it appears in the response.
public enum Untrusted {
    /// The token of the response being built. Set by the dispatcher around each call (`scope`); child tasks inherit it.
    @TaskLocal static var responseToken: String?

    /// The current response's token, or a fresh one when no response is being built (tests, the CLI).
    public static var current: String { responseToken ?? makeToken() }

    /// Runs `body` with one token for every mark it makes.
    public static func scope<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $responseToken.withValue(responseToken ?? makeToken(), operation: body)
    }

    /// Runs `body` with a fixed token (tests).
    public static func scope<T>(token: String, _ body: () async throws -> T) async rethrows -> T {
        try await $responseToken.withValue(token, operation: body)
    }

    /// The characters a boundary is made of. Content never keeps two of these in a row.
    static let opener = "<<"

    /// Six characters from a 36-letter alphabet (about 31 bits) from the system generator.
    public static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    public static func open(_ token: String) -> String { "<<untrusted \(token)>>" }
    public static func close(_ token: String) -> String { "<<end \(token)>>" }

    /// `text` between a boundary's opening and closing lines. Empty text stays empty.
    public static func wrap(_ text: String, token: String = current) -> String {
        guard !text.isEmpty else { return text }
        return "\(open(token))\n\(defuse(text))\n\(close(token))"
    }

    /// Several lines as one block (the common case: a list or a report).
    public static func wrap(lines: [String], token: String = current) -> String {
        wrap(lines.joined(separator: "\n"), token: token)
    }

    /// A short value inside a sentence: one line, at most `limit` characters, marked on both sides.
    public static func inline(_ text: String, limit: Int = 120, token: String = current) -> String {
        "\(open(token))\(flatten(text, limit: limit))\(close(token))"
    }

    /// One line, boundary-safe, cut at `limit` characters: for a title or label inside a line the tool builds itself.
    public static func flatten(_ text: String, limit: Int = .max) -> String {
        var flat = text.map { $0.isNewline ? " " : String($0) }.joined()
        if flat.count > limit { flat = String(flat.prefix(limit)) + "…" }
        return defuse(flat)
    }

    /// Breaks up every `<<` so the text can't contain an opening or closing boundary (`<<<` is handled too).
    /// Readable text is barely changed: `a << b` becomes `a < < b`.
    public static func defuse(_ text: String) -> String {
        var out = text
        while out.contains(opener) { out = out.replacingOccurrences(of: opener, with: "< <") }
        return out
    }

    /// `text` with every marked span (block or inline) replaced by `placeholder`: what the audit log keeps of a
    /// response. Spans are whole by construction: marked text never holds `<<`, so a span can't end early.
    public static func strip(_ text: String, placeholder: String = "…") -> String {
        guard text.contains(opener) else { return text }
        return text.replacing(/<<untrusted ([a-z0-9]+)>>(?s:.*?)<<end \1>>/) { _ in placeholder }
    }
}
