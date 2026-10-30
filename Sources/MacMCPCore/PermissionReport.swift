import Foundation

/// The Accessibility and Screen Recording grants as the agent's doctor report states them. The agent owns the grants,
/// so the only way to learn them is to ask it: `mac_doctor` writes these two lines (`lines`) and `mac-mcp setup`
/// reads them back (`parse`). Both live here so the wording can't drift apart.
public struct PermissionReport: Sendable, Equatable {
    public enum Grant: Sendable, Equatable {
        case granted
        case missing
        /// Granted, but not working; the text says what the doctor found.
        case needsAttention(String)

        public var isGranted: Bool { self == .granted }
    }

    public var accessibility: Grant
    public var screenRecording: Grant

    public init(accessibility: Grant, screenRecording: Grant) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    private static let accessibilityLabel = "Accessibility: "
    private static let screenRecordingLabel = "Screen Recording: "

    /// The two lines of the doctor's Permissions section.
    public static func lines(accessibility: Bool, screenRecording: Bool, captureFailure: String?) -> [String] {
        func mark(_ ok: Bool) -> String { ok ? "OK " : "!! " }
        return [
            "  \(mark(accessibility)) " + accessibilityLabel
                + (accessibility ? "granted"
                   : "MISSING — System Settings > Privacy & Security > Accessibility (\"Device Control\" on macOS 27): enable MacMCP"),
            "  \(mark(screenRecording && captureFailure == nil)) " + screenRecordingLabel
                + (screenRecording
                   ? captureFailure.map { "granted, but a test capture FAILED (\($0)). The grant may be stale: in System "
                       + "Settings > Privacy & Security > Screen & System Audio Recording, turn MacMCP off and on again, "
                       + "then restart the agent" } ?? "granted (test capture OK)"
                   : "MISSING — System Settings > Privacy & Security > Screen & System Audio Recording: enable MacMCP. "
                     + "If MacMCP isn't listed, click +, press Cmd-Shift-G and enter \(Paths.app)"),
        ]
    }

    /// The grants a doctor report states, or nil if it doesn't state both.
    public static func parse(_ doctor: String) -> PermissionReport? {
        func grant(_ label: String) -> Grant? {
            for line in doctor.split(separator: "\n", omittingEmptySubsequences: true) {
                for mark in ["OK ", "!! "] {
                    let prefix = "  \(mark) \(label)"
                    guard line.hasPrefix(prefix) else { continue }
                    let value = line.dropFirst(prefix.count)
                    if value.hasPrefix("MISSING") { return .missing }
                    if value.hasPrefix("granted (") || value == "granted" { return .granted }
                    return .needsAttention(String(value))
                }
            }
            return nil
        }
        guard let accessibility = grant(accessibilityLabel), let screenRecording = grant(screenRecordingLabel) else { return nil }
        return PermissionReport(accessibility: accessibility, screenRecording: screenRecording)
    }
}
