import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit

/// Periodic self-check for an unattended box: finds what silently breaks agents (a lost permission, capture that
/// returns only wallpaper, Secure Input left on, a macOS prompt waiting for a person) and alerts before an agent trips
/// over it. A locked screen or nobody logged in is expected on this box and only noted, never alerted.
public actor HealthMonitor {
    public static let shared = HealthMonitor()

    public struct Problem: Sendable, Equatable {
        public let kind: Alerts.Kind
        public let summary: String
    }

    public struct Report: Sendable {
        public let checkedAt: Date
        /// Why the GUI checks were skipped (screen locked, …), if they were.
        public let skipped: String?
        public let problems: [Problem]
    }

    /// What one check observed.
    public struct Observation: Sendable {
        /// Why the GUI checks were skipped (screen locked, …): the rest is then unobserved.
        public var skipped: String?
        public var onConsole = true
        public var screenLocked = false
        public var displayAsleep = false
        public var accessibility = true
        public var screenRecording = true
        /// On-screen windows of other apps (window server) vs. windows ScreenCaptureKit can see.
        public var visibleWindows = 0
        public var capturableWindows = 0
        public var secureInput: (pid: pid_t, name: String)?
        public var prompts: [(owner: String, text: String)] = []
        /// Guard workers stuck in a blocking call (an unresponsive network mount), per pool. Needs no GUI session.
        public var stuckGuards: [(pool: String, count: Int, oldest: TimeInterval)] = []
        public init() {}
    }

    public private(set) var last: Report?
    private var secureInputSince: (pid: pid_t, since: Date)?
    private var started = false
    private let alerts: Alerts
    private let policy: @Sendable () -> Policy
    private let observe: @Sendable () async -> Observation

    /// Defaults observe this Mac and alert through the policy's webhook; tests inject both.
    public init(alerts: Alerts = .shared, policy: @escaping @Sendable () -> Policy = { Policy.load() },
                observe: @escaping @Sendable () async -> Observation = HealthMonitor.observeSystem) {
        self.alerts = alerts
        self.policy = policy
        self.observe = observe
    }

    /// How long Secure Input may stay on, held by the same process, before it counts as stuck.
    public static let secureInputLimit: TimeInterval = 15 * 60

    /// The problems in an observation. Pure, for tests; `secureFor` is how long the current holder has held it.
    public static func problems(_ o: Observation, secureFor: TimeInterval) -> [Problem] {
        var out: [Problem] = []
        if !o.accessibility {
            out.append(Problem(kind: .permission, summary: "MacMCP has lost Accessibility (\"Device Control\") permission: "
                + "a person must re-enable it in System Settings ▸ Privacy & Security."))
        }
        if !o.screenRecording {
            out.append(Problem(kind: .permission, summary: "MacMCP has lost Screen Recording permission: a person must "
                + "re-enable it in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."))
        } else if o.visibleWindows > 0, o.capturableWindows == 0 {
            out.append(Problem(kind: .permission, summary: "Screen capture sees no windows (only the wallpaper) although "
                + "\(o.visibleWindows) are on screen: Screen Recording is probably stale. Toggle MacMCP off and on in "
                + "System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then `mac-mcp restart`."))
        }
        if let s = o.secureInput, secureFor >= secureInputLimit {
            out.append(Problem(kind: .session, summary: "Secure keyboard entry has been on for \(Int(secureFor / 60)) min, "
                + "held by \(s.name) (a focused password field, or a terminal's Secure Keyboard Entry). Typing into "
                + "other apps can fail until it's released."))
        }
        for p in o.prompts {
            out.append(Problem(kind: .prompt, summary: promptSummary(owner: p.owner, text: p.text)))
        }
        return out + stuckProblems(o)
    }

    /// Route and focus checks run on bounded workers; one blocked in the kernel for 10× its timeout is lost until the
    /// call returns. The pool adds replacements, but a hung SMB/NFS mount will keep using them up.
    static func stuckProblems(_ o: Observation) -> [Problem] {
        o.stuckGuards.map {
            Problem(kind: .agent, summary: "\($0.count) \($0.pool) check worker\($0.count == 1 ? " is" : "s are") stuck, the oldest for "
                + "\(Int($0.oldest)) s: a filesystem call is not returning, usually an unresponsive network mount (SMB/NFS). "
                + "Checks on other paths still run, but input may be refused until it recovers. Unmount or reconnect it.")
        }
    }

    /// What a waiting macOS prompt is, with a specific fix for the ones we know.
    static func promptSummary(owner: String, text: String) -> String {
        let t = text.lowercased()
        let quoted = text.isEmpty ? "" : ": \"\(text.prefix(160))\""
        if t.contains("bypass the system private window picker")
            || (t.contains("screen") && (t.contains("record") || t.contains("access your screen")) && t.contains("macmcp")) {
            return "macOS is asking whether MacMCP may keep recording the screen (the periodic Screen Recording "
                + "re-approval)\(quoted). Until a person answers it via Remote Access, screenshots fail. Choose Allow."
        }
        return "A macOS prompt from \(owner) is waiting for a person\(quoted). Agents never answer these; "
            + "answer it via Remote Access."
    }

    /// Runs the checks now. Alerts (subject to the per-kind cooldown) unless `alert` is false.
    @discardableResult
    public func check(alert: Bool = true, now: Date = Date()) async -> Report {
        let o = await observe()
        if let skipped = o.skipped {
            secureInputSince = nil
            let report = Report(checkedAt: now, skipped: skipped, problems: Self.stuckProblems(o))
            last = report
            return report
        }
        if let s = o.secureInput {
            if secureInputSince?.pid != s.pid { secureInputSince = (s.pid, now) }
        } else {
            secureInputSince = nil
        }
        let secureFor = secureInputSince.map { now.timeIntervalSince($0.since) } ?? 0
        let report = Report(checkedAt: now, skipped: nil, problems: Self.problems(o, secureFor: secureFor))
        last = report
        if alert {
            let p = policy()
            for problem in report.problems { await alerts.notify(problem.kind, problem.summary, policy: p, now: now) }
            if !report.problems.isEmpty { log("health: " + report.problems.map(\.summary).joined(separator: " | ")) }
        }
        return report
    }

    /// What this Mac looks like right now.
    @Sendable public static func observeSystem() async -> Observation {
        let state = SessionState.current()
        var o = Observation()
        o.stuckGuards = Input.stuckGuardWorkers()
        o.onConsole = state.onConsole
        o.screenLocked = state.screenLocked
        o.displayAsleep = state.displayAsleep
        o.skipped = !state.onConsole ? "nobody is logged in at the console"
            : state.screenLocked ? "the screen is locked" : state.displayAsleep ? "the display is asleep" : nil
        guard o.skipped == nil else { return o }
        o.accessibility = AXIsProcessTrusted()
        o.screenRecording = await SessionState.screenRecordingLive()
        let windows = WindowServer.onScreenWindows()
        let me = getpid()
        o.visibleWindows = windows.filter { $0.isNormalLayer && $0.pid != me }.count
        if o.screenRecording, o.visibleWindows > 0 {
            o.capturableWindows = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))?
                .windows.filter { $0.windowLayer == 0 }.count ?? 0
        }
        if let pid = WindowServer.secureInputPID {
            o.secureInput = (pid, NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)")
        }
        o.prompts = WindowServer.systemPrompts(in: windows)
            .filter { !["loginwindow", "ScreenSaverEngine"].contains($0.owner) }
            .reduce(into: [(owner: String, text: String)]()) { acc, w in
                if !acc.contains(where: { $0.owner == w.owner }) { acc.append((w.owner, WindowServer.promptText(pid: w.pid))) }
            }
        return o
    }

    /// Checks every `interval` seconds for the life of the agent (the first one after a minute).
    public func start(every interval: TimeInterval = 600) {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(60))
            while true {
                await self.check()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

extension WindowServer {
    /// The visible text of a process's windows (a prompt's message and buttons), best effort. Short timeouts: a
    /// prompt process that doesn't answer accessibility just yields "".
    public static func promptText(pid: pid_t, limit: Int = 300) -> String {
        let app = AXElement.application(pid: pid, timeout: 1)
        var parts: [String] = []
        var visited = 0
        // Recursive, but depth < 8 and 200 visits bound it to eight frames of a few locals.
        func walk(_ e: AXElement, depth: Int) {
            guard depth < 8, visited < 200 else { return }
            visited += 1
            let v = e.read([kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]) ?? [:]
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = v[key] as? String, !s.isEmpty, !parts.contains(s) { parts.append(s) }
            }
            for child in e.elements(kAXChildrenAttribute) { walk(child, depth: depth + 1) }
        }
        for window in app.elements(kAXWindowsAttribute) { walk(window, depth: 0) }
        return String(parts.joined(separator: " · ").prefix(limit))
    }
}
