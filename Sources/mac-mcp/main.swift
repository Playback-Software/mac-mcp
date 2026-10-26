// mac-mcp: command-line companion to MacMCP.app.
//
//   mac-mcp [relay]        Pipe stdio to the agent's socket. This is what MCP clients run, locally or as
//                          `ssh <mac> mac-mcp`. It passes messages through unchanged, reading just enough of
//                          them to reconnect and replay the handshake when the agent restarts.
//   mac-mcp doctor         Health report (asks the agent; falls back to local checks if it can't).
//   mac-mcp install        Install/refresh the LaunchAgent for ~/Applications/MacMCP.app and start it.
//   mac-mcp uninstall [--purge]
//   mac-mcp start | stop | restart | status
//   mac-mcp logs [--audit] [-n N]
//   mac-mcp call <tool> ['{json}'] [--save-image PATH] [--timeout SECONDS]
//   mac-mcp lease acquire [--minutes N] [--reason TEXT] [--holder NAME] [--pid PID]
//   mac-mcp lease release [TOKEN] | status
//   mac-mcp alerts setup ntfy TOPIC [--server URL] | setup url URL | test | off | status
//   mac-mcp version
import CoreGraphics
import Foundation
import MacMCPCore

let cliVersion = "0.1.0"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac-mcp: \(message)\n".utf8))
    exit(1)
}

func say(_ message: String) { print(message) }

// MARK: - relay

/// How long to keep trying to reach a restarted agent (launchd's KeepAlive brings it back within seconds).
let reconnectWindow: TimeInterval = 15

func unreachable(_ error: Any) -> String {
    "cannot reach the MacMCP agent (\(error)).\n"
        + "  agent: \(LaunchAgent.status())\n"
        + "  Run `mac-mcp doctor` on the Mac for details. The agent runs only while someone is logged in at "
        + "the console; after a reboot, log in via Remote Access."
}

/// Relays newline-delimited JSON-RPC between stdin/stdout and the agent's socket. Messages pass through as-is;
/// `RelaySession` watches them so that when the agent restarts, the relay reconnects, replays the client's
/// handshake, and answers calls that were cut off with an error rather than ending the client's session.
final class Relay: @unchecked Sendable {
    // `lock` guards everything mutable. Lines bound for the agent are queued on `toAgent` while holding it, so
    // they reach the socket in the order the session produced them. Only the socket reader writes stdout.
    private let lock = NSLock()
    private var session = RelaySession()
    private var fd: Int32
    private var stdinOpen = true
    private let toAgent = DispatchQueue(label: "relay.to-agent")

    /// Presented to every agent connection (including reconnects): the lease (if MAC_MCP_LEASE is set), where this
    /// session comes from, and one session id for the life of the relay.
    private let directive = AgentClient.directive(lease: LeaseStore.ownToken, origin: AgentClient.origin(),
                                                  session: AgentClient.newSessionID())

