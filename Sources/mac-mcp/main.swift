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
//   mac-mcp policy approve [--expect-sha256 HEX] | status | prune
//   mac-mcp version
import CoreGraphics
import Foundation
import MacMCPCore

let cliVersion = "0.1.1"

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
    private let lock = NSLock()
    private let clientWriter = NSLock()
    private var session = RelaySession()
    private var fd: Int32
    private var writer: StreamWriter
    private var stdinOpen = true
    private let directive = AgentClient.directive(lease: LeaseStore.ownToken, origin: AgentClient.origin(),
                                                  session: AgentClient.newSessionID())

    init(fd: Int32) throws {
        self.fd = fd
        self.writer = StreamWriter(fd: fd)
        try StreamIO.configure(fd)
        try StreamIO.configure(STDOUT_FILENO)
    }

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
            let framed = lines.append(buffer[0..<n])
            if lines.exceededLimit { fail("client frame exceeds 16 MiB") }
            for line in framed {
                let out = lock.withLock {
                    let out = session.fromClient(line)
                    sendToAgent(out.toAgent)
                    return out
                }
                sendToClient(out.toClient)
            }
        }
        lock.withLock {
            stdinOpen = false
            guard session.phase == .connected else { exit(0) }
            writer.halfClose()
        }
    }

    private func readAgent() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var lines = LineBuffer()
            let currentFD = lock.withLock { fd }
            while true {
                let expired = lock.withLock { session.expire() }
                sendToClient(expired.toClient)
                if let failure = lock.withLock({ session.failure }) { fail(failure) }
                let deadline = lock.withLock { session.reconnectDeadline } ?? .infinity
                do { try StreamIO.wait(currentFD, events: Int16(POLLIN), deadline: deadline) }
                catch {
                    let out = lock.withLock { session.expire() }
                    sendToClient(out.toClient)
                    if let failure = lock.withLock({ session.failure }) { fail(failure) }
                    break
                }
                let n = read(currentFD, &buffer, buffer.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                if n <= 0 { break }
                let framed = lines.append(buffer[0..<n])
                if lines.exceededLimit { fail("agent frame exceeds 16 MiB") }
                for line in framed {
                    let out = lock.withLock {
                        let expired = session.expire()
                        if session.failure != nil { return expired }
                        let out = session.fromAgent(line)
                        sendToAgent(out.toAgent)
                        return out
                    }
                    sendToClient(out.toClient)
                    if let failure = lock.withLock({ session.failure }) { fail(failure) }
                }
            }
            let lost = lock.withLock {
                writer.finish { close(currentFD) }
                if !stdinOpen { exit(0) }
                return session.agentLost()
            }
            sendToClient(lost.toClient)
            FileHandle.standardError.write(Data("mac-mcp: lost the agent connection; reconnecting\n".utf8))
            reconnect()
        }
    }

    private func reconnect() {
        while true {
            let out = lock.withLock { session.expire() }
            sendToClient(out.toClient)
            if let failure = lock.withLock({ session.failure }) { fail(failure) }
            let deadline = lock.withLock { session.reconnectDeadline } ?? (StreamIO.now + reconnectWindow)
            do {
                let new = try UnixSocket.connect(path: Paths.socket, deadline: deadline)
                try StreamIO.configure(new)
                let out = lock.withLock {
                    fd = new
                    writer = StreamWriter(fd: new)
                    let expired = session.expire()
                    if session.failure != nil { writer.finish { close(new) }; return expired }
                    if let directive { sendToAgent([directive.dropLast()]) }
                    let out = session.agentReconnected()
                    sendToAgent(out.toAgent)
                    return out
                }
                sendToClient(out.toClient)
                if let failure = lock.withLock({ session.failure }) { fail(failure) }
                return
            } catch {
                usleep(200_000)   // CLI's dedicated reconnect thread
            }
        }
    }

    /// Call holding `lock`. Failure shuts down the socket and wakes the reader; queued writes stay bounded.
    private func sendToAgent(_ lines: [Data]) {
        for line in lines { if !writer.send(line + [0x0A]) { break } }
    }

    private func sendToClient(_ lines: [Data]) {
        clientWriter.withLock {
            for line in lines {
                do { try StreamIO.writeAll(STDOUT_FILENO, line + [0x0A]) }
                catch { exit(0) }
            }
        }
    }
}

