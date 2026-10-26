import Foundation

/// Runs child processes without `Process.waitUntilExit()`.
///
/// `waitUntilExit()` spins the calling thread's run loop until the exit is noticed. On a Swift-concurrency thread
/// nothing wakes that run loop, so it can block forever even after the child has exited and been reaped. Seen in M5:
/// `mac_script` hung for 13 minutes while holding the action lock. Here a termination handler signals a semaphore,
/// both pipes are drained concurrently (a full pipe can't stall the child), and a child that ignores SIGTERM after
/// its timeout gets SIGKILL.
public enum Subprocess {
    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
        public let timedOut: Bool
    }

    /// Async variant: the blocking wait happens on a GCD thread, not on the cooperative pool.
    /// Cancelling the calling task stops the child: an abandoned call (deadline, client cancel) must not leave a script
    /// or Shortcut driving apps after the action lock has moved on.
    public static func run(_ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> Output {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try runBlocking(path, arguments, input: input, timeout: timeout, child: child) })
                }
            }
        } onCancel: {
            child.stop()
        }
    }

    /// Blocks the calling thread on a semaphore (safe on any thread, unlike `waitUntilExit()`).
    public static func runBlocking(_ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) throws -> Output {
        try runBlocking(path, arguments, input: input, timeout: timeout, child: Child())
    }

    private static func runBlocking(_ path: String, _ arguments: [String], input: Data?, timeout: TimeInterval, child: Child) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        let drained = DispatchGroup()
        let out = Collected(), err = Collected()
        for (pipe, sink) in [(stdout, out), (stderr, err)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
                drained.leave()
            }
        }

        try p.run()
        child.started(p)
        if let input {
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()   // lint:allow-blocking SIGKILL can't be ignored; this returns promptly
            }
        }
        // EOF arrives once the child exits, unless a grandchild inherited the pipe; don't wait on that forever.
        _ = drained.wait(timeout: .now() + 2)
        return Output(stdout: out.text, stderr: err.text, status: p.terminationStatus, timedOut: timedOut)
    }

    /// The running child, so a cancellation from another thread can stop it (even one that arrives before it starts).
    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        func started(_ p: Process) {
            let stopNow: Bool = lock.withLock { process = p; return stopped }
            if stopNow { Child.terminate(p) }
        }

        func stop() {
            let p: Process? = lock.withLock { stopped = true; return process }
            if let p { Child.terminate(p) }
        }

        /// SIGTERM, then SIGKILL if it's still there two seconds later.
        private static func terminate(_ p: Process) {
            guard p.isRunning else { return }
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        var text: String {
            lock.withLock { String(decoding: data, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
