import ApplicationServices
import CoreGraphics
import Foundation

public struct WalkStats: Sendable {
    /// Why a walk stopped before the whole tree. Only `.time` depends on how fast the app answered: the other reasons
    /// stop at the same node for the same tree, so two such walks of an unchanged UI see the same nodes.
    public enum Truncation: Sendable, Equatable { case nodes, depth, time, cancelled }

    public var visited = 0
    public var offscreenSkipped = 0
    public var truncation: Truncation?
    public var truncated: Bool {
        get { truncation != nil }
        set { truncation = newValue ? (truncation ?? .nodes) : nil }
    }
    /// Holes in the tree: nodes that failed to read, and nodes whose children couldn't be enumerated (or whose rows
    /// couldn't be, with no children to fall back on). Absence checks must not treat these as empty subtrees.
    public var readFailures = 0
    /// Nodes read whole but with a label source or identifier that failed to read (`RawNode.identityUncertain`): the
    /// node is in the tree, possibly unnamed, so the walk can't vouch for what it says.
    public var identityReadFailures = 0
    /// Nodes read whole but with searchable text that failed to read (`RawNode.textUncertain`): a label source, a
    /// shown value, or the children that could hold text. A failed identifier alone isn't counted here.
    public var textReadFailures = 0
    public var milliseconds = 0
    /// Web views (AXWebArea) whose page hasn't finished loading.
    public var loadingPages = 0
    /// The walk reached everything it was pointed at and read every node, label and identifier: what it says about
    /// an element's identity is what the UI says.
    public var complete: Bool { truncation == nil && readFailures == 0 && identityReadFailures == 0 }
    /// The walk reached everything it was pointed at and read every node's text whole: a query that matches nothing
    /// in it is absent from the UI. Unlike `complete`, an identifier that failed to read doesn't count, so a wait
    /// on text isn't held up by a failure that can't hide text.
    public var textComplete: Bool { truncation == nil && readFailures == 0 && textReadFailures == 0 }
}

