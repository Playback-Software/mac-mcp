import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Maps pixels in a screenshot back to global screen points (top-left origin).
public struct ScreenshotMapping: Sendable, Equatable {
    /// The captured area in global points.
    public let source: CGRect
    /// Output image size in pixels.
    public let pixelSize: CGSize
    /// The window this was captured from, with its frame at the time; nil for a display capture.
    public let window: CapturedWindow?
    public let takenAt: Date

    public struct CapturedWindow: Sendable, Equatable {
        public let id: UInt32
        public let frame: CGRect
        public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
    }

    public init(source: CGRect, pixelSize: CGSize, window: CapturedWindow? = nil, takenAt: Date = Date()) {
        self.source = source
        self.pixelSize = pixelSize
        self.window = window
        self.takenAt = takenAt
    }

    /// Screenshots older than this are refused for clicking: what's on screen has likely moved on.
    public static let maxAge: TimeInterval = 600

    /// Why a click at this screenshot's pixels would land somewhere else now, or nil if it still maps. `windows` is
    /// the current on-screen window list.
    public func staleReason(id: String, now: Date = Date(), windows: [WindowInfo]) -> String? {
        let retake = "Take a new mac_screenshot."
        if now.timeIntervalSince(takenAt) > Self.maxAge {
            return "Screenshot \(id) is \(Int(now.timeIntervalSince(takenAt) / 60)) minutes old; the screen has likely changed. \(retake)"
        }
        guard let window else { return nil }
        guard let now = windows.first(where: { $0.id == window.id }) else {
            return "The window in screenshot \(id) is gone (closed, minimized or on another Space). \(retake)"
        }
        if abs(now.bounds.minX - window.frame.minX) > 1 || abs(now.bounds.minY - window.frame.minY) > 1
            || abs(now.bounds.width - window.frame.width) > 1 || abs(now.bounds.height - window.frame.height) > 1 {
            return "The window in screenshot \(id) has moved or resized since it was taken, so its pixels no longer map to the screen. \(retake)"
        }
        return nil
    }

    public var pointsPerPixel: CGFloat { pixelSize.width > 0 ? source.width / pixelSize.width : 1 }

    public func point(forPixel p: CGPoint) -> CGPoint {
        CGPoint(x: source.minX + p.x * pointsPerPixel, y: source.minY + p.y * (pixelSize.height > 0 ? source.height / pixelSize.height : 1))
    }

    public func contains(pixel p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < pixelSize.width && p.y < pixelSize.height
    }

    /// Output size for a source area: native pixels (points × backing scale), scaled down so the long edge ≤ maxEdge.
    public static func outputSize(source: CGSize, backingScale: CGFloat, maxEdge: Int) -> CGSize {
        let native = CGSize(width: source.width * backingScale, height: source.height * backingScale)
        let longEdge = max(native.width, native.height)
        let scale = longEdge > CGFloat(maxEdge) ? CGFloat(maxEdge) / longEdge : 1
        return CGSize(width: max(1, (native.width * scale).rounded()), height: max(1, (native.height * scale).rounded()))
    }
}

public struct Screenshot: Sendable {
    public let id: String
    public let png: Data
    public let mapping: ScreenshotMapping
    public let subject: String
}

public actor ScreenshotStore {
    public static let shared = ScreenshotStore()
    private var mappings: [String: ScreenshotMapping] = [:]
    private var order: [String] = []
    private var next = 1

    public init() {}

    public func record(_ mapping: ScreenshotMapping) -> String {
        let id = "c\(next)"
        next += 1
        mappings[id] = mapping
        order.append(id)
        if order.count > 50 { mappings[order.removeFirst()] = nil }
        return id
    }

    public func mapping(_ id: String) -> ScreenshotMapping? { mappings[id] }
}

public enum CaptureError: Error, CustomStringConvertible {
    case permission
    case noWindow(String)
    case noDisplay
    case failed(String)

    public var description: String {
        switch self {
        case .permission:
            "Screen Recording is not granted to MacMCP. Enable it in System Settings > Privacy & Security > "
                + "Screen & System Audio Recording (run mac_doctor for details)."
        case let .noWindow(s): "No on-screen window for \(s). It may be minimized or on another Space."
        case .noDisplay: "No display found."
        case let .failed(s): "Capture failed: \(s)"
        }
    }
}

public enum Capture {
    public struct Request: Sendable {
        public var app: AppInfo?
        /// Region to capture, in global points. With an app, intersected with its window.
        public var region: CGRect?
        /// Display to capture when there's no app. Default: the one holding the region's center, else the main one.
        public var display: Displays.Display?
        public var maxEdge = 1280
        /// Apps whose windows are left out of a display capture (bundle ID, name) → excluded?
        public var exclude: @Sendable (String?, String?) -> Bool = { _, _ in false }
        public init() {}
    }

