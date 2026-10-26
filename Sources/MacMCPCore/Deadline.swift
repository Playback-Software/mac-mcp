import Foundation

/// Bounded waiting that actually returns on time.
///
/// A task group (the obvious way to race work against a timer) waits for every child before it returns. A child stuck
/// in a call that ignores cancellation (a synchronous AX request to a hung app, an NSWorkspace completion that never
/// fires) therefore holds the caller hostage, timer or not. `Deadline.run` instead runs the work as its own task and
/// returns when the timer fires, cancelling and *abandoning* the work. Abandoned work finishes (or stays stuck) in
/// the background; because it's cancelled, `Input` refuses to post its events and `Task.sleep` ends it at its next
/// suspension point.
public enum Deadline {
    /// The work's result, or nil when the deadline passed first.
    public static func run<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
                race.start(continuation)
                race.setWork(Task {
                    do { race.finish(.success(try await operation()), byWork: true) }
                    catch { race.finish(.failure(error), byWork: true) }
                })
                Task {
                    try? await Task.sleep(for: .milliseconds(Int(max(seconds, 0) * 1000)))
                    race.finish(.success(nil), byWork: false)
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()), byWork: false)
        }
    }

    /// The first finisher wins and resumes the caller. If the work didn't win, it is cancelled.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Error>?
        private var result: Result<T?, Error>?
        private var workWon = false
        private var work: Task<Void, Never>?

        func start(_ c: CheckedContinuation<T?, Error>) {
            let early: Result<T?, Error>? = lock.withLock {
                if result == nil { continuation = c }
                return result
            }
            if let early { c.resume(with: early) }
        }

        func setWork(_ task: Task<Void, Never>) {
            let lost: Bool = lock.withLock {
                if result != nil, !workWon { return true }
                work = task
                return false
            }
            if lost { task.cancel() }
        }

        func finish(_ r: Result<T?, Error>, byWork: Bool) {
            let (c, loser): (CheckedContinuation<T?, Error>?, Task<Void, Never>?) = lock.withLock {
                guard result == nil else { return (nil, nil) }
                result = r
                workWon = byWork
                defer { continuation = nil }
                return (continuation, byWork ? nil : work)
            }
            loser?.cancel()
            c?.resume(with: r)
        }
    }
}

/// Thrown when an operation outlived its deadline and was abandoned.
public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let what: String
    public let seconds: TimeInterval
    public init(_ what: String, seconds: TimeInterval) {
        self.what = what
        self.seconds = seconds
    }
    public var description: String { "\(what) did not finish within \(Int(seconds.rounded())) s and was abandoned" }
}
