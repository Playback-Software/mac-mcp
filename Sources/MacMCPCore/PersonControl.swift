import CoreGraphics
import Foundation

/// Not an MCP endpoint. Reaching this owner-only socket requires local code execution, like policy approval.
public final class PersonControl: Sendable {
    public enum Command: String, Sendable { case pause, resume, status }
    // Control-Shift-Command-backslash: no assignment in the checked Apple/system/accessibility, Xcode,
    // VS Code or Chrome defaults (see the documented shortcut review). Omitting Option avoids VoiceOver's
    // Control-Option commands; no fn is needed. Four modifiers + period starts sysdiagnose, and + K is
    // VoiceOver's previous colour change, so a four-modifier chord alone is no assurance of availability.
    public static let defaultHotkey = "ctrl+shift+cmd+backslash"
    public static func hotkey(arguments: [String]) throws -> KeySpec {
        var text = defaultHotkey
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
        // Refuse even optional/disabled system bindings: enabling Accessibility later must stay safe.
        let system = [
            "ctrl+alt+shift+cmd+period", // sysdiagnose(1), not listed by symbolic hotkeys
            "ctrl+alt+cmd+period", "ctrl+alt+cmd+comma", "ctrl+alt+shift+cmd+comma", // contrast
            "ctrl+alt+cmd+8", // invert colours
            "ctrl+alt+shift+cmd+k", // VoiceOver: find previous colour change
            "alt+cmd+escape", "alt+shift+cmd+escape", // force quit
            "alt+cmd+f5", "ctrl+alt+cmd+f5", // Accessibility panel / VoiceOver
            "cmd+f5", "ctrl+cmd+space", "ctrl+alt+space", "alt+cmd+space", // VoiceOver, emoji, input, search
            "alt+cmd+d", "ctrl+cmd+f", // Dock, full screen
            "alt+cmd+8", "alt+cmd+equals", "alt+cmd+minus", // Zoom
            "cmd+shift+3", "cmd+shift+4", "cmd+shift+5", "cmd+shift+6",
            "ctrl+cmd+shift+3", "ctrl+cmd+shift+4", // screenshots to clipboard
        ]
        guard try !system.contains(where: { try KeySpec.parse($0) == key }) else {
            throw ActionError("The pause hotkey conflicts with a known macOS system shortcut; choose another chord.")
        }
        return key
    }

    public static var socketPath: String { Paths.socket + ".control" }
    /// Validate both before startup writes state or accepts tools. sun_path includes the terminating NUL.
    public static func validateSocketPaths(mcpSocket: String = Paths.socket) throws {
        try UnixSocket.validatePath(mcpSocket)
        do { try UnixSocket.validatePath(mcpSocket + ".control") }
        catch { throw ActionError("MAC_MCP_SOCKET leaves no room for the .control socket (maximum MCP path: 95 UTF-8 bytes). Choose a shorter socket path.") }
    }
    public static var statePath: String { Paths.supportDir + "/pause-state" }

    public static func hotkeyLabel(_ key: KeySpec) -> String {
        let names = KeySpec.keyCodes.filter { $0.value == key.key }.map(\.key).sorted()
        let name = names.first { $0.count > 1 } ?? names.first ?? "keycode \(key.key)"
        return KeySpec.describe(key.flags) + "+" + name
    }

