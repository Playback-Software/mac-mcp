import Foundation
import Darwin

/// Blocking IPC and file locks belong on bounded native threads, not either shared worker pool.
public final class DedicatedThreads: Sendable {
    /// A pool whose workers can all be stuck in the kernel (an unresponsive network mount) adds a replacement thread,
    /// up to `max`, once every worker has been busy for longer than `after`. Replacements retire once idle.
    public struct Growth: Sendable {
        public let after: TimeInterval
        public let max: Int
        public init(after: TimeInterval, max: Int) { self.after = after; self.max = max }
    }

    /// Workers busy for longer than the pool's `Growth.after` are stuck; `oldest` is the longest-busy one's age.
    public struct Status: Sendable, Equatable {
        public let threads: Int
        public let busy: Int
        public let stuck: Int
        public let oldest: TimeInterval
    }

    /// Longest a relative wait lasts before it re-reads the monotonic deadline.
    static let waitCap: TimeInterval = 0.1
    static func waitInterval(until due: TimeInterval, now: TimeInterval) -> TimeInterval { min(max(0, due - now), waitCap) }

    /// NSCondition's dated wait uses wall time. Darwin's relative condition wait keeps a backwards clock adjustment
    /// from extending a timer, while atomically releasing the mutex so submissions cannot lose their wakeup.
    private final class Condition {
        private var mutex = pthread_mutex_t()
        private var condition = pthread_cond_t()

        init() {
            precondition(pthread_mutex_init(&mutex, nil) == 0)
            precondition(pthread_cond_init(&condition, nil) == 0)
        }
        deinit { pthread_cond_destroy(&condition); pthread_mutex_destroy(&mutex) }
        func lock() { pthread_mutex_lock(&mutex) }
        func unlock() { pthread_mutex_unlock(&mutex) }
        func broadcast() { pthread_cond_broadcast(&condition) }
        func wait() { pthread_cond_wait(&condition, &mutex) } // lint:allow-blocking dedicated native thread only
        func wait(for interval: TimeInterval) {
            var relative = timespec(tv_sec: Int(interval), tv_nsec: Int(interval.truncatingRemainder(dividingBy: 1) * 1_000_000_000))
            pthread_cond_timedwait_relative_np(&condition, &mutex, &relative) // lint:allow-blocking dedicated native timer thread only
        }
        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock()
            defer { unlock() }
            return try body()
        }
    }

    private final class State: @unchecked Sendable {
        struct Job {
            let due: TimeInterval
            let sequence: UInt64
            let work: @Sendable () -> Void
        }

        let condition = Condition()
        let name: String
        let base: Int
        let growth: Growth?
        var jobs: [Job] = []
        var sequence: UInt64 = 0
        var stopped = false
        var finishing = false
        var active = 0
        var spawned = 0
        var exited = 0
        var busySince: [Int: TimeInterval] = [:]
        var completions: [@Sendable () -> Void] = []

        init(name: String, base: Int, growth: Growth?) { self.name = name; self.base = base; self.growth = growth }

        /// Jobs run in (due, submission) order, so equal times are strictly first in, first out.
        func insert(due: TimeInterval, _ work: @escaping @Sendable () -> Void) {
            sequence &+= 1
            let job = Job(due: due, sequence: sequence, work: work)
            var low = 0, high = jobs.count
            while low < high {
                let mid = (low + high) / 2
                if (jobs[mid].due, jobs[mid].sequence) < (job.due, job.sequence) { low = mid + 1 } else { high = mid }
            }
            jobs.insert(job, at: low)
        }

        /// Called with the lock held.
        func stuckCount(now: TimeInterval) -> Int {
            guard let growth else { return 0 }
            return busySince.values.filter { now - $0 > growth.after }.count
        }

        /// Called with the lock held, after queueing: with every live worker stuck, work would wait for the kernel.
        func growIfStuck() {
            guard let growth, !stopped, !jobs.isEmpty, spawned - exited < growth.max,
                  busySince.count == spawned - exited, stuckCount(now: StreamIO.now) == busySince.count else { return }
            spawn()
        }

        /// Called with the lock held.
        func spawn() {
            let index = spawned
            spawned += 1
            let thread = Thread { [self] in loop(index) }
            thread.name = "mac-mcp.\(name).\(index)"
            thread.start()
        }

        func loop(_ index: Int) {
            while true {
                condition.lock()
                while !stopped && (jobs.isEmpty || jobs[0].due > StreamIO.now) {
                    if let first = jobs.first {
                        condition.wait(for: DedicatedThreads.waitInterval(until: first.due, now: StreamIO.now))
                    } else { condition.wait() } // lint:allow-blocking dedicated native thread, never a shared worker
                }
                if stopped { exited += 1; condition.unlock(); return }
                var work: (@Sendable () -> Void)? = jobs.removeFirst().work
                active += 1
                busySince[index] = StreamIO.now
                condition.unlock()
                work?()
                work = nil
                condition.lock()
                active -= 1
                busySince[index] = nil
                let finished = finishing && jobs.isEmpty && active == 0
                let callbacks = finished ? completions : []
                if finished { stopped = true; completions.removeAll(); condition.broadcast() }
                // Replacements only stand in for stuck workers: once those return, the extras are surplus. The exit is
                // counted here, under the lock, so two workers can't both retire and leave the pool below `base`.
                let surplus = !finished && spawned - exited - 1 - stuckCount(now: StreamIO.now) >= base
                if surplus { exited += 1 }
                condition.unlock()
                callbacks.forEach { $0() }
                if surplus { return }
            }
        }
    }

    private let state: State

    var isFinished: Bool { state.condition.withLock { state.exited == state.spawned } }

    public var status: Status {
        state.condition.withLock {
            let now = StreamIO.now
            return Status(threads: state.spawned - state.exited, busy: state.busySince.count, stuck: state.stuckCount(now: now),
                          oldest: state.busySince.values.map { now - $0 }.max() ?? 0)
        }
    }

    public init(name: String, count: Int = 1, growth: Growth? = nil) {
        precondition(count > 0 && growth.map { $0.max >= count } ?? true)
        state = State(name: name, base: count, growth: growth)
        state.condition.withLock { for _ in 0..<count { state.spawn() } }
    }

    deinit { finish {} }

    /// Drains submitted work, then stops the threads even if their owner remains alive. Safe to call again.
    public func finish(_ completion: @escaping @Sendable () -> Void) {
        state.condition.lock()
        if state.stopped { state.condition.unlock(); completion(); return }
        state.completions.append(completion)
        state.finishing = true
        // A final no-op also wakes an idle worker to run the completion after all earlier jobs, delayed ones included.
        state.insert(due: max(StreamIO.now, state.jobs.last?.due ?? 0), {})
        state.condition.broadcast()
        state.condition.unlock()
    }

    public func async(after delay: TimeInterval = 0, _ work: @escaping @Sendable () -> Void) {
        async(at: StreamIO.now + delay, work)
    }

    func async(at due: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        state.condition.lock()
        precondition(!state.finishing && !state.stopped, "work submitted after dedicated threads finished")
        state.insert(due: due, work)
        state.growIfStuck()
        state.condition.broadcast()
        state.condition.unlock()
    }
}
