import CoreGraphics
import Foundation
import Vision

/// Text recognition on screenshots, for UI that accessibility can't see: canvases, remote desktops, games, custom-drawn
/// controls. Each line comes with its box in the screenshot's pixels, so the screenshot id maps it back to the screen.
public enum OCR {
    public struct Line: Sendable, Equatable {
        public let text: String
        public let confidence: Float
        /// In the screenshot's pixels, top-left origin.
        public let box: CGRect
        public var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
    }

    /// Loads the accurate recognizer ahead of the first real request. Its first use on a machine compiles a model
    /// (measured: 61 s on this M1, once, then cached system-wide until an OS update); later loads take ~0.1 s.
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let blank = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            guard let image = blank?.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let took = Date().timeIntervalSince(started)
            if took > 5 { log("text recognition warmed up in \(Int(took)) s") }
        }
    }

    /// Recognized lines in reading order (top to bottom, then left to right). Vision blocks while it works, so it
    /// runs on a GCD thread rather than the cooperative pool.
    public static func recognize(png: Data, accurate: Bool = true) async throws -> [Line] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try recognizeBlocking(png: png, accurate: accurate) })
            }
        }
    }

    static func recognizeBlocking(png: Data, accurate: Bool) throws -> [Line] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ActionError("Not an image.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false   // UI text: labels, file names, numbers
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let lines: [Line] = (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox   // normalized, bottom-left origin
            return Line(text: best.string, confidence: best.confidence,
                        box: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
        return readingOrder(lines)
    }

    /// Top to bottom; lines whose vertical centers are within half a line height count as one row, left to right.
    static func readingOrder(_ lines: [Line]) -> [Line] {
        lines.sorted { a, b in
            let tolerance = min(a.box.height, b.box.height) / 2
            if abs(a.center.y - b.center.y) > tolerance { return a.center.y < b.center.y }
            return a.box.minX < b.box.minX
        }
    }
}
