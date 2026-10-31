import AppKit
import CoreGraphics
import Foundation
import Testing
import MacMCPCore

/// Not run by unit checks. Uses the installed agent and TestHost only when the parent opts into Integration.
/// Synchronous AgentClient exchanges and the existing fixture setup run on a native thread, not the task pool.
private let backgroundTestThreads = DedicatedThreads(name: "background-integration", count: 1)

private func backgroundTest(_ body: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        backgroundTestThreads.async { continuation.resume(with: Result { try body() }) }
    }
}

extension Integration {
@Suite struct BackgroundModeTests {
    @Test func nameSubmitAndMenuLeaveAnotherAppAndPointerAlone() async throws {
        try await backgroundTest {
            try closeMenus()
            try hostURL("dismiss")
            try hostURL("reset")
            let client = try AgentClient(clientName: "integration-tests-background", version: "1", timeout: 90, background: true)
            let snapshot = try client.call("mac_snapshot", ["app": hostApp]).text
            let name = try #require(ref(of: "textfield \"Name\"", in: snapshot))
            let submit = try #require(ref(of: "button \"Submit\"", in: snapshot))
            let activate = try agent().call("mac_app", ["action": "activate", "app": "com.apple.finder"])
            try #require(!activate.isError, "\(activate.text)")
            let front = try #require(Apps.frontmost()?.pid)
            let hostPID = try Apps.resolve(hostApp).pid
            try #require(front != hostPID)
            let pointer = try #require(CGEvent(source: nil)?.location)
            func unchanged() {
                #expect(Apps.frontmost()?.pid == front)
                #expect(CGEvent(source: nil)?.location == pointer)
            }

            let typed = try client.call("mac_type", ["ref": name, "text": "Background Example"])
            #expect(!typed.isError && typed.text.contains("field value verified"), "\(typed.text)")
            unchanged()
            let readback = try client.call("mac_snapshot", ["app": hostApp, "query": "Name"])
            #expect(readback.text.contains("= \"Background Example\""), "\(readback.text)")
            unchanged()
            let pressed = try client.call("mac_click", ["ref": submit])
            #expect(!pressed.isError && pressed.text.contains("Submitted: Background Example"), "\(pressed.text)")
            #expect(events().contains { $0.kind == "submit" && $0.detail.contains("Background Example") })
            unchanged()
            let menu = try client.call("mac_menu", ["app": hostApp, "path": "Test > Say Hello"])
            #expect(!menu.isError && menu.text.contains("Menu: Say Hello"), "\(menu.text)")
            #expect(events().contains { $0 == ("menu", "Say Hello") })
            unchanged()

            let coordinate = try client.call("mac_click", ["app": hostApp, "x": 10, "y": 10])
            #expect(coordinate.isError && coordinate.text.contains("background mode"), "\(coordinate.text)")
            unchanged()
            let drag = try client.call("mac_drag", ["from_ref": name, "to_ref": submit])
            #expect(drag.isError && drag.text.contains("background mode"), "\(drag.text)")
            unchanged()
            let doctor = try client.call("mac_doctor")
            #expect(doctor.text.contains("background mode: enabled"), "\(doctor.text)")
            unchanged()
        }
    }

    @Test func windowCaptureAndOCRWithAnotherAppFrontmost() async throws {
        try await backgroundTest {
            try closeMenus()
            try hostURL("dismiss")
            try hostURL("reset")
            let activate = try agent().call("mac_app", ["action": "activate", "app": "com.apple.finder"])
            try #require(!activate.isError, "\(activate.text)")
            let front = try #require(Apps.frontmost()?.pid)
            let pointer = try #require(CGEvent(source: nil)?.location)
            let client = try AgentClient(clientName: "integration-tests-background", version: "1", timeout: 90, background: true)
            let shot = try client.call("mac_screenshot", ["app": hostApp, "max_edge": 640])
            #expect(!shot.isError && !shot.images.isEmpty, "\(shot.text)")
            #expect(!shot.text.contains("captured from the display"))
            let ocr = try client.call("mac_screenshot", ["app": hostApp, "ocr": true, "find": "Order Form"])
            #expect(!ocr.isError && ocr.text.contains("\"Order Form\" @"), "\(ocr.text)")
            #expect(Apps.frontmost()?.pid == front)
            #expect(CGEvent(source: nil)?.location == pointer)
        }
    }
}
}
