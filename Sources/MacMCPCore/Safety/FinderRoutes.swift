import AppKit
import ApplicationServices
import Foundation

/// What reading a selection takes from a tree, so that it runs the same on accessibility elements and on the fake
/// trees of the tests. A read that failed is told apart from an attribute the element doesn't have: a role or children
/// that can't be read leave the walk incomplete, a selection that can't be read leaves it unknown.
struct SelectionTree<N> {
    /// nil when it can't be read.
    var role: (N) -> String?
    /// nil when they can't be read.
    var children: (N) -> [N]?
    var parent: (N) -> N?
    var selected: (N) -> ListSelection<N>
    /// AXURL on the element itself.
    var url: (N) -> URL?
    var identifier: (N) -> String? = { _ in nil }
    var frame: (N) -> CGRect? = { _ in nil }
    /// Whether two nodes are the same element; nodes never match without it.
    var same: (N, N) -> Bool = { _, _ in false }
}

/// What a node says is selected in it.
enum ListSelection<N> {
    /// It holds no selection: it isn't a list.
    case none
    /// Reading its selection failed.
    case unreadable
    case items([N])

    var items: [N]? { if case let .items(items) = self { items } else { nil } }
    var isNone: Bool { if case .none = self { true } else { false } }
}

extension SelectionTree where N == AXElement {
    static var accessibility: SelectionTree {
        SelectionTree(role: { e in
                          // `kAXErrorFailure` is what some apps answer for an attribute they don't have: believed the second time.
                          var read = e.attribute(reporting: kAXRoleAttribute)
                          if read.error == .failure { read = e.attribute(reporting: kAXRoleAttribute) }
                          return read.error == nil ? read.value as? String : nil
                      },
                      children: { e in
                          var read = e.elements(reporting: kAXChildrenAttribute)
                          if read.error == .failure { read = e.elements(reporting: kAXChildrenAttribute) }
                          return read.error == nil ? read.elements : nil
                      },
                      parent: { $0.element(kAXParentAttribute) },
                      selected: { e in
                          var read = e.read(reporting: selectionAttributes)
                          if read?.errors.values.contains(.failure) == true { read = e.read(reporting: selectionAttributes) }
                          return selection(from: read)
                      },
                      url: { OpenRoutes.url(of: $0, levels: 0) },
                      identifier: { $0.string(kAXIdentifierAttribute) },
                      frame: { e in
                          let v = e.read([kAXPositionAttribute, kAXSizeAttribute]) ?? [:]
                          return MacMCPCore.frame(position: v[kAXPositionAttribute], size: v[kAXSizeAttribute])
                      },
                      same: ==)
    }

    static let selectionAttributes = [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute]

    /// What a batched read of a list's selected children and rows says. Either one failing leaves the selection
    /// unknown, even when the other reads empty (an outline whose rows fail may answer no selected children); neither
    /// there at all means the element holds no selection.
    static func selection(from read: AXElement.Read?) -> ListSelection<AXElement> {
        guard let read, read.errors.isEmpty else { return .unreadable }
        let lists = selectionAttributes.compactMap { read.values[$0] }
        if lists.isEmpty { return .none }
        var items: [AXElement] = []
        for list in lists {
            guard let values = list as? [Any] else { return .unreadable }
            let elements = values.compactMap(AXElement.from)
            guard elements.count == values.count else { return .unreadable }
            items += elements
        }
        return .items(items)
    }
}

/// Finder's windows as its route checks read them (macOS 26): which files are selected, which folder a paste or a
/// drop on blank space lands in, which item a click, drag or rename is on. Finder sets no AXDocument on its windows,
/// so a window's folder is known from the files it lists.
extension OpenRoutes {
    /// AppKit identifiers of Finder's icon, list, column and gallery views: their lists stand for a folder's files even
    /// while it shows none.
    static let finderViewIdentifiers: Set<String> = ["IconView", "ListView", "ColumnView", "GalleryView"]

    /// One file list of a Finder window (a column of a column view, or the whole icon, list or gallery view).
    struct FinderList<N> {
        var node: N
        /// Its selected items; nil when they can't be read.
        var selected: [N]?
        /// The folder whose files it lists: the parent of its first items, or for an empty column the folder selected
        /// in the column before it.
        var folder: URL?
        /// A column of a column view.
        var column = false
    }

