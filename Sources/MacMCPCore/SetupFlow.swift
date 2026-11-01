import Foundation

/// The System Settings panes `mac-mcp setup` opens.
public enum SettingsPane: Sendable, Equatable {
    case accessibility
    case screenRecording

    public var url: String {
        switch self {
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }

    var name: String { self == .accessibility ? "Accessibility" : "Screen & System Audio Recording" }
    /// Where to find it by hand if the pane won't open.
    var path: String { "System Settings ▸ Privacy & Security ▸ \(name)" }
}

/// What `mac-mcp setup` sees of this Mac's session.
public struct SetupSession: Sendable, Equatable {
    public var onConsole: Bool
    public var screenLocked: Bool
    public var displayAsleep: Bool

    public init(onConsole: Bool, screenLocked: Bool, displayAsleep: Bool) {
        self.onConsole = onConsole
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
    }

    public var problem: String? {
        if !onConsole { return "nobody is logged in at this Mac's console" }
        if screenLocked { return "the screen is locked" }
        if displayAsleep { return "the display is asleep" }
        return nil
    }
}

/// Everything `SetupFlow` does to the outside world. The CLI's host acts on this Mac; tests supply a fake. Nothing here
/// clicks, toggles or answers anything in macOS: the flow can only open a pane, ask the person a question, and read.
public protocol SetupHost: AnyObject {
    /// A person at a terminal on this Mac, in its GUI session. Otherwise the flow prints the steps and checks once.
    var interactive: Bool { get }
    /// Why `interactive` is false, for the person reading the output.
    var notInteractiveReason: String { get }
    func say(_ text: String)
    /// This Mac's session, or nil when this process isn't in the GUI session (SSH) and so can't see it.
    func session() -> SetupSession?
    func appInstalled() -> Bool
    func agentRunning() -> Bool
    /// Starts the agent and waits for it to answer. Returns why it couldn't, if it couldn't.
    func startAgent() -> String?
    /// The grants as the agent reports them; nil if it can't be reached.
    func permissions() -> PermissionReport?
    /// Opens the pane in System Settings. False if that failed.
    func open(_ pane: SettingsPane) -> Bool
    /// Asks the person a question and returns their line; nil when input has ended.
    func ask(_ prompt: String) -> String?
    /// Waits up to `seconds` for the person to press Return: true if they did, false if the time passed, nil if input has ended.
    func waitForReturn(seconds: TimeInterval) -> Bool?
    /// What `mac-mcp doctor` reports.
    func doctorReport() -> String
    /// Registers MacMCP with the client (`mac-mcp install --client`), saying what happened. False if that failed.
    func register(_ client: McpClient) -> Bool
}

/// `mac-mcp setup`: a guided first run. It checks the session and the agent, then for each of the Accessibility and
/// Screen Recording grants opens the right pane, says what to switch on, and waits until the grant shows up (the person
/// can skip). It ends with the doctor's report and an offer to add MacMCP to an AI client.
///
/// It never clicks or toggles anything and never answers a prompt. The person does that in System Settings.
public enum SetupFlow {
    public static let pollInterval: TimeInterval = 2
    /// How many polls a grant gets before the flow gives up on it (ten minutes).
    public static let maxPolls = 300

    /// Runs the flow and returns the exit status: 0 when the session, the agent and both grants are in place.
    public static func run(_ host: SetupHost, pollInterval: TimeInterval = pollInterval, maxPolls: Int = maxPolls) -> Int32 {
        host.interactive ? guided(host, pollInterval: pollInterval, maxPolls: maxPolls) : printed(host)
    }

    // MARK: guided

