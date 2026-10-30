import ApplicationServices
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

/// What committing a file panel checks, on fake trees shaped like the Go to Folder sheet and the Open and Save panels.
@Suite struct PanelCommitTests {
    final class Node {
        var role: String
        var subrole: String?
        var identifier: String?
        /// nil: the value can't be read.
        var value: String?
        var children: [Node]
        var selected: [Node] = []
        var url: URL?
        /// Reads that fail: `role`, `children`, `selected`, `url`, `identifier`.
        var failing: Set<String> = []
        init(_ role: String, id: String? = nil, value: String? = "", url: URL? = nil, _ children: [Node] = []) {
            self.role = role
            identifier = id
            self.value = value
            self.url = url
            self.children = children
        }

        @discardableResult func fail(_ reads: String...) -> Node {
            failing.formUnion(reads)
            return self
        }
    }

    private let home = Paths.home

    private func reader(folders: [String] = []) -> PanelReader<Node> {
        PanelReader(
            element: { n in
                n.failing.contains("role") ? nil
                    : PanelElement(role: n.role, subrole: n.subrole, identifier: n.identifier, url: n.url,
                                   unresolved: !n.failing.isDisjoint(with: ["url", "identifier"]))
            },
            value: { $0.value },
            children: { $0.failing.contains("children") ? nil : $0.children },
            selected: { $0.failing.contains("selected") ? nil : $0.selected },
            typing: { text, _ in OpenRoutes.typingRefusal(text, bases: folders, names: true, scan: { [] }) },
            tile: { OpenRoutes.tileRefusal($0, policy: Policy()) })
    }

    /// A completion row as AppKit shows it: its path list (`AXList desc="path"`) carries the path as its identifier
    /// and no file URL, unless `url` says so.
    private func completion(_ path: String?, url: URL? = nil) -> Node {
        Node("AXRow", [Node("AXCell", [Node("AXList", id: path, url: url, [Node("AXStaticText", value: "Users")])])])
    }

    /// A row with nothing to check: no file URL and no path.
    private func blankRow() -> Node { Node("AXRow", [Node("AXCell", [Node("AXList", [Node("AXStaticText")])])]) }

    /// The Go to Folder sheet: the typed path, and a completion table whose first row (or `selected`) is selected.
    private func goToFolder(typed: String?, rows: [Node], selecting selected: [Node]? = nil) -> Node {
        let header = Node("AXRow", [Node("AXCell", [Node("AXStaticText", value: "Go to:")])])
        let table = Node("AXTable", [header] + rows)
        table.selected = selected ?? rows.prefix(1).map { $0 }
        return Node("AXSheet", id: "GoToWindow", [
            Node("AXStaticText", value: typed ?? ""), Node("AXButton", id: "CloseButton"),
            Node(kAXTextFieldRole, id: "PathTextField", value: typed), Node("AXScrollArea", [table]),
        ])
    }

    private func table(of sheet: Node) -> Node { sheet.children[3].children[0] }

    private func refusal(_ root: Node, folders: [String] = []) -> String? {
        RouteGuards.panelRefusal(root, reader: reader(folders: folders))
    }

    // MARK: Go to Folder

    @Test func aTypedPathWithoutACompletionOrWithItsOwnCompletionPasses() {
        #expect(refusal(goToFolder(typed: "/tmp/agent-test-g2", rows: [])) == nil)
        #expect(refusal(goToFolder(typed: "~/Desktop/agent-test-g2", rows: [])) == nil)
        // The completion selected for a complete path stands for that path.
        #expect(refusal(goToFolder(typed: "/tmp/agent-test-g2", rows: [completion("/tmp/agent-test-g2")])) == nil)
        #expect(refusal(goToFolder(typed: "~/Desktop/agent-test-g2", rows: [completion(home + "/Desktop/agent-test-g2")])) == nil)
        // Completions shown but none selected: the typed path is what Return commits.
        #expect(refusal(goToFolder(typed: "/tmp/agent-test-g2", rows: [completion("/tmp/agent-test-g2")], selecting: [])) == nil)
    }

