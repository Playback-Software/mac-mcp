import ApplicationServices
import Foundation
import Testing
@testable import MacMCPCore

/// Reading Finder's selection, on fake trees shaped like its icon, list, column and gallery views (macOS 26).
@Suite struct FinderSelectionTests {
    final class Node {
        let role: String
        let url: URL?
        var identifier: String?
        var frame: CGRect?
        var children: [Node] { didSet { children.forEach { $0.parent = self } } }
        /// nil: holds no selection, or (on a list) one that can't be read.
        var selected: [Node]?
        weak var parent: Node?
        /// Reads of these fail: "role", "children", "selection".
        var failing: Set<String> = []
        init(_ role: String, url: URL? = nil, identifier: String? = nil, _ children: [Node] = []) {
            self.role = role
            self.url = url
            self.identifier = identifier
            self.children = children
            children.forEach { $0.parent = self }
        }
    }

    private let tree = SelectionTree<Node>(role: { $0.failing.contains("role") ? nil : $0.role },
                                           children: { $0.failing.contains("children") ? nil : $0.children }, parent: { $0.parent },
                                           selected: { n in n.failing.contains("selection") ? .unreadable : n.selected.map { .items($0) } ?? .none },
                                           url: { $0.url }, identifier: { $0.identifier }, frame: { $0.frame }, same: { $0 === $1 })
    private let file = URL(fileURLWithPath: "/tmp/route/one.txt")
    private let other = URL(fileURLWithPath: "/tmp/route/two.txt")

    /// An icon or gallery view's item: a group holding the file's image, which carries its URL.
    private func iconItem(_ url: URL?) -> Node { Node("AXGroup", [Node("AXImage", url: url)]) }

    /// A list view's row: cells for name, date, size and kind; the name cell's field carries the URL.
    private func listRow(_ url: URL?) -> Node {
        Node(kAXRowRole, [Node("AXCell", [Node("AXImage"), Node(kAXTextFieldRole, url: url)]),
                          Node("AXCell", [Node("AXStaticText")]), Node("AXCell", [Node("AXStaticText")])])
    }

    /// A column view's item: a group holding an image and the name field, which carries the URL.
    private func columnItem(_ url: URL?) -> Node { Node("AXGroup", [Node("AXImage"), Node(kAXTextFieldRole, url: url)]) }

    private func sidebarRow() -> Node { Node(kAXRowRole, [Node("AXCell", [Node("AXImage"), Node("AXStaticText")])]) }

    private func list(_ role: String, _ items: [Node], selecting selected: [Node], identifier: String? = nil) -> Node {
        let list = Node(role, identifier: identifier, items)
        list.selected = selected
        return list
    }

    /// A window with a sidebar (its place selected) and `content`.
    private func window(_ content: Node) -> Node {
        let place = sidebarRow()
        return Node(kAXWindowRole, [Node("AXSplitGroup", [Node("AXScrollArea", [list(kAXOutlineRole, [place], selecting: [place])]),
                                                          Node("AXScrollArea", [content])])])
    }

    private func read(focused: Node?, in window: Node?) -> [URL]? {
        OpenRoutes.finderSelection(focused: focused, windows: { window.map { [$0] } ?? [] }, tree: tree)
    }

    @Test func everyViewReadsItsSelectedItemsFromTheFocusedList() {
        for (role, make) in [(kAXListRole, iconItem), (kAXOutlineRole, listRow), (kAXListRole, columnItem)] as [(String, (URL?) -> Node)] {
            let items = [make(file), make(other)]
            let view = list(role, items, selecting: items)
            #expect(read(focused: view, in: window(view)) == [file, other], "\(role)")
            // Focus on the name field of a row being renamed reads the list above it.
            #expect(read(focused: items[0].children.first?.children.last ?? items[0], in: window(view)) == [file, other], "\(role)")
        }
    }

