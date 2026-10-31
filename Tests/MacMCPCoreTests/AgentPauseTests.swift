import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

private final class PauseEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CGEventType] = []
    var all: [CGEventType] { lock.withLock { values } }
    func append(_ event: CGEvent) { lock.withLock { values.append(event.type) } }
}

private final class LeaseReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func read(_ path: String) -> Lease? {
        lock.withLock { reads += 1 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Lease.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

@Suite struct AgentPauseTests {
    @Test func pauseHotkeyDefaultAvoidsSystemShortcutsAndCanBeConfigured() throws {
        let key = try PersonControl.hotkey(arguments: ["--hide-indicator"])
        #expect(try key == KeySpec.parse("ctrl+shift+cmd+backslash"))
        #expect(PersonControl.hotkeyLabel(key) == "ctrl+shift+cmd+backslash")
        #expect(try key != KeySpec.parse("ctrl+alt+cmd+period"))
        #expect(try PersonControl.hotkey(arguments: ["--pause-hotkey", "ctrl+alt+f12"]) == KeySpec.parse("ctrl+alt+f12"))
        for args in [["--pause-hotkey"], ["--pause-hotkey", "period"], ["--pause-hotkey", "ctrl+cmd+q"],
                     ["--pause-hotkey", "ctrl+alt+fn+period"]] {
            #expect(throws: ActionError.self) { try PersonControl.hotkey(arguments: args) }
        }
        for chord in ["ctrl+alt+shift+cmd+period", "cmd+shift+opt+control+.", "ctrl+alt+shift+cmd+k",
                      "ctrl+alt+cmd+period", "ctrl+alt+cmd+comma", "ctrl+alt+shift+cmd+comma",
                      "ctrl+alt+cmd+8", "alt+cmd+esc", "alt+cmd+f5", "ctrl+cmd+space",
                      "alt+cmd+d", "ctrl+cmd+f", "alt+cmd+8", "alt+cmd+equal", "cmd+shift+4"] {
            #expect(throws: ActionError.self) { try PersonControl.hotkey(arguments: ["--pause-hotkey", chord]) }
        }
    }

    @Test func pauseLatchesAndOnlyPersonControlResumes() async throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause()
        let controls = PersonControl(state: state, path: directory + "/state", event: { _, _ in })
        #expect(try await state.withAction(label: "test") { 7 } == 7)
        state.pause()
        let revision = state.status.revision
        state.pause()
        #expect(state.status.paused)
        #expect(!state.resumeFromPerson(revision: revision))
        let error = await #expect(throws: ActionError.self) { try await state.withAction(label: "test") { 8 } }
        #expect(error?.description == AgentPause.refusal)
        #expect(controls.apply(.status) == state.status.controlSummary)
        #expect(!controls.apply(.status).contains("Ask a person"))
        #expect(controls.apply(.resume).hasPrefix("Agents are running (not paused)."))
        #expect(try await state.withAction(label: "test") { 9 } == 9)
    }

    @Test func pauseSurvivesRestartAndFailedResumeStaysPaused() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause()
        let controls = PersonControl(state: state, path: path, event: { _, _ in })
        #expect(controls.apply(.pause).hasPrefix("Paused by a person."))
        let revision = state.status.revision
        let restarted = AgentPause()
        try PersonControl(state: restarted, path: path, event: { _, _ in }).restore()
        #expect(restarted.status.paused)
        #expect(restarted.status.revision == revision)
        _ = controls.apply(.resume)
        #expect(!state.status.paused)
        let afterResume = AgentPause()
        try PersonControl(state: afterResume, path: path, event: { _, _ in }).restore()
        #expect(!afterResume.status.paused)
        #expect(afterResume.status.revision == state.status.revision)
        state.pause()
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(controls.apply(.resume).hasPrefix("Paused because the resumed state could not be saved"))
        #expect(state.status.paused)
    }

