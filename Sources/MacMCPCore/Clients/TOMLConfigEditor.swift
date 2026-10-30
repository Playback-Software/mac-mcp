import Foundation

/// Edits one `[mcp_servers.<name>]` table in a TOML config (Codex's `config.toml`) by changing only the lines of that
/// table. The rest of the file, including comments and ordering, stays as it was. A file that doesn't parse is refused.
///
/// The table must be written as `[mcp_servers.<name>]` (with sub-tables such as `[mcp_servers.<name>.env]`). An entry
/// written another way (an inline table, dotted keys) is refused rather than rewritten.
enum TOMLConfigEditor {
    static let root = "mcp_servers"

    static func upsert(_ data: Data?, name: String, command: String, args: [String]) throws -> (data: Data, outcome: JSONConfigEditor.Outcome) {
        let source = try text(data)
        let document = try TOMLScanner(source).parse()
        if document.assignments.contains(where: { $0.scope.isEmpty && $0.key.first == root }) {
            throw ConfigFormatError(description: "`\(root)` is set outside a [\(root)] table; edit the file by hand")
        }
        let sections = try locate(document, name: name)
        let newline = source.contains(0x0D) ? "\r\n" : "\n"
        let table = render(name: name, command: command, args: args, newline: newline)
        guard let first = sections.first else {
            var out = source
            if let last = out.last, last != 0x0A { out += Array(newline.utf8) }
            if !out.isEmpty, !endsWithBlankLine(out) { out += Array(newline.utf8) }
            out += Array(table.utf8)
            return (Data(out), .added)
        }
        let current = String(decoding: source[first.start..<first.contentEnd], as: UTF8.self)
        if sections.count == 1, current == table || current == table.trimmingCharacters(in: .newlines) { return (Data(source), .unchanged) }
        var out = source
        for extra in sections.dropFirst().reversed() { out.removeSubrange(removalRange(extra, in: source)) }
        out.replaceSubrange(first.start..<first.contentEnd, with: Array(table.utf8))
        return (Data(out), .replaced)
    }

    static func remove(_ data: Data?, name: String) throws -> (data: Data, outcome: JSONConfigEditor.Outcome) {
        let source = try text(data)
        let document = try TOMLScanner(source).parse()
        let sections = try locate(document, name: name)
        guard !sections.isEmpty else { return (Data(source), .unchanged) }
        var out = source
        for section in sections.reversed() { out.removeSubrange(removalRange(section, in: source)) }
        return (Data(out), .removed)
    }

    /// The command and args of the entry, or nil when absent. For checking what a write produced.
    static func entry(in data: Data, name: String) throws -> (command: String, args: [String])? {
        let source = try text(data)
        let document = try TOMLScanner(source).parse()
        guard let table = try locate(document, name: name).first(where: { $0.path.count == 2 }) else { return nil }
        var command: String?
        var args: [String]?
        for kv in document.assignments where kv.scope == table.path && kv.key.count == 1 {
            if kv.key[0] == "command", case let .string(s)? = kv.value { command = s }
            if kv.key[0] == "args", case let .strings(a)? = kv.value { args = a }
        }
        return command.map { ($0, args ?? []) }
    }

    // MARK: layout

    /// The sections that make up `name`'s entry. Throws when it's defined in a form we won't rewrite.
    private static func locate(_ document: TOMLDocument, name: String) throws -> [TOMLDocument.Section] {
        var found: [TOMLDocument.Section] = []
        for section in document.sections where section.path.first == root {
            if section.path.count == 1 {
                if section.isArray { throw ConfigFormatError(description: "`[[\(root)]]` is an array of tables; edit the file by hand") }
                continue
            }
            guard section.path[1] == name else { continue }
            if section.isArray { throw ConfigFormatError(description: "`[[\(root).\(name)]]` is an array of tables; edit the file by hand") }
            found.append(section)
        }
        if found.filter({ $0.path.count == 2 }).count > 1 {
            throw ConfigFormatError(description: "[\(root).\(name)] appears more than once; fix the file by hand")
        }
        for kv in document.assignments {
            if kv.scope == [root], kv.key.first == name {
                throw ConfigFormatError(description: "`\(name)` is written as a value inside [\(root)] rather than as a [\(root).\(name)] table; edit the file by hand")
            }
            if kv.scope.isEmpty, kv.key.first == root, kv.key.count == 1 || kv.key[1] == name {
                throw ConfigFormatError(description: "`\(root)` is set as a value rather than as [\(root).\(name)] tables; edit the file by hand")
            }
        }
        return found
    }

