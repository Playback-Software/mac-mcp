import Foundation
import Testing
import MacMCPCore

extension Integration {
@Suite struct RelayReplayDeadlineTests {
    /// Exercises the actual relay process against two fake agent connections. Uses only a temporary socket;
    /// no agent restart, GUI access, live socket or LaunchAgent operations are involved.
    @Test(arguments: ["silent", "error", "version"])
    func replacementAgentMustCompleteCompatibleInitialize(_ reply: String) throws {
        // Under /tmp: NSTemporaryDirectory (/var/folders/…) makes the socket path longer than sun_path's 104 bytes.
        let directory = "/tmp/mm-replay-\(UUID().uuidString.prefix(8))"
        let path = directory + "/mcp.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try UnixSocket.listen(path: path)
        let replayed = DispatchSemaphore(value: 0), stop = DispatchSemaphore(value: 0), finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            func acceptPeer() throws -> Int32 {
                try StreamIO.wait(listener, events: Int16(POLLIN), deadline: StreamIO.now + 10)
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { throw SocketError("accept", path: path) }
                try StreamIO.configure(fd)
                return fd
            }
            func initialize(_ fd: Int32) throws -> [String: Any] {
                var framing = LineBuffer(), buffer = [UInt8](repeating: 0, count: 4096)
                let deadline = StreamIO.now + 10
                while true {
                    try StreamIO.wait(fd, events: Int16(POLLIN), deadline: deadline)
                    let n = read(fd, &buffer, buffer.count)
                    guard n > 0 else { throw SocketError("read", path: path) }
                    for line in framing.append(buffer[0..<n]) {
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                           object["method"] as? String == "initialize" { return object }
                    }
                }
            }
            do {
                let first = try acceptPeer()
                let request = try initialize(first)
                let response: [String: Any] = ["jsonrpc": "2.0", "id": request["id"]!, "result": ["protocolVersion": "2025-11-25"]]
                try StreamIO.writeAll(first, JSONSerialization.data(withJSONObject: response) + [0x0A], deadline: StreamIO.now + 5)
                close(first)
                let second = try acceptPeer()
                defer { close(second) }
                let replay = try initialize(second)
                replayed.signal()
                if reply != "silent" {
                    var response: [String: Any] = ["jsonrpc": "2.0", "id": replay["id"]!]
                    if reply == "error" { response["error"] = ["code": -32602, "message": "initialize refused"] }
                    else { response["result"] = ["protocolVersion": "2025-06-18"] }
                    try StreamIO.writeAll(second, JSONSerialization.data(withJSONObject: response) + [0x0A], deadline: StreamIO.now + 5)
                }
                _ = stop.wait(timeout: .now() + 20)
            } catch { replayed.signal() }
        }
        let relay = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let ended = DispatchSemaphore(value: 0)
        relay.executableURL = URL(fileURLWithPath: Paths.cli)
        relay.arguments = ["relay"]
        relay.environment = ProcessInfo.processInfo.environment.merging([
            "MAC_MCP_SOCKET": path, "MAC_MCP_LEASE_FILE": directory + "/lease.json", "MAC_MCP_LEASE": "",
        ]) { _, new in new }
        relay.standardInput = input
        relay.standardOutput = output
        relay.standardError = errors
        relay.terminationHandler = { _ in ended.signal() }
        defer {
            if relay.isRunning { relay.terminate() }
            stop.signal()
            _ = finished.wait(timeout: .now() + 12)
            close(listener)
            try? FileManager.default.removeItem(atPath: directory)
        }
        try relay.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        // Duplicate handles so AgentClient owns only its own descriptors.
        let client = try AgentClient(clientName: "replay-regression", version: "1",
                                     input: dup(output.fileHandleForReading.fileDescriptor),
                                     output: dup(input.fileHandleForWriting.fileDescriptor), timeout: 20)
        #expect(replayed.wait(timeout: .now() + 10) == .success)
        let started = StreamIO.now
        do {
            let result = try client.call("mac_doctor")
            #expect(result.isError)
            #expect(result.text.contains(reply == "silent" ? "complete initialize" : "incompatible protocol"))
        } catch {
            // A failed replay may close before the next request reaches stdin; stderr still reports why.
        }
        #expect(ended.wait(timeout: .now() + 20) == .success)
        #expect(StreamIO.now - started < 19)
        #expect(relay.terminationStatus != 0)
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(diagnostic.contains(reply == "silent" ? "complete initialize" : "incompatible protocol"))
    }
}
}
