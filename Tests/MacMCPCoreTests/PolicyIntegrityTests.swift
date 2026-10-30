import Foundation
import Testing
@testable import MacMCPCore

/// The login keychain's stand-in: records, each in an item a build made, which a test can delete, damage or make
/// unreadable (a locked keychain). As in the real one, a build deletes the items it made without anything shown, and
/// macOS would ask a person to let it delete another's: only an interactive delete does, and each is counted.
final class MemoryKeychain: ApprovalKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(stored: StoredApproval, build: String)] = []
    private var failure: String?
    private var readFailure: String?
    private var writeFailure: String?
    private var addCount = 0
    private var readCount = 0
    private var promptCount = 0
    private var readLag: TimeInterval = 0
    private var writeLag: TimeInterval = 0
    private var currentBuild = "build 1"
    private var readHook: (@Sendable () -> Void)?
    private var addHook: (@Sendable () -> Void)?
    private var addFinished: (@Sendable () -> Void)?
    private var addTimeout: TimeInterval?
    private var heldUpOverride: KeychainCall?
    private let addThread = KeychainThread()

    var place: String { "the test keychain" }

    /// The newest record's bytes, whether or not it can be read. Setting it replaces every record with that one, in the
    /// item from before 0.1.1, as something outside MacMCP might; nil deletes them all.
    var record: Data? {
        get { lock.withLock { let l = ApprovalLedger(items.map(\.stored)); return (l.damagedNewest?.stored ?? l.entries.last?.stored)?.data } }
        set {
            lock.withLock {
                items = newValue.map { [(StoredApproval(account: ApprovalLedger.legacyAccount, data: $0, modified: Date()), "outside")] } ?? []
            }
        }
    }
    /// Every record's account.
    var accounts: [String] { lock.withLock { items.map(\.stored.account) } }
    var ledger: ApprovalLedger { lock.withLock { ApprovalLedger(items.map(\.stored)) } }
    /// Which build adds records and deletes them: a rebuild is a stranger to the items earlier builds made.
    var build: String {
        get { lock.withLock { currentBuild } }
        set { lock.withLock { currentBuild = newValue } }
    }
    /// While set, reads are `.unreadable` and writes throw.
    var failing: String? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    /// While set, adds work but the current ledger can't be read for comparison.
    var rejectingReads: String? {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }
    /// While set, reads work but writes throw.
    var rejectingWrites: String? {
        get { lock.withLock { writeFailure } }
        set { lock.withLock { writeFailure = newValue } }
    }
    /// Records added.
    var writes: Int { lock.withLock { addCount } }
    var reads: Int { lock.withLock { readCount } }
    /// How many times macOS would have asked a person something.
    var prompts: Int { lock.withLock { promptCount } }
    /// How long each read and write takes, as one the keychain holds up does.
    var readDelay: TimeInterval {
        get { lock.withLock { readLag } }
        set { lock.withLock { readLag = newValue } }
    }
    var writeDelay: TimeInterval {
        get { lock.withLock { writeLag } }
        set { lock.withLock { writeLag = newValue } }
    }
    /// A call macOS holds up: an add that timed out and hasn't returned, unless a test says otherwise.
    var heldUp: KeychainCall? {
        get { lock.withLock { heldUpOverride } ?? addThread.heldUp() }
        set { lock.withLock { heldUpOverride = newValue } }
    }
    /// The approved policy in the newest record, as text.
    var approvedPolicy: String? {
        record.flatMap { try? ApprovalRecord.decode($0).get() }.map { String(decoding: $0.policy, as: UTF8.self) }
    }

    /// Adds a record nobody can read after all the others, as the integration test does.
    @discardableResult func damage(_ bytes: String = "garbage") -> String {
        lock.withLock {
            let account = ApprovalLedger.account(sequence: ApprovalLedger(items.map(\.stored)).nextSequence)
            items.append((StoredApproval(account: account, data: Data(bytes.utf8), modified: Date()), "outside"))
            return account
        }
    }

    func read(interactive: Bool) -> KeychainRead {
        let (lag, hook) = lock.withLock {
            readCount += 1
            defer { readHook = nil }
            return (readLag, readHook)
        }
        hook?()
        if lag > 0 { Thread.sleep(forTimeInterval: lag) }
        return lock.withLock { (failure ?? readFailure).map { .unreadable($0) } ?? .found(items.map(\.stored)) }
    }

    func beforeNextRead(_ hook: @escaping @Sendable () -> Void) { lock.withLock { readHook = hook } }

    /// Pauses one writer after it has read and compared its candidate, before its append.
    func beforeNextAdd(_ hook: @escaping @Sendable () -> Void) { lock.withLock { addHook = hook } }

    /// Models a Security call that completes after its caller has given up, retaining the transaction meanwhile.
    func timeOutNextAdd(before: @escaping @Sendable () -> Void, finished: @escaping @Sendable () -> Void) {
        lock.withLock { addHook = before; addFinished = finished; addTimeout = 0.05 }
    }

    func add(_ record: Data, sequence: Int, interactive: Bool, holding transaction: ApprovalTransaction?) throws -> String {
        let (hook, finished, timeout) = lock.withLock {
            defer { addHook = nil; addFinished = nil; addTimeout = nil }
            return (addHook, addFinished, addTimeout)
        }
        guard let result = addThread.run(interactive: interactive, timeout: timeout, {
            withExtendedLifetime(transaction) { () -> Result<String, KeychainFailure> in
                defer { finished?() }
                hook?()
                if case let lag = self.writeDelay, lag > 0 { Thread.sleep(forTimeInterval: lag) }
                return self.lock.withLock {
                    if let why = self.failure ?? self.writeFailure { return .failure(KeychainFailure(why)) }
                    let account = ApprovalLedger.account(sequence: sequence)
                    self.items.append((StoredApproval(account: account, data: record, modified: Date()), self.currentBuild))
                    self.addCount += 1
                    return .success(account)
                }
            }
        }) else { throw KeychainFailure(KeychainThread.unanswered) }
        return try result.get()
    }

    func delete(_ accounts: [String], interactive: Bool) -> [String] {
        lock.withLock {
            guard failure == nil else { return accounts }
            return accounts.filter { account in
                guard let i = items.firstIndex(where: { $0.stored.account == account }) else { return false }
                if items[i].build != currentBuild {
                    guard interactive else { return true }
                    promptCount += 1
                }
                items.remove(at: i)
                return false
            }
        }
    }
}

