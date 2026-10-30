import Foundation
import Security

/// The approved policy as MacMCP records it: policy.json's bytes exactly as a person approved them (so keys this build
/// doesn't model still compare), and when and how they were approved.
public struct ApprovalRecord: Codable, Sendable, Equatable {
    /// Bumped when the layout changes. A record from a newer MacMCP isn't trusted by an older one.
    public static let currentFormat = 1

    public var format: Int
    public var policy: Data
    /// When it was recorded, to the millisecond. `approved_at` keeps whole seconds, which is what older builds read.
    public var approvedAt: Date
    /// What recorded it: `mac-mcp policy approve`, `mac-mcp alerts`, the first run, or the agent applying a change
    /// that tightened the policy.
    public var by: String
    /// Whether a person recorded it, in Terminal (`mac-mcp policy approve`, `mac-mcp alerts`), rather than MacMCP on
    /// its own. Only such a record, made later, replaces a tightening the agent holds but couldn't record. Records
    /// from before 0.1.1 lack it and count as MacMCP's own.
    public var byPerson: Bool
    /// One more than the highest sequence read under the transaction lock, so a record made knowing another comes after
    /// it whatever the clocks say. Records from before 0.1.1 lack it and count as 0.
    public var sequence: Int

    enum CodingKeys: String, CodingKey {
        case format, policy, approvedAt = "approved_at", approvedAtMilliseconds = "approved_at_ms", by,
             byPerson = "by_person", sequence
    }

    public init(policy: Data, by: String, byPerson: Bool = false, sequence: Int = 0, approvedAt: Date = Date()) {
        format = Self.currentFormat
        self.policy = policy
        self.approvedAt = Self.date(milliseconds: Self.milliseconds(approvedAt))
        self.by = by
        self.byPerson = byPerson
        self.sequence = sequence
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        policy = try c.decode(Data.self, forKey: .policy)
        approvedAt = try c.decodeIfPresent(Int64.self, forKey: .approvedAtMilliseconds).map(Self.date(milliseconds:))
            ?? c.decode(Date.self, forKey: .approvedAt)
        by = try c.decode(String.self, forKey: .by)
        byPerson = try c.decodeIfPresent(Bool.self, forKey: .byPerson) ?? false
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(policy, forKey: .policy)
        try c.encode(approvedAt, forKey: .approvedAt)
        try c.encode(Self.milliseconds(approvedAt), forKey: .approvedAtMilliseconds)
        try c.encode(by, forKey: .by)
        try c.encode(byPerson, forKey: .byPerson)
        try c.encode(sequence, forKey: .sequence)
    }

    /// Sequence comes first. At equal sequences a person's record wins even after clock rollback, then the
    /// millisecond, then the record's contents (never the random account). Identical records are in no order.
    public func isNewer(than other: ApprovalRecord) -> Bool {
        if order != other.order { return order > other.order }
        if format != other.format { return format > other.format }
        if !by.utf8.elementsEqual(other.by.utf8) { return other.by.utf8.lexicographicallyPrecedes(by.utf8) }
        return other.policy.lexicographicallyPrecedes(policy)
    }

    var order: (Int, Int, Int64) { (sequence, byPerson ? 1 : 0, Self.milliseconds(approvedAt)) }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    public var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    /// The record in `data`, or why it isn't one MacMCP can use.
    public static func decode(_ data: Data) -> Result<ApprovalRecord, Policy.DecodeFailure> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(ApprovalRecord.self, from: data) else {
            return .failure(.init(why: "it isn't an approval record"))
        }
        guard record.format <= currentFormat else {
            return .failure(.init(why: "a newer MacMCP wrote it (format \(record.format))"))
        }
        return .success(record)
    }
}


/// One record of the approved policy as the keychain holds it, in an item of its own.
public struct StoredApproval: Sendable, Equatable {
    /// Names the item: `approval.<sequence>.<random>`, or `approved-policy` for the one item MacMCP kept before 0.1.1.
    public let account: String
    /// The record's bytes: the item's generic attribute.
    public let data: Data
    /// When the keychain last changed the item, to the second. It orders a record that can't be read, and whose account
    /// doesn't say where it comes, against those that can.
    public let modified: Date?

    public init(account: String, data: Data, modified: Date?) {
        self.account = account
        self.data = data
        self.modified = modified
    }
}

