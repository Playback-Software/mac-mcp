import ApplicationServices
import Foundation

/// Which sheets, popovers and dialogs are file panels (Open, Save, Go to Folder). A container counts only on evidence:
/// an ordinary dialog or floating panel (Fonts, Find, a rename or login sheet) is not one just for being a sheet.
enum FilePanelScan {
    /// What one element tells about the container holding it.
    struct Probe {
        var role = ""
        var identifier = ""
        /// AXURL is a file URL.
        var fileURL = false
        /// The element belongs to the out-of-process Open/Save service, not the app showing the panel.
        var remote = false
    }

    enum Verdict: Equatable {
        case panel, notPanel
        /// Part of the container couldn't be read, or the walk hit its bound before settling.
        case unreadable
    }

    /// AppKit's own identifiers, as seen on the sheet or window (`save-panel`, `open-panel`, the Go to Folder sheet)
    /// and inside the panel: its name field and label, Go to Folder's path field, the sidebar's section headers, the
    /// column view, the "more options" disclosure, the format and location popups and its buttons. These aren't
    /// localized.
    static let identifiers: Set<String> = [
        "save-panel", "open-panel", "GoToWindow", "PathTextField", "saveAsNameTextField", "nameFieldLabel",
        "xSidebarHeader", "ColumnView", "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE", "ContentTypesPopup", "NewFolderButton",
        "NewDocumentButton", "where popup",
    ]

    /// Windows that are file panels by identifier alone: a modal Open panel is an ordinary window, not a dialog.
    static let windowIdentifiers: Set<String> = ["save-panel", "open-panel"]

    static let listRoles: Set<String> = [kAXListRole, kAXTableRole, kAXOutlineRole]

    /// Rows read from each list. Fonts, contacts or messages come in thousands; a file list shows file URLs from its
    /// first rows on, and a panel has other evidence besides.
    static let sampledRows = 6
    static let visitLimit = 300

    /// A bounded breadth-first walk. Evidence: the out-of-process panel service as owner of an element, a column view,
    /// one of AppKit's identifiers, or a row in a list carrying a file URL.
    static func verdict<N>(_ root: N, probe: (N) -> Probe?, children: (N) -> [N]?) -> Verdict {
        var queue: [(node: N, inList: Bool)] = [(root, false)]
        var next = 0
        var unreadable = false
        while next < queue.count {
            if next >= visitLimit { return .unreadable }
            let (node, inList) = queue[next]
            next += 1
            guard let p = probe(node) else { unreadable = true; continue }
            if p.remote || p.role == kAXBrowserRole || identifiers.contains(p.identifier) || (inList && p.fileURL) { return .panel }
            guard let kids = children(node) else { unreadable = true; continue }
            // A container with nothing in it yet (a remote view still loading) tells nothing.
            if next == 1, kids.isEmpty { unreadable = true }
            let list = listRoles.contains(p.role)
            queue += (list ? Array(kids.prefix(sampledRows)) : kids).map { ($0, inList || list) }
        }
        return unreadable ? .unreadable : .notPanel
    }

    /// A kind of container a file panel can be.
    enum Kind: Equatable {
        case sheet, popover, dialog, floating
        /// An ordinary window by subrole whose identifier says it is an Open or Save panel.
        case window

        init?(role: String, subrole: String, identifier: String) {
            switch role {
            case "AXSheet": self = .sheet
            case "AXPopover": self = .popover
            case kAXWindowRole:
                if ["AXDialog", "AXSystemDialog"].contains(subrole) { self = .dialog }
                else if ["AXFloatingWindow", "AXSystemFloatingWindow"].contains(subrole) { self = .floating }
                else if windowIdentifiers.contains(identifier) { self = .window }
                else { return nil }
            default: return nil
            }
        }
    }

    /// Whether a container is treated as a file panel, given what its scan found. A sheet or dialog that can't be
    /// read fails closed, since a real panel is one of those; a floating panel or popover doesn't (a Fonts panel on
    /// a busy app would be refused as a panel). A popover in a document window stays one on that ground alone: it may
    /// be the one that renames the document's file.
    static func qualifies(_ kind: Kind, _ verdict: Verdict, inDocumentWindow: @autoclosure () -> Bool) -> Bool {
        switch verdict {
        case .panel: true
        case .unreadable: kind == .sheet || kind == .dialog
        case .notPanel: kind == .popover && inDocumentWindow()
        }
    }