/// A policy.json, readable approved copy, keychain and managed policy in a temporary folder and in memory, never the
/// real ones.
struct PolicySandbox {
    let dir: String
    let keychain = MemoryKeychain()
    let locations: PolicyStore.Locations

    init() throws {
        dir = NSTemporaryDirectory() + "policy-integrity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/managed", withIntermediateDirectories: true)
        chmod(dir + "/managed", 0o755)
        chmod(dir, 0o755)
        var places = PolicyStore.Locations(user: dir + "/policy.json", approved: dir + "/support/policy.approved.json",
                          managed: dir + "/managed/policy.json", keychain: keychain, managedOwner: getuid())
        places.managedRoot = dir
        locations = places
    }

    /// A store that reads the keychain on every call, as a fresh agent would.
    func store(writes: Bool = true, report: @escaping @Sendable (String, Policy) -> Void = { _, _ in }) -> PolicyStore {
        PolicyStore(locations: locations, writes: writes, recheck: 0, report: report)
    }

    /// Replaces the file (a new inode each time, as editors that save safely do).
    func write(_ json: String, to path: String? = nil) throws {
        let path = path ?? locations.user
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
    func contents(_ path: String) -> String? { FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }
    func cleanUp() { remove(dir) }
}

final class PolicyReports: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var all: [String] { lock.withLock { messages } }
    func add(_ m: String) { lock.withLock { messages.append(m) } }
}

