import AppKit
import Foundation
import MacMCPCore

enum DoctorTool {
    static let spec = ToolSpec(
        name: "mac_doctor",
        description: """
            Health check for this Mac's automation agent: macOS permissions (Accessibility, Screen Recording, \
            Automation for each app mac_script may control), \
            whether the screen is locked or nobody is logged in, display state, the agent's signing identity \
            and version. Call it first when actions fail unexpectedly; each problem comes with how to fix it.
            """,
        annotations: .readOnly
    ) { _, context in
        let screenRecording = await SessionState.screenRecordingLive()
        let captureFailure = screenRecording ? await testCapture() : nil
        let automation = await automationLines()
        let lock = await ActionLock.shared.status
        let health = await HealthMonitor.shared.check(alert: false)
        let claims = await Claims.shared.all().map { "\($0.resource) by \($0.holder.label)" }
        // Both wait on other processes (the keychain, launchctl): awaited here, never on the main thread.
        let policy = await PolicyStore.shared.status()
        let session = await launchdSession()
        let keychainCall = PolicyStore.shared.heldUpKeychainCall
        return .text(await MainActor.run {
            report(client: context.client, screenRecording: screenRecording, captureFailure: captureFailure,
                   automation: automation, lock: lock, health: health, claims: claims, launchdSession: session,
                   policy: policy, keychainCall: keychainCall)
        })
    }

    /// `launchdSessionType()`, without blocking a thread on launchctl.
    static func launchdSession() async -> String {
        guard let r = try? await Subprocess.run("/bin/launchctl", ["managername"], timeout: 5), !r.timedOut else { return "unknown" }
        let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "unknown" : name
    }

    /// Takes a tiny real capture: a Screen Recording grant can read as granted yet fail to capture (a stale grant
    /// after a rebuild, or one revoked mid-session). Nil when the capture works or there's nothing to capture.
    static func testCapture() async -> String? {
        guard SessionState.current().actionBlocker == nil else { return nil }
        var req = Capture.Request()
        req.maxEdge = 64
        let main = CGDisplayBounds(CGMainDisplayID())
        req.region = CGRect(x: main.minX, y: main.minY, width: 64, height: 64)
        do { _ = try await Capture.take(req, store: ScreenshotStore()); return nil } catch { return "\(error)" }
    }

    /// Automation (Apple Events) grant for each app in script.allowed_apps. Checks never prompt, and only work for
    /// running apps.
    static func automationLines() async -> [String] {
        guard case let .success(p) = await Policy.current(), !p.script.allowedApps.isEmpty else {
            return ["      no apps in script.allowed_apps"]
        }
        var lines: [String] = []
        lines.append("      System Events: " + (p.script.allowSystemEvents ? "explicitly enabled" : "off (script.allow_system_events)"))
        for app in p.script.allowedApps {
            if let warning = Scripts.broadAccessWarning(for: app) { lines.append("  !!  " + warning) }
            guard let bundleID = Scripts.bundleID(for: app) else { lines.append("      \(app): not installed"); continue }
            let grant = await Scripts.automationGrant(bundleID: bundleID, timeout: 2)
            lines.append("  \(grant.isProblem ? "!! " : grant == .granted ? "OK " : "   ") \(app): \(grant.summary)")
        }
        return lines
    }