    static func render(name: String, command: String, args: [String], newline: String) -> String {
        "[\(root).\(name)]" + newline
            + "command = \(quote(command))" + newline
            + "args = [" + args.map(quote).joined(separator: ", ") + "]" + newline
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// A section's lines and the blank lines that follow them. Comments between it and the next header stay: they
    /// usually belong to the next one.
    private static func removalRange(_ section: TOMLDocument.Section, in source: [UInt8]) -> Range<Int> {
        var end = section.contentEnd
        while end < source.count {
            var j = end
            while j < source.count, source[j] == 0x20 || source[j] == 0x09 || source[j] == 0x0D { j += 1 }
            guard j < source.count, source[j] == 0x0A else { break }
            end = j + 1
        }
        guard end >= source.count else { return section.start..<end }
        // The last thing in the file: take the blank line that separated it from the table before, as well. A blank
        // line right before a header can't be inside a multi-line string.
        var start = section.start
        while start > 0 {
            var lineStart = start - 1
            while lineStart > 0, source[lineStart - 1] != 0x0A { lineStart -= 1 }
            guard source[lineStart..<(start - 1)].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { break }
            start = lineStart
        }
        return start..<end
    }

    private static func endsWithBlankLine(_ bytes: [UInt8]) -> Bool {
        var i = bytes.count - 1
        guard i >= 0, bytes[i] == 0x0A else { return false }
        i -= 1
        if i >= 0, bytes[i] == 0x0D { i -= 1 }
        return i < 0 || bytes[i] == 0x0A
    }

    private static func text(_ data: Data?) throws -> [UInt8] {
        guard let data else { return [] }
        guard String(data: data, encoding: .utf8) != nil else { throw ConfigFormatError(description: "not valid UTF-8") }
        return [UInt8](data)
    }
}

// MARK: - scanner

struct TOMLDocument {
    struct Section {
        let path: [String]
        let isArray: Bool
        /// The header's line start, and the end of the section's last line of content (after its newline).
        let start: Int
        var contentEnd: Int
    }

    enum Value: Equatable {
        case string(String)
        case strings([String])
        case other
    }

    struct Assignment {
        let scope: [String]
        let key: [String]
        let value: Value?
    }

    var sections: [Section] = []
    var assignments: [Assignment] = []
}

/// A TOML 1.0 syntax checker that reports where tables start and end. It checks that the file's syntax is valid; it
/// doesn't check every rule about redefining keys. (It accepts newlines and trailing commas in inline tables, which
/// TOML 1.1 allows.)
struct TOMLScanner {
    let b: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { b = bytes }

    private static let maxDepth = 128

    func fail(_ message: String, at offset: Int? = nil) -> ConfigFormatError {
        let pos = min(offset ?? i, b.count)
        let line = b[0..<pos].filter { $0 == 0x0A }.count + 1
        let lineStart = (b[0..<pos].lastIndex(of: 0x0A) ?? -1) + 1
        return ConfigFormatError(description: "\(message) (line \(line), column \(pos - lineStart + 1))")
    }

    func parse() throws -> TOMLDocument {
        var scanner = self
        return try scanner.run()
    }

    private mutating func run() throws -> TOMLDocument {
        var document = TOMLDocument()
        var scope: [String] = []
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        while i < b.count {
            let lineStart = i
            skipBlanks()
            guard i < b.count else { break }
            switch b[i] {
            case 0x0A: i += 1
            case 0x0D where i + 1 < b.count && b[i + 1] == 0x0A: i += 2
            case UInt8(ascii: "#"): try skipComment()
            case UInt8(ascii: "["):
                let isArray = i + 1 < b.count && b[i + 1] == UInt8(ascii: "[")
                i += isArray ? 2 : 1
                skipBlanks()
                let path = try parseKey()
                skipBlanks()
                for _ in 0..<(isArray ? 2 : 1) {
                    guard i < b.count, b[i] == UInt8(ascii: "]") else { throw fail("expected \"]\" to close the table header") }
                    i += 1
                }
                try endOfLine()
                scope = path
                document.sections.append(.init(path: path, isArray: isArray, start: lineStart, contentEnd: i))
            default:
                let key = try parseKey()
                skipBlanks()
                guard i < b.count, b[i] == UInt8(ascii: "=") else { throw fail("expected \"=\" after the key") }
                i += 1
                skipBlanks()
                let value = try parseValue(depth: 0)
                try endOfLine()
                document.assignments.append(.init(scope: scope, key: key, value: value))
                if !document.sections.isEmpty { document.sections[document.sections.count - 1].contentEnd = i }
            }
        }
        return document
    }

