import CoreGraphics
import CryptoKit
import Foundation
import os
import Vision

/// Text recognition on screenshots, for UI that accessibility can't see: canvases, remote desktops, games, custom-drawn
/// controls. Each line comes with its box in the screenshot's pixels, so the screenshot id maps it back to the screen.
public enum OCR {
    private static let threads = DedicatedThreads(name: "ocr", count: 2)
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
        threads.async {
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
    /// runs on two dedicated native threads. With a `memo`, a frame whose pixels equal the memo's last one returns
    /// that frame's lines without running Vision again.
    public static func recognize(image: CGImage, accurate: Bool = true, memo: Memo? = nil) async throws -> [Line] {
        try await withCheckedThrowingContinuation { continuation in
            threads.async {
                continuation.resume(with: Result {
                    guard let memo else { return try recognizeBlocking(image: image, accurate: accurate) }
                    return try memo.lines(for: image, accurate: accurate) {
                        try recognizeBlocking(image: image, accurate: accurate)
                    }
                })
            }
        }
    }

    /// The last frame recognized by one wait, so polling an unchanged window costs a hash, not a recognition. It
    /// holds one entry and lives as long as the wait; nothing is kept across calls.
    public final class Memo: Sendable {
        private struct State {
            var last: (fingerprint: SHA256.Digest, accurate: Bool, lines: [Line])?
            var reused = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        public init() {}

        /// Recognitions skipped because the frame matched the last one.
        public var reused: Int { state.withLock { $0.reused } }

        func lines(for image: CGImage, accurate: Bool, recognize: () throws -> [Line]) throws -> [Line] {
            guard let fingerprint = try? OCR.fingerprint(image) else { return try recognize() }
            let hit: [Line]? = state.withLock { s in
                guard let last = s.last, last.fingerprint == fingerprint, last.accurate == accurate else { return nil }
                s.reused += 1
                return last.lines
            }
            if let hit { return hit }
            let lines = try recognize()
            state.withLock { $0.last = (fingerprint, accurate, lines) }
            return lines
        }
    }

    /// SHA-256 of the frame's size, format, color interpretation and visible pixels (row padding left out). Identical
    /// pixels read the same way recognize identically, so equal fingerprints let a wait reuse the last result; a
    /// changed pixel changes it. An image with a decode array has none, so Vision always reads it.
    static func fingerprint(_ image: CGImage) throws -> SHA256.Digest {
        guard let data = image.dataProvider?.data, image.decode == nil else { throw ActionError("Not an image.") }
        var hasher = SHA256()
        let header = [image.width, image.height, image.bitsPerPixel, image.bitsPerComponent, Int(image.bitmapInfo.rawValue)]
        header.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data((image.colorSpace?.name as String? ?? "").utf8))
        let rowBytes = (image.width * image.bitsPerPixel + 7) / 8
        let stride = image.bytesPerRow
        let total = CFDataGetLength(data)
        guard let base = CFDataGetBytePtr(data), rowBytes > 0, stride >= rowBytes,
              total >= stride * (image.height - 1) + rowBytes else { throw ActionError("Not an image.") }
        for row in 0..<image.height {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base + row * stride, count: rowBytes))
        }
        return hasher.finalize()
    }

    static func recognizeBlocking(image: CGImage, accurate: Bool) throws -> [Line] {
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
