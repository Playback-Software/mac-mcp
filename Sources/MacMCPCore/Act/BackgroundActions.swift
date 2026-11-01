import AppKit
import ApplicationServices
import Foundation

extension Actions {
    /// A route decision independent of live AX, also used by unit tests. Modified and repeated clicks need real
    /// pointer semantics and cannot be represented by a single accessibility action.
    static func backgroundClickAction(button: Input.Button, count: Int, modifiers: CGEventFlags, actions: [String]) -> String? {
        guard count == 1, modifiers.isEmpty else { return nil }
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
        if let refusal = BackgroundMode.actionRefusal(button == .right ? kAXShowMenuAction : kAXPressAction, role: element.role)
            ?? BackgroundMode.menuRefusal(element) {
            throw ActionError(refusal)
        }
        guard let action = backgroundClickAction(button: button, count: count, modifiers: modifiers, actions: element.actionNames) else {
            throw ActionError(BackgroundMode.refusal("click this control without pointer input; try an AX button or mac_menu"))
        }
        try await checkBackground(element, pid: r.pid, row: r.row)
        switch pressOutcome(element.perform(action), cancelled: Task.isCancelled) {
        case .pressed: return "accessibility " + (action == kAXPickAction ? "pick" : "press")
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
                try await ActionRoute.validate(.typing(text, mode: mode, pid: pid))
                let access = BackgroundTextField(value: { field.string(kAXValueAttribute) },
                        selection: { field.attribute(kAXSelectedTextRangeAttribute) as? CFRange },
                        isSettable: { field.isSettable($0) }, set: { field.set($0, $1) },
                        setRange: { try setBackgroundRange(field, location: $0.location, length: $0.length) })
                let input = BackgroundTypingInput(check: { try await checkBackground(field, pid: pid, row: row) },
                        keyboardCheck: { try await Input.check(pid: pid, keyboard: true) },
                        submitCheck: { try await Input.check(pid: pid, keyboard: true, route: .key(KeySpec(key: 36, flags: []), pid: pid)) },
                        press: { try await Input.press($0, pid: pid) },
                        type: { try await Input.type($0, pid: pid, replacing: mode == .replace) })
                return try await backgroundEdit(access, input: input, text: text, mode: mode, submit: submit)
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
        if let refusal = BackgroundMode.keySequenceRefusal(specs, repeat: count) { throw ActionError(refusal) }
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
