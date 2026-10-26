import Foundation
import Testing
import MacMCPCore

/// The installed `mac-mcp` relay keeps one MCP session alive across an agent restart.
extension Integration {
@Suite struct RelayTests {
    /// Starts `mac-mcp relay` and speaks MCP to it over its stdio, as an MCP client would.
    func relaySession() throws -> (AgentClient, Process) {
        var toRelay: [Int32] = [0, 0], fromRelay: [Int32] = [0, 0]
        #expect(pipe(&toRelay) == 0 && pipe(&fromRelay) == 0)
        _ = fcntl(toRelay[1], F_SETNOSIGPIPE, 1)
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: Paths.cli)
        relay.arguments = ["relay"]
        // closeOnDealloc must stay false: these ends are closed explicitly below, and a second close at dealloc
        // (whenever ARC gets to it) would hit whatever socket reused the number, e.g. a later test's client.
        relay.standardInput = FileHandle(fileDescriptor: toRelay[0], closeOnDealloc: false)
        relay.standardOutput = FileHandle(fileDescriptor: fromRelay[1], closeOnDealloc: false)
        try relay.run()
        close(toRelay[0])
        close(fromRelay[1])
        let client = try AgentClient(clientName: "integration-tests", version: "1",
                                     input: fromRelay[0], output: toRelay[1])
        return (client, relay)
    }

    func agentPID(_ doctor: String) -> String? {
        doctor.firstMatch(of: /agent pid (\d+)/).map { String($0.1) }
    }

    /// A remote client's SSH link drops mid-call: sshd closes the relay's stdin. The relay exits and the agent
    /// cancels the call, so nothing is left running (or holding the GUI) for a client that's gone.
    @Test func droppedLinkEndsTheRelayAndCancelsTheCall() throws {
        var toRelay: [Int32] = [0, 0], fromRelay: [Int32] = [0, 0]
        #expect(pipe(&toRelay) == 0 && pipe(&fromRelay) == 0)
        _ = fcntl(toRelay[1], F_SETNOSIGPIPE, 1)
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: Paths.cli)
        relay.arguments = ["relay"]
        // Closed explicitly below; closeOnDealloc would close the numbers again later, hitting whatever reused them.
        relay.standardInput = FileHandle(fileDescriptor: toRelay[0], closeOnDealloc: false)
        relay.standardOutput = FileHandle(fileDescriptor: fromRelay[1], closeOnDealloc: false)
        try relay.run()
        close(toRelay[0])
        close(fromRelay[1])
        let query = "NoSuchApp-\(UUID())"
        func send(_ line: String) { _ = (line + "\n").withCString { write(toRelay[1], $0, strlen($0)) } }
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"integration-tests","version":"1"}}}"#)
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mac_wait","arguments":{"until":"app","query":"\#(query)","timeout":20}}}"#)
        Thread.sleep(forTimeInterval: 1.5)
        let dropped = Date()
        close(toRelay[1])   // the link is gone
        while relay.isRunning, Date().timeIntervalSince(dropped) < 5 { Thread.sleep(forTimeInterval: 0.1) }
        close(fromRelay[0])
        #expect(!relay.isRunning, "the relay outlived its client")
        // The agent records the call as cancelled within a moment, long before its 20 s timeout.
        var entry: String?
        let deadline = Date().addingTimeInterval(5)
        while entry == nil, Date() < deadline {
            entry = (try? String(contentsOfFile: Paths.auditLog, encoding: .utf8))?
                .split(separator: "\n").last { $0.contains(query) }.map(String.init)
            if entry == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        #expect(entry?.contains("cancelled by the client") == true, "\(entry ?? "no audit entry")")
        #expect(Date().timeIntervalSince(dropped) < 8)
    }

    @Test func sessionSurvivesAgentRestart() throws {
        let (client, relay) = try relaySession()
        defer { relay.terminate() }
        let before = try client.call("mac_doctor")
        #expect(!before.text.hasPrefix("protocol error"), "\(before.text)")

        // Restart the agent while a call is waiting on it: that call fails fast instead of hanging...
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/sh")
        kick.arguments = ["-c", "sleep 1; launchctl kickstart -k gui/$(id -u)/\(Paths.launchAgentLabel)"]
        try kick.run()
        let started = Date()
        let cut = try client.call("mac_wait", ["until": "app", "query": "NoSuchApp-\(UUID())", "timeout": 20])
        kick.waitUntilExit()
        #expect(kick.terminationStatus == 0)
        #expect(cut.isError)
        #expect(cut.text.contains("agent restarted"), "\(cut.text)")
        #expect(Date().timeIntervalSince(started) < 10)

        // ...and the next call on the same session reaches the new agent.
        let after = try client.call("mac_doctor")
        #expect(!after.text.hasPrefix("protocol error"), "\(after.text)")
        #expect(agentPID(after.text) != nil && agentPID(after.text) != agentPID(before.text))
        let tools = try client.listTools()
        #expect(tools.contains("mac_snapshot"))
        #expect(relay.isRunning)
    }
}
}
