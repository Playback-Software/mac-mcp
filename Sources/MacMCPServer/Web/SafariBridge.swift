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
///
/// safarimcp's `navigate_to_url` and `page_interactions` reply in the format of the last `get_page_content` call. A
/// markdown read (`readMarkdown`) therefore puts the text tree back in the same turn, so no queued call can run
/// while markdown is the active format and come back without uids; the restore runs even when the read is
/// cancelled, and a restore that fails leaves the format unknown for that session, which the next format-dependent
/// call repairs before it runs.
///
/// The action lock moves on when it abandons a request (cancelled, or past its deadline), but the abandoned request's
/// code goes on until it notices, and a markdown read's restore deliberately runs to the end. So each request also
/// holds the bridge (`occupancy`) for as long as its code runs, and the next one starts only after that.
///
/// A request already sent to safarimcp can't be taken back: a `page_interactions` whose caller gave up keeps typing
/// and clicking in Safari. So an abandoned request stays in `inFlight` until its reply arrives, and the next request
/// that touches the page waits for it, up to `abandonedGrace`; past that the session is restarted, which ends
/// whatever was left running, and that request fails with a short explanation. Nothing is sent to safarimcp to cancel
/// it: see docs/architecture.md for why.
public final class SafariBridge: @unchecked Sendable {
    public static let shared = SafariBridge()
    public static let executable = "/usr/bin/safarimcp"

    /// How requests reach safarimcp: the child process, or a stand-in in tests (`init(exchange:)`).
    typealias Exchange = @Sendable (_ method: String, _ params: Value) async throws -> Value
    private let fake: Exchange?
    /// How long a request waits for earlier abandoned requests that touch the page to finish before it restarts the session.
    private let abandonedGrace: TimeInterval

    public init() { fake = nil; abandonedGrace = Self.abandonedGrace }
    /// A bridge whose requests go to `exchange` instead of a safarimcp process (tests).
    init(exchange: @escaping Exchange, abandonedGrace: TimeInterval = SafariBridge.abandonedGrace) {
        fake = exchange
        self.abandonedGrace = abandonedGrace
    }

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
        /// Requests abandoned earlier (tool names) were still running in Safari when the grace period ended.
        case abandonedStillRunning([String], TimeInterval)

