import Foundation

/// A value written into a client's config. Just enough JSON/TOML for a stdio server entry.
indirect enum ConfigValue: Equatable {
    case string(String)
    case array([ConfigValue])
    case object([(key: String, value: ConfigValue)])

    static func == (a: ConfigValue, b: ConfigValue) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    /// The Foundation equivalent, to compare with what `JSONSerialization` reads from an existing entry.
    var foundation: Any {
        switch self {
        case let .string(s): return s
        case let .array(a): return a.map(\.foundation)
        case let .object(o): return Dictionary(o.map { ($0.key, $0.value.foundation) }, uniquingKeysWith: { _, last in last })
        }
    }
}

struct ConfigFormatError: Error, CustomStringConvertible {
    let description: String
}

/// Edits one server entry in a JSON (or JSONC) config file by changing only the bytes of that entry. The rest of the file,
/// including key order, indentation, comments and formatting, stays as it was. A file that doesn't parse is refused.
enum JSONConfigEditor {
    typealias Outcome = ClientChange

    /// Adds or replaces `container.name`. A missing or empty file becomes a new document.
    static func upsert(_ data: Data?, jsonc: Bool, container: String, name: String,
                       entry: ConfigValue) throws -> (data: Data, outcome: Outcome) {
        let source = try text(data)
        if source.allSatisfy(isWhitespace) {
            let unit = "  "
            let body = ConfigValue.object([(container, .object([(name, entry)]))])
            return (Data((render(body, indent: "", unit: unit, newline: "\n", compact: false) + "\n").utf8), .added)
        }
        var scanner = JSONScanner(source, jsonc: jsonc)
        let top = try scanner.parseDocument()
        let style = Style(source, top)
        let containers = top.members.filter { $0.key == container }
        if containers.count > 1 { throw ConfigFormatError(description: "\"\(container)\" appears more than once; fix the file by hand") }
        guard let found = containers.first else {
            let edits = insert({ compact, indent in renderMember(container, .object([(name, entry)]), indent: indent, style: style, compact: compact) },
                               into: top, objectIndent: "", source: source, style: style, jsonc: jsonc)
            return (apply(edits, to: source), .added)
        }
        guard let object = found.object else {
            throw ConfigFormatError(description: "\"\(container)\" is not an object; fix the file by hand")
        }
        let matches = object.members.filter { $0.key == name }
        if matches.count > 1 { throw ConfigFormatError(description: "\"\(name)\" appears more than once in \"\(container)\"; fix the file by hand") }
        let containerIndent = lineIndent(of: found.keyStart, in: source)
        if let existing = matches.first {
            let current = Array(source[existing.valueStart..<existing.valueEnd])
            if let parsed = try? JSONSerialization.jsonObject(with: Data(current), options: [.fragmentsAllowed]),
               (parsed as AnyObject).isEqual(entry.foundation) {
                return (Data(source), .unchanged)
            }
            let compact = !object.multiline(in: source)
            let value = render(entry, indent: style.memberIndent(of: object, in: source, base: containerIndent),
                               unit: style.unit, newline: style.newline, compact: compact)
            var out = source
            out.replaceSubrange(existing.valueStart..<existing.valueEnd, with: Array(value.utf8))
            return (Data(out), .replaced)
        }
        let edits = insert({ compact, indent in renderMember(name, entry, indent: indent, style: style, compact: compact) },
                           into: object, objectIndent: containerIndent, source: source, style: style, jsonc: jsonc)
        return (apply(edits, to: source), .added)
    }

    /// Removes `container.name` if it's there.
    static func remove(_ data: Data?, jsonc: Bool, container: String, name: String) throws -> (data: Data, outcome: Outcome) {
        let source = try text(data)
        if source.allSatisfy(isWhitespace) { return (Data(source), .unchanged) }
        var scanner = JSONScanner(source, jsonc: jsonc)
        let top = try scanner.parseDocument()
        let containers = top.members.filter { $0.key == container }
        if containers.count > 1 { throw ConfigFormatError(description: "\"\(container)\" appears more than once; fix the file by hand") }
        guard let found = containers.first else { return (Data(source), .unchanged) }
        guard let object = found.object else {
            throw ConfigFormatError(description: "\"\(container)\" is not an object; fix the file by hand")
        }
        let matches = object.members.enumerated().filter { $0.element.key == name }
        if matches.count > 1 { throw ConfigFormatError(description: "\"\(name)\" appears more than once in \"\(container)\"; fix the file by hand") }
        guard let (index, member) = matches.first else { return (Data(source), .unchanged) }
        let edits = scanner.removalEdits(of: member, index: index, in: object)
        return (apply(edits, to: source), .removed)
    }

