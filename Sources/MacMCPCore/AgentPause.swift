import Foundation

/// A person revokes every admitted mutation, including calls waiting for claims or the action lock.
public final class AgentPause: @unchecked Sendable {
    public static let shared = AgentPause()
    public static let refusal = "Refused: Paused by a person. Ask a person to run `mac-mcp resume` in Terminal."
    @TaskLocal public static var permit: Permit?

    public struct Status: Sendable {
        public let paused: Bool
        public let revision: UInt64
        public let active: String?
        public let recent: String?
        public var summary: String { paused ? AgentPause.refusal : "Agents are running (not paused)." }
    }

    public final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        private var cancel: (@Sendable () -> Void)?
        let label: String
        fileprivate init(_ label: String) { self.label = label }
        public var isRevoked: Bool { lock.withLock { revoked } }
        public func check() throws {
            try lock.withLock { if revoked { throw ActionError(AgentPause.refusal) } }
        }
        fileprivate func attach(_ cancel: @escaping @Sendable () -> Void) {
            let stopped = lock.withLock { self.cancel = cancel; return revoked }
            if stopped { cancel() }
        }
        fileprivate func revoke() -> (@Sendable () -> Void)? {
            lock.withLock { revoked = true; return cancel }
        }
        fileprivate func detach() { lock.withLock { cancel = nil } }
    }

    private let lock = NSLock()
    private var paused: Bool
    private var revision: UInt64 = 0
    private var calls: [UUID: Permit] = [:]
    private var recent: (label: String, time: TimeInterval)?

    public init(paused: Bool = false) { self.paused = paused }

    public var status: Status {
        lock.withLock {
            Status(paused: paused, revision: revision, active: calls.values.first?.label,
                   recent: recent.flatMap { StreamIO.now - $0.time < 5 ? $0.label : nil })
        }
    }

    /// Latch first; cancellation and all I/O happen after releasing the state lock. Never toggles.
    public func pause() {
        let calls = lock.withLock {
            paused = true
            revision &+= 1
            return self.calls.values.compactMap { $0.revoke() }
        }
        calls.forEach { $0() }
    }

    /// Only the separate person control service calls this, after persisting the resumed state.
    /// A hotkey arriving during that write wins over resume.
    @discardableResult
    func resumeFromPerson(revision expected: UInt64) -> Bool {
        lock.withLock {
            guard revision == expected else { return false }
            paused = false
            revision &+= 1
            return true
        }
    }

    public func withAction<T: Sendable>(label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let permit = try lock.withLock {
            guard !paused else { throw ActionError(Self.refusal) }
            let permit = Permit(label)
            calls[id] = permit
            return permit
        }
        defer {
            permit.detach()
            lock.withLock {
                calls[id] = nil
                recent = (label, StreamIO.now)
            }
        }
        let task = Task {
            try permit.check()
            try Task.checkCancellation()
            return try await Self.$permit.withValue(permit) { try await body() }
        }
        permit.attach { task.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                try permit.check()
                return value
            } catch {
                try permit.check()
                throw error
            }
        } onCancel: { task.cancel() }
    }
}

public enum AgentSafety {
    public static let refusal = "Refused: that is MacMCP itself. A person controls it with the mac-mcp command."
    public static func refusal(pid: pid_t?) -> String? { pid == getpid() ? refusal : nil }
}
