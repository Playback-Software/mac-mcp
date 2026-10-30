import Foundation
import Testing
@testable import MacMCPCore

@Suite struct GuardPoolTests {
    /// Route checks resolve paths and can hang in the kernel on a dead network mount.
    @Test(.timeLimit(.minutes(1))) func blockedRouteChecksDoNotStarveFocusGuards() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<8 { gate.signal() } }
        async let blocked: Void = withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try? await Input.guardWork(pool: .route, timeout: 0.05) { gate.wait(); return 0 } }
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        // A focus guard times out 0.25 s after it's queued, so it returns only if a worker took it at once.
        let value = try await Input.guardWork { 42 }
        #expect(value == 42)
        _ = await blocked
    }

    @Test(.timeLimit(.minutes(1))) func aPoolWithEveryWorkerStuckAddsAReplacement() async throws {
        let pool = Input.GuardPool(name: "test", count: 2, stuckAfter: 0.1, max: 4)
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<8 { gate.signal() } }
        async let first: Void = { _ = try? await Input.guardWork(pool: pool, timeout: 0.05) { gate.wait(); return 0 } }()
        async let second: Void = { _ = try? await Input.guardWork(pool: pool, timeout: 0.05) { gate.wait(); return 0 } }()
        _ = await (first, second)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pool.threads.status.stuck == 2)
        let value = try await Input.guardWork(pool: pool, timeout: 2) { 7 }
        #expect(value == 7)
    }

    @Test func stuckWorkersAreReportedToHealth() async {
        var observation = HealthMonitor.Observation()
        observation.stuckGuards = [(pool: "route", count: 2, oldest: 45.4)]
        let problems = HealthMonitor.problems(observation, secureFor: 0)
        #expect(problems.count == 1)
        #expect(problems[0].summary.contains("2 route check workers are stuck, the oldest for 45 s"))
        // Needs no GUI session, so a locked screen doesn't hide it.
        observation.skipped = "the screen is locked"
        let locked = observation
        let monitor = HealthMonitor(observe: { locked })
        let report = await monitor.check(alert: false)
        #expect(report.skipped != nil && report.problems.count == 1)
    }
}