    /// The entry's value as JSON, or nil when absent. For checking what a write produced.
    static func entry(in data: Data, jsonc: Bool, container: String, name: String) throws -> Any? {
        let source = try text(data)
        var scanner = JSONScanner(source, jsonc: jsonc)
        let top = try scanner.parseDocument()
        guard let object = top.members.first(where: { $0.key == container })?.object,
              let member = object.members.first(where: { $0.key == name }) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(source[member.valueStart..<member.valueEnd]), options: [.fragmentsAllowed])
    }

    // MARK: layout

    /// How the file is laid out, so new text looks like the old.
    struct Style {
        let unit: String
        let newline: String

        init(_ source: [UInt8], _ top: JSONObjectSpan) {
            newline = source.contains(0x0D) ? "\r\n" : "\n"
            if let first = top.members.first, let indent = JSONConfigEditor.ownLineIndent(of: first.keyStart, in: source), !indent.isEmpty {
                unit = indent
            } else {
                unit = "  "
            }
        }

        /// The indent of `object`'s members: its first member's, else one level in from `base`.
        func memberIndent(of object: JSONObjectSpan, in source: [UInt8], base: String) -> String {
            if let first = object.members.first, let indent = JSONConfigEditor.ownLineIndent(of: first.keyStart, in: source) { return indent }
            return base + unit
        }
    }

    private static func renderMember(_ key: String, _ value: ConfigValue, indent: String, style: Style, compact: Bool = false) -> String {
        quote(key) + ": " + render(value, indent: indent, unit: style.unit, newline: style.newline, compact: compact)
    }

    /// Edits that add a member to `object`. `member` renders it, compact or laid out at an indent.
    private static func insert(_ member: (_ compact: Bool, _ indent: String) -> String, into object: JSONObjectSpan,
                               objectIndent: String, source: [UInt8], style: Style, jsonc: Bool) -> [Edit] {
        if let last = object.members.last {
            guard object.multiline(in: source) else {
                return [Edit(range: last.valueEnd..<last.valueEnd, text: ", " + member(true, ""))]
            }
            // The new member goes on the line after the last one's, past any trailing comma and comment on that line.
            let indent = style.memberIndent(of: object, in: source, base: objectIndent)
            let scanner = JSONScanner(source, jsonc: jsonc)
            let comma = scanner.comma(after: last.valueEnd)
            let endOfLine = scanner.endOfLine(from: (comma.map { $0 + 1 }) ?? last.valueEnd)
            guard let endOfLine else {
                return [Edit(range: last.valueEnd..<last.valueEnd, text: "," + style.newline + indent + member(false, indent))]
            }
            let text = style.newline + indent + member(false, indent) + (comma == nil ? "" : ",")
            if comma == nil, endOfLine == last.valueEnd { return [Edit(range: endOfLine..<endOfLine, text: "," + text)] }
            return (comma == nil ? [Edit(range: last.valueEnd..<last.valueEnd, text: ",")] : []) + [Edit(range: endOfLine..<endOfLine, text: text)]
        }
        let interior = Array(source[(object.start + 1)..<(object.end - 1)])
        let childIndent = objectIndent + style.unit
        // Only whitespace inside: lay the braces out afresh. Comments inside: put the member before them.
        guard interior.allSatisfy(isWhitespace) else {
            return [Edit(range: (object.start + 1)..<(object.start + 1), text: style.newline + childIndent + member(false, childIndent))]
        }
        if source.contains(0x0A) {
            return [Edit(range: object.start..<object.end,
                         text: "{" + style.newline + childIndent + member(false, childIndent) + style.newline + objectIndent + "}")]
        }
        return [Edit(range: object.start..<object.end, text: "{" + member(true, "") + "}")]
    }

    struct Edit {
        let range: Range<Int>
        let text: String
    }

    private static func apply(_ edits: [Edit], to source: [UInt8]) -> Data {
        var out = source
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return Data(out)
    }

    // MARK: text helpers

    private static func text(_ data: Data?) throws -> [UInt8] {
        guard let data else { return [] }
        guard String(data: data, encoding: .utf8) != nil else { throw ConfigFormatError(description: "not valid UTF-8") }
        return [UInt8](data)
    }

    static func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// The whitespace before `position` on its line, when nothing else is.
    static func ownLineIndent(of position: Int, in source: [UInt8]) -> String? {
        var i = position
        while i > 0, source[i - 1] != 0x0A {
            i -= 1
            if source[i] != 0x20 && source[i] != 0x09 { return nil }
        }
        return String(decoding: source[i..<position], as: UTF8.self)
    }

    /// The leading whitespace of the line holding `position`.
    static func lineIndent(of position: Int, in source: [UInt8]) -> String {
        var start = position
        while start > 0, source[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < position, source[end] == 0x20 || source[end] == 0x09 { end += 1 }
        return String(decoding: source[start..<end], as: UTF8.self)
    }

    // MARK: rendering

    static func quote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `value` as JSON. A multi-line object continues at `indent` (its first line is already placed).
    static func render(_ value: ConfigValue, indent: String, unit: String, newline: String, compact: Bool) -> String {
        switch value {
        case let .string(s):
            return quote(s)
        case let .array(items):
            let inline = "[" + items.map { render($0, indent: indent, unit: unit, newline: newline, compact: true) }.joined(separator: ", ") + "]"
            if compact || inline.count <= 72 { return inline }
            let inner = indent + unit
            return "[" + newline + items.map { inner + render($0, indent: inner, unit: unit, newline: newline, compact: false) }
                .joined(separator: "," + newline) + newline + indent + "]"
        case let .object(pairs):
            if compact { return "{" + pairs.map { quote($0.key) + ": " + render($0.value, indent: indent, unit: unit, newline: newline, compact: true) }.joined(separator: ", ") + "}" }
            let inner = indent + unit
            return "{" + newline + pairs.map { inner + quote($0.key) + ": " + render($0.value, indent: inner, unit: unit, newline: newline, compact: false) }
                .joined(separator: "," + newline) + newline + indent + "}"
        }
    }
}