@Suite struct PolicyStoreTests {
    @Test func firstRunApprovesWhatIsThere() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.bank.app"]}"#)
        let status = box.store().status()
        #expect(status.source == .user && status.pending.isEmpty && status.problems.isEmpty)
        #expect(try status.enforced.get().denyApps == ["com.bank.app"])
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": ["com.bank.app"]}"#)
        #expect(status.approval?.by == "MacMCP's first run")
        // The readable copy follows the keychain.
        #expect(box.contents(box.locations.approved) == #"{"deny_apps": ["com.bank.app"]}"#)
        let mode = try FileManager.default.attributesOfItem(atPath: box.locations.approved)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func noFileAtAllMeansTheDefaultsAsTheBaseline() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        let status = box.store().status()
        #expect(status.source == .defaults)
        #expect(try status.enforced.get() == .defaults)
        #expect(box.keychain.approvedPolicy.map { Data($0.utf8) } == Policy.encodedDefaults)
        // A file written later that drops a default deny entry is a loosening, not a fresh start.
        try box.write(#"{"deny_apps": []}"#)
        let later = box.store().status()
        #expect(later.source == .approved && later.pending.first?.key == "deny_apps")
    }

    @Test func tighteningAppliesAtOnceAndIsRecordedAsApproved() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = PolicyStore(locations: box.locations)
        _ = store.status()
        try box.write(#"{"deny_apps": ["a", "b"], "clipboard_read": false}"#)
        let status = store.status()
        #expect(status.source == .user && status.pending.isEmpty)
        #expect(try status.enforced.get().denyApps == ["a", "b"])
        #expect(box.keychain.approvedPolicy?.contains("\"b\"") == true)
        #expect(status.approval?.by.contains("tightened") == true)
        #expect(box.contents(box.locations.approved)?.contains("\"b\"") == true)
        // Going back to the old file now loosens what's recorded.
        try box.write(#"{"deny_apps": ["a"]}"#)
        #expect(box.store().status().pending.first?.key == "deny_apps")
    }

    @Test func looseningWaitsForAPersonAndIsReportedOnce() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.apple.Terminal", "com.bank.app"]}"#)
        let reports = PolicyReports()
        let store = PolicyStore(locations: box.locations) { message, _ in reports.add(message) }
        _ = store.status()
        try box.write(#"{"deny_apps": ["com.bank.app"], "script": {"allowed_apps": ["Finder"]}}"#)
        let status = store.status()
        #expect(status.source == .approved)
        #expect(status.inForce.contains("kept in the test keychain"))
        #expect(try status.enforced.get().denyApps == ["com.apple.Terminal", "com.bank.app"])
        #expect(status.pending.map(\.key) == ["deny_apps", "script.allowed_apps"])
        #expect(status.pendingMessage?.contains("mac-mcp policy approve") == true)
        #expect(store.refusalReference.contains("mac-mcp policy approve"))
        let reported = reports.all.count   // the first baseline's notice (it drops default denies), then this
        #expect(reports.all.last?.contains("no longer lists com.apple.Terminal") == true, "\(reports.all)")
        _ = store.status()
        #expect(reports.all.count == reported)
        // The person approves it in Terminal; from then on the file is in force.
        let approval = try PolicyStore.approve(box.locations)
        #expect(approval.loosenings.map(\.key) == ["deny_apps", "script.allowed_apps"])
        #expect(box.keychain.approvedPolicy?.contains("com.apple.Terminal") == false)
        let after = store.status()
        #expect(after.source == .user && after.pending.isEmpty)
        #expect(try after.enforced.get().denyApps == ["com.bank.app"])
        #expect(after.approval?.by == "`mac-mcp policy approve`")
        #expect(!store.refusalReference.contains("approve"))
    }

    @Test func aMissingFileKeepsTheApprovedPolicyNotTheDefaults() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"allow_apps": ["Finder"]}"#)
        let store = PolicyStore(locations: box.locations)
        _ = store.status()
        box.remove(box.locations.user)
        let status = store.status()
        #expect(status.source == .approved)
        #expect(try status.enforced.get().allowApps == ["Finder"])
        #expect(status.problems.contains { $0.contains("is missing") })
        // A fresh agent (no memory of the file) gets the same answer from the keychain.
        #expect(try box.store().status().enforced.get().allowApps == ["Finder"])
    }

    @Test func anInvalidFileBlocksButKeepsTheApprovedWebhook() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"alert_webhook": "https://ntfy.example/topic"}"#)
        let store = PolicyStore(locations: box.locations)
        _ = store.status()
        try box.write("{ nope")
        let status = store.status()
        guard case let .failure(e) = status.enforced else { Issue.record("an invalid file was accepted"); return }
        #expect(e.description.hasPrefix("POLICY INVALID"))
        #expect(status.policy.alertWebhook == "https://ntfy.example/topic")   // alerts still reach the person
    }

    /// Records that go missing, or a newest one that goes bad, while the agent runs leave the policy it read in force,
    /// and a person is told to approve it again. The agent puts nothing back, and changes and deletes nothing.
    @Test func aRecordDeletedOrDamagedWhileRunningKeepsWhatTheAgentRead() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.apple.Terminal"]}"#)
        let store = box.store()
        _ = store.status()
        let first = try #require(box.keychain.record)
        box.keychain.record = nil
        try box.write(#"{"deny_apps": []}"#)
        let deleted = store.status()
        #expect(deleted.source == .approved && deleted.pending.first?.key == "deny_apps")
        #expect(try deleted.enforced.get().denyApps == ["com.apple.Terminal"])
        #expect(deleted.problems.contains { $0.contains("deleted outside MacMCP") && $0.contains("mac-mcp policy approve") })
        #expect(box.keychain.record == nil && box.keychain.writes == 1)
        box.keychain.record = first
        _ = store.status()
        let garbage = box.keychain.damage()
        let damaged = store.status()
        #expect(try damaged.enforced.get().denyApps == ["com.apple.Terminal"] && damaged.pending.first?.key == "deny_apps")
        #expect(damaged.problems.contains { $0.contains("newest record of the approved policy") && $0.contains("is damaged")
            && $0.contains("mac-mcp policy approve") })
        #expect(box.keychain.accounts == [ApprovalLedger.legacyAccount, garbage] && box.keychain.writes == 1 && box.keychain.prompts == 0)
    }

    /// An evaluation that waits on the keychain longer than the recheck interval still stands for the calls right
    /// after it, rather than being redone at once.
    @Test func aSlowEvaluationIsNotStaleAtOnce() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.apple.Terminal"]}"#)
        let store = PolicyStore(locations: box.locations, recheck: 0.5)
        _ = store.status()
        box.keychain.damage()
        box.keychain.readDelay = 0.8
        try box.write(#"{"deny_apps": []}"#)
        #expect(store.status().problems.contains { $0.contains("is damaged") })
        let reads = box.keychain.reads
        box.keychain.readDelay = 0
        #expect(store.status().problems.contains { $0.contains("is damaged") })
        #expect(box.keychain.reads == reads)
    }

    /// An evaluation the keychain holds up doesn't hold up other calls: they wait briefly, then use the status found
    /// before, or block agents if nothing was found yet.
    @Test func aKeychainThatHangsDoesntStallOtherCalls() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        for warm in [true, false] {
            let store = PolicyStore(locations: box.locations, recheck: 0, patience: 0.2)
            if warm { _ = await store.status() }
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let (started, signal) = AsyncStream<Void>.makeStream()
            box.keychain.beforeNextRead {
                signal.yield(); signal.finish()
                _ = gate.wait(timeout: .now() + 30)
            }
            let slow = Task {
                await withCheckedContinuation { continuation in
                    Thread { continuation.resume(returning: store.status()) }.start()
                }
            }
            for await _ in started { break }
            let start = Date()
            let meanwhile = await store.status()
            #expect(Date().timeIntervalSince(start) < 1, "warm: \(warm)")
            if warm {
                #expect(try meanwhile.enforced.get().denyApps == ["a"])
            } else {
                guard case let .failure(e) = meanwhile.enforced else { Issue.record("served a policy nothing vouched for"); return }
                #expect(e.description.contains("still reading its approved policy"))
            }
            gate.signal()
            #expect(try await slow.value.enforced.get().denyApps == ["a"])
        }
    }

    @Test func aDamagedRecordWithNothingToRestoreFailsClosed() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        box.keychain.record = Data("garbage".utf8)
        try box.write(#"{"deny_apps": []}"#)
        guard case let .failure(e) = box.store().status().enforced else {
            Issue.record("a damaged record let a file through"); return
        }
        #expect(e.description.hasPrefix("POLICY BLOCKED") && e.description.contains("mac-mcp policy approve"))
        #expect(box.keychain.record == Data("garbage".utf8))   // not replaced with what policy.json says
    }

    @Test func aRootOwnedManagedPolicyIsUsedAlone() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": []}"#)
        try box.write(#"{"deny_apps": ["com.apple.TextEdit"]}"#, to: box.locations.managed)
        chmod(box.locations.managed, 0o644)
        let status = box.store().status()
        #expect(status.source == .managed, "\(status.problems)")
        #expect(try status.enforced.get().denyApps == ["com.apple.TextEdit"])
        #expect(status.inForce.contains("managed") && status.approvalLine == nil)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations) }
        #expect(box.keychain.record == nil)   // the user's file was never approved behind the managed one

        chmod(box.locations.managed, 0o666)   // writable by others: not trusted, and said so
        let untrusted = box.store().status()
        #expect(untrusted.source != .managed && untrusted.problems.contains { $0.contains("Ignoring the managed policy") })
        var other = box.locations
        other.managedOwner = getuid() &+ 1   // owned by someone other than root
        chmod(box.locations.managed, 0o644)
        #expect(PolicyStore(locations: other, recheck: 0).status().source != .managed)
    }

    @Test func alertsSetupApprovesOnlyItsOwnKey() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.apple.Terminal"]}"#)
        _ = try PolicyStore.approve(box.locations)
        try box.write(#"{"deny_apps": ["com.apple.Terminal"], "alert_webhook": "https://ntfy.example/t"}"#)
        #expect(try PolicyStore.approve(box.locations, onlyKeys: ["alert_webhook"]).loosenings.map(\.key) == ["alert_webhook"])
        try box.write(#"{"deny_apps": [], "alert_webhook": "https://ntfy.example/u"}"#)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations, onlyKeys: ["alert_webhook"]) }
        #expect(box.keychain.approvedPolicy?.contains("com.apple.Terminal") == true)   // unchanged
    }

    @Test func approveRestoresAMissingFileAndRefusesAnInvalidOne() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"allow_apps": ["Finder"]}"#)
        _ = try PolicyStore.approve(box.locations)
        box.remove(box.locations.user)
        let approval = try PolicyStore.approve(box.locations)
        #expect(approval.notes.contains { $0.contains("put it back") } && approval.loosenings.isEmpty)
        #expect(box.contents(box.locations.user) == #"{"allow_apps": ["Finder"]}"#)
        try box.write(#"{"deny_apps": "nope"}"#)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations) }
    }

    @Test func aFirstBaselineLooserThanTheDefaultsIsReported() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": []}"#)
        let reports = PolicyReports()
        let status = box.store { message, _ in reports.add(message) }.status()
        #expect(status.source == .user && status.problems.isEmpty)
        #expect(status.notices.first?.contains("Nothing was approved yet") == true && reports.all.count == 1)
        let quiet = try PolicySandbox()
        defer { quiet.cleanUp() }
        try quiet.write(#"{"clipboard_read": false}"#)
        #expect(quiet.store().status().notices.isEmpty)
    }

    @Test func rawFileReadsAreUnchanged() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        #expect(try Policy.current(path: box.locations.user).get() == .defaults)
        try box.write(#"{"rate_limit_per_second": 3}"#)
        #expect(try Policy.current(path: box.locations.user).get().rateLimitPerSecond == 3)
    }
}