    init(fd: Int32) { self.fd = fd }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        if let directive { lock.withLock { sendToAgent([directive.dropLast()]) } }
        Thread { self.readClient() }.start()
        Thread { self.readAgent() }.start()
        dispatchMain()
    }

    private func readClient() {
        var lines = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            for line in lines.append(buffer[0..<n]) {
                lock.withLock { sendToAgent(session.fromClient(line).toAgent) }
            }
        }
        // Client closed stdin: half-close so the agent sees EOF but can still send its last responses.
        lock.withLock {
            stdinOpen = false
            guard session.phase == .connected else { exit(0) }  // nobody left to reconnect for
            let fd = fd
            toAgent.async { shutdown(fd, SHUT_WR) }
        }
    }

    private func readAgent() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var outageStarted: Date?
        while true {
            var lines = LineBuffer()
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                for line in lines.append(buffer[0..<n]) {
                    let toClient = lock.withLock {
                        let out = session.fromAgent(line)
                        sendToAgent(out.toAgent)
                        if session.phase == .connected { outageStarted = nil }
                        return out.toClient
                    }
                    sendToClient(toClient)
                }
            }

            let lost = lock.withLock {
                if !stdinOpen { exit(0) }  // the normal end of a session
                let fd = fd
                toAgent.async { close(fd) }  // after anything still queued for it
                return session.agentLost().toClient
            }
            sendToClient(lost)
            FileHandle.standardError.write(Data("mac-mcp: lost the agent connection; reconnecting\n".utf8))

            // The window only resets once a new connection is through the replayed handshake, so an agent that
            // keeps dying during it can't keep the client waiting forever.
            let started = outageStarted ?? Date()
            outageStarted = started
            reconnect(deadline: started.addingTimeInterval(reconnectWindow))
            if lock.withLock({ session.phase == .connected }) { outageStarted = nil }
            FileHandle.standardError.write(Data("mac-mcp: reconnected to the agent\n".utf8))
        }
    }

    private func reconnect(deadline: Date) {
        while true {
            let error: Error
            do {
                let new = try UnixSocket.connect(path: Paths.socket)
                lock.withLock {
                    fd = new
                    if let directive { sendToAgent([directive.dropLast()]) }
                    sendToAgent(session.agentReconnected().toAgent)
                }
                return
            } catch let e { error = e }
            if Date() >= deadline {
                let out = lock.withLock {
                    session.giveUp(reason: "The MacMCP agent did not come back within \(Int(reconnectWindow)) s. "
                        + "Run `mac-mcp doctor` on the Mac.")
                }
                sendToClient(out.toClient)
                fail(unreachable(error))
            }
            usleep(200_000)
        }
    }

    /// Call holding `lock`. A failed write is ignored: the reader sees the connection drop and recovers.
    private func sendToAgent(_ lines: [Data]) {
        guard !lines.isEmpty else { return }
        let fd = fd
        toAgent.async { for line in lines { _ = Self.writeAll(fd, line + [0x0A]) } }
    }

    private func sendToClient(_ lines: [Data]) {
        for line in lines where !Self.writeAll(STDOUT_FILENO, line + [0x0A]) { exit(0) }  // the client is gone
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

func relay() -> Never {
    do {
        Relay(fd: try UnixSocket.connect(path: Paths.socket)).run()
    } catch {
        fail(unreachable(error))
    }
}

// MARK: - agent calls

func callTool(_ name: String) throws -> String {
    try AgentClient(clientName: "mac-mcp-cli", version: cliVersion).call(name).text
}

/// `mac-mcp call <tool> ['{"json":"args"}'] [--save-image PATH]`: for debugging and scripted checks.
func call(_ args: [String]) {
    guard let tool = args.first else { fail("usage: mac-mcp call <tool> ['{json args}'] [--save-image PATH]") }
    var arguments: [String: Any] = [:]
    if args.count > 1, !args[1].hasPrefix("--") {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(args[1].utf8))) as? [String: Any] else {
            fail("arguments must be a JSON object, e.g. '{\"app\":\"Finder\"}'")
        }
        arguments = obj
    }
    let savePath = args.firstIndex(of: "--save-image").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    // Long calls (a script waiting for a person to answer a consent prompt) need more than the default 30 s.
    let timeout = args.firstIndex(of: "--timeout").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 30
    do {
        let result = try AgentClient(clientName: "mac-mcp-cli", version: cliVersion, timeout: timeout).call(tool, arguments)
        for block in result.content {
            if let text = block["text"] as? String { print(text) }
            else if block["type"] as? String == "image", let b64 = block["data"] as? String {
                if let savePath, let data = Data(base64Encoded: b64) {
                    try data.write(to: URL(fileURLWithPath: savePath))
                    print("[image saved to \(savePath)]")
                } else { print("[image: \(b64.count) base64 chars]") }
            }
        }
        exit(result.isError ? 2 : 0)
    } catch { fail("\(error)") }
}

// MARK: - commands

func doctor() {
    do {
        say(try callTool("mac_doctor"))
    } catch {
        let fm = FileManager.default
        say("Could not reach the agent: \(error)\n")
        say("Local checks (from this \(launchdSessionType()) session):")
        say("  app installed:      \(fm.fileExists(atPath: Paths.app) ? "yes" : "NO — build and install it (scripts/build.sh)") (\(Paths.app))")
        say("  LaunchAgent plist:  \(fm.fileExists(atPath: Paths.launchAgentPlist) ? "yes" : "NO — run `mac-mcp install`")")
        say("  LaunchAgent:        \(LaunchAgent.status())")
        say("  socket:             \(fm.fileExists(atPath: Paths.socket) ? "present" : "missing") (\(Paths.socket))")
        let session = SessionState(sessionInfo: CGSessionCopyCurrentDictionary() as? [String: Any],
                                   displayAsleep: false, accessibility: true, screenRecording: true)
        if !session.onConsole && launchdSessionType() == "Aqua" {
            say("  console session:    nobody logged in? Log in via Remote Access.")
        }
        say("\nAgent log: \(Paths.agentLog)")
        exit(1)
    }
}