public enum KeychainRead: Sendable, Equatable {
    /// Every record, in no particular order: none if nothing was approved yet, or the records were deleted.
    case found([StoredApproval])
    /// Locked, denied or failed: not the same as finding none, which only an approval that was never made is.
    case unreadable(String)
}

public struct KeychainFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Where the approved policy is kept, out of reach of the apps agents drive. The real one is the login keychain
/// (`LoginKeychainApproval`); tests use one in memory.
///
/// Records are only ever added, each in an item of its own, and the newest is the approved policy (`ApprovalLedger`).
/// macOS never asks anyone anything to add an item, but does to change or delete one another build of MacMCP made
/// (see `LoginKeychainApproval`). So the agent only adds records, and only a person deletes old ones.
public protocol ApprovalKeychain: Sendable {
    /// Where the records are, for messages: "your login keychain".
    var place: String { get }
    /// Every record. `interactive`: a person is at Terminal, so macOS may ask them to unlock the keychain; otherwise
    /// nothing is ever shown and a locked keychain is `.unreadable`.
    func read(interactive: Bool) -> KeychainRead
    /// Adds `record` in a new item named for `sequence`, and returns its account. Never changes an item that's there.
    /// Retains `transaction` until the underlying add finishes, including after a timeout returned to its caller.
    @discardableResult func add(_ record: Data, sequence: Int, interactive: Bool,
                                holding transaction: ApprovalTransaction?) throws -> String
    /// Deletes the records with these accounts, and returns those still there. Without `interactive`, only those macOS
    /// lets this build delete without asking anyone go; with it, macOS may ask a person for the keychain password to
    /// delete the others.
    func delete(_ accounts: [String], interactive: Bool) -> [String]
    /// A call macOS is holding up: still running after its caller stopped waiting. While it's an add, it holds the
    /// approval lock.
    var heldUp: KeychainCall? { get }
}

/// One keychain call: what it does, and when it started.
public struct KeychainCall: Sendable, Equatable {
    public let what: String
    public let since: Date

    public init(what: String, since: Date) {
        self.what = what
        self.since = since
    }

    /// What it means and what to do; the same until the call returns, so it's reported once.
    public var message: String {
        "MacMCP's keychain call (\(what)) hasn't returned since \(ApprovalTransaction.Busy.time(since)); macOS may be "
            + "waiting on a person, or be stuck. Until it returns, MacMCP can't record approvals or tightenings (it "
            + "enforces tightenings in memory meanwhile), and `mac-mcp policy approve` and `mac-mcp alerts setup` can't "
            + "run. If it doesn't return, run `mac-mcp restart`."
    }

    /// How long it has been running, for mac_doctor.
    public func duration(now: Date = Date()) -> String { ApprovalTransaction.Busy.duration(now.timeIntervalSince(since)) }
}

extension ApprovalKeychain {
    public var heldUp: KeychainCall? { nil }

    public func read() -> KeychainRead { read(interactive: false) }

    @discardableResult public func add(_ record: Data, sequence: Int, interactive: Bool) throws -> String {
        try add(record, sequence: sequence, interactive: interactive, holding: nil)
    }

    /// The records in order, or why they can't be read.
    public func ledger(interactive: Bool = false) -> Result<ApprovalLedger, KeychainFailure> {
        switch read(interactive: interactive) {
        case let .found(stored): .success(ApprovalLedger(stored))
        case let .unreadable(why): .failure(KeychainFailure(why))
        }
    }
}

/// The records of the approved policy in the order they were made. The newest is the approved policy, unless a record
/// that can't be read (damaged, or from a newer MacMCP) may be newer still: then what was approved last isn't known.
///
/// Records are ordered by sequence, person, millisecond, then contents (`ApprovalRecord.isNewer`). One that can't
/// be read is placed by the sequence in its account or, with none there (the item from before 0.1.1, or one MacMCP
/// didn't make), by when the keychain last changed it. It is ignored if it comes before the newest one that can be
/// read, and taken to be newer if that isn't clear.
public struct ApprovalLedger: Sendable {
    public struct Entry: Sendable {
        public let stored: StoredApproval
        public let record: ApprovalRecord
        public let policy: Policy
    }

