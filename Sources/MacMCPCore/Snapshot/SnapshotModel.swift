import CoreGraphics
import Foundation

/// One accessibility element as read during a walk, before deciding what to show.
public struct RawNode: Sendable {
    public var element: AXElement?
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var placeholder: String?
    public var identifier: String?
    public var help: String?
    public var frame: CGRect?
    public var enabled: Bool = true
    public var focused: Bool = false
    public var selected: Bool = false
    public var expanded: Bool?
    /// Index path from the snapshot root ("0.3.1"); part of the ref fingerprint.
    public var path: String = ""
    /// The title was borrowed from the text element beside it (`Snapshot.associateLabels`): the element itself is unnamed.
    public var labelFromNeighbor = false
    /// The walk couldn't vouch for this node's label and identifier: one of its label sources (title, description,
    /// value, identifier, title element) failed to read, a descendant failed to read, or the walk was cut short
    /// inside its subtree. Labels come from descendants too (a row's cells, a button's text), so an empty or
    /// missing one from such a node is unknown, not proof that it is unnamed.
    public var identityUncertain = false
    /// The walk couldn't vouch for this node's searchable text: a label source, a value that is shown, or children
    /// that could hold text failed to read, or the walk was cut short inside its subtree. A query that matches
    /// nothing here may still be on screen. A failed identifier alone leaves this false: it names the element to
    /// an action (`identityUncertain`), but a wait on text doesn't depend on it.
    public var textUncertain = false
    public var children: [RawNode] = []

    public init(role: String, subrole: String? = nil, title: String? = nil, description: String? = nil,
                value: String? = nil, placeholder: String? = nil, identifier: String? = nil, frame: CGRect? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
        self.frame = frame
    }
}

extension RawNode {
    /// A copy of the tree with `transform` applied to each node, parents before children. `transform` returns whether
    /// to go on into the children it leaves in the node. Iterative: trees reach the walker's 60-level limit, and
    /// a recursive pass would put that many frames on a small cooperative-pool or GCD thread stack.
    func mapped(_ transform: (inout RawNode) -> Bool) -> RawNode {
        struct Frame {
            var node: RawNode
            var source: [RawNode]
            var next = 0
        }
        func open(_ original: RawNode) -> Frame {
            var node = original
            guard transform(&node) else { return Frame(node: node, source: []) }
            let source = node.children
            node.children = []
            node.children.reserveCapacity(source.count)
            return Frame(node: node, source: source)
        }
        var stack = [open(self)]
        while true {
            let top = stack.count - 1
            if stack[top].next < stack[top].source.count {
                stack[top].next += 1
                stack.append(open(stack[top].source[stack[top].next - 1]))
                continue
            }
            let finished = stack.removeLast().node
            guard let parent = stack.indices.last else { return finished }
            stack[parent].node.children.append(finished)
        }
    }
}

/// What a row means to the agent.
public enum RowKind: Sendable { case interactive, text, context }

/// One line of snapshot output.
public struct Row: Sendable, Equatable {
    public var kind: RowKind
    public var role: String          // short role name ("button", "textfield", ...)
    public var label: String
    public var value: String?
    public var states: [String]
    public var frame: CGRect?
    public var depth: Int
    public var ref: String?
    /// Identity inputs for ref matching (not printed).
    public var fingerprint: String
    /// The live element behind an interactive row (not printed).
    public var element: AXElement? = nil
    /// Window, sheet or menu bar that owns this control; fingerprint matching never crosses this boundary.
    public var refScope: AXElement? = nil
    /// Full sanitized text for queries. Presentation remains compact.
    public var searchText: String? = nil
    /// The developer's AXIdentifier (not printed); with the label, what an action re-checks before using a ref.
    public var identifier: String? = nil
    /// The label came from the text beside the control, not from the control (see `RawNode.labelFromNeighbor`).
    public var labelFromNeighbor: Bool = false
    /// The label or identifier may be missing because the read failed or was cut (see `RawNode.identityUncertain`).
    public var identityUncertain: Bool = false