    @Test func aListViewRowCarriesItsURLTwoLevelsDown() {
        let row = listRow(file)
        #expect(OpenRoutes.itemURL(of: row, tree: tree) == file)
        #expect(OpenRoutes.itemURL(of: listRow(nil), tree: tree) == nil)
        // Three levels down is not the row's own file.
        let deep = Node(kAXRowRole, [Node("AXCell", [Node("AXGroup", [Node(kAXTextFieldRole, url: file)])])])
        #expect(OpenRoutes.itemURL(of: deep, tree: tree) == nil)
    }

    @Test func aSelectedItemWithNoFileMakesTheSelectionUnreadable() {
        for (role, make) in [(kAXListRole, iconItem), (kAXOutlineRole, listRow), (kAXListRole, columnItem)] as [(String, (URL?) -> Node)] {
            let items = [make(file), make(nil)]
            let view = list(role, items, selecting: items)
            #expect(read(focused: view, in: window(view)) == nil, "\(role)")
            #expect(read(focused: nil, in: window(view)) == nil, "\(role) without focus")
        }
        // A focused sidebar's place is not a file either.
        let place = sidebarRow()
        #expect(read(focused: list(kAXOutlineRole, [place], selecting: [place]), in: nil) == nil)
    }

    @Test func withoutFocusTheWindowsFileListsAreReadAndItsSidebarLeftOut() {
        let items = [listRow(file), listRow(other)]
        let view = list(kAXOutlineRole, items, selecting: [items[1]])
        #expect(read(focused: nil, in: window(view)) == [other])
        // Nothing selected anywhere but the sidebar: the file list was read, and nothing in it is selected.
        #expect(read(focused: nil, in: window(list(kAXOutlineRole, items, selecting: []))) == [])
        #expect(read(focused: nil, in: nil) == nil)
        // A window with no file list, or one whose selection can't be read, has nothing to read.
        let place = sidebarRow()
        #expect(read(focused: nil, in: Node(kAXWindowRole, [list(kAXOutlineRole, [place], selecting: [place])])) == nil)
        let unreadable = list(kAXOutlineRole, items, selecting: [])
        unreadable.selected = nil
        #expect(read(focused: nil, in: window(unreadable)) == nil)
    }

    @Test func withoutFocusEveryColumnOfAColumnViewCounts() {
        let folder = URL(fileURLWithPath: "/tmp/route")
        let parent = columnItem(folder), child = columnItem(file)
        let browser = Node(kAXBrowserRole, [Node("AXScrollArea", [list(kAXListRole, [parent], selecting: [parent])]),
                                            Node("AXScrollArea", [list(kAXListRole, [child], selecting: [child])])])
        #expect(read(focused: nil, in: window(browser)) == [folder, file])
        // The focused column alone is what its keys act on.
        #expect(read(focused: child.parent, in: window(browser)) == [file])
    }

    @Test func aProtectedItemInAnyViewIsRefusedForCopying() throws {
        let protected = URL(fileURLWithPath: Paths.home + "/.config/mac-mcp")
        let copy = try KeySpec.parse("cmd+c")
        for (role, make) in [(kAXListRole, iconItem), (kAXOutlineRole, listRow), (kAXListRole, columnItem)] as [(String, (URL?) -> Node)] {
            let items = [make(file), make(protected)]
            let view = list(role, items, selecting: items)
            let selection = read(focused: view, in: window(view))
            #expect(selection == [file, protected], "\(role)")
            #expect(OpenRoutes.finderKeyRefusal(copy, selection: selection, policy: Policy()) != nil, "\(role)")
            let safe = list(role, [make(file)], selecting: [])
            safe.selected = safe.children
            #expect(OpenRoutes.finderKeyRefusal(copy, selection: read(focused: safe, in: window(safe)), policy: Policy()) == nil, "\(role)")
        }
    }

    // MARK: Empty views, window folders, items under the pointer (macOS 26 has no AXDocument on Finder windows)

    private let folder = URL(fileURLWithPath: "/tmp/route")

    /// Finder's application element above `windows`, which keeps the fake tree's weak parents alive.
    private func app(_ windows: Node...) -> Node { Node(kAXApplicationRole, windows) }

