import CoreGraphics
import Foundation

/// Synthesized mouse and keyboard input, posted at the HID level (the box is dedicated: taking the real cursor and
/// keyboard focus is fine). Every key-down gets its key-up with modifiers cleared, so nothing is left held down
/// (a stuck modifier turns later typing into shortcuts).
public enum Input {
    public enum Button: String, Sendable, CaseIterable { case left, right, middle }

    // Only used from the serialized action path (ActionLock).
    nonisolated(unsafe) static let source = CGEventSource(stateID: .hidSystemState)

    static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]

    static func pause(_ ms: Int) { usleep(useconds_t(ms * 1000)) }   // lint:allow-blocking milliseconds between events

    /// An action abandoned at its deadline is cancelled; from then on it may only release what it pressed (key and
    /// button ups), never start new input that would land in the middle of the next action.
    static func post(_ event: CGEvent?) {
        guard let event else { return }
        let release = [.keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
            || (event.type == .flagsChanged && event.flags.intersection(modifierMask).isEmpty)
        if Task.isCancelled, !release { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    public static func move(to p: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        pause(15)
    }

    public static func click(at p: CGPoint, button: Button = .left, count: Int = 1, modifiers: CGEventFlags = []) {
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
        move(to: p)   // many apps need hover state before a click lands
        for i in 1...max(1, count) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.flags = modifiers
                post(e)
                pause(type == down ? 30 : 15)
            }
        }
    }

    /// Moves the pointer without clicking and leaves it there (hover). A second small move follows, since some
    /// apps (web views) only start hover tracking after more than one mouse-moved event.
    public static func hover(at p: CGPoint) {
        move(to: CGPoint(x: p.x - 2, y: p.y))
        move(to: p)
    }

    /// How a drag is paced. Finder starts a file drag only after a press that's held, then a small move; the Dock
    /// accepts a drop only after the pointer dwells on its icon.
    public struct DragTiming: Sendable {
        public var holdMs = 150      // after mouse-down, before the first move
        public var steps = 20        // intermediate mouse-dragged events
        public var dwellMs = 150     // over the target, before mouse-up
        public var modifiers: CGEventFlags = []
        public init() {}
    }

    public static func drag(from a: CGPoint, to b: CGPoint, timing: DragTiming = DragTiming()) {
        func event(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            e?.flags = timing.modifiers
            post(e)
        }
        move(to: a)
        event(.leftMouseDown, a)
        pause(max(0, timing.holdMs))
        // A few pixels first, so the drag starts at the source rather than wherever the first big step lands.
        let length = max(1, hypot(b.x - a.x, b.y - a.y))
        let nudge = CGPoint(x: a.x + (b.x - a.x) / length * 6, y: a.y + (b.y - a.y) / length * 6)
        event(.leftMouseDragged, nudge)
        pause(50)
        let steps = max(1, timing.steps)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            event(.leftMouseDragged, CGPoint(x: nudge.x + (b.x - nudge.x) * t, y: nudge.y + (b.y - nudge.y) * t))
            pause(12)
        }
        // Small moves over the target while dwelling: drop targets update their highlight on drag events.
        let dwell = max(0, timing.dwellMs), wiggles = max(1, dwell / 100)
        for i in 0..<wiggles {
            event(.leftMouseDragged, CGPoint(x: b.x + (i % 2 == 0 ? 1 : 0), y: b.y))
            pause(dwell / wiggles)
        }
        event(.leftMouseUp, b)
        pause(30)
    }

    public enum ScrollUnit: String, Sendable, CaseIterable { case line, pixel }

    /// Scrolls at a point (positive dy scrolls content down, i.e. reveals what's below), by lines like a mouse wheel
    /// or by pixels as continuous events like a trackpad. Modifiers are held for the whole scroll (cmd/ctrl-wheel
    /// zoom, shift-wheel, option-wheel).
    public static func scroll(at p: CGPoint, dx: Int = 0, dy: Int, unit: ScrollUnit = .line, modifiers: CGEventFlags = []) {
        move(to: p)
        if !modifiers.isEmpty { setModifiers(modifiers) }
        // Several small events scroll more reliably than one big one.
        let total = abs(dy) + abs(dx)
        let steps = max(1, min(unit == .line ? total : total / 10, 40))
        let ys = shares(dy, steps: steps), xs = shares(dx, steps: steps)
        for i in 0..<steps {
            let e = CGEvent(scrollWheelEvent2Source: source, units: unit == .line ? .line : .pixel, wheelCount: 2,
                            wheel1: ys[i], wheel2: xs[i], wheel3: 0)
            if unit == .pixel { e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            e?.flags = modifiers
            post(e)
            pause(12)
        }
        if !modifiers.isEmpty { setModifiers([]) }
    }

    /// Splits a scroll distance over `steps` events so they add up to exactly `d` (the remainder goes to the first
    /// events), as wheel deltas: positive `d` reveals content below or to the right, which is a negative delta.
    static func shares(_ d: Int, steps: Int) -> [Int32] {
        let base = abs(d) / steps, extra = abs(d) % steps, sign = d > 0 ? -1 : 1
        return (0..<steps).map { Int32(clamping: sign * (base + ($0 < extra ? 1 : 0))) }
    }

    /// Posts a flags-changed event, for apps that read the current modifier state rather than the event's flags.
    static func setModifiers(_ flags: CGEventFlags) {
        let e = CGEvent(source: source)
        e?.type = .flagsChanged
        e?.flags = flags
        post(e)
    }

    // MARK: Keyboard

    /// Types arbitrary text as Unicode, independent of keyboard layout. Newlines become Return, tabs Tab.
    public static func type(_ text: String) {
        var buffer = ""
        func flush() {
            for chunk in unicodeChunks(buffer) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.flags = []
                    chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    post(e)
                }
                pause(8)
            }
            buffer = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" { flush(); press(KeySpec(key: 36, flags: [])) }
            else if ch == "\t" { flush(); press(KeySpec(key: 48, flags: [])) }
            else { buffer.append(ch) }
        }
        flush()
    }

    /// Text as keyboard-event payloads of at most 20 UTF-16 units (the practical limit per event), split only between
    /// characters: half a surrogate pair or emoji sequence arrives as garbage. A longer single character goes alone.
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

    public static func press(_ spec: KeySpec, repeat count: Int = 1) {
        for _ in 0..<max(1, count) {
            if Task.isCancelled { break }   // a call abandoned at its deadline must not keep typing
            let down = CGEvent(keyboardEventSource: source, virtualKey: spec.key, keyDown: true)
            down?.flags = spec.flags
            post(down)
            pause(25)
            let up = CGEvent(keyboardEventSource: source, virtualKey: spec.key, keyDown: false)
            up?.flags = spec.flags
            post(up)
            pause(25)
        }
        // Release state: a flags-changed event with no modifiers.
        setModifiers([])
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
