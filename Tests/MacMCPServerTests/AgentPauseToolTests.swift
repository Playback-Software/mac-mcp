import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct AgentPauseToolTests {
    private func context(_ directory: String) -> RequestContext {
        RequestContext(client: "test", protocolVersion: nil, leaseToken: nil, origin: "unit test",
                       id: UUID().uuidString, leasePath: directory + "/lease")
    }

    private func text(_ result: CallResult) -> String {
        result.content.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined(separator: "\n")
    }

    @Test func everyMutatingToolIsRefusedBeforeItsHandler() async throws {
        let directory = NSTemporaryDirectory() + "pause-tools-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause(paused: true)
        let server = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: MacMCPServer.tools, pause: state)
        let calls: [(String, [String: Value])] = [
            ("mac_click", [:]), ("mac_type", [:]), ("mac_key", ["keys": "ctrl+alt+shift+cmd+period"]),
            ("mac_scroll", [:]), ("mac_drag", [:]), ("mac_hover", [:]), ("mac_menu", [:]),
            ("mac_app", ["action": "launch"]), ("mac_window", ["action": "close"]),
            ("mac_clipboard", ["action": "set"]), ("mac_script", [:]), ("mac_shortcut", ["action": "run"]),
            ("web_navigate", [:]), ("web_act", [:]), ("web_eval", [:]),
            ("web_tabs", ["action": "new"]), ("web_dialog", ["action": "accept"]),
        ]
        for (name, args) in calls {
            let result = await server.call(name, args, context(directory))
            #expect(result.isError, "\(name)")
            #expect(text(result) == AgentPause.refusal, "\(name): \(text(result))")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/audit"))
        let entries = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().withISO8601().decode(AuditEntry.self, from: Data($0.utf8))
        }
        #expect(entries.count == calls.count)
        #expect(entries.allSatisfy { $0.outcome == "refused" })
    }

    @Test func readOnlyAndMixedToolReadsStillAnswerAndHaveNoResumeRoute() async {
        let directory = NSTemporaryDirectory() + "pause-tools-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause(paused: true)
        let read = ToolSpec(name: "read", description: "read", annotations: .readOnly) { _, _ in .text("read answer") }
        let mixed = ToolSpec(name: "mixed", description: "mixed", annotations: .action,
                             mutates: { $0.string("action") != "list" }) { _, _ in .text("list answer") }
        let server = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: [read, mixed], pause: state)
        #expect(text(await server.call("read", [:], context(directory))) == "read answer")
        #expect(text(await server.call("mixed", ["action": "list"], context(directory))) == "list answer")
        #expect(text(await server.call("mixed", ["action": "resume"], context(directory))) == AgentPause.refusal)
        let actual = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: MacMCPServer.tools, pause: state)
        for name in ["resume", "mac_resume", "mac-mcp resume"] {
            #expect(text(await actual.call(name, [:], context(directory))).hasPrefix("Unknown tool"))
        }
        #expect(state.status.paused)
        for (name, args) in [("mac_app", ["action": Value.string("list")]), ("mac_window", ["action": .string("list")]),
                             ("mac_clipboard", ["action": .string("get")]), ("mac_shortcut", ["action": .string("list")]),
                             ("web_tabs", ["action": .string("list")]), ("web_dialog", ["action": .string("list")])] {
            let spec = MacMCPServer.tools.first { $0.tool.name == name }
            #expect(spec?.mutates(ToolArgs(args)) == false, "\(name)")
        }
    }

    @Test func pauseCancelsDispatchedActionAndReadOnlyStillWorks() async {
        let directory = NSTemporaryDirectory() + "pause-tools-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let entered = Signal(), state = AgentPause()
        let action = ToolSpec(name: "act", description: "act", annotations: .action) { _, _ in
            entered.fire()
            do { try await Task.sleep(for: .seconds(120)); Issue.record("Action was not cancelled") }
            catch {}
            return .text("ended")
        }
        let read = ToolSpec(name: "read", description: "read", annotations: .readOnly) { _, _ in .text("answer") }
        let server = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: [action, read],
                                             pause: state, claims: Claims())
        let task = Task { await server.call("act", [:], context(directory)) }
        await entered.wait()
        state.pause()
        #expect(text(await task.value) == AgentPause.refusal)
        #expect(text(await server.call("read", [:], context(directory))) == "answer")
    }

    @Test func ownPIDIsRefusedByEveryRouteKind() {
        let key = KeySpec(key: 36, flags: [])
        let steps: [ActionRoute.Step] = [.key(key, pid: getpid()), .text("resume", pid: getpid()),
            .typing("resume", mode: .insert, pid: getpid()), .target(nil, point: nil, pid: getpid(), opens: false),
            .drag(from: .zero, to: .zero, pid: getpid())]
        for step in steps {
            #expect(RouteGuards.refusal(step, policy: Policy(denyApps: []), clipboard: ClipboardInfo(types: [])) == AgentSafety.refusal)
        }
    }

    @Test func pauseAlsoStopsCallsWaitingForAnotherSessionsClaim() async {
        let directory = NSTemporaryDirectory() + "pause-tools-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let entered = Signal(), waiting = Signal(), state = AgentPause()
        let claims = Claims(pause: { waiting.fire(); try await Task.sleep(for: .seconds(120)) })
        let action = ToolSpec(name: "act", description: "act", annotations: .action) { _, _ in
            entered.fire()
            do { try await Task.sleep(for: .seconds(120)); Issue.record("Action was not cancelled") }
            catch {}
            return .text("ended")
        }
        let server = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: [action],
                                             pause: state, claims: claims)
        let first = Task { await server.call("act", [:], context(directory)) }
        await entered.wait()
        let second = Task { await server.call("act", [:], context(directory)) }
        await waiting.wait()
        state.pause()
        #expect(text(await first.value) == AgentPause.refusal)
        #expect(text(await second.value) == AgentPause.refusal)
    }
}

private extension JSONDecoder {
    func withISO8601() -> JSONDecoder { dateDecodingStrategy = .iso8601; return self }
}