    /// ScreenCaptureKit's "Failed to start stream due to audio/video capture failure" (-3811).
    static func isStreamStartFailure(_ error: NSError) -> Bool {
        error.domain == SCStreamErrorDomain && error.code == -3811
    }

    public static func take(_ req: Request, store: ScreenshotStore = .shared) async throws -> Screenshot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CGPreflightScreenCaptureAccess() ? CaptureError.failed("\(error)") : CaptureError.permission
        }

        let filter: SCContentFilter
        var source: CGRect
        var subject: String
        var captured: ScreenshotMapping.CapturedWindow?
        if let app = req.app {
            // The app's frontmost normal window, in window-server z-order.
            let zOrder = WindowServer.onScreenWindows().filter { $0.pid == app.pid && $0.isNormalLayer }.map(\.id)
            guard let window = zOrder.lazy.compactMap({ id in content.windows.first { $0.windowID == id } }).first else {
                throw CaptureError.noWindow(app.name)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            source = window.frame
            captured = .init(id: window.windowID, frame: window.frame)
            subject = "\(app.name) window \"\(window.title ?? "")\""
        } else {
            let displays = Displays.all()
            let center = req.region.map { CGPoint(x: $0.midX, y: $0.midY) }
            guard let chosen = req.display ?? center.flatMap({ c in displays.first { $0.bounds.contains(c) } })
                    ?? displays.first(where: \.isMain) ?? displays.first,
                  let display = content.displays.first(where: { $0.displayID == chosen.id }) else {
                throw req.display.map { CaptureError.failed("display \($0.index) is no longer connected") } ?? CaptureError.noDisplay
            }
            let hidden = content.applications.filter { req.exclude($0.bundleIdentifier, $0.applicationName) }
            filter = SCContentFilter(display: display, excludingApplications: hidden, exceptingWindows: [])
            source = chosen.bounds
            subject = "display \(chosen.index) of \(displays.count) \"\(chosen.name)\""
                + (hidden.isEmpty ? "" : " (\(hidden.count) app(s) hidden by policy)")
        }

        let windowOrigin = source.origin
        if let region = req.region {
            let clipped = source.intersection(region)
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
                throw CaptureError.failed("region \(region) is outside the captured \(subject) at \(source)")
            }
            source = clipped
            // One capture covers one display or window; say so rather than silently returning less than was asked.
            if clipped != region.standardized {
                subject += " · region clipped to \(clipped.minX.safeInt),\(clipped.minY.safeInt) "
                    + "\(clipped.width.safeInt)x\(clipped.height.safeInt) (it extends beyond this \(req.app == nil ? "display" : "window"))"
            }
        }

        let size = ScreenshotMapping.outputSize(source: source.size, backingScale: CGFloat(filter.pointPixelScale), maxEdge: req.maxEdge)
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        // sourceRect is relative to the filtered content (window or display), in points.
        config.sourceRect = CGRect(x: source.minX - windowOrigin.x, y: source.minY - windowOrigin.y, width: source.width, height: source.height)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch let first as NSError where req.app != nil && Self.isStreamStartFailure(first) {
            // A window with a sheet or popover attached sometimes can't be captured on its own. Crop the display
            // instead: the same pixels, plus whatever overlaps the window.
            let displays = Displays.all()
            guard let chosen = displays.first(where: { $0.bounds.intersects(source) }),
                  let display = content.displays.first(where: { $0.displayID == chosen.id }) else {
                throw CaptureError.failed("\(first)")
            }
            let hidden = content.applications.filter { req.exclude($0.bundleIdentifier, $0.applicationName) }
            let cropConfig = SCStreamConfiguration()
            cropConfig.width = config.width
            cropConfig.height = config.height
            cropConfig.showsCursor = false
            cropConfig.sourceRect = CGRect(x: source.minX - chosen.bounds.minX, y: source.minY - chosen.bounds.minY,
                                           width: source.width, height: source.height)
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingApplications: hidden, exceptingWindows: []),
                    configuration: cropConfig)
            } catch {
                throw CaptureError.failed("\(first) (a display capture also failed: \(error))")
            }
            subject += " (captured from the display: the window couldn't be captured alone)"
        } catch {
            throw CaptureError.failed("\(error)")
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureError.failed("PNG encoding")
        }
        let mapping = ScreenshotMapping(source: source, pixelSize: CGSize(width: image.width, height: image.height), window: captured)
        let id = await store.record(mapping)
        return Screenshot(id: id, png: png, mapping: mapping, subject: subject)
    }
}
