import ApplicationServices
import Foundation

extension Actions {
    /// Small adapters keep the read/check/write ordering testable without AX IPC or desktop input.
    struct BackgroundTextField: Sendable {
        var value: @Sendable () -> String?
        var selection: @Sendable () -> CFRange?
        var isSettable: @Sendable (String) -> Bool
        var set: @Sendable (String, String) -> AXError
        var setRange: @Sendable (CFRange) throws -> Void
    }

    struct BackgroundTypingInput: Sendable {
        var check: @Sendable () async throws -> Void
        var keyboardCheck: @Sendable () async throws -> Void
        var submitCheck: @Sendable () async throws -> Void
        var press: @Sendable (KeySpec) async throws -> Void
        var type: @Sendable (String) async throws -> Void
    }

    static func backgroundEdit(_ field: BackgroundTextField, input: BackgroundTypingInput,
                               text: String, mode: TypeMode, submit: Bool) async throws -> String {
        try await input.check()
        guard let original = field.value() else {
            throw ActionError(BackgroundMode.refusal("edit a field whose value cannot be read and checked for concurrent changes"))
        }
        let selection = field.selection()
        guard let expected = expectedTypedValue(original: original, text: text, mode: mode, selection: selection) else {
            throw ActionError(BackgroundMode.refusal("insert at an unreadable or invalid selection; take a new mac_snapshot"))
        }
        let range: CFRange
        switch mode {
        case .replace: range = CFRange(location: 0, length: original.utf16.count)
        case .append: range = CFRange(location: original.utf16.count, length: 0)
        case .insert: range = selection!
        }
        let valueWrite = mode == .replace && field.isSettable(kAXValueAttribute)
        let rangeSettable = field.isSettable(kAXSelectedTextRangeAttribute)
        let selectedWrite = rangeSettable && field.isSettable(kAXSelectedTextAttribute)

        func unchanged(selection expectedRange: CFRange? = nil) throws {
            if let expectedRange {
                guard let current = field.selection(), current.location == expectedRange.location, current.length == expectedRange.length else {
                    throw ActionError(BackgroundMode.refusal("type after the field's selection changed or could not be checked"))
                }
            }
            // Keep the value read last: a range IPC can itself give the person time to edit the field.
            guard field.value() == original else {
                throw ActionError(BackgroundMode.refusal("overwrite a field that changed before typing; take a new mac_snapshot"))
            }
        }

        func preflightSubmit() async throws {
            guard submit else { return }
            do { try await input.submitCheck() }
            catch let error as ActionError {
                throw ActionError("Refused: background mode: submit=true requires Return to be deliverable to this field before typing; "
                    + "no text was changed. " + error.description, audit: "Refused: background submit")
            }
        }

        // AX writes do not focus the field. Refuse an impossible submit before even changing its selection.
        try await preflightSubmit()
        if valueWrite {
            try await input.check()
            try await preflightSubmit()
            try unchanged()
            guard field.set(kAXValueAttribute, expected) == .success else {
                throw ActionError(BackgroundMode.refusal("confirm the AX value write; it may have applied, so inspect the field before retrying"))
            }
        } else if selectedWrite {
            try await input.check()
            try await preflightSubmit()
            try unchanged(selection: mode == .insert ? selection : nil)
            try field.setRange(range)
            try await input.check()
            try await preflightSubmit()
            try unchanged(selection: range)
            guard field.set(kAXSelectedTextAttribute, text) == .success else {
                throw ActionError(BackgroundMode.refusal("confirm the AX selected-text write; inspect the field before retrying"))
            }
        } else {
            // Never flatten a rich editor into AXValue just because selected-text edits are unsupported.
            if let keys = OpenRoutes.typedKeys(text, replacing: mode == .replace),
               let refusal = BackgroundMode.keySequenceRefusal(keys, repeat: 1) { throw ActionError(refusal) }
            try await input.keyboardCheck()
            try await input.check()
            try await preflightSubmit()
            try unchanged(selection: mode == .insert ? selection : nil)
            if mode == .replace { try await input.press(KeySpec(key: 0, flags: .maskCommand)) }
            else if mode == .append {
                guard rangeSettable else { throw ActionError(BackgroundMode.refusal("place the caret at the end through accessibility")) }
                try field.setRange(range)
            }
            try await input.check()
            try await preflightSubmit()
            try unchanged(selection: range)
            try await input.type(text)
        }
        try await Task.sleep(for: .milliseconds(100))
        // Compare the full expected splice, including the unchanged prefix/suffix, rather than merely finding text.
        _ = try await verifyAndSubmit(value: field.value(), expected: expected, typedCount: text.count,
                                     submit: false, previouslyReadable: true) {}
        let typed = "typed \(text.count) characters; field value verified"
        guard submit else { return typed }
        do {
            try await input.press(KeySpec(key: 36, flags: []))
            return typed + "; Return sent to the app, delivery unverified; inspect the diff"
        } catch {
            // Focus/lease/policy may change after the verified write. Preserve its successful result instead of
            // reporting the whole edit as refused and inviting a duplicate write. Never retry or roll it back.
            return typed + "; Return could not be confirmed; text was already written. Inspect mac_snapshot before submitting or retrying"
        }
    }
}
