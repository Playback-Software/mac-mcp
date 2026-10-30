import ApplicationServices
import Foundation
import MacMCPCore

/// What a file panel's commit check reads from a tree, so the walk runs the same on accessibility elements and on
/// the fake trees of the tests. A read that failed is nil, and the check refuses on it: a list whose selection can't be
/// read may have a protected file selected, a subtree that can't be read may hide the name field. An attribute the
/// element doesn't have (unsupported, no value) is absent, not failed.
struct PanelReader<N> {
    /// An element's role, subrole, identifier and AXURL; nil when the element or its role can't be read.
    var element: (N) -> PanelElement?
    /// A text field's value; nil when it can't be read.
    var value: (N) -> String?
    /// nil when the read failed (an element without children has none).
    var children: (N) -> [N]?
    /// The selected rows and items of a list; nil when the read failed.
    var selected: (N) -> [N]?
    /// What typing `text` into a text field would do (`OpenRoutes.typingRefusal`).
    var typing: (String, N) -> String?
    var tile: (URL) -> String?
}

/// What the commit check reads of one element.
struct PanelElement {
    var role: String
    /// nil when absent or unreadable: a text field whose subrole is unknown is checked as a name field.
    var subrole: String?
    var identifier: String?
    /// AXURL, as a URL with a scheme.
    var url: URL?
    /// AXURL or the identifier failed to read: what the element stands for is unknown.
    var unresolved = false
}

extension RouteGuards {
    static let unreadablePathRefusal = "Refused: the panel's selection can't be checked. Select a file with mac_app open= instead."
    static let incompletePanelRefusal = "Refused: the panel can't be checked completely. Use mac_app open= instead."

    static func panelRefusal(_ element: AXElement, pid: pid_t, policy: Policy) -> String? {
        guard let root = OpenRoutes.namingPanel(of: element) else { return nil }
        if let cancel = root.element(kAXCancelButtonAttribute), element == cancel { return nil }
        return panelRefusal(root, reader: accessibility(pid: pid, policy: policy))
    }

    /// Whether committing the panel under `root` would name or reach something refused: every text field's value, and
    /// what each selected row stands for (`target(of:in:reader:)`). The Go to Folder sheet commits its typed path,
    /// which its field holds and is checked as any field's value, or the completion row selected under it, which is
    /// checked by the path it stands for: one whose path can't be read refuses, since checking the typed prefix
    /// (`~/.ss`) says nothing about where the completion goes (`~/.ssh`).
    static func panelRefusal<N>(_ root: N, reader r: PanelReader<N>) -> String? {
        var queue = [(root, false)], visited = 0, unchecked = false
        while !queue.isEmpty, visited < 600 {
            let (e, inBrowser) = queue.removeFirst()
            visited += 1
            guard let info = r.element(e) else { return incompletePanelRefusal }
            let role = info.role
            // A column view's preview of the selected file (its tag editor) gives no name: that field is outside it.
            if !inBrowser, role == kAXTextFieldRole, info.subrole != "AXSearchField", info.subrole != "AXSecureTextField" {
                guard let value = r.value(e) else { return "Refused: the panel's file name can't be checked. Take mac_snapshot and retry." }
                if let refusal = r.typing(value, e) { return refusal }
            }
            let fileList = [kAXListRole, kAXTableRole, kAXOutlineRole, kAXBrowserRole].contains(role)
            if fileList {
                guard let rows = r.selected(e) else { return unreadablePathRefusal }
                for row in rows {
                    switch target(of: row, in: info, reader: r) {
                    case let .url(url): if let refusal = r.tile(url) { return refusal }
                    case .place: break
                    case .unknown: unchecked = true
                    }
                }
            }
            // A list's items are files, known through its selection, not fields: their names (App Store.app) aren't
            // being given, and walking each would outlast the guard's time. A column view holds its lists.
            if !fileList || role == kAXBrowserRole {
                guard let children = r.children(e) else { return incompletePanelRefusal }
                queue += children.map { ($0, inBrowser || role == kAXBrowserRole) }
            }
        }
        if !queue.isEmpty { return incompletePanelRefusal }
        return unchecked ? unreadablePathRefusal : nil
    }

    /// What a selected row of a panel's list stands for.
    enum RowTarget: Equatable {
        case url(URL)
        /// A sidebar place, which stands for the folder shown, not for a selected item.
        case place
        case unknown
    }

    /// What a selected row stands for: AXURL on the row or up to two levels into it (a column view's item holds it on
    /// its name field, a list view's row on the field in its cell), else a path an identifier there names (Go to
    /// Folder's completion row carries none, its path list has the path as its identifier). A row of an outline whose
    /// cells hold static text and no name field is a sidebar place (Favorites, Locations, Tags); a list view is an
    /// outline too, but its rows hold a name field. A read that fails before the row is resolved leaves it unknown.
    static func target<N>(of row: N, in list: PanelElement, reader r: PanelReader<N>) -> RowTarget {
        var level = [row], levels: [[PanelElement]] = [], path: String?
        for depth in 0..<3 {
            var infos: [PanelElement] = []
            for e in level {
                guard let info = r.element(e), !info.unresolved else { return .unknown }
                infos.append(info)
            }
            if let url = infos.lazy.compactMap(\.url).first { return .url(url) }
            path = path ?? infos.lazy.compactMap(\.identifier).first { $0.hasPrefix("/") }
            levels.append(infos)
            guard depth < 2 else { break }
            var next: [N] = []
            for e in level {
                guard let children = r.children(e) else { return .unknown }
                next += children
            }
            level = next
        }
        if let path { return .url(URL(fileURLWithPath: path)) }
        let parts = levels[2]
        if list.role == kAXOutlineRole, levels[0].first?.role == kAXRowRole, !parts.isEmpty,
           !parts.contains(where: { $0.role == kAXTextFieldRole }) { return .place }
        return .unknown
    }

    static func accessibility(pid: pid_t, policy: Policy) -> PanelReader<AXElement> {
        func readable(_ read: (elements: [AXElement], error: AXError?)) -> [AXElement]? { read.error == nil ? read.elements : nil }
        return PanelReader(
            element: panelElement(_:), value: { $0.string(kAXValueAttribute) },
            children: { readable($0.elements(reporting: kAXChildrenAttribute)) },
            selected: { e in
                guard let children = readable(e.elements(reporting: kAXSelectedChildrenAttribute)),
                      let rows = readable(e.elements(reporting: kAXSelectedRowsAttribute)) else { return nil }
                return children + rows
            },
            typing: { OpenRoutes.typingRefusal($0, into: $1, pid: pid) },
            tile: { OpenRoutes.tileRefusal($0, policy: policy) })
    }

    /// One batched read of what the check needs from an element; nil when the read or the role failed.
    static func panelElement(_ element: AXElement) -> PanelElement? {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXURLAttribute]
        guard let read = element.read(reporting: names), read.errors[kAXRoleAttribute] == nil else { return nil }
        let v = read.values
        let url = v[kAXURLAttribute] as? URL ?? (v[kAXURLAttribute] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme != nil ? $0 : nil }
        return PanelElement(role: v[kAXRoleAttribute] as? String ?? "", subrole: v[kAXSubroleAttribute] as? String,
                            identifier: v[kAXIdentifierAttribute] as? String, url: url,
                            unresolved: read.errors[kAXIdentifierAttribute] != nil || read.errors[kAXURLAttribute] != nil)
    }
}
