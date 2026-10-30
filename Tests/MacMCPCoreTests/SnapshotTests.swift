import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

private func node(_ role: String, _ subrole: String? = nil, title: String? = nil, desc: String? = nil, value: String? = nil,
                  placeholder: String? = nil, frame: CGRect? = CGRect(x: 0, y: 0, width: 50, height: 20),
                  path: String = "", children: [RawNode] = []) -> RawNode {
    var n = RawNode(role: role, subrole: subrole, title: title, description: desc, value: value, placeholder: placeholder, frame: frame)
    n.path = path
    n.children = children
    return n
}

@Suite struct LabelTests {
    @Test func prefersTitleThenDescriptionThenValue() {
        #expect(Snapshot.label(node("AXButton", title: "Save", desc: "save doc")) == "Save")
        #expect(Snapshot.label(node("AXButton", desc: "Close tab")) == "Close tab")
        #expect(Snapshot.label(node("AXLink", value: "Read more")) == "Read more")
    }

    @Test func textFieldsUsePlaceholderAndShowValueSeparately() {
        let field = node("AXTextField", value: "Ada", placeholder: "Customer name")
        #expect(Snapshot.label(field) == "Customer name")
        #expect(Snapshot.displayValue(field) == "Ada")
        #expect(Snapshot.displayValue(node("AXTextField")) == "")   // empty field is shown as empty, not omitted
    }

    @Test func checkboxValueIsStateNotLabel() {
        let box = node("AXCheckBox", value: "1", children: [node("AXStaticText", value: "Bacon")])
        #expect(Snapshot.label(box) == "Bacon")
        #expect(Snapshot.states(box) == ["checked"])
        #expect(Snapshot.states(node("AXCheckBox", value: "2")) == ["mixed"])
        #expect(Snapshot.states(node("AXRadioButton", value: "1")) == ["selected"])
    }

    @Test func unnamedWindowControlsAreNamedFromSubrole() {
        #expect(Snapshot.label(node("AXButton", "AXCloseButton")) == "close")
    }

    @Test func secureFieldValueIsNeverRevealed() {
        let pw = node("AXTextField", "AXSecureTextField", value: "hunter2", placeholder: "Password")
        #expect(Snapshot.displayValue(pw) == "•••")
        #expect(Snapshot.shortRole(pw.role, subrole: pw.subrole) == "password")
        let rows = Snapshot.rows(from: node("AXWindow", children: [pw]), pid: 1)
        #expect(!rows.map { $0.render(frames: true) }.joined().contains("hunter2"))
    }

    @Test func tableRowsCollapseCellTextIntoOneLabel() {
        let row = node("AXRow", children: [
            node("AXCell", children: [node("AXStaticText", value: "Finder")]),
            node("AXCell", children: [node("AXStaticText", value: "1259")]),
        ])
        #expect(Snapshot.label(row) == "Finder | 1259")
    }
}

@Suite struct RowTests {
    let window = node("AXWindow", title: "Pizza Order", children: [
        node("AXHeading", title: "Pizza Order"),
        node("AXGroup", title: "Pizza Toppings", children: [
            node("AXCheckBox", value: "0", path: "1.0", children: [node("AXStaticText", value: "Bacon")]),
        ]),
        node("AXButton", path: "2", children: [node("AXStaticText", value: "Submit order")]),
        node("AXStaticText", value: "Nothing happened yet."),
    ])

    @Test func foldsTextIntoInteractiveParentsAndKeepsLooseText() {
        let rows = Snapshot.rows(from: window, pid: 7)
        let rendered = rows.map { $0.render(frames: false) }
        #expect(rendered == [
            "heading \"Pizza Order\"",
            "group \"Pizza Toppings\"",
            " checkbox \"Bacon\" [unchecked]",
            "button \"Submit order\"",
            "text \"Nothing happened yet.\"",
        ])
        #expect(rows.filter { $0.kind == .interactive }.count == 2)
    }

    @Test func textCanBeExcluded() {
        let rows = Snapshot.rows(from: window, pid: 7, includeText: false)
        #expect(!rows.contains { $0.kind == .text })
    }

    @Test func budgetCutsRowsAndCountsThem() {
        let many = node("AXWindow", children: (0..<200).map { node("AXButton", title: "Button number \($0)", path: "\($0)") })
        let rows = Snapshot.rows(from: many, pid: 1)
        let (text, omitted) = Snapshot.render(rows, frames: false, maxTokens: 200)
        #expect(omitted > 0)
        #expect(text.count <= 800)
        #expect(text.split(separator: "\n").count + omitted == 200)
    }

    @Test func framesAreOptIn() {
        let rows = Snapshot.rows(from: node("AXWindow", children: [node("AXButton", title: "OK", frame: CGRect(x: 10, y: 20, width: 30, height: 40))]), pid: 1)
        #expect(rows[0].render(frames: false) == "button \"OK\"")
        #expect(rows[0].render(frames: true) == "button \"OK\" @10,20 30x40")
    }
}

