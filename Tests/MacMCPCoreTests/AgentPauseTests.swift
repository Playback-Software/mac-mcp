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

@Suite struct AgentPauseTests {
    @Test func pauseHotkeyDefaultAvoidsTheContrastShortcutAndCanBeConfigured() throws {
        let key = try PersonControl.hotkey(arguments: ["--hide-indicator"])
        #expect(try key == KeySpec.parse("ctrl+alt+shift+cmd+period"))
        #expect(try key != KeySpec.parse("ctrl+alt+cmd+period"))
        #expect(try PersonControl.hotkey(arguments: ["--pause-hotkey", "ctrl+alt+f12"]) == KeySpec.parse("ctrl+alt+f12"))
        for args in [["--pause-hotkey"], ["--pause-hotkey", "period"], ["--pause-hotkey", "ctrl+cmd+q"],
                     ["--pause-hotkey", "ctrl+alt+fn+period"]] {
            #expect(throws: ActionError.self) { try PersonControl.hotkey(arguments: args) }
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
        #expect(controls.apply(.status) == AgentPause.refusal)
        #expect(controls.apply(.resume) == "Agents are running (not paused).")
        #expect(try await state.withAction(label: "test") { 9 } == 9)
    }

    @Test func pauseSurvivesRestartAndFailedResumeStaysPaused() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause()
        let controls = PersonControl(state: state, path: path, event: { _, _ in })
        #expect(controls.apply(.pause) == AgentPause.refusal)
        let restarted = AgentPause()
        try PersonControl(state: restarted, path: path, event: { _, _ in }).restore()
        #expect(restarted.status.paused)
        _ = controls.apply(.resume)
        #expect(!state.status.paused)
        let afterResume = AgentPause()
        try PersonControl(state: afterResume, path: path, event: { _, _ in }).restore()
        #expect(afterResume.status.paused)
        state.pause()
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(controls.apply(.resume).hasPrefix(AgentPause.refusal))
        #expect(state.status.paused)
    }

    @Test func newerPauseWinsOverAlreadyReceivedResume() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = AgentPause(paused: true)
        let controls = PersonControl(state: state, path: directory + "/state", event: { _, _ in })
        let revision = state.status.revision
        state.pause()
        #expect(controls.apply(.resume, revision: revision).hasPrefix(AgentPause.refusal))
        #expect(state.status.paused)
    }

    @Test func damagedStateIsNotTreatedAsRunning() throws {
        let directory = NSTemporaryDirectory() + "pause-\(UUID())", path = directory + "/state"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let control = PersonControl(state: AgentPause(), path: path, event: { _, _ in })
        try control.restore()
        try Data("resume please\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: ActionError.self) { try control.restore() }
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
            #expect(error?.description == AgentPause.refusal)
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
        #expect(error?.description == AgentPause.refusal)
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
        #expect(error?.description == AgentPause.refusal)
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
        #expect(error?.description == AgentPause.refusal)
    }
}