    public func matches(_ query: String) -> Bool {
        (searchText ?? [label, value].compactMap { $0 }.joined(separator: "\n"))
            .localizedCaseInsensitiveContains(query)
    }

    public func render(frames: Bool) -> String {
        var s = String(repeating: " ", count: min(depth, 8))
        if let ref { s += ref + " " }
        s += role
        if !label.isEmpty { s += " \"" + Snapshot.escape(label) + "\"" }
        if let value { s += " = \"" + Snapshot.escape(value) + "\"" }
        if !states.isEmpty { s += " [" + states.joined(separator: ", ") + "]" }
        if frames, let f = frame { s += " @\(f.minX.safeInt),\(f.minY.safeInt) \(f.width.safeInt)x\(f.height.safeInt)" }
        return s
    }
}

public enum Snapshot {
    // MARK: Roles

    static let shortRoles: [String: String] = [
        "AXButton": "button", "AXTextField": "textfield", "AXTextArea": "textarea", "AXCheckBox": "checkbox",
        "AXRadioButton": "radio", "AXPopUpButton": "popup", "AXMenuButton": "menubutton", "AXComboBox": "combobox",
        "AXLink": "link", "AXMenuItem": "menuitem", "AXMenuBarItem": "menu", "AXSlider": "slider",
        "AXIncrementor": "stepper", "AXDisclosureTriangle": "disclosure", "AXRow": "row", "AXCell": "cell",
        "AXStaticText": "text", "AXHeading": "heading", "AXImage": "image", "AXGroup": "group", "AXTabGroup": "tabs",
        "AXToolbar": "toolbar", "AXList": "list", "AXTable": "table", "AXOutline": "outline", "AXScrollArea": "scroll",
        "AXWebArea": "page", "AXSheet": "sheet", "AXWindow": "window", "AXColorWell": "colorwell",
        "AXSegmentedControl": "segmented", "AXDateField": "datefield", "AXDockItem": "dockitem",
        "AXValueIndicator": "indicator", "AXSplitGroup": "split", "AXBrowser": "browser", "AXLevelIndicator": "level",
        "AXProgressIndicator": "progress", "AXBusyIndicator": "busy", "AXMenu": "menulist", "AXMenuBar": "menubar",
    ]

    static let subroleNames: [String: String] = [
        "AXSecureTextField": "password", "AXSearchField": "search", "AXTabButton": "tab", "AXToggle": "toggle",
        "AXSwitch": "switch", "AXDialog": "dialog", "AXSystemDialog": "dialog", "AXFloatingWindow": "panel",
        "AXCloseButton": "button", "AXMinimizeButton": "button", "AXZoomButton": "button", "AXFullScreenButton": "button",
    ]

    /// Window-control buttons expose no name; MacOS-MCP 0.3.14 learned to name them from the subrole.
    static let windowControlNames: [String: String] = [
        "AXCloseButton": "close", "AXMinimizeButton": "minimize", "AXZoomButton": "zoom", "AXFullScreenButton": "full screen",
    ]

