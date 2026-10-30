import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Synthesized input. Each sequence owns its cleanup, including when its action is abandoned at a deadline.
public enum Input {
    public enum Button: String, Sendable, CaseIterable { case left, right, middle }
    nonisolated(unsafe) static let source = CGEventSource(stateID: .hidSystemState)

    /// Revocation closes the race between abandoning an action and it starting another input sequence.
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        private var active = 0
        func begin() throws {
            try lock.withLock {
                guard !revoked else { throw CancellationError() }
                active += 1
            }
        }
        func check() throws {
            try lock.withLock { if revoked { throw CancellationError() } }
        }
        func end() { lock.withLock { active -= 1 } }
        func revoke() { lock.withLock { revoked = true } }
        var drained: Bool { lock.withLock { active == 0 } }
    }
    @TaskLocal static var session: Session?
    @TaskLocal public static var leaseCheck: LeaseStore.InputCheck?

    /// Tests replace both the guard and event sink; they never send input to the desktop.
    struct Environment: @unchecked Sendable {
        var check: (pid_t?, Bool) throws -> Void
        var post: (CGEvent) -> Void
        var windows: (@Sendable () -> [WindowInfo])? = nil
        var dragCleanup: (@Sendable (CGPoint, pid_t?) throws -> DragCleanupState)? = nil
    }
    @TaskLocal static var environment: Environment?

    static let promptRefusal = "A macOS security or permission prompt is on screen. A person must answer it before input can continue."

    static func promptBlocks(hasPrompts: Bool, targetIsPrompt: Bool, focusIsPrompt: Bool, focusKnown: Bool) -> Bool {
        hasPrompts || targetIsPrompt || focusIsPrompt
    }

    static func keyboardRefusal(target: pid_t, exists: Bool, frontmost: pid_t?, focused: pid_t?, focusName: String?) -> String? {
        guard exists else { return "The target app quit. Open it and take a new mac_snapshot before sending keys." }
        guard frontmost == target else { return "The target app is no longer frontmost. Activate it and retry." }
        if let focused, focused != target {
            return "Keyboard focus is held by \(focusName ?? "another process"). Dismiss it or focus the target app and retry."
        }
        return nil
    }

    static func check(pid: pid_t?, keyboard: Bool = false, point: CGPoint? = nil,
                      validate: @escaping @Sendable () throws -> Void = {}, route: ActionRoute.Step? = nil) async throws {
        try Task.checkCancellation()
        try session?.check()
        let environment = environment, leaseCheck = leaseCheck, inputSession = session
        try await guardWork {
            do { try leaseCheck?.check() }
            catch { inputSession?.revoke(); throw error }
            let windows = environment.map { $0.windows?() ?? [] } ?? WindowServer.onScreenWindows()
            try $guardWindows.withValue(windows) {
                if let environment { try environment.check(pid, keyboard) }
                else { try checkBlocking(pid: pid, keyboard: keyboard, windows: windows) }
                try validate()
            }
        }
        if let route { try await ActionRoute.validate(route) }
        else if let point { try await ActionRoute.validate(.target(nil, point: point, pid: pid, opens: false)) }
        if ActionRoute.check != nil, route != nil || point != nil {
            try await check(pid: pid, keyboard: keyboard, validate: validate)
        }
        try Task.checkCancellation()
        try session?.check()
    }

    static func sequence(_ body: () async throws -> Void) async throws {
        try Task.checkCancellation()
        try session?.begin()
        defer { session?.end() }
        try await body()
    }

    static func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(max(0, ms))) }

    /// Only cleanup bypasses the guard, and only for a down this sequence actually posted.
    static func post(_ event: CGEvent?) {
        guard let event else { return }
        if let environment { environment.post(event) } else { event.post(tap: .cghidEventTap) }
    }

    static func setModifiers(_ flags: CGEventFlags) {
        let e = CGEvent(source: source)
        e?.type = .flagsChanged
        e?.flags = flags
        post(e)
    }

    public static func move(to p: CGPoint, pid: pid_t? = nil) async throws {
        try await sequence {
            try await check(pid: pid, point: p)
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
            try await pause(15)
        }
    }

    public static func click(at p: CGPoint, button: Button = .left, count: Int = 1, modifiers: CGEventFlags = [], pid: pid_t? = nil) async throws {
        try await sequence {
            let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
            case .left: (.leftMouseDown, .leftMouseUp, .left)
            case .right: (.rightMouseDown, .rightMouseUp, .right)
            case .middle: (.otherMouseDown, .otherMouseUp, .center)
            }
            try await move(to: p, pid: pid)
            var pressedModifiers = false
            defer { if pressedModifiers { setModifiers([]) } }
            for i in 1...max(1, count) {
                try await check(pid: pid, point: p, route: .target(nil, point: p, pid: pid, opens: count >= 2))
                let e = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: cgButton)
                guard let e else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e.flags = modifiers
                post(e)
                pressedModifiers = !modifiers.isEmpty
                do {
                    defer {
                        e.type = up
                        e.flags = Task.isCancelled ? [] : modifiers
                        post(e)
                    }
                    try await pause(30)
                }
                try await pause(15)
            }
        }
    }

    public static func hover(at p: CGPoint, pid: pid_t? = nil) async throws {
        try await sequence {
            try await move(to: CGPoint(x: p.x - 2, y: p.y), pid: pid)
            try await move(to: p, pid: pid)
        }
    }

    public struct DragTiming: Sendable {
        public var holdMs = 150
        public var steps = 20
        public var dwellMs = 150
        public var modifiers: CGEventFlags = []
        public init() {}
    }

    public static func drag(from a: CGPoint, to b: CGPoint, timing: DragTiming = DragTiming(), pid: pid_t? = nil,
                            validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await sequence {
            guard let mouse = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left) else {
                throw ActionError("Could not create mouse input. Check mac_doctor and retry.")
            }
            func event(_ type: CGEventType, _ p: CGPoint, cleanup: Bool = false) {
                mouse.type = type
                mouse.location = p
                mouse.setIntegerValueField(.mouseEventClickState, value: 1)
                mouse.flags = cleanup ? [] : timing.modifiers
                post(mouse)
            }
            try await move(to: a, pid: pid)
            try await check(pid: pid, point: a, validate: validate, route: .drag(from: a, to: b, pid: pid, modifiers: timing.modifiers))
            event(.leftMouseDown, a)
            defer { if !timing.modifiers.isEmpty { setModifiers([]) } }
            do {
                try await pause(timing.holdMs)
                let length = max(1, hypot(b.x - a.x, b.y - a.y))
                let nudge = CGPoint(x: a.x + (b.x - a.x) / length * 6, y: a.y + (b.y - a.y) / length * 6)
                try await check(pid: pid, point: nudge, validate: validate, route: .drag(from: a, to: b, pid: pid, modifiers: timing.modifiers))
                event(.leftMouseDragged, nudge)
                try await pause(50)
                let steps = max(1, timing.steps)
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let p = CGPoint(x: nudge.x + (b.x - nudge.x) * t, y: nudge.y + (b.y - nudge.y) * t)
                    try await check(pid: pid, point: p, validate: validate, route: .drag(from: a, to: b, pid: pid, modifiers: timing.modifiers))
                    event(.leftMouseDragged, p)
                    try await pause(12)
                }
                let dwell = max(0, timing.dwellMs), wiggles = max(1, dwell / 100)
                for i in 0..<wiggles {
                    let p = CGPoint(x: b.x + (i % 2 == 0 && i < wiggles - 1 ? 1 : 0), y: b.y)
                    try await check(pid: pid, point: p, validate: validate, route: .drag(from: a, to: b, pid: pid, modifiers: timing.modifiers))
                    event(.leftMouseDragged, p)
                    try await pause(dwell / wiggles)
                }
                try await check(pid: pid, point: b, validate: validate, route: .drag(from: a, to: b, pid: pid, modifiers: timing.modifiers))
                event(.leftMouseUp, b)
            } catch {
                let cleanup = await dragCleanup(at: a, pid: pid)
                if cleanup.escape {
                    let escape = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
                    escape?.flags = []
                    post(escape)
                    escape?.type = .keyUp
                    post(escape)
                }
                let release = cleanup.source ? a : cleanup.fallback
                if cleanup.source || cleanup.fallbackSafe { event(.leftMouseDragged, release, cleanup: true) }
                event(.leftMouseUp, release, cleanup: true)
                if !cleanup.source {
                    let place = cleanup.fallbackSafe ? "over the menu bar" : "outside displays"
                    log("drag aborted: no verified source drop; released " + place)
                    throw ActionError("Drag stopped; no safe source drop could be verified. "
                        + (cleanup.fallbackSafe ? "Released over the menu bar, where nothing takes a drop." : "Released outside all displays to avoid a window drop.")
                        + " Take mac_snapshot and check the result.", audit: "drag aborted; released " + place)
                }
                throw error
            }
        }
    }

    public enum ScrollUnit: String, Sendable, CaseIterable { case line, pixel }

    public static func scroll(at p: CGPoint, dx: Int = 0, dy: Int, unit: ScrollUnit = .line, modifiers: CGEventFlags = [],
                              pid: pid_t? = nil, validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await sequence {
            try await move(to: p, pid: pid)
            try await check(pid: pid, point: p, validate: validate)
            if !modifiers.isEmpty { setModifiers(modifiers) }
            defer { if !modifiers.isEmpty { setModifiers([]) } }
            let total = abs(dy) + abs(dx)
            let steps = max(1, min(unit == .line ? total : total / 10, 40))
            let ys = shares(dy, steps: steps), xs = shares(dx, steps: steps)
            for i in 0..<steps {
                try await check(pid: pid, point: p, validate: validate)
                let e = CGEvent(scrollWheelEvent2Source: source, units: unit == .line ? .line : .pixel, wheelCount: 2,
                                wheel1: ys[i], wheel2: xs[i], wheel3: 0)
                if unit == .pixel { e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
                e?.flags = modifiers
                post(e)
                try await pause(12)
            }
        }
    }

    static func shares(_ d: Int, steps: Int) -> [Int32] {
        let base = abs(d) / steps, extra = abs(d) % steps, sign = d > 0 ? -1 : 1
        return (0..<steps).map { Int32(clamping: sign * (base + ($0 < extra ? 1 : 0))) }
    }

    /// `replacing`: ⌘A was just sent to select what the text replaces. A newline or tab in the text is sent as Return or
    /// Tab, each checked as a key of one call with the text before it (see `OpenRoutes.typedKeys`).
    public static func type(_ text: String, pid: pid_t? = nil, replacing: Bool = false) async throws {
        try await sequence {
            var buffer = ""
            func flush() async throws {
                for chunk in unicodeChunks(buffer) {
                    try await check(pid: pid, keyboard: true, route: .text(String(decoding: chunk, as: UTF16.self), pid: pid))
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
                    e.flags = []
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    post(e)
                    e.type = .keyUp
                    post(e)
                    try await pause(8)
                }
                buffer = ""
            }
            let keys = OpenRoutes.typedKeys(text, replacing: replacing)
            var position = replacing ? 1 : 0
            func control(_ code: CGKeyCode) async throws {
                try await flush()
                let sequence = keys.map { ActionRoute.KeySequence(keys: $0, index: position, typed: true) }
                try await ActionRoute.$keySequence.withValue(sequence) { try await press(KeySpec(key: code, flags: []), pid: pid) }
            }
            for ch in text {
                try Task.checkCancellation()
                if ch == "\n" || ch == "\r" || ch == "\r\n" { try await control(36) }
                else if ch == "\t" { try await control(48) }
                else { buffer.append(ch) }
                position += 1
            }
            try await flush()
        }
    }

    static func unicodeChunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = [], current: [UniChar] = []
        for ch in text {
            let units = Array(String(ch).utf16)
            if !current.isEmpty, current.count + units.count > 20 { chunks.append(current); current = [] }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public static func press(_ spec: KeySpec, repeat count: Int = 1, pid: pid_t? = nil) async throws {
        try await sequence {
            for _ in 0..<max(1, count) {
                try await check(pid: pid, keyboard: true, route: .key(spec, pid: pid))
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: spec.key, keyDown: true) else { continue }
                e.flags = spec.flags
                post(e)
                do {
                    defer {
                        e.type = .keyUp
                        e.flags = []
                        post(e)
                        if !spec.flags.isEmpty { setModifiers([]) }
                    }
                    try await pause(25)
                }
                try await pause(25)
            }
        }
    }
}

