import CryptoKit
import Foundation

/// One way a policy is looser than the approved one: `deny_apps: no longer lists com.apple.Terminal`.
public struct Loosening: Sendable, Equatable, CustomStringConvertible {
    public let key: String
    public let change: String

    public init(_ key: String, _ change: String) {
        self.key = key
        self.change = change
    }

    public var description: String { "\(key): \(change)" }
}

/// What makes one policy looser than another. policy.json is an ordinary file that apps an agent drives (TextEdit,
/// Finder) can rewrite, so a change that gives agents more reach only takes effect once a person approves it.
public enum PolicyDiff {
    /// Every way `candidate` gives agents more than `approved`. The raw JSON of both, when given, covers keys this
    /// build doesn't model: a boolean turning on, a timeout or limit going up, an allow list growing or a deny list
    /// shrinking all count as looser, so a newer key can't be used to slip a loosening past an older check.
    public static func loosenings(from approved: Policy, to candidate: Policy,
                                  approvedJSON: Any? = nil, candidateJSON: Any? = nil) -> [Loosening] {
        let a = approved, c = candidate
        var out: [Loosening] = []
        func list(_ l: [String]) -> String { l.joined(separator: ", ") }
        func turnedOn(_ key: String, _ old: Bool, _ new: Bool) { if !old && new { out.append(Loosening(key, "turned on")) } }
        func raised<T: Comparable>(_ key: String, _ old: T, _ new: T) {
            if new > old { out.append(Loosening(key, "raised from \(old) to \(new)")) }
        }

        let undenied = added(c.denyApps, to: a.denyApps, key: { Policy.appKey($0, trimmingWhitespace: true) })
        if !undenied.isEmpty { out.append(Loosening("deny_apps", "no longer lists \(list(undenied))")) }
        if !a.allowApps.isEmpty {
            if c.allowApps.isEmpty { out.append(Loosening("allow_apps", "emptied, which allows every app not denied")) }
            else if case let more = added(a.allowApps, to: c.allowApps, key: { Policy.appKey($0, trimmingWhitespace: true) }), !more.isEmpty {
                out.append(Loosening("allow_apps", "adds \(list(more))"))
            }
        }

        let scripted = added(a.script.allowedApps, to: c.script.allowedApps, key: { Policy.appKey($0) })
        if !scripted.isEmpty { out.append(Loosening("script.allowed_apps", "adds \(list(scripted))")) }
        turnedOn("script.jxa", a.script.jxa, c.script.jxa)
        turnedOn("script.allow_system_events", a.script.allowSystemEvents, c.script.allowSystemEvents)
        raised("script.timeout_seconds", a.script.timeoutSeconds, c.script.timeoutSeconds)

        turnedOn("web.enabled", a.web.enabled, c.web.enabled)
        turnedOn("web.eval_allowed", a.web.evalAllowed, c.web.evalAllowed)
        turnedOn("web.allow_private_hosts", a.web.allowPrivateHosts, c.web.allowPrivateHosts)
        typealias Web = Policy.WebPolicy
        let newHosts = c.web.allowHosts.filter { !Web.covers(a.web.allowHosts, host: Web.normalizedHost($0)) }
        if !a.web.allowHosts.isEmpty {
            if c.web.allowHosts.isEmpty { out.append(Loosening("web.allow_hosts", "emptied, which allows every host not denied")) }
            else if !newHosts.isEmpty { out.append(Loosening("web.allow_hosts", "adds \(list(newHosts))")) }
        } else if !a.web.allowPrivateHosts {
            // With no allow list every public host is open already, but an entry also opens a private address.
            let privateHosts = newHosts.filter { reachesPrivateHosts(Web.normalizedHost($0)) }
            if !privateHosts.isEmpty { out.append(Loosening("web.allow_hosts", "adds private-network \(list(privateHosts))")) }
        }
        let undeniedHosts = a.web.denyHosts.filter { e in
            let host = Web.normalizedHost(e)
            return !host.isEmpty && !Web.covers(c.web.denyHosts, host: host)
        }
        if !undeniedHosts.isEmpty { out.append(Loosening("web.deny_hosts", "no longer covers \(list(undeniedHosts))")) }

        let shortcuts = added(a.shortcuts.allowed, to: c.shortcuts.allowed, key: Policy.ShortcutsPolicy.matchingKey)
        if !shortcuts.isEmpty { out.append(Loosening("shortcuts.allowed", "adds \(list(shortcuts))")) }
        raised("shortcuts.timeout_seconds", a.shortcuts.timeoutSeconds, c.shortcuts.timeoutSeconds)

        turnedOn("clipboard_read", a.clipboardRead, c.clipboardRead)
        raised("rate_limit_per_second", a.rateLimitPerSecond, c.rateLimitPerSecond)
        if a.alertWebhook != c.alertWebhook {
            // Only hosts: webhook URLs often carry a secret topic or token.
            let host = c.alertWebhook.flatMap { URL(string: $0)?.host } ?? "?"
            out.append(Loosening("alert_webhook", c.alertWebhook == nil ? "removed, so nobody is alerted"
                : a.alertWebhook == nil ? "added (alerts would go to \(host))" : "changed (alerts would go to \(host))"))
        }
        raised("alert_cooldown_minutes", a.alertCooldownMinutes, c.alertCooldownMinutes)

        if approvedJSON != nil || candidateJSON != nil { out += unmodelled(approvedJSON, candidateJSON, path: "") }
        return out
    }

    /// Whether an allow_hosts entry can match a private address: one itself, or a suffix that covers some ("1.1" covers
    /// 192.168.1.1, "local" covers printer.local), since entries match their subdomains.
    static func reachesPrivateHosts(_ entry: String) -> Bool {
        Policy.WebPolicy.isPrivate(host: entry) || Policy.WebPolicy.isPrivate(host: "x." + entry) || !entry.contains(".")
            || entry.allSatisfy { $0.isNumber || $0 == "." } || entry.contains(":")
    }

    /// Entries enforcement can match now that it couldn't before. Unknown keys preserve whitespace too.
    static func added(_ old: [String], to new: [String], key: (String) -> String = { $0 }) -> [String] {
        let known = Set(old.map(key))
        var seen = Set<String>()
        return new.filter { let k = key($0); return !known.contains(k) && seen.insert(k).inserted }
    }

