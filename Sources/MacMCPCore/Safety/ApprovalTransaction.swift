import Foundation

/// Serializes the agent's and CLI's read → compare → append across processes. Acquisition never waits: a busy
/// agent keeps evaluating against the approved policy it read before, applying tightenings in memory only, and the CLI
/// tells the person who holds the lock and what to do. The file stays put in MacMCP's protected support directory, so
/// every process locks the same inode.
public final class ApprovalTransaction: Sendable {
    private let descriptor: Int32

    /// Who holds the lock, as the holder wrote it into the file once it had the lock.
    public struct Holder: Sendable, Equatable, Codable {
        public let pid: pid_t
        public let since: Date
        /// The agent, rather than the CLI (a person in Terminal).
        public let agent: Bool

        public init(pid: pid_t, since: Date, agent: Bool) {
            self.pid = pid
            self.since = since
            self.agent = agent
        }
    }

    /// Another process (or another call in this one) holds the lock.
    public struct Busy: Error, CustomStringConvertible {
        /// Nil if the holder hadn't written itself in yet, or the file can't be read.
        public let holder: Holder?

        /// Stays the same while the same holder does, so the agent reports it once.
        public var description: String {
            guard let holder else { return "another approval transaction is still running; try again" }
            let held = "since \(Self.time(holder.since))"
            if holder.agent {
                return "MacMCP's agent (pid \(holder.pid)) has held the approval lock \(held), waiting on the keychain. If it "
                    + "doesn't finish within a minute, run `mac-mcp restart`, then try again"
            }
            return "another `mac-mcp` command (pid \(holder.pid)) has held the approval lock \(held); it may be waiting "
                + "for someone to unlock the keychain or answer macOS. Finish or quit it, then try again"
        }

        static func time(_ date: Date) -> String {
            ISO8601DateFormatter.string(from: date, timeZone: .current,
                                        formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
        }

        static func duration(_ seconds: TimeInterval) -> String {
            let s = max(0, Int(seconds.rounded()))
            return s < 120 ? "\(s) s" : "\(s / 60) min"
        }
    }

    /// Whether this process is the agent, for the holder record. The CLI and tests are not.
    public static let isAgent = Bundle.main.bundleIdentifier == Paths.bundleID

    public init(path: String, agent: Bool = ApprovalTransaction.isAgent, now: Date = Date()) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw KeychainFailure("the approval transaction lock can't be opened") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_mode & 0o077 == 0 else {
            close(fd)
            throw KeychainFailure("the approval transaction lock isn't a private, owned regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { // lint:allow-blocking LOCK_NB never waits for another process
            let holder = Self.holder(fd)
            close(fd)
            throw Busy(holder: holder)
        }
        descriptor = fd
        // Who holds it, for whoever finds it busy. Only a holder writes, so readers see the current one or nothing.
        if let data = try? JSONEncoder().encode(Holder(pid: getpid(), since: now, agent: agent)) {
            _ = ftruncate(fd, 0)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
    }

    /// The holder the file names, if it names one that's still running.
    private static func holder(_ fd: Int32) -> Holder? {
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count > 0, let holder = try? JSONDecoder().decode(Holder.self, from: Data(bytes[0..<count])),
              holder.pid > 0, kill(holder.pid, 0) == 0 || errno == EPERM else { return nil }
        return holder
    }

    // An add that outlives its timeout retains this object until the keychain call actually returns. Closing the
    // descriptor then releases the lock; a later transaction must read the ledger again, including that late add.
    deinit {
        _ = ftruncate(descriptor, 0)   // no holder any more
        flock(descriptor, LOCK_UN) // lint:allow-blocking release even if a concurrent spawn inherited a duplicate
        close(descriptor)
    }
}
