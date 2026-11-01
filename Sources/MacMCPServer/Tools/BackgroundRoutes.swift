import Foundation
import MacMCPCore

/// These tools can dispatch work outside the AX/input adapters (including launching Safari on a read). Their
/// effects cannot be constrained to a background app. The person chooses a foreground connection for that work.
func backgroundRefusal(tool: String, args: ToolArgs) -> String? {
    if tool.hasPrefix("web_") || tool == "mac_script" || tool == "mac_shortcut" && args.string("action") != "list" {
        return BackgroundMode.refusal("run " + tool + " with unconstrained app or input effects")
    }
    switch tool {
    case "mac_drag", "mac_hover": return BackgroundMode.refusal("use pointer input (" + tool + ")")
    case "mac_click":
        if args.string("ref") == nil { return BackgroundMode.refusal("click coordinates or screenshot pixels") }
    case "mac_scroll":
        if args.string("to_ref") == nil { return BackgroundMode.refusal("scroll with the pointer; use mac_scroll to_ref") }
    case "mac_app":
        let action = args.string("action") ?? "list"
        if action != "list" && action != "launch" { return BackgroundMode.refusal(action + " an app") }
        if args.string("open") != nil { return BackgroundMode.refusal("open files or URLs through app launch") }
    case "mac_clipboard":
        if args.string("action") == "set" { return BackgroundMode.refusal("write the shared clipboard; use mac_type") }
    case "mac_window":
        if args.string("action") != "list" { return BackgroundMode.refusal("manage or focus windows") }
    default: break
    }
    return nil
}