    public struct Damaged: Sendable {
        public let stored: StoredApproval
        public let why: String
    }

    /// The account of the one item MacMCP kept before 0.1.1. It is read like any other record, and never written.
    public static let legacyAccount = "approved-policy"

    /// The records that can be read, oldest first.
    public let entries: [Entry]
    /// Those that can't.
    public let damaged: [Damaged]
    /// A record that can't be read and may be newer than every one that can.
    public let damagedNewest: Damaged?
    /// One more than every sequence in the keychain, so a record made now comes after all of them.
    public let nextSequence: Int

    /// The approved policy: the newest record, if it can be read.
    public var inForce: Entry? { damagedNewest == nil ? entries.last : nil }
    public var accounts: [String] { entries.map(\.stored.account) + damaged.map(\.stored.account) }
    public var isEmpty: Bool { entries.isEmpty && damaged.isEmpty }

    public init(_ stored: [StoredApproval]) {
        var entries: [Entry] = [], damaged: [Damaged] = []
        for item in stored {
            switch ApprovalRecord.decode(item.data) {
            case let .failure(f): damaged.append(Damaged(stored: item, why: f.why))
            case let .success(record):
                switch Policy.decode(record.policy) {
                case let .success(p): entries.append(Entry(stored: item, record: record, policy: p))
                case let .failure(f): damaged.append(Damaged(stored: item, why: "the policy in it is invalid: \(f.why)"))
                }
            }
        }
        entries.sort { $1.record.isNewer(than: $0.record) }
        let newest = entries.last
        damagedNewest = damaged.first { d in
            guard let newest else { return true }
            if let sequence = Self.sequence(of: d.stored.account) { return sequence >= newest.record.sequence }
            guard let changed = d.stored.modified, let last = newest.stored.modified else { return true }
            // Modification time is only a fallback for legacy and unrecognized accounts; equality is ambiguous.
            return changed >= last
        }
        nextSequence = max(0, (entries.map(\.record.sequence) + stored.compactMap { Self.sequence(of: $0.account) }).max() ?? 0) + 1
        self.entries = entries
        self.damaged = damaged
    }

    /// The account for a new record: its sequence, and a random part so that two made at once don't collide.
    public static func account(sequence: Int) -> String {
        "approval.\(sequence).\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The sequence an account names; nil for one MacMCP didn't name that way.
    static func sequence(of account: String) -> Int? {
        let parts = account.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "approval" else { return nil }
        return Int(parts[1])
    }
}

/// The approved policy in generic-password items in the login (file-based) keychain, one per record, all under one
/// service. MacMCP has no Team ID, so the data-protection keychain and its access groups are out of reach.
///
/// Without a Team ID, an item's partition list names only the cdhash of the build that created it, so every rebuild
/// is a stranger to the items earlier builds made. macOS asks for the keychain password before a stranger reads an
/// item's secret, changes the item or deletes it, and asks even when the call says no UI may be shown. It asks nothing
/// to read attributes or to add an item. So each record is kept in an item's generic attribute, not its secret (the
/// policy isn't one), records are only ever added, and `delete` without `interactive` looks before it deletes and
/// leaves an item it would be asked about.
///
/// What protects the records is that no app agents may drive can reach them: Keychain Access and Passwords are denied,
/// agents have no shell, and the keychain files are protected paths. Each item's access list trusts MacMCP's agent and
/// CLI, by designated requirement. Like the rest of the legacy keychain, it doesn't stop code that already runs as the
/// user from changing the items, which SECURITY.md leaves out of scope.
public struct LoginKeychainApproval: ApprovalKeychain {
    public let service: String
    /// The binaries each new item's access list trusts: the app bundle and the CLI, plus whichever one adds it.
    public let trusted: [String]

    public var place: String { "your login keychain" }

    public init(service: String = Paths.approvalKeychainService, trusted: [String] = [Paths.app, Paths.cli]) {
        self.service = service
        self.trusted = trusted
    }

    public func read(interactive: Bool) -> KeychainRead {
        let service = service
        guard let (status, stored) = KeychainThread.shared.run(interactive: interactive, what: "reading the approval records", {
            legacy.read(service, interactive: interactive)
        }) else { return .unreadable(KeychainThread.unanswered) }
        switch status {
        case errSecSuccess: return .found(stored)
        case errSecItemNotFound: return .found([])
        default: return .unreadable(Legacy.message(status))
        }
    }