    private mutating func skipBlanks() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
    }

    private mutating func skipComment() throws {
        while i < b.count, b[i] != 0x0A {
            if b[i] < 0x20 && b[i] != 0x09 && !(b[i] == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A) { throw fail("control character in a comment") }
            i += 1
        }
    }

    /// After a header or a value: blanks, a comment, then the end of the line. Leaves `i` after the newline.
    private mutating func endOfLine() throws {
        skipBlanks()
        if i < b.count, b[i] == UInt8(ascii: "#") { try skipComment() }
        if i < b.count, b[i] == 0x0D, i + 1 < b.count, b[i + 1] == 0x0A { i += 1 }
        guard i >= b.count || b[i] == 0x0A else { throw fail("unexpected text after the value") }
        if i < b.count { i += 1 }
    }

    // MARK: keys

    private mutating func parseKey() throws -> [String] {
        var parts: [String] = []
        while true {
            skipBlanks()
            guard i < b.count else { throw fail("expected a key") }
            switch b[i] {
            case UInt8(ascii: "\""): parts.append(try parseBasicString())
            case UInt8(ascii: "'"): parts.append(try parseLiteralString())
            default:
                let start = i
                while i < b.count, isBare(b[i]) { i += 1 }
                guard i > start else { throw fail("expected a key") }
                parts.append(String(decoding: b[start..<i], as: UTF8.self))
            }
            skipBlanks()
            if i < b.count, b[i] == UInt8(ascii: ".") { i += 1; continue }
            return parts
        }
    }

    private func isBare(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
    }

    // MARK: values