    @MainActor
    static func report(client: String, screenRecording: Bool, captureFailure: String? = nil, automation: [String], lock: ActionLock.Status,
                       health: HealthMonitor.Report, claims: [String] = [], launchdSession: String, policy: PolicyStatus,
                       keychainCall: KeychainCall? = nil) -> String {
        var state = SessionState.current()
        state.screenRecording = screenRecording
        let identity = SigningIdentity.current()
        func mark(_ ok: Bool) -> String { ok ? "OK " : "!! " }

        var lines = ["mac-mcp \(MacMCPServer.version) — agent pid \(getpid()), client: \(client)", ""]
        lines.append("Session")
        lines.append("  \(mark(state.onConsole)) GUI session on console: \(state.onConsole ? "yes" : "NO — log in via Remote Access")")
        lines.append("  \(mark(!state.screenLocked)) screen: \(state.screenLocked ? "LOCKED — unlock via Remote Access" : "unlocked")")
        lines.append("  \(mark(!state.displayAsleep)) display: \(state.displayAsleep ? "ASLEEP — wake it via Remote Access" : "awake")")
        lines.append("      launchd session: \(launchdSession) (must be Aqua)")
        lines.append("")
        lines.append("Health (checked every 10 min; problems are alerted)")
        if let why = health.skipped {
            lines.append("      checks paused: \(why)")
        } else if health.problems.isEmpty {
            lines.append("  OK  permissions, capture, Secure Input and macOS prompts all fine")
        }
        for p in health.problems { lines.append("  !!  \(p.summary)") }
        lines.append("")
        lines.append("Control")
        lines.append("      GUI lease: \(LeaseStore.current().map { "held by \($0.summary); other clients can't act" } ?? "free")")
        lines.append("      session claims: " + (claims.isEmpty ? "none" : claims.joined(separator: "; ")))
        let held = lock.heldFor.map { " for \(Int($0)) s" } ?? ""
        lines.append("      action lock: \(lock.holder.map { "held by \($0)\(held)" } ?? "idle")"
            + (lock.waiting > 0 ? ", \(lock.waiting) waiting" : "")
            + (lock.abandoned > 0 ? "; \(lock.abandoned) abandoned at their deadline since the agent started" : ""))
        lines.append("")
        lines.append("Permissions (granted to MacMCP.app, \(Paths.bundleID))")
        lines.append("  \(mark(state.accessibility)) Accessibility: "
            + (state.accessibility ? "granted"
               : "MISSING — System Settings > Privacy & Security > Accessibility (\"Device Control\" on macOS 27): enable MacMCP"))
        lines.append("  \(mark(state.screenRecording && captureFailure == nil)) Screen Recording: "
            + (state.screenRecording
               ? captureFailure.map { "granted, but a test capture FAILED (\($0)). The grant may be stale: in System "
                   + "Settings > Privacy & Security > Screen & System Audio Recording, turn MacMCP off and on again, "
                   + "then restart the agent" } ?? "granted (test capture OK)"
               : "MISSING — System Settings > Privacy & Security > Screen & System Audio Recording: enable MacMCP. "
                 + "If MacMCP isn't listed, click +, press Cmd-Shift-G and enter \(Paths.app)"))
        lines.append("")
        lines.append("Automation (mac_script, granted to MacMCP per app)")
        lines += automation
        lines.append("")
        lines.append("Web (web_* tools: Safari's automation browser via \(SafariBridge.executable))")
        if !FileManager.default.isExecutableFile(atPath: SafariBridge.executable) {
            lines.append("  !!  \(SafariBridge.executable) missing: web_* needs Safari 27 or later")
        } else if let s = SafariBridge.shared.status {
            lines.append("  OK  session running (safarimcp pid \(s.pid), since \(s.since.formatted(date: .omitted, time: .shortened)))")
        } else {
            lines.append("      no session yet (starts on the first web_* call; needs Safari ▸ Settings ▸ Developer ▸ "
                + "\"Allow remote automation and external agents\")")
        }
        if case let .success(p) = policy.enforced {
            func list(_ l: [String]) -> String { l.isEmpty ? "none" : l.joined(separator: ", ") }
            lines.append("      \(p.web.enabled ? "enabled" : "DISABLED by policy") · web_eval \(p.web.evalAllowed ? "allowed" : "off")"
                + " · deny_hosts: \(list(p.web.denyHosts))"
                + (p.web.allowHosts.isEmpty ? "" : " · allow_hosts: \(list(p.web.allowHosts))"))
        }
        lines.append("")
        lines.append("Identity")
        lines.append("  \(mark(!identity.isAdHoc)) signing: \(identity.summary)")
        lines.append("")
        lines += policyLines(policy, keychainCall: keychainCall)
        lines.append("")
        lines.append("Displays")
        for display in Displays.all() { lines.append("      " + display.line) }
        lines.append("")
        lines.append("Files")
        lines.append("      socket: \(Paths.socket)")
        lines.append("      agent log: \(Paths.agentLog)")
        lines.append("      audit log: \(Paths.auditLog)")
        lines.append("")
        lines.append(state.actionBlocker.map { "Actions are BLOCKED: \($0)" } ?? "Actions can run.")
        return lines.joined(separator: "\n")
    }

    /// Which policy is in force and why, what's waiting for a person, and the policy's main settings.
    /// `keychainCall`: a keychain call this agent made that hasn't returned in time.
    static func policyLines(_ status: PolicyStatus, keychainCall: KeychainCall? = nil, now: Date = Date()) -> [String] {
        var lines = ["Policy"]
        let healthy = status.pending.isEmpty && status.problems.isEmpty && keychainCall == nil
        lines.append("  \(healthy ? "OK " : "!! ") in force: \(status.inForce)")
        if let approval = status.approvalLine { lines.append("      " + approval) }
        if let pending = status.pendingMessage { lines.append("  !!  " + pending) }
        if let keychainCall {
            lines.append("  !!  keychain call held up for \(keychainCall.duration(now: now)): " + keychainCall.message)
        }
        for problem in status.problems where problem != keychainCall?.message { lines.append("  !!  " + problem) }
        for notice in status.notices { lines.append("  --  " + notice) }
        if status.source != .managed {
            lines.append("  --  warning: \(Paths.policyFile) is writable by your user account, so apps an agent drives can "
                + "edit it. Changes that loosen it wait for `mac-mcp policy approve`, which records them in your login "
                + "keychain; on an unattended Mac, install a managed policy (root-owned, in \(Paths.managedPolicyDir)) instead.")
        }
        switch status.enforced {
        case .failure:
            break   // the reason is among the problems above
        case let .success(p):
            func list(_ l: [String]) -> String { l.isEmpty ? "none" : l.joined(separator: ", ") }
            lines.append("      deny_apps: \(list(p.denyApps))")
            lines.append("      allow_apps: \(p.allowApps.isEmpty ? "any app not denied" : list(p.allowApps))")
            lines.append("      mac_script may control: \(list(p.script.allowedApps)) (timeout \(p.script.timeoutSeconds) s)")
            lines.append("      clipboard reads: \(p.clipboardRead ? "allowed" : "disabled")  ·  rate limit: \(p.rateLimitPerSecond) actions/s")
            // Webhook URLs often embed a secret topic or token: show only the host.
            lines.append("      alerts: " + (p.alertWebhook.flatMap { URL(string: $0)?.host }.map { "webhook to \($0) (cooldown \(p.alertCooldownMinutes) min)" }
                ?? "agent log only (set alert_webhook to get notified when a person is needed)"))
        }
        return lines
    }
}