// MARK: - scanner

/// Where an object's members sit in the file (byte offsets).
struct JSONObjectSpan {
    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
        /// The member's own members, when the value is an object and this level was scanned in detail.
        let object: JSONObjectSpan?
    }

    let start: Int   // the "{"
    let end: Int     // after the "}"
    var members: [Member]

    func multiline(in source: [UInt8]) -> Bool { source[start..<end].contains(0x0A) }
}

/// A strict JSON parser (RFC 8259) that also reports byte positions; with `jsonc`, it accepts comments and trailing
/// commas as VS Code does. It describes the top-level object and the objects directly inside it, and checks the rest.
struct JSONScanner {
    let b: [UInt8]
    let jsonc: Bool
    var i = 0

    init(_ bytes: [UInt8], jsonc: Bool) {
        b = bytes
        self.jsonc = jsonc
    }

    private static let maxDepth = 256

    func fail(_ message: String, at offset: Int? = nil) -> ConfigFormatError {
        let pos = min(offset ?? i, b.count)
        let line = b[0..<pos].filter { $0 == 0x0A }.count + 1
        let lineStart = (b[0..<pos].lastIndex(of: 0x0A) ?? -1) + 1
        return ConfigFormatError(description: "\(message) (line \(line), column \(pos - lineStart + 1))")
    }

    mutating func parseDocument() throws -> JSONObjectSpan {
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        try skipTrivia()
        guard i < b.count, b[i] == UInt8(ascii: "{") else { throw fail("expected a JSON object at the top of the file") }
        let object = try parseObject(depth: 0, detail: 2)
        try skipTrivia()
        guard i == b.count else { throw fail("unexpected text after the JSON object") }
        return object
    }

