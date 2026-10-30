import Foundation

/// Notices when the agent stops making progress, and ends it so launchd's KeepAlive starts a fresh one (relays
/// reconnect and replay the session, so clients see one failed call instead of a frozen agent).
///
/// Deadlines bound each call, but they can't free a thread stuck in a synchronous call. Enough abandoned work and the
/// cooperative pool runs dry; a stuck main thread stops NSWorkspace's app list from updating. The watchdog runs on
/// its own thread and probes the main queue, the cooperative pool and the action lock every few seconds.
public final class Watchdog: @unchecked Sendable {
    public struct Limits: Sendable {
        public var interval: TimeInterval = 5
        /// No progress on the main queue or the cooperative pool for this long counts as a stall.
        public var stall: TimeInterval = 60
        /// Fallback for a holder whose deadline has not yet been published.
        public var lockHeld: TimeInterval = 180
        /// Grace after the holder's actual deadline for cancellation and lock handoff.
        public var deadlineMargin: TimeInterval = 15
        public init() {}
    }

    /// Why the agent is stalled at `now`, or nil if it's healthy. Times are monotonic (system uptime, which stops
    /// while the Mac sleeps, so waking up doesn't look like a stall).
    public static func stall(now: TimeInterval, lastMain: TimeInterval, lastPool: TimeInterval,
                             lockHeldFor: TimeInterval?, lockHolder: String?, limits: Limits, lockDeadline: TimeInterval? = nil) -> String? {
        if now - lastMain > limits.stall { return "main thread unresponsive for \(Int(now - lastMain)) s" }
        if now - lastPool > limits.stall { return "task pool starved for \(Int(now - lastPool)) s" }
        if let held = lockHeldFor, lockDeadline.map({ now > $0 + limits.deadlineMargin }) ?? (held > limits.lockHeld) {
            return "action lock held by \(lockHolder ?? "?") for \(Int(held)) s"
        }
        return nil
    }

    private let limits: Limits
    private let lock = NSLock()
    private var lastMain: TimeInterval
    private var lastPool: TimeInterval
    private var lockHeldFor: TimeInterval?
    private var lockHolder: String?
    private var lockDeadline: TimeInterval?

    public init(limits: Limits = Limits()) {
        self.limits = limits
        let now = Watchdog.now
        lastMain = now
        lastPool = now
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Starts the watchdog thread. `onStall` runs on that thread (it typically logs, samples and exits).
    public func start(onStall: @escaping @Sendable (String) -> Void) {
        let thread = Thread { [self] in
            var lastTick = Watchdog.now
            while true {
                Thread.sleep(forTimeInterval: limits.interval)   // lint:allow-blocking the watchdog's own thread
                let now = Watchdog.now
                // If this thread itself was held up (heavy load), the probes had no chance either: skip a round.
                let late = now - lastTick > limits.interval * 3
                lastTick = now
                DispatchQueue.main.async { self.lock.withLock { self.lastMain = Watchdog.now } }
                Task.detached {
                    let status = await ActionLock.shared.status
                    self.lock.withLock {
                        self.lastPool = Watchdog.now
                        self.lockHeldFor = status.heldFor
                        self.lockHolder = status.holder
                        self.lockDeadline = status.deadline
                    }
                }
                guard !late else { continue }
                let reason = lock.withLock {
                    Watchdog.stall(now: now, lastMain: lastMain, lastPool: lastPool, lockHeldFor: lockHeldFor,
                                   lockHolder: lockHolder, limits: limits, lockDeadline: lockDeadline)
                }
                if let reason { onStall(reason) }
            }
        }
        thread.name = "mac-mcp.watchdog"
        thread.start()
    }
}
