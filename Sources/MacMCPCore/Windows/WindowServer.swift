import AppKit
import ApplicationServices
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

    /// Reuse the step's snapshot for prompt detection and pointer ownership.
    static func owner(at p: CGPoint, in windows: [WindowInfo]) -> pid_t? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let displays = ids.prefix(Int(count)).map(CGDisplayBounds)
        return windows.first {
            $0.alpha > 0.01 && $0.owner != "Window Server" && $0.bounds.contains(p)
                && !($0.layer > 0 && displays.contains($0.bounds))
        }?.pid
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

    /// Processes that draw macOS security, permission, consent and pairing prompts, and nothing else, by bundle ID.
    /// The server must never act on these, only report them. Each was checked against /System, /usr/libexec and the
    /// App cryptex on macOS 26.
    static let systemPromptBundleIDs: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.authorizationhost",             // admin passwords, authorization
        "com.apple.UserNotificationCenter",                                    // legacy alerts, older TCC prompts
        "com.apple.coreservices.uiagent",                                      // "downloaded from the internet" (Gatekeeper)
        "com.apple.tcc.AuthorizationPromptService",                            // privacy (TCC) and Automation consent
        "com.apple.accessibility.universalAccessAuthWarn",                     // "would like to control this computer"
        "com.apple.LocalAuthentication.UIAgent",                               // Touch ID / password (coreautha)
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",    // passkeys and saved passwords
        "com.apple.BluetoothUIServer", "com.apple.BluetoothUIService",         // Bluetooth pairing codes
        "com.apple.ssinvitationagent",                                         // screen-sharing invitations
        "com.apple.ScreenSaver.Engine",
    ]

    /// Processes that draw prompts but also windows that aren't: AirDrop's accept prompt and its transfer progress
    /// (AirDropUI, sharingd), screen-sharing requests and the overlays and indicators of a session in progress
    /// (ScreensharingAgent, the screen-sharing menu extra, AppleVNCServer's "would like to view" consent), the lock
    /// screen and shutdown confirmations (loginwindow, whose lock screen the session check covers), Software Update's
    /// restart prompts and its window. Only their windows that look like prompts count (`isDialog`), so a person
    /// watching through screen sharing doesn't block agents.
    static let mixedPromptBundleIDs: Set<String> = [
        "com.apple.sharingd", "com.apple.Sharing.AirDropUI", "com.apple.screensharing.agent", "com.apple.SSMenuAgent",
        "com.apple.AppleVNCServer", "com.apple.loginwindow", "com.apple.SoftwareUpdate",
    ]

    /// The same processes by executable name, for those without a bundle ID (tccd) or whose bundle ID can't be read.
    /// Only executables in the read-only system volume count, so an app can't pass itself off as one.
    static let systemPromptExecutables: Set<String> = [
        "SecurityAgent", "authorizationhost", "UserNotificationCenter", "CoreServicesUIAgent", "tccd",
        "AuthorizationPromptService", "universalAccessAuthWarn", "coreautha", "AuthenticationServicesAgent",
        "BluetoothUIServer", "BluetoothUIService", "SSInvitationAgent", "ScreenSaverEngine",
    ]
    static let mixedPromptExecutables: Set<String> = [
        "sharingd", "AirDropUI", "ScreensharingAgent", "SSMenuAgent", "AppleVNCServer", "loginwindow", "Software Update",
    ]

    /// Display names, the fallback when neither of the above can be read.
    static let systemPromptOwners: Set<String> = [
        "UserNotificationCenter", "SecurityAgent", "coreautha", "universalAccessAuthWarn", "CoreServicesUIAgent",
        "TCC", "tccd", "SystemUIServer Prompt", "ScreenSaverEngine", "AuthorizationPromptService",
        "AuthenticationServicesAgent", "BluetoothUIServer", "SSInvitationAgent",
    ]
    static let mixedPromptOwners: Set<String> = ["Software Update", "loginwindow", "AirDropUI", "sharingd", "ScreensharingAgent"]

    public enum PromptKind: Sendable, Equatable {
        case none
        /// Every window the process shows is a prompt.
        case all
        /// Only its windows that look like prompts are (`isDialog`).
        case dialogs
    }

    /// Whether a process (known by any of these) draws system prompts, and which of its windows are. Pure, for tests.
    static func promptKind(bundleID: String?, executablePath: String?, name: String?) -> PromptKind {
        if let bundleID {
            if systemPromptBundleIDs.contains(bundleID) { return .all }
            if mixedPromptBundleIDs.contains(bundleID) { return .dialogs }
        }
        if let path = executablePath, ["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: path.hasPrefix) {
            let file = (path as NSString).lastPathComponent
            if systemPromptExecutables.contains(file) { return .all }
            if mixedPromptExecutables.contains(file) { return .dialogs }
        }
        guard let name else { return .none }
        return systemPromptOwners.contains(name) ? .all : mixedPromptOwners.contains(name) ? .dialogs : .none
    }

    /// Whether a process draws system prompts at all: what may never be acted on, moved, hidden or quit.
    static func isPromptProcess(bundleID: String?, executablePath: String?, name: String?) -> Bool {
        promptKind(bundleID: bundleID, executablePath: executablePath, name: name) != .none
    }

    /// What the accessibility API says about one window.
    struct WindowTraits: Sendable, Equatable {
        var role: String?
        var subrole: String?
        var modal = false
        /// An accept/decline pair, as alerts and consent prompts have.
        var hasDefaultOrCancelButton = false
        var hasCloseButton = false

        /// A dialog, sheet, floating panel or modal window, or one with a default or cancel button.
        var isDialog: Bool {
            role == "AXSheet" || ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(subrole) || modal
                || hasDefaultOrCancelButton
        }

        /// A document-style window: a standard window with a close button, and nothing of a dialog.
        var isOrdinary: Bool { role == "AXWindow" && subrole == "AXStandardWindow" && hasCloseButton && !isDialog }
    }

    /// Whether a window of a process that shows prompts and ordinary windows alike is a prompt. In doubt it is, since
    /// it then only blocks input. It isn't if it is an ordinary window on the normal layer (an AirDrop or Software
    /// Update window), or something that covers a whole display without being a dialog (the lock screen, which the
    /// session check covers, or a screen-sharing curtain or overlay). Anything above the normal layer that doesn't
    /// cover a display (the modal-panel, alert and pop-up levels), and anything accessibility calls a dialog, is one.
    /// `traits` is asked only when the layer doesn't settle it.
    static func isDialog(_ w: WindowInfo, displays: [CGRect], traits: () -> WindowTraits?) -> Bool {
        let coversDisplay = displays.contains { w.bounds.contains($0) }
        if w.layer > 0 && !coversDisplay { return true }
        let traits = traits()
        if traits?.isDialog == true { return true }
        if coversDisplay { return false }
        return !(w.layer == 0 && traits?.isOrdinary == true)
    }

    /// Whether this window, owned by a process of this kind, is a prompt. Slivers and menu-bar items (a sharing
    /// indicator) never are.
    static func isPrompt(_ w: WindowInfo, kind: PromptKind, displays: [CGRect], traits: () -> WindowTraits?) -> Bool {
        guard w.alpha > 0, w.bounds.width >= 60, w.bounds.height >= 40 else { return false }
        switch kind {
        case .none: return false
        case .all: return true
        case .dialogs: return isDialog(w, displays: displays, traits: traits)
        }
    }

    static func activeDisplays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// The process's windows and sheets as accessibility reports them, by frame (global points, top-left origin, as
    /// the window server's bounds). Read-only, with a short timeout; empty without the Accessibility permission, for
    /// a process that doesn't answer, and for MacMCP itself (which would wait on its own main thread).
    /// `timeout` bounds each accessibility message (each element is given it), and `budget` the whole read: what
    /// isn't read by then is left out, so its windows count as prompts.
    static func accessibilityWindows(of pid: pid_t, timeout: Float = 0.5,
                                     budget: TimeInterval = .infinity) -> [(frame: CGRect, traits: WindowTraits)] {
        guard pid != getpid() else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXDefaultButtonAttribute,
                     kAXCancelButtonAttribute, kAXCloseButtonAttribute, kAXPositionAttribute, kAXSizeAttribute]
        func bounded(_ e: AXElement) -> AXElement {
            AXUIElementSetMessagingTimeout(e.raw, timeout)
            return e
        }
        func describe(_ e: AXElement) -> (frame: CGRect, traits: WindowTraits)? {
            guard let v = e.read(names), let f = frame(position: v[kAXPositionAttribute], size: v[kAXSizeAttribute]) else { return nil }
            return (f, WindowTraits(role: v[kAXRoleAttribute] as? String, subrole: v[kAXSubroleAttribute] as? String,
                                    modal: v[kAXModalAttribute] as? Bool ?? false,
                                    hasDefaultOrCancelButton: v[kAXDefaultButtonAttribute] != nil || v[kAXCancelButtonAttribute] != nil,
                                    hasCloseButton: v[kAXCloseButtonAttribute] != nil))
        }
        var out: [(frame: CGRect, traits: WindowTraits)] = []
        for window in AXElement.application(pid: pid, timeout: timeout).elements(kAXWindowsAttribute).map(bounded) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let d = describe(window) { out.append(d) }
            // A sheet is a window of its own to the window server, but a child of its window to accessibility.
            for child in window.elements(kAXChildrenAttribute).map(bounded) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if child.role == "AXSheet", let d = describe(child) { out.append(d) }
            }
        }
        return out
    }

    /// Recent decisions about windows whose accessibility had to be asked, by window (and where it is), for a moment:
    /// the input guard asks before every step, and a process that answers slowly would otherwise use up each step's
    /// time. A window that couldn't be read in time counts as a prompt, alone, until it is asked again.
    final class PromptCache: @unchecked Sendable {
        struct Key: Hashable {
            let id: CGWindowID, pid: pid_t, layer: Int
            let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
            init(_ w: WindowInfo) {
                (id, pid, layer) = (w.id, w.pid, w.layer)
                (x, y, width, height) = (w.bounds.minX, w.bounds.minY, w.bounds.width, w.bounds.height)
            }
        }
        private let lock = NSLock()
        private var entries: [Key: (prompt: Bool, expires: TimeInterval)] = [:]
        static let lifetime: TimeInterval = 1.5

        func decision(_ w: WindowInfo, now: TimeInterval, decide: () -> Bool) -> Bool {
            let key = Key(w)
            if let hit = lock.withLock({ entries[key] }), hit.expires > now { return hit.prompt }
            let prompt = decide()
            lock.withLock {
                entries = entries.filter { $0.value.expires > now }
                entries[key] = (prompt, now + Self.lifetime)
            }
            return prompt
        }
    }
    static let promptCache = PromptCache()

    /// Each accessibility message may take this long while the input guard classifies a window, and the whole read
    /// for one process this long: well inside a step's 0.25 s.
    static let promptTraitsTimeout: Float = 0.05
    static let promptTraitsBudget: TimeInterval = 0.1

    /// What accessibility says about this window, matched by frame; nil if nothing matches.
    static func traits(of w: WindowInfo, in windows: [(frame: CGRect, traits: WindowTraits)]) -> WindowTraits? {
        windows.first { f, _ in
            abs(f.minX - w.bounds.minX) <= 1 && abs(f.minY - w.bounds.minY) <= 1
                && abs(f.width - w.bounds.width) <= 1 && abs(f.height - w.bounds.height) <= 1
        }?.traits
    }

    /// The process's bundle ID and executable path, as macOS reports them.
    static func processIdentity(_ pid: pid_t) -> (bundleID: String?, path: String?) {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = n > 0 ? String(decoding: buffer.prefix(Int(n)), as: UTF8.self) : nil
        return (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, path)
    }

    static func promptKind(of w: WindowInfo) -> PromptKind {
        let id = processIdentity(w.pid)
        return promptKind(bundleID: id.bundleID, executablePath: id.path, name: w.owner)
    }

    /// System prompts currently on screen.
    public static func systemPrompts(in windows: [WindowInfo]? = nil) -> [WindowInfo] {
        systemPrompts(in: windows ?? onScreenWindows(), cache: promptCache) {
            accessibilityWindows(of: $0, timeout: promptTraitsTimeout, budget: promptTraitsBudget)
        }
    }

    /// Only windows whose decision needed accessibility are cached; the rest are decided from the window list alone.
    static func systemPrompts(in windows: [WindowInfo], cache: PromptCache,
                              describe: (pid_t) -> [(frame: CGRect, traits: WindowTraits)]) -> [WindowInfo] {
        var kinds: [pid_t: PromptKind] = [:]
        var described: [pid_t: [(frame: CGRect, traits: WindowTraits)]] = [:]
        let displays = activeDisplays(), now = ProcessInfo.processInfo.systemUptime
        return windows.filter { w in
            let kind = kinds[w.pid] ?? promptKind(of: w)
            kinds[w.pid] = kind
            var asked = false
            let quick = isPrompt(w, kind: kind, displays: displays) { asked = true; return nil }
            guard asked else { return quick }
            return cache.decision(w, now: now) {
                isPrompt(w, kind: kind, displays: displays) {
                    let windows = described[w.pid] ?? describe(w.pid)
                    described[w.pid] = windows
                    return traits(of: w, in: windows)
                }
            }
        }
    }

    /// Whether this one window is a system prompt.
    public static func isSystemPrompt(window w: WindowInfo) -> Bool {
        isPrompt(w, kind: promptKind(of: w), displays: activeDisplays()) { traits(of: w, in: accessibilityWindows(of: w.pid)) }
    }

    /// Whether a process draws system prompts: none of its windows may be acted on, and it may not be moved, hidden
    /// or quit, even while it shows nothing a person must answer.
    public static func isSystemPrompt(pid: pid_t) -> Bool {
        let id = processIdentity(pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (id.bundleID == nil && id.path == nil ? onScreenWindows().first(where: { $0.pid == pid })?.owner : nil)
        return isPromptProcess(bundleID: id.bundleID, executablePath: id.path, name: name)
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
