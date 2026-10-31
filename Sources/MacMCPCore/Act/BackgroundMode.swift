import ApplicationServices
import CoreGraphics
import Foundation

/// Set once by the connection preamble, never by a tool argument or MCP metadata. Task-local so concurrent
/// foreground and background clients cannot change each other's routes.
public enum BackgroundMode {
    @TaskLocal public static var enabled = false
    /// The explicit field being edited, or the app-local focus pinned before a sequence of targeted keys.
    @TaskLocal public static var target: AXElement?
    @TaskLocal public static var row: Row?

    public static let instructions = "Background mode: enabled by this client's --background configuration. "
        + "Use app= or element refs. Accessibility actions and window captures work without activation. "
        + "Pointer input, focusing windows and foreground fallbacks are refused. Only a person can change the client configuration."

    public static func refusal(_ operation: String) -> String {
        "Refused: background mode cannot " + operation + ". Use an accessibility ref or mac_menu; "
            + "if this needs foreground input, ask a person to reconnect this client without --background."
    }

    public static func requireForeground(_ operation: String) throws {
        if enabled { throw ActionError(refusal(operation), audit: "Refused: background mode") }
    }

    /// Defense at the AX adapter: no focus, raise, positioning or activation attributes/actions can escape a
    /// higher-level refusal. Accessibility enabling flags are read support and do not change keyboard focus.
    static func allows(attribute: String) -> Bool {
        [kAXValueAttribute, kAXSelectedAttribute, kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute,
         "AXManualAccessibility", "AXEnhancedUserInterface"].contains(attribute)
    }

    static func allows(action: String) -> Bool {
        [kAXPressAction, kAXPickAction, kAXShowMenuAction, kAXIncrementAction, kAXDecrementAction,
         "AXScrollToVisible"].contains(action)
    }

    /// An element must belong to the target's AX window or be attached to that app's menu tree. A PID alone
    /// cannot establish which host owns a remote child, and an unreadable parent chain proves nothing.
    public static func owns(_ element: AXElement, pid: pid_t) -> Bool {
        guard element.pid == pid else { return false }
        if Input.windowOwner(of: element) == pid { return true }
        guard [kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole].contains(element.role ?? "") else { return false }
        return Actions.isWithin(element, AXElement.application(pid: pid, timeout: Input.focusTimeout))
    }

    public static func contextRefusal(owned: Bool, finder: Bool, filePanel: Bool, secure: Bool) -> String? {
        if !owned { return refusal("check an unknown or remote accessibility receiver") }
        if finder { return refusal("act on Finder selections; use a foreground client for file operations") }
        if filePanel { return refusal("act in a file panel; use a foreground client for file operations") }
        if secure { return refusal("type into or act on a secure field") }
        return nil
    }

    /// App-switching/system shortcuts are unsuitable even when delivered to an app instead of the HID stream.
    public static func keyRefusal(_ key: KeySpec) -> String? {
        let command = key.flags.contains(.maskCommand)
        if (command && [48, 50, 12, 4].contains(key.key)) || key.flags.contains(.maskSecondaryFn)
            || (key.flags.contains(.maskControl) && [123, 124, 125, 126].contains(key.key))
            || key.key >= 64 && ![76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(key.key) {
            return refusal("send a shortcut that may switch apps, windows or system focus")
        }
        return nil
    }

    /// PID delivery cannot be bound to a remote view service's host. No fallback to system-wide focus is valid.
    static func keyboardRefusal(pid: pid_t, elementPID: pid_t?, windowPID: pid_t?, matches: Bool,
                                secure: Bool, secureInput: Bool) -> String? {
        if secureInput { return refusal("send input while Secure Input is enabled; ask a person to turn it off") }
        if secure { return refusal("type into a secure field") }
        guard elementPID == pid, windowPID == pid, matches else {
            return refusal("prove keyboard delivery to the intended element; take mac_snapshot app= and use AX typing or a ref")
        }
        return nil
    }
}
