import ApplicationServices
import Foundation
import Testing
@testable import MacMCPCore

/// File panel detection on fake trees shaped like what the real panels, and the dialogs mistaken for them, report.
@Suite struct FilePanelTests {
    final class Node {
        var probe: FilePanelScan.Probe
        var children: [Node]?
        init(_ role: String, id: String = "", fileURL: Bool = false, remote: Bool = false, _ children: [Node]? = []) {
            probe = FilePanelScan.Probe(role: role, identifier: id, fileURL: fileURL, remote: remote)
            self.children = children
        }
    }

    final class Walk {
        var visited = 0
        func verdict(_ root: Node, unreadable: Set<ObjectIdentifier> = []) -> FilePanelScan.Verdict {
            FilePanelScan.verdict(root, probe: { [self] n in
                visited += 1
                return unreadable.contains(ObjectIdentifier(n)) ? nil : n.probe
            }, children: { $0.children })
        }
    }

    private func verdict(_ root: Node) -> FilePanelScan.Verdict { Walk().verdict(root) }

    private func rows(_ count: Int, fileURL: Bool = false) -> [Node] {
        (0..<count).map { _ in Node("AXRow", [Node("AXCell", [Node("AXTextField", fileURL: fileURL, [])])]) }
    }

    // MARK: Panels