    @Test func newerPauseWinsOverAlreadyReceivedResume() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause(paused: true)
        let controls = PersonControl(state: state, path: directory + "/state", event: { _, _ in })
        let revision = state.status.revision
        state.pause()
        #expect(controls.apply(.resume, revision: revision).hasPrefix("Paused by a person."))
        #expect(state.status.paused)
    }

    @Test func damagedStateIsNotTreatedAsRunning() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let control = PersonControl(state: AgentPause(), path: path, event: { _, _ in })
        try control.restore()
        try Data("resume please\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: ActionError.self) { try control.restore() }
        #expect(control.apply(.status).contains("corrupt"))
        #expect(!control.apply(.status).contains("by a person"))
    }

    @Test func firstStartAndRunningStateSurviveRestartWithPrivatePermissions() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause()
        try PersonControl(state: state, path: path, event: { _, _ in }).restore()
        let restarted = AgentPause()
        try PersonControl(state: restarted, path: path, event: { _, _ in }).restore()
        #expect(!restarted.status.paused)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        #expect(saved["state"] as? String == "running")
        #expect(saved["revision"] as? UInt64 == state.status.revision)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unsafeOrUnreadableStateFailsClosedWithTheActualReason() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause()
        let controls = PersonControl(state: state, path: path, event: { _, _ in })
        try controls.restore()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(throws: ActionError.self) { try controls.restore() }
        #expect(state.status.paused)
        #expect(state.status.summary.contains("private, owner-owned regular file"))
        #expect(!state.status.summary.contains("by a person"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        #expect(throws: (any Error).self) { try controls.restore() }
        #expect(state.status.paused)
        #expect(state.status.refusal.contains("could not be restored"))
        #expect(!state.status.refusal.contains("by a person"))
    }

    @Test func legacyPausedStateMigratesAndRestoreCannotEraseAStartupFailure() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("paused\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let state = AgentPause()
        let controls = PersonControl(state: state, path: path, event: { _, _ in })
        try controls.restore()
        #expect(state.status.paused)
        #expect(state.status.revision == 1)
        #expect(controls.apply(.resume).hasPrefix("Agents are running"))
        let failed = AgentPause()
        failed.pause(reason: "Paused because the stop hotkey could not be registered")
        try PersonControl(state: failed, path: path, event: { _, _ in }).restore()
        #expect(failed.status.paused)
        #expect(failed.status.summary.contains("hotkey could not be registered"))
        #expect(!failed.status.summary.contains("by a person"))
        #expect(failed.status.revision == state.status.revision + 1)
    }

    @Test func registrationFailureStaysVisibleAfterResume() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause()
        state.setHotkeyStatus("UNAVAILABLE (already registered); restart to retry")
        state.pause(reason: "Paused because the stop hotkey could not be registered")
        let controls = PersonControl(state: state, path: directory + "/state", event: { _, _ in })
        #expect(controls.apply(.status).contains("Hotkey: UNAVAILABLE"))
        #expect(controls.apply(.resume).contains("Hotkey: UNAVAILABLE"))
        #expect(!state.status.paused)
        #expect(controls.apply(.status).contains("Hotkey: UNAVAILABLE"))
    }

    @Test func permitCompletionAndRevocationHaveDistinctOutcomes() throws {
        let before = AgentPause.Permit("before")
        _ = before.revoke(refusal: AgentPause.refusal)
        let refused = #expect(throws: ActionError.self) { try before.begin() }
        #expect(refused?.description == AgentPause.refusal)
        let during = AgentPause.Permit("during")
        try during.begin()
        _ = during.revoke(refusal: AgentPause.refusal)
        let stopped = #expect(throws: ActionError.self) { try during.complete() }
        #expect(stopped?.description == AgentPause.stopped)
        let finished = AgentPause.Permit("finished")
        try finished.begin()
        try finished.complete()
        _ = finished.revoke(refusal: AgentPause.refusal)
        try finished.check() // the caller can collect success even if it wakes after the pause
        #expect(!finished.isRevoked)
    }

    @Test func controlSocketLimitIncludesSuffixNULAndUTF8Bytes() throws {
        try PersonControl.validateSocketPaths(mcpSocket: "/" + String(repeating: "s", count: 94))
        #expect(throws: ActionError.self) {
            try PersonControl.validateSocketPaths(mcpSocket: "/" + String(repeating: "s", count: 95))
        }
        try PersonControl.validateSocketPaths(mcpSocket: "/" + String(repeating: "é", count: 47))
        #expect(throws: ActionError.self) {
            try PersonControl.validateSocketPaths(mcpSocket: "/" + String(repeating: "é", count: 48))
        }
        try UnixSocket.validatePath("/" + String(repeating: "s", count: 102))
        #expect(throws: SocketError.self) { try UnixSocket.validatePath("/" + String(repeating: "s", count: 103)) }
    }

    @Test func activityLabelsKeepAUsefulSessionIdentifier() {
        #expect(PersonControl.activityLabel("client-name (session 12345678-1234-5678-1234-567812345678)") == "client-name · 12345678")
        let long = PersonControl.activityLabel(String(repeating: "x", count: 60) + " unique-tail")
        #expect(long.count == 48)
        #expect(long.hasSuffix("unique-tail"))
        #expect(PersonControl.activityLabel("client\n\tname") == "clientname")
    }

    @Test func activityLeaseReaderOnlyDecodesChangedFilesAndChecksExpiry() async throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/lease"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let reads = LeaseReads(), reader = LeaseStore.InputCheck(token: nil, path: path, read: reads.read)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func publish(_ holder: String, expires: Date) throws {
            let lease = Lease(token: "token", holder: holder, reason: "test", pid: 0, acquired: .now, expires: expires)
            try LeaseStore.writePrivately(encoder.encode(lease), to: path)
        }
        try publish("first", expires: .now.addingTimeInterval(3600))
        #expect(await reader.currentAsync()?.holder == "first")
        #expect(await reader.currentAsync()?.holder == "first")
        #expect(reads.count == 1)
        try publish("second", expires: .now.addingTimeInterval(3600))
        #expect(await reader.currentAsync()?.holder == "second")
        #expect(reads.count == 2)
        try publish("expired", expires: .distantPast)
        #expect(await reader.currentAsync() == nil)
        #expect(await reader.currentAsync() == nil)
        #expect(reads.count == 3)
        try FileManager.default.removeItem(atPath: path)
        #expect(await reader.currentAsync() == nil)
    }

    @Test func pauseCancelsRunningAndQueuedActionsEvenAfterResume() async throws {
        let state = AgentPause(), actionLock = ActionLock(), entered = Signal()
        let first = Task {
            try await state.withAction(label: "first") {
                try await actionLock.run {
                    entered.fire()
                    try await Task.sleep(for: .seconds(120))
                    return 1
                }
            }
        }
        await entered.wait()
        let second = Task {
            try await state.withAction(label: "second") {
                try await actionLock.run { Issue.record("Queued action ran after pause"); return 2 }
            }
        }
        await waitUntil("queued action") { await actionLock.status.waiting == 1 }
        state.pause()
        #expect(state.resumeFromPerson(revision: state.status.revision))
        for task in [first, second] {
            let error = await #expect(throws: ActionError.self) { try await task.value }
            #expect(error?.description == AgentPause.stopped)
        }
        #expect(await actionLock.status.waiting == 0)
        #expect(await actionLock.status.holder == nil)
    }

    @Test func pauseReleasesHeldKeyAndModifiers() async throws {
        let state = AgentPause(), events = PauseEvents(), actionLock = ActionLock()
        let error = await #expect(throws: ActionError.self) {
            try await state.withAction(label: "keys") {
                try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: {
                    events.append($0)
                    if $0.type == .keyDown { state.pause() }
                })) {
                    try await actionLock.run { try await Input.press(KeySpec.parse("cmd+s"), repeat: 100, pid: 42) }
                }
            }
        }
        #expect(error?.description == AgentPause.stopped)
        #expect(events.all == [.keyDown, .keyUp, .flagsChanged])
        #expect(await actionLock.status.holder == nil)
    }

    @Test func pauseCleansUpHeldDrag() async throws {
        let state = AgentPause(), events = PauseEvents(), actionLock = ActionLock()
        let error = await #expect(throws: ActionError.self) {
            try await state.withAction(label: "drag") {
                try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: {
                    events.append($0)
                    if $0.type == .leftMouseDown { state.pause() }
                })) {
                    try await actionLock.run {
                        try await Input.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), pid: 42)
                    }
                }
            }
        }
        #expect(error?.description == AgentPause.stopped)
        #expect(events.all.filter { $0 == .leftMouseDown }.count == 1)
        #expect(events.all.filter { $0 == .leftMouseUp }.count == 1)
        #expect(events.all.contains(.keyUp))
        #expect(await actionLock.status.holder == nil)
    }

    @Test func ownPIDIsRefusedBeforeAnyInputOrAXWrite() async throws {
        let events = PauseEvents()
        let error = await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in Issue.record("Guard reached") },
                                                                     post: { events.append($0) })) {
                try await Input.press(KeySpec.parse("return"), pid: getpid())
            }
        }
        #expect(error?.description == AgentSafety.refusal)
        #expect(events.all.isEmpty)
        let own = AXElement.application(pid: getpid())
        #expect(own.perform("AXPress") == .cannotComplete)
        #expect(own.set("AXValue", "test") == .cannotComplete)
        #expect(Policy(denyApps: [], allowApps: [Paths.bundleID]).refusal(bundleID: Paths.bundleID, name: "MacMCP") != nil)
    }

    @Test func aCoordinateOnTheAgentsStatusItemIsRefusedWithAnotherAppAsTarget() async {
        let events = PauseEvents()
        let window = WindowInfo(id: 1, pid: getpid(), owner: "MacMCP", title: "Status item", layer: 25,
                                bounds: CGRect(x: 10, y: 10, width: 30, height: 22), alpha: 1)
        let error = await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { events.append($0) },
                                                                     windows: { [window] })) {
                try await Input.click(at: CGPoint(x: 20, y: 20), pid: 42)
            }
        }
        #expect(error?.description == AgentSafety.refusal)
        #expect(events.all.isEmpty)
    }

    @Test func revocationBlocksAXWritesFromAnUncancelledChildTask() async {
        let state = AgentPause(), entered = Signal()
        let action = Task {
            try await state.withAction(label: "AX") {
                entered.fire()
                try? await Task.sleep(for: .seconds(120))
                // An unstructured child inherits the revoked permit, but not its parent's cancellation.
                await Task {
                    #expect(!Task.isCancelled)
                    #expect(AXElement.mutate { Issue.record("AX write ran after pause"); return .success } == .cannotComplete)
                }.value
            }
        }
        await entered.wait()
        state.pause()
        let error = await #expect(throws: ActionError.self) { try await action.value }
        #expect(error?.description == AgentPause.stopped)
    }
}
