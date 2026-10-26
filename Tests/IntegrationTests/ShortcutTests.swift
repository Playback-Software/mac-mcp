import Foundation
import Testing
import MacMCPCore

/// mac_shortcut against the real Shortcuts CLI. The run test needs a shortcut named "MacMCP Test" that outputs the
/// text "MacMCP shortcut OK" (made once in the Shortcuts app; signing one from the CLI needs iCloud). Without it,
/// that test is skipped. Policy is swapped temporarily, as in PolicyTests.
extension Integration {
@Suite struct ShortcutTests {
    static let testShortcut = "MacMCP Test"
    static var installed: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").contains { $0 == testShortcut }
    }

    @Test func listWorksAndRunIsRefusedUnlessAllowed() throws {
        let list = try agent().call("mac_shortcut", ["action": "list"])
        #expect(!list.isError, "\(list.text)")
        let refused = try agent().call("mac_shortcut", ["action": "run", "name": Self.testShortcut])
        #expect(refused.isError)
        #expect(refused.text.contains(Self.installed ? "isn't in shortcuts.allowed" : "No shortcut named"), "\(refused.text)")
    }

    @Test(.enabled(if: ShortcutTests.installed)) func allowedShortcutRunsAndReturnsItsOutput() throws {
        try withPolicy(#"{"shortcuts":{"allowed":["\#(Self.testShortcut)"]}}"#) {
            let r = try agent().call("mac_shortcut", ["action": "run", "name": Self.testShortcut, "input": "ping"])
            #expect(!r.isError && r.text.contains("MacMCP shortcut OK"), "\(r.text)")
        }
    }
}
}
