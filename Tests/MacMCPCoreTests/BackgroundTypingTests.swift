import ApplicationServices
import Foundation
import Testing
@testable import MacMCPCore

private final class BackgroundFieldTape: @unchecked Sendable {
    struct State {
        var text: NSMutableAttributedString?
        var range: CFRange? = CFRange(location: 0, length: 0)
        var settable: Set<String> = [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute]
        var writes: [String] = []
        var checks = 0
        var keys: [CGKeyCode] = []
        var ignoreText = false
        var wrongLocation = false
        var failReturn = false
        var editOnSelectionRead: String?
    }
    private let lock = NSLock()
    private var state: State
    init(_ text: NSAttributedString) { state = State(text: NSMutableAttributedString(attributedString: text)) }
    convenience init(_ text: String = "old") { self.init(NSAttributedString(string: text)) }
    func withState<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }

    var field: Actions.BackgroundTextField {
        Actions.BackgroundTextField(value: { self.withState { $0.text?.string } }, selection: { self.withState { state in
                    if let edit = state.editOnSelectionRead { state.text = NSMutableAttributedString(string: edit); state.editOnSelectionRead = nil }
                    return state.range
                } },
                isSettable: { name in self.withState { $0.settable.contains(name) } },
                set: { name, text in self.write(name, text) }, setRange: { range in
                    self.withState { $0.writes.append(kAXSelectedTextRangeAttribute); $0.range = range }
                })
    }

    func input(check: @escaping @Sendable (BackgroundFieldTape) throws -> Void = { _ in },
               keyboard: @escaping @Sendable () throws -> Void = {},
               submit: @escaping @Sendable () throws -> Void = {}) -> Actions.BackgroundTypingInput {
        Actions.BackgroundTypingInput(check: {
            self.withState { $0.checks += 1 }
            try check(self)
        }, keyboardCheck: { try keyboard() }, submitCheck: { try submit() }, press: { key in
            let fail = self.withState { state in
                state.keys.append(key.key)
                if key.key == 0 { state.range = CFRange(location: 0, length: state.text?.length ?? 0) }
                return key.key == 36 && state.failReturn
            }
            if fail { throw ActionError("focus changed") }
        }, type: { text in _ = self.write(kAXSelectedTextAttribute, text) })
    }

    private func write(_ name: String, _ text: String) -> AXError {
        withState { state in
            state.writes.append(name)
            if state.ignoreText { return .success }
            if name == kAXValueAttribute { state.text = NSMutableAttributedString(string: text); return .success }
            guard let value = state.text, let range = state.range else { return .failure }
            let location = state.wrongLocation ? 0 : range.location
            value.replaceCharacters(in: NSRange(location: location, length: range.length), with: text)
            state.range = CFRange(location: location + text.utf16.count, length: 0)
            return .success
        }
    }
}

