import Foundation
import Synchronization

/// Reserves blocks of id numbers that never repeat across agent restarts.
///
/// Relays keep their clients' MCP sessions while the agent restarts, so a client may still hold `e12` or `c3` from
/// the previous incarnation. If every incarnation counted from 1, those ids would resolve to whatever the new one
/// minted first, for whoever asked first. Instead each kind of id (`e` refs, `s` snapshots, `c` screenshots) takes a
/// block of numbers at a time and records the block's end in a file before using any of it, so a new incarnation
/// starts above everything an earlier one could have handed out. Blocks keep disk writes rare; their size trades
/// writes against how fast ids grow over restarts (and ids cost agents tokens, so blocks stay modest).
///
/// A block is issued only once its end is durably on disk: a write that fails (disk full, directory unwritable)
/// issues nothing, since after a restart the unchanged file would hand the same numbers out again. Every
/// reservation reloads the file under an interprocess lock, so a second agent instance (another socket, a test)
/// sharing the file can't take the same block, and neither can overwrite the other's newer marks.
///
/// A file that exists but can't be read or decoded is not treated as empty. The highest number ever reserved, of
/// any kind, is also kept in a sibling file (`ids.json.highwater`), written and synced before the id file on every
/// reservation that raises it, so when the id file's marks are lost that mark still says what was issued: numbering
/// restarts above it, for every kind, and the problem is logged. The mark is kept apart from the id file because
/// the clock can't take its place: a floor taken from the time lies below the ids a block issued after an earlier
/// recovery until the clock catches up, and two recoveries close together would reissue them. Only an install with
/// no high-water file at all (one from before it was kept) falls back to the current time in milliseconds, which no
/// such incarnation can have reached; with both files unusable, nothing is issued until a person fixes them. The
/// floor is recorded in the id file for every kind, not just the one being reserved: the other kinds have lost
/// their marks too, and without it the next `e` or `c` reservation would read a valid file with no mark for them
/// and start at 1. The unusable file is left in place until its replacement is written and synced, so a failed
/// replacement followed by a retry sees an unusable file again rather than a missing one.
///
/// A `path` of nil keeps nothing: counters start at 1 every time (tests, throwaway stores).
public final class IDBlocks: Sendable {
    private static let threads = DedicatedThreads(name: "id-blocks")
    public static let shared = IDBlocks(path: Paths.supportDir + "/ids.json")
    /// A fresh allocator that persists nothing: its counters start at 1.
    public static var ephemeral: IDBlocks { IDBlocks(path: nil) }

    public let path: String?
    /// Tests: a failure injected into writing the replacement file (a full disk can't be arranged in a test).
    let writeFault: (@Sendable () throws -> Void)?
    /// The clock behind the last-resort recovery floor (tests set it to show what wall time can and can't prove).
    let now: @Sendable () -> Date

    public convenience init(path: String?) { self.init(path: path, writeFault: nil) }

    init(path: String?, writeFault: (@Sendable () throws -> Void)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.writeFault = writeFault
        self.now = now
    }

    /// The next unused block of `size` numbers for `kind`, recorded on disk before it is returned. Throws when it
    /// can't be recorded: no id is ever handed out that a later incarnation could repeat.
    public func reserve(_ kind: String, size: Int) async throws -> ClosedRange<Int> {
        let size = max(size, 1)
        guard let path else { return ephemeralReserve(kind, size: size) }
        // The lock can wait on another process, so it is taken off the cooperative pool.
        return try await withCheckedThrowingContinuation { c in
            Self.threads.async {
                c.resume(with: Result {
                    do {
                        return try Self.locked(path) {
                            try Self.reserveOnDisk(kind, size: size, at: path, writeFault: self.writeFault, now: self.now)
                        }
                    } catch let e as IDBlocksError {
                        throw e
                    } catch {
                        log("could not record an id block for \(kind): \(error)")
                        throw IDBlocksError.notRecorded(path: path, error: "\(error)")
                    }
                })
            }
        }
    }

    // MARK: Ephemeral

    private let ephemeralMarks = Mutex<[String: Int]>([:])

    private func ephemeralReserve(_ kind: String, size: Int) -> ClosedRange<Int> {
        ephemeralMarks.withLock { marks in
            let start = (marks[kind] ?? 0) + 1
            marks[kind] = start + size - 1
            return start...(start + size - 1)
        }
    }

    // MARK: On disk

    /// What the file held when it was read.
    enum State: Equatable {
        /// No file yet: the first incarnation ever, or a fresh install. Numbering starts at 1.
        case missing
        case marks([String: Int])
        /// The file exists but can't be read or doesn't decode: whatever it held is unknown.
        case unusable(String)
    }

    /// The mark under which a kind with no mark of its own starts: written when the file's marks were lost, so every
    /// kind restarts above anything an earlier incarnation could have handed out, not only the kind reserved first.
    static let floorKey = "floor"

