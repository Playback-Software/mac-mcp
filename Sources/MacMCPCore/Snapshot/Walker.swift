import ApplicationServices
import CoreGraphics
import Foundation

public struct WalkStats: Sendable {
    public var visited = 0
    public var offscreenSkipped = 0
    public var truncated = false
    /// Failed attribute reads leave holes in the tree; absence checks must not treat these as empty subtrees.
    public var readFailures = 0
    public var milliseconds = 0
    /// Web views (AXWebArea) whose page hasn't finished loading.
    public var loadingPages = 0
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
        public init() {}
    }

    public static func walk(_ root: AXElement, options: Options = Options()) -> (RawNode, WalkStats) {
        var stats = WalkStats()
        let started = Date()
        let deadline = started.addingTimeInterval(options.timeLimit)

        func node(_ element: AXElement, clip: CGRect?, path: String, depth: Int) -> RawNode? {
            guard !Task.isCancelled else { stats.truncated = true; return nil }
            guard stats.visited < options.maxNodes, depth < 60 else { stats.truncated = true; return nil }
            if stats.visited % 64 == 0, Date() > deadline { stats.truncated = true; return nil }
            stats.visited += 1
            guard let v = element.read(attributes) else { stats.readFailures += 1; return nil }

            var n = RawNode(role: v["AXRole"] as? String ?? "AXUnknown")
            n.element = element
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
            if n.role == "AXWebArea", element.attribute("AXLoaded") as? Bool == false { stats.loadingPages += 1 }
            var childClip = clip
            if clippingRoles.contains(n.role), let f = n.frame, f.width > 0, f.height > 0 {
                childClip = clip.map { $0.intersection(f) }   // no clip stays no clip (offscreen: true)
            }

            var children = (v["AXChildren"] as? [AXUIElement])?.map(AXElement.init) ?? []
            // Lists and tables: walk only the visible rows when clipping (count the rest as offscreen), all otherwise.
            if visibleRowRoles.contains(n.role) || n.role == "AXList" {
                let visible = element.elements(n.role == "AXList" ? "AXVisibleChildren" : "AXVisibleRows")
                if !visible.isEmpty {
                    let all = n.role == "AXList" ? children : element.elements("AXRows")
                    if options.clip != nil {
                        stats.offscreenSkipped += max(0, all.count - visible.count)
                        children = visible
                    } else if !all.isEmpty {
                        children = all
                    }
                }
            }
            // An unlabeled control may name its label element explicitly.
            if n.title == nil, n.description == nil, Snapshot.isInteractive(n),
               let labelElement = element.element("AXTitleUIElement"),
               let text = labelElement.string(kAXValueAttribute) ?? labelElement.string(kAXTitleAttribute) {
                n.title = text
            }
            if n.role == "AXMenuBarItem", !options.descendMenus { children = [] }

            for (i, child) in children.enumerated() {
                if let c = node(child, clip: childClip, path: path.isEmpty ? "\(i)" : "\(path).\(i)", depth: depth + 1) {
                    n.children.append(c)
                }
                if stats.truncated { break }
            }
            return n
        }

        let root = node(root, clip: options.clip, path: "", depth: 0) ?? RawNode(role: "AXUnknown")
        stats.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return (root, stats)
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
