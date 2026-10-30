import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import MacMCPCore

/// Distinct accessibility objects for tests: application elements for different pids are never CFEqual.
private func fakeElement(_ n: Int32) -> AXElement { AXElement.application(pid: 200_000 + n) }

/// A window holding one list row whose only cell text is `text`, backed by the same AXRow object each time.
private func listWindow(rowObject: Int32, text: String, identifier: String? = nil) -> RawNode {
    var root = RawNode(role: "AXWindow", title: "Items")
    root.element = fakeElement(1)
    var row = RawNode(role: "AXRow")
    row.element = fakeElement(rowObject)
    row.identifier = identifier
    row.path = "0.0"
    var cell = RawNode(role: "AXCell")
    cell.children = [RawNode(role: "AXStaticText", value: text)]
    row.children = [cell]
    root.children = [row]
    return root
}

private func buttonWindow(object: Int32, title: String) -> RawNode {
    var root = RawNode(role: "AXWindow", title: "Form")
    root.element = fakeElement(1)
    var button = RawNode(role: "AXButton", title: title)
    button.element = fakeElement(object)
    root.children = [button]
    return root
}

// MARK: D1 — a ref must keep meaning what the agent saw

@Suite struct RefIdentityTests {
    @Test func aReusedRowObjectWithDifferentTextGetsANewRef() async throws {
        let store = RefStore()
        var first = Snapshot.rows(from: listWindow(rowObject: 10, text: "Item 1"), pid: 7)
        _ = try await store.record(&first, pid: 7)
        let e10 = try #require(first[0].ref)
        // A virtualised list reuses the AXRow for another item.
        var later = Snapshot.rows(from: listWindow(rowObject: 10, text: "Item 7"), pid: 7)
        _ = try await store.record(&later, pid: 7)
        #expect(later[0].ref != e10, "the same AXRow now shows a different item; it must not keep the old ref")
        // The old ref still remembers what it was.
        #expect(try #require(await store.entry(e10)).row.label == "Item 1")
        // Same object, same text: the ref stays.
        var same = Snapshot.rows(from: listWindow(rowObject: 10, text: "Item 7"), pid: 7)
        _ = try await store.record(&same, pid: 7)
        #expect(same[0].ref == later[0].ref)
    }