    /// What one read of a Finder window (or the desktop) found.
    struct FinderWindowRead<N> {
        var lists: [FinderList<N>] = []
        /// The path bar's folders, outermost first, when it is shown.
        var pathBar: [URL] = []
        /// The walk ended within its bound, and every role and set of children on the way could be read.
        var complete = true
    }

    /// What a Finder window shows: the files selected (empty when its file lists were read and nothing in them is
    /// selected, nil when they can't be read), the folders a drop on blank space could land in, and the ones a paste
    /// lands in (in column view, the column holding focus rather than every column shown).
    public struct FinderView: Equatable, Sendable {
        public var selection: [URL]?
        public var folders: [URL]
        public var pasteFolders: [URL]
        public init(selection: [URL]?, folders: [URL], pasteFolders: [URL]? = nil) {
            self.selection = selection
            self.folders = folders
            self.pasteFolders = pasteFolders ?? folders
        }
    }

    static let fileListRoles: Set<String> = [kAXListRole, kAXTableRole, kAXOutlineRole]
    public static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// The file lists of a window, without walking their items (the selection says what is selected). A list counts
    /// as one when it is one of Finder's views, a column of a column view, or a list whose first items carry file URLs
    /// (the desktop's icons); the sidebar's places carry none and the path bar is read apart. An element whose role or
    /// children can't be read could be, or hold, a file list: the read is then incomplete.
    static func finderLists<N>(in root: N, tree t: SelectionTree<N>) -> FinderWindowRead<N> {
        var read = FinderWindowRead<N>()
        var queue = [(root, false)], visited = 0
        var lastColumnSelection: URL?
        while !queue.isEmpty, visited < 600 {
            let (e, inBrowser) = queue.removeFirst()
            visited += 1
            guard let role = t.role(e) else { read.complete = false; continue }
            if role == kAXBrowserRole {
                guard let children = t.children(e) else { read.complete = false; continue }
                queue += children.map { ($0, true) }
                continue
            }
            let selected = t.selected(e)
            // A group whose selection can't be read may be the desktop's.
            let listLike = fileListRoles.contains(role) || (role == kAXGroupRole && !selected.isNone)
            guard listLike else {
                guard let children = t.children(e) else { read.complete = false; continue }
                queue += children.map { ($0, inBrowser) }
                continue
            }
            guard let children = t.children(e) else { read.complete = false; continue }
            let items = Array(children.prefix(6))
            if let chain = pathBar(items, tree: t) {
                read.pathBar = chain
                continue
            }
            let urls = items.lazy.compactMap { itemURL(of: $0, tree: t) }
            let first = urls.first
            guard first != nil || inBrowser || finderViewIdentifiers.contains(t.identifier(e) ?? "") else { continue }
            var list = FinderList(node: e, selected: selected.items, folder: first?.deletingLastPathComponent(), column: inBrowser)
            if inBrowser {
                if list.folder == nil { list.folder = lastColumnSelection }
                lastColumnSelection = (selected.items ?? []).compactMap { itemURL(of: $0, tree: t) }.last { isPlainFolder($0) }
            }
            read.lists.append(list)
        }
        if !queue.isEmpty { read.complete = false }
        return read
    }

    /// The path bar's items: static texts each carrying the URL of the folder inside the one before.
    static func pathBar<N>(_ items: [N], tree t: SelectionTree<N>) -> [URL]? {
        guard !items.isEmpty, items.allSatisfy({ t.role($0) == kAXStaticTextRole }) else { return nil }
        let urls = items.compactMap(t.url)
        guard urls.count == items.count, urls.allSatisfy(\.isFileURL) else { return nil }
        return urls
    }

    static func finderView<N>(_ read: FinderWindowRead<N>, focused: N? = nil, tree t: SelectionTree<N>) -> FinderView {
        var selection: [URL]? = read.complete && !read.lists.isEmpty ? [] : nil
        for list in read.lists {
            guard let rows = list.selected else { selection = nil; break }
            let urls = rows.map { itemURL(of: $0, tree: t) }
            if urls.contains(where: { $0 == nil }) { selection = nil; break }
            selection? += urls.compactMap { $0 }
        }
        var folders = unique(read.lists.compactMap(\.folder))
        // An empty icon or list view names no folder; the path bar does, ending at the selected item when there is one.
        if folders.isEmpty, var chain = read.pathBar.isEmpty ? nil : read.pathBar {
            if let last = chain.last, selection.map({ $0.contains(last) }) ?? true { chain.removeLast() }
            folders = chain.suffix(1)
        }
        return FinderView(selection: selection, folders: folders, pasteFolders: columnPasteFolders(read, focused: focused, tree: t))
    }

