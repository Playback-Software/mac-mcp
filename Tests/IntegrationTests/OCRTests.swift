import Foundation
import Testing
import MacMCPCore

extension Integration {
@Suite struct OCRIntegrationTests {
    init() throws { try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

    /// The TestHost canvas is drawn and hidden from accessibility: only text recognition finds its targets.
    @Test func clickACanvasTargetFoundByText() throws {
        #expect(!(try hostSnapshot()).contains("Canvas"))
        let shot = try agent().call("mac_screenshot", ["app": hostApp, "ocr": true, "find": "Canvas Launch"])
        #expect(!shot.isError && shot.images.isEmpty, "\(shot.text)")
        let id = try #require(shot.text.firstMatch(of: /screenshot (c\d+)/).map { String($0.1) })
        let point = try #require(shot.text.firstMatch(of: /"Canvas Launch" @(\d+),(\d+)/), "\(shot.text)")
        let r = try agent().call("mac_click", ["x": Int(point.1)!, "y": Int(point.2)!, "screenshot_id": id, "app": hostApp])
        #expect(!r.isError, "\(r.text)")
        #expect(try hostSnapshot(["query": "Canvas:"]).contains("Canvas: launch"))
    }

    @Test func doctorReportsHealth() throws {
        let d = try agent().call("mac_doctor").text
        #expect(d.contains("Health (checked every 10 min") && d.contains("all fine"), "\(d)")
    }

    @Test func waitForCanvasTextUsingOCR() throws {
        let result = try agent().call("mac_wait", ["app": hostApp, "until": "text", "query": "Canvas Launch",
                                                   "ocr": true, "timeout": 10])
        #expect(!result.isError && result.text.contains("met after") && result.text.contains("(OCR)"), "\(result.text)")
        #expect(result.text.contains("screenshot c") && result.text.contains("Canvas Launch"))
        let missing = try agent().call("mac_wait", ["app": hostApp, "until": "text", "query": "NoSuchCanvasText123",
                                                    "ocr": true, "timeout": 1])
        #expect(missing.isError && missing.text.contains("Timed out") && missing.text.contains("mac_screenshot"), "\(missing.text)")
    }
}
}
