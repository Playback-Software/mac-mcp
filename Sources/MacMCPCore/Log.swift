import Foundation

/// Diagnostic log line to stderr (the LaunchAgent routes stderr to ~/Library/Logs/MacMCP/agent.log).
public func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}