        public var description: String {
            switch self {
            case let .unavailable(why): "Safari automation is unavailable: \(why)"
            case let .timedOut(tool, s): "Safari's automation server didn't answer \(tool) within \(Int(s)) s; the session was restarted (open tabs are gone)."
            case .exited: "Safari's automation server exited; the next call starts a new session (open tabs are gone)."
            case let .abandonedStillRunning(tools, s):
                "An earlier \(tools.joined(separator: ", ")) was abandoned but still running in Safari after \(Int(s)) s, "
                    + "so the session was restarted (open tabs are gone). Retry."
            }
        }
    }

    private let turn = ActionLock()   // one request at a time, in order
    private let occupancy = Occupancy()   // held until a request's code has finished, even after its turn moved on
    private let writer = DedicatedThreads(name: "safari-writer")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    /// Requests awaiting a reply, with the session they were sent on: an old session ending must not fail a new one's.
    private var pending: [Int: (session: Int, continuation: CheckedContinuation<Value, Error>)] = [:]
    /// Every request sent and not yet answered, including the ones whose caller gave up (`abandoned`): safarimcp is
    /// still working on those. A reply, or the session ending, removes the entry.
    private struct Flight { let session: Int; let tool: String; let touchesPage: Bool; var abandoned = false }
    private var inFlight: [Int: Flight] = [:]
    private(set) var stopCount = 0
    private var session = 0
    private var nextID = 1
    private var sessionStarted: Date?
    /// The session whose page-content format may still be markdown, and the markdown read that left it so: the read
    /// is in progress, or its restore failed. A new session starts in the default (text tree) format, so a stale value
    /// is ignored. Each read takes a new mark, and a restore clears only the mark it was started for, never a later
    /// read's.
    private var formatUnknown: (session: Int, mark: UInt64)?
    private var lastMark: UInt64 = 0

    /// The running session's process id and start time, for mac_doctor.
    public var status: (pid: Int32, since: Date)? {
        lock.withLock { process.flatMap { p in sessionStarted.map { (p.processIdentifier, $0) } } }
    }

    /// Tools that change nothing (or only open a page), so they can be retried on a fresh session.
    static let restartable: Set<String> = ["navigate_to_url", "list_tabs", "page_info", "get_page_content", "create_tab",
                                           "browser_dialogs", "browser_console_messages", "list_network_requests"]
    /// Tools whose reply comes in the current page-content format, so the text tree (with uids) must be in place.
    static let formatDependent: Set<String> = ["navigate_to_url", "page_interactions"]
    /// Tools that neither read nor change the page, so they neither wait for an abandoned request nor hold up the next
    /// one. `browser_dialogs` must stay free: answering a dialog is what lets a blocked interaction finish.
    static let pageIndependent: Set<String> = ["list_tabs", "browser_dialogs", "browser_console_messages", "list_network_requests"]
    static let restoreTimeout: TimeInterval = 15
    /// How long a request waits for abandoned requests to finish before the session is restarted.
    static let abandonedGrace: TimeInterval = 20

    /// Calls one safarimcp tool. Throws `BridgeError` when the session can't be used.
    ///
    /// The automation Safari can disappear underneath the session (someone quit Safari, or it crashed); safarimcp
    /// then exits. A call that hit a session like that never ran, so a restartable one is retried once on a new session.
    public func call(_ tool: String, _ arguments: [String: Value] = [:], timeout: TimeInterval = 45) async throws -> Reply {
        try await inTurn("safari:\(tool)", deadline: 2 * timeout + 30 + 2 * Self.restoreTimeout,
                         touchesPage: !Self.pageIndependent.contains(tool)) {
            do {
                if Self.formatDependent.contains(tool) { try await self.restoreTextTreeIfNeeded() }
                return try await self.sendRestartingLostSafari(tool, arguments, timeout: timeout)
            } catch BridgeError.exited where Self.restartable.contains(tool) {
                log("Safari automation session ended; retrying \(tool) on a new one")
                self.stop()
                return try await self.send(tool, arguments, timeout: timeout)
            }
        }
    }

    /// Reads the page as markdown and puts the text-tree format back before the turn ends, as one transaction: a
    /// queued navigate or interaction can't run in between and reply without uids. The restore runs even when the
    /// read is cancelled or fails (on its own task, which the cancellation doesn't reach), and the next request waits
    /// for it even if this one's turn was abandoned; if the restore itself fails, the format stays unknown and the next
    /// format-dependent call restores it first.
    public func readMarkdown(timeout: TimeInterval = 45) async throws -> Reply {
        try await inTurn("safari:get_page_content", deadline: 2 * timeout + 30 + 2 * Self.restoreTimeout) {
            try await self.ensureStarted()
            let mark = self.lock.withLock { () -> UInt64 in
                self.lastMark &+= 1
                self.formatUnknown = (self.session, self.lastMark)
                return self.lastMark
            }
            let result: Result<Reply, Error>
            do {
                result = .success(try await self.sendRestartingLostSafari("get_page_content", ["format": "markdown"], timeout: timeout))
            } catch {
                result = .failure(error)
            }
            await self.restoreTextTree(clearing: mark)
            return try result.get()
        }
    }

    /// Runs `body` in the bridge's turn, once every earlier request's code has finished, including a request whose
    /// turn was abandoned while its cleanup still ran. A request that `touchesPage` also waits for earlier abandoned
    /// requests to be answered (or restarts the session). The waits count toward `deadline`.
    private func inTurn<T: Sendable>(_ name: String, deadline: TimeInterval, touchesPage: Bool = true,
                                     _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await turn.run(name, deadline: deadline + (touchesPage ? abandonedGrace : 0), maxWait: 60) {
            await self.occupancy.acquire()
            let result: Result<T, Error>
            do {
                try Task.checkCancellation()   // abandoned while waiting: don't run late
                if touchesPage { try await self.settleAbandoned() }
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
            await self.occupancy.release()
            return try result.get()
        }
    }

    /// Abandoned requests that touch the page and that safarimcp hasn't answered on the running session.
    private func abandonedOnPage() -> [String] {
        lock.withLock { inFlight.values.filter { $0.session == session && $0.touchesPage && $0.abandoned }.map(\.tool) }
    }

    /// Before a request that touches the page: waits for the replies to requests that were abandoned, so an interaction
    /// whose caller gave up can't keep typing while this one reads or navigates. If they aren't answered within the
    /// grace period the session is restarted (that ends them) and this request fails rather than run on a new, empty one.
    private func settleAbandoned() async throws {
        let limit = ContinuousClock.now + .seconds(abandonedGrace)
        while true {
            let leftover = abandonedOnPage()
            if leftover.isEmpty { return }
            if ContinuousClock.now >= limit {
                log("Safari automation: \(leftover.joined(separator: ", ")) still running after being abandoned; restarting the session")
                stop()
                throw BridgeError.abandonedStillRunning(Array(Set(leftover)).sorted(), abandonedGrace)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Whether the session's page-content format may still be markdown (a restore failed), so the next
    /// format-dependent call sets the text tree first.
    public var needsFormatRestore: Bool {
        lock.withLock { formatUnknown?.session == session }
    }

    /// Sets the text-tree format, however the caller's task stands: cancellation must not skip the restore that
    /// keeps later calls' uids meaningful. Success clears `mark`, if it is still the current one; a failure keeps the
    /// format marked unknown and is logged.
    private func restoreTextTree(clearing mark: UInt64) async {
        let restore = Task { try await self.send("get_page_content", ["format": "textTree"], timeout: Self.restoreTimeout) }
        switch await restore.result {
        case let .success(reply) where !reply.isError:
            lock.withLock { if formatUnknown?.mark == mark { formatUnknown = nil } }
        case let .success(reply):
            log("Safari's page format couldn't be put back to the text tree: \(reply.text.prefix(200))")
        case let .failure(error):
            log("Safari's page format couldn't be put back to the text tree: \(error)")
        }
    }

    /// Before a format-dependent call: repairs a format left unknown by a failed restore, or fails the call rather
    /// than let it reply in the wrong format.
    private func restoreTextTreeIfNeeded() async throws {
        try await ensureStarted()
        guard let mark = lock.withLock({ formatUnknown.flatMap { $0.session == session ? $0.mark : nil } }) else { return }
        await restoreTextTree(clearing: mark)
        if needsFormatRestore {
            throw BridgeError.unavailable("the page couldn't be put back into the text-tree format after a markdown read, "
                + "so its uids can't be trusted; retry, or open a new tab with web_tabs")
        }
    }

    /// `send`, and once more on a new safarimcp when the first one can't reach a Safari. safarimcp outlives the
    /// automation Safari when that is quit or killed mid-session (or crashes), and from then on answers every request
    /// with "Could not create a session" without trying again, so the web tools stayed down until the agent restarted.
    /// No session existed, so nothing ran and any tool can be retried.
    private func sendRestartingLostSafari(_ tool: String, _ arguments: [String: Value], timeout: TimeInterval) async throws -> Reply {
        let reply = try await send(tool, arguments, timeout: timeout)
        guard reply.isError, Self.lostSafari(reply.text) else { return reply }
        log("Safari automation couldn't create a session; starting a new safarimcp and retrying \(tool)")
        stop()
        return try await send(tool, arguments, timeout: timeout)
    }

    /// safarimcp's answer when it can't find or launch a Safari to drive (WebDriverErrorDomain code 6).
    static func lostSafari(_ text: String) -> Bool {
        text.contains("Could not create a session") || (text.contains("WebDriverErrorDomain") && text.contains("Code=6"))
    }

    private func send(_ tool: String, _ arguments: [String: Value], timeout: TimeInterval) async throws -> Reply {
        try await ensureStarted()
        return Self.reply(try await request("tools/call", ["name": .string(tool), "arguments": .object(arguments)],
                                            timeout: timeout, what: tool))
    }

    // MARK: session

    private func ensureStarted() async throws {
        if fake != nil || lock.withLock({ process?.isRunning ?? false }) { return }
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw BridgeError.unavailable("\(Self.executable) not found (needs Safari 27 or later)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.executable)
        let stdin = Pipe(), stdout = Pipe()
        // safarimcp exiting early (Safari gone) must make a write fail with EPIPE, not raise SIGPIPE in this process.
        try StreamIO.configure(stdin.fileHandleForWriting.fileDescriptor)
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
            defer {
                process = nil; input = nil; sessionStarted = nil
                stopCount += 1
                inFlight = inFlight.filter { $0.value.session != session }   // ending the session ends them
            }
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

    /// Sends one request and waits for its reply, however long that takes (callers bound it). If the caller gives up
    /// first, the request stays in `inFlight` as abandoned until safarimcp answers it; a late reply is then dropped.
    private func exchange(_ method: String, _ params: Value) async throws -> Value {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        let tool = method == "tools/call" ? params["name"]?.stringValue ?? method : method
        let touchesPage = method == "tools/call" && !Self.pageIndependent.contains(tool)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Value, Error>) in
                let cancelled = self.lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }   // cancelled before it was sent: nothing is left running
                    self.pending[id] = (self.session, c)
                    self.inFlight[id] = Flight(session: self.session, tool: tool, touchesPage: touchesPage)
                    return false
                }
                if cancelled { c.resume(throwing: CancellationError()); return }
                if let fake {
                    // Like safarimcp, the stand-in isn't told to stop when its caller gives up.
                    Task {
                        do { self.deliver(id, .success(try await fake(method, params))) }
                        catch { self.deliver(id, .failure(error)) }
                    }
                } else {
                    self.write(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
                }
            }
        } onCancel: {
            // Stop waiting, but safarimcp is still working on it until it answers.
            let c = self.lock.withLock { () -> CheckedContinuation<Value, Error>? in
                self.inFlight[id]?.abandoned = true
                return self.pending.removeValue(forKey: id)?.continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// A reply (or the stand-in's failure) for request `id`: the request is no longer in flight, and its caller, if
    /// it is still waiting, gets the result.
    private func deliver(_ id: Int, _ result: Result<Value, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            inFlight.removeValue(forKey: id)
            return pending.removeValue(forKey: id)?.continuation
        }
        c?.resume(with: result)
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
        try await inTurn("safari:page_interactions", deadline: timeout + 30 + 2 * Self.restoreTimeout) {
            try await self.restoreTextTreeIfNeeded()   // its reply comes in the page-content format
            let params: Value = ["name": "page_interactions", "arguments": .object(arguments)]
            let pending = Task { try await self.exchange("tools/call", params) }
            let started = Date()
            do {
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
            } catch {
                // Given up on (cancelled, or past the tool's deadline): the next request waits for safarimcp to finish it.
                pending.cancel()
                throw error
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
        guard let reply = try? await Deadline.run(seconds, { try await task.value }) else {
            task.cancel()   // gave up on it: the next request waits for safarimcp to finish it
            return nil
        }
        return (try? Self.unwrap(reply)).map(Self.reply)
    }

    private func write(_ message: Value) {
        let data = message.jsonData() + Data([0x0A])
        let (handle, current, child) = lock.withLock { (input, session, process) }
        guard let handle else { return }
        writer.async { [self] in
            guard lock.withLock({ session == current && input === handle }) else { return }
            do { try StreamIO.writeAll(handle.fileDescriptor, data, deadline: StreamIO.now + 20) }
            catch { child?.terminate(); failAll(session: current) }
        }
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
                deliver(id, .success(message))
            }
        }
        lock.withLock {
            if self.session == session { process = nil; input = nil; sessionStarted = nil }
        }
        failAll(session: session)
    }

    /// Fails the requests still waiting on a session that has ended.
    private func failAll(session ended: Int) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            inFlight = inFlight.filter { $0.value.session != ended }
            let ids = pending.filter { $0.value.session == ended }.map(\.key)
            return ids.compactMap { pending.removeValue(forKey: $0)?.continuation }
        }
        waiting.forEach { $0.resume(throwing: BridgeError.exited) }
    }
}

/// A first-come, first-served hold on the bridge that, unlike the action lock, is let go only by the code holding it.
/// Waiting isn't cancellable: the holder is a request on its way out, bounded by its own timeouts.
private actor Occupancy {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the hold straight to the next waiter, so it's never free in between for a newcomer to take.
    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
