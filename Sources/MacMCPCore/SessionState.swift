import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Whether the GUI session can be driven right now, and which permissions are in place.
///
/// The box keeps screen lock on and auto-login off by design: a human unlocks via Remote Access when needed.
/// So every action checks this first and fails fast with something the agent can relay, rather than
/// clicking into a lock screen or capturing a black display.
public struct SessionState: Sendable, Equatable {
    public var onConsole: Bool
    public var screenLocked: Bool
    public var displayAsleep: Bool
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(onConsole: Bool, screenLocked: Bool, displayAsleep: Bool, accessibility: Bool, screenRecording: Bool) {
        self.onConsole = onConsole
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    /// Builds state from a `CGSessionCopyCurrentDictionary` dictionary. `CGSSessionScreenIsLocked` is only
    /// present while the screen is locked; a nil dictionary means this process has no GUI session at all.
    public init(sessionInfo: [String: Any]?, displayAsleep: Bool, accessibility: Bool, screenRecording: Bool) {
        self.onConsole = sessionInfo?["kCGSSessionOnConsoleKey"] as? Bool ?? false
        self.screenLocked = sessionInfo?["CGSSessionScreenIsLocked"] as? Bool ?? false
        self.displayAsleep = displayAsleep
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public static func current() -> SessionState {
        SessionState(
            sessionInfo: CGSessionCopyCurrentDictionary() as? [String: Any],
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    /// Screen Recording as of right now. `CGPreflightScreenCaptureAccess` caches its answer for the life of the
    /// process, so a grant made after launch reads as missing until restart; ScreenCaptureKit sees it live.
    public static func screenRecordingLive() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
    }

    /// Why GUI actions can't run now, phrased for the agent to pass on. Nil when actions may proceed.
    public var actionBlocker: String? {
        if !onConsole {
            return "NO GUI SESSION: nobody is logged in at the console of this Mac (for example after a reboot). "
                + "Log in via Remote Access (Screen Sharing), then retry."
        }
        if screenLocked {
            return "SCREEN LOCKED: a person must unlock this Mac via Remote Access (Screen Sharing). Retry afterwards, or call mac_wait until=unlock to wait for it."
        }
        if displayAsleep {
            return "DISPLAY ASLEEP: wake the display via Remote Access, then retry."
        }
        if !accessibility {
            return "ACCESSIBILITY NOT GRANTED to MacMCP.app. Enable it in System Settings > Privacy & Security > "
                + "Accessibility (\"Device Control\" on macOS 27); run `mac-mcp doctor` for details."
        }
        return nil
    }

    /// Compact state for response headers.
    public var summary: String {
        if let blocker = actionBlocker { return blocker.components(separatedBy: ":").first ?? blocker }
        return screenRecording ? "ready" : "ready (no screen recording)"
    }
}
