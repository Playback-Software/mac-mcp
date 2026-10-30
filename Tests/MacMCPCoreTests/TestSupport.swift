import Foundation
import Testing

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
