import Foundation

/// Exclusive use of the GUI, for evaluations and GUI tests.
///
/// There is one screen, one keyboard and one mouse. Two clients driving them at once spoil each other's work (in M5,
/// integration tests run by another session derailed an eval run). While a lease is held, the agent refuses mutating
/// tools from every connection that doesn't present the lease's token, and `scripts/build.sh` and the GUI
/// integration tests refuse to start. Read-only tools keep working for everyone.
///
/// A lease ends when it's released, when it expires, or when the process that took it exits, so a crashed harness
/// can't strand the box.
public struct Lease: Codable, Sendable, Equatable {
    public let token: String
    public let holder: String
    public let reason: String
    /// The process the lease belongs to (usually the harness that asked for it, not the short-lived CLI), or 0 for
    /// a lease that lasts until it's released or expires.
    public let pid: Int32
    public let acquired: Date
    public let expires: Date

    public var isActive: Bool { expires > Date() && Lease.alive(pid) }

    public var summary: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(holder) (\(reason))\(pid > 0 ? ", pid \(pid)" : ""), until \(f.string(from: expires))"
    }

    static func alive(_ pid: Int32) -> Bool { pid <= 0 || kill(pid, 0) == 0 || errno == EPERM }
}

public enum LeaseError: Error, CustomStringConvertible {
    case held(Lease)
    case io(String)

    public var description: String {
        switch self {
        case let .held(l): "The GUI is already leased by \(l.summary)."
        case let .io(m): "Lease file: \(m)"
        }
    }
}

public enum LeaseStore {
    /// The environment variable through which a lease holder's token reaches the relay, the CLI and tests.
    public static let tokenVariable = "MAC_MCP_LEASE"

    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["MAC_MCP_LEASE_FILE"] ?? Paths.supportDir + "/lease.json"
    }

    /// The token this process holds, if any (from MAC_MCP_LEASE).
    public static var ownToken: String? {
        ProcessInfo.processInfo.environment[tokenVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The active lease, or nil. Expired leases and leases whose process has exited are cleared.
    public static func current(path: String = defaultPath) -> Lease? {
        locked(path) { readActive(path) }
    }

    public static func acquire(holder: String, reason: String, minutes: Double, pid: Int32,
                               path: String = defaultPath) throws -> Lease {
        try locked(path) {
            if let existing = readActive(path) { throw LeaseError.held(existing) }
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // the file keeps whole seconds
            let lease = Lease(token: UUID().uuidString.lowercased(), holder: holder, reason: reason, pid: pid,
                              acquired: now, expires: now.addingTimeInterval(minutes * 60))
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try writePrivately(enc.encode(lease), to: path)
            } catch { throw LeaseError.io("\(error)") }
            return lease
        }
    }

    /// Writes atomically with owner-only permissions from the first byte. (`Data.write(options: .atomic)` creates
    /// its temporary file with the umask's mode, so the token was readable until a chmod afterwards.)
    static func writePrivately(_ data: Data, to path: String) throws {
        let temp = path + ".tmp-\(UUID().uuidString)"
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw LeaseError.io("create \(temp): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(temp)
            throw error
        }
        guard rename(temp, path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(temp)
            throw LeaseError.io("rename to \(path): \(why)")
        }
    }

    /// Releases the lease if `token` holds it. Returns whether it did.
    @discardableResult
    public static func release(token: String, path: String = defaultPath) -> Bool {
        locked(path) {
            guard let lease = read(path), lease.token == token else { return false }
            try? FileManager.default.removeItem(atPath: path)
            return true
        }
    }

    /// Why a client presenting `token` may not change the GUI right now, or nil if it may.
    public static func refusal(token: String?, path: String = defaultPath) -> String? {
        guard let lease = current(path: path), lease.token != token else { return nil }
        return "Refused: the GUI is leased by \(lease.summary), so other clients can't change it until then. "
            + "Looking still works (mac_snapshot, mac_screenshot, mac_doctor, mac_app/mac_window list, mac_clipboard get). "
            + "Wait, or ask whoever holds the lease."
    }

    // MARK: file access

    private static func read(_ path: String) -> Lease? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Lease.self, from: data)
    }

    private static func readActive(_ path: String) -> Lease? {
        guard let lease = read(path) else { return nil }
        if lease.isActive { return lease }
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }

    /// Serializes read-modify-write across processes with an flock on a sibling lock file.
    private static func locked<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
        let lockPath = path + ".lock"
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }   // lint:allow-blocking held for a file read/write only
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }   // lint:allow-blocking unlocking never blocks
        return try body()
    }
}
