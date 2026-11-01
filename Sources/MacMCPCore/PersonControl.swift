import CoreGraphics
import Foundation

/// Not an MCP endpoint. Reaching this owner-only socket requires local code execution, like policy approval.
public final class PersonControl: Sendable {
    public enum Command: String, Sendable { case pause, resume, status }
    public static func hotkey(arguments: [String]) throws -> KeySpec {
        var text = "ctrl+alt+shift+cmd+period"
        if let index = arguments.firstIndex(of: "--pause-hotkey") {
            guard arguments.indices.contains(index + 1) else { throw ActionError("--pause-hotkey needs a key spec") }
            text = arguments[index + 1]
        }
        let key = try KeySpec.parse(text)
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        guard key.flags.intersection(modifiers).rawValue.nonzeroBitCount >= 2,
              !key.flags.contains(.maskSecondaryFn), SessionSafety.refusal(keys: [key]) == nil else {
            throw ActionError("The pause hotkey needs at least two modifiers, no fn, and no session shortcut.")
        }
        return key
    }

    public static var socketPath: String { Paths.socket + ".control" }
    public static var statePath: String { Paths.supportDir + "/pause-state" }
    private let state: AgentPause
    private let path: String
    private let socket: String
    private let io = DedicatedThreads(name: "person-control")
    private let cancellation = DedicatedThreads(name: "person-stop")
    private let stopAdditionalWork: @Sendable () -> Void
    private let event: @Sendable (String, String) -> Void

    public init(state: AgentPause = .shared, path: String = PersonControl.statePath,
                socket: String = PersonControl.socketPath,
                stopAdditionalWork: @escaping @Sendable () -> Void = {},
                event: @escaping @Sendable (String, String) -> Void) {
        self.state = state
        self.path = path
        self.socket = socket
        self.event = event
        self.stopAdditionalWork = stopAdditionalWork
    }

    public func pause(source: String) {
        latch(source: source)
        io.async { [self] in
            do { try persist() }
            catch { event("control_error", "Paused in memory, but could not save pause state: \(error)") }
        }
    }

    private func latch(source: String) {
        state.pause()
        cancellation.async { [self] in
            stopAdditionalWork()
            event("pause", "Paused by a person (\(source)). Run `mac-mcp resume` in Terminal to resume.")
        }
    }

    /// Called once at startup, on a native thread, before accepting MCP requests.
    public func start(ready: @escaping @Sendable () -> Void) {
        Thread { [self] in
            do {
                try restore()
                if state.status.paused { event("pause_restored", "MacMCP started paused. Run `mac-mcp resume` in Terminal to resume.") }
            }
            catch {
                state.pause()
                event("control_error", "Pause state could not be restored; agents stay paused: \(error)")
            }
            do {
                let fd = try UnixSocket.listen(path: socket)
                defer { close(fd) }
                ready()
                while true {
                    let peer = accept(fd, nil, nil)
                    if peer < 0 {
                        if errno == EINTR || errno == ECONNABORTED { continue }
                        event("control_error", "Person control accept failed; pausing agents.")
                        pause(source: "control listener failure")
                        return
                    }
                    // One short exchange at a time; socket waits never occupy a shared worker.
                    do {
                        try StreamIO.configure(peer)
                        let line = try Self.readLine(peer, deadline: StreamIO.now + 2)
                        if let command = Command(rawValue: line) {
                            let revision = state.status.revision
                            let respond: @Sendable () -> Void = { [self] in
                                io.async { [self] in
                                    defer { close(peer) }
                                    let reply = apply(command, revision: revision)
                                    try? StreamIO.writeAll(peer, Data((reply + "\n").utf8), deadline: StreamIO.now + 2)
                                }
                            }
                            if command == .resume { cancellation.async(respond) }
                            else { respond() }
                        } else { close(peer) }
                    } catch { close(peer) }
                }
            } catch {
                pause(source: "person control startup failure")
                event("control_error", "Person control unavailable: \(error)")
                ready()   // read-only diagnosis remains available
            }
        }.start()
    }

    /// Only the CLI control listener dispatches commands here. MCP has no control command or resume tool.
    /// Resume leaves the restart latch on disk; it opens only this incarnation's memory latch.
    func apply(_ command: Command, revision expected: UInt64? = nil) -> String {
        switch command {
        case .status: return state.status.summary
        case .pause:
            latch(source: "CLI")
            do { try persist() }
            catch { event("control_error", "Could not save pause state: \(error)") }
        case .resume:
            let revision = expected ?? state.status.revision
            do {
                // Disk stays armed: a crash or automatic restart must never resume a person's pause.
                try persist()
                if state.resumeFromPerson(revision: revision) {
                    event("resume", "Agents resumed by a person (CLI).")
                } else {
                    return AgentPause.refusal + " Another pause arrived during resume; retry."
                }
            } catch {
                state.pause()
                event("control_error", "Could not save resumed state; agents stay paused: \(error)")
                return AgentPause.refusal + " Could not save resumed state."
            }
        }
        return state.status.summary
    }

    func restore() throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try persist()
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let value = String(data: try Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8),
              value == "paused\n" else {
            throw ActionError("Pause state is unreadable or unsafe; a person must run `mac-mcp resume`.")
        }
        state.pause()
    }

    private func persist() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = path + ".tmp-\(UUID().uuidString)"
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlink(temp) }
        try StreamIO.writeAll(fd, Data("paused\n".utf8), deadline: StreamIO.now + 2)
        guard fsync(fd) == 0, rename(temp, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let dir = open(directory, O_RDONLY | O_CLOEXEC)
        guard dir >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(dir) }
        guard fsync(dir) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Synchronous CLI only. No agent tool calls this path.
    public static func request(_ command: Command, socket: String = socketPath) throws -> String {
        let deadline = StreamIO.now + 5
        let fd = try UnixSocket.connect(path: socket, deadline: deadline)
        defer { close(fd) }
        try StreamIO.configure(fd)
        try StreamIO.writeAll(fd, Data((command.rawValue + "\n").utf8), deadline: deadline)
        return try readLine(fd, deadline: deadline)
    }

    private static func readLine(_ fd: Int32, deadline: TimeInterval) throws -> String {
        var data = Data(), byte: UInt8 = 0
        while data.count < 1024 {
            try StreamIO.wait(fd, events: Int16(POLLIN), deadline: deadline)
            let n = read(fd, &byte, 1)
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            guard n == 1 else { throw ActionError("Person control connection closed.") }
            if byte == 10, let line = String(data: data, encoding: .utf8) { return line }
            data.append(byte)
        }
        throw ActionError("Person control frame too long.")
    }
}