    public static func activityLabel(_ label: String) -> String {
        let clean = String(label.prefix(256).filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        if let session = clean.range(of: " (session ") {
            let client = clean[..<session.lowerBound]
            let id = clean[session.upperBound...].prefix(8)
            return String(client.prefix(28)) + " · " + id
        }
        guard clean.count > 48 else { return clean }
        return String(clean.prefix(23)) + "…" + clean.suffix(24)
    }
    private let state: AgentPause
    private let path: String
    private let socket: String
    private let io = DedicatedThreads(name: "person-control")
    private let restored = Locked(false)
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

    public func pause(source: String, reason: String = "Paused by a person") {
        latch(source: source, reason: reason)
        io.async { [self] in
            // Registration can fail before startup restoration. Merge that pause with the saved revision first,
            // instead of overwriting a newer on-disk revision with this incarnation's initial counter.
            guard restored.withLock({ $0 }) else { return }
            do { try persist() }
            catch { event("control_error", "Paused in memory, but could not save pause state: \(error)") }
        }
    }

    private func latch(source: String, reason: String = "Paused by a person") {
        state.pause(reason: reason)
        cancellation.async { [self] in
            stopAdditionalWork()
            event("pause", "\(reason) (\(source)). Run `mac-mcp resume` in Terminal to resume.")
        }
    }

    /// Called once at startup, on a native thread, before accepting MCP requests.
    public func start(ready: @escaping @Sendable () -> Void) {
        io.async { [self] in
            do {
                try restore()
                if state.status.paused { event("pause_restored", "MacMCP started paused. " + state.status.summary) }
            }
            catch {
                event("control_error", "Pause state could not be restored; agents stay paused: \(error)")
            }
            Thread { [self] in listen(ready: ready) }.start()
        }
    }

    private func listen(ready: @escaping @Sendable () -> Void) {
        do {
            let fd = try UnixSocket.listen(path: socket)
            defer { close(fd) }
            ready()
            while true {
                let peer = accept(fd, nil, nil)
                if peer < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    event("control_error", "Person control accept failed; pausing agents.")
                    pause(source: "control listener failure", reason: "Paused because the person control listener failed")
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
            pause(source: "person control startup failure", reason: "Paused because person control is unavailable")
            event("control_error", "Person control unavailable: \(error)")
            ready()   // read-only diagnosis remains available
        }
    }

    /// Only the CLI control listener dispatches commands here. MCP has no control command or resume tool.
    /// Runs on the serial I/O worker. A newer hotkey pause always wins over an already received resume.
    func apply(_ command: Command, revision expected: UInt64? = nil) -> String {
        switch command {
        case .status: return state.status.controlSummary
        case .pause:
            latch(source: "CLI")
            do { try persist() }
            catch { event("control_error", "Could not save pause state: \(error)") }
        case .resume:
            let revision = expected ?? state.status.revision
            do {
                guard state.status.revision == revision else {
                    return state.status.controlSummary + " Another pause arrived during resume; retry."
                }
                try persist(SavedState(state: "running", revision: revision &+ 1, reason: nil))
                if state.resumeFromPerson(revision: revision) {
                    event("resume", "Agents resumed by a person (CLI).")
                } else {
                    try persist()
                    return state.status.controlSummary + " Another pause arrived during resume; retry."
                }
            } catch {
                state.pause(reason: "Paused because the resumed state could not be saved")
                try? persist()
                event("control_error", "Could not save resumed state; agents stay paused: \(error)")
                return state.status.controlSummary
            }
        }
        return state.status.controlSummary
    }

    func restore() throws {
        defer { restored.withLock { $0 = true } }
        do { try restoreSavedState() }
        catch {
            state.pause(reason: "Paused because pause state could not be restored: \(error)")
            throw error
        }
    }

    private struct SavedState: Codable {
        let state: String
        let revision: UInt64
        let reason: String?
    }

    private func restoreSavedState() throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try persist()
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ActionError("saved file is not a private, owner-owned regular file")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data == Data("paused\n".utf8) { // migrate the earlier pause-only latch conservatively
            state.restore(paused: true, revision: 1, reason: "Paused from the saved stop state")
        } else {
            guard let saved = try? JSONDecoder().decode(SavedState.self, from: data),
                  ["paused", "running"].contains(saved.state), saved.revision < UInt64.max,
                  saved.reason.map({ $0.count <= 512 && !$0.contains(where: { $0.isNewline }) }) ?? true else {
                throw ActionError("saved file is corrupt or has an unsupported state/revision")
            }
            state.restore(paused: saved.state == "paused", revision: saved.revision,
                          reason: saved.reason ?? "Paused from the saved stop state")
        }
        try persist()
    }

    private func persist(_ saved: SavedState? = nil) throws {
        let current = state.status
        let saved = saved ?? SavedState(state: current.paused ? "paused" : "running", revision: current.revision,
                                       reason: current.paused ? current.reason : nil)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = path + ".tmp-\(UUID().uuidString)"
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlink(temp) }
        let data = try JSONEncoder().encode(saved)
        try StreamIO.writeAll(fd, data, deadline: StreamIO.now + 2)
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