    mutating func skipTrivia() throws {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
            if c == UInt8(ascii: "/") {
                guard jsonc else { throw fail("comments aren't allowed in this JSON file") }
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "/") {
                    while i < b.count, b[i] != 0x0A { i += 1 }
                    continue
                }
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "*") {
                    let open = i
                    i += 2
                    while i + 1 < b.count, !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    guard i + 1 < b.count else { throw fail("unterminated comment", at: open) }
                    i += 2
                    continue
                }
                throw fail("unexpected \"/\"")
            }
            return
        }
    }

    /// `detail` counts levels still described: 2 describes this object's members and their objects.
    private mutating func parseObject(depth: Int, detail: Int) throws -> JSONObjectSpan {
        guard depth < Self.maxDepth else { throw fail("nested too deeply") }
        let start = i
        i += 1
        var members: [JSONObjectSpan.Member] = []
        try skipTrivia()
        if i < b.count, b[i] == UInt8(ascii: "}") {
            i += 1
            return JSONObjectSpan(start: start, end: i, members: members)
        }
        while true {
            try skipTrivia()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a string key") }
            let keyStart = i
            let key = try parseString()
            try skipTrivia()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected \":\" after the key") }
            i += 1
            try skipTrivia()
            let valueStart = i
            var nested: JSONObjectSpan?
            if i < b.count, b[i] == UInt8(ascii: "{") {
                nested = try parseObject(depth: depth + 1, detail: detail - 1)
            } else {
                try parseValue(depth: depth + 1)
            }
            if detail <= 1 { nested = nil }
            members.append(.init(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: i, object: nested))
            try skipTrivia()
            guard i < b.count else { throw fail("the object is never closed") }
            if b[i] == UInt8(ascii: ",") {
                i += 1
                try skipTrivia()
                if jsonc, i < b.count, b[i] == UInt8(ascii: "}") { i += 1; break }
                continue
            }
            guard b[i] == UInt8(ascii: "}") else { throw fail("expected \",\" or \"}\"") }
            i += 1
            break
        }
        return JSONObjectSpan(start: start, end: i, members: members)
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth < Self.maxDepth else { throw fail("nested too deeply") }
        guard i < b.count else { throw fail("expected a value") }
        switch b[i] {
        case UInt8(ascii: "{"):
            // Described in no detail, but still checked.
            _ = try parseObject(depth: depth, detail: 0)
        case UInt8(ascii: "["):
            i += 1
            try skipTrivia()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return }
            while true {
                try skipTrivia()
                try parseValue(depth: depth + 1)
                try skipTrivia()
                guard i < b.count else { throw fail("the array is never closed") }
                if b[i] == UInt8(ascii: ",") {
                    i += 1
                    try skipTrivia()
                    if jsonc, i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return }
                    continue
                }
                guard b[i] == UInt8(ascii: "]") else { throw fail("expected \",\" or \"]\"") }
                i += 1
                return
            }
        case UInt8(ascii: "\""):
            _ = try parseString()
        case UInt8(ascii: "t"): try literal("true")
        case UInt8(ascii: "f"): try literal("false")
        case UInt8(ascii: "n"): try literal("null")
        default:
            try parseNumber()
        }
    }

    private mutating func literal(_ word: String) throws {
        let bytes = Array(word.utf8)
        guard b.count - i >= bytes.count, Array(b[i..<(i + bytes.count)]) == bytes else { throw fail("invalid value") }
        i += bytes.count
    }

    private mutating func parseNumber() throws {
        let start = i
        func digits() -> Int {
            var n = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1; n += 1 }
            return n
        }
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw fail("invalid number", at: start) }
        if b[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw fail("invalid value", at: start) }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            if digits() == 0 { throw fail("invalid number", at: start) }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            if digits() == 0 { throw fail("invalid number", at: start) }
        }
    }

    /// Reads a string starting at its opening quote and returns its decoded text.
    private mutating func parseString() throws -> String {
        let open = i
        i += 1
        var raw: [UInt8] = []
        var units: [UInt16] = []
        func flush() {
            if !units.isEmpty { raw.append(contentsOf: Array(String(decoding: units, as: UTF16.self).utf8)); units = [] }
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                flush()
                return String(decoding: raw, as: UTF8.self)
            }
            if c < 0x20 { throw fail("control character in a string") }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < b.count else { break }
                switch b[i] {
                case UInt8(ascii: "\""): flush(); raw.append(0x22)
                case UInt8(ascii: "\\"): flush(); raw.append(0x5C)
                case UInt8(ascii: "/"): flush(); raw.append(0x2F)
                case UInt8(ascii: "b"): flush(); raw.append(0x08)
                case UInt8(ascii: "f"): flush(); raw.append(0x0C)
                case UInt8(ascii: "n"): flush(); raw.append(0x0A)
                case UInt8(ascii: "r"): flush(); raw.append(0x0D)
                case UInt8(ascii: "t"): flush(); raw.append(0x09)
                case UInt8(ascii: "u"):
                    guard i + 4 < b.count, let unit = UInt16(String(decoding: b[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else {
                        throw fail("invalid \\u escape")
                    }
                    units.append(unit)
                    i += 4
                default: throw fail("invalid escape in a string")
                }
                i += 1
                continue
            }
            flush()
            raw.append(c)
            i += 1
        }
        throw fail("unterminated string", at: open)
    }

    // MARK: removal

    /// The edits that delete `member`, with the comma that separates it from its neighbours.
    /// The comma that follows the value ending at `position`, if one does.
    func comma(after position: Int) -> Int? {
        var scanner = JSONScanner(b, jsonc: jsonc)
        scanner.i = position
        try? scanner.skipTrivia()
        return scanner.i < b.count && b[scanner.i] == UInt8(ascii: ",") ? scanner.i : nil
    }

    /// The end of the line `position` is on (the offset of its newline), if only blanks and a line comment lie between.
    func endOfLine(from position: Int) -> Int? {
        var j = position
        while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
        if jsonc, j + 1 < b.count, b[j] == UInt8(ascii: "/"), b[j + 1] == UInt8(ascii: "/") {
            while j < b.count, b[j] != 0x0A, b[j] != 0x0D { j += 1 }
        }
        if j < b.count, b[j] == 0x0D { return j }
        return j < b.count && b[j] == 0x0A ? j : nil
    }

    func removalEdits(of member: JSONObjectSpan.Member, index: Int, in object: JSONObjectSpan) -> [JSONConfigEditor.Edit] {
        let own = comma(after: member.valueEnd)
        let after = (own.map { $0 + 1 }) ?? member.valueEnd
        let previous = index > 0 ? object.members[index - 1] : nil
        let isLast = index == object.members.count - 1
        // The rest of the member's last line: blanks and (in JSONC) a line comment, then the newline.
        var lineEnd = after
        while lineEnd < b.count, b[lineEnd] == 0x20 || b[lineEnd] == 0x09 { lineEnd += 1 }
        if jsonc, lineEnd + 1 < b.count, b[lineEnd] == UInt8(ascii: "/"), b[lineEnd + 1] == UInt8(ascii: "/") {
            while lineEnd < b.count, b[lineEnd] != 0x0A { lineEnd += 1 }
        }
        if lineEnd < b.count, b[lineEnd] == 0x0D { lineEnd += 1 }
        let ownLines = JSONConfigEditor.ownLineIndent(of: member.keyStart, in: b) != nil && (lineEnd < b.count && b[lineEnd] == 0x0A)
        var edits: [JSONConfigEditor.Edit] = []
        if ownLines {
            var lineStart = member.keyStart
            while lineStart > 0, b[lineStart - 1] != 0x0A { lineStart -= 1 }
            edits.append(.init(range: lineStart..<(lineEnd + 1), text: ""))
            // The previous member loses its comma unless this one had a trailing comma of its own to leave behind.
            if isLast, own == nil, let previous, let c = comma(after: previous.valueEnd) { edits.append(.init(range: c..<(c + 1), text: "")) }
            return edits
        }
        if let own {
            var end = own + 1
            if end < b.count, b[end] == 0x20 { end += 1 }
            return [.init(range: member.keyStart..<end, text: "")]
        }
        if let previous { return [.init(range: previous.valueEnd..<member.valueEnd, text: "")] }
        return [.init(range: (object.start + 1)..<(object.end - 1), text: "")]
    }
}