    static func load(_ path: String) -> State {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return .missing
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) {
            return .missing
        } catch {
            return .unusable("\(error)")
        }
        guard let marks = try? JSONDecoder().decode([String: Int].self, from: data), marks.values.allSatisfy({ $0 >= 0 }) else {
            return .unusable("the file doesn't decode")
        }
        return .marks(marks)
    }

    /// The sibling file holding the highest number ever reserved, of any kind, and its one key.
    static func highWaterPath(_ path: String) -> String { path + ".highwater" }
    static let highWaterKey = "highwater"

    /// What the high-water file held when it was read.
    enum HighWater: Equatable {
        /// No file: an install from before the mark was kept, or a fresh one.
        case missing
        case mark(Int)
        case unusable(String)
    }

    static func loadHighWater(_ path: String) -> HighWater {
        switch load(highWaterPath(path)) {
        case .missing: .missing
        case let .marks(m): m[highWaterKey].map(HighWater.mark) ?? .unusable("the file holds no mark")
        case let .unusable(why): .unusable(why)
        }
    }

    /// A start no earlier incarnation can have reached: milliseconds since 1970. The last resort when the file's
    /// marks are lost and no high-water mark was ever kept; an incarnation would have to mint over a thousand ids a
    /// second for as long as it ran to catch up. It can't be used twice: after one recovery the ids run ahead of
    /// the clock by the blocks issued since, which is why the mark is kept.
    static func fallbackStart(now: Date = Date()) -> Int { Int(now.timeIntervalSince1970 * 1000) }

    /// Runs under the lock: reload, take the block, write it back durably. Each step reads the file afresh, so marks
    /// written by another process since the last reservation are seen. The high-water mark is raised and written
    /// before the id file, so a crash between the two leaves a mark at or above every id recorded, never below.
    private static func reserveOnDisk(_ kind: String, size: Int, at path: String,
                                      writeFault: (@Sendable () throws -> Void)? = nil,
                                      now: () -> Date = { Date() }) throws -> ClosedRange<Int> {
        var marks: [String: Int] = [:]
        let highWater = loadHighWater(path)
        switch load(path) {
        case .missing:
            // Nothing recorded, unless the mark says ids were issued and the id file alone went missing.
            switch highWater {
            case .missing: break
            case let .mark(h):
                marks[floorKey] = h + 1
                log("id file \(path) is missing but \(highWaterPath(path)) records ids up to \(h): numbering restarts above it")
            case let .unusable(why):
                log("id file \(path) is missing and \(highWaterPath(path)) is unusable (\(why)): no ids can be issued")
                throw IDBlocksError.unrecoverable(path: path, highWaterPath: highWaterPath(path))
            }
        case let .marks(m):
            marks = m
        case let .unusable(why):
            // The floor is written with the block; the unusable file stays until that replacement is on disk.
            switch highWater {
            case let .mark(h):
                marks[floorKey] = h + 1
                log("id file \(path) is unusable (\(why)): numbering restarts above the recorded high-water mark \(h)")
            case .missing:
                marks[floorKey] = fallbackStart(now: now())
                log("id file \(path) is unusable (\(why)) and no high-water mark was kept: numbering restarts from "
                    + "\(marks[floorKey]!) so no earlier id can repeat")
            case let .unusable(hwWhy):
                log("id file \(path) is unusable (\(why)) and so is \(highWaterPath(path)) (\(hwWhy)): no ids can be issued")
                throw IDBlocksError.unrecoverable(path: path, highWaterPath: highWaterPath(path))
            }
        }
        let start = max(marks[kind].map { $0 + 1 } ?? 1, marks[floorKey] ?? 1)
        let end = start + size - 1
        marks[kind] = end
        let recorded: Int? = if case let .mark(h) = highWater { h } else { nil }
        let mark = max(end, recorded ?? 0, marks.values.max() ?? 0)
        do {
            if recorded != mark { try save([highWaterKey: mark], to: highWaterPath(path), writeFault: writeFault) }
            try save(marks, to: path, writeFault: writeFault)
        } catch {
            log("could not record id block \(kind) \(start)…\(end): \(error)")
            throw IDBlocksError.notRecorded(path: path, error: "\(error)")
        }
        return start...end
    }

    /// Writes the marks to a sibling file, syncs it, renames it over `path`, then syncs the directory: readers see
    /// the old file or the new one, the data and the name are on disk before any id from the block is handed out,
    /// and an unusable old file (even one that can't be opened for writing) stays in place until its replacement
    /// exists.
    private static func save(_ marks: [String: Int], to path: String, writeFault: (@Sendable () throws -> Void)? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(marks)
        try writeFault?()
        let tmp = path + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileError("create \(tmp)") }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw FileError("write \(tmp)") }
                    offset += n
                }
            }
            guard sync(fd) else { throw FileError("sync \(tmp)") }
            guard close(fd) == 0 else { throw FileError("close \(tmp)") }
        } catch {
            close(fd)
            unlink(tmp)
            throw error
        }
        guard rename(tmp, path) == 0 else {
            let e = FileError("rename \(tmp) over \(path)")
            unlink(tmp)
            throw e
        }
        try syncDirectory(containing: path)
    }

    /// Flushes a descriptor through to the disk. `fsync` on macOS only hands the data to the drive, and a power
    /// loss can still lose what sits in its cache, so the full flush is asked for first; a volume that can't do it
    /// (a network mount) gets the plain sync.
    static func sync(_ fd: Int32) -> Bool { fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 }

    /// The rename is an entry in the directory, and the directory's own data isn't synced with the file's: without
    /// this, a power loss can bring back the old file and its old marks, and the block just issued would be issued
    /// again. Throws when it can't be done: the file is in place, but the block isn't proven durable.
    static func syncDirectory(containing path: String) throws {
        let fd = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileError("open the folder of \(path)") }
        defer { close(fd) }
        guard sync(fd) else { throw FileError("sync the folder of \(path)") }
    }

    private struct FileError: Error, CustomStringConvertible {
        let description: String
        init(_ operation: String) { description = "\(operation): \(String(cString: strerror(errno)))" }
    }

    /// Serializes read-modify-write across processes with an flock on a sibling lock file (the data file itself is
    /// replaced by each atomic write, so a lock on it wouldn't hold). Called off the cooperative pool.
    private static func locked<T>(_ path: String, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IDBlocksError.notRecorded(path: path, error: "cannot open the lock file") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {   // lint:allow-blocking runs on a dedicated native thread
            throw IDBlocksError.notRecorded(path: path, error: "cannot lock the id file")
        }
        defer { flock(fd, LOCK_UN) }   // lint:allow-blocking unlocking never blocks
        return try body()
    }
}