    private mutating func parseValue(depth: Int) throws -> TOMLDocument.Value {
        guard depth < Self.maxDepth else { throw fail("nested too deeply") }
        guard i < b.count else { throw fail("expected a value") }
        switch b[i] {
        case UInt8(ascii: "\""):
            if has("\"\"\"") { try parseMultilineString(quote: UInt8(ascii: "\""), literal: false); return .other }
            return .string(try parseBasicString())
        case UInt8(ascii: "'"):
            if has("'''") { try parseMultilineString(quote: UInt8(ascii: "'"), literal: true); return .other }
            return .string(try parseLiteralString())
        case UInt8(ascii: "["):
            i += 1
            var strings: [String] = []
            var onlyStrings = true
            while true {
                try skipSpace()
                guard i < b.count else { throw fail("the array is never closed") }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                if case let .string(s) = try parseValue(depth: depth + 1) { strings.append(s) } else { onlyStrings = false }
                try skipSpace()
                guard i < b.count else { throw fail("the array is never closed") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                guard b[i] == UInt8(ascii: "]") else { throw fail("expected \",\" or \"]\"") }
                i += 1
                break
            }
            return onlyStrings ? .strings(strings) : .other
        case UInt8(ascii: "{"):
            i += 1
            while true {
                try skipSpace()
                guard i < b.count else { throw fail("the inline table is never closed") }
                if b[i] == UInt8(ascii: "}") { i += 1; break }
                _ = try parseKey()
                skipBlanks()
                guard i < b.count, b[i] == UInt8(ascii: "=") else { throw fail("expected \"=\" after the key") }
                i += 1
                skipBlanks()
                _ = try parseValue(depth: depth + 1)
                try skipSpace()
                guard i < b.count else { throw fail("the inline table is never closed") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                guard b[i] == UInt8(ascii: "}") else { throw fail("expected \",\" or \"}\"") }
                i += 1
                break
            }
            return .other
        default:
            try parseScalar()
            return .other
        }
    }

    /// Blanks, newlines and comments between the items of an array or inline table.
    private mutating func skipSpace() throws {
        while i < b.count {
            switch b[i] {
            case 0x20, 0x09, 0x0A: i += 1
            case 0x0D where i + 1 < b.count && b[i + 1] == 0x0A: i += 1
            case UInt8(ascii: "#"): try skipComment()
            default: return
            }
        }
    }

    private func has(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        return b.count - i >= bytes.count && Array(b[i..<(i + bytes.count)]) == bytes
    }

    private mutating func parseBasicString() throws -> String {
        let open = i
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if c == 0x0A || (c < 0x20 && c != 0x09) || c == 0x7F { throw fail("unterminated or invalid string", at: open) }
            if c == UInt8(ascii: "\\") {
                i += 1
                out += try parseEscape()
                continue
            }
            out.append(c)
            i += 1
        }
        throw fail("unterminated string", at: open)
    }

    /// After a backslash: the escaped character's UTF-8 bytes. Leaves `i` after the escape.
    private mutating func parseEscape() throws -> [UInt8] {
        guard i < b.count else { throw fail("unterminated escape") }
        let c = b[i]
        i += 1
        switch c {
        case UInt8(ascii: "b"): return [0x08]
        case UInt8(ascii: "t"): return [0x09]
        case UInt8(ascii: "n"): return [0x0A]
        case UInt8(ascii: "f"): return [0x0C]
        case UInt8(ascii: "r"): return [0x0D]
        case UInt8(ascii: "e"): return [0x1B]
        case UInt8(ascii: "\""): return [0x22]
        case UInt8(ascii: "\\"): return [0x5C]
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let count = c == UInt8(ascii: "u") ? 4 : 8
            guard b.count - i >= count, let code = UInt32(String(decoding: b[i..<(i + count)], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(code) else { throw fail("invalid unicode escape") }
            i += count
            return Array(String(Character(scalar)).utf8)
        default: throw fail("invalid escape in a string", at: i - 1)
        }
    }

    private mutating func parseLiteralString() throws -> String {
        let open = i
        i += 1
        let start = i
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "'") { defer { i += 1 }; return String(decoding: b[start..<i], as: UTF8.self) }
            if c == 0x0A || (c < 0x20 && c != 0x09) || c == 0x7F { throw fail("unterminated or invalid string", at: open) }
            i += 1
        }
        throw fail("unterminated string", at: open)
    }

    private mutating func parseMultilineString(quote: UInt8, literal: Bool) throws {
        let open = i
        i += 3
        while i < b.count {
            let c = b[i]
            if c == quote, i + 2 < b.count, b[i + 1] == quote, b[i + 2] == quote {
                i += 3
                // Up to two more quotes may belong to the string.
                var extra = 0
                while extra < 2, i < b.count, b[i] == quote { i += 1; extra += 1 }
                return
            }
            if !literal, c == UInt8(ascii: "\\") {
                i += 1
                // A backslash at the end of a line trims the whitespace after it.
                var j = i
                while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
                if j < b.count, b[j] == 0x0A || (b[j] == 0x0D && j + 1 < b.count && b[j + 1] == 0x0A) { i = j; continue }
                _ = try parseEscape()
                continue
            }
            if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) || c == 0x7F { throw fail("control character in a string") }
            i += 1
        }
        throw fail("unterminated string", at: open)
    }

    private static let patterns: [NSRegularExpression] = [
        "true|false",
        "[+-]?(0|[1-9](_?[0-9])*)",
        "0x[0-9A-Fa-f](_?[0-9A-Fa-f])*", "0o[0-7](_?[0-7])*", "0b[01](_?[01])*",
        "[+-]?(0|[1-9](_?[0-9])*)(\\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?",
        "[+-]?(inf|nan)",
        "[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?([Zz]|[+-][0-9]{2}:[0-9]{2})?)?",
        "[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?",
    ].map { try! NSRegularExpression(pattern: "^(?:\($0))$") }

    private mutating func parseScalar() throws {
        let start = i
        while i < b.count, !" \t\r\n,]}#".utf8.contains(b[i]) { i += 1 }
        // A date and a time may be separated by a space.
        if i + 1 < b.count, b[i] == 0x20, b[i + 1] >= 0x30, b[i + 1] <= 0x39, i - start == 10 {
            i += 1
            while i < b.count, !" \t\r\n,]}#".utf8.contains(b[i]) { i += 1 }
        }
        let token = String(decoding: b[start..<i], as: UTF8.self)
        let whole = NSRange(token.startIndex..., in: token)
        guard !token.isEmpty, Self.patterns.contains(where: { $0.firstMatch(in: token, range: whole) != nil }) else {
            throw fail("invalid value", at: start)
        }
    }
}
