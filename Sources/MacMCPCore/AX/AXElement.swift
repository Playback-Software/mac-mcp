import ApplicationServices
import Foundation

/// A thin, Sendable wrapper around `AXUIElement`.
///
/// Every attribute read is a synchronous IPC round trip into the target app's main thread, so reads are batched
/// (`read(_:)`) and each app element gets a messaging timeout: a hung app costs at most that long, not forever.
public struct AXElement: @unchecked Sendable, Hashable {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t, timeout: Float = 2.0) -> AXElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return AXElement(app)
    }

    /// The system-wide element, with a bounded wait: its hit tests go to whichever app is under the point, and a hung
    /// app would otherwise stall the caller for the default six seconds.
    public static var systemWide: AXElement {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 2.0)
        return AXElement(el)
    }

    public var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(raw, &pid)
        return pid
    }

    // MARK: Reading

    /// Reads several attributes in one round trip. Missing or unsupported attributes come back as nil, as do ones
    /// whose read failed; `read(reporting:)` tells those apart.
    public func read(_ names: [String]) -> [String: Any]? { read(reporting: names)?.values }

    /// A batched read that also says which attributes failed to read, and how: an error other than "unsupported" or
    /// "no value", which the value alone can't tell from an absent one. A label or identifier that failed to read is
    /// unknown, not empty. The error is kept because `kAXErrorFailure` is what some apps answer for attributes they
    /// don't have, and the walker re-reads those once before believing them.
    public struct Read {
        public var values: [String: Any]
        /// The attributes whose read failed, by error. Absent attributes (`absent`) aren't in it.
        public var errors: [String: AXError]
        public var failed: Set<String> { Set(errors.keys) }
        public init(values: [String: Any], errors: [String: AXError] = [:]) {
            self.values = values
            self.errors = errors
        }
    }

    public func read(reporting names: [String]) -> Read? {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as [AnyObject]? else { return nil }
        var result = Read(values: [:])
        for (name, value) in zip(names, array) {
            if let v = AXElement.unwrap(value) { result.values[name] = v }
            else if let error = AXElement.failure(in: value) { result.errors[name] = error }
        }
        return result
    }

    public func attribute(_ name: String) -> Any? { attribute(reporting: name).value }

    /// One attribute, and the error if its read failed rather than finding nothing (see `Read`): nil for a value
    /// read or an absent attribute.
    public func attribute(reporting name: String) -> (value: Any?, error: AXError?) {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        guard err == .success else { return (nil, Self.absent.contains(err) ? nil : err) }
        return (AXElement.unwrap(value), nil)
    }

    public func element(_ name: String) -> AXElement? { attribute(name).flatMap(AXElement.from) }

    /// The element an attribute value holds, if it is one.
    public static func from(_ value: Any) -> AXElement? {
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    /// Errors that mean an attribute has nothing to deliver, as opposed to a read that failed.
    static let absent: Set<AXError> = [.attributeUnsupported, .noValue, .notImplemented, .parameterizedAttributeUnsupported]

    /// Whether a value from a batched read is a per-attribute error other than an absent attribute.
    static func isFailure(_ value: AnyObject?) -> Bool { failure(in: value) != nil }

    /// The per-attribute error a value from a batched read carries, unless it means the attribute is absent.
    static func failure(in value: AnyObject?) -> AXError? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .axError else { return nil }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error), !absent.contains(error) else { return nil }
        return error
    }

    public func elements(_ name: String) -> [AXElement] { elements(reporting: name).elements }

    /// The elements an attribute holds, and the error if the read failed (see `attribute(reporting:)`): a failed
    /// read of a list's rows is a hole in the tree, not an empty list.
    public func elements(reporting name: String) -> (elements: [AXElement], error: AXError?) {
        let read = attribute(reporting: name)
        return ((read.value as? [AXUIElement])?.map(AXElement.init) ?? [], read.error)
    }

    public func string(_ name: String) -> String? { attribute(name) as? String }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }

    public var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Whether the element still exists. Elements die when their UI goes away (`invalidUIElement`); `cannotComplete`
    /// means the app didn't answer (busy or hung), which says nothing about the element, so it counts as alive.
    public var isAlive: Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &value)
        return err != .invalidUIElement
    }

    // MARK: Writing

    @discardableResult
    public func set(_ name: String, _ value: Any) -> AXError {
        Self.mutate { AXUIElementSetAttributeValue(raw, name as CFString, value as CFTypeRef) }
    }

    @discardableResult
    public func perform(_ action: String) -> AXError {
        Self.mutate { AXUIElementPerformAction(raw, action as CFString) }
    }

    /// Cancellation blocks new requests; an IPC request already sent to an app cannot be recalled.
    static func mutate(_ operation: () -> AXError) -> AXError {
        guard !Task.isCancelled else { return .cannotComplete }
        return operation()
    }

    // MARK: Hit testing

    /// The deepest element at a global point (top-left origin, points), as seen by this app element or system-wide.
    public func element(at point: CGPoint) -> AXElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(raw, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        return AXElement(hit)
    }

    // MARK: Values

    /// Converts AXValue-wrapped geometry to Foundation types and drops per-attribute errors (`isFailure` keeps them).
    static func unwrap(_ value: AnyObject?) -> Any? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return value }
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var p = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &p) && p.x.isFinite && p.y.isFinite ? p : nil
        case .cgSize:
            var s = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &s) && s.width.isFinite && s.height.isFinite ? s : nil
        case .cgRect:
            var r = CGRect.zero
            return AXValueGetValue(axValue, .cgRect, &r) && r.origin.x.isFinite && r.origin.y.isFinite
                && r.width.isFinite && r.height.isFinite ? r : nil
        case .cfRange:
            var r = CFRange()
            return AXValueGetValue(axValue, .cfRange, &r) ? r : nil
        case .axError:
            return nil
        default:
            return value
        }
    }

    public static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.raw, b.raw) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

/// Frame from batched position + size values. Some apps report non-finite geometry (seen in System Settings);
/// that's treated as "no frame", since converting it to integers traps.
func frame(position: Any?, size: Any?) -> CGRect? {
    guard let p = position as? CGPoint, let s = size as? CGSize,
          p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width >= 0, s.height >= 0 else { return nil }
    return CGRect(origin: p, size: s)
}

public extension BinaryFloatingPoint {
    /// An Int for display or arithmetic that can't trap: 0 for NaN/infinity, clamped to ±1e9.
    var safeInt: Int { isFinite ? Int(Swift.max(Swift.min(self, 1e9), -1e9)) : 0 }
}