    public static func shortRole(_ role: String, subrole: String?) -> String {
        if let subrole, let name = subroleNames[subrole] { return name }
        return shortRoles[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXRow", "AXColorWell", "AXDateField", "AXDockItem", "AXSegmentedControl",
    ]
    static let interactiveSubroles: Set<String> = ["AXSearchField", "AXTabButton", "AXSecureTextField"]
    /// Containers worth a context line when they carry a name.
    static let contextRoles: Set<String> = ["AXGroup", "AXTabGroup", "AXToolbar", "AXList", "AXTable", "AXOutline",
                                            "AXWebArea", "AXSheet", "AXWindow", "AXSplitGroup", "AXBrowser", "AXMenu"]
    /// Roles whose AXValue is a state, not a label.
    static let stateValueRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]
    static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// Roles whose AXValue is a state or an entry's contents, never a label: for every other role the value can
    /// name the element itself (`label`) or an ancestor (`descendantText`), and so a failed read of it is a failed
    /// read of a label.
    static let valueNeverLabels: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXTextArea", "AXComboBox",
                                                "AXPopUpButton", "AXSlider", "AXIncrementor"]

    /// Large parts of a window that accessibility describes as nothing: an element covering at least a quarter of
    /// the window, with no interactive element and no text inside it (a canvas, a remote desktop, a game, a
    /// custom-drawn view). Their frames, largest first, so a hint can point text recognition at them.
    public static func opaqueRegions(_ root: RawNode) -> [CGRect] {
        guard let window = root.frame, window.width * window.height > 0 else { return [] }
        let minArea = window.width * window.height / 4
        var found: [CGRect] = []
        func hasContent(_ root: RawNode) -> Bool {
            var pending = [root]
            while let n = pending.popLast() {
                if isInteractive(n) || !(n.title ?? n.value ?? n.description ?? "").isEmpty { return true }
                pending += n.children
            }
            return false
        }
        var pending = [root]
        while let n = pending.popLast() {
            if let f = n.frame?.intersection(window), !f.isNull, f.width * f.height >= minArea, n.role != "AXWindow" {
                if !hasContent(n) { found.append(f); continue }
            }
            pending += n.children.reversed()   // preorder: the first child is popped first
        }
        return found.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    public static func isInteractive(_ n: RawNode) -> Bool {
        interactiveRoles.contains(n.role) || (n.subrole.map(interactiveSubroles.contains) ?? false)
    }

    // MARK: Labels and states

    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        // Icon fonts (VS Code's codicons, SF Symbols in text) put Private Use Area glyphs into labels.
        let scalars = s.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) && !(0xF0000...0x10FFFF).contains($0.value) }
        let t = String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }

    /// Remove secure values before any labels, fingerprints, search metadata or debug output are derived.
    static func sanitized(_ node: RawNode) -> RawNode {
        node.mapped { n in
            guard n.subrole == "AXSecureTextField" else { return true }
            n.value = (n.value?.isEmpty == false) ? "•••" : nil
            n.children = []
            return false
        }
    }

    /// Concatenated visible text under a node (for unlabeled buttons, links, headings and table rows).
    static func descendantText(_ n: RawNode, separator: String = " ", limit: Int = 160) -> String? {
        var parts: [String] = []
        var images: [String] = []   // icon descriptions ("trash", "letter A icon") only when there is no text
        // Recursive, but depth < 6 stops it at seven frames, each of a few locals.
        func visit(_ node: RawNode, depth: Int) {
            guard node.subrole != "AXSecureTextField" else { return }
            guard depth < 6, parts.joined(separator: separator).count < limit else { return }
            if node.role == "AXStaticText" || node.role == "AXHeading" || node.role == "AXTextField",
               let t = clean(node.value) ?? clean(node.title) ?? clean(node.description) {
                parts.append(t)
                return
            }
            if node.role == "AXImage", let t = clean(node.description) ?? clean(node.title) { images.append(t) }
            for c in node.children { visit(c, depth: depth + 1) }
        }
        for c in n.children { visit(c, depth: 0) }
        let joined = (parts.isEmpty ? images : parts).joined(separator: separator)
        return joined.isEmpty ? nil : truncate(joined, limit)
    }

    public static func label(_ n: RawNode, limit: Int = 100) -> String {
        if let s = n.subrole, let name = windowControlNames[s], clean(n.title) == nil, clean(n.description) == nil { return name }
        if n.role == "AXRow" { return descendantText(n, separator: " | ", limit: max(limit, 160)) ?? clean(n.title) ?? "" }
        let valueIsLabel = !stateValueRoles.contains(n.role) && !textEntryRoles.contains(n.role)
            && n.role != "AXPopUpButton" && n.role != "AXSlider" && n.role != "AXIncrementor"
        let candidates = [clean(n.title), clean(n.description), valueIsLabel ? clean(n.value) : nil,
                          textEntryRoles.contains(n.role) ? clean(n.placeholder) : nil]
        if let first = candidates.compactMap({ $0 }).first { return truncate(first, limit) }
        if let text = descendantText(n, limit: limit) { return text }
        return clean(n.placeholder) ?? meaningfulIdentifier(n.identifier)
            ?? clean(n.help).map { truncate($0, limit == Int.max ? limit : 60) } ?? ""
    }

    /// Developer identifiers can name an element ("saveButton"), but AppKit's generated ones ("_NS:122") are noise.
    static func meaningfulIdentifier(_ id: String?) -> String? {
        guard let id = clean(id), !id.hasPrefix("_NS:"), !id.hasPrefix("NS"), id.count <= 60,
              id.range(of: #"^[0-9A-Fa-f-]{16,}$"#, options: .regularExpression) == nil else { return nil }
        return id
    }

    /// The value worth showing separately from the label: field contents, popup selection, slider level.
    static func displayValue(_ n: RawNode, limit: Int = 120) -> String? {
        if n.subrole == "AXSecureTextField" { return clean(n.value) == nil ? nil : "•••" }   // never reveal secrets
        guard textEntryRoles.contains(n.role) || n.role == "AXPopUpButton" || n.role == "AXSlider"
            || n.role == "AXIncrementor" || n.role == "AXValueIndicator" || n.role == "AXLevelIndicator" else { return nil }
        guard let v = n.value else { return n.role == "AXTextField" || n.role == "AXTextArea" ? "" : nil }
        return truncate(v.replacingOccurrences(of: "\n", with: "⏎"), limit)
    }

    static func states(_ n: RawNode) -> [String] {
        var s: [String] = []
        if n.focused { s.append("focused") }
        if !n.enabled { s.append("disabled") }
        if stateValueRoles.contains(n.role) || n.subrole == "AXToggle" || n.subrole == "AXSwitch" {
            switch n.value {
            case "1": s.append(n.role == "AXRadioButton" || n.subrole == "AXTabButton" ? "selected" : "checked")
            case "2": s.append("mixed")
            case "0": if n.role == "AXCheckBox" { s.append("unchecked") }
            default: break
            }
        }
        if n.selected, !s.contains("selected") { s.append("selected") }
        if let e = n.expanded, n.role == "AXDisclosureTriangle" || n.role == "AXRow" || n.role == "AXPopUpButton"
            || n.role == "AXComboBox" || n.role == "AXMenuButton" {
            s.append(e ? "expanded" : "collapsed")
        }
        return s
    }

    static func fingerprint(_ n: RawNode, pid: pid_t, label: String) -> String {
        "\(pid)|\(n.role)|\(n.subrole ?? "")|\(n.identifier ?? "")|\(label)|\(n.path)"
    }

    // MARK: Rendering

    /// Turns a walked tree into rows: interactive elements, readable text and named containers for context.
    /// Text inside an interactive element is folded into that element's label rather than repeated.
    public static func rows(from root: RawNode, pid: pid_t, includeText: Bool = true) -> [Row] {
        var rows: [Row] = []
        let root = associateLabels(sanitized(root))
        let windowTitle = root.role == "AXWindow" ? clean(root.title) : nil
        func scope(_ n: RawNode, inherited: AXElement?) -> AXElement? {
            ["AXWindow", "AXSheet", "AXMenuBar"].contains(n.role) ? n.element ?? inherited : inherited
        }
        func searchable(_ n: RawNode) -> String {
            [label(n, limit: Int.max), displayValue(n, limit: Int.max)].compactMap { $0 }.joined(separator: "\n")
        }
        // Iterative, in document order: a task emits its own rows when popped, then pushes its children in reverse.
        enum Task {
            case visit(RawNode, depth: Int, isRoot: Bool, inheritedScope: AXElement?)
            case visitInteractiveOnly(RawNode, depth: Int, rowLabel: String?, inheritedScope: AXElement?)
            /// After a wrapper row's children: its selection moves to the first row that replaced it.
            case keepSelection(from: Int)
        }
        var tasks: [Task] = [.visit(root, depth: 0, isRoot: true, inheritedScope: nil)]
        func push(_ children: [RawNode], _ task: (RawNode) -> Task) {
            for c in children.reversed() { tasks.append(task(c)) }
        }
        func visit(_ n: RawNode, depth: Int, isRoot: Bool, inheritedScope: AXElement?) {
            let refScope = scope(n, inherited: inheritedScope)
            // Scroll bars are noise for agents (scrolling is mac_scroll's job); title-bar text repeats the window title.
            if n.role == "AXScrollBar" { return }
            if n.role == "AXStaticText", let t = windowTitle, clean(n.value) == t, depth == 0 { return }
            let interactive = isInteractive(n)
            // An unlabeled row is just a wrapper (System Settings' sidebar): show what's inside it, or nothing.
            if n.role == "AXRow", label(n).isEmpty {
                if n.selected { tasks.append(.keepSelection(from: rows.count)) }
                push(n.children) { .visitInteractiveOnly($0, depth: depth, rowLabel: nil, inheritedScope: refScope) }
                return
            }
            if interactive {
                let label = label(n)
                rows.append(Row(kind: .interactive, role: shortRole(n.role, subrole: n.subrole), label: label,
                                value: displayValue(n), states: states(n), frame: n.frame, depth: depth, ref: nil,
                                fingerprint: fingerprint(n, pid: pid, label: label), element: n.element,
                                refScope: refScope, searchText: searchable(n), identifier: n.identifier, labelFromNeighbor: n.labelFromNeighbor,
                                identityUncertain: n.identityUncertain))
                // Rows and links summarize their text; still surface interactive descendants (buttons in a row),
                // except text fields that only repeat the row's own text (Finder's inline rename fields).
                push(n.children) { .visitInteractiveOnly($0, depth: depth + 1, rowLabel: n.role == "AXRow" ? label : nil, inheritedScope: refScope) }
                return
            }
            if includeText, n.role == "AXStaticText" || n.role == "AXHeading" {
                let text = n.role == "AXHeading" ? (clean(n.title) ?? clean(n.description) ?? descendantText(n, limit: Int.max) ?? clean(n.value))
                                                  : (clean(n.value) ?? clean(n.title) ?? clean(n.description))
                if let text {
                    rows.append(Row(kind: .text, role: n.role == "AXHeading" ? "heading" : "text", label: truncate(text, 200),
                                    value: nil, states: [], frame: n.frame, depth: depth, ref: nil, fingerprint: "", searchText: text))
                }
                if n.role == "AXHeading" { return }   // its text children are already in the heading
            }
            var childDepth = depth
            if contextRoles.contains(n.role), !isRoot || n.role == "AXSheet",
               let name = clean(n.title) ?? (n.role == "AXGroup" || n.role == "AXToolbar" ? nil : clean(n.description)) {
                rows.append(Row(kind: .context, role: shortRole(n.role, subrole: n.subrole), label: truncate(name, 100),
                                value: nil, states: [], frame: n.frame, depth: depth, ref: nil, fingerprint: ""))
                childDepth += 1
            }
            push(n.children) { .visit($0, depth: childDepth, isRoot: false, inheritedScope: refScope) }
        }
        func visitInteractiveOnly(_ n: RawNode, depth: Int, rowLabel: String?, inheritedScope: AXElement?) {
            let refScope = scope(n, inherited: inheritedScope)
            let repeatsRow = rowLabel != nil && textEntryRoles.contains(n.role) && !n.focused
                && (clean(n.value).map { rowLabel!.contains($0) } ?? true)
            if isInteractive(n), n.role != "AXRow", !repeatsRow {
                let label = label(n)
                rows.append(Row(kind: .interactive, role: shortRole(n.role, subrole: n.subrole), label: label,
                                value: displayValue(n), states: states(n), frame: n.frame, depth: depth, ref: nil,
                                fingerprint: fingerprint(n, pid: pid, label: label), element: n.element,
                                refScope: refScope, searchText: searchable(n), identifier: n.identifier, labelFromNeighbor: n.labelFromNeighbor,
                                identityUncertain: n.identityUncertain))
            }
            push(n.children) { .visitInteractiveOnly($0, depth: depth, rowLabel: rowLabel, inheritedScope: refScope) }
        }
        while let task = tasks.popLast() {
            switch task {
            case let .visit(n, depth, isRoot, inheritedScope): visit(n, depth: depth, isRoot: isRoot, inheritedScope: inheritedScope)
            case let .visitInteractiveOnly(n, depth, rowLabel, inheritedScope):
                visitInteractiveOnly(n, depth: depth, rowLabel: rowLabel, inheritedScope: inheritedScope)
            case let .keepSelection(before):
                if rows.count > before, !rows[before].states.contains("selected") { rows[before].states.append("selected") }
            }
        }
        return rows
    }

    /// Debug view: every walked node with its raw attributes, indented by depth.
    public static func rawDump(_ root: RawNode, maxLines: Int = 400) -> String {
        var lines: [String] = []
        var pending = [(node: sanitized(root), depth: 0)]
        while let (n, depth) = pending.popLast(), lines.count < maxLines {
            var parts = [n.role + (n.subrole.map { "/" + $0 } ?? "")]
            for (k, v) in [("title", n.title), ("desc", n.description), ("value", n.value), ("placeholder", n.placeholder),
                           ("id", n.identifier), ("help", n.help)] {
                if let v, !v.isEmpty { parts.append("\(k)=\"\(truncate(v.replacingOccurrences(of: "\n", with: "⏎"), 60))\"") }
            }
            if let f = n.frame { parts.append("@\(f.minX.safeInt),\(f.minY.safeInt) \(f.width.safeInt)x\(f.height.safeInt)") }
            lines.append(String(repeating: " ", count: min(depth, 20)) + parts.joined(separator: " "))
            for c in n.children.reversed() { pending.append((c, depth + 1)) }
        }
        return lines.joined(separator: "\n")
    }

    /// Form layouts often put a field's label in a separate text element just to its left ("Size  [Small ▾]") with
    /// no accessibility link. Give unlabeled controls that text as their title, and drop the now-redundant text node.
    static func associateLabels(_ node: RawNode) -> RawNode {
        node.mapped { associateLabels(amongChildrenOf: &$0); return true }
    }

    private static func associateLabels(amongChildrenOf n: inout RawNode) {
        var consumed = Set<Int>()
        for i in n.children.indices where i > 0 {
            let c = n.children[i], prev = n.children[i - 1]
            guard isInteractive(c), prev.role == "AXStaticText", let text = clean(prev.value), text.count <= 60,
                  let f = c.frame, let pf = prev.frame, abs(f.midY - pf.midY) < 10, pf.maxX <= f.minX + 4, f.minX - pf.maxX < 80
            else { continue }
            let name = text.hasSuffix(":") ? String(text.dropLast()) : text
            let unlabeled = label(c).isEmpty || (textEntryRoles.contains(c.role) && clean(c.title) == nil && clean(c.description) == nil)
            if unlabeled {
                n.children[i].title = name
                n.children[i].labelFromNeighbor = true
                consumed.insert(i - 1)
            } else if clean(c.title) == name || clean(c.description) == name {
                consumed.insert(i - 1)   // already labeled by it (AXTitleUIElement): don't repeat the text
            }
        }
        n.children = n.children.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
    }

    /// Renders rows within a token budget (~4 characters per token). Returns the text and how many rows were cut.
    public static func render(_ rows: [Row], frames: Bool, maxTokens: Int) -> (text: String, omitted: Int) {
        let budget = max(200, maxTokens) * 4
        var out: [String] = []
        var used = 0
        for (i, row) in rows.enumerated() {
            let line = row.render(frames: frames)
            if used + line.count + 1 > budget { return (out.joined(separator: "\n"), rows.count - i) }
            out.append(line)
            used += line.count + 1
        }
        return (out.joined(separator: "\n"), 0)
    }
}
