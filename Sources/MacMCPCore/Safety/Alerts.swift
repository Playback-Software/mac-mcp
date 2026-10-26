import Foundation

/// Tells a person when agent work is blocked on them: a locked screen, a macOS prompt, a missing permission, an
/// invalid policy. Posts a plain-text body to `alert_webhook` (ntfy.sh-compatible headers), at most once per kind per
/// cooldown. Without a webhook configured, alerts only go to the agent log.
public actor Alerts {
    public static let shared = Alerts()

    public enum Kind: String, Sendable {
        case session, prompt, permission, policy, agent
    }

    private var lastSent: [Kind: Date] = [:]
    private let send: @Sendable (URL, String, Kind) async -> Bool

    public init(send: @escaping @Sendable (URL, String, Kind) async -> Bool = Alerts.post) {
        self.send = send
    }

    /// Returns true if an alert was sent (not throttled, webhook configured and reachable).
    @discardableResult
    public func notify(_ kind: Kind, _ message: String, policy: Policy = Policy.load(), now: Date = Date()) async -> Bool {
        if let last = lastSent[kind], now.timeIntervalSince(last) < Double(policy.alertCooldownMinutes * 60) { return false }
        lastSent[kind] = now   // before the await, so concurrent callers don't all send
        log("alert (\(kind.rawValue)): \(message)")
        guard let raw = policy.alertWebhook, let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" else { return false }
        let sent = await send(url, message, kind)
        if !sent, lastSent[kind] == now { lastSent[kind] = nil }   // undelivered: the next one of this kind tries again
        return sent
    }

    public static let post: @Sendable (URL, String, Kind) async -> Bool = { url, message, kind in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("MacMCP on \(Host.current().localizedName ?? "Mac") needs a person", forHTTPHeaderField: "Title")
        request.setValue(kind == .prompt || kind == .permission ? "high" : "default", forHTTPHeaderField: "Priority")
        request.setValue("warning", forHTTPHeaderField: "Tags")
        request.httpBody = Data(message.utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            log("alert webhook failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// Spaces actions out to at most `rate` per second; callers wait for their slot instead of being rejected.
public actor RateLimiter {
    public static let shared = RateLimiter()
    private var next = Date.distantPast

    /// How long the caller had to wait, in seconds.
    @discardableResult
    public func acquire(rate: Double, now: Date = Date()) async -> TimeInterval {
        let interval = 1 / max(rate, 0.01)
        let slot = max(now, next)
        next = slot.addingTimeInterval(interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        return wait
    }
}