    @discardableResult public func add(_ record: Data, sequence: Int, interactive: Bool,
                                       holding transaction: ApprovalTransaction?) throws -> String {
        let (service, trusted) = (service, trusted)
        for _ in 0..<3 {
            let account = ApprovalLedger.account(sequence: sequence)
            guard let status = KeychainThread.shared.run(interactive: interactive, what: "adding an approval record", {
                withExtendedLifetime(transaction) {
                    legacy.add(service, account, record, trusted: trusted, interactive: interactive)
                }
            }) else { throw KeychainFailure(KeychainThread.unanswered) }
            if status == errSecDuplicateItem { continue }   // the random part collided
            guard status == errSecSuccess else { throw KeychainFailure(Legacy.message(status)) }
            return account
        }
        throw KeychainFailure(Legacy.message(errSecDuplicateItem))
    }

    public func delete(_ accounts: [String], interactive: Bool) -> [String] {
        let service = service
        return accounts.filter { account in
            let status = KeychainThread.shared.run(interactive: interactive, what: "deleting an approval record") {
                legacy.delete(service, account, interactive: interactive)
            }
            return status != errSecSuccess && status != errSecItemNotFound
        }
    }

    public var heldUp: KeychainCall? { KeychainThread.shared.heldUp() }
}

/// Where every call to the login keychain runs: a queue of its own, never the caller's thread. If macOS holds a call
/// up (waiting on a person at a prompt, which MacMCP never means to cause), its caller waits a few seconds at most, and
/// until it returns, later calls fail at once rather than queue behind it. So neither the policy lock nor Swift's
/// cooperative pool ever waits on the keychain without a bound. Callers are synchronous: the policy store's own thread
/// and the CLI. A call still running after `alertAfter` is reported once (`onStuck`), and mac_doctor shows it.
final class KeychainThread: @unchecked Sendable {
    static let shared = KeychainThread(onStuck: KeychainThread.logAndAlert)
    /// Calls take milliseconds; a person at Terminal may take a while to unlock the keychain or answer macOS.
    static let timeout: TimeInterval = 5
    static let interactiveTimeout: TimeInterval = 300
    static let unanswered = "the keychain didn't answer in time (macOS may be waiting on a person)"
    /// When a non-interactive call that hasn't returned is alerted: an add then holds the approval lock.
    static let alertAfter: TimeInterval = 60

    /// Logs, and in the agent alerts through the policy's webhook.
    static let logAndAlert: @Sendable (KeychainCall) -> Void = { call in
        let message = call.message
        log("policy: " + message)
        if ApprovalTransaction.isAgent { Task { await Alerts.shared.notify(.policy, message) } }
    }

    /// Times the calls that are running; shared, since its jobs only look and report.
    private static let watch = DedicatedThreads(name: "keychain-watch")

    private let queue = DedicatedThreads(name: "keychain")
    private let lock = NSLock()
    /// The call that timed out and hasn't returned yet.
    private var stuck: AnyObject?
    /// The call running now, and how long its caller waits for it.
    private var running: (id: Int, started: KeychainCall, patience: TimeInterval)?
    private var calls = 0
    private let alertAfter: TimeInterval
    private let onStuck: @Sendable (KeychainCall) -> Void

    init(alertAfter: TimeInterval = KeychainThread.alertAfter, onStuck: @escaping @Sendable (KeychainCall) -> Void = { _ in }) {
        self.alertAfter = alertAfter
        self.onStuck = onStuck
    }

    private final class Call<T>: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var value: T?   // set under the lock
        var body: (@Sendable () -> T)?   // consumed by the dedicated thread
        init(_ body: @escaping @Sendable () -> T) { self.body = body }
    }

    /// The call running now, if it has outlasted its caller's wait.
    func heldUp(now: Date = Date()) -> KeychainCall? {
        lock.withLock { running.flatMap { now.timeIntervalSince($0.started.since) >= $0.patience ? $0.started : nil } }
    }

