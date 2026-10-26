import Foundation
import Testing
@testable import MacMCPCore

@Suite struct ShortcutsTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String]] = []
        func add(_ a: [String]) { lock.withLock { items.append(a) } }
        var all: [[String]] { lock.withLock { items } }
    }

    @Test func listParsesNamesAndIdentifiers() {
        let text = "Resize Images (0A1B2C3D-0000-4000-8000-123456789ABC)\nMake GIF (with sound) (FFFFFFFF-1111-4222-8333-444444444444)\nPlain\n"
        let all = Shortcuts.parseList(text)
        #expect(all == [
            .init(name: "Resize Images", identifier: "0A1B2C3D-0000-4000-8000-123456789ABC"),
            .init(name: "Make GIF (with sound)", identifier: "FFFFFFFF-1111-4222-8333-444444444444"),
            .init(name: "Plain", identifier: nil),
        ])
        #expect(Shortcuts.find("resize images", in: all)?.identifier == "0A1B2C3D-0000-4000-8000-123456789ABC")
        #expect(Shortcuts.find("ffffffff-1111-4222-8333-444444444444", in: all)?.name == "Make GIF (with sound)")
        #expect(Shortcuts.find("Resize", in: all) == nil)   // exact names only
    }

    @Test func runPassesInputAndReadsTextOutput() async throws {
        let calls = Calls()
        let fake: Shortcuts.CLI = { args, _ in
            calls.add(args)
            let input = args.firstIndex(of: "--input-path").map { try? String(contentsOfFile: args[$0 + 1], encoding: .utf8) } ?? nil
            if let i = args.firstIndex(of: "--output-path") {
                try Data("echo: \(input ?? "")".utf8).write(to: URL(fileURLWithPath: args[i + 1]))
            }
            return Subprocess.Output(stdout: "", stderr: "", status: 0, timedOut: false)
        }
        let shortcut = Shortcuts.Info(name: "Echo", identifier: "0A1B2C3D-0000-4000-8000-123456789ABC")
        let r = try await Shortcuts.run(shortcut, input: "hello", timeout: 5, cli: fake)
        #expect(r.output == "echo: hello" && r.status == 0)
        let args = try #require(calls.all.first)
        #expect(args.prefix(2) == ["run", "0A1B2C3D-0000-4000-8000-123456789ABC"])   // by identifier: names can repeat
        #expect(args.contains("--output-type") && args.contains("public.plain-text"))
    }

    @Test func noOutputAndFailuresAreReported() async throws {
        let fake: Shortcuts.CLI = { _, _ in Subprocess.Output(stdout: "", stderr: "The action could not run", status: 1, timedOut: false) }
        let r = try await Shortcuts.run(.init(name: "X", identifier: nil), input: nil, timeout: 5, cli: fake)
        #expect(r.output == nil && r.status == 1 && r.stderr.contains("could not run"))
    }

    @Test func policyAllowsOnlyNamedShortcutsAndDefaultsToNone() throws {
        #expect(Policy().shortcuts.allowed.isEmpty)
        let p = try JSONDecoder().decode(Policy.self, from: Data(#"{"shortcuts":{"allowed":["Resize Images"]}}"#.utf8))
        #expect(p.shortcuts.allows(name: "resize images") && !p.shortcuts.allows(name: "Delete Everything"))
        #expect(p.shortcuts.timeoutSeconds == 60)
        let old = try JSONDecoder().decode(Policy.self, from: Data(#"{"deny_apps":[]}"#.utf8))
        #expect(old.shortcuts == Policy.ShortcutsPolicy())   // files from before M13 keep working
    }
}
