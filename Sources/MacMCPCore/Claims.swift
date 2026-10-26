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
    private var holders: [String: Holder] = [:]

    public init(idle: TimeInterval = 60, maxWait: TimeInterval = 30) {
        self.idle = idle
        self.maxWait = maxWait
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
