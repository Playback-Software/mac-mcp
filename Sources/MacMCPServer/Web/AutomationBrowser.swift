import Foundation
import MacMCPCore

struct AutomationBrowser: Sendable {
    @TaskLocal static var selection = "safari"
    @TaskLocal static var maxChars = 12_000
    static let shared = AutomationBrowser()
    static var isChrome: Bool { selection == "chrome" }
    static var bundleID: String { isChrome ? "com.google.Chrome" : "com.apple.Safari" }
    static var name: String { isChrome ? "Google Chrome" : "Safari" }

    var started: Bool { get async { if Self.isChrome { return await ChromeBridge.shared.started }; return SafariBridge.shared.status != nil } }
    func call(_ tool: String, _ arguments: [String: Value] = [:], timeout: TimeInterval = 45) async throws -> SafariBridge.Reply {
        if Self.isChrome { return try await ChromeBridge.shared.call(tool, arguments, timeout: timeout) }
        if arguments.values.contains(where: { $0.stringValue?.hasPrefix("chrome-") == true }) {
            throw ActionError("That handle belongs to Chrome; pass browser=chrome.")
        }
        return try await SafariBridge.shared.call(tool, arguments, timeout: timeout)
    }
    func readMarkdown() async throws -> SafariBridge.Reply {
        if Self.isChrome { return try await call("get_page_content", ["format": "markdown"]) }
        return try await SafariBridge.shared.readMarkdown()
    }
    func interact(_ arguments: [String: Value]) async throws -> SafariBridge.Interaction {
        if Self.isChrome { return try await ChromeBridge.shared.interact(arguments) }
        return try await SafariBridge.shared.interact(arguments)
    }
    func finishParked() async -> SafariBridge.Reply? {
        if Self.isChrome { return await ChromeBridge.shared.finishParked() }
        return await SafariBridge.shared.finishParked()
    }
}
