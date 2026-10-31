/// Relay options are parsed before connecting: a misspelled opt-in must never silently start a foreground client.
public struct RelayOptions {
    public let background: Bool

    public enum ParseError: Error, CustomStringConvertible {
        case unknown(String), duplicateBackground
        public var description: String {
            switch self {
            case let .unknown(argument): "unknown relay argument '\(argument)'. Usage: mac-mcp [relay] [--background]"
            case .duplicateBackground: "duplicate --background. Usage: mac-mcp [relay] [--background]"
            }
        }
    }

    public init(_ arguments: [String]) throws {
        if let unknown = arguments.first(where: { $0 != "--background" }) { throw ParseError.unknown(unknown) }
        guard arguments.count <= 1 else { throw ParseError.duplicateBackground }
        background = !arguments.isEmpty
    }
}