    @Test func anEmptyViewIsReadAsNothingSelectedWhenFinderSaysWhichViewItIs() {
        for id in ["IconView", "ListView", "GalleryView"] {
            let view = list(id == "ListView" ? kAXOutlineRole : kAXListRole, [], selecting: [], identifier: id)
            #expect(read(focused: view, in: window(view)) == [], "\(id)")
            #expect(OpenRoutes.frontView(windows: [window(view)], tree: tree)?.folders.isEmpty == true, "\(id) names no folder")
        }
        // A list of no known kind with nothing in it could be anything.
        let anonymous = list(kAXListRole, [], selecting: [])
        #expect(read(focused: nil, in: window(anonymous)) == nil)
    }

    @Test func aWindowsFolderIsTheParentOfItsFirstItems() {
        // A list view's first row is a top-level item even when a folder above is expanded below it.
        let rows = [listRow(URL(fileURLWithPath: "/tmp/route/inbox")), listRow(URL(fileURLWithPath: "/tmp/route/inbox/a.txt"))]
        let view = list(kAXOutlineRole, rows, selecting: [rows[1]], identifier: "ListView")
        let seen = OpenRoutes.frontView(windows: [window(view)], tree: tree)
        #expect(seen?.folders.map(\.path) == [folder.path])
        #expect(seen?.selection == [URL(fileURLWithPath: "/tmp/route/inbox/a.txt")])
        // A gallery view holds its items in a section list, one level further down.
        let gallery = list(kAXListRole, [Node(kAXListRole, [Node("AXGroup"), iconItem(file)])], selecting: [], identifier: "GalleryView")
        #expect(OpenRoutes.frontView(windows: [window(gallery)], tree: tree)?.folders.map(\.path) == [folder.path])
    }

    @Test func anEmptyColumnShowsTheFolderSelectedBeforeIt() {
        let empty = URL(fileURLWithPath: "/tmp/route/empty")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let parent = columnItem(empty)
        let browser = Node(kAXBrowserRole, [Node("AXScrollArea", [list(kAXListRole, [parent], selecting: [parent])]),
                                            Node("AXScrollArea", [list(kAXListRole, [], selecting: [])])])
        let seen = OpenRoutes.frontView(windows: [window(browser)], tree: tree)
        #expect(seen?.folders.map(\.path) == [folder.path, empty.path])
        #expect(seen?.selection == [empty])
    }

    @Test func thePathBarNamesAnEmptyWindowsFolder() {
        let chain = [URL(fileURLWithPath: "/tmp"), folder].map { Node(kAXStaticTextRole, url: $0) }
        let bar = Node(kAXListRole, chain)
        let view = list(kAXOutlineRole, [], selecting: [], identifier: "ListView")
        let w = Node(kAXWindowRole, [Node("AXSplitGroup", [Node("AXScrollArea", [view]), bar])])
        #expect(OpenRoutes.frontView(windows: [w], tree: tree)?.folders.map(\.path) == [folder.path])
    }

    @Test func aRowBeingRenamedHasNoFileButItsFolderIsKnownByWhereTheFieldIs() {
        // Finder takes the name field out of the row while its own field edits the name.
        let renaming = Node(kAXRowRole, [Node("AXCell", [Node("AXImage")]), Node("AXCell", [Node("AXStaticText")])])
        renaming.frame = CGRect(x: 0, y: 20, width: 500, height: 20)
        let other = listRow(other)
        other.frame = CGRect(x: 0, y: 0, width: 500, height: 20)
        let view = list(kAXOutlineRole, [other, renaming], selecting: [renaming], identifier: "ListView")
        #expect(read(focused: nil, in: window(view)) == nil, "the general selection stays unreadable")
        let item = OpenRoutes.renamedItem(at: CGPoint(x: 100, y: 30), windows: [window(view)], tree: tree)
        #expect(item?.url == nil && item?.folder?.path == folder.path)
        #expect(item?.alone == true)
        #expect(OpenRoutes.renamedItem(at: CGPoint(x: 100, y: 90), windows: [window(view)], tree: tree) == nil)
        view.selected = [other, renaming]
        #expect(OpenRoutes.renamedItem(at: CGPoint(x: 100, y: 30), windows: [window(view)], tree: tree)?.alone == false)
        #expect(OpenRoutes.renameRefusal(.init(url: nil, folder: folder)).refusal == nil)
        // A folder holding protected items (the home folder) can't tell which of them is being renamed.
        #expect(OpenRoutes.renameRefusal(.init(url: nil, folder: URL(fileURLWithPath: Paths.home))).refusal != nil)
        #expect(OpenRoutes.renameRefusal(.init(url: nil, folder: nil)).refusal != nil)
        #expect(OpenRoutes.renameRefusal(.init(url: URL(fileURLWithPath: Paths.home + "/.ssh"), folder: nil)).refusal != nil)
        #expect(OpenRoutes.renameRefusal(.init(url: file, folder: folder)).folders.contains(folder.path))
    }