    @Test func aRenamedButtonKeepsItsRefButRemembersWhatWasShown() async throws {
        let store = RefStore()
        var play = Snapshot.rows(from: buttonWindow(object: 20, title: "Play"), pid: 7)
        _ = try await store.record(&play, pid: 7)
        let ref = try #require(play[0].ref)
        #expect(try #require(await store.entry(ref)).shown == nil, "nothing was rendered to the agent yet")
        await store.markShown(play)
        #expect(try #require(await store.entry(ref)).shown == RefStore.Shown(label: "Play", identifier: nil))

        var pause = Snapshot.rows(from: buttonWindow(object: 20, title: "Pause"), pid: 7)
        _ = try await store.record(&pause, pid: 7)
        let entry = try #require(await store.entry(ref))
        #expect(pause[0].ref == ref)
        #expect(entry.row.label == "Pause")
        #expect(entry.shown?.label == "Play", "a snapshot the agent didn't see must not update what it was shown")
        let refusal = RefStore.changeMessage(ref: ref, role: entry.row.role, shown: entry.shown,
                                             label: entry.row.label, identifier: entry.row.identifier)
        // The labels are the app's own text, so they are marked.
        #expect(refusal.map { Untrusted.strip($0) } == "\(ref) was … but now reads …. Take a new mac_snapshot.")
        #expect(refusal?.contains(">>Play<<end") == true && refusal?.contains(">>Pause<<end") == true)
        await store.markShown(pause)
        #expect(RefStore.changeMessage(ref: ref, role: "button", shown: try #require(await store.entry(ref)).shown,
                                       label: "Pause", identifier: nil) == nil)
    }

    /// Snapshot A renders "Play" to the agent; before A marks it, a bookkeeping snapshot B records the same button as
    /// "Pause". The guard must remember "Play" (what the agent saw), not whatever the entry says when A gets round to
    /// marking, or an action on the changed button would be accepted.
    @Test func markingRecordsTheRenderedIdentityNotTheEntrysCurrentOne() async throws {
        let store = RefStore()
        var play = Snapshot.rows(from: buttonWindow(object: 21, title: "Play"), pid: 7)
        _ = try await store.record(&play, pid: 7)
        let ref = try #require(play[0].ref)
        var pause = Snapshot.rows(from: buttonWindow(object: 21, title: "Pause"), pid: 7)
        _ = try await store.record(&pause, pid: 7)   // B lands between A's record and A's mark
        #expect(pause[0].ref == ref)
        await store.markShown(play)   // A returns "Play" to the agent
        let entry = try #require(await store.entry(ref))
        #expect(entry.shown?.label == "Play", "the guard must hold what the agent was shown")
        #expect(entry.row.label == "Pause")
        let message = RefStore.changeMessage(ref: ref, role: "button", shown: entry.shown, label: entry.row.label, identifier: nil)
        #expect(message.map { Untrusted.strip($0) } == "\(ref) was … but now reads …. Take a new mac_snapshot.")
        #expect(message?.contains(">>Play<<end") == true && message?.contains(">>Pause<<end") == true)
    }

    @Test func snapshotsMarkNothingUnlessAsked() {
        #expect(!SnapshotRequest().markShown, "only mac_snapshot renders rows to the agent as they are; every other snapshot marks what it returns")
    }

    @Test func aRowWithAStableIdentifierKeepsItsRefWhenItsTextChanges() async throws {
        let store = RefStore()
        var first = Snapshot.rows(from: listWindow(rowObject: 11, text: "Build · 12:00:01", identifier: "build-row"), pid: 7)
        _ = try await store.record(&first, pid: 7)
        let ref = try #require(first[0].ref)
        await store.markShown(first)
        var later = Snapshot.rows(from: listWindow(rowObject: 11, text: "Build · 12:00:02", identifier: "build-row"), pid: 7)
        _ = try await store.record(&later, pid: 7)
        #expect(later[0].ref == ref, "same item by identifier: the clock text is display state")
        let entry = try #require(await store.entry(ref))
        #expect(RefStore.changeMessage(ref: ref, role: "row", shown: entry.shown, label: entry.row.label, identifier: entry.row.identifier) == nil)
        // A changed identifier is another item, whatever the text.
        #expect(RefStore.changeMessage(ref: ref, role: "row", shown: entry.shown, label: entry.row.label, identifier: "other-row")?
            .contains("different element") == true)
        // Buttons don't get this: Play → Pause is a change an action must not ignore.
        #expect(RefStore.changeMessage(ref: "e9", role: "button", shown: .init(label: "Play", identifier: "playPause"),
                                       label: "Pause", identifier: "playPause") != nil)
    }

    @Test func anAppKitGeneratedIdentifierDoesNotCarryARowAcrossATextChange() async throws {
        let store = RefStore()
        var first = Snapshot.rows(from: listWindow(rowObject: 12, text: "Item 1", identifier: "_NS:142"), pid: 7)
        _ = try await store.record(&first, pid: 7)
        var later = Snapshot.rows(from: listWindow(rowObject: 12, text: "Item 7", identifier: "_NS:142"), pid: 7)
        _ = try await store.record(&later, pid: 7)
        #expect(later[0].ref != first[0].ref, "_NS: ids name the reused view, not the item")
        #expect(RefStore.changeMessage(ref: "e1", role: "row", shown: .init(label: "Item 1", identifier: "_NS:142"),
                                       label: "Item 7", identifier: "_NS:142") != nil)
    }

    @Test func changeMessageRules() {
        let shown = RefStore.Shown(label: "Item 1", identifier: "row-1")
        #expect(RefStore.changeMessage(ref: "e1", role: "row", shown: nil, label: "Anything", identifier: nil) == nil)
        #expect(RefStore.changeMessage(ref: "e1", role: "row", shown: shown, label: "Item 1", identifier: "row-1") == nil)
        // An identifier that was there and is gone: not the same element, or not fully read; either way refused.
        #expect(RefStore.changeMessage(ref: "e1", role: "row", shown: shown, label: "Item 1", identifier: nil)?
            .contains("identifier is gone") == true)
        #expect(RefStore.changeMessage(ref: "e1", role: "row", shown: shown, label: "Item 1", identifier: nil, complete: false)?
            .contains("couldn't be fully re-read") == true)
        // An element the agent saw without an identifier may gain one.
        #expect(RefStore.changeMessage(ref: "e1", role: "button", shown: .init(label: "Save", identifier: nil), label: "Save", identifier: "save") == nil)
        // A row with a meaningful, unchanged identifier is the same item: its text is display state (D1 finding 8).
        #expect(RefStore.changeMessage(ref: "e1", role: "row", shown: shown, label: "Item 7", identifier: "row-1") == nil)
        let anonymous = RefStore.Shown(label: "Item 1", identifier: nil)
        let renamed = RefStore.changeMessage(ref: "e1", role: "row", shown: anonymous, label: "Item 7", identifier: nil)
        // The labels are the app's own text, so they are marked.
        #expect(renamed.map { Untrusted.strip($0) } == "e1 was … but now reads …. Take a new mac_snapshot.")
        #expect(renamed?.contains(">>Item 1<<end") == true && renamed?.contains(">>Item 7<<end") == true)
        let idChanged = RefStore.changeMessage(ref: "e1", role: "row", shown: shown, label: "Item 1", identifier: "row-9")
        #expect(idChanged?.contains("different element") == true && idChanged?.contains("row-") == false)
        let unnamed = RefStore.changeMessage(ref: "e2", role: "button", shown: .init(label: "", identifier: nil), label: "Save", identifier: nil)
        #expect(unnamed.map { Untrusted.strip($0) } == "e2 had no label but now reads …. Take a new mac_snapshot.")
        #expect(unnamed?.contains(">>Save<<end") == true)
        let secret = RefStore.changeMessage(ref: "e3", role: "password", shown: .init(label: "PIN", identifier: nil),
                                            label: "hunter2", identifier: nil)
        #expect(secret?.contains("hunter2") == false && secret?.contains("password field") == true)
    }

    /// An empty current label used to prove nothing. It now proves the element is unnamed when the read was complete,
    /// so a control that lost its label (a recycled row whose cells didn't read) is refused, while a control named by
    /// the text beside it, which reads as unnamed on its own, still passes.
    @Test func anEmptyLabelIsOnlyAcceptedFromACompleteReadOfAControlThatCarriesNoNameItself() {
        let named = RefStore.Shown(label: "Size", identifier: nil)
        let message = RefStore.changeMessage(ref: "e5", role: "popup", shown: named, label: "", identifier: nil)
        #expect(message.map { Untrusted.strip($0) } == "e5 was … but now has no label. Take a new mac_snapshot.")
        #expect(message?.contains(">>Size<<end") == true)
        #expect(RefStore.changeMessage(ref: "e5", role: "popup", shown: named, label: "", identifier: nil, complete: false)?
            .contains("couldn't be fully re-read") == true)
        let byNeighbor = RefStore.Shown(label: "Size", identifier: nil, labelFromNeighbor: true)
        #expect(RefStore.changeMessage(ref: "e5", role: "popup", shown: byNeighbor, label: "", identifier: nil) == nil)
        #expect(RefStore.changeMessage(ref: "e5", role: "popup", shown: byNeighbor, label: "", identifier: nil, complete: false) != nil,
                "a cut-short read can't tell an unnamed control from one whose name didn't come back")
        #expect(RefStore.changeMessage(ref: "e5", role: "popup", shown: byNeighbor, label: "Colour", identifier: nil) != nil,
                "a different name is still a change")
        let unnamed = RefStore.Shown(label: "", identifier: nil)
        #expect(RefStore.changeMessage(ref: "e6", role: "button", shown: unnamed, label: "", identifier: nil) == nil)
        // A secret never leaks, whichever rule refuses.
        let secret = RefStore.changeMessage(ref: "e7", role: "password", shown: .init(label: "PIN", identifier: nil), label: "", identifier: nil)
        #expect(secret?.contains("password field") == true)
    }

    @Test func rowsRememberWhenTheirLabelCameFromTheTextBesideThem() {
        var text = RawNode(role: "AXStaticText", value: "Size:", frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        text.element = fakeElement(40)
        var popup = RawNode(role: "AXPopUpButton", frame: CGRect(x: 50, y: 0, width: 80, height: 20))
        popup.element = fakeElement(41)
        var window = RawNode(role: "AXWindow")
        window.children = [text, popup]
        let rows = Snapshot.rows(from: window, pid: 7)
        let row = try! #require(rows.first { $0.role == "popup" })
        #expect(row.label == "Size" && row.labelFromNeighbor)
        #expect(RefStore.Shown(row).labelFromNeighbor)
        var named = RawNode(role: "AXPopUpButton", title: "Size", frame: CGRect(x: 50, y: 0, width: 80, height: 20))
        named.element = fakeElement(42)
        window.children = [named]
        #expect(Snapshot.rows(from: window, pid: 7)[0].labelFromNeighbor == false)
    }

    @Test func rowsCarryTheirIdentifierForTheCheck() {
        var button = RawNode(role: "AXButton", title: "Save")
        button.identifier = "saveButton"
        let rows = Snapshot.rows(from: RawNode(role: "AXWindow", children: [button]), pid: 7)
        #expect(rows[0].identifier == "saveButton")
    }
}

private extension RawNode {
    init(role: String, children: [RawNode]) {
        self.init(role: role)
        self.children = children
    }
}

// MARK: D2 — ids never repeat across agent incarnations

/// Mints as the stores do: reserve a block when none is left, then mint.
private func mint(_ counter: inout IDCounter) async throws -> String {
    if counter.blockNeeded() { counter.add(try await counter.reserveBlock()) }
    return counter.mint()
}

@Suite struct IDBlockTests {
    func tempDir() -> String { NSTemporaryDirectory() + "macmcp-ids-\(UUID().uuidString)" }
    func tempPath() -> String { tempDir() + "/ids.json" }