    private static func guided(_ host: SetupHost, pollInterval: TimeInterval, maxPolls: Int) -> Int32 {
        host.say("""
            MacMCP setup
            This checks that MacMCP can see and drive your Mac. Where it needs a permission, it opens the System Settings
            pane and tells you what to switch on. It never clicks anything for you and never answers a macOS prompt.

            1. This Mac
            """)
        guard let session = host.session() else {
            host.say("  !!  this isn't the Mac's GUI session. Run `mac-mcp setup` in Terminal on the Mac.")
            return 1
        }
        if let problem = session.problem {
            host.say("  !!  \(problem). Fix that, then run `mac-mcp setup` again.")
            return 1
        }
        host.say("  OK  logged in at the console, screen unlocked")
        host.say("\n2. The MacMCP agent")
        guard host.appInstalled() else {
            host.say("  !!  \(Paths.app) isn't installed. Build and install it with scripts/build.sh, then run `mac-mcp setup` again.")
            return 1
        }
        if host.agentRunning() {
            host.say("  OK  running")
        } else {
            host.say("  !!  not running. It has to run for macOS to list MacMCP in Privacy & Security.")
            let answer = host.ask("Start it now? macOS will then ask for the permissions below; setup doesn't answer those. [Y/n] ")?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard let answer, answer.isEmpty || answer.hasPrefix("y") else {
                host.say("Not started. `mac-mcp install` starts it; run `mac-mcp setup` again afterwards.")
                return 1
            }
            if let why = host.startAgent() {
                host.say("  !!  couldn't start it: \(why)")
                return 1
            }
            host.say("  OK  started")
        }

        var allGranted = true
        for (step, pane) in [(3, SettingsPane.accessibility), (4, .screenRecording)] {
            host.say("\n\(step). \(pane == .accessibility ? "Accessibility" : "Screen Recording")")
            if !grant(pane, host, pollInterval: pollInterval, maxPolls: maxPolls) { allGranted = false }
        }

        host.say("\nWhat `mac-mcp doctor` reports now:\n")
        host.say(host.doctorReport())
        var registered = true
        let names = McpClient.allCases.map(\.rawValue).joined(separator: ", ")
        host.say("\nAdd MacMCP to an AI client? That is `mac-mcp install --client NAME`, with NAME one of: \(names).")
        if let line = host.ask("Type one or more names separated by spaces, or press Return to skip: ") {
            for word in line.split(whereSeparator: \.isWhitespace) {
                guard let client = McpClient(argument: String(word)) else {
                    host.say("  !!  \(word) isn't a client I know; skipped.")
                    registered = false
                    continue
                }
                host.say("")
                if !host.register(client) { registered = false }
            }
        }
        host.say(allGranted ? "\nSetup is done." : "\nSetup is not finished: run `mac-mcp setup` again when you're ready, or `mac-mcp doctor` to see what's missing.")
        return allGranted && registered ? 0 : 1
    }

    /// One permission: checks it, and if it's not there, opens its pane and waits. True once granted.
    private static func grant(_ pane: SettingsPane, _ host: SetupHost, pollInterval: TimeInterval, maxPolls: Int) -> Bool {
        func state() -> PermissionReport.Grant? {
            host.permissions().map { pane == .accessibility ? $0.accessibility : $0.screenRecording }
        }
        let first = state()
        if first == .granted {
            host.say("  OK  granted")
            return true
        }
        let (problem, steps) = guidance(pane, state: first)
        host.say("  !!  " + problem + "\n" + steps.map { "        - " + $0 }.joined(separator: "\n")
                 + "\n        macOS may ask for your password or Touch ID. That is yours to answer; setup can't.")
        if first == nil { host.say("  (The agent isn't answering yet, so this may already be done. Checking again as it starts.)") }
        if !host.open(pane) {
            host.say("  !!  couldn't open it. Open \(pane.path) yourself.")
        }
        host.say("  Waiting for the grant to show up. Press Return to skip this step.")
        var unreachable = first == nil
        for poll in 1...max(maxPolls, 1) {
            switch host.waitForReturn(seconds: pollInterval) {
            case .some(false): break
            case .some(true), .none:
                host.say("  Skipped. \(pane == .accessibility ? "Accessibility" : "Screen Recording") is still not granted.")
                return false
            }
            switch state() {
            case .granted?:
                host.say("  OK  granted")
                return true
            case nil:
                if !unreachable {
                    host.say("  The agent isn't answering (macOS may be restarting it after the change). Still waiting.")
                    unreachable = true
                }
            default:
                unreachable = false
                if poll % 15 == 0 { host.say("  Still waiting. Return skips this step.") }
            }
        }
        host.say("  Gave up waiting. Run `mac-mcp setup` again when it's switched on.")
        return false
    }

