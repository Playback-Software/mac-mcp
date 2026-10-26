import ApplicationServices
import Foundation

/// Actions that would end or suspend this Mac's login session (log out, restart, shut down, sleep, lock). MacMCP
/// refuses them outright, whatever the policy says: the console session hosts other services, and nobody is there to
/// log back in. Best effort across the obvious routes (Apple menu, shortcuts, scripts, loginwindow); not a sandbox.
public enum SessionSafety {
    public static let refusal = "Refused: that would end or suspend this Mac's login session (log out, restart, "
        + "shut down, sleep or lock). Other services depend on the session; MacMCP never does this. A person can, "
        + "via Remote Access."

    /// Processes whose windows are the session itself (the log-out/restart confirmation belongs to loginwindow).
    static let sessionApps: Set<String> = ["com.apple.loginwindow", "loginwindow"]

    public static func isSessionApp(bundleID: String?, name: String?) -> Bool {
        [bundleID, name].compactMap { $0?.lowercased() }.contains(where: sessionApps.contains)
    }

    static func normalized(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// An Apple-menu item that ends or suspends the session ("Log Out Ada Lovelace…", "Restart…", "Lock Screen").
    public static func isSessionMenuItem(_ title: String) -> Bool {
        let t = normalized(title)
        return t.hasPrefix("log out") || ["restart", "shut down", "sleep", "lock screen"].contains(t)
    }

    /// A mac_menu path through the Apple menu to a session item.
    public static func refusal(menuPath path: [String]) -> String? {
        guard path.count >= 2, normalized(path[0]) == "apple", isSessionMenuItem(path[path.count - 1]) else { return nil }
        return refusal
    }

    /// A menu item element in the Apple menu with a session title (a click on it, by ref or point).
    public static func refusal(element: AXElement) -> String? {
        guard element.string(kAXRoleAttribute) == kAXMenuItemRole,
              isSessionMenuItem(element.string(kAXTitleAttribute) ?? "") else { return nil }
        var node = element.element(kAXParentAttribute)
        for _ in 0..<4 {
            guard let n = node else { return nil }
            if n.string(kAXRoleAttribute) == kAXMenuBarItemRole {
                return normalized(n.string(kAXTitleAttribute) ?? "") == "apple" ? refusal : nil
            }
            node = n.element(kAXParentAttribute)
        }
        return nil
    }

    /// The system shortcuts for log out (⇧⌘Q, ⌥⇧⌘Q) and lock (⌃⌘Q).
    public static func refusal(keys: [KeySpec]) -> String? {
        let q: CGKeyCode = 12
        for k in keys where k.key == q && k.flags.contains(.maskCommand) {
            if k.flags.contains(.maskShift) || k.flags.contains(.maskControl) { return refusal }
        }
        return nil
    }

    /// Session commands in a script: Finder/System Events `log out`, `restart`, `shut down`, `sleep`, and the raw
    /// loginwindow events. String literals and comments are ignored, so `"restart the server"` in a document is fine.
    public static func refusal(script source: String, language: Scripts.Language) -> String? {
        let lower = source.lowercased()
        for code in ["aevtrlgo", "aevtlogo", "aevtrrst", "aevtrsdn", "aevtslep"] where lower.contains(code) { return refusal }
        let code = Scripts.code(of: source, language: language).lowercased()
        let pattern = language == .applescript
            ? #"(^|[^a-z])(log out|restart|shut down|sleep)([^a-z]|$)"#
            : #"\.(logout|logOut|restart|shutdown|shutDown|sleep)\s*\("#.lowercased()
        return code.range(of: pattern, options: .regularExpression) != nil ? refusal : nil
    }
}
