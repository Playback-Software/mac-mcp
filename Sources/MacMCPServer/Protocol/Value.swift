import Foundation

/// A JSON value: tool arguments, schemas and protocol payloads.
public enum Value: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    public var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    public var boolValue: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var intValue: Int? {
        switch self {
        case let .int(i): i
        case let .double(d) where d.rounded() == d && abs(d) < 1e15: Int(d)
        default: nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case let .double(d): d
        case let .int(i): Double(i)
        default: nil
        }
    }
    public var objectValue: [String: Value]? { if case let .object(o) = self { o } else { nil } }
    public var arrayValue: [Value]? { if case let .array(a) = self { a } else { nil } }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> Value? { objectValue?[key] }
}

extension Value: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([Value].self) { self = .array(a) }
        else if let o = try? c.decode([String: Value].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral s: String) { self = .string(s) }
    public init(integerLiteral i: Int) { self = .int(i) }
    public init(floatLiteral d: Double) { self = .double(d) }
    public init(booleanLiteral b: Bool) { self = .bool(b) }
    public init(arrayLiteral elements: Value...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, Value)...) { self = .object(Dictionary(elements) { $1 }) }
    public init(nilLiteral: ()) { self = .null }
}

extension Value {
    /// One-line JSON, keys sorted (stable output helps clients' prompt caching).
    public func jsonData() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    public static func parse(_ data: Data) throws -> Value { try JSONDecoder().decode(Value.self, from: data) }
}