    /// Where a paste lands in column view: the folder of the column holding focus, or the folder selected in it (a
    /// column before the last stays focused while the folder selected in it is shown after). Nil when the window isn't
    /// in column view or the column holding focus isn't known: then every folder it shows counts.
    static func columnPasteFolders<N>(_ read: FinderWindowRead<N>, focused: N?, tree t: SelectionTree<N>) -> [URL]? {
        guard read.complete, !read.lists.isEmpty, read.lists.allSatisfy(\.column) else { return nil }
        var node = focused
        for _ in 0..<6 {
            guard let e = node else { return nil }
            if let list = read.lists.first(where: { t.same($0.node, e) }) {
                guard let folder = list.folder, let rows = list.selected else { return nil }
                let urls = rows.map { itemURL(of: $0, tree: t) }
                guard !urls.contains(where: { $0 == nil }) else { return nil }
                return unique([folder] + urls.compactMap { $0 }.filter(isPlainFolder))
            }
            node = t.parent(e)
        }
        return nil
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: Finder's selection

    /// The files selected in Finder's front window (or desktop), or nil if they can't be read.
    public static func finderSelection(pid: pid_t) -> [URL]? {
        let app = AXElement.application(pid: pid)
        return finderSelection(focused: app.element(kAXFocusedUIElementAttribute), windows: { finderWindows(app) }, tree: .accessibility)
    }

    /// The front window's view: the focused window, or the main one while focus is in a window without file lists
    /// (the field Finder renames an item in, a dialog).
    public static func finderView(pid: pid_t) -> FinderView? {
        let app = AXElement.application(pid: pid)
        return frontView(windows: finderWindows(app), focused: app.element(kAXFocusedUIElementAttribute), tree: .accessibility)
    }

    /// The focused window, then the main one; the desktop when Finder has neither.
    static func finderWindows(_ app: AXElement) -> [AXElement] {
        var windows: [AXElement] = []
        for w in [app.element(kAXFocusedWindowAttribute), app.element(kAXMainWindowAttribute)].compactMap({ $0 }) where !windows.contains(w) {
            windows.append(w)
        }
        return windows.isEmpty ? app.elements(kAXWindowsAttribute).filter { $0.role == kAXScrollAreaRole } : windows
    }

    static func frontView<N>(windows: [N], focused: N? = nil, tree t: SelectionTree<N>) -> FinderView? {
        for window in windows {
            let read = finderLists(in: window, tree: t)
            if !read.lists.isEmpty || !read.complete { return finderView(read, focused: focused, tree: t) }
        }
        return nil
    }

    /// The selection of the list holding focus, nearest first up from `focused`; without one, every file list of the
    /// front window. A selected item standing for no file, or a selection on the way up that can't be read, makes it
    /// unreadable.
    static func finderSelection<N>(focused: N?, windows: () -> [N], tree t: SelectionTree<N>) -> [URL]? {
        var node = focused
        for _ in 0..<6 {
            guard let e = node else { break }
            switch t.selected(e) {
            case .unreadable: return nil
            case let .items(selected) where !selected.isEmpty:
                let urls = selected.map { itemURL(of: $0, tree: t) }
                return urls.contains(where: { $0 == nil }) ? nil : urls.compactMap { $0 }
            default: break
            }
            node = t.parent(e)
        }
        return frontView(windows: windows(), tree: t)?.selection
    }

    // MARK: Items under a click, drag or drop

    /// What a point in a Finder window is on.
    enum FinderHit: Equatable {
        /// An item standing for this file.
        case item(URL)
        /// An item (a row, an icon, a sidebar place) that stands for no file that can be read.
        case unreadable
        /// The space around items: a drop there lands in the window's folder.
        case background
    }

    /// The item holding `hit`: the element carrying its URL, up from the hit (a name field, an icon's image), or down
    /// from the row or item of a list it is in (a list view row's date cell holds no URL).
    static func finderHit<N>(_ hit: N, tree t: SelectionTree<N>) -> FinderHit {
        var node: N? = hit
        for _ in 0..<6 {
            guard let n = node else { break }
            if let url = t.url(n) { return url.isFileURL ? .item(url) : .unreadable }
            guard let role = t.role(n) else { return .unreadable }
            if fileListRoles.contains(role) || [kAXWindowRole, kAXApplicationRole, kAXScrollAreaRole, kAXBrowserRole].contains(role) {
                return .background
            }
            let parent = t.parent(n)
            if role == kAXRowRole || parent.map({ fileListRoles.contains(t.role($0) ?? "") || !t.selected($0).isNone }) == true {
                return itemURL(of: n, tree: t).map { .item($0) } ?? .unreadable
            }
            node = parent
        }
        return .unreadable
    }

    public static func finderHit(_ hit: AXElement) -> FinderHitResult {
        switch finderHit(hit, tree: .accessibility) {
        case let .item(url): .item(url)
        case .unreadable: .unreadable
        case .background: .background
        }
    }

    public enum FinderHitResult: Equatable, Sendable { case item(URL), unreadable, background }

    /// The window (or desktop) an element is in: the last element up from it before the application.
    static func topLevel<N>(of element: N, tree t: SelectionTree<N>) -> N? {
        var node = element
        for _ in 0..<40 {
            guard let parent = t.parent(node) else { return nil }
            if t.role(parent) == kAXApplicationRole { return node }
            node = parent
        }
        return nil
    }

    /// The view of the window an element is in, for a drag that starts there or a drop that lands there; nil for a
    /// window that lists no files (a dialog, the Copy window).
    public static func finderView(around element: AXElement) -> FinderView? {
        finderView(around: element, tree: .accessibility)
    }

    static func finderView<N>(around element: N, tree t: SelectionTree<N>) -> FinderView? {
        guard let window = topLevel(of: element, tree: t) else { return FinderView(selection: nil, folders: []) }
        let read = finderLists(in: window, tree: t)
        return read.lists.isEmpty && read.complete ? nil : finderView(read, tree: t)
    }

    /// The folders a drop at `hit` could land in: a folder it is on, and the folders its window shows (a list view
    /// row takes a drop only over its icon and name, and a file under the drop doesn't take it). Nil when they can't
    /// be told: an unreadable item, a sidebar place, an empty window.
    static func dropFolders<N>(_ hit: N, tree t: SelectionTree<N>) -> [URL]? {
        var folders: [URL] = []
        switch finderHit(hit, tree: t) {
        case let .item(url) where isPlainFolder(url): folders.append(url)
        case let .item(url): folders.append(url.deletingLastPathComponent())
        case .unreadable: return nil
        case .background: break
        }
        folders += finderView(around: hit, tree: t)?.folders ?? []
        return folders.isEmpty ? nil : unique(folders)
    }

    public static func dropFolders(_ hit: AXElement) -> [URL]? { dropFolders(hit, tree: .accessibility) }

    /// The files a drag from `hit` carries: the selection of its window when the item under it is part of it (Finder
    /// drags them all), else that item alone. Nil when the item or the selection can't be read.
    static func draggedFiles<N>(_ hit: N, tree t: SelectionTree<N>) -> [URL]? {
        guard case let .item(url) = finderHit(hit, tree: t), let selection = finderView(around: hit, tree: t)?.selection else { return nil }
        return selection.contains(url) ? selection : [url]
    }

    public static func draggedFiles(_ hit: AXElement) -> [URL]? { draggedFiles(hit, tree: .accessibility) }

    // MARK: Renaming

    /// The item Finder is renaming in the field at `center`: its file when that can be read, the folder of the list it
    /// is in, and whether it is the only item selected there. Finder edits names in a field of its own, outside the
    /// list, and takes the row's name field away meanwhile (a list or column view row then carries no URL), so the
    /// item is the selected one under the field.
    static func renamedItem<N>(at center: CGPoint, windows: [N], tree t: SelectionTree<N>) -> RenamedItem? {
        for window in windows {
            for list in finderLists(in: window, tree: t).lists {
                let selected = list.selected ?? []
                for item in selected where t.frame(item)?.contains(center) == true {
                    return RenamedItem(url: itemURL(of: item, tree: t), folder: list.folder, alone: selected.count == 1)
                }
            }
        }
        return nil
    }

    struct RenamedItem {
        var url: URL?
        var folder: URL?
        /// The only item selected in its list: Finder renames one item at a time.
        var alone = true
    }

    /// Why Finder mustn't rename the item it is editing in `field`, or nil. Its file when that can be read; otherwise
    /// the item checked when the rename began (`noteFinderSelection`) if it is still there in the folder listed, or
    /// that folder, which must then hold nothing protected at any depth (a list view shows subfolders' items too).
    /// Also gives the folders a typed name is checked against.
    public static func finderRenameCheck(_ field: AXElement, pid: pid_t) -> (refusal: String?, folders: [String]) {
        if let url = url(of: field) {
            return (mutationSelectionRefusal([url]), [url.deletingLastPathComponent().path])
        }
        let app = AXElement.application(pid: pid)
        let windows = finderWindows(app) + app.elements(kAXWindowsAttribute)
        guard let frame = SelectionTree.accessibility.frame(field),
              let item = renamedItem(at: CGPoint(x: frame.midX, y: frame.midY), windows: windows, tree: .accessibility) else {
            return (unreadableSelectionRefusal, [])
        }
        return renameRefusal(item, noted: notedFinderItem(pid: pid))
    }

    /// `noted`: the one item an agent's last checked click, key or menu command in Finder was on, where it is now.
    /// Every route that starts a rename (Return, File ▸ Rename, a click on a selected item's name) is checked against
    /// the selection or the item it is on, and notes it, so an item being renamed with no file of its own is that one
    /// when it sits alone in the same folder.
    static func renameRefusal(_ item: RenamedItem, noted: URL? = nil) -> (refusal: String?, folders: [String]) {
        let folders = [item.url?.deletingLastPathComponent(), item.folder].compactMap { $0?.path }
        if let url = item.url { return (mutationSelectionRefusal([url]), folders) }
        guard let folder = item.folder else { return (unreadableSelectionRefusal, []) }
        if item.alone, let noted, samePath(noted.deletingLastPathComponent(), folder) {
            return (mutationSelectionRefusal([noted]), folders)
        }
        return (ProtectedPaths.mutationRefusal(folder.path), folders)
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        ProtectedPaths.comparable(ProtectedPaths.physical(a.path)) == ProtectedPaths.comparable(ProtectedPaths.physical(b.path))
    }

    /// The item noted for a rename: Finder's pid, the file and its identity.
    private static let finderNoted = Locked<(pid: pid_t, url: URL, reference: NSURL)?>(nil)

    /// Notes what an agent's checked key or menu command in Finder acts on (its selection, nil when it can't be read)
    /// or what a click lands on; only a single item is kept.
    public static func noteFinderSelection(_ urls: [URL]?, pid: pid_t) {
        let url = urls.flatMap { $0.count == 1 ? $0[0] : nil }
        let reference = url.flatMap(fileReference)
        finderNoted.withLock { $0 = reference.map { (pid, url!, $0) } }
    }

    /// The noted item while it is still where it was noted: renamed, moved or replaced, it no longer counts.
    static func notedFinderItem(pid: pid_t) -> URL? {
        finderNoted.withLock { noted in
            guard let noted, noted.pid == pid, let now = currentURL(of: noted.reference), samePath(now, noted.url) else { return nil }
            return noted.url
        }
    }

    /// A file's identity (volume and file ID), which follows it through renames and moves: its file reference URL.
    /// Kept as NSURL: bridged to URL, a reference URL turns into the path it had.
    static func fileReference(_ url: URL) -> NSURL? {
        guard let reference = (url as NSURL).fileReferenceURL() as NSURL?, reference.isFileReferenceURL() else { return nil }
        return reference
    }

    /// Where the file a reference stands for is now; nil when it is gone.
    static func currentURL(of reference: NSURL) -> URL? {
        guard let path = reference.filePathURL?.path, path.hasPrefix("/"), !path.hasPrefix("/.file/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: Pasting and dropping files

    /// Why copying or moving `files` into any of `folders` must be refused, or nil: a protected file or a folder
    /// holding one, or a name that would land on (or replace) a protected location.
    public static func transferRefusal(_ files: [URL], into folders: [URL]) -> String? {
        for file in files {
            if let r = ProtectedPaths.mutationRefusal(file.path) { return r }
        }
        for folder in folders {
            for file in files {
                if let r = ProtectedPaths.mutationRefusal(folder.appendingPathComponent(file.lastPathComponent).path) { return r }
            }
        }
        return nil
    }

    public static let unknownFolderRefusal = "Refused: Finder doesn't say which folder this window shows while it lists no "
        + "files. Switch it to column view (cmd+3) or show the path bar (View > Show Path Bar), or drop the items onto the "
        + "folder's icon."
}