@Suite struct RefStoreTests {
    @Test func sameElementKeepsItsRefAcrossSnapshots() async throws {
        let store = RefStore()
        let tree = node("AXWindow", children: [node("AXButton", title: "Save", path: "0"), node("AXButton", title: "Cancel", path: "1")])
        var first = Snapshot.rows(from: tree, pid: 9)
        let s1 = try await store.record(&first, pid: 9)
        var second = Snapshot.rows(from: tree, pid: 9)
        let s2 = try await store.record(&second, pid: 9)
        #expect(s2 == s1 + 1)
        #expect(first.map(\.ref) == second.map(\.ref))
        #expect(Set(first.compactMap(\.ref)).count == 2)
    }

    @Test func newElementsGetNewRefs() async throws {
        let store = RefStore()
        var a = Snapshot.rows(from: node("AXWindow", children: [node("AXButton", title: "Save", path: "0")]), pid: 9)
        _ = try await store.record(&a, pid: 9)
        var b = Snapshot.rows(from: node("AXWindow", children: [node("AXButton", title: "Save", path: "0"),
                                                               node("AXButton", title: "Don't Save", path: "1")]), pid: 9)
        _ = try await store.record(&b, pid: 9)
        #expect(b[0].ref == a[0].ref)
        #expect(b[1].ref != a[0].ref && b[1].ref != nil)
    }
}

@Suite struct ScreenshotMappingTests {
    @Test func oneXDisplayFullCapture() {
        let size = ScreenshotMapping.outputSize(source: CGSize(width: 1920, height: 1080), backingScale: 1, maxEdge: 1280)
        #expect(size == CGSize(width: 1280, height: 720))
        let m = ScreenshotMapping(source: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelSize: size)
        #expect(m.point(forPixel: CGPoint(x: 640, y: 360)) == CGPoint(x: 960, y: 540))
    }

    @Test func retinaZoomedRegionKeepsNativeDetail() {
        // 300x200 points on a 2x display → 600x400 px, under the cap, so no downscale.
        let size = ScreenshotMapping.outputSize(source: CGSize(width: 300, height: 200), backingScale: 2, maxEdge: 1280)
        #expect(size == CGSize(width: 600, height: 400))
        let m = ScreenshotMapping(source: CGRect(x: 100, y: 50, width: 300, height: 200), pixelSize: size)
        #expect(m.pointsPerPixel == 0.5)
        #expect(m.point(forPixel: CGPoint(x: 600, y: 400)) == CGPoint(x: 400, y: 250))
    }

    @Test func displayLeftOfPrimaryHasNegativeOrigin() {
        let m = ScreenshotMapping(source: CGRect(x: -1440, y: -200, width: 1440, height: 900), pixelSize: CGSize(width: 1280, height: 800))
        let p = m.point(forPixel: CGPoint(x: 0, y: 0))
        #expect(p == CGPoint(x: -1440, y: -200))
        #expect(m.contains(pixel: CGPoint(x: 1279, y: 799)) && !m.contains(pixel: CGPoint(x: 1280, y: 0)))
    }
}

@Suite struct LabelNoiseTests {
    @Test func iconDescriptionsOnlyWhenNoText() {
        let row = node("AXRow", children: [node("AXCell", children: [node("AXImage", desc: "letter A icon"), node("AXStaticText", value: "Applications")])])
        #expect(Snapshot.label(row) == "Applications")
        let iconOnly = node("AXButton", children: [node("AXImage", desc: "trash")])
        #expect(Snapshot.label(iconOnly) == "trash")
    }

    @Test func generatedIdentifiersAreIgnored() {
        var n = node("AXTextField", "AXSearchField")
        n.identifier = "_NS:122"
        #expect(Snapshot.label(n) == "")
        n.identifier = "searchField"
        #expect(Snapshot.label(n) == "searchField")
        n.identifier = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        #expect(Snapshot.label(n) == "")
    }
}

@Suite struct GlyphTests {
    @Test func privateUseIconGlyphsAreStripped() {
        #expect(Snapshot.clean("\u{EA7F} New File...") == "New File...")
        #expect(Snapshot.clean("\u{EB60}") == nil)
        let row = node("AXRow", children: [node("AXStaticText", value: "\u{EAB6}"), node("AXStaticText", value: ".build")])
        #expect(Snapshot.label(row) == ".build")
    }
}

