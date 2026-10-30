import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

private final class KeyTape: @unchecked Sendable {
    struct Event { let type: CGEventType; let point: CGPoint; let key: Int64 }
    private let lock = NSLock()
    private var events: [Event] = []
    var all: [Event] { lock.withLock { events } }
    var keys: [Int64] { all.filter { $0.type == .keyDown }.map(\.key) }
    func post(_ event: CGEvent) {
        lock.withLock { events.append(Event(type: event.type, point: event.location, key: event.getIntegerValueField(.keyboardEventKeycode))) }
    }
}

/// Runs a mac_key call against a fake desktop whose selection context (Finder, a file panel, an open menu) is
/// `context(index of the key being checked)`, with the real per-key sequence rule. Returns the posted key codes.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

private func press(_ text: String, repeat count: Int = 1, context: @escaping @Sendable (Int) -> Bool) async throws -> [Int64] {
    let tape = KeyTape()
    try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.post($0) })) {
        try await ActionRoute.$check.withValue({ step in
            guard case .key = step, let sequence = ActionRoute.keySequence else { return }
            if let r = OpenRoutes.selectionSequenceRefusal(sequence, selectionContext: { context(sequence.index) }) { throw ActionError(r) }
        }) {
            try await Actions.press(try KeySpec.parseSequence(text), repeat: count, pid: 42)
        }
    }
    return tape.keys
}

@Suite struct InputFinalReviewTests {
    // MARK: 1. Finder: a key acting on the selection after another key

