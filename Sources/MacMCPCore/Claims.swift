import Foundation

/// Who may drive a shared resource right now, so two sessions never interleave their tasks: one session's clicks
/// landing in another's half-finished dialog. A session claims a resource with its first acting call and keeps it
/// until it has been idle for `idle` seconds or disconnects. Others wait for it (up to `maxWait`), then get told
/// who holds it. Looking (snapshots, screenshots, lists) never needs a claim.
///
/// Resources: `gui` (synthetic input, apps, windows: there is one keyboard and mouse) and `web` (the one
/// automation Safari behind the web_* tools), so a web session doesn't hold up a GUI session.
public actor Claims {
    public static let shared = Claims()

    public struct Holder: Sendable, Equatable {
        public let session: String
        public let client: String
        public let origin: String?
        public let since: Date
        public internal(set) var lastActive: Date
        /// Calls of this session on the resource still running: a claim never lapses mid-call.
        public internal(set) var running: Int

        public var label: String {
            "\(client) (\(origin ?? "direct socket"), session \(session))"
        }
    }

    public let idle: TimeInterval
    public let maxWait: TimeInterval
    private let now: @Sendable () -> Date
    private let pause: @Sendable () async throws -> Void
    private var admissions: [UUID: Bool] = [:]
    private var holders: [String: Holder] = [:]

    public init(idle: TimeInterval = 60, maxWait: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = { Date() },
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.idle = idle
        self.maxWait = maxWait
        self.now = now
        self.pause = pause
    }

    /// The live holder of `resource`, if any (a lapsed claim is dropped).
    public func holder(_ resource: String, now: Date = Date()) -> Holder? {
        guard let h = holders[resource] else { return nil }
        if h.running == 0, now.timeIntervalSince(h.lastActive) >= idle {
            holders[resource] = nil
            return nil
        }
        return h
    }

    /// Claims `resource` for a call by `session`, or returns the other session holding it. On success the caller
    /// must call `finish` when the call ends.
    public func tryBegin(_ resource: String, session: String, client: String, origin: String?, now: Date = Date()) -> Holder? {
        if let h = holder(resource, now: now), h.session != session { return h }
        var h = holders[resource] ?? Holder(session: session, client: client, origin: origin, since: now, lastActive: now, running: 0)
        h.running += 1
        h.lastActive = now
        holders[resource] = h
        return nil
    }

    /// `tryBegin`, waiting up to `maxWait` for another session's claim to lapse or be released.
    public func begin(_ resource: String, session: String, client: String, origin: String?) async -> Holder? {
        let deadline = Date().addingTimeInterval(maxWait)
        while true {
            guard let other = tryBegin(resource, session: session, client: client, origin: origin) else { return nil }
            if Date() >= deadline || Task.isCancelled { return other }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    public struct Admission: Sendable {
        fileprivate let id: UUID
        fileprivate let resource: String
        fileprivate let session: String
        fileprivate let client: String
        fileprivate let origin: String?
        fileprivate let token: String?
        fileprivate let leasePath: String
    }

    /// Lease ownership and claims are checked together on every attempt. A blocked claimant holds no lease guard,
    /// so a lease acquired while it waits is observed on the next attempt.
    public func admit(_ resource: String, session: String, client: String, origin: String?, token: String?,
                      leasePath: String = LeaseStore.defaultPath) async throws -> Admission {
        let end = now().addingTimeInterval(maxWait)
        while true {
            try Task.checkCancellation()
            let (admission, other) = try await attempt(resource, session: session, client: client, origin: origin,
                                                       token: token, leasePath: leasePath)
            if let admission { return admission }
            if let other, now() >= end { throw ActionError(refusal(resource, held: other, now: now())) }
            try await pause()
        }
    }

    private func attempt(_ resource: String, session: String, client: String, origin: String?, token: String?,
                         leasePath: String) async throws -> (Admission?, Holder?) {
        let guardLease = try await LeaseStore.admit(path: leasePath)
        defer { guardLease.release() }
        let lease = await guardLease.current()
        try Task.checkCancellation()
        if let lease, lease.token != token { throw ActionError(LeaseStore.refusal(for: lease)) }
        let claimed = lease == nil
        if claimed, let other = tryBegin(resource, session: session, client: client, origin: origin, now: now()) {
            return (nil, other)
        }
        let admission = Admission(id: UUID(), resource: resource, session: session, client: client, origin: origin,
                                  token: token, leasePath: leasePath)
        admissions[admission.id] = claimed
        return (admission, nil)
    }

    /// Called immediately before execution, including after waiting for the action lock. A released/expired lease
    /// loses its bypass and must acquire a current claim. A disconnected or cancelled call cannot reclaim resources.
    public func recheck(_ admission: Admission) async throws {
        let guardLease = try await LeaseStore.admit(path: admission.leasePath)
        defer { guardLease.release() }
        let lease = await guardLease.current()
        try Task.checkCancellation()
        guard let claimed = admissions[admission.id] else { throw CancellationError() }
        if let lease {
            guard lease.token == admission.token else { throw ActionError(LeaseStore.refusal(for: lease)) }
        } else if !claimed {
            if let other = tryBegin(admission.resource, session: admission.session, client: admission.client,
                                    origin: admission.origin, now: now()) {
                throw ActionError(refusal(admission.resource, held: other, now: now()))
            }
            admissions[admission.id] = true
        } else if holder(admission.resource, now: now())?.session != admission.session {
            throw ActionError("The resource claim ended before this call could execute; retry.")
        }
    }

    public func finish(_ admission: Admission) {
        if admissions.removeValue(forKey: admission.id) == true { finish(admission.resource, session: admission.session, now: now()) }
    }

    /// A call that began with `tryBegin`/`begin` ended; the claim's idle clock starts now.
    public func finish(_ resource: String, session: String, now: Date = Date()) {
        guard var h = holders[resource], h.session == session else { return }
        h.running = max(0, h.running - 1)
        h.lastActive = now
        holders[resource] = h
    }

    /// The session disconnected: everything it held is free at once.
    public func release(session: String) {
        holders = holders.filter { $0.value.session != session }
    }

    /// Every live claim, for mac_doctor.
    public func all(now: Date = Date()) -> [(resource: String, holder: Holder)] {
        holders.keys.sorted().compactMap { r in holder(r, now: now).map { (r, $0) } }
    }

    /// The refusal for a call that couldn't get the resource.
    public func refusal(_ resource: String, held other: Holder, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let what = resource == "web" ? "The automation Safari (web_* tools)" : "The GUI"
        let last = other.running > 0 ? "acting right now" : "last acted \(Int(now.timeIntervalSince(other.lastActive))) s ago"
        return "\(what) is in use by another session: \(other.label), since \(f.string(from: other.since)), \(last). "
            + "Waited \(Int(maxWait)) s. Its claim lapses after \(Int(idle)) s without actions or when it disconnects; "
            + "try again then. Looking (mac_snapshot, mac_screenshot, lists) works meanwhile."
    }
}
