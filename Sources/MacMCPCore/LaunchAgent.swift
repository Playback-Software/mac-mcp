import Foundation

/// Installs and controls the agent's LaunchAgent in the user's GUI domain (`gui/<uid>`).
///
/// `launchctl bootstrap gui/<uid>` works from SSH/Background sessions too, which is what lets the CLI manage
/// the agent remotely. `LimitLoadToSessionType=Aqua` keeps it out of non-GUI sessions.
public enum LaunchAgent {
    public static var domain: String { "gui/\(getuid())" }
    public static var service: String { "\(domain)/\(Paths.launchAgentLabel)" }

    public static func plist(executable: String = Paths.agentExecutable) -> [String: Any] {
        [
            "Label": Paths.launchAgentLabel,
            "ProgramArguments": [executable],
            "AssociatedBundleIdentifiers": Paths.bundleID,
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": Paths.agentLog,
            "StandardErrorPath": Paths.agentLog,
        ]
    }

    public static func writePlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist(), format: .xml, options: 0)
        let url = URL(fileURLWithPath: Paths.launchAgentPlist)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: Paths.logsDir, withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @discardableResult
    public static func launchctl(_ args: String...) -> (status: Int32, output: String) {
        guard let r = try? Subprocess.runBlocking("/bin/launchctl", args, timeout: 30) else { return (-1, "could not run launchctl") }
        return (r.timedOut ? -1 : r.status, [r.stdout, r.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    public static var isLoaded: Bool { launchctl("print", service).status == 0 }

    /// "running (pid N)", "loaded, not running (last exit N)" or "not loaded".
    public static func status() -> String {
        let (code, out) = launchctl("print", service)
        guard code == 0 else { return "not loaded" }
        func field(_ name: String) -> String? {
            out.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(name) =") }
                .map { $0.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
        }
        if let pid = field("pid") { return "running (pid \(pid))" }
        return "loaded, not running (last exit \(field("last exit code") ?? "?"))"
    }

    public static func start() -> (status: Int32, output: String) {
        if isLoaded { return launchctl("kickstart", "-k", service) }
        return launchctl("bootstrap", domain, Paths.launchAgentPlist)
    }

    public static func stop() -> (status: Int32, output: String) {
        guard isLoaded else { return (0, "not loaded") }
        return launchctl("bootout", service)
    }
}
