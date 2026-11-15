import ApplicationServices
import Foundation

public enum MenuHints {
    public struct Item: Sendable {
        public var path: [String]
        public var enabled: Bool
        public init(path: [String], enabled: Bool = true) { self.path = path; self.enabled = enabled }
    }

    /// A title match is a suggestion, not proof that two controls have the same effect.
    public static func matching(_ title: String, items: [Item]) -> [String]? {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let target = normalized(title)
        guard !target.isEmpty else { return nil }
        let matches = items.filter { $0.enabled && $0.path.count >= 2 && normalized($0.path.last ?? "") == target }
        guard matches.count == 1, !matches[0].path.contains(where: { $0.contains(">") || $0.contains("\n") }) else { return nil }
        return matches[0].path
    }

    /// Only already-exposed AX children: never presses, opens or dismisses a menu.
    public static func exposed(pid: pid_t) -> [Item] {
        guard let bar = AXElement.application(pid: pid, timeout: 0.1).element(kAXMenuBarAttribute) else { return [] }
        let start = ContinuousClock.now
        var pending = bar.elements(kAXChildrenAttribute).reversed().map { ($0, [String]()) }
        var seen: Set<AXElement> = [], items: [Item] = []
        while let (element, path) = pending.popLast(), seen.count < 500,
              start.duration(to: .now) < .milliseconds(100), !Task.isCancelled {
            guard seen.insert(element).inserted, path.count < 8 else { continue }
            AXUIElementSetMessagingTimeout(element.raw, 0.05)
            let attributes = element.read([kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute]) ?? [:]
            let title = attributes[kAXTitleAttribute] as? String ?? ""
            let role = attributes[kAXRoleAttribute] as? String
            let next = title.isEmpty || !["AXMenuItem", "AXMenuBarItem"].contains(role ?? "") ? path : path + [String(title.prefix(120))]
            let children = element.elements(kAXChildrenAttribute)
            if attributes[kAXRoleAttribute] as? String == "AXMenuItem", children.isEmpty {
                items.append(Item(path: next, enabled: attributes[kAXEnabledAttribute] as? Bool == true))
            }
            pending += children.prefix(500 - seen.count).reversed().map { ($0, next) }
        }
        return items
    }
}
