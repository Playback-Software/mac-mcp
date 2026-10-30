import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

private final class ReviewTape: @unchecked Sendable {
    struct Event { let type: CGEventType; let point: CGPoint; let key: Int64 }
    private let lock = NSLock()
    private var events: [Event] = []
    var all: [Event] { lock.withLock { events } }
    func post(_ event: CGEvent) {
        lock.withLock { events.append(Event(type: event.type, point: event.location, key: event.getIntegerValueField(.keyboardEventKeycode))) }
    }
}

@Suite struct InputReviewRegressionTests {
    @Test(arguments: ["prompt", "foreign-focus", "unreadable-focus", "replaced-source", "route-refused", "safe"])
    func abortedDragNeverBlindlyEscapesOrDrops(_ scenario: String) async throws {
        let tape = ReviewTape(), source = CGPoint(x: 20, y: 30), fallback = CGPoint(x: -12000, y: -13000)
        let environment = Input.Environment(check: { _, _ in }, post: { event in
            tape.post(event)
            if event.type == .leftMouseDown { withUnsafeCurrentTask { $0?.cancel() } }
        }, dragCleanup: { _, _ in
            Input.DragCleanupState(prompts: scenario == "prompt", focused: scenario == "foreign-focus" ? 77 : scenario == "unreadable-focus" ? nil : 42,
                                   owner: scenario == "replaced-source" ? 77 : 42, fallback: fallback)
        })
        let task = Task {
            try await Input.$environment.withValue(environment) {
                try await ActionRoute.$check.withValue({ step in
                    if case let .drag(from, to, _, _) = step, from == to {
                        #expect(from == source)
                        if scenario == "route-refused" { throw ActionError("Refused: changed source route") }
                    }
                }) {
                    try await Input.drag(from: source, to: CGPoint(x: 100, y: 200), pid: 42)
                }
            }
        }
        do { try await task.value; Issue.record("Cancelled drag succeeded") }
        catch {
            let unsafeSource = ["replaced-source", "route-refused"].contains(scenario)
            #expect(String(describing: error).contains("outside all displays") == unsafeSource)
        }
        let escape = tape.all.contains { $0.type == .keyDown && $0.key == 53 }
        #expect(escape == (scenario == "safe"))
        let releases = tape.all.filter { $0.type == .leftMouseUp }
        #expect(releases.count == 1)
        #expect(releases.first?.point == (["replaced-source", "route-refused"].contains(scenario) ? fallback : source))
    }

