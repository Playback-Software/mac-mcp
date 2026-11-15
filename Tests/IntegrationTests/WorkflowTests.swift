import Foundation
import Testing
import MacMCPCore

extension Integration {
@Suite struct WorkflowTests {
    init() throws { try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

    @Test func incrementalSnapshotsStayOnTheirConnection() throws {
        let client = try agent()
        let before = try client.call("mac_snapshot", ["app": hostApp])
        let id = try #require(before.text.firstMatch(of: /snapshot (s[0-9]+)/)?.1).description
        let name = try #require(ref(of: "textfield \"Name\"", in: before.text))
        let typed = try client.call("mac_type", ["ref": name, "text": "Workflow smoke"])
        #expect(!typed.isError, "\(typed.text)")
        let diff = try client.call("mac_snapshot", ["app": hostApp, "since": id])
        #expect(!diff.isError && diff.text.contains("Workflow smoke"), "\(diff.text)")
        #expect(diff.text.contains("changes since"))
        let other = try agent().call("mac_snapshot", ["app": hostApp, "since": id])
        #expect(other.isError && other.text.contains("this connection"))
    }

    @Test func annotatedAppCaptureAndInstalledTerminology() throws {
        let client = try agent()
        let shot = try client.call("mac_screenshot", ["app": hostApp, "annotate": true])
        #expect(!shot.isError && shot.text.contains("Labels are AX refs"), "\(shot.text)")
        #expect(!shot.text.contains("hunter2"))
        let dictionary = try client.call("mac_script", ["action": "dictionary", "app": "Finder"])
        #expect(!dictionary.isError && dictionary.text.contains("Installed scripting terminology"), "\(dictionary.text)")
    }
}
}