/// A block of ids couldn't be recorded, or it couldn't be told which ids were already issued, so none were issued.
public enum IDBlocksError: Error, CustomStringConvertible {
    case notRecorded(path: String, error: String)
    /// Both the id file and the high-water file are unusable: no floor can be established, and one taken from the
    /// clock could repeat ids issued after an earlier recovery.
    case unrecoverable(path: String, highWaterPath: String)

    public var description: String {
        switch self {
        case let .notRecorded(path, error):
            "Could not record ids in \(path) (\(error)), so no snapshot or screenshot ids can be issued. "
                + "Free disk space or fix the folder's permissions, then retry."
        case let .unrecoverable(path, highWaterPath):
            "Could not tell which ids were already issued: \(path) and \(highWaterPath) are both unreadable, so no "
                + "snapshot or screenshot ids can be issued. Fix the files' permissions, or move both aside to restart "
                + "numbering (ids from before may then repeat; reconnect MCP clients afterwards)."
        }
    }
}

/// Mints one kind of id (`e12`) from blocks reserved through `IDBlocks`. Numbers below `first` were never minted by
/// this incarnation: they come from an earlier one, or were never handed out.
///
/// Reserving suspends (the file is locked and written), so it is a separate step from minting: an owner calls
/// `blockNeeded` and `add(_:)` around an `await` on `IDBlocks.reserve`, without holding the counter inout across the
/// suspension, then mints synchronously. Two owners that both reserve during the same gap both add their block; the
/// extra block is used up later, never repeated.
public struct IDCounter: Sendable {
    public let prefix: String
    public let blocks: IDBlocks
    public let blockSize: Int
    /// Reserved, not yet used up, in order of use.
    private var reserved: [ClosedRange<Int>] = []
    /// The first number this incarnation can mint; nil until the first block is reserved.
    public private(set) var first: Int?

    public init(prefix: String, blocks: IDBlocks, blockSize: Int) {
        self.prefix = prefix
        self.blocks = blocks
        self.blockSize = blockSize
    }

    /// Numbers that can be minted without reserving another block.
    public var remaining: Int { reserved.reduce(0) { $0 + $1.count } }

    /// Whether minting `count` more numbers needs another block first.
    public func blockNeeded(for count: Int = 1) -> Bool { remaining < count }

    /// Makes a reserved block available for minting.
    public mutating func add(_ block: ClosedRange<Int>) {
        reserved.append(block)
        if first == nil { first = block.lowerBound }
    }

    /// One more block from the allocator; `add` it once it arrives.
    public func reserveBlock() async throws -> ClosedRange<Int> { try await blocks.reserve(prefix, size: blockSize) }

    /// The next number. Reserve first (`blockNeeded`, `add`); minting with nothing reserved is a programming error.
    public mutating func mintNumber() -> Int {
        precondition(!reserved.isEmpty, "mint without a reserved block")
        let n = reserved[0].lowerBound
        if reserved[0].count == 1 { reserved.removeFirst() } else { reserved[0] = (n + 1)...reserved[0].upperBound }
        return n
    }

    public mutating func mint() -> String { prefix + String(mintNumber()) }

    /// The number in an id of this kind ("e12" → 12), or nil for anything else.
    public func number(of id: String) -> Int? {
        guard id.hasPrefix(prefix), let n = Int(id.dropFirst(prefix.count)), n > 0 else { return nil }
        return n
    }

    /// Whether `id` was minted by an earlier incarnation of the agent (so it can never resolve here).
    public func isFromEarlierIncarnation(_ id: String) -> Bool {
        guard let n = number(of: id) else { return false }
        guard let first else { return blocks.path != nil }   // nothing minted yet: every id predates this incarnation
        return n < first
    }
}