@Suite struct BackgroundTypingTests {
    @Test(arguments: [Actions.TypeMode.append, .insert])
    func selectedEditsPreserveSurroundingFormattingAndAttachments(_ mode: Actions.TypeMode) async throws {
        let style = NSAttributedString.Key("fixtureStyle"), attachment = NSAttributedString.Key("fixtureAttachment")
        let rich = NSMutableAttributedString(string: "A😀\u{fffc}Z", attributes: [style: "bold"])
        rich.addAttribute(attachment, value: "attachment payload", range: NSRange(location: 3, length: 1))
        let tape = BackgroundFieldTape(rich)
        tape.withState { $0.range = CFRange(location: 1, length: 2) }
        let result = try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "xy", mode: mode, submit: false)
        #expect(result.contains("field value verified"))
        tape.withState { state in
            #expect(state.writes == [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute])
            #expect(state.text?.string == (mode == .append ? "A😀\u{fffc}Zxy" : "Axy\u{fffc}Z"))
            #expect(state.text?.attribute(style, at: 0, effectiveRange: nil) as? String == "bold")
            #expect(state.text?.attribute(attachment, at: 3, effectiveRange: nil) as? String == "attachment payload")
            #expect(state.keys.isEmpty)
        }
    }

    @Test func replaceMayWriteTheWholeValue() async throws {
        let tape = BackgroundFieldTape()
        _ = try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "new", mode: .replace, submit: false)
        #expect(tape.withState { $0.writes } == [kAXValueAttribute])
        #expect(tape.field.value() == "new")
    }

    @Test(arguments: [Actions.TypeMode.replace, .append, .insert])
    func concurrentValueChangeRefusesBeforeTextMutation(_ mode: Actions.TypeMode) async {
        let tape = BackgroundFieldTape()
        let input = tape.input(check: { tape in
            tape.withState { if $0.checks == 2 { $0.text = NSMutableAttributedString(string: "person's edit") } }
        })
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: mode, submit: false)
        }
        #expect(tape.withState { $0.writes.isEmpty })
        #expect(tape.field.value() == "person's edit")
    }

    @Test func changeAfterCaretPlacementRefusesBeforeSelectedTextWrite() async {
        let tape = BackgroundFieldTape()
        let input = tape.input(check: { tape in
            tape.withState { if $0.checks == 3 { $0.text = NSMutableAttributedString(string: "person's edit") } }
        })
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: .append, submit: false)
        }
        #expect(tape.withState { $0.writes } == [kAXSelectedTextRangeAttribute])
        #expect(tape.field.value() == "person's edit")
    }

    @Test func changedSelectionRefusesBeforeInsertingAtAnotherLocation() async {
        let tape = BackgroundFieldTape()
        let input = tape.input(check: { tape in
            tape.withState { if $0.checks == 3 { $0.range = CFRange(location: 0, length: 0) } }
        })
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: .append, submit: false)
        }
        #expect(tape.field.value() == "old")
        #expect(tape.withState { $0.writes } == [kAXSelectedTextRangeAttribute])
    }

    @Test func valueChangeDuringSelectionReadIsCheckedBeforeWriting() async {
        let tape = BackgroundFieldTape()
        let input = tape.input(check: { tape in
            tape.withState { if $0.checks == 3 { $0.editOnSelectionRead = "person's edit" } }
        })
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: .append, submit: false)
        }
        #expect(tape.withState { $0.writes } == [kAXSelectedTextRangeAttribute])
        #expect(tape.field.value() == "person's edit")
    }

    @Test(arguments: [Actions.TypeMode.replace, .append, .insert])
    func submitPreflightRefusesWithoutChangingTextOrSelection(_ mode: Actions.TypeMode) async {
        let tape = BackgroundFieldTape()
        let input = tape.input(submit: { throw ActionError("field is not the app's AXFocusedUIElement") })
        do {
            _ = try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: mode, submit: true)
            Issue.record("unfocused submit was accepted")
        } catch {
            #expect(String(describing: error).contains("submit=true"))
            #expect(String(describing: error).contains("no text was changed"))
            #expect((error as? ActionError)?.audit == "Refused: background submit")
        }
        #expect(tape.field.value() == "old")
        #expect(tape.withState { $0.writes.isEmpty && $0.keys.isEmpty })
    }

    @Test func focusChangeAfterWriteReportsWrittenTextAndUnconfirmedReturn() async throws {
        let tape = BackgroundFieldTape()
        tape.withState { $0.failReturn = true }
        let result = try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "new", mode: .replace, submit: true)
        #expect(result.contains("field value verified"))
        #expect(result.contains("Return could not be confirmed; text was already written"))
        #expect(tape.field.value() == "new")
        #expect(tape.withState { $0.keys } == [36])
    }

    @Test(arguments: [Actions.TypeMode.replace, .append, .insert])
    func submitRecheckCatchesFocusChangesBeforeAnyMutation(_ mode: Actions.TypeMode) async {
        let tape = BackgroundFieldTape()
        let input = tape.input(submit: {
            if tape.withState({ $0.checks }) >= 2 { throw ActionError("focus changed before writing") }
        })
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: mode, submit: true)
        }
        #expect(tape.field.value() == "old")
        #expect(tape.withState { $0.writes.isEmpty && $0.keys.isEmpty })
    }

    @Test func verifiedWritePrecedesReturn() async throws {
        let tape = BackgroundFieldTape()
        let result = try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "new", mode: .replace, submit: true)
        #expect(result.contains("Return sent to the app"))
        #expect(tape.withState { $0.keys } == [36])
    }

    @Test(arguments: [false, true])
    func readbackRejectsMissingOrMisplacedInsertionAndNeverSubmits(_ misplaced: Bool) async {
        let tape = BackgroundFieldTape()
        tape.withState { $0.ignoreText = !misplaced; $0.wrongLocation = misplaced }
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "X", mode: .append, submit: true)
        }
        #expect(tape.withState { $0.keys.isEmpty })
    }

    @Test func missingSelectedTextSupportDoesNotFlattenTheValue() async throws {
        let tape = BackgroundFieldTape("A\u{fffc}Z")
        _ = tape.withState { $0.settable.remove(kAXSelectedTextAttribute) }
        _ = try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "X", mode: .append, submit: false)
        #expect(tape.withState { !$0.writes.contains(kAXValueAttribute) })
        #expect(tape.field.value() == "A\u{fffc}ZX")
    }

    @Test func keyboardFallbackRequiresFocusBeforeChangingTheSelection() async {
        let tape = BackgroundFieldTape()
        _ = tape.withState { $0.settable.remove(kAXSelectedTextAttribute) }
        let input = tape.input(keyboard: { throw ActionError("the field is not focused") })
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: input, text: "new", mode: .append, submit: false)
        }
        #expect(tape.withState { $0.writes.isEmpty && $0.keys.isEmpty })
    }

    @Test func appendWithoutASettableRangeRefusesInsteadOfReplacingTheValue() async {
        let tape = BackgroundFieldTape()
        _ = tape.withState { $0.settable.remove(kAXSelectedTextRangeAttribute) }
        await #expect(throws: ActionError.self) {
            try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "new", mode: .append, submit: false)
        }
        #expect(tape.withState { $0.writes.isEmpty && $0.keys.isEmpty })
    }

    @Test func unreadableValueOrInsertRangeRefusesBeforeWriting() async {
        for unreadableValue in [false, true] {
            let tape = BackgroundFieldTape()
            tape.withState { if unreadableValue { $0.text = nil } else { $0.range = nil } }
            await #expect(throws: ActionError.self) {
                try await Actions.backgroundEdit(tape.field, input: tape.input(), text: "X", mode: .insert, submit: false)
            }
            #expect(tape.withState { $0.writes.isEmpty })
        }
    }
}
