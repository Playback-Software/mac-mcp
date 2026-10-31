import AppKit
import ApplicationServices
import Foundation

extension Actions {
    /// A route decision independent of live AX, also used by unit tests. Modified and repeated clicks need real
    /// pointer semantics and cannot be represented by a single accessibility action.
    static func backgroundClickAction(button: Input.Button, count: Int, modifiers: CGEventFlags, actions: [String]) -> String? {
        guard count == 1, modifiers.isEmpty else { return nil }
        if button == .right { return actions.contains(kAXShowMenuAction) ? kAXShowMenuAction : nil }
        guard button == .left else { return nil }
        return [kAXPressAction, kAXPickAction].first { actions.contains($0) }
    }

    /// Recheck ownership, routes, prompts, modality and the identity seen at resolution immediately before AX
    /// input. No hit test: an occluding window belongs to the person and does not determine an AX action's receiver.
    static func checkBackground(_ element: AXElement, pid: pid_t, row: Row? = nil) async throws {
        try await Input.check(pid: pid, route: .target(element, point: nil, pid: pid, opens: false))
        try await Input.guardWork(pool: .route, timeout: Input.routeTimeout) {
            guard BackgroundMode.owns(element, pid: pid), element.isAlive else {
                throw ActionError(BackgroundMode.refusal("act on an unavailable or remote accessibility element"))
            }
            if let blocked = modalBlocker(of: element, pid: pid) { throw ActionError(blocked) }
            if let row {
                if let changed = backgroundIdentityRefusal(element, row: row) { throw ActionError(changed) }
            }
        }
        // Identity reads may take time; a lease or prompt arriving meanwhile must stop the write too.
        try await Input.check(pid: pid)
    }

    public static func backgroundIdentityRefusal(_ element: AXElement, row: Row) -> String? {
        guard let now = currentIdentity(of: element), now.role == row.role else {
            return BackgroundMode.refusal("recheck this element's identity; take a new mac_snapshot")
        }
        return RefStore.changeMessage(ref: row.ref ?? "target", role: row.role, shown: .init(row),
                                     label: now.label, identifier: now.identifier, complete: now.complete)
    }

    static func backgroundRow(_ element: AXElement, row: Row?) async throws -> Row {
        if let row { return row }
        return try await Input.guardWork(pool: .route, timeout: Input.routeTimeout) {
            guard let now = currentIdentity(of: element), now.complete else {
                throw ActionError(BackgroundMode.refusal("read the intended element's identity; take mac_snapshot app="))
            }
            var row = Row(kind: .interactive, role: now.role, label: now.label, value: nil, states: [], frame: nil,
                          depth: 0, ref: nil, fingerprint: "")
            row.identifier = now.identifier
            return row
        }
    }

    static func backgroundClick(_ r: Resolved, button: Input.Button, count: Int, modifiers: CGEventFlags) async throws -> String {
        guard let element = r.element else { throw ActionError(BackgroundMode.refusal("click coordinates or screenshot pixels")) }
        guard let action = backgroundClickAction(button: button, count: count, modifiers: modifiers, actions: element.actionNames) else {
            throw ActionError(BackgroundMode.refusal("click this control without pointer input; try an AX button or mac_menu"))
        }
        try await checkBackground(element, pid: r.pid, row: r.row)
        switch pressOutcome(element.perform(action), cancelled: Task.isCancelled) {
        case .pressed: return "accessibility " + (action == kAXShowMenuAction ? "show-menu" : action == kAXPickAction ? "pick" : "press")
        case .unanswered: return "accessibility action unverified (the app did not reply; inspect the snapshot before retrying)"
        case .failed: throw ActionError(BackgroundMode.refusal("complete this accessibility action; no foreground fallback was sent"))
        }
    }