    @Test func blocksAreReservedOnDiskAndTheNextIncarnationStartsAbove() async throws {
        let path = tempPath()
        var first = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 50)
        #expect(try await mint(&first) == "e1")
        #expect(try await mint(&first) == "e2")
        #expect(FileManager.default.fileExists(atPath: path))
        // A restart: nothing in memory survives, only the file.
        var second = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 50)
        #expect(second.isFromEarlierIncarnation("e2"), "before minting, every id predates this incarnation")
        #expect(try await mint(&second) == "e51")
        #expect(second.isFromEarlierIncarnation("e2"))
        #expect(second.isFromEarlierIncarnation("e50"))
        #expect(!second.isFromEarlierIncarnation("e51"))
        #expect(!second.isFromEarlierIncarnation("e999"), "not yet minted here, but not from before either")
        #expect(!second.isFromEarlierIncarnation("c1") && !second.isFromEarlierIncarnation("bogus"))
        // Using up a block takes the next one, past anything another kind reserved.
        for _ in 0..<49 { _ = try await mint(&second) }
        #expect(try await mint(&second) == "e101")
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    @Test func kindsAreIndependentAndEphemeralStoresStartAtOne() async throws {
        let blocks = IDBlocks(path: tempPath())
        var e = IDCounter(prefix: "e", blocks: blocks, blockSize: 10)
        var c = IDCounter(prefix: "c", blocks: blocks, blockSize: 10)
        #expect(try await mint(&e) == "e1")
        #expect(try await mint(&c) == "c1")
        var ephemeral = IDCounter(prefix: "e", blocks: .ephemeral, blockSize: 10)
        #expect(try await mint(&ephemeral) == "e1")
        #expect(!ephemeral.isFromEarlierIncarnation("e1"), "nothing persists, so nothing predates it")
        try? FileManager.default.removeItem(atPath: (blocks.path! as NSString).deletingLastPathComponent)
    }

    @Test func refsSnapshotsAndScreenshotsSurviveARestartWithoutRepeating() async throws {
        let path = tempPath()
        let before = RefStore(ids: IDBlocks(path: path))
        var rows = Snapshot.rows(from: buttonWindow(object: 30, title: "Save"), pid: 7)
        let s1 = try await before.record(&rows, pid: 7)
        let e1 = try #require(rows[0].ref)
        let shots = ScreenshotStore(ids: IDBlocks(path: path))
        let c1 = try await shots.record(ScreenshotMapping(source: CGRect(x: 0, y: 0, width: 100, height: 100), pixelSize: CGSize(width: 100, height: 100)))
        #expect(e1 == "e1" && s1 == 1 && c1 == "c1")

        let restarted = RefStore(ids: IDBlocks(path: path))
        let restartedShots = ScreenshotStore(ids: IDBlocks(path: path))
        #expect(await restarted.entry(e1) == nil)
        #expect(await restarted.missingMessage(e1).contains("before the agent restarted"))
        #expect(await restartedShots.missingMessage(c1).contains("before the agent restarted"))
        var again = Snapshot.rows(from: buttonWindow(object: 30, title: "Save"), pid: 7)
        let s2 = try await restarted.record(&again, pid: 7)
        let c2 = try await restartedShots.record(ScreenshotMapping(source: .zero, pixelSize: .zero))
        #expect(again[0].ref == "e1001" && s2 == 101 && c2 == "c101")
        #expect(await restarted.missingMessage("e5000").hasPrefix("Unknown ref e5000"))
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// A block that couldn't be written is a block the next incarnation would hand out again, so it is never issued.
    @Test func aBlockThatCannotBeRecordedIsNotIssued() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: dir + "/blocked"))
        let path = dir + "/blocked/ids.json"   // the parent is a file: nothing can be created under it
        var counter = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        await #expect(throws: IDBlocksError.self) { try await mint(&counter) }
        #expect(counter.blockNeeded() && counter.first == nil, "nothing was reserved, so nothing can be minted")
        let store = RefStore(ids: IDBlocks(path: path))
        var rows = Snapshot.rows(from: buttonWindow(object: 31, title: "Save"), pid: 7)
        await #expect(throws: IDBlocksError.self) { _ = try await store.record(&rows, pid: 7) }
        #expect(rows[0].ref == nil, "a snapshot whose ids weren't recorded assigns none")
        let shots = ScreenshotStore(ids: IDBlocks(path: path))
        await #expect(throws: IDBlocksError.self) { _ = try await shots.record(ScreenshotMapping(source: .zero, pixelSize: .zero)) }
        #expect("\(IDBlocksError.notRecorded(path: path, error: "x"))".contains("no snapshot or screenshot ids"))
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func missingStateIsTOldApartFromUnusableState() throws {
        let path = tempPath()
        #expect(IDBlocks.load(path) == .missing)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("{\"e\": 40}".utf8).write(to: URL(fileURLWithPath: path))
        #expect(IDBlocks.load(path) == .marks(["e": 40]))
        try Data("{\"e\": -1}".utf8).write(to: URL(fileURLWithPath: path))
        if case .unusable = IDBlocks.load(path) {} else { Issue.record("a negative mark is corrupt") }
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        if case .unusable = IDBlocks.load(path) {} else { Issue.record("garbage is corrupt, not empty") }
        try Data().write(to: URL(fileURLWithPath: path))
        if case .unusable = IDBlocks.load(path) {} else { Issue.record("an empty file is corrupt: an atomic write never leaves one") }
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Marks that can't be read are unknown, not zero: numbering restarts above anything an earlier incarnation can
    /// have reached, so `e12` from before the corruption can't come back as a new element.
    @Test func corruptOrUnreadableStateRestartsNumberingHighNotLow() async throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        let floor = IDBlocks.fallbackStart()
        var counter = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        let n = try #require(counter.number(of: try await mint(&counter)))
        #expect(n >= floor, "\(n) must not restart low after corruption")
        #expect(counter.isFromEarlierIncarnation("e12"))
        // The fallback was recorded, so the next incarnation continues above it as usual.
        var next = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try #require(next.number(of: try await mint(&next))) == n + 10)

        // Unreadable (permissions) is the same as corrupt: the marks are unknown.
        try Data("{\"e\": 5}".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        if case .unusable = IDBlocks.load(path) {
            var unreadable = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
            #expect(try #require(unreadable.number(of: try await mint(&unreadable))) >= floor)
        } else {
            Issue.record("expected an unreadable file to be unusable")   // (root can read anything; the test can't run as root)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Recovering from an unusable file must raise every kind, not only the first one reserved afterwards: the
    /// other kinds' marks are lost too, and a fresh file with no mark for them would otherwise restart them at 1,
    /// so a client's old `e1` or `c1` would name whatever the new incarnation minted first. The floor is the
    /// recorded high-water mark, not the clock, so the ids stay short.
    @Test func recoveryFloorAppliesToEveryKind() async throws {
        let path = tempPath()
        let before = IDBlocks(path: path)
        var e = IDCounter(prefix: "e", blocks: before, blockSize: 10)
        var c = IDCounter(prefix: "c", blocks: before, blockSize: 10)
        #expect(try await mint(&e) == "e1")
        #expect(try await mint(&c) == "c1")
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        guard case let .mark(mark) = IDBlocks.loadHighWater(path) else { Issue.record("no high-water mark was kept"); return }
        let floor = mark + 1
        #expect(floor == 11 && floor < IDBlocks.fallbackStart(), "with a mark kept, the clock isn't needed")
        // The next snapshot reserves `s` first and `e` after it; a screenshot reserves `c` later still. Each
        // reservation reads the file afresh, and only the first one sees it unusable.
        let after = IDBlocks(path: path)
        var s = IDCounter(prefix: "s", blocks: after, blockSize: 10)
        var e2 = IDCounter(prefix: "e", blocks: after, blockSize: 10)
        var c2 = IDCounter(prefix: "c", blocks: after, blockSize: 10)
        #expect(try #require(s.number(of: try await mint(&s))) >= floor)
        let eNext = try #require(e2.number(of: try await mint(&e2)))
        #expect(eNext >= floor, "e\(eNext) restarted low after s took the recovery floor")
        let cNext = try #require(c2.number(of: try await mint(&c2)))
        #expect(cNext >= floor, "c\(cNext) restarted low after s took the recovery floor")
        #expect(e2.isFromEarlierIncarnation("e1") && c2.isFromEarlierIncarnation("c1"))
        // The floor outlives the recovery: a kind first reserved by a later incarnation starts above it too.
        var k = IDCounter(prefix: "k", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try #require(k.number(of: try await mint(&k))) >= floor)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// A replacement that can't be written (a full disk) leaves the unusable file where it is: a retry then sees an
    /// unusable file again and restarts high, rather than a missing one and restarting at 1.
    @Test func anUnusableFileStaysUntilItsReplacementIsWritten() async throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        let floor = IDBlocks.fallbackStart()
        let fullDisk = IDBlocks(path: path, writeFault: { throw POSIXError(.ENOSPC) })
        var counter = IDCounter(prefix: "e", blocks: fullDisk, blockSize: 10)
        await #expect(throws: IDBlocksError.self) { try await mint(&counter) }
        #expect(FileManager.default.fileExists(atPath: path), "the unusable file was removed before its replacement existed")
        if case .unusable = IDBlocks.load(path) {} else { Issue.record("the unusable file should still be there, unusable") }
        var retry = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try #require(retry.number(of: try await mint(&retry))) >= floor, "the retry must not count from 1")
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// The scenario from the review: a recovery takes its floor from the clock at T and issues T…T+9; a second
    /// recovery before the clock has moved past that block would start at T again and reissue them. The high-water
    /// mark kept beside the id file is what the second recovery starts above.
    @Test func aSecondRecoveryStartsAboveWhatTheFirstIssuedNotAtTheClock() async throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        let stopped = Date()
        let clock: @Sendable () -> Date = { stopped }   // wall time that doesn't move between the two recoveries
        var first = IDCounter(prefix: "e", blocks: IDBlocks(path: path, writeFault: nil, now: clock), blockSize: 10)
        let a = try #require(first.number(of: try await mint(&first)))
        #expect(a == IDBlocks.fallbackStart(now: stopped), "with no mark ever kept, the first recovery falls back to the clock")
        for _ in 0..<5 { _ = try await mint(&first) }
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        var second = IDCounter(prefix: "e", blocks: IDBlocks(path: path, writeFault: nil, now: clock), blockSize: 10)
        let b = try #require(second.number(of: try await mint(&second)))
        #expect(b == a + 10, "e\(b) must start above the block the first recovery issued (e\(a)…e\(a + 9))")
        #expect(second.isFromEarlierIncarnation("e\(a + 5)"))
        // A clock that went backwards changes nothing once a mark exists.
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        let earlier: @Sendable () -> Date = { stopped.addingTimeInterval(-3600) }
        var third = IDCounter(prefix: "e", blocks: IDBlocks(path: path, writeFault: nil, now: earlier), blockSize: 10)
        #expect(try #require(third.number(of: try await mint(&third))) == b + 10)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// With both records unusable nothing can be proven about what was issued, and a floor from the clock could
    /// repeat ids from an earlier recovery: no id is issued, and both files are left for a person.
    @Test func withBothRecordsUnusableNothingIsIssued() async throws {
        let path = tempPath()
        let highWater = IDBlocks.highWaterPath(path)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: highWater))
        var counter = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        await #expect(throws: IDBlocksError.self) { try await mint(&counter) }
        if case .unusable = IDBlocks.load(path) {} else { Issue.record("the id file was replaced without a floor") }
        if case .unusable = IDBlocks.loadHighWater(path) {} else { Issue.record("the high-water file was replaced") }
        #expect("\(IDBlocksError.unrecoverable(path: path, highWaterPath: highWater))".contains("both unreadable"))
        // A missing id file next to an unusable mark is the same: the mark says ids were issued, but not which.
        try FileManager.default.removeItem(atPath: path)
        await #expect(throws: IDBlocksError.self) { try await mint(&counter) }
        #expect(!FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// The id file alone going missing used to restart numbering at 1; the mark beside it says what was issued.
    @Test func aMissingIdFileWithAHighWaterMarkStartsAboveTheMark() async throws {
        let path = tempPath()
        var before = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try await mint(&before) == "e1")
        try FileManager.default.removeItem(atPath: path)
        var after = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try await mint(&after) == "e11")
        #expect(after.isFromEarlierIncarnation("e1"))
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// The mark is the highest number of any kind, written only when a block raises it, and rebuilt from a valid
    /// id file when it is the one that can't be read.
    @Test func theHighWaterMarkCoversEveryKindAndIsRepairedFromAValidIdFile() async throws {
        let path = tempPath()
        let blocks = IDBlocks(path: path)
        var e = IDCounter(prefix: "e", blocks: blocks, blockSize: 10)
        var c = IDCounter(prefix: "c", blocks: blocks, blockSize: 5)
        _ = try await mint(&e)
        #expect(IDBlocks.loadHighWater(path) == .mark(10))
        _ = try await mint(&c)
        #expect(IDBlocks.loadHighWater(path) == .mark(10), "a lower block of another kind doesn't lower or rewrite the mark")
        for _ in 0..<10 { _ = try await mint(&e) }
        #expect(IDBlocks.loadHighWater(path) == .mark(20))
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: IDBlocks.highWaterPath(path)))
        for _ in 0..<5 { _ = try await mint(&c) }   // c6: the id file is valid, so the mark is rebuilt from it
        #expect(IDBlocks.load(path) == .marks(["e": 20, "c": 10]))
        #expect(IDBlocks.loadHighWater(path) == .mark(20))
        // A recovery then restarts above the rebuilt mark.
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        var s = IDCounter(prefix: "s", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try await mint(&s) == "s21")
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// The directory is synced after the rename (a power loss can't be arranged in a test; this checks the step
    /// runs and reports a directory it can't open).
    @Test func theDirectoryIsSyncedAfterTheRename() async throws {
        let path = tempPath()
        var counter = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        _ = try await mint(&counter)
        #expect(throws: Never.self) { try IDBlocks.syncDirectory(containing: path) }
        #expect(throws: (any Error).self) { try IDBlocks.syncDirectory(containing: tempDir() + "/missing/ids.json") }
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Two allocators on one file whose lifetimes overlap (a second agent instance on another socket): neither may
    /// hand out a block the other already took, and neither may write back marks older than the other's.
    @Test func overlappingAllocatorsNeverShareABlock() async throws {
        let path = tempPath()
        var a = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        var b = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try await mint(&a) == "e1")
        #expect(try await mint(&b) == "e11", "b reads a's reservation")
        for _ in 0..<9 { _ = try await mint(&a) }
        #expect(try await mint(&a) == "e21", "a's next block is above b's, not a repeat of it from a cached mark")
        for _ in 0..<9 { _ = try await mint(&b) }
        #expect(try await mint(&b) == "e31")
        var c = IDCounter(prefix: "e", blocks: IDBlocks(path: path), blockSize: 10)
        #expect(try await mint(&c) == "e41", "the file holds the newest mark, not one overwritten by an older copy")
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    @Test func concurrentReservationsFromSeveralAllocatorsAreDisjoint() async throws {
        let path = tempPath()
        let blocks = try await withThrowingTaskGroup(of: [ClosedRange<Int>].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let allocator = IDBlocks(path: path)
                    var mine: [ClosedRange<Int>] = []
                    for _ in 0..<8 { mine.append(try await allocator.reserve("e", size: 25)) }
                    return mine
                }
            }
            var all: [ClosedRange<Int>] = []
            for try await part in group { all += part }
            return all
        }
        let sorted = blocks.sorted { $0.lowerBound < $1.lowerBound }
        #expect(sorted.count == 32)
        for (x, y) in zip(sorted, sorted.dropFirst()) { #expect(!x.overlaps(y), "\(x) and \(y) overlap") }
        #expect(sorted.first?.lowerBound == 1 && sorted.last?.upperBound == 800)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}

// MARK: D3 — screenshot pixels are checked when the action runs

@Suite struct PixelTargetTests {
    let window = ScreenshotMapping.CapturedWindow(id: 77, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
    func windows(at origin: CGPoint) -> [WindowInfo] {
        [WindowInfo(id: 77, pid: 7, owner: "Host", title: "", layer: 0, bounds: CGRect(origin: origin, size: CGSize(width: 400, height: 300)), alpha: 1)]
    }

    @Test func parsingKeepsThePixelsAndTheScreenshotId() throws {
        guard case let .pixel(id, px) = try Actions.target(ref: nil, x: 10, y: 20, screenshotID: "c3") else {
            Issue.record("expected a pixel target"); return
        }
        #expect(id == "c3" && px == CGPoint(x: 10, y: 20))
        guard case let .point(p) = try Actions.target(ref: nil, x: 10, y: 20, screenshotID: nil) else {
            Issue.record("expected a point target"); return
        }
        #expect(p == CGPoint(x: 10, y: 20))
        guard case let .ref(r) = try Actions.target(ref: "e4", x: nil, y: nil, screenshotID: nil) else {
            Issue.record("expected a ref target"); return
        }
        #expect(r == "e4")
        #expect(throws: ActionError.self) { try Actions.target(ref: nil, x: 10, y: nil, screenshotID: nil) }
    }

    @Test func conversionSeesTheWindowAsItIsAtActionTime() async throws {
        let store = ScreenshotStore()
        let id = try await store.record(ScreenshotMapping(source: window.frame, pixelSize: CGSize(width: 800, height: 600), window: window))
        let p = try await Actions.point(ofPixel: CGPoint(x: 400, y: 300), screenshot: id, store: store, windows: windows(at: CGPoint(x: 100, y: 100)))
        #expect(p == CGPoint(x: 300, y: 250))
        // The window moved after the screenshot (another action ran first): refuse rather than click elsewhere.
        await #expect(throws: ActionError.self) {
            try await Actions.point(ofPixel: CGPoint(x: 400, y: 300), screenshot: id, store: store, windows: windows(at: CGPoint(x: 160, y: 100)))
        }
        do {
            _ = try await Actions.point(ofPixel: CGPoint(x: 400, y: 300), screenshot: id, store: store, windows: [])
            Issue.record("a gone window should refuse")
        } catch {
            #expect("\(error)".contains("is gone"))
        }
        do {
            _ = try await Actions.point(ofPixel: CGPoint(x: 800, y: 0), screenshot: id, store: store, windows: windows(at: CGPoint(x: 100, y: 100)))
            Issue.record("a pixel outside the image should refuse")
        } catch {
            #expect("\(error)".contains("outside screenshot"))
        }
        do {
            _ = try await Actions.point(ofPixel: .zero, screenshot: "c999", store: store, windows: [])
            Issue.record("an unknown id should refuse")
        } catch {
            #expect("\(error)".contains("Unknown screenshot_id c999"))
        }
    }

    /// A screenshot target resolved while its app was in the background is converted again after the app is
    /// activated: an app that moves or resizes its window on activation must be refused, not clicked at the point
    /// worked out before.
    @Test func aScreenshotTargetIsConvertedAfterActivationNotBefore() async throws {
        let store = ScreenshotStore()
        let id = try await store.record(ScreenshotMapping(source: window.frame, pixelSize: CGSize(width: 800, height: 600), window: window))
        // Resolution, before activation: the window is where the screenshot saw it.
        let resolved = Resolved(pid: 7, element: nil, row: nil,
                                point: try await Actions.point(ofPixel: CGPoint(x: 400, y: 300), screenshot: id, store: store,
                                                               windows: windows(at: CGPoint(x: 100, y: 100))),
                                pixel: PixelTarget(screenshot: id, pixel: CGPoint(x: 400, y: 300)))
        #expect(resolved.point == CGPoint(x: 300, y: 250))
        // Activation moves the window (the app restores its saved position).
        var current = windows(at: CGPoint(x: 100, y: 100))
        var activated = false
        await #expect(throws: ActionError.self) {
            _ = try await Actions.activatedPoint(resolved, store: store, windows: { current }) {
                activated = true
                current = windows(at: CGPoint(x: 160, y: 100))
            }
        }
        #expect(activated)
        // When activation changes nothing, the point stands.
        current = windows(at: CGPoint(x: 100, y: 100))
        let p = try await Actions.activatedPoint(resolved, store: store, windows: { current }) {}
        #expect(p == CGPoint(x: 300, y: 250))
        // A plain point target has no pixels to re-check.
        let plain = Resolved(pid: 7, element: nil, row: nil, point: CGPoint(x: 5, y: 6))
        #expect(try await Actions.activatedPoint(plain, store: store, windows: { [] }) {} == CGPoint(x: 5, y: 6))
    }
}

// MARK: D5 — an incomplete walk can't prove a row disappeared

@Suite struct IncompleteDiffTests {
    func row(_ ref: String?, _ role: String, _ label: String) -> Row {
        Row(kind: ref == nil ? .text : .interactive, role: role, label: label, value: nil, states: [], frame: nil,
            depth: 0, ref: ref, fingerprint: "")
    }

    @Test func disappearedLinesAreLeftOutWhenAsked() {
        let before = [row("e1", "button", "Old"), row("e2", "button", "Same"), row(nil, "text", "Gone text")]
        let after = [row("e2", "button", "Renamed"), row("e3", "button", "New"), row(nil, "text", "New text")]
        let full = Diff.compute(before: before, after: after)
        #expect(full.lines == ["~ e2 button \"Renamed\": label \"Same\" → \"Renamed\"", "+ e3 button \"New\"",
                               "- e1 button \"Old\"", "+ text \"New text\"", "- text \"Gone text\""])
        #expect(full.refs == ["e2", "e3"])
        let partial = Diff.compute(before: before, after: after, showDisappeared: false)
        #expect(partial.lines == ["~ e2 button \"Renamed\": label \"Same\" → \"Renamed\"", "+ e3 button \"New\"", "+ text \"New text\""])
        #expect(partial.refs == ["e2", "e3"])
        #expect(Diff.lines(before: before, after: after) == full.lines)
    }

    @Test func refsPastTheLineCapAreNotCountedAsShown() {
        let after = (0..<40).map { row("e\($0)", "button", "B\($0)") }
        let r = Diff.compute(before: [], after: after, maxLines: 10)
        #expect(r.lines.count == 11 && r.refs.count == 10 && r.refs.last == "e9")
    }
}

