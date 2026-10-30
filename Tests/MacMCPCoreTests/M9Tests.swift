import AppKit
import Foundation
import Testing
@testable import MacMCPCore

@Suite struct HealthRuleTests {
    @Test func healthyBoxHasNoProblems() {
        var o = HealthMonitor.Observation()
        o.visibleWindows = 5
        o.capturableWindows = 5
        #expect(HealthMonitor.problems(o, secureFor: 0).isEmpty)
    }

    @Test func eachProblemIsFoundAndExplained() {
        var o = HealthMonitor.Observation()
        o.accessibility = false
        o.screenRecording = false
        let p = HealthMonitor.problems(o, secureFor: 0)
        #expect(p.count == 2 && p.allSatisfy { $0.kind == .permission })
        #expect(p[0].summary.contains("Accessibility") && p[1].summary.contains("Screen Recording"))

        var wallpaper = HealthMonitor.Observation()
        wallpaper.visibleWindows = 4
        wallpaper.capturableWindows = 0
        #expect(HealthMonitor.problems(wallpaper, secureFor: 0).first?.summary.contains("only the wallpaper") == true)

        var secure = HealthMonitor.Observation()
        secure.secureInput = (42, "Terminal")
        #expect(HealthMonitor.problems(secure, secureFor: 60).isEmpty)   // briefly on: a person typing a password
        #expect(HealthMonitor.problems(secure, secureFor: 20 * 60).first?.summary.contains("held by Terminal") == true)
    }

    @Test func screenRecordingReapprovalIsRecognized() {
        let reapproval = HealthMonitor.promptSummary(owner: "UserNotificationCenter",
            text: "\"MacMCP\" is requesting to bypass the system private window picker and directly access your screen and audio.")
        #expect(reapproval.contains("periodic Screen Recording re-approval") && reapproval.contains("Choose Allow"))
        let other = HealthMonitor.promptSummary(owner: "SecurityAgent", text: "Software Update wants to make changes.")
        #expect(other.contains("from SecurityAgent") && !other.contains("re-approval"))
        var o = HealthMonitor.Observation()
        o.prompts = [("UserNotificationCenter", "x")]
        #expect(HealthMonitor.problems(o, secureFor: 0).first?.kind == .prompt)
    }
}

@Suite struct HealthAlertTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Alerts.Kind, String)] = []
        func add(_ k: Alerts.Kind, _ m: String) { lock.withLock { items.append((k, m)) } }
        var all: [(Alerts.Kind, String)] { lock.withLock { items } }
    }

    /// The whole path a person depends on, except the OS probe: a check that observes a lost permission sends an
    /// alert to the webhook, and the cooldown keeps the next check from repeating it.
    @Test func lostPermissionReachesTheWebhookOnce() async {
        let sent = Sent()
        let alerts = Alerts { _, message, kind in sent.add(kind, message); return true }
        let monitor = HealthMonitor(alerts: alerts, policy: { Policy(alertWebhook: "https://ntfy.example/t") }) {
            var o = HealthMonitor.Observation()
            o.screenRecording = false
            return o
        }
        let t0 = Date()
        let report = await monitor.check(now: t0)
        #expect(report.problems.count == 1)
        #expect(sent.all.count == 1 && sent.all[0].0 == .permission && sent.all[0].1.contains("lost Screen Recording"))
        await monitor.check(now: t0.addingTimeInterval(60))        // a minute later: within the 10-minute cooldown
        #expect(sent.all.count == 1)
        await monitor.check(now: t0.addingTimeInterval(11 * 60))   // past it: the person is reminded
        #expect(sent.all.count == 2)
    }

    @Test func lockedScreenIsNeverAlerted() async {
        let sent = Sent()
        let alerts = Alerts { _, message, kind in sent.add(kind, message); return true }
        let monitor = HealthMonitor(alerts: alerts, policy: { Policy(alertWebhook: "https://ntfy.example/t") }) {
            var o = HealthMonitor.Observation()
            o.skipped = "the screen is locked"
            o.screenRecording = false
            return o
        }
        let report = await monitor.check()
        #expect(report.skipped == "the screen is locked" && report.problems.isEmpty && sent.all.isEmpty)
    }

    @Test func secureInputCountsAsStuckOnlyAfterTheLimit() async {
        let sent = Sent()
        let alerts = Alerts { _, message, kind in sent.add(kind, message); return true }
        let monitor = HealthMonitor(alerts: alerts, policy: { Policy(alertWebhook: "https://ntfy.example/t") }) {
            var o = HealthMonitor.Observation()
            o.secureInput = (77, "Terminal")
            return o
        }
        let t0 = Date()
        #expect(await monitor.check(now: t0).problems.isEmpty)
        #expect(await monitor.check(now: t0.addingTimeInterval(10 * 60)).problems.isEmpty)
        #expect(await monitor.check(now: t0.addingTimeInterval(16 * 60)).problems.first?.summary.contains("Terminal") == true)
        #expect(sent.all.count == 1)
    }
}

@Suite struct OpaqueRegionTests {
    func node(_ role: String, _ frame: CGRect, title: String? = nil, _ children: [RawNode] = []) -> RawNode {
        var n = RawNode(role: role, title: title, frame: frame)
        n.children = children
        return n
    }

    @Test func emptyCanvasIsFlaggedButRealContentIsNot() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let canvas = node("AXGroup", CGRect(x: 0, y: 100, width: 800, height: 450))
        let toolbar = node("AXButton", CGRect(x: 0, y: 0, width: 80, height: 30), title: "Play")
        let regions = Snapshot.opaqueRegions(node("AXWindow", window, [toolbar, canvas]))
        #expect(regions == [CGRect(x: 0, y: 100, width: 800, height: 450)])

