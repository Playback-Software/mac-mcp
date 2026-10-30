import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    public init(_ operation: String, path: String) {
        description = "\(operation) \(path): \(String(cString: strerror(errno)))"
    }
}

/// Minimal AF_UNIX stream sockets: the agent listens, the relay connects.
public enum UnixSocket {
    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            errno = ENAMETOOLONG
            throw SocketError("socket path too long", path: path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        return addr
    }

    /// Binds and listens on `path`, replacing any stale socket file. The socket is made owner-only (0600):
    /// whoever can connect can drive this Mac.
    public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing support directory may predate that (or have been loosened); tighten it. An overridden socket
        // path's directory is left alone: it could be /tmp or a home folder.
        if dir == Paths.supportDir { chmod(dir, 0o700) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket", path: path) }
        var addr = try address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw SocketError("bind", path: path) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, backlog) == 0 else { close(fd); throw SocketError("listen", path: path) }
        return fd
    }

    /// Whether something accepts TCP connections on host:port (IPv4), within `timeout`.
    public static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval = 1) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    public static func connect(path: String, deadline: TimeInterval = StreamIO.now + 15) throws -> Int32 {
        guard StreamIO.now < deadline else { errno = ETIMEDOUT; throw SocketError("connect deadline exceeded", path: path) }
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket", path: path) }
        do {
            try StreamIO.configure(fd)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw SocketError("connect", path: path) }
                try StreamIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var error: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0, error == 0 else {
                    if error != 0 { errno = error }
                    throw SocketError("connect", path: path)
                }
            }
            guard StreamIO.now < deadline else { errno = ETIMEDOUT; throw SocketError("connect deadline exceeded", path: path) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            return fd
        } catch { close(fd); throw error }
    }
}

/// Synchronous descriptor I/O for dedicated reader/writer threads and the CLI.
public enum StreamIO {
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public static let frameLimit = 16 * 1024 * 1024
    public static let queueLimit = 32 * 1024 * 1024

    public static func configure(_ fd: Int32) throws {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)   // AgentClient also accepts pipes to a relay
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketError("nonblocking I/O", path: "descriptor")
        }
    }

    public static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let left = deadline - now
            guard left > 0 else { errno = ETIMEDOUT; throw SocketError("deadline exceeded", path: "descriptor") }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, Int32(min(ceil(left * 1000), Double(Int32.max))))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { if n == 0 { errno = ETIMEDOUT }; throw SocketError("poll", path: "descriptor") }
            guard p.revents & Int16(POLLNVAL) == 0 else { errno = EBADF; throw SocketError("poll", path: "descriptor") }
            if events & Int16(POLLOUT) != 0, p.revents & Int16(POLLERR | POLLHUP) != 0 {
                errno = EPIPE
                throw SocketError("peer closed", path: "descriptor")
            }
            return
        }
    }

    /// The longest one write may take in all, however steadily its reader drains it: ten minutes, plus a second per
    /// 16 KiB so a large frame over a slow link that is genuinely moving still fits. A progress timeout alone lets a
    /// reader that takes one byte just inside each timeout hold the writer, and everything queued behind it, for ever.
    public static func writeBudget(bytes: Int) -> TimeInterval { 600 + Double(max(bytes, 0)) / 16_384 }

    /// Writes all of `data`. `deadline` is absolute; `progressTimeout` is reset by every accepted byte; `maxDuration`
    /// bounds the whole write from now, whatever progress it makes.
    public static func writeAll(_ fd: Int32, _ data: Data, deadline: TimeInterval = .infinity,
                                progressTimeout: TimeInterval? = nil, maxDuration: TimeInterval? = nil) throws {
        try writeAll(data, deadline: deadline, progressTimeout: progressTimeout, maxDuration: maxDuration,
                     waitForWrite: { try wait(fd, events: Int16(POLLOUT), deadline: $0) },
                     writeChunk: { Darwin.write(fd, $0, $1) })
    }

    static func writeAll(_ data: Data, deadline: TimeInterval = .infinity, progressTimeout: TimeInterval? = nil,
                         maxDuration: TimeInterval? = nil, now: () -> TimeInterval = { StreamIO.now },
                         waitForWrite: (TimeInterval) throws -> Void, writeChunk: (UnsafeRawPointer, Int) -> Int) throws {
        let deadline = maxDuration.map { min(deadline, now() + $0) } ?? deadline
        var progressDeadline = progressTimeout.map { now() + $0 } ?? .infinity
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try waitForWrite(min(deadline, progressDeadline))
                let n = writeChunk(raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard n > 0 else { throw SocketError("write", path: "descriptor") }
                offset += n
                if let progressTimeout { progressDeadline = now() + progressTimeout }
            }
        }
    }
}

/// Whole, ordered writes with a byte budget, a timeout for stalled progress once a write starts, and a cap on how
/// long one write may take in all (`StreamIO.writeBudget`). The owner closes the descriptor only after `finish`
/// completes; teardown rejects future sends under the same lock before draining the writer.
public final class StreamWriter: @unchecked Sendable {
    private let fd: Int32
    private let queue = DedicatedThreads(name: "stream-writer")
    private let lock = NSLock()
    private let maxBytes: Int
    private let timeout: TimeInterval
    private var closed = false
    private var queuedBytes = 0

    public init(fd: Int32, maxBytes: Int = StreamIO.queueLimit, timeout: TimeInterval = 10) {
        self.fd = fd
        self.maxBytes = maxBytes
        self.timeout = timeout
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            guard data.count <= maxBytes - queuedBytes else { stop(); return false }
            queuedBytes += data.count
            queue.async { [self] in
                defer { lock.withLock { queuedBytes -= data.count } }
                guard !lock.withLock({ closed }) else { return }
                do { try StreamIO.writeAll(fd, data, progressTimeout: timeout, maxDuration: StreamIO.writeBudget(bytes: data.count)) }
                catch { abort() }
            }
            return true
        }
    }

    private func stop() {
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)   // wakes both the reader and a writer waiting for a slow peer
    }

    public func halfClose() {
        lock.withLock {
            guard !closed else { return }
            queue.async { [self] in shutdown(fd, SHUT_WR) }
        }
    }

    public func abort() { lock.withLock { stop() } }

    public func finish(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { stop() }
        queue.finish(completion)
    }

    public func finish() async {
        await withCheckedContinuation { c in finish { c.resume() } }
    }
}
