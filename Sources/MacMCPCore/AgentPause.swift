import Foundation

/// A person revokes every admitted mutation, including calls waiting for claims or the action lock.
public final class AgentPause: @unchecked Sendable {
    public static let shared = AgentPause()
    public static let refusal = "Refused: Paused by a person. Ask a person to run `mac-mcp resume` in Terminal."
    public static let stopped = "Stopped by a person's pause after this call started; it may have partly or fully run. Check with mac_snapshot before retrying."
    @TaskLocal public static var permit: Permit?

    public struct Status: Sendable {
        public let paused: Bool
        public let revision: UInt64
        public let active: String?
        public let recent: String?
        public let reason: String
        public let hotkey: String
        /// Person-facing text for the control socket and CLI.
        public var summary: String { paused ? "\(reason). Run `mac-mcp resume` in Terminal to resume." : "Agents are running (not paused)." }
        public var refusal: String { "Refused: \(reason). Ask a person to run `mac-mcp resume` in Terminal." }
        public var controlSummary: String { summary + " Hotkey: " + hotkey }
    }

    public final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        private var started = false
        private var completed = false
        private var refusal = AgentPause.refusal
        private var cancel: (@Sendable () -> Void)?
        let label: String
        init(_ label: String) { self.label = label }
        public var isRevoked: Bool { lock.withLock { revoked } }
        public func check() throws {
            try lock.withLock { if revoked { throw ActionError(started ? AgentPause.stopped : refusal) } }
        }
        func begin() throws {
            try lock.withLock {
                if revoked { throw ActionError(refusal) }
                started = true
            }
        }
        /// Linearize completion against revocation here, in the body task, rather than when its caller wakes up.
        func complete() throws {
            try lock.withLock {
                if revoked { throw ActionError(AgentPause.stopped) }
                completed = true
                cancel = nil
            }
        }
        fileprivate func attach(_ cancel: @escaping @Sendable () -> Void) {
            let stopped = lock.withLock { self.cancel = cancel; return revoked }
            if stopped { cancel() }
        }
        func revoke(refusal: String) -> (@Sendable () -> Void)? {
            lock.withLock {
                guard !completed else { return nil }
                self.refusal = refusal
                revoked = true
                return cancel
            }
        }
        fileprivate func detach() { lock.withLock { cancel = nil } }
    }

    private let lock = NSLock()
    private var paused: Bool
    private var reason = "Paused by a person"
    private var hotkey = "not registered"
    private var revision: UInt64 = 0
    private var calls: [UUID: Permit] = [:]
    private var recent: (label: String, time: TimeInterval)?

    public init(paused: Bool = false) { self.paused = paused }

    public var status: Status {
        lock.withLock {
            Status(paused: paused, revision: revision, active: calls.values.first?.label,
                   recent: recent.flatMap { StreamIO.now - $0.time < 5 ? $0.label : nil }, reason: reason, hotkey: hotkey)
        }
    }

    /// Latch first; cancellation and all I/O happen after releasing the state lock. Never toggles.
    public func pause(reason: String = "Paused by a person") {
        let calls = lock.withLock {
            paused = true
            self.reason = reason
            revision &+= 1
            let refusal = "Refused: \(reason). Ask a person to run `mac-mcp resume` in Terminal."
            return self.calls.values.compactMap { $0.revoke(refusal: refusal) }
        }
        calls.forEach { $0() }
    }

    public func setHotkeyStatus(_ message: String) { lock.withLock { hotkey = message } }

    /// Startup restoration must not erase a pause raised meanwhile (for example, a failed hotkey registration).
    func restore(paused: Bool, revision saved: UInt64, reason: String) {
        lock.withLock {
            if revision == 0 { self.paused = paused; self.reason = reason; revision = saved }
            else { revision = max(revision, saved &+ 1) }
        }
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
            guard !paused else { throw ActionError("Refused: \(reason). Ask a person to run `mac-mcp resume` in Terminal.") }
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
            do {
                try permit.check()
                try Task.checkCancellation()
                try permit.begin()
                let value = try await Self.$permit.withValue(permit) { try await body() }
                try permit.complete()
                return value
            } catch {
                try permit.check()
                throw error
            }
        }
        permit.attach { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}

public enum AgentSafety {
    public static let refusal = "Refused: that is MacMCP itself. A person controls it with the mac-mcp command."
    public static func refusal(pid: pid_t?) -> String? { pid == getpid() ? refusal : nil }
}