@Suite struct FormLabelTests {
    @Test func textJustLeftOfAnUnlabeledControlBecomesItsLabel() {
        let form = node("AXGroup", children: [
            node("AXStaticText", value: "Size:", frame: CGRect(x: 0, y: 100, width: 30, height: 16)),
            node("AXPopUpButton", value: "Small", frame: CGRect(x: 36, y: 96, width: 90, height: 24)),
            node("AXStaticText", value: "Unrelated", frame: CGRect(x: 0, y: 200, width: 80, height: 16)),
            node("AXButton", frame: CGRect(x: 300, y: 200, width: 20, height: 20)),   // too far away
        ])
        let rendered = Snapshot.rows(from: node("AXWindow", children: [form]), pid: 1).map { $0.render(frames: false) }
        #expect(rendered.contains("popup \"Size\" = \"Small\""))
        #expect(!rendered.contains("text \"Size:\""))
        #expect(rendered.contains("text \"Unrelated\""))
    }

    @Test func scrollBarsAreHiddenAndHeadingsReadDescription() {
        let win = node("AXWindow", title: "Main", children: [
            node("AXHeading", desc: "Order Form"),
            node("AXScrollBar", children: [node("AXButton", "AXIncrementPage")]),
            node("AXStaticText", value: "Main"),
        ])
        let rendered = Snapshot.rows(from: win, pid: 1).map { $0.render(frames: false) }
        #expect(rendered == ["heading \"Order Form\""])
    }
}

@Suite struct WrapperRowTests {
    @Test func unlabeledRowsCollapseToTheirContents() {
        let sidebar = node("AXOutline", children: [
            { var r = node("AXRow", children: [node("AXCell", children: [node("AXButton", desc: "Wi-Fi")])]); r.selected = true; return r }(),
            node("AXRow"),   // separator
            node("AXRow", children: [node("AXCell", children: [node("AXStaticText", value: "General")])]),
        ])
        let rendered = Snapshot.rows(from: node("AXWindow", children: [sidebar]), pid: 1).map { $0.render(frames: false) }
        #expect(rendered == ["button \"Wi-Fi\" [selected]", "row \"General\""])
    }
}

@Suite struct NonFiniteGeometryTests {
    @Test func nonFiniteGeometryIsDroppedNotTrapped() {
        #expect(frame(position: CGPoint(x: CGFloat.nan, y: 0), size: CGSize(width: 10, height: 10)) == nil)
        #expect(frame(position: CGPoint(x: 0, y: 0), size: CGSize(width: CGFloat.infinity, height: 10)) == nil)
        #expect(frame(position: CGPoint(x: 1, y: 2), size: CGSize(width: 3, height: 4)) == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func renderingNeverTrapsOnBadFrames() {
        var row = Snapshot.rows(from: node("AXWindow", children: [node("AXButton", title: "OK")]), pid: 1)[0]
        row.frame = CGRect(x: CGFloat.infinity, y: CGFloat.nan, width: 1, height: 1)
        #expect(row.render(frames: true) == "button \"OK\" @0,0 1x1")
        #expect(CGFloat.nan.safeInt == 0 && CGFloat.infinity.safeInt == 0 && CGFloat(12.7).safeInt == 12)
    }
}

@Suite struct StaleScreenshotTests {
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    func window(_ id: UInt32 = 7, at f: CGRect) -> WindowInfo {
        WindowInfo(id: id, pid: 1, owner: "App", title: "", layer: 0, bounds: f, alpha: 1)
    }
    func mapping(window: Bool = true, age: TimeInterval = 0) -> ScreenshotMapping {
        ScreenshotMapping(source: frame, pixelSize: CGSize(width: 800, height: 600),
                          window: window ? .init(id: 7, frame: frame) : nil, takenAt: Date(timeIntervalSinceNow: -age))
    }

    @Test func unchangedWindowIsFine() {
        #expect(mapping().staleReason(id: "c1", windows: [window(at: frame)]) == nil)
    }
    @Test func movedResizedOrGoneWindowIsStale() {
        #expect(mapping().staleReason(id: "c1", windows: [window(at: frame.offsetBy(dx: 40, dy: 0))])?.contains("moved") == true)
        #expect(mapping().staleReason(id: "c1", windows: [window(at: CGRect(x: 100, y: 100, width: 700, height: 600))]) != nil)
        #expect(mapping().staleReason(id: "c1", windows: [window(99, at: frame)])?.contains("gone") == true)
    }
    @Test func displayCapturesOnlyAge() {
        #expect(mapping(window: false).staleReason(id: "c1", windows: []) == nil)
        #expect(mapping(window: false, age: 700).staleReason(id: "c1", windows: [])?.contains("old") == true)
    }
}