/// Walks an accessibility subtree into `RawNode`s.
///
/// - One batched attribute read per element (`AXUIElementCopyMultipleAttributeValues`).
/// - Tables, outlines and lists contribute only their visible rows.
/// - Elements entirely outside the visible area (window, scroll view) are skipped with their subtrees; elements with
///   no usable frame are kept and descended into (MacOS-MCP 0.3.14: collapsed wrappers can hold visible content).
/// - Closed menus aren't expanded: a menu bar item's children are only walked when `descendMenus` is set.
/// - Stops at `maxNodes` or the deadline and reports truncation.
public enum Walker {
    static let attributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXIdentifier",
        "AXHelp", "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXSelected", "AXExpanded", "AXChildren",
    ]
    static let clippingRoles: Set<String> = ["AXWindow", "AXSheet", "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXBrowser"]
    static let visibleRowRoles: Set<String> = ["AXTable", "AXOutline"]

    public struct Options: Sendable {
        public var maxNodes = 5000
        public var timeLimit: TimeInterval = 3
        public var clip: CGRect?
        public var descendMenus = false
        /// Where attribute values come from: the live accessibility API, or a synthetic tree in tests.
        public var source = Source.live
        public init() {}
    }

    /// The reads a walk makes, so tests can walk a synthetic tree (with its own clock) through the real walker.
    /// `read`, `attributeRead` and `elements` report which reads failed and how (`AXElement.Read`); a source without
    /// failures can be built from plain dictionaries.
    public struct Source: Sendable {
        public var read: @Sendable (AXElement, [String]) -> AXElement.Read?
        public var attribute: @Sendable (AXElement, String) -> Any?
        public var attributeRead: @Sendable (AXElement, String) -> (value: Any?, error: AXError?)
        public var elements: @Sendable (AXElement, String) -> (elements: [AXElement], error: AXError?)
        public var now: @Sendable () -> Date

        public init(read: @escaping @Sendable (AXElement, [String]) -> AXElement.Read?,
                    attributeRead: @escaping @Sendable (AXElement, String) -> (value: Any?, error: AXError?),
                    elements: @escaping @Sendable (AXElement, String) -> (elements: [AXElement], error: AXError?),
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.read = read
            self.attribute = { attributeRead($0, $1).value }
            self.attributeRead = attributeRead
            self.elements = elements
            self.now = now
        }

        /// A source whose reads never fail: an absent value is absent.
        public init(read: @escaping @Sendable (AXElement, [String]) -> [String: Any]?,
                    attribute: @escaping @Sendable (AXElement, String) -> Any?,
                    elements: @escaping @Sendable (AXElement, String) -> [AXElement],
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.init(read: { read($0, $1).map { AXElement.Read(values: $0) } },
                      attributeRead: { (attribute($0, $1), nil) }, elements: { (elements($0, $1), nil) }, now: now)
        }

        public static let live = Source(read: { $0.read(reporting: $1) }, attributeRead: { $0.attribute(reporting: $1) },
                                        elements: { $0.elements(reporting: $1) })
    }

    /// The attributes a label can come from, whatever the role: a failed read of one leaves the node's label unknown.
    /// `AXValue` counts too unless the role's value is never a label (`Snapshot.valueNeverLabels`), and so do the
    /// children, since a row's cells or a button's text name it.
    static let labelAttributes: Set<String> = ["AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp", "AXChildren"]

    /// Whether a failed read of `name` leaves the node's label unknown (`RawNode.identityUncertain`).
    static func isLabelSource(_ name: String, role: String) -> Bool {
        labelAttributes.contains(name) || (name == "AXValue" && !Snapshot.valueNeverLabels.contains(role))
    }

    /// Whether a failed read of `name` leaves the node's searchable text unknown (`RawNode.textUncertain`): the label
    /// sources, and a value that is shown beside the label (a popup's choice, a field's contents) even where it
    /// never names the element. Only a state value (checked, expanded) carries no text.
    static func isTextSource(_ name: String, role: String) -> Bool {
        isLabelSource(name, role: role) || (name == "AXValue" && !Snapshot.stateValueRoles.contains(role))
    }

    public static func walk(_ root: AXElement, options: Options = Options()) -> (RawNode, WalkStats) {
        var stats = WalkStats()
        let source = options.source
        let started = source.now()
        let deadline = started.addingTimeInterval(options.timeLimit)

        /// A node whose children are still being walked.
        struct Frame {
            var node: RawNode
            var children: [AXElement]
            var next = 0
            var childClip: CGRect?
            var depth: Int
        }
        var stack: [Frame] = []

        /// The nodes still open (the ancestors of what is being read now) can no longer vouch for their labels: a
        /// descendant that failed to read, or a cut, may have taken text that would have named them. A failed
        /// identifier can't hide text (`text` is off), and a shown value that is never a label can't name an
        /// ancestor (`identity` is off); a lost node or a cut could do either.
        func markOpenNodesUncertain(identity: Bool = true, text: Bool = true) {
            for i in stack.indices {
                if identity { stack[i].node.identityUncertain = true }
                if text { stack[i].node.textUncertain = true }
            }
        }

        /// One attribute read whose `kAXErrorFailure` is believed only the second time: some apps (Java, some Qt and
        /// Office builds) answer that for attributes they don't have, and a control there would otherwise never be
        /// re-read whole. One retry, for identity reads only; a read the app couldn't complete isn't repeated, since
        /// it already cost the messaging timeout.
        func readIdentity(_ element: AXElement, _ name: String) -> (value: Any?, failed: Bool) {
            var read = source.attributeRead(element, name)
            if read.error == .failure { read = source.attributeRead(element, name) }
            return (read.value, read.error != nil)
        }

        /// Reads one element and decides what to do with it: nil for a node that is cut, failed or offscreen,
        /// otherwise the node with the children to walk next.
        func open(_ element: AXElement, clip: CGRect?, path: String, depth: Int) -> Frame? {
            guard !Task.isCancelled else { stats.truncation = .cancelled; markOpenNodesUncertain(); return nil }
            guard stats.visited < options.maxNodes else { stats.truncation = .nodes; markOpenNodesUncertain(); return nil }
            guard depth < 60 else { stats.truncation = .depth; markOpenNodesUncertain(); return nil }
            if stats.visited % 64 == 0, source.now() > deadline { stats.truncation = .time; markOpenNodesUncertain(); return nil }
            stats.visited += 1
            guard let read = source.read(element, attributes) else { stats.readFailures += 1; markOpenNodesUncertain(); return nil }
            var v = read.values
            var errors = read.errors
            let role = v["AXRole"] as? String ?? "AXUnknown"
            // Identity attributes that answered kAXErrorFailure get one more batched read (see `readIdentity`); only
            // a repeated failure counts. Other errors, and attributes that can't hide a label, are taken as they are.
            let doubtful = errors.filter { $0.value == .failure && (isTextSource($0.key, role: role) || $0.key == "AXIdentifier") }.keys.sorted()
            if !doubtful.isEmpty, let again = source.read(element, doubtful) {
                for name in doubtful where again.errors[name] == nil {
                    errors[name] = nil
                    if let value = again.values[name] { v[name] = value }
                }
            }

            var n = RawNode(role: role)
            n.element = element
            n.identityUncertain = errors.keys.contains { isLabelSource($0, role: role) || $0 == "AXIdentifier" }
            n.textUncertain = errors.keys.contains { isTextSource($0, role: role) }
            // Children that couldn't be enumerated are a hole in the tree, not an empty subtree.
            var hole = errors["AXChildren"] != nil
            n.subrole = v["AXSubrole"] as? String
            n.title = v["AXTitle"] as? String
            n.description = v["AXDescription"] as? String
            n.value = stringValue(v["AXValue"])
            n.placeholder = v["AXPlaceholderValue"] as? String
            n.identifier = v["AXIdentifier"] as? String
            n.help = v["AXHelp"] as? String
            n.frame = frame(position: v["AXPosition"], size: v["AXSize"])
            n.enabled = v["AXEnabled"] as? Bool ?? true
            n.focused = v["AXFocused"] as? Bool ?? false
            n.selected = v["AXSelected"] as? Bool ?? false
            n.expanded = v["AXExpanded"] as? Bool
            n.path = path

            // Offscreen: a real (positive-area) frame that doesn't touch the visible area.
            if let clip, let f = n.frame, f.width > 0, f.height > 0, !f.intersects(clip) {
                stats.offscreenSkipped += 1
                return nil
            }
            if n.role == "AXWebArea", source.attribute(element, "AXLoaded") as? Bool == false { stats.loadingPages += 1 }
            var childClip = clip
            if clippingRoles.contains(n.role), let f = n.frame, f.width > 0, f.height > 0 {
                childClip = clip.map { $0.intersection(f) }   // no clip stays no clip (offscreen: true)
            }

            var children = (v["AXChildren"] as? [AXUIElement])?.map(AXElement.init) ?? []
            // Lists and tables: walk only the visible rows when clipping (count the rest as offscreen), all otherwise.
            // The rows are children too, so a failed row read falls back to them; it is a hole only with none to
            // fall back on.
            if visibleRowRoles.contains(n.role) || n.role == "AXList" {
                let visible = source.elements(element, n.role == "AXList" ? "AXVisibleChildren" : "AXVisibleRows")
                if visible.error != nil, children.isEmpty { hole = true }
                if !visible.elements.isEmpty {
                    let all = n.role == "AXList" ? (elements: children, error: nil) : source.elements(element, "AXRows")
                    if options.clip != nil {
                        stats.offscreenSkipped += max(0, all.elements.count - visible.elements.count)   // a failed count only loses this figure
                        children = visible.elements
                    } else if !all.elements.isEmpty {
                        children = all.elements
                    } else if children.isEmpty {
                        children = visible.elements
                        if all.error != nil { hole = true }   // the visible rows may not be all of them
                    }
                }
            }
            // An unlabeled control may name its label element explicitly.
            if n.title == nil, n.description == nil, Snapshot.isInteractive(n) {
                let titleElement = readIdentity(element, "AXTitleUIElement")
                if titleElement.failed { n.identityUncertain = true; n.textUncertain = true }
                if let labelElement = titleElement.value.flatMap(AXElement.from) {
                    let value = readIdentity(labelElement, kAXValueAttribute)
                    let title: (value: Any?, failed: Bool) = value.value as? String == nil
                        ? readIdentity(labelElement, kAXTitleAttribute) : (nil, false)
                    if let text = value.value as? String ?? title.value as? String { n.title = text }
                    else if value.failed || title.failed { n.identityUncertain = true; n.textUncertain = true }
                }
            }
            if hole {
                stats.readFailures += 1
                n.identityUncertain = true
                n.textUncertain = true
            }
            if n.identityUncertain { stats.identityReadFailures += 1 }
            if n.textUncertain { stats.textReadFailures += 1 }
            if n.identityUncertain || n.textUncertain { markOpenNodesUncertain(identity: n.identityUncertain, text: n.textUncertain) }
            if n.role == "AXMenuBarItem", !options.descendMenus { children = [] }

            return Frame(node: n, children: children, childClip: childClip, depth: depth)
        }

        // The walk is iterative: a deep tree (React and Electron nest hundreds of groups) would otherwise recurse
        // once per level on a cooperative-pool or GCD thread with a 512 KB stack.
        var result: RawNode?
        if let frame = open(root, clip: options.clip, path: "", depth: 0) { stack.append(frame) }
        while let top = stack.indices.last {
            if !stats.truncated, stack[top].next < stack[top].children.count {
                let i = stack[top].next
                stack[top].next += 1
                let path = stack[top].node.path
                if let frame = open(stack[top].children[i], clip: stack[top].childClip,
                                    path: path.isEmpty ? "\(i)" : "\(path).\(i)", depth: stack[top].depth + 1) {
                    stack.append(frame)
                }
                continue
            }
            let finished = stack.removeLast().node
            if let parent = stack.indices.last { stack[parent].node.children.append(finished) } else { result = finished }
        }

        stats.milliseconds = Int(source.now().timeIntervalSince(started) * 1000)
        return (result ?? RawNode(role: "AXUnknown"), stats)
    }

    static func stringValue(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case let a as NSAttributedString: a.string
        case let u as URL: u.absoluteString
        default: nil
        }
    }

    /// Union of all screens, in global top-left-origin points.
    public static var screenBounds: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }
}
