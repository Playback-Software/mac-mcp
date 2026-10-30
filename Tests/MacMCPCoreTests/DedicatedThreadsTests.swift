import Foundation
import Testing
@testable import MacMCPCore

@Suite struct DedicatedThreadsTests {
    @Test func finishDrainsWorkAndEndsThreadsWhileTheOwnerIsRetained() async throws {
        let threads = DedicatedThreads(name: "lifecycle", count: 2)
        let gate = DispatchSemaphore(value: 0)
        let (events, stream) = AsyncStream<Int>.makeStream()
        threads.async { gate.wait(); stream.yield(1) }
        threads.async { gate.wait(); stream.yield(2) }
        threads.finish { stream.yield(3); stream.finish() }
        gate.signal()
        gate.signal()
        var seen: [Int] = []
        for await value in events { seen.append(value) }
        #expect(Set(seen.prefix(2)) == [1, 2] && seen.last == 3)
        for _ in 0..<100 where !threads.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(threads.isFinished)
        // Finishing twice must also complete, including when the native threads have already exited.
        await withCheckedContinuation { c in threads.finish { c.resume() } }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        func add(_ value: Int) { lock.withLock { items.append(value) } }
        var values: [Int] { lock.withLock { items } }
    }

    private func drain(_ threads: DedicatedThreads) async {
        await withCheckedContinuation { c in threads.finish { c.resume() } }
    }

    /// Writers need strict FIFO: jobs with identical times must not depend on the sort being stable.
    @Test func jobsWithEqualTimesRunInSubmissionOrder() async {
        let threads = DedicatedThreads(name: "fifo")
        let gate = DispatchSemaphore(value: 0)
        let log = Log()
        threads.async { gate.wait() }
        let due = StreamIO.now + 0.05
        for index in 0..<500 { threads.async(at: due) { log.add(index) } }
        gate.signal()
        await drain(threads)
        #expect(log.values == Array(0..<500))
    }

    @Test func delayedJobsRunInTimeOrderAndFinishWaitsForThem() async {
        let threads = DedicatedThreads(name: "delayed")
        let log = Log()
        threads.async(after: 0.2) { log.add(3) }
        threads.async(after: 0.05) { log.add(1) }
        threads.async(after: 0.1) { log.add(2) }
        await drain(threads)
        #expect(log.values == [1, 2, 3], "finish() drains delayed work too, in order")
    }

    /// Relative waits re-read the monotonic deadline at least every 100 ms.
    @Test func relativeWaitsAreCappedToRecheckDeadlines() {
        #expect(DedicatedThreads.waitInterval(until: 110, now: 100) == DedicatedThreads.waitCap)
        #expect(DedicatedThreads.waitCap <= 0.1)
        #expect(DedicatedThreads.waitInterval(until: 100.03, now: 100) < 0.031)
        #expect(DedicatedThreads.waitInterval(until: 90, now: 100) == 0)
    }

    @Test(.timeLimit(.minutes(1))) func stuckWorkersAreReplacedAndReported() async throws {
        let threads = DedicatedThreads(name: "stuck", count: 2, growth: .init(after: 0.5, max: 4))
        let gate = DispatchSemaphore(value: 0)
        let (started, startedStream) = AsyncStream<Void>.makeStream()
        for _ in 0..<2 { threads.async { startedStream.yield(); gate.wait() } }
        var seen = 0
        for await _ in started { seen += 1; if seen == 2 { break } }
        let log = Log()
        threads.async { log.add(1) }
        try await Task.sleep(for: .milliseconds(700))
        #expect(threads.status.stuck == 2 && threads.status.oldest >= 0.5)
        // Every worker has been stuck for longer than the limit: a new submission gets a replacement thread.
        threads.async { log.add(2) }
        for _ in 0..<200 where log.values.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(log.values) == [1, 2])
        // Replacements are capped.
        for _ in 0..<10 { threads.async { gate.wait() } }
        try await Task.sleep(for: .milliseconds(700))
        for _ in 0..<10 { threads.async { gate.wait() } }
        #expect(threads.status.threads <= 4)
        // Once the stuck workers return, the extras retire and the pool is back to its base size.
        for _ in 0..<30 { gate.signal() }
        for _ in 0..<200 where threads.status.threads != 2 || threads.status.busy != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(threads.status == .init(threads: 2, busy: 0, stuck: 0, oldest: 0))
        await drain(threads)
    }

    @Test func poolsWithoutGrowthOrWithWorkersNotYetStuckNeverAddThreads() async throws {
        for growth in [nil, DedicatedThreads.Growth(after: 3600, max: 4)] {
            let threads = DedicatedThreads(name: "fixed", count: 1, growth: growth)
            let gate = DispatchSemaphore(value: 0)
            let log = Log()
            threads.async { gate.wait() }
            try await Task.sleep(for: .milliseconds(50))
            threads.async { log.add(1) }
            try await Task.sleep(for: .milliseconds(50))
            #expect(threads.status.threads == 1 && threads.status.stuck == 0 && log.values.isEmpty, "the job waits for the busy worker")
            gate.signal()
            await drain(threads)
            #expect(log.values == [1])
        }
    }
}