    @Test func aCompletionRowCarryingASafePathOrURLPasses() {
        #expect(refusal(goToFolder(typed: "~/Desktop/a", rows: [completion("/Users/someone/Desktop/agent-test-g2")])) == nil)
        let url = URL(fileURLWithPath: "/tmp/agent-test-g2")
        #expect(refusal(goToFolder(typed: "/tmp/a", rows: [completion(nil, url: url)])) == nil)
    }

    @Test func aSelectedCompletionWhosePathCantBeResolvedIsRefusedWhateverIsTyped() throws {
        // "~/.ss" may complete to the SSH folder: the typed prefix being safe says nothing about the completion.
        let message = try #require(refusal(goToFolder(typed: "~/.ss", rows: [blankRow()])))
        #expect(message.contains("selection can't be checked"))
        #expect(refusal(goToFolder(typed: "/tmp/agent-test-g2", rows: [blankRow()])) != nil)
        // A path list whose identifier or URL fails to read, or whose subtree can't be read.
        for row in [completion(home + "/.ssh"), completion(nil, url: URL(fileURLWithPath: home + "/.ssh"))] {
            row.children[0].children[0].fail("identifier", "url")
            #expect(refusal(goToFolder(typed: "~/.ss", rows: [row]))?.contains("selection can't be checked") == true)
        }
        let hidden = completion(home + "/.ssh")
        hidden.children[0].fail("children")
        #expect(refusal(goToFolder(typed: "~/.ss", rows: [hidden]))?.contains("selection can't be checked") == true)
    }

    @Test func aCompletionTableWhoseSelectionCantBeReadIsRefused() throws {
        let sheet = goToFolder(typed: "~/.ss", rows: [completion(home + "/.ssh")], selecting: [])
        table(of: sheet).fail("selected")
        let message = try #require(refusal(sheet))
        #expect(message.contains("selection can't be checked"))
    }

    @Test func aCompletionRowCarryingAProtectedPathIsRefusedWhateverIsTyped() throws {
        // "~/.ss" completes to the SSH folder: Return would go there although the field itself isn't protected.
        let row = completion(home + "/.ssh")
        let message = try #require(refusal(goToFolder(typed: "~/.ss", rows: [row])))
        #expect(message.contains("protected"))
        #expect(refusal(goToFolder(typed: "~/Library/LaunchA", rows: [completion(home + "/Library/LaunchAgents")])) != nil)
    }

    @Test func aCompletionRowCarryingAProtectedFileURLIsRefused() {
        let row = completion(nil, url: URL(fileURLWithPath: home + "/.ssh"))
        #expect(refusal(goToFolder(typed: "~/.ss", rows: [row])) != nil)
        // A launcher the completion names is refused as an opened file would be.
        #expect(refusal(goToFolder(typed: "/tmp/x", rows: [completion(nil, url: URL(fileURLWithPath: "/tmp/payload.command"))])) != nil)
    }

    @Test func aProtectedTypedPathIsRefusedWithOrWithoutACompletion() {
        for typed in ["~/.ssh", home + "/Library/LaunchAgents", "~/.config/mac-mcp"] {
            #expect(refusal(goToFolder(typed: typed, rows: [])) != nil, "\(typed)")
            #expect(refusal(goToFolder(typed: typed, rows: [blankRow()])) != nil, "\(typed)")
            #expect(refusal(goToFolder(typed: typed, rows: [completion("/tmp/agent-test-g2")])) != nil, "\(typed)")
        }
    }

    @Test func anUnreadableTypedPathIsRefusedEvenWithASafeCompletion() throws {
        let message = try #require(refusal(goToFolder(typed: nil, rows: [completion("/tmp/agent-test-g2")])))
        #expect(message.contains("can't be checked"))
    }

    @Test func aSelectedRowWithoutAFileURLElsewhereInTheSheetIsRefused() {
        // A selected row without a file URL in a column view's list, or in a list that isn't a table, refuses.
        let item = Node("AXRow", [Node("AXCell", [Node("AXStaticText")])])
        let list = Node("AXList", [item])
        list.selected = [item]
        let browser = Node("AXBrowser", [Node("AXTable", [item])])
        browser.children[0].selected = [item]
        for extra in [browser, list] {
            let sheet = goToFolder(typed: "/tmp/ok", rows: [])
            sheet.children.append(extra)
            #expect(refusal(sheet)?.contains("selection can't be checked") == true)
        }
        // A protected file selected beside it refuses as well.
        let protected = Node("AXRow", [Node("AXTextField", value: "ssh", url: URL(fileURLWithPath: home + "/.ssh"))])
        let sheet = goToFolder(typed: "/tmp/ok", rows: [protected])
        #expect(refusal(sheet) != nil)
    }

