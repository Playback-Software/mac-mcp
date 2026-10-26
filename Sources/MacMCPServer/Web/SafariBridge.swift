import Foundation
import MacMCPCore

/// One long-lived session with Safari's built-in MCP server (`/usr/bin/safarimcp`, Safari 27+).
///
/// What the M8 spike established:
/// - safarimcp drives a **separate automation Safari** (`Safari --automation`, a WebDriver session) with a fresh,
///   ephemeral profile. It never touches the person's Safari windows, logins or history. Cookies and storage last
///   only as long as the session, so the agent keeps one session open across calls and clients.
/// - Tabs belong to the session; a new safarimcp process starts with none.
/// - Node uids in its page text are per page load; stale ones are refused, not guessed.
/// - It needs Safari ▸ Settings ▸ Developer ▸ "Allow remote automation and external agents" (a person turns it on).
///
/// The child is started on first use and restarted if it exits or stops answering. Calls are serialized: the
/// automation browser has one active tab at a time.
public final class SafariBridge: @unchecked Sendable {
    public static let shared = SafariBridge()
    public static let executable = "/usr/bin/safarimcp"

    public struct Reply: Sendable {
        public let text: String
        public let isError: Bool
        /// The text parsed as JSON, when it is JSON (most safarimcp tools return a JSON object as text).
        public var json: Value? { try? Value.parse(Data(text.utf8)) }
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case unavailable(String)
        case timedOut(String, TimeInterval)
        case exited

        public var description: String {
            switch self {
            case let .unavailable(why): "Safari automation is unavailable: \(why)"
            case let .timedOut(tool, s): "Safari's automation server didn't answer \(tool) within \(Int(s)) s; the session was restarted (open tabs are gone)."
            case .exited: "Safari's automation server exited; the next call starts a new session (open tabs are gone)."
            }
        }
    }

    private let turn = ActionLock()   // one request at a time, in order
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    /// Requests awaiting a reply, with the session they were sent on: an old session ending must not fail a new one's.
    private var pending: [Int: (session: Int, continuation: CheckedContinuation<Value, Error>)] = [:]
    private var session = 0
    private var nextID = 1
    private var sessionStarted: Date?

    /// The running session's process id and start time, for mac_doctor.
    public var status: (pid: Int32, since: Date)? {
        lock.withLock { process.flatMap { p in sessionStarted.map { (p.processIdentifier, $0) } } }
    }

    /// Tools that change nothing (or only open a page), so they can be retried on a fresh session.
    static let restartable: Set<String> = ["navigate_to_url", "list_tabs", "page_info", "get_page_content", "create_tab",
                                           "browser_dialogs", "browser_console_messages", "list_network_requests"]

    /// Calls one safarimcp tool. Throws `BridgeError` when the session can't be used.
    ///
    /// The automation Safari can disappear underneath the session (someone quit Safari, or it crashed); safarimcp
    /// then exits. A call that hit a session like that never ran, so a restartable one is retried once on a new session.
    public func call(_ tool: String, _ arguments: [String: Value] = [:], timeout: TimeInterval = 45) async throws -> Reply {
        try await turn.run("safari:\(tool)", deadline: 2 * timeout + 30, maxWait: 60) {
            do {
                return try await self.send(tool, arguments, timeout: timeout)
            } catch BridgeError.exited where Self.restartable.contains(tool) {
                log("Safari automation session ended; retrying \(tool) on a new one")
                self.stop()
                return try await self.send(tool, arguments, timeout: timeout)
            }
        }
    }

    private func send(_ tool: String, _ arguments: [String: Value], timeout: TimeInterval) async throws -> Reply {
        try await ensureStarted()
        return Self.reply(try await request("tools/call", ["name": .string(tool), "arguments": .object(arguments)],
                                            timeout: timeout, what: tool))
    }

    // MARK: session