/// The thread keychain calls run on: a call macOS holds up costs its caller the timeout, and later ones nothing.
@Suite struct KeychainThreadTests {
    @Test func aCallThatHangsCostsItsCallerTheTimeoutAndLaterCallsNothing() async throws {
        let thread = KeychainThread()
        let gate = DispatchSemaphore(value: 0)
        var start = Date()
        #expect(thread.run(timeout: 0.2) { gate.wait(); return 1 } == nil)
        #expect(Date().timeIntervalSince(start) < 1)
        start = Date()
        #expect(thread.run(timeout: 5) { 2 } == nil)   // at once, while the first hasn't returned
        #expect(Date().timeIntervalSince(start) < 0.1)
        gate.signal()
        var answer: Int?
        for _ in 0..<100 where answer == nil {
            answer = thread.run(timeout: 1) { 3 }
            if answer == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(answer == 3)
    }
}

@Suite struct PolicyDiffTests {
    private func looser(_ a: String, _ c: String) throws -> [Loosening] {
        let ad = Data(a.utf8), cd = Data(c.utf8)
        return PolicyDiff.loosenings(from: try Policy.decode(ad).get(), to: try Policy.decode(cd).get(),
                                     approvedJSON: PolicyDiff.json(ad), candidateJSON: PolicyDiff.json(cd))
    }

