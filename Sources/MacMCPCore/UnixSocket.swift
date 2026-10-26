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

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket", path: path) }
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw SocketError("connect", path: path) }
        return fd
    }
}
