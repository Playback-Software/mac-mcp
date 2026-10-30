import Darwin
import Foundation

/// One native kqueue thread services every child's pipes, exit, timeout and cancellation. No worker waits for a child.
public enum Subprocess {
    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
        public let timedOut: Bool
        /// A stream passed `outputLimit`: the child was stopped, the rest of that stream was dropped, and `stderr` ends
        /// with a note saying so. A child that still exited 0 is reported as exit 1, so no caller reads cut-off output
        /// as a complete result.
        public var truncated = false
    }

    /// Each of stdout and stderr is capped, so a runaway child can't grow the agent's memory without bound.
    public static let outputLimit = 16 * 1024 * 1024

    /// Reaps without blocking, like `waitpid(pid, &status, WNOHANG)`; tests replace it to simulate a lost child.
    typealias Reap = @Sendable (pid_t, UnsafeMutablePointer<Int32>) -> pid_t
    static let reapChild: Reap = { waitpid($0, $1, WNOHANG) }

    public static func run(_ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval,
                           outputLimit: Int = outputLimit) async throws -> Output {
        try await run(path, arguments, input: input, timeout: timeout, outputLimit: outputLimit, reap: reapChild)
    }

    static func run(_ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval,
                    outputLimit: Int = outputLimit, reap: @escaping Reap) async throws -> Output {
        try Task.checkCancellation()
        let child = Child(path, arguments, input: input, timeout: timeout, outputLimit: outputLimit, reap: reap)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Reactor.shared.submit {
                    child.completion = { continuation.resume(with: $0) }
                    Reactor.shared.start(child)
                }
            }
        } onCancel: {
            Reactor.shared.submit { child.stop() }
        }
    }

    /// Only the synchronous caller waits; the native event loop progresses even if all GCD workers are busy.
    public static func runBlocking(_ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval,
                                   outputLimit: Int = outputLimit) throws -> Output {
        let reply = BlockingReply()
        let child = Child(path, arguments, input: input, timeout: timeout, outputLimit: outputLimit, reap: reapChild)
        Reactor.shared.submit {
            child.completion = { reply.finish($0) }
            Reactor.shared.start(child)
        }
        return try reply.wait() // lint:allow-blocking runBlocking waits on its own synchronous calling thread
    }

    private final class BlockingReply: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Output, Error>?
        func finish(_ value: Result<Output, Error>) {
            condition.lock()
            result = value
            condition.signal()
            condition.unlock()
        }
        func wait() throws -> Output {
            condition.lock()
            defer { condition.unlock() }
            while result == nil { condition.wait() } // lint:allow-blocking synchronous caller only
            return try result!.get()
        }
    }

    /// All child state is confined to the reactor, including cancellation received before spawn.
    private final class Child: @unchecked Sendable {
        let path: String
        let arguments: [String]
        let input: Data?
        let timeout: TimeInterval
        let outputLimit: Int
        let reap: Reap
        var pid: pid_t = 0
        var outFD: Int32 = -1, errFD: Int32 = -1, inFD: Int32 = -1
        var stdout = Data(), stderr = Data(), offset = 0
        var deadline = TimeInterval.infinity
        var killAt = TimeInterval.infinity
        var drainUntil = TimeInterval.infinity
        var stopped = false, timedOut = false
        var truncatedStreams: [String] = []
        var status: Int32?
        var completion: (@Sendable (Result<Output, Error>) -> Void)?

        init(_ path: String, _ arguments: [String], input: Data?, timeout: TimeInterval, outputLimit: Int, reap: @escaping Reap) {
            self.path = path; self.arguments = arguments; self.input = input; self.timeout = timeout
            self.outputLimit = outputLimit; self.reap = reap
        }

        /// The child leads its own process group (see `spawn`), so signals reach whatever it started as well.
        func stop() {
            guard !stopped else { return }
            stopped = true
            if pid > 0 {
                // Buffered output can exceed the cap after the leader has already exited. Its descendants may still
                // hold the pipes open; there is no later leader-reap transition to clean them up in that case.
                killpg(pid, status == nil ? SIGTERM : SIGKILL)
                if status == nil { killAt = StreamIO.now + 2 }
            }
        }

        func spawn() throws {
            var descriptors: [Int32] = []
            defer { descriptors.forEach { close($0) } }
            func pipeEnds() throws -> [Int32] {
                var fds: [Int32] = [0, 0]
                guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                descriptors += fds
                for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
                return fds
            }
            let output = try pipeEnds(), errors = try pipeEnds()
            let incoming: [Int32]
            if input != nil { incoming = try pipeEnds() }
            else {
                let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                descriptors.append(fd)
                incoming = [fd, -1]
            }
            for fd in [output[0], errors[0], incoming[1]] where fd >= 0 {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            // A host may refuse before reading stdin. EPIPE must never terminate the server.
            if incoming[1] >= 0, fcntl(incoming[1], F_SETNOSIGPIPE, 1) != 0 { throw POSIXError(.EIO) }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
            var mask = sigset_t(), defaults = sigset_t()
            sigemptyset(&mask)
            sigfillset(&defaults)
            posix_spawnattr_setsigmask(&attributes, &mask)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETPGROUP))
            let argv = ([path] + arguments).map { strdup($0) } + [nil]
            let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
            let error = argv.withUnsafeBufferPointer {
                let argv = $0.baseAddress!
                return environment.withUnsafeBufferPointer {
                    posix_spawn(&pid, path, &actions, &attributes, argv, $0.baseAddress!)
                }
            }
            guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
            outFD = output[0]; errFD = errors[0]; inFD = incoming[1]
            descriptors.removeAll { $0 == outFD || $0 == errFD || $0 == inFD }
            deadline = StreamIO.now + timeout
        }

        func service() -> Bool {
            let now = StreamIO.now
            if status == nil {
                var raw: Int32 = 0
                let reaped = reap(pid, &raw)
                if reaped == pid {
                    status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
                } else if reaped < 0 && errno == ECHILD {
                    status = -1 // someone else reaped it; the child is gone, only its status is unknown
                }
                if status != nil {
                    // A call we stopped leaves nothing behind, even grandchildren that outlived the child.
                    if stopped { killpg(pid, SIGKILL) }
                    drainUntil = now + 2
                    closeInput()
                } else {
                    if now >= deadline, !stopped { timedOut = true; stop() }
                    if now >= killAt { killpg(pid, SIGKILL); killAt = .infinity }
                }
            }
            if Self.drain(&outFD, into: &stdout, limit: outputLimit) { truncated("stdout") }
            if Self.drain(&errFD, into: &stderr, limit: outputLimit) { truncated("stderr") }
            if inFD >= 0, let input {
                let n = input.withUnsafeBytes { bytes -> Int in
                    guard offset < bytes.count else { return 0 }
                    return Darwin.write(inFD, bytes.baseAddress! + offset, min(64 * 1024, bytes.count - offset))
                }
                if n > 0 { offset += n }
                if offset == input.count || (n < 0 && errno != EAGAIN && errno != EINTR) { closeInput() }
            }
            guard let status, (outFD < 0 && errFD < 0) || now >= drainUntil else { return false }
            for fd in [outFD, errFD] where fd >= 0 { close(fd) }
            outFD = -1; errFD = -1
            var errors = Self.text(stderr)
            if !truncatedStreams.isEmpty {
                let note = "[mac-mcp: \(truncatedStreams.joined(separator: " and ")) exceeded \(outputLimit / 1024 / 1024) MiB; "
                    + "the process was stopped and its output is cut off]"
                errors += (errors.isEmpty ? "" : "\n") + note
            }
            completion?(.success(Output(stdout: Self.text(stdout), stderr: errors,
                                        status: status == 0 && !truncatedStreams.isEmpty ? 1 : status,
                                        timedOut: timedOut, truncated: !truncatedStreams.isEmpty)))
            completion = nil
            return true
        }

        /// Over the limit: keep reading (and dropping) so the child can't block on a full pipe, but stop it.
        private func truncated(_ stream: String) {
            if !truncatedStreams.contains(stream) { truncatedStreams.append(stream) }
            stop()
        }

        private func closeInput() { if inFD >= 0 { close(inFD); inFD = -1 } }

        /// Returns true if bytes past `limit` were dropped.
        private static func drain(_ fd: inout Int32, into data: inout Data, limit: Int) -> Bool {
            guard fd >= 0 else { return false }
            var dropped = false
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            // Bound each turn so a noisy child can't delay another child's timeout or exit.
            for _ in 0..<4 {
                let n = Darwin.read(fd, &bytes, bytes.count)
                if n > 0 {
                    let room = max(0, limit - data.count)
                    data.append(contentsOf: bytes.prefix(min(n, room)))
                    if n > room { dropped = true }
                }
                else if n < 0 && errno == EINTR { continue }
                else {
                    if n == 0 || errno != EAGAIN { close(fd); fd = -1 }
                    break
                }
            }
            return dropped
        }

        private static func text(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private final class Reactor: @unchecked Sendable {
        static let shared = Reactor()
        private let fd: Int32
        private let lock = NSLock()
        private var jobs: [@Sendable () -> Void] = []
        private var children: [Child] = []

        private init() {
            fd = kqueue()
            precondition(fd >= 0, "cannot create subprocess kqueue")
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            change(0, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR)
            let thread = Thread { [self] in loop() }
            thread.name = "mac-mcp.subprocess"
            thread.start()
        }

        func submit(_ job: @escaping @Sendable () -> Void) {
            lock.withLock { jobs.append(job) }
            change(0, filter: EVFILT_USER, flags: 0, notes: UInt32(NOTE_TRIGGER))
        }

        func start(_ child: Child) {
            // Cancelled before it began: spawning a child only to stop it could still run its first instructions.
            if child.stopped { child.completion?(.failure(CancellationError())); child.completion = nil; return }
            do {
                try child.spawn()
                change(UInt(child.pid), filter: EVFILT_PROC, flags: EV_ADD | EV_ONESHOT, notes: UInt32(NOTE_EXIT))
                for fd in [child.outFD, child.errFD] { change(UInt(fd), filter: EVFILT_READ, flags: EV_ADD) }
                if child.inFD >= 0 { change(UInt(child.inFD), filter: EVFILT_WRITE, flags: EV_ADD) }
                children.append(child)
            } catch { child.completion?(.failure(error)); child.completion = nil }
        }

        private func change(_ ident: UInt, filter: Int32, flags: Int32, notes: UInt32 = 0) {
            var event = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: notes, data: 0, udata: nil)
            _ = kevent(fd, &event, 1, nil, 0, nil)
        }

        private func loop() {
            var events = Array(repeating: kevent(), count: 64)
            while true {
                let ready = lock.withLock { let ready = jobs; jobs.removeAll(); return ready }
                ready.forEach { $0() }
                children.removeAll { $0.service() }
                let next = children.map { $0.status == nil ? min($0.stopped ? .infinity : $0.deadline, $0.killAt) : $0.drainUntil }.min()
                if let next, next.isFinite {
                    let left = max(0, next - StreamIO.now)
                    var timeout = timespec(tv_sec: Int(left), tv_nsec: Int((left - floor(left)) * 1_000_000_000))
                    _ = kevent(fd, nil, 0, &events, Int32(events.count), &timeout)
                } else {
                    _ = kevent(fd, nil, 0, &events, Int32(events.count), nil) // dedicated event-loop thread
                }
            }
        }
    }
}