    /// `body`'s result, or nil if it didn't return in time or an earlier call that didn't still hasn't. Blocks its
    /// caller, which must not be a Swift concurrency thread.
    func run<T: Sendable>(interactive: Bool = false, timeout: TimeInterval? = nil, what: String = "a keychain call",
                          _ body: @escaping @Sendable () -> T) -> T? {
        let call = Call(body)
        let patience = timeout ?? (interactive ? Self.interactiveTimeout : Self.timeout)
        guard let id = lock.withLock({ () -> Int? in
            guard stuck == nil else { return nil }
            calls += 1
            return calls
        }) else { return nil }
        // The caller holds `self` until it returns; a late call or watch mustn't keep it (and its thread) alive.
        queue.async { [weak self] in
            guard let self else { return }
            let started = KeychainCall(what: what, since: Date())
            self.lock.withLock { self.running = (id, started, patience) }
            // A person at Terminal may rightly take minutes; only the agent's own calls are expected back at once.
            if !interactive {
                Self.watch.async(after: self.alertAfter) { [weak self] in
                    guard let self, self.lock.withLock({ self.running?.id == id }) else { return }
                    self.onStuck(started)
                }
            }
            let value = call.body!()
            // Release the approval transaction captured by the call before waking its synchronous caller.
            call.body = nil
            self.lock.withLock {
                call.value = value
                if self.stuck === call { self.stuck = nil }
                if self.running?.id == id { self.running = nil }
            }
            call.done.signal()
        }
        _ = call.done.wait(timeout: .now() + patience) // lint:allow-blocking bounded; callers are dedicated threads or the CLI
        return lock.withLock {
            if call.value == nil { stuck = call }
            return call.value
        }
    }
}

/// The legacy keychain calls, deprecated since macOS 10.10 but the only ones that work without a Team ID. Callers go
/// through this protocol, so only the implementation below is marked deprecated.
private protocol LegacyKeychain: Sendable {
    func read(_ service: String, interactive: Bool) -> (OSStatus, [StoredApproval])
    func add(_ service: String, _ account: String, _ record: Data, trusted: [String], interactive: Bool) -> OSStatus
    func delete(_ service: String, _ account: String, interactive: Bool) -> OSStatus
}

private let legacy: any LegacyKeychain = Legacy()

/// Each call runs with keychain UI switched on or off for that call alone. The switch is per process, so the calls
/// take turns.
private struct Legacy: LegacyKeychain {
    static let lock = NSLock()