    /// The keys held through a drag reach its route checks: a selection-changing modifier on the button going down
    /// must be refused before it goes down.
    @Test func aDragsRouteChecksCarryTheKeysHeldThroughIt() async throws {
        let seen = Locked<[CGEventFlags]>([]), tape = ReviewTape()
        var timing = Input.DragTiming()
        timing.modifiers = .maskShift
        let environment = Input.Environment(check: { _, _ in }, post: { tape.post($0) }, dragCleanup: { _, _ in
            Input.DragCleanupState(prompts: false, focused: 42, owner: 42)
        })
        await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(environment) {
                try await ActionRoute.$check.withValue({ step in
                    guard case let .drag(_, _, _, modifiers) = step else { return }
                    seen.withLock { $0.append(modifiers) }
                    throw ActionError("Refused: shift on a Finder drag")
                }) {
                    try await Input.drag(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 100, y: 200), timing: timing, pid: 42)
                }
            }
        }
        #expect(seen.withLock { $0 } == [.maskShift])
        #expect(!tape.all.contains { $0.type == .leftMouseDown }, "refused before the button goes down")
    }

    @Test func unreadableFocusUsesWindowOrderIncludingNonactivatingPanels() {
        func window(_ pid: pid_t, layer: Int = 0, alpha: Double = 1) -> WindowInfo {
            WindowInfo(id: UInt32(pid), pid: pid, owner: "fixture", title: "", layer: layer,
                       bounds: CGRect(x: 0, y: 0, width: 200, height: 100), alpha: alpha)
        }
        #expect(Input.unknownFocusBlocked(target: 42, windows: [window(77, layer: 3), window(42)]))
        #expect(!Input.unknownFocusBlocked(target: 42, windows: [window(42), window(77)]))
        #expect(!Input.unknownFocusBlocked(target: 42, windows: [window(77, alpha: 0), window(42)]))
        #expect(!Input.unknownFocusBlocked(target: 42, windows: [window(42, layer: 3), window(42)]))
        #expect(Input.unknownFocusBlocked(target: 42, windows: [window(77)]))
    }

    /// A commit after a key that may open a panel or menu is refused anywhere, before any key is posted: its check
    /// can't see what the first key opened. Navigation then a commit is refused only where a selection is (see
    /// InputFinalReviewTests).
    @Test(arguments: ["cmd+s, return", "cmd+o, down, return", "return, return", "space, return", "ctrl+f2, down, return",
                      "cmd+shift+g, enter", "f5, space", "return, cmd+o"])
    func commitAfterAnOpeningKeyIsRefusedBeforePostingEvenWhenAXWouldStillReadOldState(_ text: String) async throws {
        let tape = ReviewTape(), keys = try KeySpec.parseSequence(text)
        #expect(OpenRoutes.keySequenceRefusal(keys, repeat: 1) != nil)
        await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.post($0) })) {
                try await Actions.keys(keys, repeat: 1, pid: 42)
            }
        }
        #expect(tape.all.isEmpty)
        #expect(OpenRoutes.keySequenceRefusal(try KeySpec.parseSequence("down down"), repeat: 2) == nil)
        #expect(OpenRoutes.keySequenceRefusal(try KeySpec.parseSequence("cmd+a, delete"), repeat: 1) == nil)
        #expect(OpenRoutes.keySequenceRefusal(try KeySpec.parseSequence("return"), repeat: 1) == nil)
        #expect(OpenRoutes.keySequenceRefusal(try KeySpec.parseSequence("return"), repeat: 2) != nil)
    }

    @Test func routeBudgetAllowsSlowReadWithoutRelaxingPerStepBudget() async throws {
        // The slow read waits on a gate that the second read opens from its own worker, half a second after its
        // per-step budget has run out, so neither outcome depends on how soon this test's task is scheduled again.
        let gate = DispatchSemaphore(value: 0)
        async let slowRead = Input.guardWork(timeout: Input.routeTimeout) {
            #expect(withUnsafeCurrentTask { $0 == nil })
            _ = gate.wait(timeout: .now() + 30)
            return "checked"
        }
        #expect(Input.guardTimeout == 0.25)
        await #expect(throws: ActionError.self) {
            _ = try await Input.guardWork {
                Thread.sleep(forTimeInterval: Input.guardTimeout + 0.5)
                gate.signal()
                return "too late"
            }
        }
        #expect(try await slowRead == "checked")
    }

    @Test func gcdGuardsUseTheResponsesNonceAcrossMultipleReads() async throws {
        try await Untrusted.scope(token: "same42") {
            let first = try await Input.guardWork { Untrusted.inline("one") }
            let second = try await Input.guardWork { Untrusted.inline("two") }
            #expect(first == "<<untrusted same42>>one<<end same42>>")
            #expect(second == "<<untrusted same42>>two<<end same42>>")
        }
    }

    @Test func leaseTakenDuringTypingStopsTheNextChunkAndRevokesTheSession() async throws {
        let path = NSTemporaryDirectory() + "input-lease-\(UUID().uuidString)/lease.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let tape = ReviewTape(), session = Input.Session(), checker = LeaseStore.InputCheck(token: nil, path: path)
        let environment = Input.Environment(check: { _, _ in }, post: { event in
            tape.post(event)
            if event.type == .keyDown, tape.all.filter({ $0.type == .keyDown }).count == 1 {
                _ = try? LeaseStore.acquire(holder: "person", reason: "take over", minutes: 1, pid: 0, path: path)
            }
        })
        await #expect(throws: ActionError.self) {
            try await Input.$leaseCheck.withValue(checker) {
                try await Input.$session.withValue(session) {
                    try await Input.$environment.withValue(environment) { try await Input.type(String(repeating: "x", count: 100), pid: 42) }
                }
            }
        }
        #expect(tape.all.filter { $0.type == .keyDown }.count == 1)
        #expect(tape.all.filter { $0.type == .keyUp }.count == 1)
        #expect(throws: CancellationError.self) { try session.check() }
    }

    @Test func leaseReaderObservesAtomicReplacementsAndHonorsItsOwnToken() throws {
        let path = NSTemporaryDirectory() + "input-lease-cache-\(UUID().uuidString)/lease.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let empty = LeaseStore.InputCheck(token: nil, path: path)
        try empty.check()
        let lease = try LeaseStore.acquire(holder: "fixture", reason: "test", minutes: 1, pid: 0, path: path)
        let own = LeaseStore.InputCheck(token: lease.token, path: path)
        try own.check()
        try own.check()
        #expect(throws: ActionError.self) { try empty.check() }
        #expect(LeaseStore.release(token: lease.token, path: path))
        try empty.check()
        _ = try LeaseStore.acquire(holder: "other", reason: "replace", minutes: 1, pid: 0, path: path)
        #expect(throws: ActionError.self) { try own.check() }
        try Data("invalid".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(throws: LeaseError.self) { try empty.check() }
    }
}
