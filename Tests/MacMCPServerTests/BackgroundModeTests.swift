import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct BackgroundSessionTests {
    @Test(arguments: [false, true])
    func modeIsConnectionOwnedAndCannotBeChangedByMCP(_ background: Bool) async throws {
        let server = ServerDefinition(name: "mode", version: "1", instructions: "Instructions", tools: []) { _, _, context in
            CallResult(content: [.text(context.background ? "background" : "foreground")])
        }
        let peer = try Peer(server)
        defer { peer.close() }
        if background { peer.sendRaw("#mac-mcp background=true") }
        peer.send(request(1, "initialize", ["protocolVersion": "2025-11-25", "background": .bool(!background)]))
        let initialized = try #require(await peer.next())
        #expect(initialized["result"]?["instructions"]?.stringValue?.contains("Background mode:") == background)
        peer.sendRaw("#mac-mcp background=\(background ? "false" : "true")")
        peer.send(request(2, "tools/call", ["name": "mode", "arguments": ["background": .bool(!background)],
                                           "_meta": ["background": .bool(!background)]]))
        let reply = try #require(await peer.next())
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"] == .string(background ? "background" : "foreground"))
        #expect(await peer.session.background == background)
        var meta = modernMeta.objectValue!
        meta["background"] = .bool(!background)
        peer.send(request(3, "server/discover", ["_meta": .object(meta)]))
        let discovered = try #require(await peer.next())
        #expect(discovered["result"]?["instructions"]?.stringValue?.contains("Background mode:") == background)
        #expect(await peer.session.snapshot(version: "2026-07-28", info: nil).background == background)
    }

    @Test func relayStripsModeDirectivesOnInitialAndReconnectedStreams() {
        var relay = RelaySession()
        #expect(relay.fromClient(Data("#mac-mcp background=true".utf8)).toAgent.isEmpty)
        _ = relay.agentLost(now: 0)
        #expect(relay.fromClient(Data("#mac-mcp background=false".utf8)).toAgent.isEmpty)
        #expect(relay.held.isEmpty)
        #expect(relay.agentReconnected().toAgent.isEmpty)
    }

    @Test func optInIsStickyEvenInRepeatedPreambles() async {
        let session = Session()
        await session.apply(directive: "#mac-mcp background=true")
        await session.apply(directive: "#mac-mcp background=false")
        #expect(await session.background)
    }

    @Test func eachCallKeepsItsModeAcrossConcurrentClientsAndReportsIt() async {
        let directory = NSTemporaryDirectory() + "background-context-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let spec = ToolSpec(name: "mode", description: "mode", annotations: .readOnly) { _, _ in
            .text(BackgroundMode.enabled ? "background handler" : "foreground handler")
        }
        let server = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: [spec], pause: AgentPause())
        let foreground = RequestContext(client: "test", protocolVersion: nil, leaseToken: nil, origin: nil, id: "f", leasePath: directory + "/lease")
        let pinnedBackground = RequestContext(client: "test", protocolVersion: nil, leaseToken: nil, origin: nil, id: "b",
                                             background: true, leasePath: directory + "/lease")
        async let a = server.call("mode", [:], foreground)
        async let b = server.call("mode", ["background": false], pinnedBackground)
        let (normal, hidden) = await (a, b)
        #expect(text(normal) == "foreground handler")
        #expect(text(hidden) == "Background mode: enabled.\nbackground handler")
    }

    @Test func unsupportedToolsRefuseBeforeTheirHandlersAndRemainAudited() async throws {
        let directory = NSTemporaryDirectory() + "background-refusals-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let calls: [(String, [String: Value])] = [
            ("mac_click", ["x": 10, "y": 10]), ("mac_click", ["x": 10, "y": 10, "screenshot_id": "c1"]),
            ("mac_drag", ["from_ref": "e1", "to_ref": "e2"]), ("mac_hover", ["ref": "e1"]),
            ("mac_scroll", ["ref": "e1"]), ("mac_window", ["action": "focus"]),
            ("mac_window", ["action": "restore"]), ("mac_app", ["action": "activate"]),
            ("mac_app", ["action": "launch", "open": "https://example.com"]),
            ("mac_clipboard", ["action": "set"]), ("mac_script", [:]), ("mac_shortcut", ["action": "run"]), ("web_read", [:]), ("web_act", [:]),
        ]
        let specs = Set(calls.map(\.0)).map { name in
            ToolSpec(name: name, description: name, annotations: .readOnly) { _, _ in
                Issue.record("unsupported handler ran: \(name)"); return .text("ran")
            }
        }
        let server = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: specs, pause: AgentPause())
        let context = RequestContext(client: "test", protocolVersion: nil, leaseToken: nil, origin: nil, id: "b",
                                     background: true, leasePath: directory + "/lease")
        for (name, args) in calls {
            let result = await server.call(name, args, context)
            #expect(result.isError)
            #expect(text(result).contains("Refused: background mode"))
        }
        let lines = try String(contentsOfFile: directory + "/audit", encoding: .utf8).split(separator: "\n")
        #expect(lines.count == calls.count)
        #expect(lines.allSatisfy { $0.contains("\"outcome\":\"refused\"") })
        for (name, args) in [("mac_click", ["ref": Value.string("e1")]), ("mac_scroll", ["to_ref": "e1"]),
                             ("mac_app", ["action": "launch"]), ("mac_window", ["action": "list"]), ("mac_shortcut", ["action": "list"])] {
            #expect(backgroundRefusal(tool: name, args: ToolArgs(args)) == nil)
        }
    }

    @Test func unsafeRoutesRefuseWithoutGlobalFocusOrHitTests() throws {
        let clipboard = ClipboardInfo(types: [], source: nil, changeCount: 0)
        BackgroundMode.$enabled.withValue(true) {
            for step in [ActionRoute.Step.target(nil, point: CGPoint(x: 10, y: 10), pid: nil, opens: false),
                         .drag(from: .zero, to: .zero, pid: nil), .key(try! KeySpec.parse("cmd+tab"), pid: nil),
                         .typing("text", mode: .replace, pid: 42)] {
                #expect(RouteGuards.refusal(step, policy: Policy(), clipboard: clipboard)?.contains("background mode") == true)
            }
            #expect(RouteGuards.refusal(.key(try! KeySpec.parse("a"), pid: getpid()), policy: Policy(), clipboard: clipboard)?.contains("MacMCP") == true)
        }
    }

    @Test func backgroundPanelsAreCheckedWithoutAnyFocusedWindow() {
        // An inactive app's window inventory, independent of focus: 1 is a document, 2 is a file-panel sheet.
        #expect(RouteGuards.backgroundHasFilePanel(windows: [1], panel: { $0 == 2 }, children: { _ in [2] }))
        #expect(RouteGuards.backgroundHasFilePanel(windows: [2], panel: { $0 == 2 }, children: { _ in [] }))
        #expect(!RouteGuards.backgroundHasFilePanel(windows: [1], panel: { $0 == 2 }, children: { _ in [] }))
        #expect(RouteGuards.backgroundHasFilePanel(windows: nil as [Int]?, panel: { _ in false }, children: { _ in [] }))
        #expect(RouteGuards.backgroundHasFilePanel(windows: [1], panel: { _ in false }, children: { _ in nil }))
        #expect(RouteGuards.backgroundHasFilePanel(windows: Array(0..<65), panel: { _ in false }, children: { _ in [] }))
        #expect(RouteGuards.backgroundHasFilePanel(windows: [1], panel: { _ in false }, children: { _ in Array(0..<129) }))
    }

    @Test func pauseAndClaimAdmissionStillApplyToBackgroundActions() async {
        let directory = NSTemporaryDirectory() + "background-admission-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let spec = ToolSpec(name: "action", description: "action", annotations: .action) { _, _ in
            Issue.record("blocked action ran"); return .text("ran")
        }
        let context = RequestContext(client: "test", protocolVersion: nil, leaseToken: nil, origin: nil, id: "b",
                                     background: true, leasePath: directory + "/lease")
        let paused = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: [spec], pause: AgentPause(paused: true))
        #expect(text(await paused.call("action", [:], context)).contains(AgentPause.refusal))
        let claims = Claims(maxWait: 0)
        _ = await claims.tryBegin("gui", session: "other", client: "other", origin: nil)
        let claimed = MacMCPServer.definition(audit: AuditLog(path: directory + "/audit"), tools: [spec], pause: AgentPause(), claims: claims)
        #expect((await claimed.call("action", [:], context)).isError)
    }

    private func text(_ result: CallResult) -> String {
        result.content.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined(separator: "\n")
    }
}