    /// Renaming ~/notes.txt in list or column view: the row being renamed carries no file, and the home folder it is
    /// listed in holds protected items. The item checked when the rename began (Return, File ▸ Rename, a click on its
    /// name) is the one renamed, when it is the only one selected in that folder.
    @Test func anItemRenamedInTheHomeFolderIsTheOneCheckedWhenTheRenameBegan() {
        let home = URL(fileURLWithPath: Paths.home), notes = home.appendingPathComponent("notes.txt")
        let renaming = OpenRoutes.RenamedItem(url: nil, folder: home)
        let checked = OpenRoutes.renameRefusal(renaming, noted: notes)
        #expect(checked.refusal == nil)
        #expect(checked.folders.contains(home.path))
        #expect(OpenRoutes.renameRefusal(renaming).refusal != nil, "with nothing noted the folder is checked")
        // A protected item, or a folder holding one, is refused as itself.
        #expect(OpenRoutes.renameRefusal(renaming, noted: home.appendingPathComponent(".zshrc")).refusal != nil)
        #expect(OpenRoutes.renameRefusal(renaming, noted: home.appendingPathComponent("Library")).refusal != nil)
        // An item noted in another folder, or a rename with more than one item selected, says nothing about this one.
        #expect(OpenRoutes.renameRefusal(renaming, noted: URL(fileURLWithPath: "/tmp/route/notes.txt")).refusal != nil)
        #expect(OpenRoutes.renameRefusal(.init(url: nil, folder: home, alone: false), noted: notes).refusal != nil)
        // In column view the folder is the column's.
        let docker = home.appendingPathComponent(".docker")
        #expect(OpenRoutes.renameRefusal(.init(url: nil, folder: docker), noted: docker.appendingPathComponent("notes.txt")).refusal == nil)
        #expect(OpenRoutes.renameRefusal(.init(url: nil, folder: docker), noted: docker.appendingPathComponent("config.json")).refusal != nil)
    }

