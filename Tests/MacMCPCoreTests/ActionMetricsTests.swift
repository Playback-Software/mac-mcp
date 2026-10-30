import Foundation
import Testing
@testable import MacMCPCore

@Suite struct ActionMetricsTests {
    private func walk() {
        Self.walkFixture()
    }

    private static func walkFixture() {
        var options = Walker.Options()
        options.source = Walker.Source(read: { _, _ in ["AXRole": "AXWindow"] },
                                       attribute: { _, _ in nil }, elements: { _, _ in [] })
        _ = Walker.walk(AXElement.application(pid: 470_001), options: options)
    }

    @Test func countsWalksByPhaseAndIncludesChildTasks() async throws {
        let recorder = ActionMetrics.Recorder()
        try await ActionMetrics.$current.withValue(recorder) {
            await ActionMetrics.during(.before) { walk() }
            _ = try await Deadline.run(60) {
                await ActionMetrics.during(.settle) { Self.walkFixture(); Self.walkFixture() }
            }
            await ActionMetrics.during(.after) { walk() }
        }
        let report = recorder.finish(tool: "mac_click", session: "fixture", isError: false)
        #expect(report.walks == 4 && report.nodes == 4 && report.inFlightWalks == 0)
        #expect(report.phases["before"]?.walks == 1)
        #expect(report.phases["settle"]?.walks == 2)
        #expect(report.phases["after"]?.walks == 1)
        #expect(report.phases.values.reduce(0) { $0 + $1.milliseconds } <= report.milliseconds + 1)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ActionMetrics.Report.self, from: data)
        #expect(decoded.walks == 4 && decoded.phases["settle"] != nil)
    }

    @Test func dedicatedGuardsKeepTheRecorderAndPhase() async throws {
        let recorder = ActionMetrics.Recorder()
        try await ActionMetrics.$current.withValue(recorder) {
            try await ActionMetrics.during(.act) {
                try await Input.guardWork(timeout: 60) { Self.walkFixture() }
            }
        }
        let report = recorder.finish(tool: "mac_type", session: "fixture", isError: false)
        #expect(report.walks == 1 && report.phases["act"]?.walks == 1)
        #expect(report.phases["guards"]?.walks == 0)
    }

    @Test func thrownPhasesAreStillMeasured() async {
        struct Refused: Error {}
        let recorder = ActionMetrics.Recorder()
        await ActionMetrics.$current.withValue(recorder) {
            do {
                try await ActionMetrics.during(.resolve) { walk(); throw Refused() }
            } catch {}
        }
        let report = recorder.finish(tool: "mac_click", session: "fixture", isError: true)
        #expect(report.isError && report.phases["resolve"]?.walks == 1)
        #expect(report.phases["resolve"]!.milliseconds >= report.phases["resolve"]!.walkMilliseconds)
    }

    @Test func lateWalksCannotChangeAFinishedReport() {
        let recorder = ActionMetrics.Recorder()
        recorder.startWalk(.act)
        let report = recorder.finish(tool: "mac_key", session: "fixture", isError: true)
        recorder.endWalk(.act, since: .now, nodes: 50)
        recorder.startWalk(.after)
        let later = recorder.finish(tool: "mac_key", session: "fixture", isError: true)
        #expect(report.walks == 1 && report.inFlightWalks == 1 && report.nodes == 0)
        #expect(later.walks == report.walks && later.nodes == report.nodes && later.inFlightWalks == report.inFlightWalks)
    }

    @Test func recordingIsScopedToOneCall() {
        let recorder = ActionMetrics.Recorder()
        ActionMetrics.$current.withValue(recorder) { walk() }
        walk()
        #expect(ActionMetrics.current == nil)
        #expect(recorder.finish(tool: "mac_key", session: "fixture", isError: false).walks == 1)
    }
}