    // MARK: Open panel

    /// An Open panel showing `/tmp/agent-test-g2`: the sidebar, a column view whose list selects `selecting`, and a
    /// list view (an outline) whose rows hold a name field in their first cell.
    private func openPanel(selecting: Node? = nil, listView: Node? = nil) -> Node {
        let file = Node("AXRow", [Node("AXTextField", value: "note.txt", url: URL(fileURLWithPath: "/tmp/agent-test-g2/note.txt"))])
        let list = Node("AXList", [file])
        if let selecting { list.selected = [selecting] }
        let sidebar = Node("AXOutline", id: "sidebar", [Node("AXRow", [Node("AXCell", [Node("AXStaticText", value: "Desktop")])])])
        sidebar.selected = sidebar.children
        var views = [sidebar, Node("AXBrowser", id: "ColumnView", [list])]
        if let listView { views.append(listView) }
        return Node("AXSheet", id: "open-panel", [
            Node("AXSplitGroup", views), Node("AXButton", id: "OKButton"), Node("AXButton", id: "CancelButton"),
        ])
    }

    /// A list view's row: a name field carrying the file's URL in its first cell, its kind as text in another.
    private func listViewRow(_ path: String) -> Node {
        Node("AXRow", [
            Node("AXCell", [Node("AXTextField", value: (path as NSString).lastPathComponent, url: URL(fileURLWithPath: path))]),
            Node("AXCell", [Node("AXStaticText", value: "Folder")]),
        ])
    }

    @Test func theOpenPanelOpensAnOrdinaryFile() {
        let file = Node("AXRow", [Node("AXTextField", value: "note.txt", url: URL(fileURLWithPath: "/tmp/agent-test-g2/note.txt"))])
        #expect(refusal(openPanel(selecting: file)) == nil)
        let outline = Node("AXOutline", [listViewRow("/tmp/agent-test-g2/note.txt")])
        outline.selected = outline.children
        #expect(refusal(openPanel(listView: outline)) == nil)
    }

    @Test func aProtectedFileSelectedInAListWhoseSelectionCantBeReadIsRefused() throws {
        // Selected by keyboard navigation: the selection is there, only its read failed.
        let key = Node("AXRow", [Node("AXTextField", value: "id_rsa", url: URL(fileURLWithPath: home + "/.ssh/id_rsa"))])
        let panel = openPanel(selecting: key)
        panel.children[0].children[1].children[0].fail("selected")
        let message = try #require(refusal(panel))
        #expect(message.contains("selection can't be checked"))
        // The same for a list view's outline and the column view itself.
        let outline = Node("AXOutline", [listViewRow(home + "/.ssh")]).fail("selected")
        outline.selected = outline.children
        #expect(refusal(openPanel(listView: outline))?.contains("selection can't be checked") == true)
        let browser = openPanel()
        browser.children[0].children[1].fail("selected")
        #expect(refusal(browser)?.contains("selection can't be checked") == true)
    }

    @Test func aListViewRowWhoseNameCellCantBeReadIsNotTakenForASidebarPlace() {
        // With the name field's cell unread, only the kind's text would be left, as in a sidebar row.
        let row = listViewRow(home + "/.ssh")
        row.children[0].fail("children")
        let outline = Node("AXOutline", [row])
        outline.selected = [row]
        #expect(refusal(openPanel(listView: outline))?.contains("selection can't be checked") == true)
        // Or its URL, or a cell's role.
        let unreadURL = listViewRow(home + "/.ssh")
        unreadURL.children[0].children[0].fail("url")
        let unreadRole = listViewRow(home + "/.ssh")
        unreadRole.children[0].children[0].fail("role")
        for row in [unreadURL, unreadRole] {
            let outline = Node("AXOutline", [row])
            outline.selected = [row]
            #expect(refusal(openPanel(listView: outline))?.contains("selection can't be checked") == true)
        }
    }