    /// What is wrong, and what the person has to do in the pane.
    static func guidance(_ pane: SettingsPane, state: PermissionReport.Grant?) -> (problem: String, steps: [String]) {
        switch pane {
        case .accessibility:
            return ("MacMCP doesn't have Accessibility yet. In \(pane.path):",
                    ["Switch on MacMCP (the list calls it \"Device Control\" on macOS 27).",
                     "If MacMCP isn't listed, click + and choose \(Paths.app)."])
        case .screenRecording:
            if case let .needsAttention(detail)? = state {
                return ("Screen Recording is on but isn't working (\(detail)). In \(pane.path):",
                        ["Switch MacMCP off, then on again."])
            }
            return ("MacMCP doesn't have Screen Recording yet. In \(pane.path):",
                    ["Switch on MacMCP.",
                     "If MacMCP isn't listed, click + and choose \(Paths.app).",
                     "macOS may offer to quit and reopen MacMCP. Choose that; the agent restarts by itself."])
        }
    }

    // MARK: not at a terminal

    private static func printed(_ host: SetupHost) -> Int32 {
        host.say("mac-mcp setup (\(host.notInteractiveReason): printing the steps and checking once)\n")
        var ok = true
        func check(_ good: Bool, _ text: String, fix: [String] = []) {
            host.say((good ? "  OK  " : "  !!  ") + text)
            for line in fix where !good { host.say("        " + line) }
            ok = ok && good
        }
        if let session = host.session() {
            check(session.problem == nil, session.problem ?? "logged in at the console, screen unlocked",
                  fix: ["Unlock this Mac, or log in at its console (Screen Sharing works), then run this again."])
        } else {
            host.say("  --  not checked: this isn't the Mac's GUI session, so it can't see whether the screen is locked")
        }
        let installed = host.appInstalled()
        check(installed, installed ? "\(Paths.app) is installed" : "\(Paths.app) isn't installed", fix: ["Build and install it with scripts/build.sh."])
        let running = installed && host.agentRunning()
        if installed { check(running, running ? "the MacMCP agent is running" : "the MacMCP agent isn't running", fix: ["`mac-mcp install` starts it."]) }
        let report = running ? host.permissions() : nil
        for pane in [SettingsPane.accessibility, .screenRecording] {
            let name = pane == .accessibility ? "Accessibility" : "Screen Recording"
            guard let report else {
                check(false, "\(name): can't tell, because the agent isn't answering")
                continue
            }
            let grant = pane == .accessibility ? report.accessibility : report.screenRecording
            let (_, steps) = guidance(pane, state: grant)
            check(grant == .granted, grant == .granted ? "\(name) is granted" : "\(name) is not granted to MacMCP",
                  fix: ["At the Mac, open \(pane.path), or run:", "  open '\(pane.url)'"] + steps.map { "- " + $0 }
                    + ["Setup never changes this itself."])
        }
        host.say("""

            Next: `mac-mcp doctor` shows the full report; `mac-mcp install --client NAME` adds MacMCP to a client \
            (\(McpClient.allCases.map(\.rawValue).joined(separator: ", "))).
            """)
        if !ok { host.say("Run `mac-mcp setup` in Terminal on the Mac to be walked through the rest.") }
        return ok ? 0 : 1
    }
}
