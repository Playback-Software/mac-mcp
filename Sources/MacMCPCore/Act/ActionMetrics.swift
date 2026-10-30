import Foundation
import Synchronization

/// Opt-in diagnostics. No arguments, labels, values or other screen text are recorded.
public enum ActionMetrics {
    public static let enabled = ProcessInfo.processInfo.environment["MAC_MCP_DEBUG_ACTIONS"] == "1"
    @TaskLocal public static var current: Recorder?
    @TaskLocal public static var phase: Phase = .guards

    public enum Phase: String, Sendable, CaseIterable {
        case guards, lockWait = "lock_wait", before, resolve, act, settle, after, report
    }

    public struct Totals: Sendable, Codable {
        public var milliseconds: Double = 0
        public var walks = 0
        public var reusedWalks = 0
        public var walkMilliseconds: Double = 0
        public var nodes = 0
    }

    public struct Report: Sendable, Codable {
        public let tool: String
        public let session: String
        public let milliseconds: Double
        public let walks: Int
        public let reusedWalks: Int
        public let walkMilliseconds: Double
        public let nodes: Int
        public let inFlightWalks: Int
        public let isError: Bool
        public let phases: [String: Totals]
    }

    public final class Recorder: Sendable {
        private struct State {
            var phases: [Phase: Totals] = [:]
            var inFlightWalks = 0
            var finished = false
        }
        private let state = Mutex(State())
        private let started = ContinuousClock.now
        public init() {}

        public func addTime(_ phase: Phase, since start: ContinuousClock.Instant) {
            state.withLock {
                guard !$0.finished else { return }
                $0.phases[phase, default: Totals()].milliseconds += Self.milliseconds(since: start)
            }
        }

        func startWalk(_ phase: Phase) {
            state.withLock {
                guard !$0.finished else { return }
                $0.phases[phase, default: Totals()].walks += 1
                $0.inFlightWalks += 1
            }
        }

        func endWalk(_ phase: Phase, since start: ContinuousClock.Instant, nodes: Int) {
            state.withLock {
                guard !$0.finished else { return }
                $0.phases[phase, default: Totals()].walkMilliseconds += Self.milliseconds(since: start)
                $0.phases[phase, default: Totals()].nodes += nodes
                $0.inFlightWalks -= 1
            }
        }

        func reuseWalk(_ phase: Phase) {
            state.withLock {
                guard !$0.finished else { return }
                $0.phases[phase, default: Totals()].reusedWalks += 1
            }
        }

        /// Freeze before logging: an abandoned guard may still be finishing on its own thread.
        public func finish(tool: String, session: String, isError: Bool) -> Report {
            state.withLock { state in
                state.finished = true
                let elapsed = Self.milliseconds(since: started)
                let measured = state.phases.values.reduce(0) { $0 + $1.milliseconds }
                state.phases[.guards, default: Totals()].milliseconds += max(0, elapsed - measured)
                let totals = state.phases.values
                return Report(tool: tool, session: session, milliseconds: elapsed,
                              walks: totals.reduce(0) { $0 + $1.walks },
                              reusedWalks: totals.reduce(0) { $0 + $1.reusedWalks },
                              walkMilliseconds: totals.reduce(0) { $0 + $1.walkMilliseconds },
                              nodes: totals.reduce(0) { $0 + $1.nodes }, inFlightWalks: state.inFlightWalks,
                              isError: isError,
                              phases: Dictionary(uniqueKeysWithValues: Phase.allCases.map { ($0.rawValue, state.phases[$0] ?? Totals()) }))
            }
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            Double(start.duration(to: .now) / .microseconds(1)) / 1000
        }
    }

    public static func during<T>(_ phase: Phase, _ body: () async throws -> T) async rethrows -> T {
        guard let recorder = current else { return try await body() }
        let started = ContinuousClock.now
        defer { recorder.addTime(phase, since: started) }
        return try await $phase.withValue(phase) { try await body() }
    }
}