    @Test func aNotedItemCountsOnlyWhileItIsWhereItWasNoted() throws {
        // The real path: Finder's URLs name /private/var, not the /var link.
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("finder-note-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: a)
        let pid: pid_t = 424_242
        OpenRoutes.noteFinderSelection([a], pid: pid)
        #expect(OpenRoutes.notedFinderItem(pid: pid) == a)
        #expect(OpenRoutes.notedFinderItem(pid: pid + 1) == nil)
        try FileManager.default.moveItem(at: a, to: b)
        #expect(OpenRoutes.notedFinderItem(pid: pid) == nil, "renamed since")
        OpenRoutes.noteFinderSelection([b], pid: pid)
        #expect(OpenRoutes.notedFinderItem(pid: pid) == b)
        OpenRoutes.noteFinderSelection([a, b], pid: pid)
        #expect(OpenRoutes.notedFinderItem(pid: pid) == nil, "more than one item")
        OpenRoutes.noteFinderSelection([b], pid: pid)
        OpenRoutes.noteFinderSelection(nil, pid: pid)
        #expect(OpenRoutes.notedFinderItem(pid: pid) == nil, "an unreadable selection clears it")
    }

    @Test func aHitIsOnTheItemWhoseRowOrIconHoldsIt() {
        let row = listRow(file)
        let view = list(kAXOutlineRole, [row], selecting: [], identifier: "ListView")
        let finder = app(window(view))
        // A list view row's date column holds no URL; the row's name field does.
        #expect(OpenRoutes.finderHit(row.children[1].children[0], tree: tree) == .item(file))
        #expect(OpenRoutes.finderHit(row.children[0].children[1], tree: tree) == .item(file))
        #expect(OpenRoutes.finderHit(view, tree: tree) == .background)
        // A sidebar place stands for no file that can be read.
        let place = sidebarRow()
        let sidebar = list(kAXOutlineRole, [place], selecting: [])
        #expect(OpenRoutes.finderHit(place.children[0].children[1], tree: tree) == .unreadable)
        // The desktop's icons are images carrying their URL, in a group holding the selection.
        let icon = Node("AXImage", url: file)
        let desktop = Node(kAXGroupRole, [icon])
        desktop.selected = []
        let screen = app(Node(kAXScrollAreaRole, [desktop]))
        #expect(OpenRoutes.finderHit(icon, tree: tree) == .item(file))
        #expect(OpenRoutes.finderHit(desktop, tree: tree) == .background)
        #expect(OpenRoutes.finderView(around: icon, tree: tree)?.folders.map(\.path) == [folder.path])
        withExtendedLifetime((finder, sidebar, screen)) {}
    }

    @Test func aDropLandsInTheFolderUnderItOrTheWindowsFolder() throws {
        // Off a row's icon and name, Finder drops into the window's folder: both count.
        let sub = URL(fileURLWithPath: "/tmp/route/sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let folderRow = listRow(sub), fileRow = listRow(file)
        let view = list(kAXOutlineRole, [folderRow, fileRow], selecting: [], identifier: "ListView")
        let finder = app(window(view))
        #expect(OpenRoutes.dropFolders(folderRow.children[1], tree: tree)?.map(\.path) == [sub.path, folder.path])
        #expect(OpenRoutes.dropFolders(fileRow.children[1], tree: tree)?.map(\.path) == [folder.path])
        #expect(OpenRoutes.dropFolders(view, tree: tree)?.map(\.path) == [folder.path])
        let place = sidebarRow()
        let sidebar = list(kAXOutlineRole, [place], selecting: [])
        #expect(OpenRoutes.dropFolders(place.children[0], tree: tree) == nil)
        // An empty window says nothing about its folder.
        let empty = list(kAXOutlineRole, [], selecting: [], identifier: "ListView")
        let other = app(window(empty))
        #expect(OpenRoutes.dropFolders(empty, tree: tree) == nil)
        withExtendedLifetime((finder, sidebar, other)) {}
    }

    @Test func aDragCarriesTheSelectionWhenItStartsOnASelectedItem() {
        let a = listRow(file), b = listRow(other), c = listRow(URL(fileURLWithPath: "/tmp/route/three.txt"))
        let view = list(kAXOutlineRole, [a, b, c], selecting: [a, b], identifier: "ListView")
        let finder = app(window(view))
        #expect(OpenRoutes.draggedFiles(b.children[2], tree: tree) == [file, other])
        #expect(OpenRoutes.draggedFiles(c.children[2], tree: tree) == [URL(fileURLWithPath: "/tmp/route/three.txt")])
        view.selected = nil
        #expect(OpenRoutes.draggedFiles(a.children[1], tree: tree) == nil)
        withExtendedLifetime(finder) {}
    }

    // MARK: Reads that fail

    /// An outline answers an empty AXSelectedChildren while AXSelectedRows fails: the selection is unknown, not empty,
    /// so a protected item selected there isn't passed as nothing selected (⌘⌫).
    @Test func aSelectionThatFailsToReadIsUnknownNotEmpty() throws {
        typealias AX = SelectionTree<AXElement>
        let failedRows = AXElement.Read(values: [kAXSelectedChildrenAttribute: [Any]()], errors: [kAXSelectedRowsAttribute: .failure])
        #expect(AX.selection(from: failedRows).items == nil)
        #expect(AX.selection(from: AXElement.Read(values: [:], errors: [kAXSelectedChildrenAttribute: .cannotComplete])).items == nil)
        #expect(AX.selection(from: nil).items == nil)
        // Attributes the element doesn't have are absent, not failed: no selection; an empty one read is empty.
        #expect(AX.selection(from: AXElement.Read(values: [:])).isNone)
        #expect(AX.selection(from: AXElement.Read(values: [kAXSelectedRowsAttribute: [Any]()])).items?.isEmpty == true)
        #expect(AX.selection(from: AXElement.Read(values: [kAXSelectedRowsAttribute: ["not an element"]])).items == nil)

        let key = URL(fileURLWithPath: Paths.home + "/.ssh/id_ed25519")
        let rows = [listRow(key)]
        let view = list(kAXOutlineRole, rows, selecting: rows, identifier: "ListView")
        view.failing = ["selection"]
        #expect(read(focused: view, in: window(view)) == nil)
        #expect(read(focused: rows[0].children[0].children[1], in: window(view)) == nil)
        #expect(read(focused: nil, in: window(view)) == nil)
        #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse("cmd+delete"), selection: nil, policy: Policy()) != nil)
        // A group whose selection can't be read (the desktop's) counts as a file list whose selection is unknown.
        let icon = Node("AXImage", url: key), desktop = Node(kAXGroupRole, [icon])
        desktop.failing = ["selection"]
        #expect(OpenRoutes.frontView(windows: [Node(kAXScrollAreaRole, [desktop])], tree: tree)?.selection == nil)
    }

    /// An element whose role or children can't be read could be, or hold, a file list: the window's selection is then
    /// unknown rather than the selection of the lists that could be read.
    @Test func aFailedReadThatCouldHideAFileListLeavesTheSelectionUnknown() {
        let row = listRow(file)
        let view = list(kAXOutlineRole, [row], selecting: [row], identifier: "ListView")
        let other = Node("AXSplitGroup", [Node("AXScrollArea")])
        let w = Node(kAXWindowRole, [Node("AXScrollArea", [view]), other])
        #expect(read(focused: nil, in: w) == [file])
        for failure in ["children", "role"] {
            other.failing = [failure]
            #expect(read(focused: nil, in: w) == nil, "\(failure)")
            #expect(OpenRoutes.frontView(windows: [w], tree: tree)?.selection == nil, "\(failure)")
        }
        other.failing = []
        view.failing = ["children"]
        #expect(read(focused: nil, in: w) == nil, "the list's items")
        let browser = Node(kAXBrowserRole, [Node("AXScrollArea", [list(kAXListRole, [columnItem(file)], selecting: [])])])
        browser.failing = ["children"]
        #expect(read(focused: nil, in: window(browser)) == nil, "a column view's columns")
    }

    // MARK: Pasting in column view

    /// Column view shows every folder from the window's root down: a paste lands in the column holding focus (or the
    /// folder selected there), so ~/.docker shown as a column doesn't refuse an ordinary paste into ~/.docker/scratch.
    @Test func aPasteInColumnViewLandsInTheFocusedColumnsFolder() throws {
        let home = URL(fileURLWithPath: Paths.home)
        let docker = home.appendingPathComponent(".docker"), scratch = docker.appendingPathComponent("scratch")
        let inHome = columnItem(docker), inDocker = columnItem(scratch), inScratch = columnItem(scratch.appendingPathComponent("a.txt"))
        let homeColumn = list(kAXListRole, [inHome], selecting: [inHome])
        let dockerColumn = list(kAXListRole, [inDocker], selecting: [inDocker])
        let scratchColumn = list(kAXListRole, [inScratch], selecting: [])
        let w = window(Node(kAXBrowserRole, [homeColumn, dockerColumn, scratchColumn].map { Node("AXScrollArea", [$0]) }))
        let config = URL(fileURLWithPath: "/tmp/route/config.json")

        let view = try #require(OpenRoutes.frontView(windows: [w], focused: scratchColumn, tree: tree))
        #expect(view.folders.map(\.path) == [home.path, docker.path, scratch.path])
        #expect(view.pasteFolders.map(\.path) == [scratch.path])
        #expect(OpenRoutes.transferRefusal([config], into: view.pasteFolders) == nil)
        #expect(OpenRoutes.frontView(windows: [w], focused: inScratch.children[1], tree: tree)?.pasteFolders.map(\.path) == [scratch.path])
        // Focus in ~/.docker's column: the paste may land there.
        let inDockerColumn = try #require(OpenRoutes.frontView(windows: [w], focused: dockerColumn, tree: tree))
        #expect(inDockerColumn.pasteFolders.first?.path == docker.path)
        #expect(OpenRoutes.transferRefusal([config], into: inDockerColumn.pasteFolders) != nil)
        // Focus outside the columns, or a column whose selection can't be read: every column counts.
        let unknown = try #require(OpenRoutes.frontView(windows: [w], tree: tree))
        #expect(unknown.pasteFolders == unknown.folders)
        #expect(OpenRoutes.transferRefusal([config], into: unknown.pasteFolders) != nil)
        scratchColumn.selected = nil
        #expect(OpenRoutes.frontView(windows: [w], focused: scratchColumn, tree: tree)?.pasteFolders.contains(docker) == true)
        // Other views paste into the window's folder, as before.
        let rows = [listRow(scratch.appendingPathComponent("a.txt"))]
        let listView = list(kAXOutlineRole, rows, selecting: [], identifier: "ListView")
        #expect(OpenRoutes.frontView(windows: [window(listView)], focused: listView, tree: tree)?.pasteFolders.map(\.path) == [scratch.path])
    }

    @Test func aCopyOrMoveIsRefusedIntoOrOntoProtectedLocations() {
        let home = URL(fileURLWithPath: Paths.home)
        #expect(OpenRoutes.transferRefusal([file], into: [folder]) == nil)
        #expect(OpenRoutes.transferRefusal([file], into: [home.appendingPathComponent(".ssh")]) != nil)
        #expect(OpenRoutes.transferRefusal([file], into: [home.appendingPathComponent("Library/LaunchAgents")]) != nil)
        #expect(OpenRoutes.transferRefusal([URL(fileURLWithPath: "/tmp/route/.zshrc")], into: [home]) != nil)
        #expect(OpenRoutes.transferRefusal([URL(fileURLWithPath: "/tmp/route/.zshrc")], into: [folder]) == nil)
        #expect(OpenRoutes.transferRefusal([home.appendingPathComponent(".ssh/id_ed25519")], into: [folder]) != nil)
        // The home folder holds protected items, so a copy of it would too.
        #expect(OpenRoutes.transferRefusal([home], into: [folder]) != nil)
        // Any of the folders a paste could land in counts.
        #expect(OpenRoutes.transferRefusal([file], into: [folder, home.appendingPathComponent(".aws")]) != nil)
    }
}

@Suite struct FinderURLTests {
    /// Finder's file reference URLs name their file's path; one that no longer resolves names nothing, rather than an
    /// empty path that would be taken as the home folder.
    @Test func aReferenceURLThatNoLongerResolvesNamesNoFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("route-ref-" + UUID().uuidString)
        try Data("x".utf8).write(to: file)
        let reference = try #require((file as NSURL).fileReferenceURL())
        #expect(OpenRoutes.resolved(reference)?.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: file)
        // As accessibility hands it over: a reference string, with nothing behind its file ID any more.
        #expect(OpenRoutes.resolved(try #require(URL(string: "file:///.file/id=1.999999999999/"))) == nil)
        #expect(OpenRoutes.resolved(URL(string: "https://example.com")!) == URL(string: "https://example.com"))
    }
}