    // MARK: Accessibility

    static func probe(_ element: AXElement, remote: (pid_t) -> Bool) -> Probe? {
        guard let read = element.read(reporting: [kAXRoleAttribute, kAXIdentifierAttribute, kAXURLAttribute]),
              read.failed.isEmpty else { return nil }
        return Probe(role: read.values[kAXRoleAttribute] as? String ?? "",
                     identifier: read.values[kAXIdentifierAttribute] as? String ?? "",
                     fileURL: OpenRoutes.fileURL(from: read.values[kAXURLAttribute]) != nil,
                     remote: remote(element.pid))
    }

    /// An element's children, or nil when the read failed (an element without children has none).
    static func children(_ element: AXElement) -> [AXElement]? {
        let read = element.attribute(reporting: kAXChildrenAttribute)
        guard read.error == nil else { return nil }
        return (read.value as? [AXUIElement])?.map(AXElement.init) ?? []
    }

    static func verdict(_ container: AXElement) -> Verdict {
        var remote: [pid_t: Bool] = [:]
        func isRemote(_ pid: pid_t) -> Bool {
            if let known = remote[pid] { return known }
            let result = OpenRoutes.ownerBundleID(pid) == OpenRoutes.panelService
            remote[pid] = result
            return result
        }
        return verdict(container, probe: { probe($0, remote: isRemote) }, children: children)
    }

    /// Fresh positive evidence of which service processes are attached to this container. Unlike classification,
    /// an AppKit identifier or browser is no reason to stop: it says nothing about who draws the panel's pixels.
    static func servicePIDs<N>(_ root: N, probe: (N) -> Probe?, pid: (N) -> pid_t, children: (N) -> [N]?) -> Set<pid_t> {
        var queue = [root], next = 0
        var result: Set<pid_t> = []
        while next < queue.count, next < visitLimit {
            let node = queue[next]
            next += 1
            guard let p = probe(node) else { continue }
            if p.remote { result.insert(pid(node)) }
            if let kids = children(node) {
                queue += listRoles.contains(p.role) ? Array(kids.prefix(sampledRows)) : kids
            }
        }
        return result
    }

    static func servicePIDs(_ container: AXElement) -> Set<pid_t> {
        var remote: [pid_t: Bool] = [:]
        return servicePIDs(container, probe: { element in
            probe(element, remote: { pid in
                if let known = remote[pid] { return known }
                let result = OpenRoutes.ownerBundleID(pid) == OpenRoutes.panelService
                remote[pid] = result
                return result
            })
        }, pid: { $0.pid }, children: children)
    }
}

/// Decisions about containers that stay open: a file panel stays one while it exists, so a verdict that said so is
/// kept until the panel is gone. One that said not is kept briefly, since a panel's contents can load after it
/// appears. Verdicts that couldn't be reached aren't kept.
final class FilePanelCache<Key: Hashable>: @unchecked Sendable {
    private struct Entry { var panel: Bool; var at: Date }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let isAlive: (Key) -> Bool
    let notPanelLifetime: TimeInterval
    let capacity: Int

    init(notPanelLifetime: TimeInterval = 2, capacity: Int = 16, isAlive: @escaping (Key) -> Bool) {
        self.notPanelLifetime = notPanelLifetime
        self.capacity = capacity
        self.isAlive = isAlive
    }

    func lookup(_ key: Key, now: Date = Date()) -> Bool? {
        guard let entry = lock.withLock({ entries[key] }) else { return nil }
        if entry.panel {
            if isAlive(key) { return true }
        } else if now.timeIntervalSince(entry.at) < notPanelLifetime {
            return false
        }
        lock.withLock { entries[key] = nil }
        return nil
    }

    func store(_ key: Key, panel: Bool, now: Date = Date()) {
        let known = lock.withLock { entries }
        let gone = known.filter { $0.value.panel ? !isAlive($0.key) : now.timeIntervalSince($0.value.at) >= notPanelLifetime }.keys
        lock.withLock {
            for k in gone { entries[k] = nil }
            while entries.count >= capacity, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries[oldest] = nil }
            entries[key] = Entry(panel: panel, at: now)
        }
    }
}

