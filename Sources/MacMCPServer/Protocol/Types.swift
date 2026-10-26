import Foundation

/// A tool as listed by `tools/list`.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: Value
    public let annotations: Annotations

    public init(name: String, description: String, inputSchema: Value, annotations: Annotations) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    /// Behaviour hints. Clients differ in how they treat missing ones (Codex assumes destructive), so every tool sets
    /// all four.
    public struct Annotations: Sendable {
        public var readOnlyHint: Bool?
        public var destructiveHint: Bool?
        public var idempotentHint: Bool?
        public var openWorldHint: Bool?

        public init(readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil,
                    openWorldHint: Bool? = nil) {
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }

        var json: Value {
            var o: [String: Value] = [:]
            if let readOnlyHint { o["readOnlyHint"] = .bool(readOnlyHint) }
            if let destructiveHint { o["destructiveHint"] = .bool(destructiveHint) }
            if let idempotentHint { o["idempotentHint"] = .bool(idempotentHint) }
            if let openWorldHint { o["openWorldHint"] = .bool(openWorldHint) }
            return .object(o)
        }
    }

    /// A block of a tool result.
    public enum Content: Sendable {
        case text(String)
        /// Base64-encoded image data.
        case image(base64: String, mimeType: String)

        var json: Value {
            switch self {
            case let .text(t): ["type": "text", "text": .string(t)]
            case let .image(data, mime): ["type": "image", "data": .string(data), "mimeType": .string(mime)]
            }
        }
    }

    var json: Value {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema,
         "annotations": annotations.json]
    }
}

/// JSON-RPC 2.0 error codes used by MCP.
enum RPCError {
    static let parse = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}
