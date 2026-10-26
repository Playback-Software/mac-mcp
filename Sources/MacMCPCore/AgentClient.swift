import Darwin
import Foundation

/// A minimal MCP client for the agent's socket: initialize once, then call tools. Used by the CLI (`doctor`,
/// `call`) and the integration tests. Not a general MCP client.
public final class AgentClient {
    public struct ToolResult {
        public let content: [[String: Any]]
        public let isError: Bool
        public var text: String { content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        public var images: [Data] {
            content.filter { $0["type"] as? String == "image" }.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        }
    }

    private let input: Int32
    private let output: Int32
    private let timeout: TimeInterval
    private var pending = Data()
    private var nextID = 2

    /// Connects to the agent's socket.
    /// Presents `lease` (default: this process's MAC_MCP_LEASE) so its calls may act while that lease is held.
    public convenience init(clientName: String, version: String, path: String = Paths.socket, timeout: TimeInterval = 30,
                            lease: String? = LeaseStore.ownToken) throws {
        let fd = try UnixSocket.connect(path: path)
        if let line = AgentClient.directive(lease: lease) {
            guard line.withUnsafeBytes({ write(fd, $0.baseAddress, line.count) }) == line.count else {
                close(fd)
                throw SocketError("write", path: path)
            }
        }
        try self.init(clientName: clientName, version: version, input: fd, output: fd, timeout: timeout)
    }

    /// The line a client sends before any JSON-RPC: a GUI lease token (see `Lease`), and for the relay, where the
    /// session comes from and a session id that stays the same across agent restarts (for the usage report).
    public static func directive(lease: String?, origin: String? = nil, session: String? = nil) -> Data? {
        let fields = [lease.map { "lease=\($0)" }, origin.map { "origin=\($0)" }, session.map { "session=\($0)" }]
            .compactMap { $0 }
        return fields.isEmpty ? nil : Data(("#mac-mcp " + fields.joined(separator: " ") + "\n").utf8)
    }

    /// Where the MCP client runs: `ssh:<client address>` when the relay is the SSH command itself (a client on another
    /// machine ran `ssh <host> mac-mcp`), else `local`. SSH_CONNECTION alone isn't enough: a client started on this
    /// Mac from an SSH terminal inherits it too, but then the relay's parent is that client, not sshd.
    public static func origin(environment: [String: String] = ProcessInfo.processInfo.environment,
                              ancestors: [String] = processAncestors()) -> String {
        guard let conn = environment["SSH_CONNECTION"], let address = conn.split(separator: " ").first else { return "local" }
        let shells: Set = ["sh", "bash", "zsh", "dash", "fish", "login"]
        for name in ancestors where !shells.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) {
            return name.hasPrefix("sshd") ? "ssh:\(address)" : "local"
        }
        return "local"
    }

    /// Names of this process's parent, grandparent, … (up to `limit`).
    public static func processAncestors(limit: Int = 4) -> [String] {
        var names: [String] = []
        var pid = getppid()
        for _ in 0..<limit where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            names.append(name)
            pid = pid_t(info.pbi_ppid)
        }
        return names
    }

    /// A short random session id.
    public static func newSessionID() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    /// Talks MCP over any pair of descriptors (e.g. pipes to a `mac-mcp relay` process), taking ownership of them.
    public init(clientName: String, version: String, input: Int32, output: Int32, timeout: TimeInterval = 30) throws {
        self.input = input
        self.output = output
        self.timeout = timeout
        // Follow the protocol: wait for the initialize result before sending anything else.
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": ["protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any],
                             "clientInfo": ["name": clientName, "version": version]]])
        _ = try response(id: 1)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    deinit {
        close(input)
        if output != input { close(output) }
    }

    public func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> ToolResult {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let msg = try response(id: id)
        if let error = msg["error"] as? [String: Any] {
            return ToolResult(content: [["type": "text", "text": "protocol error: \(error["message"] ?? error)"]], isError: true)
        }
        let result = msg["result"] as? [String: Any]
        return ToolResult(content: result?["content"] as? [[String: Any]] ?? [], isError: result?["isError"] as? Bool ?? false)
    }

    public func listTools() throws -> [String] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": "tools/list"])
        let tools = ((try response(id: id))["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        let written = data.withUnsafeBytes { write(output, $0.baseAddress, data.count) }
        guard written == data.count else { throw SocketError("write", path: Paths.socket) }
    }

    /// Reads newline-delimited JSON-RPC messages until the response with `id` arrives.
    private func response(id: Int) throws -> [String: Any] {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any], msg["id"] as? Int == id {
                    return msg
                }
            }
            var pfd = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, Int32(timeout * 1000)) > 0 ? read(input, &buffer, buffer.count) : -1
            guard n > 0 else { throw SocketError("read (timed out or closed)", path: Paths.socket) }
            pending.append(contentsOf: buffer[0..<n])
        }
    }
}