// MARK: D4 — an identity the walk couldn't vouch for is unknown, not unchanged

/// A synthetic tree whose reads can fail: a whole node, or one attribute of it (the error an app returns for a
/// single attribute, which the value alone can't tell from an absent one). `failed` attributes answer
/// `cannotComplete`; `errors` answer the given error; `transient` ones answer it only the first time they are read,
/// like an app whose "failure" is a passing one. Row reads (`AXVisibleRows`, `AXRows`) can fail too.
private final class FaultyTree: Sendable {
    struct Node: Sendable {
        var values: [String: String]
        var errors: [String: AXError] = [:]
        var transient: Set<String> = []
        var readFails = false
        var children: [Int32] = []
        var rows: [Int32]? = nil
        var rowsFail = false
        var titleElement: Int32?
    }
    private let nodes = Mutex<[Int32: Node]>([:])
    /// Every read made, as (node, attributes): the retry budget is one extra read, so tests can count them.
    let reads = Mutex<[(Int32, [String])]>([])
    private let seen = Mutex<Set<String>>([])
    static func element(_ n: Int32) -> AXElement { AXElement.application(pid: 400_000 + n) }
    private func lookup(_ el: AXElement) -> (Int32, Node)? {
        nodes.withLock { nodes in nodes.first { Self.element($0.key) == el }.map { ($0.key, $0.value) } }
    }