    /// These used to pass: only committing keys after the first were refused, so ⌘⌫ and ⌘C ran on a selection their
    /// check read before the earlier key took effect (with hidden files shown, ~/.ssh could go to the Trash).
    @Test(arguments: ["cmd+a, cmd+delete", "down, cmd+delete", "down, cmd+c", "down, delete", "down, forwarddelete",
                      "down, cmd+v", "down, return", "down, space", "down, a", "shift+down, cmd+i", "tab, tab"])
    func inFinderASelectionKeyAfterAnotherIsRefusedBeforeAnyKeyIsPosted(_ text: String) async throws {
        let keys = try KeySpec.parseSequence(text)
        let sequence = ActionRoute.KeySequence(keys: keys, index: 0)
        #expect(OpenRoutes.selectionSequenceRefusal(sequence, selectionContext: { true }) != nil)
        let tape = KeyTape()
        let error = await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.post($0) })) {
                try await ActionRoute.$check.withValue({ step in
                    guard case .key = step, let sequence = ActionRoute.keySequence else { return }
                    if let r = OpenRoutes.selectionSequenceRefusal(sequence, selectionContext: { true }) { throw ActionError(r) }
                }) { try await Actions.press(keys, repeat: 1, pid: 42) }
            }
        }
        #expect(error?.description.contains("first in its mac_key call") == true)
        #expect(tape.all.isEmpty)
    }

    @Test func aRepeatedSelectionKeyIsRefusedInFinder() async throws {
        for (text, count) in [("cmd+delete", 2), ("down", 1), ("return", 2)] {
            let error = await #expect(throws: ActionError.self) { _ = try await press(text + ", cmd+c", repeat: count) { _ in true } }
            #expect(error?.description.contains("first in its mac_key call") == true, "\(text)")
        }
    }

    /// One key that acts on the selection, first in its call, still goes, checked just before it; so does navigation
    /// and type-select.
    @Test(arguments: ["cmd+delete", "cmd+c", "return", "space", "down down", "shift+down shift+down", "a, p, p", "esc, esc",
                      "cmd+delete, down"])
    func inFinderOneSelectionKeyFirstAndNavigationStillGo(_ text: String) async throws {
        let keys = try KeySpec.parseSequence(text)
        #expect(try await press(text) { _ in true }.count == keys.count)
    }

    /// The context is read again at each key: a panel or menu that appears mid-call stops the next selection key there.
    @Test func aSelectionContextThatAppearsMidCallStopsTheNextSelectionKey() async throws {
        let posted = KeyTape()
        let error = await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { posted.post($0) })) {
                try await ActionRoute.$check.withValue({ step in
                    guard case .key = step, let sequence = ActionRoute.keySequence else { return }
                    let context = sequence.index > 0
                    if let r = OpenRoutes.selectionSequenceRefusal(sequence, selectionContext: { context }) { throw ActionError(r) }
                }) { try await Actions.press(try KeySpec.parseSequence("tab, return"), repeat: 1, pid: 42) }
            }
        }
        #expect(error?.description.contains("first in its mac_key call") == true)
        #expect(posted.keys == [48])
    }

    // MARK: 2. Tab, Space and Return elsewhere

    /// These were refused in every app.
    @Test(arguments: [("tab, return", 1), ("tab tab", 1), ("tab", 3), ("shift+tab, shift+tab", 1), ("space", 2),
                      ("shift+space", 2), ("cmd+a, delete", 1), ("down, return", 1), ("a, b, return", 1),
                      ("cmd+a, cmd+c, return", 1), ("tab, space", 1)])
    func outsideASelectionContextTabSpaceAndReturnSequencesAreOrdinaryInput(_ text: String, _ count: Int) async throws {
        let keys = try KeySpec.parseSequence(text)
        #expect(OpenRoutes.keySequenceRefusal(keys, repeat: count) == nil)
        #expect(try await press(text, repeat: count) { _ in false }.count == keys.count * count)
    }

    @Test func selectionKeysAreKnown() throws {
        func acts(_ text: String) throws -> Bool {
            let keys = try KeySpec.parseSequence(text)
            return OpenRoutes.actsOnSelection(in: keys, at: keys.count - 1)
        }
        for text in ["down, cmd+c", "down, delete", "down, forwarddelete", "down, cmd+v", "down, return", "down, enter",
                     "down, space", "down, tab", "down, a", "down, cmd+o", "down, cmd+down"] {
            #expect(try acts(text), "\(text)")
        }
        for text in ["down, down", "a, b", "down, esc", "down, shift+up", "down, pagedown"] { #expect(try !acts(text), "\(text)") }
    }

    // MARK: 3. Services hotkeys

    /// An app's own menu command runs before a Service with the same keys: Finder's ⇧⌘A (Go to Applications) is
    /// fine, though Terminal's man-page Service declares it and macOS enables it by default.
    @Test func anAppsOwnMenuShortcutWinsOverAServiceKey() throws {
        let terminal = try KeySpec.parse("shift+cmd+a")
        #expect(OpenRoutes.launcherKeyRefusal([terminal], policy: Policy(denyApps: []), hotkeys: [], serviceKeys: [terminal]) != nil)
        #expect(OpenRoutes.launcherKeyRefusal([terminal], policy: Policy(denyApps: []), hotkeys: [], serviceKeys: [terminal],
                                              appDefines: { $0 == terminal }) == nil)
        // Spotlight's hotkey is the system's, not the app's.
        let spotlight = try KeySpec.parse("cmd+space")
        #expect(OpenRoutes.launcherKeyRefusal([spotlight], policy: Policy(), hotkeys: [spotlight], serviceKeys: [], appDefines: { _ in true }) != nil)
    }

    /// AX reports a menu letter in capitals whether or not shift is part of it; only the modifier bits say.
    @Test func menuKeyEquivalentsComeFromTheirModifierBits() throws {
        #expect(OpenRoutes.menuKey(character: "A", modifiers: 1, virtualKey: nil) == (try KeySpec.parse("shift+cmd+a")))
        #expect(OpenRoutes.menuKey(character: "A", modifiers: 0, virtualKey: 0) == (try KeySpec.parse("cmd+a")))
        #expect(OpenRoutes.menuKey(character: "M", modifiers: 2 | 4, virtualKey: nil) == (try KeySpec.parse("ctrl+alt+cmd+m")))
        #expect(OpenRoutes.menuKey(character: "A", modifiers: 8, virtualKey: nil) == (try KeySpec.parse("a")))
        #expect(OpenRoutes.menuKey(character: nil, modifiers: 0, virtualKey: 125) == (try KeySpec.parse("cmd+down")))
        #expect(OpenRoutes.menuKey(character: nil, modifiers: nil, virtualKey: 125) == nil)
        #expect(OpenRoutes.menuKey(character: "", modifiers: 0, virtualKey: 0) == nil)
    }

    /// An incomplete scan used to refuse every key. It now adds the system Services' keys.
    @Test func anIncompleteScanFallsBackToKnownKeysInsteadOfRefusingEverything() throws {
        let keys = ServiceHotkeys.serviceKeys(status: [:], services: [], complete: false)
        #expect(!keys.contains { ServiceHotkeys.matches($0, try! KeySpec.parse("cmd+s")) })
        for text in ["shift+cmd+m", "shift+cmd+a", "shift+cmd+l", "shift+cmd+y", "shift+cmd+8"] {
            #expect(keys.contains { ServiceHotkeys.matches($0, try! KeySpec.parse(text)) }, "\(text)")
        }
        #expect(ServiceHotkeys.serviceKeys(status: [:], services: [], complete: true).isEmpty)
        #expect(ServiceHotkeys.equivalent("*") == (try KeySpec.parse("shift+cmd+8")))
        #expect(ServiceHotkeys.equivalent("@?") == (try KeySpec.parse("shift+cmd+slash")))
    }

    /// The scan reads bundles in a root and its folders, not inside bundles or deeper, and a large folder of
    /// documents only cuts it short.
    @Test func serviceScanIsBoundedToBundlesTwoLevelsDeep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("services-scan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ path: String, _ key: String) throws {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["NSServices": [["NSMenuItem": ["default": path], "NSMessage": "m", "NSKeyEquivalent": ["default": key]]]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try bundle("Top.app", "T")
        try bundle("Utilities/Nested.service", "N")
        try bundle("Deep/Er/Hidden.app", "H")
        try bundle("Top.app/Contents/Helper.app", "P")
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for i in 0..<50 { FileManager.default.createFile(atPath: documents.appendingPathComponent("\(i).txt").path, contents: Data()) }
        let scan = ServiceHotkeys.serviceDeclarations(roots: [root.path], deadline: ProcessInfo.processInfo.systemUptime + 5)
        #expect(scan.complete)
        let keys = ServiceHotkeys.equivalents(status: [:], services: scan.entries)
        #expect(Set(keys.map(\.key)) == [CGKeyCode(17), CGKeyCode(45)])   // T and N
        let late = ServiceHotkeys.serviceDeclarations(roots: [root.path], deadline: ProcessInfo.processInfo.systemUptime - 1)
        #expect(!late.complete)
    }

    // MARK: 4. Unreadable focus

    func window(_ pid: pid_t, layer: Int = 0, _ frame: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300),
                owner: String = "fixture") -> WindowInfo {
        WindowInfo(id: CGWindowID(Int(pid) * 10 + layer), pid: pid, owner: owner, title: "", layer: layer, bounds: frame, alpha: 1)
    }
    let display = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    var menuBar: WindowInfo { window(0, layer: 24, CGRect(x: 0, y: 0, width: 1512, height: 33), owner: "Window Server") }

    /// A nonactivating panel of another process holds the keyboard while the target stays the focused application:
    /// only the focused element tells. It used to be checked only when the focused application couldn't be read either.
    @Test func anUnreadableFocusedElementAloneChecksWhatIsAboveTheTarget() {
        let panel = window(77, layer: 3)
        #expect(Input.unreadableFocusRefusal(elementRead: false, target: 42, windows: [panel, window(42)], displays: display, dock: []) != nil)
        #expect(Input.unreadableFocusRefusal(elementRead: true, target: 42, windows: [panel, window(42)], displays: display, dock: []) == nil)
        #expect(Input.unreadableFocusRefusal(elementRead: false, target: 42, windows: [window(42), panel], displays: display, dock: []) == nil)
    }

    /// The menu bar's status items and the Dock are always in front and never hold the keyboard.
    @Test func statusItemsAndTheDockAreNotAboveTheTarget() {
        let status = window(88, layer: 25, CGRect(x: 1300, y: 0, width: 30, height: 33))
        let dock = window(99, layer: 20, display[0])
        let windows = [menuBar, status, dock, window(42)]
        #expect(!Input.unknownFocusBlocked(target: 42, windows: windows, displays: display, dock: [99]))
        // Not a status item: taller than the menu bar, or below it; and the Dock's other levels (Mission Control).
        #expect(Input.unknownFocusBlocked(target: 42, windows: [menuBar, window(88, layer: 25, CGRect(x: 1300, y: 0, width: 300, height: 400)), window(42)],
                                          displays: display, dock: []))
        #expect(Input.unknownFocusBlocked(target: 42, windows: [menuBar, window(88, layer: 25, CGRect(x: 1300, y: 40, width: 30, height: 30)), window(42)],
                                          displays: display, dock: []))
        #expect(Input.unknownFocusBlocked(target: 42, windows: [window(99, layer: 1000, display[0]), window(42)], displays: display, dock: [99]))
        // A normal-layer window in the top strip is still a window.
        #expect(Input.unknownFocusBlocked(target: 42, windows: [window(88, CGRect(x: 0, y: 0, width: 200, height: 30)), window(42)],
                                          displays: display, dock: []))
    }

    // MARK: 5. Abandoned drag release

    @Test func anAbandonedDragIsReleasedOverTheMenuBarOnlyWhereTheMenuBarIsInFront() {
        let point = Input.safeDropPoint(windows: [menuBar, window(42)], displays: display)
        #expect(point == CGPoint(x: 6, y: 16.5))
        // A window of any process there (a status item, a panel, a full-screen overlay) rules the point out.
        let covering = window(88, layer: 25, CGRect(x: 0, y: 0, width: 40, height: 33))
        #expect(Input.safeDropPoint(windows: [covering, menuBar], displays: display) == nil)
        #expect(Input.safeDropPoint(windows: [window(88, layer: 1000, display[0]), menuBar], displays: display) == nil)
        // A full-screen app hides the menu bar.
        #expect(Input.safeDropPoint(windows: [window(42, display[0])], displays: display) == nil)
        // Another display's menu bar.
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let secondBar = WindowInfo(id: 7, pid: 0, owner: "Window Server", title: "", layer: 24,
                                   bounds: CGRect(x: 1512, y: 0, width: 1920, height: 24), alpha: 1)
        #expect(Input.safeDropPoint(windows: [covering, menuBar, secondBar], displays: display + [second]) == CGPoint(x: 1518, y: 12))
    }

    @Test(arguments: [true, false])
    func anAbandonedDragReportsWhereItWasReleased(_ safe: Bool) async throws {
        let tape = KeyTape(), source = CGPoint(x: 20, y: 30), fallback = safe ? CGPoint(x: 6, y: 16) : CGPoint(x: -12000, y: -13000)
        let environment = Input.Environment(check: { _, _ in }, post: { event in
            tape.post(event)
            if event.type == .leftMouseDown { withUnsafeCurrentTask { $0?.cancel() } }
        }, dragCleanup: { _, _ in
            Input.DragCleanupState(prompts: false, focused: 42, owner: 77, fallback: fallback, fallbackSafe: safe)
        })
        let task = Task {
            try await Input.$environment.withValue(environment) {
                try await ActionRoute.$check.withValue({ _ in }) { try await Input.drag(from: source, to: CGPoint(x: 100, y: 200), pid: 42) }
            }
        }
        do { try await task.value; Issue.record("Cancelled drag succeeded") }
        catch {
            #expect(String(describing: error).contains(safe ? "over the menu bar" : "outside all displays"), "\(error)")
        }
        let ups = tape.all.filter { $0.type == .leftMouseUp }
        #expect(ups.count == 1 && ups.first?.point == fallback)
        // Over the menu bar, the drag moves there first, so the drop is decided there.
        let last = tape.all.last { $0.type == .leftMouseDragged }
        #expect((last?.point == fallback) == safe)
    }

    // MARK: 6. Prompt-window classification under the step budget

    /// The classification of a window that needs accessibility is remembered for a moment, so a slow process costs
    /// one step at most; one that can't be described counts as a prompt alone, and other windows are unaffected.
    @Test func promptClassificationIsCachedPerWindowAndFailsClosedPerWindow() {
        let cache = WindowServer.PromptCache()
        let ordinary = WindowServer.WindowTraits(role: "AXWindow", subrole: "AXStandardWindow", hasCloseButton: true)
        let described = WindowInfo(id: 1, pid: getpid(), owner: "sharingd", title: "", layer: 0,
                                   bounds: CGRect(x: 100, y: 80, width: 800, height: 600), alpha: 1)
        let silent = WindowInfo(id: 2, pid: getpid(), owner: "sharingd", title: "", layer: 0,
                                bounds: CGRect(x: 200, y: 200, width: 500, height: 400), alpha: 1)
        let counter = Counter()
        func prompts() -> [WindowInfo] {
            WindowServer.systemPrompts(in: [described, silent], cache: cache) { _ in
                counter.add()
                return [(described.bounds, ordinary)]   // the second window isn't described: no answer in time
            }
        }
        #expect(prompts() == [silent])
        #expect(prompts() == [silent])
        #expect(counter.count == 1)
        // A window that moved is asked again.
        let moved = WindowInfo(id: 1, pid: getpid(), owner: "sharingd", title: "", layer: 0,
                               bounds: CGRect(x: 120, y: 80, width: 800, height: 600), alpha: 1)
        _ = WindowServer.systemPrompts(in: [moved], cache: cache) { _ in counter.add(); return [] }
        #expect(counter.count == 2)
        // Windows the layer settles are never asked, nor cached.
        let alert = WindowInfo(id: 3, pid: getpid(), owner: "sharingd", title: "", layer: 8,
                               bounds: CGRect(x: 100, y: 80, width: 400, height: 200), alpha: 1)
        #expect(WindowServer.systemPrompts(in: [alert], cache: cache) { _ in counter.add(); return [] } == [alert])
        #expect(counter.count == 2)
    }

    @Test func promptClassificationFitsInsideAStep() {
        #expect(Double(WindowServer.promptTraitsTimeout) < Input.guardTimeout / 2)
        #expect(WindowServer.promptTraitsBudget < Input.guardTimeout / 2)
        #expect(WindowServer.PromptCache.lifetime >= 1 && WindowServer.PromptCache.lifetime <= 2)
    }
}
