import Foundation
import Testing
@testable import MacMCPCore

@Suite struct SessionStateTests {
    func state(_ info: [String: Any]?, asleep: Bool = false, ax: Bool = true, sr: Bool = true) -> SessionState {
        SessionState(sessionInfo: info, displayAsleep: asleep, accessibility: ax, screenRecording: sr)
    }

    @Test func unlockedConsoleSessionCanAct() {
        let s = state(["kCGSSessionOnConsoleKey": true])
        #expect(s.actionBlocker == nil)
        #expect(s.summary == "ready")
    }

    @Test func lockKeyIsOnlyPresentWhileLocked() {
        let s = state(["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true])
        #expect(s.screenLocked)
        #expect(s.actionBlocker?.hasPrefix("SCREEN LOCKED") == true)
        #expect(s.summary == "SCREEN LOCKED")
    }

    @Test func noSessionDictionaryMeansNoGUISession() {
        #expect(state(nil).actionBlocker?.hasPrefix("NO GUI SESSION") == true)
    }

    @Test func blockersAreReportedInPriorityOrder() {
        // Not on console outranks a lock; a lock outranks a sleeping display; all outrank permissions.
        #expect(state(["CGSSessionScreenIsLocked": true]).actionBlocker?.hasPrefix("NO GUI SESSION") == true)
        #expect(state(["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true], asleep: true)
            .actionBlocker?.hasPrefix("SCREEN LOCKED") == true)
        #expect(state(["kCGSSessionOnConsoleKey": true], asleep: true, ax: false)
            .actionBlocker?.hasPrefix("DISPLAY ASLEEP") == true)
        #expect(state(["kCGSSessionOnConsoleKey": true], ax: false).actionBlocker?.hasPrefix("ACCESSIBILITY") == true)
    }

    @Test func missingScreenRecordingDoesNotBlockActions() {
        let s = state(["kCGSSessionOnConsoleKey": true], sr: false)
        #expect(s.actionBlocker == nil)
        #expect(s.summary == "ready (no screen recording)")
    }
}

@Suite struct AuditLogTests {
    @Test func redactsSecretKeysAndCallSpecificSecrets() {
        let out = AuditLog.redact(["password": "hunter2", "text": "typed secret", "app": "Safari"],
                                  secretValueKeys: ["text"])
        #expect(out["password"] == "[REDACTED 7 chars]")
        #expect(out["text"] == "[REDACTED 12 chars]")
        #expect(out["app"] == "Safari")
    }

    @Test func truncatesLongValues() {
        let out = AuditLog.redact(["source": String(repeating: "x", count: 500)], maxLength: 10)
        #expect(out["source"] == "xxxxxxxxxx… [500 chars]")
    }

    @Test func appendsOneJSONLinePerEntry() async throws {
        let path = NSTemporaryDirectory() + "audit-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = AuditLog(path: path)
        await log.record(AuditEntry(client: "test 1.0", tool: "mac_doctor", arguments: [:], outcome: "ok", durationMs: 3))
        await log.record(AuditEntry(client: "test 1.0", tool: "mac_click", arguments: ["ref": "e4"], outcome: "error",
                                    detail: "stale ref", durationMs: 9))
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let second = try decoder.decode(AuditEntry.self, from: Data(lines[1].utf8))
        #expect(second.tool == "mac_click" && second.arguments["ref"] == "e4" && second.detail == "stale ref")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite struct LaunchAgentTests {
    @Test func plistRestrictsToGUISessionAndKeepsAlive() {
        let p = LaunchAgent.plist(executable: "/x/MacMCPAgent")
        #expect(p["Label"] as? String == "com.playbacksoftware.macmcp")
        #expect(p["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(p["KeepAlive"] as? Bool == true)
        #expect(p["ProgramArguments"] as? [String] == ["/x/MacMCPAgent"])
    }
}

@Suite struct UnixSocketTests {
    @Test func roundTripsBytesWithOwnerOnlyPermissions() throws {
        let path = "/tmp/mm-\(getpid())-\(Int.random(in: 0..<100_000)).sock"
        defer { unlink(path) }
        let server = try UnixSocket.listen(path: path)
        defer { close(server) }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        let accepted = accept(server, nil, nil)
        defer { close(accepted) }
        let message = Array("ping\n".utf8)
        #expect(write(client, message, message.count) == message.count)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = read(accepted, &buffer, buffer.count)
        #expect(Array(buffer[0..<n]) == message)
    }

    @Test func connectFailsClearlyWhenNobodyListens() {
        #expect(throws: SocketError.self) { try UnixSocket.connect(path: "/tmp/mm-nobody-\(UUID().uuidString.prefix(8)).sock") }
    }
}
