import ApplicationServices
import CoreText
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func markWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Labels are existing refs, not a new coordinate namespace. Actions still re-resolve and guard each ref.
public enum ScreenshotMarks {
    public struct Mark: Sendable, Equatable {
        public let ref: String
        public let pixels: CGRect
    }

    public static func windowID(of root: AXElement) -> UInt32? {
        var element: AXElement? = root
        for _ in 0..<20 {
            guard let current = element else { break }
            var id: CGWindowID = 0
            if markWindowID(current.raw, &id) == .success, id != 0 { return id }
            element = current.element(kAXParentAttribute)
        }
        return nil
    }

    public static func select(rows: [Row], mapping: ScreenshotMapping) -> [Mark] {
        guard mapping.source.width > 0, mapping.source.height > 0 else { return [] }
        let sx = mapping.pixelSize.width / mapping.source.width, sy = mapping.pixelSize.height / mapping.source.height
        return rows.compactMap { row -> Mark? in
            guard row.kind == .interactive, row.role != "password", !row.identityUncertain,
                  let ref = row.ref, let frame = row.frame, !frame.isInfinite, !frame.isNull,
                  frame.width > 0, frame.height > 0 else { return nil }
            let visible = frame.intersection(mapping.source)
            guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { return nil }
            return Mark(ref: ref, pixels: CGRect(x: (visible.minX - mapping.source.minX) * sx,
                y: (visible.minY - mapping.source.minY) * sy, width: visible.width * sx, height: visible.height * sy))
        }.prefix(100).map { $0 }
    }

    public static func draw(_ marks: [Mark], on image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.failed("annotation context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 12, nil)
        for mark in marks {
            let rect = CGRect(x: mark.pixels.minX, y: CGFloat(image.height) - mark.pixels.maxY,
                              width: mark.pixels.width, height: mark.pixels.height)
            context.setStrokeColor(CGColor(red: 0.1, green: 1, blue: 0.3, alpha: 1))
            context.setLineWidth(2); context.stroke(rect.insetBy(dx: 1, dy: 1))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: mark.ref, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 6
            let box = CGRect(x: min(rect.minX, max(0, CGFloat(image.width) - width)),
                             y: max(0, min(rect.maxY - 18, CGFloat(image.height) - 18)), width: width, height: 18)
            context.setFillColor(CGColor(gray: 0, alpha: 0.9)); context.fill(box)
            context.textPosition = CGPoint(x: box.minX + 3, y: box.minY + 4); CTLineDraw(line, context)
        }
        guard let result = context.makeImage() else { throw CaptureError.failed("annotated image") }
        return result
    }
}