    func add(_ n: Int32, role: String, title: String? = nil, value: String? = nil, failed: Set<String> = [],
             errors: [String: AXError] = [:], transient: Set<String> = [], readFails: Bool = false, children: [Int32] = [],
             rows: [Int32]? = nil, rowsFail: Bool = false, titleElement: Int32? = nil) {
        var values = ["AXRole": role]
        if let title { values["AXTitle"] = title }
        if let value { values["AXValue"] = value }
        var all = errors
        for name in failed { all[name] = .cannotComplete }
        nodes.withLock {
            $0[n] = Node(values: values, errors: all, transient: transient, readFails: readFails, children: children,
                         rows: rows, rowsFail: rowsFail, titleElement: titleElement)
        }
    }

    /// The error a node answers for an attribute now: a transient one only the first time.
    private func error(_ n: Int32, _ node: Node, _ name: String) -> AXError? {
        guard let e = node.errors[name] else { return nil }
        guard node.transient.contains(name) else { return e }
        return seen.withLock { $0.insert("\(n)/\(name)").inserted } ? e : nil
    }

    var source: Walker.Source {
        Walker.Source(read: { [self] el, names in
            guard let (n, node) = lookup(el) else { return nil }
            reads.withLock { $0.append((n, names)) }
            guard !node.readFails else { return nil }
            var dict = node.values.mapValues { $0 as Any }
            dict["AXChildren"] = node.children.map { Self.element($0).raw }
            var errors: [String: AXError] = [:]
            for name in names { if let e = error(n, node, name) { errors[name] = e; dict[name] = nil } }
            return AXElement.Read(values: dict.filter { names.contains($0.key) }, errors: errors)
        }, attributeRead: { [self] el, name in
            guard let (n, node) = lookup(el) else { return (nil, nil) }
            reads.withLock { $0.append((n, [name])) }
            if let e = error(n, node, name) { return (nil, e) }
            if name == "AXTitleUIElement", let t = node.titleElement { return (Self.element(t).raw, nil) }
            return (node.values[name], nil)
        }, elements: { [self] el, name in
            guard let (_, node) = lookup(el) else { return ([], nil) }
            if node.rowsFail { return ([], .cannotComplete) }
            if name == "AXVisibleRows" || name == "AXRows", let rows = node.rows { return (rows.map(Self.element), nil) }
            return ([], nil)
        })
    }