func install() {
    guard FileManager.default.fileExists(atPath: Paths.agentExecutable) else {
        fail("\(Paths.app) not found. Build it first with scripts/build.sh.")
    }
    do { try LaunchAgent.writePlist() } catch { fail("writing \(Paths.launchAgentPlist): \(error)") }
    try? FileManager.default.createDirectory(atPath: Paths.configDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    if (try? Policy.writeDefaultIfMissing()) == true { say("wrote default policy: \(Paths.policyFile)") }
    _ = LaunchAgent.stop()
    // bootout can return before launchd has finished removing the service; bootstrapping into that window fails
    // with "Input/output error" (5). Wait for it to go, and retry a few times.
    for _ in 0..<50 where LaunchAgent.isLoaded { usleep(100_000) }
    var (code, out) = LaunchAgent.launchctl("bootstrap", LaunchAgent.domain, Paths.launchAgentPlist)
    for _ in 0..<4 where code != 0 {
        usleep(500_000)
        (code, out) = LaunchAgent.launchctl("bootstrap", LaunchAgent.domain, Paths.launchAgentPlist)
    }
    guard code == 0 else {
        fail("launchctl bootstrap failed (\(code)): \(out)\n"
            + "The agent can only start while someone is logged in at the console.")
    }
    // Wait until the new agent accepts connections (the old socket file may still exist, so don't trust the file).
    for _ in 0..<50 {
        if let fd = try? UnixSocket.connect(path: Paths.socket) { close(fd); break }
        usleep(100_000)
    }
    say("installed: \(LaunchAgent.status())")
}

func uninstall(purge: Bool) {
    _ = LaunchAgent.stop()
    try? FileManager.default.removeItem(atPath: Paths.launchAgentPlist)
    say("LaunchAgent removed.")
    if purge {
        for path in [Paths.app, Paths.supportDir] { try? FileManager.default.removeItem(atPath: path) }
        say("Removed \(Paths.app) and \(Paths.supportDir). Logs kept in \(Paths.logsDir); config in \(Paths.configDir).")
    }
}

func logs(audit: Bool, lines: Int) {
    let path = audit ? Paths.auditLog : Paths.agentLog
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    p.arguments = ["-n", "\(lines)", path]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - alerts

/// `mac-mcp alerts …`: set up the webhook MacMCP posts to when a person is needed (policy `alert_webhook`). Only the
/// webhook's host is ever printed: ntfy topics and many webhook URLs are secrets.
func alerts(_ args: [String]) {
    func option(_ name: String) -> String? {
        args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    func host(_ url: String?) -> String { url.flatMap { URL(string: $0)?.host } ?? "?" }
    switch args.first ?? "status" {
    case "setup":
        guard args.count >= 3 else { fail("usage: mac-mcp alerts setup ntfy TOPIC [--server URL] | setup url URL") }
        let url = args[1] == "ntfy"
            ? (option("--server") ?? "https://ntfy.sh").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + args[2]
            : args[2]
        guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme ?? ""), parsed.host != nil else {
            fail("not an http(s) URL")
        }
        setPolicyValue("alert_webhook", url)
        say("alerts now go to \(host(url)); sending a test …")
        say(sendTestAlert(url) ? "test alert delivered" : "the test alert FAILED: check the topic/URL and the network")
    case "test":
        guard let url = Policy.load().alertWebhook else { fail("no alert_webhook set. Run `mac-mcp alerts setup …` first.") }
        say(sendTestAlert(url) ? "test alert delivered to \(host(url))" : "the test alert to \(host(url)) FAILED")
    case "off":
        setPolicyValue("alert_webhook", nil)
        say("alerts off (problems are still written to \(Paths.agentLog))")
    case "status":
        say(Policy.load().alertWebhook.map { "alerts go to \(host($0))" } ?? "alerts off")
    default:
        fail("usage: mac-mcp alerts setup ntfy TOPIC [--server URL] | setup url URL | test | off | status")
    }
}

func sendTestAlert(_ url: String) -> Bool {
    guard let u = URL(string: url) else { return false }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var ok = false
    Task {
        ok = await Alerts.post(u, "Test alert from MacMCP (`mac-mcp alerts test`). Real alerts say what needs a person.", .agent)
        done.signal()
    }
    _ = done.wait(timeout: .now() + 15)
    return ok
}

/// Sets (or, with nil, removes) one top-level key of policy.json, keeping the rest of the file as it is. Refuses to
/// leave an invalid policy behind.
func setPolicyValue(_ key: String, _ value: Any?) {
    let path = Paths.policyFile
    let original = FileManager.default.contents(atPath: path)
    var object = original.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    if original != nil, object.isEmpty, (original?.count ?? 0) > 2 { fail("\(path) isn't valid JSON; fix it first (`mac-mcp doctor`)") }
    object[key] = value
    do {
        try FileManager.default.createDirectory(atPath: Paths.configDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: path))
    } catch { fail("writing \(path): \(error)") }
    if case .failure = Policy.current() {
        if let original { try? original.write(to: URL(fileURLWithPath: path)) }
        fail("that change would make the policy invalid; left it unchanged")
    }
}

// MARK: - lease

/// `mac-mcp lease …`: take, give back or show the GUI lease (see `Lease`). `acquire` prints only the token, so
/// scripts can do `export MAC_MCP_LEASE=$(mac-mcp lease acquire --pid $$ --reason eval)`. With --pid the lease also
/// ends when that process exits (a crashed script can't strand the box); without it, it lasts until released or
/// expired. (The CLI's own parent isn't a safe default: bash runs `$(...)` in a subshell that exits at once.)
func lease(_ args: [String]) {
    func option(_ name: String) -> String? {
        args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    switch args.first ?? "status" {
    case "acquire":
        let pid = option("--pid").flatMap(Int32.init) ?? 0
        do {
            let l = try LeaseStore.acquire(holder: option("--holder") ?? processName(getppid()), reason: option("--reason") ?? "unspecified",
                                           minutes: option("--minutes").flatMap(Double.init) ?? 60, pid: pid)
            print(l.token)
        } catch {
            fail("\(error)")
        }
    case "release":
        guard let token = args.dropFirst().first ?? LeaseStore.ownToken else { fail("usage: mac-mcp lease release TOKEN") }
        if LeaseStore.release(token: token) { say("released") } else { fail("that token doesn't hold the lease") }
    case "status":
        // Exit 3 only when someone else holds it, so scripts can ask "may I drive the GUI?"
        guard let l = LeaseStore.current() else { say("free"); break }
        if l.token == LeaseStore.ownToken { say("leased by you (MAC_MCP_LEASE): \(l.summary)"); break }
        say("leased: \(l.summary)")
        exit(3)
    default:
        fail("usage: mac-mcp lease acquire [--minutes N] [--reason TEXT] [--holder NAME] [--pid PID] | release [TOKEN] | status")
    }
}

/// A process's executable name, for labelling a lease ("zsh", "python3.14").
func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
}

/// Commands that disrupt a running agent refuse while someone else holds the lease (override with --force).
func requireNoForeignLease(_ args: [String], _ what: String) {
    guard !args.contains("--force"), let l = LeaseStore.current(), l.token != LeaseStore.ownToken else { return }
    fail("not \(what): the GUI is leased by \(l.summary). Wait for it, or pass --force.")
}

/// `mac-mcp remote-setup [--name mac]`: checks this Mac and prints what to run on another machine so its Claude Code
/// reaches MacMCP over SSH. Changes nothing (in particular, never touches ~/.ssh on either side).
func remoteSetup(_ args: [String]) {
    let name = args.firstIndex(of: "--name").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "mac"
    let user = NSUserName()
    let local = ((try? Subprocess.runBlocking("/usr/sbin/scutil", ["--get", "LocalHostName"], timeout: 5))?.stdout ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let host = local.isEmpty ? ProcessInfo.processInfo.hostName : local + ".local"
    var ok = true
    func check(_ good: Bool, _ text: String, _ fix: String) {
        say((good ? "  OK  " : "  !!  ") + text + (good ? "" : " — " + fix))
        ok = ok && good
    }
    say("Checks on this Mac")
    let sshd = UnixSocket.tcpReachable(host: "127.0.0.1", port: 22)
    check(sshd, "Remote Login (SSH) is on", "System Settings ▸ General ▸ Sharing ▸ Remote Login")
    let agentUp = (try? UnixSocket.connect(path: Paths.socket)).map { close($0); return true } ?? false
    check(agentUp, "the MacMCP agent is running", "`mac-mcp start` (or `mac-mcp install`)")
    check(FileManager.default.isExecutableFile(atPath: Paths.cli), "the relay is at \(Paths.cli)", "`scripts/build.sh` installs it")
    let policy = Policy.current()
    if case let .failure(e) = policy { check(false, "policy is valid", e.description) } else { check(true, "policy is valid", "") }
    if case let .success(p) = policy, p.alertWebhook == nil {
        say("  --  no alert webhook: you won't be told when a remote agent finds the screen locked (`mac-mcp alerts setup`)")
    }
    let remote = "\(user)@\(host)"
    var addresses: [String] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&list) == 0 {
        var p = list
        while let ifa = p?.pointee {
            if let a = ifa.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET), String(cString: ifa.ifa_name).hasPrefix("en") {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(a, socklen_t(a.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: buf))
                }
            }
            p = ifa.ifa_next
        }
        freeifaddrs(list)
    }
    let ssh = "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \(remote) \(Paths.cli)"
    say("""

        On the other machine
          1. Make key-based SSH work (once), then accept this Mac's host key:
               ssh-copy-id \(remote)        # if you don't use a key with this Mac yet
               ssh \(remote) \(Paths.cli) doctor
          2. Add MacMCP to Claude Code there (all projects):
               claude mcp add --scope user \(name) -- \(ssh)
          3. In Claude Code, /mcp should list "\(name)" as connected; ask it to call mac_doctor.

        Notes
          - If \(host) doesn't resolve on the other machine, use an address instead\(addresses.isEmpty ? "" : ": " + addresses.joined(separator: " or ")).
          - The screen locks by policy. A remote agent then gets SCREEN LOCKED and can mac_wait until=unlock while you
            unlock it via Remote Access; you're alerted if a webhook is set.
          - Two sessions never act at once: the second waits up to 30 s for the GUI, then is told who has it.
          - `mac-mcp report` shows remote sessions as ssh:<address>.
        """)
    if !ok { exit(1) }
}

