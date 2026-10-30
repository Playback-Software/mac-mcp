import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

private final class Tape: @unchecked Sendable {
    private let lock = NSLock()
    private var down: [Int64] = []
    private var steps: [ActionRoute.KeySequence] = []
    var keys: [Int64] { lock.withLock { down } }
    var sequences: [ActionRoute.KeySequence] { lock.withLock { steps } }
    func post(_ event: CGEvent) {
        if event.type == .keyDown { lock.withLock { down.append(event.getIntegerValueField(.keyboardEventKeycode)) } }
    }
    func record(_ sequence: ActionRoute.KeySequence?) { if let sequence { lock.withLock { steps.append(sequence) } } }
}

/// Runs mac_type's input against a fake desktop with the real sequence rules: `context` is Finder, a file panel or an
/// open menu, `textArea` a focused multi-line text area. Returns what was posted and the sequence each key step saw.
private func type(_ text: String, replacing: Bool = false, context: Bool, textArea: Bool) async throws -> Tape {
    let tape = Tape()
    try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.post($0) })) {
        try await ActionRoute.$check.withValue({ step in
            switch step {
            case let .typing(text, mode, _):
                if let r = RouteGuards.typedKeysRefusal(text, replacing: mode == .replace, selectionContext: { context }, editsText: { textArea }) {
                    throw ActionError(r)
                }
            case .key:
                tape.record(ActionRoute.keySequence)
                guard let sequence = ActionRoute.keySequence else { return }
                if let r = RouteGuards.sequenceRefusal(sequence, selectionContext: { context }, editsText: { textArea }) { throw ActionError(r) }
            default: break
            }
        }) {
            // Actions.type validates the whole text before the first character, as the route check does here.
            try await ActionRoute.validate(.typing(text, mode: replacing ? .replace : .insert, pid: 42))
            try await Input.type(text, pid: 42, replacing: replacing)
        }
    }
    return tape
}

@Suite struct TypedKeySequenceTests {
    // MARK: What mac_type's keys are

    @Test func newlinesAndTabsAreReturnAndTabKeysAfterTheTextBeforeThem() throws {
        let keys = try #require(OpenRoutes.typedKeys("ab\r\ncd\te\n", replacing: false))
        #expect(keys.map(\.key) == [0, 0, 36, 0, 0, 48, 0, 36])   // "\r\n" is one Return
        #expect(OpenRoutes.typedKeys("a b", replacing: false) == nil)
        #expect(OpenRoutes.typedKeys("", replacing: true) == nil)
        #expect(OpenRoutes.typedKeys("x\n", replacing: true)?.first == (try KeySpec.parse("cmd+a")))
    }

    @Test func eachControlKeyIsCheckedAsAKeyOfOneCallWithItsPlace() async throws {
        let tape = try await type("ab\ncd\n", context: false, textArea: true)
        #expect(tape.sequences.map(\.index) == [2, 5])
        #expect(tape.sequences.allSatisfy { $0.typed && $0.keys.count == 6 })
        let replaced = try await type("ab\n", replacing: true, context: false, textArea: true)
        #expect(replaced.sequences.map(\.index) == [3])   // ⌘A came first
        #expect(replaced.sequences.first?.keys.count == 4)
    }

    // MARK: Finder, file panels, the Open With chooser and open menus

    /// These sent `return, return` or type-select-then-Return to a selection nobody had checked.
    @Test(arguments: ["\n\n", "\n\n\n", "abc\n", "a\nb\n", "\r\n\r\n", "x\ty", "\tx", "ab\t", "Photos\n", "a b\n"])
    func inASelectionContextTextWithControlKeysIsRefusedBeforeAnythingIsTyped(_ text: String) async throws {
        for textArea in [false, true] {
            var posted: Tape?
            let error = await #expect(throws: ActionError.self) { posted = try await type(text, context: true, textArea: textArea) }
            #expect(error?.description.contains("first in its mac_type call") == true, "\(text.debugDescription)")
            #expect(posted == nil)
        }
    }

    @Test(arguments: ["abc", "My file name", "\n", "é ü 日本語"])
    func inASelectionContextPlainTextAndAFirstReturnStillGo(_ text: String) async throws {
        let tape = try await type(text, context: true, textArea: false)
        #expect(!tape.keys.isEmpty)
    }

    @Test func replacingInASelectionContextCountsTheSelectAllBeforeTheText() async throws {
        #expect(RouteGuards.typedKeysRefusal("x\n", replacing: true, selectionContext: { true }, editsText: { false }) != nil)
        #expect(RouteGuards.typedKeysRefusal("x", replacing: true, selectionContext: { true }, editsText: { false }) == nil)
        #expect(RouteGuards.typedKeysRefusal("x\n", replacing: true, selectionContext: { false }, editsText: { false }) == nil)
    }

    // MARK: A newline after a key that may open a panel

    @Test(arguments: ["\n\n", "a\n\n", "a\nb\nc\n"])
    func outsideATextAreaASecondNewlineIsRefusedLikeReturnReturn(_ text: String) async throws {
        var posted: Tape?
        let error = await #expect(throws: ActionError.self) { posted = try await type(text, context: false, textArea: false) }
        #expect(error?.description.contains("second newline") == true, "\(text.debugDescription)")
        #expect(posted == nil)
        #expect(OpenRoutes.keySequenceRefusal(try KeySpec.parseSequence("return return"), repeat: 1) != nil)
    }

    @Test(arguments: ["a\n", "\n", "a\tb\tc", "a\tb\n", "Name\tValue"])
    func outsideATextAreaOneNewlineAndTabsAreOrdinaryInput(_ text: String) async throws {
        let tape = try await type(text, context: false, textArea: false)
        #expect(tape.keys.filter { $0 == 36 }.count == text.filter { $0 == "\n" }.count)
        #expect(tape.keys.filter { $0 == 48 }.count == text.filter { $0 == "\t" }.count)
    }

    // MARK: Multiline typing in an editor keeps working

    @Test func multilineTextInATextAreaIsTypedWithEveryLineBreak() async throws {
        let text = "Dear team,\n\nThree things:\n\n1. one\n2. two\n\n\tindented\r\nThanks\n"
        let tape = try await type(text, context: false, textArea: true)
        #expect(tape.keys.filter { $0 == 36 }.count == 9)
        #expect(tape.keys.filter { $0 == 48 }.count == 1)
        let replaced = try await type("a\n\nb", replacing: true, context: false, textArea: true)
        #expect(replaced.keys.filter { $0 == 36 }.count == 2)
    }
}