    func walk(maxNodes: Int = 5000, clip: CGRect? = nil) -> (RawNode, WalkStats) {
        var options = Walker.Options()
        options.maxNodes = maxNodes
        options.clip = clip
        options.source = source
        return Walker.walk(Self.element(1), options: options)
    }
}

@Suite struct IdentityReadTests {
    /// The scenario from the review: an unnamed control was shown with no identifier; its re-read fails or is cut and
    /// again yields an empty label and no identifier. Equal empties must not count as unchanged when the read was
    /// uncertain, while the same read of a control that really is unnamed still passes.
    @Test func anUncertainReadThatComesBackEmptyIsRefusedEvenWhenTheControlWasShownUnnamed() {
        let unnamed = RefStore.Shown(label: "", identifier: nil)
        let refused = RefStore.changeMessage(ref: "e3", role: "button", shown: unnamed, label: "", identifier: nil, complete: false)
        #expect(refused?.contains("couldn't be fully re-read") == true)
        #expect(RefStore.changeMessage(ref: "e3", role: "button", shown: unnamed, label: "", identifier: nil, complete: true) == nil,
                "a complete read of an unnamed control is the control the agent saw")
        // A name that did come back and matches is evidence enough, even from a read that was cut elsewhere.
        let named = RefStore.Shown(label: "Save", identifier: nil)
        #expect(RefStore.changeMessage(ref: "e4", role: "button", shown: named, label: "Save", identifier: nil, complete: false) == nil)
        // A lost identifier from an uncertain read is uncertain, not "a different element".
        let identified = RefStore.Shown(label: "", identifier: "save")
        #expect(RefStore.changeMessage(ref: "e5", role: "button", shown: identified, label: "", identifier: nil, complete: false)?
            .contains("couldn't be fully re-read") == true)
    }

    /// Per-attribute failures of the label sources and identifier mark the node (and the ancestors whose label its
    /// text could have fed) as uncertain, and count against the walk's completeness. Absent attributes, failed state
    /// values and failures elsewhere in the tree leave ordinary rows alone.
    @Test func failedLabelSourcesMarkTheirRowsUncertainAndOrdinaryRowsStayCertain() throws {
        let t = FaultyTree()
        t.add(1, role: "AXWindow", title: "Form", children: [2, 3, 4, 8, 9, 10, 12])
        t.add(2, role: "AXButton", title: "Save")
        t.add(3, role: "AXButton", failed: ["AXTitle"])                          // the title read failed
        t.add(4, role: "AXRow", children: [5])                                   // a row named by its cells…
        t.add(5, role: "AXCell", children: [6, 7])
        t.add(6, role: "AXStaticText", value: "Item 1")
        t.add(7, role: "AXStaticText", readFails: true)                          // …one of which didn't read
        t.add(8, role: "AXButton")                                               // unnamed, read whole
        t.add(9, role: "AXPopUpButton", title: "Size", failed: ["AXValue"])      // a popup's value is never its label
        t.add(10, role: "AXButton", titleElement: 11)                            // named by a label element…
        t.add(11, role: "AXStaticText", failed: ["AXValue", "AXTitle"])          // …whose text didn't read
        t.add(12, role: "AXCheckBox", title: "Bacon", failed: ["AXValue"])       // a state, not a label
        let (tree, stats) = t.walk()
        #expect(stats.readFailures == 1 && stats.identityReadFailures == 2 && !stats.complete)
        #expect(tree.identityUncertain, "the window's own label could have come from the text that didn't read")
        let rows = Snapshot.rows(from: tree, pid: 7).filter { $0.kind == .interactive }
        func row(_ n: Int32) -> Row { rows.first { $0.element == FaultyTree.element(n) }! }
        #expect(!row(2).identityUncertain && row(2).label == "Save")
        #expect(row(3).identityUncertain && row(3).label == "")
        #expect(row(4).identityUncertain && row(4).label == "Item 1", "a cell that didn't read may have held more of the name")
        #expect(!row(8).identityUncertain && row(8).label == "", "an absent title is an unnamed control, not a failed read")
        #expect(!row(9).identityUncertain && !row(12).identityUncertain, "values that are never labels don't matter")
        #expect(row(10).identityUncertain && row(10).label == "")
        // What resolve decides from these rows: only the uncertain empties are refused.
        let unnamed = RefStore.Shown(label: "", identifier: nil)
        for n: Int32 in [3, 10] {
            let r = row(n)
            #expect(RefStore.changeMessage(ref: "e\(n)", role: r.role, shown: unnamed, label: r.label, identifier: r.identifier,
                                           complete: !r.identityUncertain) != nil, "e\(n) read as unnamed but the read failed")
        }
        let r8 = row(8)
        #expect(RefStore.changeMessage(ref: "e8", role: r8.role, shown: unnamed, label: r8.label, identifier: r8.identifier,
                                       complete: !r8.identityUncertain) == nil, "e8 is unnamed and was read whole")
        let r4 = row(4)
        #expect(RefStore.changeMessage(ref: "e4", role: r4.role, shown: .init(label: "Item 1", identifier: nil), label: r4.label,
                                       identifier: r4.identifier, complete: !r4.identityUncertain) == nil,
                "a name that came back and matches is accepted from an uncertain read")
    }

    /// A walk cut short marks only the nodes still open at the cut, so a row finished before the budget ran out is
    /// certain while the row the cut landed in is not.
    @Test func aCutMarksOnlyTheNodesItLandedIn() {
        let t = FaultyTree()
        t.add(1, role: "AXWindow", title: "Items", children: [20, 30])
        t.add(20, role: "AXRow", children: [21]); t.add(21, role: "AXCell", children: [22]); t.add(22, role: "AXStaticText", value: "A")
        t.add(30, role: "AXRow", children: [31]); t.add(31, role: "AXCell", children: [32, 33, 34])
        t.add(32, role: "AXStaticText", value: "B1"); t.add(33, role: "AXStaticText", value: "B2"); t.add(34, role: "AXStaticText", value: "B3")
        let (tree, stats) = t.walk(maxNodes: 8)   // window, row A (3 nodes), row B, its cell, B1, B2: B3 is cut
        #expect(stats.truncation == .nodes && stats.identityReadFailures == 0)
        let rows = Snapshot.rows(from: tree, pid: 7).filter { $0.kind == .interactive }
        let a = rows.first { $0.element == FaultyTree.element(20) }!
        let b = rows.first { $0.element == FaultyTree.element(30) }!
        #expect(!a.identityUncertain && a.label == "A")
        #expect(b.identityUncertain && b.label == "B1 | B2", "the cut took B3 out of row B's name")
        let (whole, wholeStats) = t.walk()
        #expect(wholeStats.complete && !whole.identityUncertain)
        #expect(Snapshot.rows(from: whole, pid: 7).filter { $0.kind == .interactive }.allSatisfy { !$0.identityUncertain })
    }

    /// Children that couldn't be enumerated, and a placeholder or help that didn't read, are failed label sources:
    /// an unnamed button whose text lives in its children, a field named by its placeholder and a control named by
    /// its help are all uncertain, and the missing subtree counts against the walk.
    @Test func failedChildrenPlaceholderAndHelpReadsLeaveTheLabelUnknown() throws {
        let t = FaultyTree()
        t.add(1, role: "AXWindow", title: "Form", children: [2, 3, 4, 5])
        t.add(2, role: "AXButton", failed: ["AXChildren"])              // its text, if any, is in children it didn't deliver
        t.add(3, role: "AXTextField", failed: ["AXPlaceholderValue"])   // a field is named by its placeholder
        t.add(4, role: "AXButton", failed: ["AXHelp"])                  // the last label source
        t.add(5, role: "AXButton", title: "Save")
        let (tree, stats) = t.walk()
        #expect(stats.readFailures == 1, "children that couldn't be enumerated are a hole in the tree")
        #expect(stats.identityReadFailures == 3 && stats.textReadFailures == 3)
        #expect(!stats.complete && !stats.textComplete)
        #expect(tree.identityUncertain && tree.textUncertain, "the window's own label could have come from the children that didn't read")
        let rows = Snapshot.rows(from: tree, pid: 7).filter { $0.kind == .interactive }
        func row(_ n: Int32) -> Row { rows.first { $0.element == FaultyTree.element(n) }! }
        for n: Int32 in [2, 3, 4] {
            #expect(row(n).identityUncertain && row(n).label == "", "e\(n) read as unnamed but a label source failed")
            #expect(RefStore.changeMessage(ref: "e\(n)", role: row(n).role, shown: .init(label: "", identifier: nil), label: "",
                                           identifier: nil, complete: !row(n).identityUncertain)?.contains("couldn't be fully re-read") == true)
        }
        #expect(!row(5).identityUncertain && row(5).label == "Save")
    }

    /// A list or table whose rows couldn't be read falls back to its children, which hold the rows too; only a
    /// container with nothing to fall back on is a hole.
    @Test func unreadableRowsAreAHoleOnlyWithoutChildrenToFallBackOn() throws {
        let t = FaultyTree()
        t.add(1, role: "AXWindow", title: "Items", children: [2, 3, 7])
        t.add(2, role: "AXTable", rowsFail: true)                         // no children either: whatever it lists is unknown
        t.add(3, role: "AXTable", children: [4], rowsFail: true)          // the children hold the rows
        t.add(4, role: "AXRow", children: [5]); t.add(5, role: "AXCell", children: [6]); t.add(6, role: "AXStaticText", value: "Item 1")
        t.add(7, role: "AXTable", rows: [8])                              // rows read, with no children: walked all the same
        t.add(8, role: "AXRow", children: [9]); t.add(9, role: "AXCell", children: [10]); t.add(10, role: "AXStaticText", value: "Item 2")
        let (tree, stats) = t.walk()
        #expect(stats.readFailures == 1 && !stats.textComplete)
        let labels = Snapshot.rows(from: tree, pid: 7).filter { $0.kind == .interactive }.map(\.label)
        #expect(labels == ["Item 1", "Item 2"], "\(labels)")
        // With rows that read, the same tree is whole; the hole is the failure, not the fallback.
        let whole = FaultyTree()
        whole.add(1, role: "AXWindow", title: "Items", children: [2, 3])
        whole.add(2, role: "AXTable", rows: [])
        whole.add(3, role: "AXTable", children: [4])
        whole.add(4, role: "AXRow", children: [5]); whole.add(5, role: "AXCell", children: [6]); whole.add(6, role: "AXStaticText", value: "Item 1")
        let (_, wholeStats) = whole.walk()
        #expect(wholeStats.complete && wholeStats.textComplete)
    }

    /// Text and identity are judged apart: an identifier that failed to read makes a ref uncertain but can't hide
    /// text, so the walk can still prove absence; a popup's value that failed to read is searchable text, so it
    /// can't, while the popup's own name is not in doubt. A tree with absent attributes and no failures is whole
    /// on both counts, so ordinary refs and waits aren't refused more often.
    @Test func failedIdentifiersAndFailedShownValuesAreKeptApart() throws {
        let t = FaultyTree()
        t.add(1, role: "AXWindow", title: "Form", children: [2, 3])
        t.add(2, role: "AXButton", title: "Save", failed: ["AXIdentifier"])
        t.add(3, role: "AXButton")
        let (tree, stats) = t.walk()
        #expect(stats.identityReadFailures == 1 && stats.textReadFailures == 0)
        #expect(!stats.complete && stats.textComplete)
        #expect(tree.identityUncertain && !tree.textUncertain)
        let rows = Snapshot.rows(from: tree, pid: 7).filter { $0.kind == .interactive }
        #expect(rows[0].identityUncertain && !rows[1].identityUncertain)

        let popup = FaultyTree()
        popup.add(1, role: "AXWindow", title: "Form", children: [2])
        popup.add(2, role: "AXPopUpButton", title: "Size", failed: ["AXValue"])
        let (popupTree, popupStats) = popup.walk()
        #expect(popupStats.identityReadFailures == 0 && popupStats.textReadFailures == 1)
        #expect(!popupStats.textComplete && popupTree.textUncertain && !popupTree.identityUncertain)
        #expect(!Snapshot.rows(from: popupTree, pid: 7).filter { $0.kind == .interactive }[0].identityUncertain)

        let plain = FaultyTree()
        plain.add(1, role: "AXWindow", children: [2, 3, 4])
        plain.add(2, role: "AXButton")
        plain.add(3, role: "AXTable", children: [])
        plain.add(4, role: "AXTextField")
        let (plainTree, plainStats) = plain.walk()
        #expect(plainStats.complete && plainStats.textComplete && !plainTree.identityUncertain && !plainTree.textUncertain)
        #expect(Snapshot.rows(from: plainTree, pid: 7).allSatisfy { !$0.identityUncertain })
    }

    /// Some apps answer kAXErrorFailure for attributes they don't have. One re-read of the doubtful identity
    /// attributes (batched) or of a title element tells a passing failure from a real one; the retry is one read,
    /// and a read the app couldn't complete isn't repeated.
    @Test func aFailureAnsweredForAnIdentityAttributeIsReReadOnce() throws {
        let t = FaultyTree()
        t.add(1, role: "AXWindow", title: "Form", children: [2, 3, 4, 5, 6])
        t.add(2, role: "AXButton", title: "Save", errors: ["AXDescription": .failure, "AXHelp": .failure], transient: ["AXDescription", "AXHelp"])
        t.add(3, role: "AXButton", title: "Discard", errors: ["AXIdentifier": .failure])                     // fails again: believed
        t.add(4, role: "AXButton", title: "Later", errors: ["AXDescription": .cannotComplete], transient: ["AXDescription"])
        t.add(5, role: "AXButton", errors: ["AXTitleUIElement": .failure], transient: ["AXTitleUIElement"], titleElement: 7)
        t.add(6, role: "AXButton", title: "Keep", errors: ["AXEnabled": .failure], transient: ["AXEnabled"])   // can't hide a label: not re-read
        t.add(7, role: "AXStaticText", value: "Name")
        let (tree, stats) = t.walk()
        let rows = Snapshot.rows(from: tree, pid: 7).filter { $0.kind == .interactive }
        func row(_ n: Int32) -> Row { rows.first { $0.element == FaultyTree.element(n) }! }
        #expect(!row(2).identityUncertain, "a failure that passes on re-read is an absent attribute")
        #expect(row(3).identityUncertain, "a failure that repeats is a failed read")
        #expect(row(4).identityUncertain, "a read the app couldn't complete is not repeated")
        #expect(row(5).label == "Name" && !row(5).identityUncertain, "the title element is re-read once too")
        #expect(!row(6).identityUncertain)
        #expect(stats.identityReadFailures == 2 && stats.textReadFailures == 1)
        let reads = t.reads.withLock { $0 }
        func batches(_ n: Int32) -> [[String]] { reads.filter { $0.0 == n && $0.1 != ["AXTitleUIElement"] }.map(\.1) }
        #expect(batches(2).count == 2 && batches(2).last == ["AXDescription", "AXHelp"], "one batched re-read of only the doubtful attributes")
        #expect(batches(3).count == 2 && batches(3).last == ["AXIdentifier"])
        #expect(batches(4).count == 1 && batches(6).count == 1)
        #expect(reads.filter { $0.0 == 5 && $0.1 == ["AXTitleUIElement"] }.count == 2)
    }

    /// The snapshot says when labels or values couldn't be read, apart from nodes that couldn't be read at all.
    @Test func snapshotNotesSayWhenLabelsCouldNotBeRead() {
        var stats = WalkStats()
        stats.textReadFailures = 2
        #expect(Snapshotter.walkNotes(stats, omitted: 0) == ["the labels or values of 2 elements could not be read: some text may be missing"])
        stats.readFailures = 1
        #expect(Snapshotter.walkNotes(stats, omitted: 0).count == 2)
        #expect(Snapshotter.walkNotes(WalkStats(), omitted: 0).isEmpty)
    }

    /// Which per-attribute errors are failures: an app that says "unsupported" or "no value" has nothing to deliver;
    /// one that can't complete, or fails, may have a value it didn't deliver.
    @Test func absentAttributesAreNotFailedReads() {
        func value(_ e: AXError) -> AXValue { var e = e; return AXValueCreate(.axError, &e)! }
        for absent in [AXError.attributeUnsupported, .noValue, .notImplemented] { #expect(!AXElement.isFailure(value(absent))) }
        for failed in [AXError.cannotComplete, .failure, .apiDisabled, .invalidUIElement, .illegalArgument] {
            #expect(AXElement.isFailure(value(failed)), "\(failed.rawValue) should count as a failed read")
        }
        #expect(!AXElement.isFailure("a string" as AnyObject) && !AXElement.isFailure(nil))
        var p = CGPoint.zero
        #expect(!AXElement.isFailure(AXValueCreate(.cgPoint, &p)))
        let unsupported = AXElement.Read(values: ["AXRole": "AXButton"])
        #expect(unsupported.failed.isEmpty)
        #expect(AXElement.failure(in: value(.failure)) == .failure && AXElement.failure(in: value(.noValue)) == nil)
    }
}