    @available(macOS, deprecated: 10.10)
    func withInteraction<T>(_ allowed: Bool, _ body: () -> T) -> T {
        Self.lock.withLock {
            var was: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&was)
            SecKeychainSetUserInteractionAllowed(allowed)
            defer { SecKeychainSetUserInteractionAllowed(was.boolValue) }
            return body()
        }
    }

    func query(_ service: String, _ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    @available(macOS, deprecated: 10.10)
    func noUI(_ query: [String: Any], _ interactive: Bool) -> [String: Any] {
        var q = query
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return q
    }

    @available(macOS, deprecated: 10.10)
    func read(_ service: String, interactive: Bool) -> (OSStatus, [StoredApproval]) {
        var q = noUI(query(service), interactive)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = withInteraction(interactive) { SecItemCopyMatching(q as CFDictionary, &out) }
        let items = (out as? [[String: Any]] ?? []).map {
            StoredApproval(account: $0[kSecAttrAccount as String] as? String ?? "", data: $0[kSecAttrGeneric as String] as? Data ?? Data(),
                           modified: $0[kSecAttrModificationDate as String] as? Date)
        }
        return (status, items)
    }

    @available(macOS, deprecated: 10.10)
    func add(_ service: String, _ account: String, _ record: Data, trusted: [String], interactive: Bool) -> OSStatus {
        var add = query(service, account)
        add[kSecAttrGeneric as String] = record
        add[kSecAttrLabel as String] = "MacMCP approved policy"
        add[kSecAttrComment as String] = "A policy a person approved with `mac-mcp policy approve`, or MacMCP recorded. MacMCP "
            + "enforces the newest one while ~/.config/mac-mcp/policy.json has changes that loosen it."
        add[kSecValueData as String] = Data()
        if let access = access(trusted) { add[kSecAttrAccess as String] = access }
        return withInteraction(interactive) { SecItemAdd(add as CFDictionary, nil) }
    }

    @available(macOS, deprecated: 10.10)
    func delete(_ service: String, _ account: String, interactive: Bool) -> OSStatus {
        withInteraction(interactive) {
            if !interactive {
                // Look first: macOS would ask for the keychain password to delete an item another build made, even
                // though this call allows no UI.
                var q = noUI(query(service, account), false)
                q[kSecReturnRef as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: CFTypeRef?
                let found = SecItemCopyMatching(q as CFDictionary, &out)
                guard found == errSecSuccess, let out else { return found }
                guard CFGetTypeID(out) == SecKeychainItemGetTypeID(), canDeleteQuietly(out as! SecKeychainItem) else {
                    return errSecInteractionNotAllowed
                }
            }
            return SecItemDelete(noUI(query(service, account), interactive) as CFDictionary)
        }
    }

    /// Whether macOS lets this process delete `item` without asking anyone: the item's partition list names this build,
    /// and its access list trusts this binary. Reading them asks nothing.
    @available(macOS, deprecated: 10.10)
    func canDeleteQuietly(_ item: SecKeychainItem) -> Bool {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return false }
        func entries(_ authorization: CFString) -> [(apps: [SecTrustedApplication]?, description: String)] {
            (SecAccessCopyMatchingACLList(access, authorization) as? [SecACL] ?? []).map { acl in
                var apps: CFArray?, description: CFString?, prompt = SecKeychainPromptSelector()
                SecACLCopyContents(acl, &apps, &description, &prompt)
                return (apps as? [SecTrustedApplication], description as String? ?? "")
            }
        }
        let partitions = entries(kSecACLAuthorizationPartitionID)
        guard !partitions.isEmpty,
              partitions.allSatisfy({ !Self.partitionIDs.isDisjoint(with: Self.partitions(in: $0.description)) }) else { return false }
        let caller = Self.callerPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return entries(kSecACLAuthorizationDecrypt).allSatisfy { entry in
            guard let apps = entry.apps else { return true }   // any application
            return apps.contains { app in
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let path = data as Data? else { return false }
                let trimmed = String(decoding: path, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path == caller
            }
        }
    }

    /// The IDs a partition list matches this process by: its cdhash (MacMCP has no Team ID), or `apple:` for an
    /// Apple-signed one such as the test runner. From the running code, not the file, which a build may have replaced.
    static let partitionIDs: Set<String> = {
        var ids: Set<String> = []
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return ids }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation),
                                         &info) == errSecSuccess, let info = info as? [String: Any] {
            if let cdhash = info[kSecCodeInfoUnique as String] as? Data {
                ids.insert("cdhash:" + cdhash.map { String(format: "%02x", $0) }.joined())
            }
            if let team = info[kSecCodeInfoTeamIdentifier as String] as? String { ids.insert("teamid:" + team) }
        }
        var apple: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &apple) == errSecSuccess, let apple,
           SecCodeCheckValidity(code, [], apple) == errSecSuccess {
            ids.insert("apple:")
        }
        return ids
    }()

    /// The partition IDs in a partition list's description, which is a property list in hex.
    static func partitions(in description: String) -> Set<String> {
        let digits = Array(description.utf8)
        guard digits.count % 2 == 0 else { return [] }
        var bytes = Data()
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else { return [] }
            bytes.append(byte)
        }
        let plist = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any]
        return Set(plist?["Partitions"] as? [String] ?? [])
    }

    /// This process as an access list names it: its app bundle, or the bare executable the CLI is.
    static var callerPath: String? { Bundle.main.bundleIdentifier != nil ? Bundle.main.bundlePath : Bundle.main.executablePath }

    /// An access list naming these binaries, and the one calling, by designated requirement. Paths that don't exist
    /// are left out.
    @available(macOS, deprecated: 10.10)
    func access(_ trusted: [String]) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var seen = Set<String>()
        for path in trusted + [Self.callerPath].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: path) && seen.insert(path).inserted {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate("MacMCP approved policy" as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    static func message(_ status: OSStatus) -> String {
        switch status {
        case errSecInteractionNotAllowed: "the keychain is locked or asked for a person's permission"
        case errSecAuthFailed: "the keychain refused MacMCP access"
        case errSecNoSuchKeychain, errSecNoDefaultKeychain: "there is no login keychain"
        default: (SecCopyErrorMessageString(status, nil) as String?).map { "\($0) (\(status))" } ?? "error \(status)"
        }
    }
}
