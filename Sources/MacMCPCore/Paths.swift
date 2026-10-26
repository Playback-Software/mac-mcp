import Foundation

/// Fixed locations and identifiers shared by the agent, the CLI and the build script.
public enum Paths {
    public static let bundleID = "com.playbacksoftware.macmcp"
    public static let launchAgentLabel = bundleID

    public static var home: String { NSHomeDirectory() }

    /// The signed app that owns the permission grants. Its path must stay stable across rebuilds.
    public static var app: String { home + "/Applications/MacMCP.app" }
    public static var agentExecutable: String { app + "/Contents/MacOS/MacMCPAgent" }
    public static var cli: String { home + "/.local/bin/mac-mcp" }

    public static var supportDir: String { home + "/Library/Application Support/MacMCP" }
    /// Override with MAC_MCP_SOCKET (tests, or running a second instance).
    public static var socket: String {
        ProcessInfo.processInfo.environment["MAC_MCP_SOCKET"] ?? supportDir + "/mcp.sock"
    }

    public static var logsDir: String { home + "/Library/Logs/MacMCP" }
    public static var agentLog: String { logsDir + "/agent.log" }
    public static var auditLog: String { logsDir + "/audit.jsonl" }

    public static var configDir: String { home + "/.config/mac-mcp" }
    public static var policyFile: String { configDir + "/policy.json" }

    public static var launchAgentPlist: String { home + "/Library/LaunchAgents/\(launchAgentLabel).plist" }
}
