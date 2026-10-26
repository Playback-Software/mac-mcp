import AppKit
import Carbon
import CoreGraphics
import Foundation

/// One on-screen window as the window server reports it (front to back).
public struct WindowInfo: Sendable, Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let owner: String
    /// Needs Screen Recording; empty otherwise.
    public let title: String
    public let layer: Int
    public let bounds: CGRect
    public let alpha: Double

    public var isNormalLayer: Bool { layer == 0 }
}

public enum WindowServer {
    /// The process whose window receives a click at `p` (global points, top-left origin): the frontmost visible
    /// window containing it, desktop included. This is ground truth for where a mouse click goes; an accessibility
    /// hit test can come back empty (Safari's automation windows answer none) or name an overlay.
    ///
    /// Full-screen windows above the normal layer are skipped: they're click-through overlays (the Dock keeps an
    /// invisible one on layer 20). Menus, the visible Dock and status items are smaller, so they still count.
    public static func owner(at p: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let displays = ids.prefix(Int(count)).map(CGDisplayBounds)
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  (w[kCGWindowOwnerName as String] as? String) != "Window Server" else { continue }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard frame.contains(p) else { continue }
            if (w[kCGWindowLayer as String] as? Int ?? 0) > 0, displays.contains(frame) { continue }
            return pid
        }
        return nil
    }

    /// On-screen windows, front to back, excluding the desktop and slivers.
    public static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard bounds.width >= 2, bounds.height >= 2 else { return nil }
            return WindowInfo(id: id, pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                              title: w[kCGWindowName as String] as? String ?? "", layer: w[kCGWindowLayer as String] as? Int ?? 0,
                              bounds: bounds, alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// Processes that draw macOS security and permission prompts. The server must never act on these, only report them.
    static let systemPromptOwners: Set<String> = [
        "UserNotificationCenter", "SecurityAgent", "coreautha", "universalAccessAuthWarn", "CoreServicesUIAgent",
        "TCC", "tccd", "SystemUIServer Prompt", "Software Update", "loginwindow", "ScreenSaverEngine",
    ]

    /// Windows from system-prompt processes currently on screen.
    public static func systemPrompts(in windows: [WindowInfo]? = nil) -> [WindowInfo] {
        (windows ?? onScreenWindows()).filter { systemPromptOwners.contains($0.owner) && $0.alpha > 0 }
    }

    public static func isSystemPrompt(pid: pid_t) -> Bool {
        guard let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? onScreenWindows().first(where: { $0.pid == pid })?.owner else { return false }
        return systemPromptOwners.contains(name)
    }

    /// Secure Event Input: on while a password field (or a terminal's Secure Keyboard Entry) has focus.
    public static var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    /// The process holding Secure Event Input, if any. When it's the app being driven (its password field has focus),
    /// typing into that field still works; when it's another app, keystrokes and other tools can be affected.
    public static var secureInputPID: pid_t? {
        guard IsSecureEventInputEnabled(),
              let pid = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? Int else { return nil }
        return pid_t(pid)
    }
}