/// `mac-mcp report [--since 7d] [--top N]`: real use, from the audit log.
func report(_ args: [String]) {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    guard let span = UsageReport.interval(value("--since") ?? "7d") else { fail("--since takes e.g. 7d, 24h or 90m.") }
    let top = value("--top").flatMap(Int.init) ?? 8
    say(UsageReport.render(UsageReport.load(), since: Date().addingTimeInterval(-span), top: top))
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "relay" : args.removeFirst()
switch command {
case "relay":
    relay()
case "doctor":
    doctor()
case "call":
    call(args)
case "install":
    requireNoForeignLease(args, "installing")
    install()
case "uninstall":
    requireNoForeignLease(args, "uninstalling")
    uninstall(purge: args.contains("--purge"))
case "lease":
    lease(args)
case "alerts":
    alerts(args)
case "report":
    report(args)
case "remote-setup":
    remoteSetup(args)
case "start", "restart":
    requireNoForeignLease(args, "restarting the agent")
    let (code, out) = LaunchAgent.start()
    for _ in 0..<50 where code == 0 {
        if let fd = try? UnixSocket.connect(path: Paths.socket) { close(fd); break }
        usleep(100_000)
    }
    say(code == 0 ? "agent: \(LaunchAgent.status())" : "failed (\(code)): \(out)")
case "stop":
    requireNoForeignLease(args, "stopping the agent")
    let (code, out) = LaunchAgent.stop()
    say(code == 0 ? "agent stopped. Run `mac-mcp start` to resume." : "failed (\(code)): \(out)")
case "status":
    say("agent: \(LaunchAgent.status())")
case "logs":
    let n = args.firstIndex(of: "-n").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 50
    logs(audit: args.contains("--audit"), lines: n)
case "version", "--version":
    say("mac-mcp \(cliVersion)")
case "help", "--help", "-h":
    say("usage: mac-mcp [relay | doctor | install | uninstall [--purge] | start | stop | restart | status | "
        + "logs [--audit] [-n N] | call <tool> [json] | lease acquire|release|status | alerts setup|test|off|status | report [--since 7d] [--top N] | remote-setup [--name mac] | version]")
default:
    fail("unknown command '\(command)'. Try `mac-mcp help`.")
}
