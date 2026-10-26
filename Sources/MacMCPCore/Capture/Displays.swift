import AppKit
import CoreGraphics
import Foundation

/// The active displays, numbered the same way everywhere: the main display is 1, the rest follow left to right,
/// then top to bottom. Bounds are global points with a top-left origin, as in snapshot frames and click coordinates.
public enum Displays {
    public struct Display: Sendable, Equatable {
        public let index: Int
        public let id: CGDirectDisplayID
        public let bounds: CGRect
        public let scale: CGFloat
        public let isMain: Bool
        public let name: String

        public var line: String {
            "display \(index)\(isMain ? " (main)" : ""): \"\(name)\" id \(id) · \(bounds.width.safeInt)x\(bounds.height.safeInt) "
                + "points at \(bounds.minX.safeInt),\(bounds.minY.safeInt) · scale \(String(format: "%g", Double(scale)))x"
        }
    }

    public static func all() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        let main = CGMainDisplayID()
        let raw = ids.prefix(Int(count)).map { id -> (CGDirectDisplayID, CGRect, CGFloat) in
            let b = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) } ?? b.width
            return (id, b, b.width > 0 ? pixels / b.width : 1)
        }
        return order(raw.map { (id: $0.0, bounds: $0.1) }, main: main).enumerated().map { i, d in
            let scale = raw.first { $0.0 == d.id }?.2 ?? 1
            return Display(index: i + 1, id: d.id, bounds: d.bounds, scale: scale, isMain: d.id == main,
                           name: names[d.id] ?? "Display \(d.id)")
        }
    }

    /// Main first, then left to right, then top to bottom.
    static func order(_ displays: [(id: CGDirectDisplayID, bounds: CGRect)], main: CGDirectDisplayID)
        -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        displays.sorted { a, b in
            if (a.id == main) != (b.id == main) { return a.id == main }
            return a.bounds.minX != b.bounds.minX ? a.bounds.minX < b.bounds.minX : a.bounds.minY < b.bounds.minY
        }
    }

    /// A display by index ("2"), display ID, or "main".
    public static func find(_ query: String, in displays: [Display] = all()) -> Display? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q == "main" { return displays.first(where: \.isMain) }
        guard let n = UInt32(q) else { return nil }
        return displays.first { $0.index == Int(n) } ?? displays.first { $0.id == n }
    }
}
