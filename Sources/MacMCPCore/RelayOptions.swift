/// Relay options are parsed before connecting: a misspelled opt-in must never silently start a foreground client.
public struct RelayOptions {
    public let background: Bool
    public let requiresConsent: Bool

    public enum ParseError: Error, CustomStringConvertible {
        case unknown(String), duplicateBackground, duplicateConsent
        public var description: String {
            switch self {
            case let .unknown(argument): "unknown relay argument '\(argument)'. Usage: mac-mcp [relay] [--background] [--require-consent]"
            case .duplicateBackground: "duplicate --background. Usage: mac-mcp [relay] [--background] [--require-consent]"
            case .duplicateConsent: "duplicate --require-consent. Usage: mac-mcp [relay] [--background] [--require-consent]"
            }
        }
    }

    public init(_ arguments: [String]) throws {
        if let unknown = arguments.first(where: { !["--background", "--require-consent"].contains($0) }) { throw ParseError.unknown(unknown) }
        guard arguments.filter({ $0 == "--background" }).count <= 1 else { throw ParseError.duplicateBackground }
        guard arguments.filter({ $0 == "--require-consent" }).count <= 1 else { throw ParseError.duplicateConsent }
        background = arguments.contains("--background")
        requiresConsent = arguments.contains("--require-consent")
    }
}