    /// Keys the comparison above already understands.
    static let modelled: Set<String> = [
        "deny_apps", "allow_apps", "script.allowed_apps", "script.timeout_seconds", "script.jxa", "script.allow_system_events", "web.enabled",
        "web.eval_allowed", "web.deny_hosts", "web.allow_hosts", "web.allow_private_hosts", "shortcuts.allowed",
        "shortcuts.timeout_seconds", "clipboard_read", "rate_limit_per_second", "alert_webhook", "alert_cooldown_minutes",
    ]

    /// Looser changes to keys this build doesn't model, judged by their JSON type and name.
    static func unmodelled(_ a: Any?, _ c: Any?, path: String) -> [Loosening] {
        if a is [String: Any] || c is [String: Any] {
            let ad = a as? [String: Any] ?? [:], cd = c as? [String: Any] ?? [:]
            return Set(ad.keys).union(cd.keys).sorted().flatMap { key in
                unmodelled(ad[key], cd[key], path: path.isEmpty ? key : path + "." + key)
            }
        }
        guard !modelled.contains(path) else { return [] }
        let leaf = (path.split(separator: ".").last.map(String.init) ?? path).lowercased()
        if let new = bool(c) {
            return new && bool(a) != true ? [Loosening(path, "turned on")] : []
        }
        if let new = number(c), leaf.contains("timeout") || leaf.contains("limit") || leaf.hasPrefix("max") {
            // Absent before means an unknown default: setting one at all counts as raising it.
            guard let old = number(a) else { return [Loosening(path, "set to \(new)")] }
            return new > old ? [Loosening(path, "raised from \(old) to \(new)")] : []
        }
        let oldList = (a as? [Any])?.compactMap { $0 as? String } ?? [], newList = (c as? [Any])?.compactMap { $0 as? String } ?? []
        if leaf.hasPrefix("allow") {
            // Whether an empty list means "none" or "any" isn't known here, so emptying one counts too.
            if !oldList.isEmpty, newList.isEmpty { return [Loosening(path, "emptied")] }
            let more = added(oldList, to: newList)
            return more.isEmpty ? [] : [Loosening(path, "adds \(more.joined(separator: ", "))")]
        }
        if leaf.hasPrefix("deny") || leaf.hasPrefix("block") {
            let fewer = added(newList, to: oldList)
            return fewer.isEmpty ? [] : [Loosening(path, "no longer lists \(fewer.joined(separator: ", "))")]
        }
        return []
    }

    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }
}

/// Which policy is in force and why.
public struct PolicyStatus: Sendable {
    public enum Source: String, Sendable {
        /// /Library/Application Support/MacMCP/policy.json, root-owned: the user's file is ignored.
        case managed
        /// ~/.config/mac-mcp/policy.json, as approved.
        case user
        /// The approved policy kept in the login keychain, because policy.json is missing or has changes waiting for
        /// approval (or because it can't be read, which blocks agents).
        case approved
        /// Nothing written yet.
        case defaults
    }

    /// What every check enforces. A failure blocks agents until a person fixes the file.
    public let enforced: Result<Policy, Policy.LoadError>
    public let source: Source
    /// Changes in policy.json that would loosen the approved policy; they wait for `mac-mcp policy approve`.
    public let pending: [Loosening]
    /// What a person should know about or fix: a missing or invalid file, an ignored managed policy.
    public let problems: [String]
    /// Worth telling a person once, but not wrong: the file approved as the first baseline loosens the defaults.
    public var notices: [String] = []
    /// For non-gating reads while `enforced` is a failure: the last approved policy, else the defaults.
    public let fallback: Policy
    /// Where `enforced` came from: a file, or the keychain.
    public let file: String
    /// When and how the approved policy was recorded; nil under a managed policy, or when it can't be read.
    public var approval: ApprovalRecord?

    public var policy: Policy { (try? enforced.get()) ?? fallback }

    /// One line on what's in force, for mac_doctor and `mac-mcp policy status`.
    public var inForce: String {
        switch source {
        case .managed: "the managed policy, \(file) (the user's policy.json is ignored)"
        case .user: "\(file), as approved"
        case .approved: "the last approved policy, kept in \(file)"
        case .defaults: "the built-in defaults (no policy.json yet)"
        }
    }