/// A key plus modifiers, parsed from specs like "cmd+shift+s", "esc", "return", "f5", "alt+left".
public struct KeySpec: Sendable, Equatable {
    public let key: CGKeyCode
    public let flags: CGEventFlags

    public init(key: CGKeyCode, flags: CGEventFlags) { self.key = key; self.flags = flags }

    public enum ParseError: Error, CustomStringConvertible {
        case unknownKey(String), empty
        public var description: String {
            switch self {
            case .empty: "Empty key spec. Use names like \"cmd+s\", \"return\", \"esc\", \"shift+tab\", \"f5\"."
            case let .unknownKey(k): "Unknown key \"\(k)\". Use a letter, digit, punctuation, or a name: return, enter, "
                + "tab, space, delete, forwarddelete, esc, up, down, left, right, home, end, pageup, pagedown, f1–f20, "
                + "comma, period, slash, semicolon, quote, bracketleft, bracketright, minus, equal, backslash, grave."
            }
        }
    }

    static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    /// US ANSI virtual key codes. Shortcuts are defined by key position, so this works on other layouts for letters
    /// that sit in the same place; text entry never uses these (it goes through Unicode).
    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            // Punctuation by name, for specs where the character itself is awkward (a comma is also the separator).
            "comma": 43, "period": 47, "slash": 44, "semicolon": 41, "quote": 39, "apostrophe": 39,
            "bracketleft": 33, "bracketright": 30, "minus": 27, "equal": 24, "equals": 24, "backslash": 42,
            "grave": 50, "backtick": 50,
        ]
        let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fkeys.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()

    /// "cmd+shift" for a set of modifier flags.
    public static func describe(_ flags: CGEventFlags) -> String {
        [(CGEventFlags.maskControl, "ctrl"), (.maskAlternate, "alt"), (.maskShift, "shift"), (.maskCommand, "cmd"), (.maskSecondaryFn, "fn")]
            .filter { flags.contains($0.0) }.map(\.1).joined(separator: "+")
    }

    /// Parses a modifier list like "cmd+shift" (for clicks with modifiers).
    public static func modifiers(_ spec: String) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for m in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) where !m.isEmpty {
            guard let f = modifierNames[m] else { throw ParseError.unknownKey(m) }
            flags.insert(f)
        }
        return flags
    }

    /// Parses a sequence of key specs separated by commas or spaces: "cmd+a, delete" or "down down return".
    /// A comma right after "+" is the comma key, so "cmd+," is Cmd-comma ("comma" names it too).
    public static func parseSequence(_ specs: String) throws -> [KeySpec] {
        var parts: [String] = [], current = ""
        for ch in specs {
            if ch == " " || (ch == "," && !current.hasSuffix("+")) {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard !parts.isEmpty else { throw ParseError.empty }
        return try parts.map(parse)
    }

    /// Parses a list of key specs, one per element: ["cmd+,", "return"]. Elements may themselves be sequences.
    public static func parseSequence(_ specs: [String]) throws -> [KeySpec] {
        let keys = try specs.flatMap { try parseSequence($0) }
        guard !keys.isEmpty else { throw ParseError.empty }
        return keys
    }

    public static func parse(_ spec: String) throws -> KeySpec {
        let lower = spec.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { throw ParseError.empty }
        // The plus key itself: "+" or "cmd++".
        if lower == "+" || lower.hasSuffix("++") {
            let flags = try modifiers(String(lower.dropLast(lower == "+" ? 1 : 2)))
            return KeySpec(key: 24, flags: flags.union(.maskShift))
        }
        let parts = lower.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.last, !name.isEmpty else { throw ParseError.empty }
        let flags = try modifiers(parts.dropLast().joined(separator: "+"))
        guard let code = keyCodes[name] else { throw ParseError.unknownKey(name) }
        return KeySpec(key: code, flags: flags)
    }
}