    @Test func aPanelWhoseTreeCantBeReadIsRefused() throws {
        // A sheet that can't be read is treated as a panel (`FilePanelScan.qualifies`), and isn't let through either.
        let message = try #require(refusal(openPanel().fail("children")))
        #expect(message.contains("can't be checked completely"))
        #expect(refusal(openPanel().fail("role"))?.contains("can't be checked completely") == true)
        // A group that may hold the name field, or the column view holding the lists.
        let group = savePanel(name: "note.txt")
        group.children[0].fail("children")
        #expect(refusal(group, folders: ["/tmp/agent-test-g2"])?.contains("can't be checked completely") == true)
        let browser = openPanel()
        browser.children[0].children[1].fail("children")
        #expect(refusal(browser)?.contains("can't be checked completely") == true)
        let unknown = openPanel()
        unknown.children[1].fail("role")
        #expect(refusal(unknown)?.contains("can't be checked completely") == true)
    }

    // MARK: Save panel after Go to Folder

    /// The expanded Save panel after Go to Folder: the name field, the sidebar and the column view's folder.
    private func savePanel(name: String?, selecting: Node? = nil) -> Node {
        let folder = Node("AXTextField", value: "agent-test-g2", url: URL(fileURLWithPath: "/tmp/agent-test-g2"))
        let list = Node("AXList", [Node("AXRow", [folder])])
        if let selecting { list.selected = [selecting] }
        let sidebar = Node("AXOutline", id: "sidebar", [Node("AXRow", [Node("AXCell", [Node("AXStaticText", value: "Desktop")])])])
        sidebar.selected = sidebar.children
        return Node("AXSheet", id: "save-panel", [
            Node("AXSplitGroup", [sidebar, Node("AXBrowser", id: "ColumnView", [list])]),
            Node("AXPopUpButton", id: "where popup"),
            Node(kAXTextFieldRole, id: "saveAsNameTextField", value: name),
            Node(kAXTextFieldRole, value: ""),
        ])
    }

    @Test func theSavePanelCommitsAnOrdinaryNameInAnOrdinaryFolder() {
        #expect(refusal(savePanel(name: "note.txt"), folders: ["/tmp/agent-test-g2"]) == nil)
        // Rows that aren't selected aren't read: one that would fail to doesn't matter.
        let panel = savePanel(name: "note.txt")
        panel.children[0].children[1].children[0].children[0].fail("url")
        #expect(refusal(panel, folders: ["/tmp/agent-test-g2"]) == nil)
    }

    @Test func theSavePanelStillRefusesALauncherNameOrAnUnreadableName() throws {
        let launcher = try #require(refusal(savePanel(name: "payload.command"), folders: ["/tmp/agent-test-g2"]))
        #expect(launcher.contains("would run"))
        #expect(refusal(savePanel(name: "Tool.app"), folders: ["/tmp/agent-test-g2"]) != nil)
        #expect(refusal(savePanel(name: nil), folders: ["/tmp/agent-test-g2"])?.contains("file name can't be checked") == true)
    }

    @Test func theSavePanelStillRefusesAProtectedDestination() {
        // The folder shown is protected: the name is checked against it, or is a protected path itself.
        #expect(refusal(savePanel(name: "authorized_keys"), folders: ["/tmp/x"]) != nil)
        #expect(refusal(savePanel(name: "config"), folders: [home + "/.ssh"]) != nil)
        #expect(refusal(savePanel(name: "~/.ssh/config"), folders: ["/tmp/x"]) != nil)
        #expect(refusal(savePanel(name: "evil.plist"), folders: [home + "/Library/LaunchAgents"]) != nil)
    }

    @Test func aSelectedFileInTheSavePanelsListIsStillChecked() {
        let protectedRow = Node("AXRow", [Node("AXTextField", value: "id_rsa", url: URL(fileURLWithPath: home + "/.ssh/id_rsa"))])
        #expect(refusal(savePanel(name: "note.txt", selecting: protectedRow), folders: ["/tmp/x"]) != nil)
        let unreadable = Node("AXRow", [Node("AXCell", [Node("AXStaticText")])])
        #expect(refusal(savePanel(name: "note.txt", selecting: unreadable), folders: ["/tmp/x"])?.contains("selection can't be checked") == true)
    }
}