        let list = node("AXScrollArea", CGRect(x: 0, y: 100, width: 800, height: 450),
                        [node("AXStaticText", CGRect(x: 0, y: 100, width: 100, height: 20), title: "Item 1")])
        #expect(Snapshot.opaqueRegions(node("AXWindow", window, [toolbar, list])).isEmpty)
        let small = node("AXGroup", CGRect(x: 0, y: 100, width: 100, height: 100))
        #expect(Snapshot.opaqueRegions(node("AXWindow", window, [toolbar, small])).isEmpty)
    }
}

@Suite struct OCRTests {
    /// Renders text into an image the way a canvas app would draw it: pixels only.
    func render(_ lines: [(String, CGPoint)], size: CGSize = CGSize(width: 600, height: 240)) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (text, p) in lines {   // p in top-left coordinates
            (text as NSString).draw(at: NSPoint(x: p.x, y: size.height - p.y - 24),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // GitHub's macOS runners are virtual machines, where Vision's text recognizer may not be able to start. CI
    // (set by GitHub Actions) skips this one test; it runs everywhere else.
    @Test(.timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func recognizesTextWithItsPosition() async throws {
        let image = render([("Launch Sequence", CGPoint(x: 40, y: 40)), ("Abort 42", CGPoint(x: 360, y: 160))])
        let lines = try await OCR.recognize(image: image)
        let launch = try #require(lines.first { $0.text.contains("Launch") })
        let abort = try #require(lines.first { $0.text.contains("Abort") })
        #expect(launch.center.x < 300 && launch.center.y < 100)
        #expect(abort.center.x > 300 && abort.center.y > 120)
        #expect(lines.firstIndex(of: launch)! < lines.firstIndex(of: abort)!)   // reading order
    }

    /// A copy of `image` with one pixel changed.
    func touched(_ image: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 3, y: 3, width: 1, height: 1))
        return ctx.makeImage()!
    }

    @Test func fingerprintFollowsThePixels() throws {
        let image = render([("Same", CGPoint(x: 40, y: 40))])
        #expect(try OCR.fingerprint(image) == OCR.fingerprint(image))
        #expect(try OCR.fingerprint(image) == OCR.fingerprint(render([("Same", CGPoint(x: 40, y: 40))])))
        #expect(try OCR.fingerprint(image) != OCR.fingerprint(touched(image)))
        #expect(try OCR.fingerprint(image) != OCR.fingerprint(render([("Same", CGPoint(x: 40, y: 40))], size: CGSize(width: 601, height: 240))))
        // The same bytes read through another color space or a decode array look different, so they never match.
        func reinterpreted(_ space: CGColorSpace, decode: [CGFloat]?) -> CGImage? {
            CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                    bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space,
                    bitmapInfo: image.bitmapInfo, provider: image.dataProvider!, decode: decode,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
        let p3 = try #require(reinterpreted(CGColorSpace(name: CGColorSpace.displayP3)!, decode: nil))
        #expect(try OCR.fingerprint(image) != OCR.fingerprint(p3))
        let inverted = try #require(reinterpreted(image.colorSpace!, decode: [1, 0, 1, 0, 1, 0]))
        #expect(throws: (any Error).self) { try OCR.fingerprint(inverted) }
    }

    @Test func memoSkipsRecognitionOnlyForUnchangedFrames() throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let memo = OCR.Memo()
        func pass(_ image: CGImage, accurate: Bool = true) throws -> [OCR.Line] {
            try memo.lines(for: image, accurate: accurate) {
                counter.n += 1
                return [OCR.Line(text: "run \(counter.n)", confidence: 1, box: .zero)]
            }
        }
        let frame = render([("Wait", CGPoint(x: 40, y: 40))])
        #expect(try pass(frame).map(\.text) == ["run 1"])
        #expect(try pass(render([("Wait", CGPoint(x: 40, y: 40))])).map(\.text) == ["run 1"])   // same pixels, new image
        #expect(counter.n == 1 && memo.reused == 1)
        #expect(try pass(touched(frame)).map(\.text) == ["run 2"])   // one pixel differs
        #expect(try pass(touched(frame), accurate: false).map(\.text) == ["run 3"])   // other recognition level
        #expect(try pass(frame).map(\.text) == ["run 4"])   // the memo holds the last frame only
        #expect(counter.n == 4 && memo.reused == 1)
    }

    @Test(.timeLimit(.minutes(3))) func memoReturnsTheSameLinesForAnUnchangedFrame() async throws {
        let image = render([("Launch Sequence", CGPoint(x: 40, y: 40))])
        let memo = OCR.Memo()
        let first = try await OCR.recognize(image: image, memo: memo)
        let second = try await OCR.recognize(image: image, memo: memo)
        #expect(!first.isEmpty && first == second && memo.reused == 1)
    }

    @Test func readingOrderGroupsRows() {
        func line(_ t: String, _ x: CGFloat, _ y: CGFloat) -> OCR.Line {
            OCR.Line(text: t, confidence: 1, box: CGRect(x: x, y: y, width: 50, height: 20))
        }
        let ordered = OCR.readingOrder([line("c", 10, 100), line("b", 200, 12), line("a", 10, 10)])
        #expect(ordered.map(\.text) == ["a", "b", "c"])
    }
}