func relay() -> Never {
    do {
        try Relay(fd: UnixSocket.connect(path: Paths.socket)).run()
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
        let policy = PolicyStore.shared.status()
        say("  policy:             \(policy.inForce)")
        for problem in policy.problems { say("                      !! \(problem)") }
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
    if !FileManager.default.fileExists(atPath: Paths.policyFile),
       case let .success(ledger) = PolicyStore.Locations.standard.keychain.ledger(), ledger.inForce != nil,
       (try? PolicyStore.approve()) != nil {
        say("restored \(Paths.policyFile) from the approved policy")   // not the defaults, which may be looser
    } else if (try? Policy.writeDefaultIfMissing()) == true {
        say("wrote default policy: \(Paths.policyFile)")
    }
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
        // The next install approves policy.json afresh, as on a new Mac.
        do {
            let removed = try PolicyStore.forgetApproval(ask: askToDeleteRecords)
            say(removed.kept == 0 ? "Removed the approved policy from your login keychain."
                : "Could not remove \(removed.kept) of the approved policy's records from your login keychain; the next "
                    + "install still enforces the newest one. Run `mac-mcp uninstall --purge` again to retry.")
        } catch { say("Could not remove the approved policy from your login keychain: \(error)") }
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
    if case .failure = Policy.current(path: path) {
        if let original { try? original.write(to: URL(fileURLWithPath: path)) }
        fail("that change would make the policy invalid; left it unchanged")
    }
    // A person ran this, so the change is approved, but only it: anything else that loosens the file still waits.
    do { _ = try PolicyStore.approve(onlyKeys: [key], by: "`mac-mcp alerts`") } catch { say("note: \(error)") }
}

// MARK: - policy

/// `mac-mcp policy approve | status | prune`. Changes to policy.json that loosen it (an app taken off deny_apps,
/// scripting or web_eval turned on …) only take effect once a person approves them here, in Terminal: agents can reach
/// the file through the apps they drive, but not this command, nor the login keychain where the approval is recorded.
/// `--expect-sha256 HEX` approves only if policy.json's bytes have that SHA-256, for scripts that write the file and
/// must not approve an edit made after they wrote it. `prune` deletes the older records of the approved policy that
/// `approve` couldn't, since other builds of MacMCP made them; macOS asks for the keychain password for each.
func policy(_ args: [String]) {
    switch args.first ?? "status" {
    case "approve":
        var expected: String?
        var rest = args.dropFirst()
        while let arg = rest.popFirst() {
            guard arg == "--expect-sha256", let hex = rest.popFirst()?.lowercased(),
                  hex.count == 64, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                fail("usage: mac-mcp policy approve [--expect-sha256 <64 hex digits>]")
            }
            expected = hex
        }
        do {
            let approval = try PolicyStore.approve(expectSHA256: expected)
            for note in approval.notes { say(note) }
            if approval.loosenings.isEmpty {
                say("Nothing in \(Paths.policyFile) loosens the approved policy.")
            } else {
                say("These changes loosen the policy:")
                for l in approval.loosenings { say("  - \(l)") }
            }
            say("Approved: MacMCP now enforces \(Paths.policyFile). The approval is kept in your login keychain.")
        } catch { fail("\(error)") }
    case "status":
        let status = PolicyStore.shared.status()
        say("in force: \(status.inForce)")
        if let approval = status.approvalLine { say(approval) }
        if !status.pending.isEmpty {
            say("\(Paths.policyFile) has changes that would loosen the policy, waiting for approval:")
            for l in status.pending { say("  - \(l)") }
            say("Review them, then run `mac-mcp policy approve` to apply them.")
        }
        for problem in status.problems { say("problem: \(problem)") }
        for notice in status.notices { say("note: \(notice)") }
        if status.source != .managed {
            say("note: \(Paths.policyFile) is writable by your account and the apps agents drive; for an unattended Mac, "
                + "install a managed policy in \(Paths.managedPolicyDir) (see docs/policy-and-security.md).")
        }
        if case .failure = status.enforced { exit(1) }
        if !status.pending.isEmpty { exit(3) }
    case "prune":
        do {
            let pruned = try PolicyStore.prune(ask: askToDeleteRecords)
            if pruned.deleted == 0 && pruned.kept == 0 {
                say("Nothing to prune: your login keychain holds only the approved policy in force.")
            } else {
                say("Deleted \(pruned.deleted) older record\(pruned.deleted == 1 ? "" : "s") of the approved policy"
                    + (pruned.kept == 0 ? "." : "; \(pruned.kept) stay\(pruned.kept == 1 ? "s" : ""), ignored."))
            }
        } catch { fail("\(error)") }
    default:
        fail("usage: mac-mcp policy approve [--expect-sha256 HEX] | status | prune")
    }
}

/// Said before macOS asks for the login keychain password to delete records other builds made, so the person at
/// Terminal knows what the prompts are for.
func askToDeleteRecords(_ count: Int) {
    let one = count == 1
    say("\(one ? "A record" : "\(count) records") of the approved policy \(one ? "was" : "were") made by another build of "
        + "MacMCP (or another program), so macOS asks for your login keychain password to let mac-mcp delete "
        + "\(one ? "it" : "each"). Enter it, or click Deny to keep \(one ? "it" : "that one"); records that stay are ignored.")
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
            let l = try LeaseStore.acquireWaiting(holder: option("--holder") ?? processName(getppid()), reason: option("--reason") ?? "unspecified",
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
case "policy":
    policy(args)
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
        + "logs [--audit] [-n N] | call <tool> [json] | lease acquire|release|status | alerts setup|test|off|status | policy approve [--expect-sha256 HEX]|status|prune | report [--since 7d] [--top N] | remote-setup [--name mac] | version]")
default:
    fail("unknown command '\(command)'. Try `mac-mcp help`.")
}