    @Test func theSavePanelSheetIsRecognizedByEachOfItsSigns() {
        // The sheet itself.
        #expect(verdict(Node("AXSheet", id: "save-panel", [Node("AXGroup")])) == .panel)
        // The out-of-process service owning an element in an otherwise plain tree.
        #expect(verdict(Node("AXSheet", [Node("AXSplitGroup", [Node("AXSplitter", remote: true)]), Node("AXButton")])) == .panel)
        // The column view.
        #expect(verdict(Node("AXSheet", [Node("AXSplitGroup", [Node("AXBrowser", id: "other")])])) == .panel)
        // The name field, the sidebar's headers, the Go to Folder field.
        #expect(verdict(Node("AXSheet", [Node("AXTextField", id: "saveAsNameTextField")])) == .panel)
        #expect(verdict(Node("AXSheet", [Node("AXScrollArea", [Node("AXOutline", [
            Node("AXRow", [Node("AXCell", [Node("AXStaticText")])]),
            Node("AXRow", [Node("AXCell", [Node("AXStaticText", id: "xSidebarHeader")])]),
        ])])])) == .panel)
        #expect(verdict(Node("AXSheet", id: "GoToWindow", [Node("AXTextField", id: "PathTextField")])) == .panel)
        #expect(verdict(Node("AXSheet", [Node("AXTextField", id: "PathTextField")])) == .panel)
    }

    @Test func theCollapsedSavePanelHasNoBrowserAndStillShowsItsNameFieldAndTheService() {
        let collapsed = Node("AXSheet", [Node("AXSplitGroup", [
            Node("AXSplitter", remote: true), Node("AXPopUpButton", id: "where popup"),
            Node("AXTextField", id: "saveAsNameTextField"), Node("AXButton", id: "OKButton"),
        ])])
        #expect(verdict(collapsed) == .panel)
        let noService = Node("AXSheet", [Node("AXSplitGroup", [
            Node("AXPopUpButton", id: "where popup"), Node("AXTextField", id: "saveAsNameTextField"),
        ])])
        #expect(verdict(noService) == .panel)
    }

    @Test func aListViewOfFilesIsRecognizedByItsRowsFileURLs() {
        let list = Node("AXWindow", [Node("AXScrollArea", [Node("AXOutline", rows(40, fileURL: true))])])
        #expect(verdict(list) == .panel)
        let table = Node("AXSheet", [Node("AXTable", rows(3, fileURL: true))])
        #expect(verdict(table) == .panel)
    }

    @Test func aFileURLOutsideAListIsNotEvidence() {
        #expect(verdict(Node("AXSheet", [Node("AXTextField", fileURL: true), Node("AXButton")])) == .notPanel)
    }

    // MARK: Ordinary dialogs

    @Test func ordinaryDialogsAndFloatingPanelsAreNotFilePanels() {
        let rename = Node("AXSheet", [Node("AXStaticText"), Node("AXTextField", id: "newName"), Node("AXButton", id: "OKButton"), Node("AXButton")])
        #expect(verdict(rename) == .notPanel)
        let login = Node("AXSheet", [Node("AXTextField"), Node("AXTextField"), Node("AXButton"), Node("AXCheckBox")])
        #expect(verdict(login) == .notPanel)
        let find = Node("AXWindow", [Node("AXTextField"), Node("AXTextField"), Node("AXButton"), Node("AXButton")])
        #expect(verdict(find) == .notPanel)
    }

    @Test func aFontsPanelWithThousandsOfRowsIsNotAPanelAndIsReadFromAFewRows() {
        let fonts = Node("AXWindow", [
            Node("AXSplitGroup", [
                Node("AXScrollArea", [Node("AXOutline", rows(1_500)), Node("AXScrollBar")]),
                Node("AXScrollArea", [Node("AXTable", rows(1_500)), Node("AXScrollBar")]),
            ]),
            Node("AXToolbar", [Node("AXMenuButton", id: "font_collections_picker"),
                               Node("AXComboBox", id: "font_size_picker", [Node("AXButton", id: "font_size_picker")])]),
        ])
        let walk = Walk()
        #expect(walk.verdict(fonts) == .notPanel)
        #expect(walk.visited < 100, "visited \(walk.visited)")
    }

    // MARK: Unreadable

    @Test func whatCantBeReadIsUnreadableUnlessEvidenceCameFirst() {
        let walk = Walk()
        let broken = Node("AXTextField")
        let sheet = Node("AXSheet", [broken, Node("AXButton")])
        #expect(walk.verdict(sheet, unreadable: [ObjectIdentifier(broken)]) == .unreadable)
        #expect(Walk().verdict(sheet, unreadable: [ObjectIdentifier(sheet)]) == .unreadable)
        #expect(verdict(Node("AXSheet", nil)) == .unreadable)
        #expect(verdict(Node("AXSheet", [])) == .unreadable)
        let withEvidence = Node("AXSheet", [broken, Node("AXBrowser")])
        #expect(Walk().verdict(withEvidence, unreadable: [ObjectIdentifier(broken)]) == .panel)
    }

    @Test func aWalkThatHitsItsBoundWithoutEvidenceIsUnreadable() {
        let wide = Node("AXSheet", (0..<(FilePanelScan.visitLimit + 50)).map { _ in Node("AXButton") })
        #expect(verdict(wide) == .unreadable)
        let late = Node("AXSheet", (0..<(FilePanelScan.visitLimit - 10)).map { _ in Node("AXButton") } + [Node("AXBrowser")])
        #expect(verdict(late) == .panel)
    }

    // MARK: Decision

    @Test func unreadableSheetsAndDialogsFailClosedButFloatingPanelsAndPopoversDoNot() {
        typealias K = FilePanelScan.Kind
        for kind in [K.sheet, .dialog] { #expect(FilePanelScan.qualifies(kind, .unreadable, inDocumentWindow: false), "\(kind)") }
        for kind in [K.floating, .popover, .window] { #expect(!FilePanelScan.qualifies(kind, .unreadable, inDocumentWindow: false), "\(kind)") }
        for kind in [K.sheet, .dialog, .floating, .popover, .window] {
            #expect(FilePanelScan.qualifies(kind, .panel, inDocumentWindow: false), "\(kind)")
            #expect(!FilePanelScan.qualifies(kind, .notPanel, inDocumentWindow: false), "\(kind)")
        }
        // The popover that renames a document's file, in the document's window.
        #expect(FilePanelScan.qualifies(.popover, .notPanel, inDocumentWindow: true))
        #expect(!FilePanelScan.qualifies(.sheet, .notPanel, inDocumentWindow: true))
        #expect(!FilePanelScan.qualifies(.floating, .notPanel, inDocumentWindow: true))
    }

    @Test func containerKindsComeFromRoleSubroleAndIdentifier() {
        typealias K = FilePanelScan.Kind
        #expect(K(role: "AXSheet", subrole: "", identifier: "") == .sheet)
        #expect(K(role: "AXPopover", subrole: "", identifier: "") == .popover)
        #expect(K(role: "AXWindow", subrole: "AXDialog", identifier: "") == .dialog)
        #expect(K(role: "AXWindow", subrole: "AXSystemDialog", identifier: "") == .dialog)
        #expect(K(role: "AXWindow", subrole: "AXFloatingWindow", identifier: "") == .floating)
        #expect(K(role: "AXWindow", subrole: "AXSystemFloatingWindow", identifier: "") == .floating)
        // A modal Open panel is an ordinary window by subrole; the identifier says what it is.
        #expect(K(role: "AXWindow", subrole: "AXStandardWindow", identifier: "open-panel") == .window)
        #expect(K(role: "AXWindow", subrole: "AXStandardWindow", identifier: "save-panel") == .window)
        #expect(K(role: "AXWindow", subrole: "AXStandardWindow", identifier: "_NS:31") == nil)
        #expect(K(role: "AXGroup", subrole: "AXDialog", identifier: "save-panel") == nil)
    }

    // MARK: Cache

    @Test func aPanelVerdictLastsWhileThePanelDoesAndANotPanelVerdictOnlyBriefly() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        nonisolated(unsafe) var alive: Set<String> = ["sheet", "other"]
        let cache = FilePanelCache<String>(notPanelLifetime: 2, capacity: 4, isAlive: { alive.contains($0) })
        cache.store("sheet", panel: true, now: start)
        cache.store("dialog", panel: false, now: start)
        #expect(cache.lookup("sheet", now: start.addingTimeInterval(3_600)) == true)
        #expect(cache.lookup("dialog", now: start.addingTimeInterval(1)) == false)
        #expect(cache.lookup("dialog", now: start.addingTimeInterval(2.5)) == nil)
        #expect(cache.lookup("unknown", now: start) == nil)
        alive.remove("sheet")
        #expect(cache.lookup("sheet", now: start.addingTimeInterval(4)) == nil)
    }

    @Test func theCacheIsBoundedAndForgetsClosedPanelsOnStore() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        nonisolated(unsafe) var alive: Set<String> = ["a", "b", "c", "d", "e"]
        let cache = FilePanelCache<String>(notPanelLifetime: 2, capacity: 3, isAlive: { alive.contains($0) })
        for (i, key) in ["a", "b", "c", "d"].enumerated() { cache.store(key, panel: true, now: start.addingTimeInterval(Double(i))) }
        #expect(cache.lookup("a", now: start) == nil)
        for key in ["b", "c", "d"] { #expect(cache.lookup(key, now: start) == true, Comment(rawValue: key)) }
        alive.subtract(["b", "c"])
        cache.store("e", panel: true, now: start.addingTimeInterval(10))
        #expect(cache.lookup("d", now: start) == true && cache.lookup("e", now: start) == true)
        #expect(cache.lookup("b", now: start) == nil && cache.lookup("c", now: start) == nil)
    }
}