extension OpenRoutes {
    /// The out-of-process service that shows Open and Save panels for apps.
    public static let panelService = "com.apple.appkit.xpc.openAndSavePanelService"

    /// The service draws a host's panel in its own windows. Ownership alone isn't enough: a fresh host attachment
    /// and a hit inside that panel (or an AX-linked popup menu) must agree. A nil point checks an AX ref's ancestry.
    /// Call on a guard worker.
    public static func filePanelOwnsPoint(owner: pid_t, host: pid_t, at point: CGPoint?, hit: AXElement? = nil) -> Bool {
        guard let hit, owner != host, ownerBundleID(owner) == panelService else { return false }
        return filePanelOwnsPoint(owner: owner, hitPID: hit.pid, ownerBundleID: panelService, prompt: WindowServer.isSystemPrompt(pid: owner),
                                  point: point, panel: { activeNamingPanel(pid: host) },
                                  servicePIDs: FilePanelScan.servicePIDs, frame: Actions.frameOf,
                                  insidePanel: { namingPanel(of: hit) == $0 },
                                  linkedMenu: { panel in
            let command = commandTarget(of: hit)
            guard [kAXMenuItemRole, kAXMenuRole].contains(command.role ?? "") else { return false }
            if Actions.isWithin(hit, panel) { return true }
            // Remote menus can lose their parent link while remaining children of the panel's popup control.
            var queue = [panel], next = 0
            while next < queue.count, next < FilePanelScan.visitLimit {
                let node = queue[next]
                next += 1
                if node == hit || node == command { return true }
                queue += FilePanelScan.children(node) ?? []
            }
            return false
        })
    }

    static func filePanelOwnsPoint<N>(owner: pid_t, hitPID: pid_t, ownerBundleID: String?, prompt: Bool, point: CGPoint?, panel: () -> N?,
                                     servicePIDs: (N) -> Set<pid_t>, frame: (N) -> CGRect?, insidePanel: (N) -> Bool,
                                     linkedMenu: (N) -> Bool) -> Bool {
        guard owner == hitPID, ownerBundleID == panelService, !prompt, let panel = panel(), servicePIDs(panel).contains(owner) else { return false }
        return (insidePanel(panel) && (point.map { frame(panel)?.contains($0) == true } ?? true)) || linkedMenu(panel)
    }

    /// A drop has no explicit destination app. Use the hit's enclosing panel/window as a candidate host, then apply
    /// the same fresh service-pid and hit checks as a source bound by app= or ref. Missing host links fail closed.
    public static func filePanelHost(of hit: AXElement, at point: CGPoint) -> pid_t? {
        guard let owner = WindowServer.owner(at: point), ownerBundleID(owner) == panelService else { return nil }
        let candidates = [namingPanel(of: hit)?.pid, Input.windowOwner(of: hit)].compactMap { $0 }
        return candidates.first { filePanelOwnsPoint(owner: owner, host: $0, at: point, hit: hit) }
    }

    private static let filePanels = FilePanelCache<AXElement>(isAlive: { $0.isAlive })

    /// Whether `container`, a sheet, popover, dialog or floating window, is an Open, Save or Go to Folder panel: it holds
    /// a file browser or another sign of one (see `FilePanelScan`).
    static func isFilePanel(_ container: AXElement, kind: FilePanelScan.Kind) -> Bool {
        if let known = filePanels.lookup(container) { return known }
        let verdict = FilePanelScan.verdict(container)
        let result = FilePanelScan.qualifies(kind, verdict, inDocumentWindow: isInDocumentWindow(container))
        if verdict != .unreadable { filePanels.store(container, panel: result) }
        return result
    }

    /// Whether the window holding `element` stands for a file (a document window), by its AXDocument.
    static func isInDocumentWindow(_ element: AXElement) -> Bool {
        var node: AXElement? = element
        for _ in 0..<8 {
            guard let e = node else { return false }
            if e.role == kAXWindowRole { return fileURL(from: e.attribute(kAXDocumentAttribute)) != nil }
            node = e.element(kAXParentAttribute)
        }
        return false
    }

    /// The file URL an AXURL or AXDocument value holds, if it holds one.
    static func fileURL(from value: Any?) -> URL? {
        let url = value as? URL ?? (value as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0) }
        return url?.isFileURL == true ? url : nil
    }
}
