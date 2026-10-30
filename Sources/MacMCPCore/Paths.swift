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
    /// A readable copy of the approved policy. Never consulted: the approved policy itself is kept in the login
    /// keychain (`approvalKeychainService`), where the apps agents drive can't change it.
    public static var approvedPolicyFile: String { supportDir + "/policy.approved.json" }
    /// The service of the login-keychain items holding the records of the approved policy, one per record; the newest
    /// is the last policy a person approved (or that tightened the one before). Enforced while policy.json is missing
    /// or has changes that loosen it, until a person runs `mac-mcp policy approve`.
    public static let approvalKeychainService = bundleID + ".policy-approval"
    /// A root-owned policy that, when present and not writable by others, replaces the user's policy entirely.
    public static let managedPolicyDir = "/Library/Application Support/MacMCP"
    public static var managedPolicyFile: String { managedPolicyDir + "/policy.json" }

    /// The dedicated signing keychain and its password file (scripts/setup-signing.sh).
    public static var signingKeychain: String { home + "/Library/Keychains/mac-mcp-signing.keychain-db" }
    public static var signingKeychainPass: String { configDir + "/signing-keychain.pass" }

    public static var launchAgentPlist: String { home + "/Library/LaunchAgents/\(launchAgentLabel).plist" }
}