    /// When the approved policy was recorded and by what, for mac_doctor and `mac-mcp policy status`.
    public var approvalLine: String? {
        guard source != .managed, let approval else { return nil }
        let when = ISO8601DateFormatter.string(from: approval.approvedAt, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
        return "approved \(when) by \(approval.by); kept in your login keychain, where the apps agents drive can't change it"
    }

    /// What to tell a person about pending changes: what they are and how to apply them.
    public var pendingMessage: String? {
        guard !pending.isEmpty else { return nil }
        return "\(Paths.policyFile) has changes that would loosen the policy (\(pending.map(\.description).joined(separator: "; "))). "
            + "MacMCP keeps enforcing the last approved policy until a person runs `mac-mcp policy approve` in Terminal."
    }

    /// The alert for this state, or nil when nothing needs a person.
    var alertMessage: String? {
        let parts = [pendingMessage].compactMap { $0 } + problems + notices
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Decides which policy is in force (`Policy.current()`), keeping policy.json from being loosened by anything but a
/// person.
///
/// - A managed policy whose file and directory chain are exclusively root-controlled is used alone.
/// - Otherwise the approved policy is the one recorded in the login keychain, which no app an agent drives can
///   change. policy.json is compared with it each time either changes. If nothing in the file is looser, it applies
///   and is recorded as the approved policy. If anything is looser, the approved policy stays in force, the change is
///   logged and alerted, and refusals and mac_doctor say a person must run `mac-mcp policy approve`.
/// - A tightening the keychain didn't take stays in force, and is written again at each evaluation. Meanwhile the
///   record still in the keychain is older than it, and replaces it only if it is no looser or a person approved it
///   later, so putting policy.json back can't undo the tightening.
/// - A missing policy.json leaves the approved policy in force; an invalid one blocks agents, as it always has (the
///   edit may have been meant to tighten it). Neither ever falls back to the built-in defaults once a policy exists.
/// - The first run (nothing approved yet) approves the current file, or the defaults, as the baseline. Until that
///   baseline is in the keychain, agents are blocked, so a later edit can't become the baseline after a restart. Once
///   a policy has been approved, records that are missing, a newest one that is damaged, or a keychain that can't be
///   read keep the policy this agent read before in force, or block agents if it read none, until a person runs
///   `mac-mcp policy approve`; they are never replaced by whatever policy.json says. `policy.approved.json` beside the
///   agent is a readable copy, never consulted; its presence only shows that a policy was approved here before.
/// - Each record is a new keychain item (`ApprovalLedger`). The agent only ever adds them, the first baseline and
///   tightenings, and never changes or deletes one, which for an item another build made macOS would ask a person
///   about. It never puts back a missing or damaged record either: a person does, with `mac-mcp policy approve`, which
///   also deletes the records it replaces.
/// - While another process holds the approval lock (a person's `mac-mcp policy approve` at a keychain prompt, or an
///   add macOS holds up), policy.json is still compared with the approved policy read before: tightenings apply in
///   memory and are recorded once the lock is free, loosenings wait.
/// - Evaluations run on a thread of their own, one at a time, never on Swift's cooperative pool, and each keychain call
///   gives up after a few seconds (`KeychainThread`), so a keychain that holds a call up can't stall tool calls. Calls
///   that come meanwhile await the evaluation briefly, without holding a thread, then use the status found before.
public final class PolicyStore: @unchecked Sendable {
    public struct Locations: Sendable {
        public var user: String
        /// The readable copy of the approved policy. Rewritten from the keychain; never trusted.
        public var approved: String
        /// Beside the readable copy, in the protected support directory; never removed while processes may use it.
        public var approvalLock: String { (approved as NSString).deletingLastPathComponent + "/policy-approval.lock" }
        public var managed: String
        /// Where the approved policy really is: the login keychain, or an in-memory stand-in in tests.
        public var keychain: any ApprovalKeychain
        /// Who must own the managed policy and every ancestor: root, except in tests.
        public var managedOwner: uid_t
        /// Tests can confine ownership checks to their sandbox; production always checks through /.
        var managedRoot = "/"

        public init(user: String, approved: String, managed: String, keychain: any ApprovalKeychain, managedOwner: uid_t = 0) {
            self.user = user
            self.approved = approved
            self.managed = managed
            self.keychain = keychain
            self.managedOwner = managedOwner
        }

        public static var standard: Locations {
            Locations(user: Paths.policyFile, approved: Paths.approvedPolicyFile, managed: Paths.managedPolicyFile,
                      keychain: LoginKeychainApproval())
        }
    }

    /// The agent and the CLI keep the approved policy up to date and alert; other processes (tests) only read.
    public static let shared: PolicyStore = {
        let agent = Bundle.main.bundleIdentifier == Paths.bundleID
        let cli = ProcessInfo.processInfo.processName == "mac-mcp"
        let quiet: @Sendable (String, Policy) -> Void = { _, _ in }
        return PolicyStore(locations: .standard, writes: agent || cli, report: agent ? logAndAlert : quiet)
    }()

    /// Logs to agent.log and alerts through the policy's webhook (with the policy in force, so a broken or loosened
    /// file can't silence it).
    public static let logAndAlert: @Sendable (String, Policy) -> Void = { message, policy in
        log("policy: " + message)
        Task { await Alerts.shared.notify(.policy, message, policy: policy) }
    }

    let locations: Locations
    private let writes: Bool
    /// How long a status stands when no file has changed. `mac-mcp policy approve` also rewrites the readable copy,
    /// which is noticed at once, so this only bounds how long a change to the keychain alone goes unnoticed.
    private let recheck: TimeInterval
    private let report: @Sendable (String, Policy) -> Void
    /// How long a call waits for another call's evaluation before it uses the status found before. Evaluations take
    /// milliseconds, unless the keychain holds one up.
    private let patience: TimeInterval
    /// Guards `cached`, `evaluating`, `waiters` and `reported`. The rest is only touched by the one evaluation running.
    private let lock = NSLock()
    private var cached: (stamps: [FileStamp], at: Date, status: PolicyStatus)?
    /// When the evaluation now running started; nil while none is.
    private var evaluating: Date?
    /// Calls waiting for the evaluation now running, each with the files as it found them.
    private var waiters: [Waiter] = []
    private typealias Waiter = (id: Int, stamps: [FileStamp], deliver: @Sendable (PolicyStatus) -> Void)
    private var nextWaiter = 0
    /// Where evaluations run: they read files and wait on the keychain, which no Swift concurrency thread may.
    private let worker = DedicatedThreads(name: "policy")
    /// Times out waiting calls; shared, since its jobs only hand over a status.
    private static let timers = DedicatedThreads(name: "policy-wait")
    /// The approved policy as last read or recorded: kept in force while the keychain can't be read (locked), or its
    /// records go missing or bad while the agent runs.
    private var knownApproved: ApprovalRecord?
    /// Whether `knownApproved` is a tightening the keychain didn't take. The keychain then holds an older record.
    private var unsaved = false
    /// One more than every sequence read in the current approval transaction. Both writers hold the same file lock.
    private var nextSequence = 1
    /// The last message reported, so each state is logged and alerted once rather than on every call.
    private var reported: String?
    private var wroteCopy = false

    public init(locations: Locations, writes: Bool = true, recheck: TimeInterval = 10, patience: TimeInterval = 2,
                report: @escaping @Sendable (String, Policy) -> Void = { _, _ in }) {
        self.locations = locations
        self.writes = writes
        self.recheck = recheck
        self.patience = patience
        self.report = report
    }

    /// The policy in force. Re-evaluated when one of the files changes, and every `recheck` seconds for the keychain.
    /// The evaluation runs on a thread of its own; callers that come meanwhile wait for it without holding a thread,
    /// and after `patience` use the status found before.
    public func status() async -> PolicyStatus {
        let stamps = fileStamps()
        return await withCheckedContinuation { continuation in
            request(stamps) { continuation.resume(returning: $0) }
        }
    }

    /// The same for synchronous code, which blocks its thread meanwhile: the CLI, and dedicated threads. Swift
    /// concurrency code awaits the other.
    public func status() -> PolicyStatus {
        let reply = Reply()
        request(fileStamps()) { reply.set($0) }
        // Evaluations give up on the keychain after a few seconds each, so this only bounds a bug.
        _ = reply.done.wait(timeout: .now() + 60) // lint:allow-blocking synchronous callers only (CLI, dedicated threads)
        return reply.value ?? lastStatus ?? stillReading()
    }

    /// For non-gating reads in synchronous code (timeouts, the alert webhook): the status found last, at once, with a
    /// fresh evaluation started in the background if it's stale. Only the very first call waits for one.
    public func recentStatus() -> PolicyStatus {
        guard let last = lastStatus else { return status() }
        request(fileStamps(), waiting: false) { _ in }
        return last
    }

    private final class Reply: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: PolicyStatus?
        var value: PolicyStatus? { lock.withLock { result } }
        func set(_ status: PolicyStatus) { lock.withLock { result = status }; done.signal() }
    }

    /// Hands `deliver` the status for files stamped `stamps`: the cached one while it stands, else the result of the
    /// evaluation running or one started now. `deliver` must return at once. Without `waiting`, a call that finds an
    /// evaluation running is handed the status found before.
    private func request(_ stamps: [FileStamp], waiting: Bool = true, _ deliver: @escaping @Sendable (PolicyStatus) -> Void) {
        lock.lock()
        if let started = evaluating {
            guard waiting else {
                let status = cached?.status ?? stillReading()
                lock.unlock()
                return deliver(status)
            }
            // Normally it's done in milliseconds; one the keychain holds up mustn't hold up this call too.
            let id = nextWaiter
            nextWaiter += 1
            waiters.append((id, stamps, deliver))
            lock.unlock()
            Self.timers.async(after: max(0, started.addingTimeInterval(patience).timeIntervalSinceNow)) { [weak self] in
                guard let self else { return }
                let late = self.lock.withLock { () -> PolicyStatus? in
                    guard let i = self.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    self.waiters.remove(at: i)
                    return self.cached?.status ?? self.stillReading()
                }
                if let late { deliver(late) }
            }
            return
        }
        if let cached, cached.stamps == stamps, Date().timeIntervalSince(cached.at) < recheck {
            lock.unlock()
            return deliver(cached.status)
        }
        evaluating = Date()
        lock.unlock()
        worker.async { self.evaluateNow(stamps, deliver) }
    }

    /// Runs on `worker`, one at a time.
    private func evaluateNow(_ read: [FileStamp], _ deliver: @escaping @Sendable (PolicyStatus) -> Void) {
        var stamps = read
        wroteCopy = false
        let status = evaluate()
        if wroteCopy { stamps[1] = FileStamp(locations.approved) }   // our own write isn't a change to react to
        let message = status.alertMessage
        let (fresh, woken) = lock.withLock { () -> (String?, [Waiter]) in
            // Timed from the end: an evaluation that waited on the keychain would otherwise be stale at once, and the
            // next call would evaluate again.
            cached = (stamps, Date(), status)
            evaluating = nil
            defer { reported = message; waiters = [] }
            return (message != reported ? message : nil, waiters)
        }
        // Logged before anyone acts on it.
        if let fresh { report(fresh, status.policy) }
        deliver(status)
        // A call that found the files changed again since this evaluation read them asks again.
        for waiter in woken {
            if waiter.stamps == read || waiter.stamps == stamps { waiter.deliver(status) }
            else { request(waiter.stamps, waiter.deliver) }
        }
    }

    /// For a call that comes while the first evaluation waits on the keychain: nothing has vouched for a policy yet.
    private func stillReading() -> PolicyStatus {
        let e = Policy.LoadError.blocked("MacMCP is still reading its approved policy from \(locations.keychain.place).")
        return PolicyStatus(enforced: .failure(e), source: .approved, pending: [], problems: [e.description],
                            fallback: .defaults, file: locations.keychain.place)
    }

    /// A keychain call this process made that macOS is holding up, for mac_doctor.
    public var heldUpKeychainCall: KeychainCall? { locations.keychain.heldUp }

    /// The last evaluated status, without reading any file (for refusal text, which must not do I/O).
    public var lastStatus: PolicyStatus? { lock.withLock { cached?.status } }

    /// The policy file to name in a refusal.
    public var refusalReference: String {
        guard let s = lastStatus else { return locations.user }
        let file = s.source == .managed ? locations.managed : locations.user
        return s.pending.isEmpty ? file
            : file + "; it has changes that would loosen it, which apply only once a person runs `mac-mcp policy approve` in Terminal"
    }

    private func fileStamps() -> [FileStamp] {
        var paths = [locations.user, locations.approved, locations.managed]
        var directory = (locations.managed as NSString).deletingLastPathComponent
        while true {
            paths.append(directory)
            if directory == locations.managedRoot || directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return paths.map(FileStamp.init)
    }

    private func evaluate() -> PolicyStatus {
        var problems: [String] = [], notices: [String] = []
        let place = locations.keychain.place
        func status(_ enforced: Result<Policy, Policy.LoadError>, _ source: PolicyStatus.Source, _ file: String,
                    pending: [Loosening] = [], approval: ApprovalRecord? = nil, fallback: Policy) -> PolicyStatus {
            // An unrecorded tightening can be noted both before and after policy.json is read.
            var seen = Set<String>()
            let problems = problems.filter { seen.insert($0).inserted }
            return PolicyStatus(enforced: enforced, source: source, pending: pending, problems: problems, notices: notices,
                                fallback: fallback, file: file, approval: approval)
        }
        func blocked(_ why: String) -> PolicyStatus {
            let e = Policy.LoadError.blocked(why)
            problems.append(e.description)
            return status(.failure(e), .approved, place, fallback: .defaults)
        }

        switch Self.readManaged(locations) {
        case .absent: break
        case let .untrusted(why):
            problems.append("Ignoring the managed policy \(locations.managed): \(why). Make the file and every ancestor "
                + "root-owned and not writable by others, including ACLs, or remove it.")
        case let .trusted(data):
            switch Policy.decode(data) {
            case let .success(p): return status(.success(p), .managed, locations.managed, fallback: p)
            case let .failure(f):
                let e = Policy.LoadError.invalid(locations.managed, f.why)
                problems.append(e.description)
                return status(.failure(e), .managed, locations.managed, fallback: .defaults)
            }
        }

        // The approved policy is the newest keychain record. A copy this agent read earlier stands in for records that
        // went missing or bad while it ran; with none, a record that should exist blocks agents rather than letting
        // policy.json become the new baseline. Nothing here puts a record back: only a person does, by approving.
        var approved: (policy: Policy, record: ApprovalRecord)?
        // An append needs a readable ledger to choose its sequence and prove it doesn't loosen the current record.
        var appendFailure: String?
        let known = knownApproved.flatMap { k in (try? Policy.decode(k.policy).get()).map { (policy: $0, record: k) } }

        var transaction: ApprovalTransaction?
        var busy = false
        do { transaction = writes ? try ApprovalTransaction(path: locations.approvalLock) : nil } catch {
            // A person's `policy approve` waiting at a keychain prompt, say. policy.json is still compared with the
            // policy read before, as when the keychain can't be read: tightenings apply in memory, and are recorded
            // once the lock is free; loosenings wait.
            busy = true
            appendFailure = "\(error)"
            guard let known else { return blocked("MacMCP couldn't start an approval transaction (\(error)).") }
            approved = known
            notices.append("MacMCP couldn't start an approval transaction (\(error)), so it keeps comparing \(locations.user) "
                + "with the approved policy it read before, and tries again at the next policy evaluation.")
            // Alerted from about a minute on, as the keychain thread alerts it too; mac_doctor shows it sooner.
            if let call = locations.keychain.heldUp, -call.since.timeIntervalSinceNow >= KeychainThread.alertAfter {
                problems.append(call.message)
            }
            if unsaved { problems.append(unsavedProblem("\(error)")) }
        }
        defer { withExtendedLifetime(transaction) {} }

        func keepKnown(_ why: String) {
            // A tightening the keychain didn't take is recorded as a new record, as any tightening is.
            if unsaved, let known { saveApproved(known.record, &problems, transaction: transaction, unavailable: appendFailure) }
            else { problems.append(why + " A person should run `mac-mcp policy approve` in Terminal to record it again.") }
        }
        switch busy ? nil : Self.readApproved(locations.keychain) {
        case nil: break
        case let .valid(record, p, ledger):
            nextSequence = ledger.nextSequence
            if let notice = Self.ignored(ledger, place) { notices.append(notice) }
            if unsaved, let known, record != known.record, !Self.supersedes(record, p, known) {
                // The record from before a tightening the keychain didn't take: the tightening stays, and is written
                // again.
                guard PolicyDiff.loosenings(from: p, to: known.policy, approvedJSON: PolicyDiff.json(record.policy),
                                             candidateJSON: PolicyDiff.json(known.record.policy)).isEmpty else {
                    return blocked("The unrecorded tightening conflicts with the newest approved policy; a person must run "
                        + "`mac-mcp policy approve` in Terminal.")
                }
                approved = known
                saveApproved(known.record, &problems, transaction: transaction, unavailable: appendFailure)
            } else {
                approved = (p, record)
                knownApproved = record
                unsaved = false
                keepCopy(record.policy)
            }
        case let .unreadable(why):
            appendFailure = why
            guard let known else { return blocked("MacMCP can't read its approved policy from \(place) (\(why)).") }
            approved = known
            notices.append("MacMCP can't read its approved policy from \(place) (\(why)), so it keeps enforcing the one it "
                + "read before.")
            if unsaved { problems.append(unsavedProblem(why)) }
        case let .damaged(why, ledger):
            appendFailure = "the newest approval record is damaged (\(why))"
            nextSequence = ledger.nextSequence
            guard let known else { return blocked("MacMCP's approved policy in \(place) is damaged (\(why)).") }
            approved = known
            keepKnown("The newest record of the approved policy in \(place) is damaged (\(why)), so MacMCP keeps enforcing "
                + "the one it read before.")
        case .missing:
            nextSequence = 1
            if let known {
                appendFailure = "the approved policy was deleted outside MacMCP"
                approved = known
                keepKnown("The approved policy in \(place) was deleted outside MacMCP, so MacMCP keeps enforcing the one it "
                    + "read before.")
            } else if FileManager.default.fileExists(atPath: locations.approved) {
                return blocked("A policy was approved on this Mac before, but the approved policy in \(place) is missing.")
            }
        }

        switch Policy.read(path: locations.user) {
        case .missing:
            if let approved {
                problems.append("\(locations.user) is missing, so MacMCP keeps enforcing the last approved policy. "
                    + "`mac-mcp policy approve` puts the file back from it.")
                return status(.success(approved.policy), .approved, place, approval: approved.record, fallback: approved.policy)
            }
            // The baseline any later file is compared with. Until it's recorded, a later file could become it instead.
            let first = ApprovalRecord(policy: Policy.encodedDefaults, by: "MacMCP's first run (the built-in defaults)",
                                       sequence: nextSequence)
            if let why = persist(first, transaction: transaction) { return blocked(firstRunUnrecorded("the built-in defaults", why)) }
            knownApproved = first
            return status(.success(.defaults), .defaults, locations.user, approval: first, fallback: .defaults)
        case let .invalid(e):
            // Blocked, as before: the edit may have been meant to tighten it, so the old policy isn't a safe stand-in.
            problems.append(e.description)
            return status(.failure(e), .user, locations.user, approval: approved?.record, fallback: approved?.policy ?? .defaults)
        case let .valid(p, data):
            guard let approved else {
                let first = ApprovalRecord(policy: data, by: "MacMCP's first run", sequence: nextSequence)
                // First run: what's there now is the baseline.
                if let why = persist(first, transaction: transaction) { return blocked(firstRunUnrecorded(locations.user, why)) }
                knownApproved = first
                // Normal after installing; worth a person's look if they expected an approval to exist.
                let beyondDefaults = PolicyDiff.loosenings(from: .defaults, to: p)
                if !beyondDefaults.isEmpty {
                    notices.append("Nothing was approved yet, so MacMCP approved \(locations.user) as it is. It loosens the "
                        + "defaults (\(beyondDefaults.map(\.description).joined(separator: "; "))); if you didn't expect "
                        + "that, check the file and run `mac-mcp policy status`.")
                }
                return status(.success(p), .user, locations.user, approval: first, fallback: p)
            }
            let looser = PolicyDiff.loosenings(from: approved.policy, to: p, approvedJSON: PolicyDiff.json(approved.record.policy),
                                               candidateJSON: PolicyDiff.json(data))
            guard looser.isEmpty else {
                return status(.success(approved.policy), .approved, place, pending: looser, approval: approved.record,
                              fallback: approved.policy)
            }
            var record = approved.record
            if data != record.policy {
                record = ApprovalRecord(policy: data, by: "MacMCP, applying an edit that tightened it",
                                        sequence: nextSequence)
                saveApproved(record, &problems, transaction: transaction, unavailable: appendFailure)
            }
            return status(.success(p), .user, locations.user, approval: record, fallback: p)
        }
    }

    /// Records `record` as the approved policy: in the keychain, then the readable copy. It applies either way. One
    /// the keychain didn't take is kept in memory and written again at each evaluation, but a restart before then would
    /// forget it, so that's reported.
    private func saveApproved(_ record: ApprovalRecord, _ problems: inout [String], transaction: ApprovalTransaction?,
                              unavailable: String?) {
        var record = record
        // The ledger was read and the candidate compared while holding the transaction lock.
        record.sequence = nextSequence
        knownApproved = record
        unsaved = false
        if let why = unavailable ?? persist(record, transaction: transaction) {
            unsaved = true
            problems.append(unsavedProblem(why))
        }
    }

    /// Adds `record` to the keychain as a new record, then writes the readable copy; why it couldn't, or nil.
    private func persist(_ record: ApprovalRecord, transaction: ApprovalTransaction?) -> String? {
        guard writes else { return nil }
        do { try locations.keychain.add(record.encoded, sequence: record.sequence, interactive: false, holding: transaction) }
        catch { return "\(error)" }
        nextSequence = record.sequence + 1
        keepCopy(record.policy)
        return nil
    }

    /// What to say about records older than the one in force that can't be read, or nil if there are none.
    static func ignored(_ ledger: ApprovalLedger, _ place: String) -> String? {
        guard let first = ledger.damaged.first else { return nil }
        let one = ledger.damaged.count == 1
        return "MacMCP ignores \(one ? "a record" : "\(ledger.damaged.count) records") in \(place) that it can't read "
            + "(\(first.why)), older than the approved policy in force; `mac-mcp policy prune` deletes \(one ? "it" : "them")."
    }

    private func unsavedProblem(_ why: String) -> String {
        "Could not record the approved policy in \(locations.keychain.place): \(why). MacMCP enforces it and tries again "
            + "each time it reads the policy, but would forget it if the agent restarted first; a person should run "
            + "`mac-mcp policy approve` in Terminal to record it."
    }

    private func firstRunUnrecorded(_ what: String, _ why: String) -> String {
        "Nothing was approved yet, and MacMCP couldn't record \(what) as the first approved policy in "
            + "\(locations.keychain.place) (\(why)). It tries again each time it reads the policy."
    }

    /// Whether the keychain's `record` replaces `known`, a tightening the keychain didn't take: only if it is no looser,
    /// or a person's record comes after that tightening (`ApprovalRecord.isNewer`, including equal-sequence ties).
    /// Anything else is the older record that tightening replaced.
    static func supersedes(_ record: ApprovalRecord, _ policy: Policy, _ known: (policy: Policy, record: ApprovalRecord)) -> Bool {
        if record.byPerson && record.isNewer(than: known.record) { return true }
        return PolicyDiff.loosenings(from: known.policy, to: policy, approvedJSON: PolicyDiff.json(known.record.policy),
                                     candidateJSON: PolicyDiff.json(record.policy)).isEmpty
    }

    /// Keeps the readable copy equal to the approved policy. Nothing reads it back.
    private func keepCopy(_ data: Data) {
        guard writes, FileManager.default.contents(atPath: locations.approved) != data else { return }
        if (try? Self.writeCopy(data, to: locations.approved)) != nil { wroteCopy = true }
    }

    static func writeCopy(_ data: Data, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LeaseStore.writePrivately(data, to: path)
    }

    enum ApprovedRead {
        /// The newest record.
        case valid(ApprovalRecord, Policy, ApprovalLedger)
        /// No records at all.
        case missing
        /// The newest record isn't one of a valid policy this build understands, so what was approved last isn't known.
        case damaged(String, ApprovalLedger)
        /// The keychain refused or failed.
        case unreadable(String)
    }

    static func readApproved(_ keychain: any ApprovalKeychain, interactive: Bool = false) -> ApprovedRead {
        switch keychain.ledger(interactive: interactive) {
        case let .failure(f): return .unreadable(f.description)
        case let .success(ledger):
            if let newest = ledger.inForce { return .valid(newest.record, newest.policy, ledger) }
            if let damaged = ledger.damagedNewest { return .damaged(damaged.why, ledger) }
            return .missing
        }
    }

    // MARK: Managed policy

    enum ManagedTrust: Equatable { case absent, untrusted(String), trusted }

    enum ManagedRead { case absent, untrusted(String), trusted(Data) }

    static func managedTrust(_ l: Locations) -> ManagedTrust {
        switch readManaged(l) {
        case .absent: .absent
        case let .untrusted(why): .untrusted(why)
        case .trusted: .trusted
        }
    }

    /// Walk from a trusted directory descriptor, refusing symlinks and checking every ancestor's mode and ACL.
    /// The checked file descriptor is also the one read, so replacement cannot switch in unchecked bytes.
    static func readManaged(_ l: Locations, beforeRead: () throws -> Void = {}) -> ManagedRead {
        var exists = stat()
        guard lstat(l.managed, &exists) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .untrusted("it can't be inspected")
        }
        let root = l.managedRoot
        guard root == "/" || l.managed.hasPrefix(root + "/") else { return .untrusted("invalid trust root") }
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .untrusted("its root directory can't be opened without following links") }
        defer { close(fd) }
        if let why = managedDescriptorRefusal(fd, owner: l.managedOwner, directory: true) { return .untrusted(root + ": " + why) }
        let relative = root == "/" ? l.managed : String(l.managed.dropFirst(root.count))
        let components = relative.split(separator: "/").map(String.init)
        for (index, name) in components.enumerated() {
            guard name != ".", name != ".." else { return .untrusted("its path contains dot components") }
            let directory = index < components.count - 1
            let next = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
            guard next >= 0 else { return .untrusted("\(name) can't be opened without following links") }
            close(fd)
            fd = next
            if let why = managedDescriptorRefusal(fd, owner: l.managedOwner, directory: directory) { return .untrusted(name + ": " + why) }
        }
        do {
            try beforeRead()
            return .trusted(try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data())
        } catch { return .untrusted("the checked file can't be read: \(error)") }
    }

    static func managedDescriptorRefusal(_ fd: Int32, owner: uid_t, directory: Bool) -> String? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return "its metadata can't be read" }
        guard st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { return "it isn't a \(directory ? "directory" : "regular file")" }
        guard st.st_uid == owner else { return "it is owned by uid \(st.st_uid), not root" }
        guard st.st_mode & 0o022 == 0 else { return "it is writable by group or others" }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // An open descriptor still exists: ENOENT here means it has no extended ACL.
            return errno == ENOENT ? nil : "its ACL can't be read (\(String(cString: strerror(errno))))"
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return "its ACL is invalid" }
        var entry: acl_entry_t?
        var cursor = ACL_FIRST_ENTRY
        let rights = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
                      ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        while true {
            let result = acl_get_entry(acl, Int32(cursor.rawValue), &entry)
            if result == -1, errno == EINVAL { return nil } // Darwin uses EINVAL for the end of a valid ACL.
            guard result == 0, let entry else { return "its ACL entries can't be read" }
            cursor = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0, let permissions else {
                return "its ACL permissions can't be read"
            }
            if tag != ACL_EXTENDED_ALLOW { continue }
            var grantsWrite = false
            for right in rights {
                let has = acl_get_perm_np(permissions, right)
                guard has >= 0 else { return "its ACL rights can't be read" }
                grantsWrite = grantsWrite || has == 1
            }
            if !grantsWrite { continue }
            // Root already has owner access; rejecting all write-granting ACEs avoids identity/group ambiguity.
            return "its ACL grants write, delete or add rights"
        }
    }

    // MARK: Approval (a person, in Terminal)

    /// Lowercase hex, as `shasum -a 256` prints it.
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public struct Approval: Sendable {
        /// What the approved file loosens compared with the policy it replaces.
        public let loosenings: [Loosening]
        public let notes: [String]
    }

    public enum ApprovalError: Error, CustomStringConvertible {
        case managed(String)
        case invalid(String)
        /// `onlyKeys` was given and other loosening changes are waiting too.
        case otherChanges([Loosening])
        /// `onlyKeys` was given, but there's no approved policy to tell the other changes apart with.
        case noBaseline(String)
        /// The keychain didn't take the new record.
        case keychain(String)
        /// Another approval transaction holds the lock: who, since when, and what to do.
        case busy(String)
        /// `expectSHA256` was given and policy.json doesn't hash to it, or is missing.
        case unexpectedFile(String)
        /// `prune`: the newest record can't be read, so which one is in force isn't known.
        case damaged(String)

        public var description: String {
            switch self {
            case let .managed(path):
                "A managed policy is in force (\(path)), so ~/.config/mac-mcp/policy.json is ignored. Edit the managed "
                    + "file with sudo instead."
            case let .invalid(why): why
            case let .otherChanges(l):
                "policy.json has other changes that would loosen it (\(l.map(\.description).joined(separator: "; "))); "
                    + "review them, then run `mac-mcp policy approve`."
            case let .noBaseline(why):
                "\(why), so MacMCP can't tell which changes in policy.json are new. Review the file, then run "
                    + "`mac-mcp policy approve`."
            case let .keychain(why):
                "Could not record the approval in your login keychain: \(why). Unlock the keychain (or allow MacMCP if "
                    + "macOS asks) and run it again."
            case let .busy(why):
                "Nothing was approved: \(why)."
            case let .unexpectedFile(why):
                "Nothing was approved: \(why). Something may have changed it since; review it before approving."
            case let .damaged(why):
                "\(why), so it isn't known which record is in force. Run `mac-mcp policy approve` first: it records the "
                    + "approved policy again."
            }
        }
    }

    /// `mac-mcp policy approve`: validates policy.json and records it as the approved policy, in the login keychain,
    /// returning how it loosens the policy it replaces. A missing policy.json is put back from the approved policy
    /// (or the defaults). With `onlyKeys`, approves only if every loosening is to one of those keys (a person's
    /// `mac-mcp alerts setup` mustn't approve whatever else an agent wrote to the file). With `expectSHA256`, approves
    /// only if policy.json's bytes have that SHA-256 (hex), so a script that wrote the file approves what it wrote and
    /// not an edit made after it; a missing file is then refused, not put back. A person runs this in Terminal, so
    /// macOS may ask them to unlock the keychain.
    ///
    /// The approval is a new record, after every one in the keychain. The records it replaces are deleted, except those
    /// another build of MacMCP made: macOS would ask for the keychain password to delete them, so they stay, ignored,
    /// until `mac-mcp policy prune`, and a note says how many.
    public static func approve(_ l: Locations = .standard, onlyKeys: Set<String>? = nil, expectSHA256: String? = nil,
                               by: String = "`mac-mcp policy approve`") throws -> Approval {
        if managedTrust(l) == .trusted { throw ApprovalError.managed(l.managed) }
        var transaction: ApprovalTransaction?
        do { transaction = try ApprovalTransaction(path: l.approvalLock) }
        catch let busy as ApprovalTransaction.Busy { throw ApprovalError.busy(busy.description) }
        catch { throw ApprovalError.keychain("\(error)") }
        defer { withExtendedLifetime(transaction) {} }
        var notes: [String] = []
        let place = l.keychain.place
        var approved: (policy: Policy, data: Data)?
        var ledger: ApprovalLedger?   // what's there; nil if nothing is
        var lost: String?   // why the approved policy, which should be there, can't be compared with
        switch readApproved(l.keychain, interactive: true) {
        case let .valid(record, p, read):
            approved = (p, record.policy)
            ledger = read
        case .missing:
            if FileManager.default.fileExists(atPath: l.approved) { lost = "The approved policy in \(place) is missing" }
            else { notes.append("Nothing was approved yet; this is the first approval.") }
        case let .damaged(why, read):
            lost = "The approved policy in \(place) is damaged (\(why))"
            ledger = read
        case let .unreadable(why):
            // Without the records, there's no telling what a new one must come after.
            throw ApprovalError.keychain("its records can't be read (\(why))")
        }
        if let lost {
            if onlyKeys != nil { throw ApprovalError.noBaseline(lost) }
            notes.append(lost + "; this replaces it.")
        }
        let data: Data
        switch Policy.read(path: l.user) {
        case let .invalid(e): throw ApprovalError.invalid(e.description)
        case let .valid(_, d):
            if let expected = expectSHA256?.lowercased(), case let actual = sha256(d), actual != expected {
                throw ApprovalError.unexpectedFile("\(l.user) has SHA-256 \(actual), not \(expected)")
            }
            data = d
        case .missing:
            if expectSHA256 != nil { throw ApprovalError.unexpectedFile("\(l.user) is missing") }
            if let approved {
                data = approved.data
                notes.append("\(l.user) was missing: put it back from the approved policy.")
            } else {
                data = Policy.encodedDefaults
                notes.append("\(l.user) was missing: wrote the default policy.")
            }
            try FileManager.default.createDirectory(atPath: (l.user as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: URL(fileURLWithPath: l.user), options: .atomic)
        }
        let candidate: Policy
        switch Policy.decode(data) {
        case let .success(p): candidate = p
        case let .failure(f): throw ApprovalError.invalid("\(l.user) is invalid: \(f.why)")
        }
        var looser: [Loosening] = []
        if let approved {
            looser = PolicyDiff.loosenings(from: approved.policy, to: candidate, approvedJSON: PolicyDiff.json(approved.data),
                                           candidateJSON: PolicyDiff.json(data))
        } else if case let beyond = PolicyDiff.loosenings(from: .defaults, to: candidate), !beyond.isEmpty {
            notes.append("Compared with the built-in defaults, it loosens: \(beyond.map(\.description).joined(separator: "; ")).")
        }
        if let onlyKeys, case let others = looser.filter({ !onlyKeys.contains($0.key) }), !others.isEmpty {
            throw ApprovalError.otherChanges(others)
        }
        let record = ApprovalRecord(policy: data, by: by, byPerson: true, sequence: ledger?.nextSequence ?? 1)
        do { try l.keychain.add(record.encoded, sequence: record.sequence, interactive: true, holding: transaction) } catch {
            throw ApprovalError.keychain("\(error)")
        }
        transaction = nil
        do { try writeCopy(data, to: l.approved) } catch { notes.append("Could not update the readable copy \(l.approved): \(error).") }
        if let older = ledger?.accounts, case let kept = l.keychain.delete(older, interactive: false), !kept.isEmpty {
            notes.append(keptNote(kept.count, place))
        }
        return Approval(loosenings: looser, notes: notes)
    }

    static func keptNote(_ count: Int, _ place: String) -> String {
        let one = count == 1
        return "\(one ? "An older record" : "\(count) older records") of the approved policy \(one ? "stays" : "stay") in \(place), "
            + "ignored: another build of MacMCP (or another program) made \(one ? "it" : "them"), and macOS asks for your "
            + "login keychain password to delete \(one ? "it" : "them"). `mac-mcp policy prune` does."
    }

    public struct Pruned: Sendable {
        public let deleted: Int
        /// Those still there: macOS asked a person, who said no, or wasn't allowed to ask.
        public let kept: Int
    }

    /// `mac-mcp policy prune`: deletes every record of the approved policy but the one in force. A person runs it in
    /// Terminal. The records this build can delete go first, without anything shown; for the rest, which other builds
    /// of MacMCP made, `ask` is told how many, and macOS then asks for the keychain password for each. With `ask` nil,
    /// those stay.
    public static func prune(_ l: Locations = .standard, ask: ((Int) -> Void)?) throws -> Pruned {
        try deleteRecords(l, keepingInForce: true, ask: ask)
    }

    /// `mac-mcp uninstall --purge`: deletes every record, so the next install approves policy.json afresh.
    public static func forgetApproval(_ l: Locations = .standard, ask: ((Int) -> Void)?) throws -> Pruned {
        try deleteRecords(l, keepingInForce: false, ask: ask)
    }

    private static func deleteRecords(_ l: Locations, keepingInForce: Bool, ask: ((Int) -> Void)?) throws -> Pruned {
        let ledger: ApprovalLedger
        switch l.keychain.ledger(interactive: true) {
        case let .success(read): ledger = read
        case let .failure(f): throw ApprovalError.keychain("its records can't be read (\(f.description))")
        }
        if keepingInForce, let damaged = ledger.damagedNewest {
            throw ApprovalError.damaged("The newest record of the approved policy in \(l.keychain.place) is damaged (\(damaged.why))")
        }
        let keep = keepingInForce ? ledger.inForce?.stored.account : nil
        let old = ledger.accounts.filter { $0 != keep }
        var kept = l.keychain.delete(old, interactive: false)
        if !kept.isEmpty, let ask {
            ask(kept.count)
            kept = l.keychain.delete(kept, interactive: true)
        }
        return Pruned(deleted: old.count - kept.count, kept: kept.count)
    }
}

/// Enough of a file's identity to notice any change to it: inode, size, and modification and change times.
struct FileStamp: Equatable {
    var exists = false
    var device: dev_t = 0
    var inode: ino_t = 0
    var size: off_t = 0
    var mode: mode_t = 0
    var owner: uid_t = 0
    var modified = timespec()
    var changed = timespec()

    init(_ path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return }
        exists = true
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
        mode = st.st_mode
        owner = st.st_uid
        modified = st.st_mtimespec
        changed = st.st_ctimespec
    }

    static func == (a: FileStamp, b: FileStamp) -> Bool {
        a.exists == b.exists && a.device == b.device && a.inode == b.inode && a.size == b.size && a.mode == b.mode
            && a.owner == b.owner && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
            && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
}

extension Policy {
    /// The default policy as written to a new policy.json.
    public static var encodedDefaults: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(defaults)) ?? Data("{}".utf8)
    }
}