    private func ensureStarted() async throws {
        if lock.withLock({ process?.isRunning ?? false }) { return }
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw BridgeError.unavailable("\(Self.executable) not found (needs Safari 27 or later)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.executable)
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        let current = lock.withLock { () -> Int in session += 1; return session }
        p.terminationHandler = { [weak self] _ in self?.failAll(session: current) }
        try p.run()
        lock.withLock {
            process = p
            input = stdin.fileHandleForWriting
            sessionStarted = Date()
        }
        let reader = Thread { [weak self] in self?.readLoop(stdout.fileHandleForReading.fileDescriptor, session: current) }
        reader.name = "mac-mcp.safari.reader"
        reader.start()
        log("Safari automation session started (safarimcp pid \(p.processIdentifier))")
        _ = try await request("initialize", [
            "protocolVersion": "2024-11-05", "capabilities": [:],
            "clientInfo": ["name": "mac-mcp", "version": .string(MacMCPServer.version)],
        ], timeout: 20, what: "initialize")
        write(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// Ends the session (and the automation Safari with it).
    public func stop() {
        let p = lock.withLock { () -> Process? in
            defer { process = nil; input = nil; sessionStarted = nil }
            return process
        }
        p?.terminate()
    }

    private func request(_ method: String, _ params: Value, timeout: TimeInterval, what: String) async throws -> Value {
        let reply: Value? = try await Deadline.run(timeout) { try await self.exchange(method, params) }
        guard let reply else {
            // A wedged automation session is worse than a lost one: start over next time.
            stop()
            throw BridgeError.timedOut(what, timeout)
        }
        return try Self.unwrap(reply)
    }

    /// Sends one request and waits for its reply, however long that takes (callers bound it).
    private func exchange(_ method: String, _ params: Value) async throws -> Value {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Value, Error>) in
                self.lock.withLock { self.pending[id] = (self.session, c) }
                self.write(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
            }
        } onCancel: {
            // Stop waiting; a late reply is then dropped.
            let c = self.lock.withLock { self.pending.removeValue(forKey: id)?.continuation }
            c?.resume(throwing: CancellationError())
        }
    }

    private static func unwrap(_ reply: Value) throws -> Value {
        if let error = reply["error"] { throw BridgeError.unavailable(error["message"]?.stringValue ?? "\(error)") }
        return reply["result"] ?? .null
    }

    private static func reply(_ result: Value) -> Reply {
        let text = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return Reply(text: text, isError: result["isError"]?.boolValue ?? false)
    }

    // MARK: interactions and JavaScript dialogs

    public enum Interaction: Sendable {
        case done(Reply)
        /// A JavaScript dialog (alert/confirm/prompt) opened mid-interaction and is waiting for an answer. The
        /// interaction is parked: it finishes once web_dialog answers the dialog.
        case dialog(String)
    }

    /// The interaction parked behind an open dialog, if any.
    private var parked: Task<Value, Error>?

    /// Runs page interactions, watching for JavaScript dialogs. A click that opens confirm() doesn't return until
    /// the dialog is answered (safarimcp blocks on it), so while it's pending we ask about dialogs every 1.5 s; safarimcp
    /// answers that concurrently.
    public func interact(_ arguments: [String: Value], timeout: TimeInterval = 45) async throws -> Interaction {
        try await turn.run("safari:page_interactions", deadline: timeout + 30, maxWait: 60) {
            try await self.ensureStarted()
            let params: Value = ["name": "page_interactions", "arguments": .object(arguments)]
            let pending = Task { try await self.exchange("tools/call", params) }
            let started = Date()
            while true {
                if let reply = try await Deadline.run(1.5, { try await pending.value }) {
                    return .done(Self.reply(try Self.unwrap(reply)))
                }
                if let message = try await self.openDialog() {
                    self.lock.withLock { self.parked = pending }
                    return .dialog(message)
                }
                if Date().timeIntervalSince(started) > timeout {
                    pending.cancel()
                    self.stop()
                    throw BridgeError.timedOut("page_interactions", timeout)
                }
            }
        }
    }

    /// The message of the open JavaScript dialog, if one is open.
    private func openDialog() async throws -> String? {
        guard let reply = try await Deadline.run(5, {
            try await self.exchange("tools/call", ["name": "browser_dialogs", "arguments": ["action": "list"]])
        }) else { return nil }
        let text = Self.reply(try Self.unwrap(reply)).text
        guard let first = (try? Value.parse(Data(text.utf8)))?["dialogs"]?.arrayValue?.first else { return nil }
        return first["message"]?.stringValue ?? "(no message)"
    }

    /// After a dialog was answered: the result of the interaction that was waiting on it, if it finishes in time.
    public func finishParked(within seconds: TimeInterval = 15) async -> Reply? {
        guard let task = lock.withLock({ () -> Task<Value, Error>? in defer { parked = nil }; return parked }) else { return nil }
        guard let reply = try? await Deadline.run(seconds, { try await task.value }) else { return nil }
        return (try? Self.unwrap(reply)).map(Self.reply)
    }

    private func write(_ message: Value) {
        var data = message.jsonData()
        data.append(0x0A)
        let handle = lock.withLock { input }
        try? handle?.write(contentsOf: data)
    }

    private func readLoop(_ fd: Int32, session: Int) {
        var framing = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            for line in framing.append(buffer[0..<n]) {
                guard let message = try? Value.parse(line), let id = message["id"]?.intValue else { continue }
                let c = lock.withLock { pending.removeValue(forKey: id) }
                c?.continuation.resume(returning: message)
            }
        }
        failAll(session: session)
    }

    /// Fails the requests still waiting on a session that has ended.
    private func failAll(session ended: Int) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            let ids = pending.filter { $0.value.session == ended }.map(\.key)
            return ids.compactMap { pending.removeValue(forKey: $0)?.continuation }
        }
        waiting.forEach { $0.resume(throwing: BridgeError.exited) }
    }
}
