import Foundation
import Testing
import MacMCPCore

extension Integration {
@Suite struct SecureInputTests {
    init() throws { try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

    @Test func appendMovesPastMidFieldCaretAndSelection() throws {
        let name = try refFor("textfield \"Name\"")
        #expect(!(try agent().call("mac_type", ["ref": name, "text": "original"])).isError)
        #expect(!(try agent().call("mac_key", ["app": hostApp, "keys": "cmd+left, shift+right"])).isError)
        let result = try agent().call("mac_type", ["ref": name, "text": " suffix ", "mode": "append"])
        #expect(!result.isError && result.text.contains("field value verified"), "\(result.text)")
        #expect(events().last { $0.kind == "name" }?.detail == "original suffix ")
    }

    @Test func implicitTypingInsertsAtMidFieldCaret() throws {
        let name = try refFor("textfield \"Name\"")
        #expect(!(try agent().call("mac_type", ["ref": name, "text": "abcd"])).isError)
        #expect(!(try agent().call("mac_key", ["app": hostApp, "keys": "cmd+left, right"])).isError)
        let result = try agent().call("mac_type", ["app": hostApp, "text": "X"])
        #expect(!result.isError && result.text.contains("field value verified"), "\(result.text)")
        #expect(events().last { $0.kind == "name" }?.detail == "aXbcd")
    }

    @Test func implicitTypingReplacesOnlyTheCurrentSelection() throws {
        let name = try refFor("textfield \"Name\"")
        #expect(!(try agent().call("mac_type", ["ref": name, "text": "abcd"])).isError)
        #expect(!(try agent().call("mac_key", ["app": hostApp, "keys": "cmd+left, right, shift+right, shift+right"])).isError)
        let result = try agent().call("mac_type", ["app": hostApp, "text": "X"])
        #expect(!result.isError && result.text.contains("field value verified"), "\(result.text)")
        #expect(events().last { $0.kind == "name" }?.detail == "aXd")
    }

    @Test func explicitAppendToUnreadableFieldRefusesWithoutNavigation() throws {
        let result = try agent().call("mac_type", ["ref": try refFor("password \"Password\""), "text": "synthetic-secret", "mode": "append"])
        #expect(result.isError && result.text.contains("click where to type"), "\(result.text)")
        #expect(!result.text.contains("synthetic-secret"))
    }

    @Test func nativeSavePanelAcceptsTypingAndCancelsWithKeys() throws {
        try hostURL("save-panel")
        defer { try? hostURL("dismiss") }
        // The native panel is hosted remotely when TestHost is sandboxed.
        let result = try agent().call("mac_type", ["ref": try refFor("textfield \"Save As:"), "text": "Input review fixture"])
        #expect(!result.isError && result.text.contains("field value verified"), "\(result.text)")
        #expect(!(try agent().call("mac_key", ["app": hostApp, "keys": "esc"])).isError)
    }

    @Test func webFieldInsideOverflowGroupsAcceptsClickAndTyping() throws {
        try hostURL("web")
        defer { try? hostURL("dismiss") }
        let field = try refFor("textfield \"Web name\"")
        let click = try agent().call("mac_click", ["ref": field])
        #expect(!click.isError, "\(click.text)")
        let type = try agent().call("mac_type", ["ref": field, "text": "Web fixture"])
        #expect(!type.isError && type.text.contains("field value verified"), "\(type.text)")
    }

    @Test func replacementKeepsBoundaryWhitespace() throws {
        let result = try agent().call("mac_type", ["ref": try refFor("textfield \"Name\""), "text": " Ada "])
        #expect(!result.isError && result.text.contains("field value verified"), "\(result.text)")
        #expect(events().last { $0.kind == "name" }?.detail == " Ada ")
    }

    @Test func submitReportsVerificationBeforeReturn() throws {
        let result = try agent().call("mac_type", ["ref": try refFor("textfield \"Name\""), "text": "Verified", "submit": true])
        #expect(!result.isError && result.text.contains("field value verified; pressed Return"), "\(result.text)")
        #expect(events().last { $0.kind == "submit" }?.detail.contains("Verified") == true)
    }

    @Test func secureSubmissionIsExplicitlyUnverified() throws {
        let result = try agent().call("mac_type", ["ref": try refFor("password \"Password\""), "text": "synthetic-secret", "submit": true])
        #expect(!result.isError && result.text.contains("submitted unverified"), "\(result.text)")
        #expect(!result.text.contains("synthetic-secret"))
    }
}
}
