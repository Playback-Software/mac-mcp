import ApplicationServices
import Foundation

extension BackgroundMode {
    struct MenuIdentity {
        var identifier: String? = nil
        var actions: [String] = []
        var title: String = ""
        var submenu = false
    }

    /// AXPress invokes the command itself, not its key equivalent. Read command metadata and its menu ancestry;
    /// a harmless command may have a key equivalent that would be unsafe to synthesize (including a function key).
    public static func menuRefusal(_ element: AXElement) -> String? {
        guard [kAXMenuItemRole, kAXMenuBarItemRole].contains(element.role ?? "") else { return nil }
        var identities: [MenuIdentity] = [], node: AXElement? = element
        var seen = Set<AXElement>()
        for _ in 0..<16 {
            guard let item = node, seen.insert(item).inserted else {
                return refusal("check this menu command's ancestry; take a new mac_snapshot")
            }
            guard let identity = item.read(reporting: [kAXRoleAttribute, kAXTitleAttribute, kAXIdentifierAttribute]),
                  identity.failed.isEmpty, let role = identity.values[kAXRoleAttribute] as? String else {
                return refusal("read this menu command's identity; take a new mac_snapshot")
            }
            if role == kAXApplicationRole || role == kAXMenuBarRole { return menuRefusal(identities) }
            if [kAXMenuItemRole, kAXMenuBarItemRole, kAXMenuRole].contains(role) {
                let selectors = item.read(["AXMenuItemAction", "AXAction", "AXSelector"]) ?? [:]
                let children = identities.isEmpty && role == kAXMenuItemRole ? item.elements(reporting: kAXChildrenAttribute) : nil
                if children?.error != nil { return refusal("check whether this menu command opens a submenu") }
                identities.append(MenuIdentity(identifier: identity.values[kAXIdentifierAttribute] as? String,
                                               actions: selectors.values.compactMap { $0 as? String } + item.actionNames,
                                               title: identity.values[kAXTitleAttribute] as? String ?? "",
                                               submenu: children?.elements.isEmpty == false))
            }
            node = item.element(kAXParentAttribute)
        }
        return refusal("check this menu command's ancestry within the read limit")
    }

    /// Identifiers/selectors take precedence over localized titles. Every Window-menu command is excluded,
    /// including dynamically named windows, Move & Resize, Move to Display/Space and full-screen tiling submenus.
    static func menuRefusal(_ identities: [MenuIdentity]) -> String? {
        if identities.first?.submenu == true {
            return refusal("open a submenu that may take the person's keyboard; use mac_menu for an exposed leaf command")
        }
        let commands: Set<String> = [
            "togglefullscreen", "performminiaturize", "performzoom", "miniaturizeall", "arrangeinfront",
            "performclose", "close", "hide", "hideotherapplications", "terminate",
            "forcequit", "forcequitapplication", "forcequitapplications", "copy", "cut",
            "fullscreen", "enterfullscreen", "exitfullscreen", "minimize", "minimizeall", "zoom", "hideothers", "quit", "closewindow",
        ]
        let windowMenus: Set<String> = ["window", "windowmenu", "nswindowmenu", "nswindowsmenu"]
        for identity in identities {
            let identifier = identity.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tokens = ([identifier] + identity.actions).map(menuToken)
            if tokens.contains(where: { commands.contains($0) || windowMenus.contains($0)
                || $0.hasPrefix("movewindow") || $0.hasPrefix("tilewindow") || $0.hasPrefix("movetoactivespace") }) {
                return refusal("choose a menu command that manages windows, Spaces, apps or the shared clipboard")
            }
            guard identifier.isEmpty else { continue }
            let title = SessionSafety.normalized(identity.title)
            if ["window", "minimize", "minimize all", "zoom", "bring all to front", "enter full screen", "exit full screen",
                "close", "close window", "copy", "cut", "hide", "hide others", "quit", "force quit"].contains(title)
                || title.hasPrefix("close ") || title.hasPrefix("hide ") || title.hasPrefix("quit ") || title.hasPrefix("force quit ") {
                return refusal("choose a menu command that manages windows, Spaces, apps or the shared clipboard")
            }
        }
        return nil
    }

    private static func menuToken(_ value: String) -> String {
        let component = value.split(separator: ".").last.map(String.init) ?? value
        let token = component.lowercased().filter { $0.isLetter || $0.isNumber }
        return token.hasPrefix("ns") && token != "nswindowmenu" && token != "nswindowsmenu" ? String(token.dropFirst(2)) : token
    }
}