    @Test func everyKnownLooseningIsCaught() throws {
        let cases: [(String, String, String)] = [
            (#"{"deny_apps": ["a", "b"]}"#, #"{"deny_apps": ["a"]}"#, "deny_apps"),
            (#"{"allow_apps": ["Finder"]}"#, #"{"allow_apps": ["Finder", "Safari"]}"#, "allow_apps"),
            (#"{"allow_apps": ["Finder"]}"#, #"{"allow_apps": []}"#, "allow_apps"),
            (#"{}"#, #"{"script": {"allowed_apps": ["Finder"]}}"#, "script.allowed_apps"),
            (#"{}"#, #"{"script": {"jxa": true}}"#, "script.jxa"),
            (#"{}"#, #"{"script": {"timeout_seconds": 300}}"#, "script.timeout_seconds"),
            (#"{"web": {"enabled": false}}"#, #"{"web": {"enabled": true}}"#, "web.enabled"),
            (#"{}"#, #"{"web": {"eval_allowed": true}}"#, "web.eval_allowed"),
            (#"{}"#, #"{"web": {"allow_private_hosts": true}}"#, "web.allow_private_hosts"),
            (#"{"web": {"allow_hosts": ["example.com"]}}"#, #"{"web": {"allow_hosts": ["example.com", "x.org"]}}"#, "web.allow_hosts"),
            (#"{"web": {"allow_hosts": ["example.com"]}}"#, #"{"web": {"allow_hosts": []}}"#, "web.allow_hosts"),
            (#"{}"#, #"{"web": {"allow_hosts": ["192.168.1.1"]}}"#, "web.allow_hosts"),
            (#"{"web": {"deny_hosts": ["bank.com"]}}"#, #"{"web": {"deny_hosts": ["www.bank.com"]}}"#, "web.deny_hosts"),
            (#"{}"#, #"{"shortcuts": {"allowed": ["Resize"]}}"#, "shortcuts.allowed"),
            (#"{}"#, #"{"shortcuts": {"timeout_seconds": 600}}"#, "shortcuts.timeout_seconds"),
            (#"{"clipboard_read": false}"#, #"{"clipboard_read": true}"#, "clipboard_read"),
            (#"{}"#, #"{"rate_limit_per_second": 50}"#, "rate_limit_per_second"),
            (#"{"alert_webhook": "https://ntfy.example/t"}"#, #"{}"#, "alert_webhook"),
            (#"{"alert_webhook": "https://ntfy.example/t"}"#, #"{"alert_webhook": "https://evil.example/t"}"#, "alert_webhook"),
            (#"{}"#, #"{"alert_webhook": "https://evil.example/t"}"#, "alert_webhook"),
            (#"{}"#, #"{"alert_cooldown_minutes": 600}"#, "alert_cooldown_minutes"),
        ]
        for (approved, candidate, key) in cases {
            #expect(try looser(approved, candidate).map(\.key) == [key], "\(approved) → \(candidate)")
        }
    }

    @Test func tighteningAndRewordingAreNotLooser() throws {
        let cases: [(String, String)] = [
            (#"{"deny_apps": ["a"]}"#, #"{"deny_apps": ["a", "b"]}"#),
            (#"{"deny_apps": ["com.apple.Terminal"]}"#, #"{"deny_apps": ["COM.APPLE.TERMINAL"]}"#),
            (#"{"allow_apps": []}"#, #"{"allow_apps": ["Finder"]}"#),
            (#"{"allow_apps": ["Finder", "Safari"]}"#, #"{"allow_apps": ["Finder"]}"#),
            (#"{"script": {"jxa": true, "timeout_seconds": 60}}"#, #"{"script": {"timeout_seconds": 10}}"#),
            (#"{}"#, #"{"web": {"enabled": false, "allow_hosts": ["example.com"]}}"#),
            (#"{"web": {"allow_hosts": ["example.com"]}}"#, #"{"web": {"allow_hosts": ["docs.example.com"]}}"#),
            (#"{"web": {"deny_hosts": ["www.bank.com"]}}"#, #"{"web": {"deny_hosts": ["bank.com"]}}"#),
            (#"{"clipboard_read": true, "rate_limit_per_second": 10}"#, #"{"clipboard_read": false, "rate_limit_per_second": 2}"#),
            (#"{"alert_webhook": "https://ntfy.example/t"}"#, #"{"alert_webhook": "https://ntfy.example/t", "alert_cooldown_minutes": 1}"#),
            (#"{"script": {"allow_system_events": true}}"#, #"{"script": {"allow_system_events": false}}"#),
        ]
        for (approved, candidate) in cases {
            #expect(try looser(approved, candidate).isEmpty, "\(approved) → \(candidate)")
        }
    }

    @Test func allowHostEntriesThatCoverPrivateAddressesAreLooser() throws {
        for entry in ["1.1", "169.254", "local", "home.arpa", "intranet", "fd00::1", "10.0.0.5"] {
            #expect(try looser(#"{}"#, #"{"web": {"allow_hosts": ["\#(entry)"]}}"#).map(\.key) == ["web.allow_hosts"], "\(entry)")
        }
        #expect(try looser(#"{}"#, #"{"web": {"allow_hosts": ["example.com", "docs.example.org"]}}"#).isEmpty)
    }

    @Test func keysThisBuildDoesntKnowStillCount() throws {
        #expect(try looser(#"{}"#, #"{"script": {"allow_system_events": true}}"#).map(\.key) == ["script.allow_system_events"])
        #expect(try looser(#"{"script": {"allow_system_events": false}}"#, #"{"script": {"allow_system_events": true}}"#).count == 1)
        #expect(try looser(#"{"future": {"deny_things": ["a", "b"]}}"#, #"{"future": {"deny_things": ["a"]}}"#).map(\.key) == ["future.deny_things"])
        #expect(try looser(#"{"future": {"allowed_things": ["a"]}}"#, #"{"future": {"allowed_things": ["a", "b"]}}"#).count == 1)
        #expect(try looser(#"{"future": {"wait_timeout": 5}}"#, #"{"future": {"wait_timeout": 50}}"#).count == 1)
        #expect(try looser(#"{"future": {"label": "x"}}"#, #"{"future": {"label": "y"}}"#).isEmpty)
    }

    @Test func webhookChangesNeverShowTheSecretPart() throws {
        let l = try looser(#"{"alert_webhook": "https://ntfy.example/secret-topic"}"#, #"{"alert_webhook": "https://ntfy.example/other-secret"}"#)
        #expect(l.count == 1 && !l[0].description.contains("secret"))
    }
}
