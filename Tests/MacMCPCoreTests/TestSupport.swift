import Foundation
import Testing
@testable import MacMCPCore

/// Waits for `condition` by reading the state it depends on, not by sleeping a guessed time. The limit only ends a hung
/// test; it is far above anything a loaded machine needs.
func waitUntil(_ what: String, limit: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () async -> Bool) async {
    let end = ContinuousClock.now + limit
    while !(await condition()) {
        if ContinuousClock.now >= end { Issue.record("Timed out waiting for \(what).", sourceLocation: sourceLocation); return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// A one-shot signal: one task awaits it, another fires it, in either order.
final class Signal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation

    init() { (stream, sink) = AsyncStream.makeStream(of: Void.self) }

    func fire() { sink.yield(); sink.finish() }
    func wait() async { for await _ in stream { return } }
}

/// Runs `body` on guard pools of its own, sized like the shared ones, wherever it calls `Input.guardWork`. A test that
/// stalls guard workers on purpose uses this so it can't exhaust the shared pools for the tests running beside it.
func withPrivateGuardPools<T>(_ body: () async throws -> T) async rethrows -> T {
    let pools = [
        "focus": Input.GuardPool(name: "focus", count: 4, stuckAfter: 10 * Input.guardTimeout, max: 12),
        "route": Input.GuardPool(name: "route", count: 4, stuckAfter: 10 * Input.routeTimeout, max: 16),
    ]
    return try await Input.$guardPoolOverrides.withValue(pools, operation: body)
}
