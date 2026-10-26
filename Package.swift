// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "mac-mcp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "mac-mcp", targets: ["mac-mcp"]),
        .executable(name: "MacMCPAgent", targets: ["MacMCPAgent"]),
    ],
    // No dependencies: MacMCPServer has its own small MCP layer (swift-sdk 0.12.1 was replaced in M7).
    targets: [
        // macOS adapters and testable logic; no MCP dependency.
        .target(name: "MacMCPCore"),
        // MCP layer: protocol (both eras), tool schemas, argument parsing, result formatting.
        .target(
            name: "MacMCPServer",
            dependencies: ["MacMCPCore"]
        ),
        // The binary inside MacMCP.app, run as a LaunchAgent in the GUI session.
        .executableTarget(
            name: "MacMCPAgent",
            dependencies: ["MacMCPCore", "MacMCPServer"]
        ),
        // CLI: stdio relay (default), doctor, install, uninstall, start, stop, status, logs.
        .executableTarget(name: "mac-mcp", dependencies: ["MacMCPCore"]),
        .testTarget(name: "MacMCPCoreTests", dependencies: ["MacMCPCore"]),
        .testTarget(name: "MacMCPServerTests", dependencies: ["MacMCPServer", "MacMCPCore"]),
        // Drives the installed agent against TestHost over its socket. Opt in with MAC_MCP_INTEGRATION=1.
        .testTarget(name: "IntegrationTests", dependencies: ["MacMCPCore"]),
        // Fixture app with known controls for integration tests (scripts/build-testhost.sh bundles it).
        .executableTarget(name: "TestHost", path: "TestHost"),
    ]
)