    /// AX typing never sets AXFocused. If neither value nor selected-text writes are supported, keys may go only
    /// to this same element while it remains the target PID's own focused element.
    static func backgroundType(_ r: Resolved?, pid: pid_t, text: String, mode: TypeMode, submit: Bool) async throws -> String {
        guard let field = r?.element ?? AXElement.application(pid: pid).element(kAXFocusedUIElementAttribute),
              OpenRoutes.textRoles.contains(field.role ?? ""), field.subrole != "AXSecureTextField", !hidesItsText(field) else {
            throw ActionError(BackgroundMode.refusal("type without a nonsecure text field; use mac_snapshot app= to find one"))
        }
        let row = try await backgroundRow(field, row: r?.row)
        return try await BackgroundMode.$row.withValue(row) {
            try await BackgroundMode.$target.withValue(field) {
                try await checkBackground(field, pid: pid, row: row)
                let original = field.string(kAXValueAttribute)
                let selection = field.attribute(kAXSelectedTextRangeAttribute) as? CFRange
                let expected = expectedTypedValue(original: original, text: text, mode: mode, selection: selection)
                try await ActionRoute.validate(.typing(text, mode: mode, pid: pid))

                let valueSettable = field.isSettable(kAXValueAttribute)
                let selectedSettable = field.isSettable(kAXSelectedTextAttribute)
                if let expected, valueSettable {
                    try await checkBackground(field, pid: pid, row: row)
                    guard field.set(kAXValueAttribute, expected) == .success else {
                        throw ActionError(BackgroundMode.refusal("confirm the AX value write; it may have applied, so inspect the field before retrying"))
                    }
                } else if selectedSettable, let original, mode != .insert || expected != nil {
                    if mode != .insert {
                        try await checkBackground(field, pid: pid, row: row)
                        try setBackgroundRange(field, location: mode == .append ? original.utf16.count : 0,
                                               length: mode == .replace ? original.utf16.count : 0)
                    }
                    try await checkBackground(field, pid: pid, row: row)
                    guard field.set(kAXSelectedTextAttribute, text) == .success else {
                        throw ActionError(BackgroundMode.refusal("confirm the AX selected-text write; inspect the field before retrying"))
                    }
                } else {
                    try await Input.check(pid: pid, keyboard: true)
                    if mode == .replace { try await Input.press(try KeySpec.parse("cmd+a"), pid: pid) }
                    if mode == .append {
                        guard let original else { throw ActionError(BackgroundMode.refusal("place an unreadable caret at the end")) }
                        try await checkBackground(field, pid: pid, row: row)
                        try setBackgroundRange(field, location: original.utf16.count, length: 0)
                    }
                    try await Input.type(text, pid: pid, replacing: mode == .replace)
                }
                try await Task.sleep(for: .milliseconds(100))
                let verified = try await verifyAndSubmit(value: field.string(kAXValueAttribute), expected: expected,
                        typedCount: text.count, submit: submit, previouslyReadable: original != nil) {
                    try await Input.press(try KeySpec.parse("return"), pid: pid)
                }
                return "typed \(text.count) characters; " + (verified ? "field value verified" : "unverified (field value or caret unavailable)")
                    + (submit ? "; Return sent to the app, delivery unverified; inspect the diff" : "")
            }
        }
    }

    static func setBackgroundRange(_ field: AXElement, location: Int, length: Int) throws {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range), field.set(kAXSelectedTextRangeAttribute, value) == .success else {
            throw ActionError(BackgroundMode.refusal("place the caret through accessibility"))
        }
    }

    static func backgroundKeys(_ specs: [KeySpec], repeat count: Int, pid: pid_t) async throws {
        for spec in specs { if let refusal = BackgroundMode.keyRefusal(spec) { throw ActionError(refusal) } }
        guard let field = AXElement.application(pid: pid).element(kAXFocusedUIElementAttribute) else {
            throw ActionError(BackgroundMode.refusal("read this app's own focused element; use an AX ref"))
        }
        let row = try await backgroundRow(field, row: nil)
        try await BackgroundMode.$row.withValue(row) {
            try await BackgroundMode.$target.withValue(field) {
                try await checkBackground(field, pid: pid, row: row)
                try await press(specs, repeat: count, pid: pid)
            }
        }
    }
}
