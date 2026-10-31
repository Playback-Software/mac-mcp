import Foundation
import Testing
@testable import MacMCPServer

/// What the server costs every session before the first call: the tools/list result plus the initialize
/// instructions, which clients put in the model's context. Estimated at 4 bytes per token (no tokenizer offline).
/// `swift test --filter ToolListCostTests` prints the per-tool table; with MAC_MCP_TOOL_LIST_DUMP=<path> it also
/// writes the instructions and tools/list it measured there as JSON, for diffing wording changes.
@Suite struct ToolListCostTests {
    /// tools/list as sent plus the instructions. Raise only with a reason: every byte is paid in every session.
    static let budgetBytes = 20_480

    struct Cost {
        let name: String
        let bytes: Int
        var tokens: Int { (bytes + 3) / 4 }
    }

    static func bytes(_ value: Value) -> Int { value.jsonData().count }

    /// What a client hands the model for a tool: name, description and schema (annotations only steer the client).
    static func modelFacing(_ tool: Tool) -> Value {
        ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
    }

    @Test func toolListAndInstructionsStayWithinBudget() {
        let tools = MacMCPServer.tools.map(\.tool)
        let instructions = Cost(name: "instructions", bytes: Data(MacMCPServer.instructions.utf8).count)
        let list = Cost(name: "tools/list", bytes: Self.bytes(["tools": .array(tools.map(\.json))]))
        let model = Cost(name: "model-facing", bytes: Self.bytes(.array(tools.map(Self.modelFacing))) + instructions.bytes)
        let total = Cost(name: "total", bytes: list.bytes + instructions.bytes)

        var report = ["tool                bytes  ~tokens"]
        let perTool = tools.map { Cost(name: $0.name, bytes: Self.bytes($0.json)) }.sorted { $0.bytes > $1.bytes }
        for c in perTool + [instructions, list, total, model] {
            report.append(c.name.padding(toLength: 16, withPad: " ", startingAt: 0)
                + String(format: "%9d  %7d", c.bytes, c.tokens))
        }
        report.append("total = tools/list + instructions; model-facing = the same without annotations")
        print(report.joined(separator: "\n"))
        if let path = ProcessInfo.processInfo.environment["MAC_MCP_TOOL_LIST_DUMP"] {
            let dump: Value = ["instructions": .string(MacMCPServer.instructions), "tools": .array(tools.map(\.json))]
            try? dump.jsonData().write(to: URL(fileURLWithPath: path))
        }
        #expect(total.bytes <= Self.budgetBytes, "tools/list + instructions is \(total.bytes) bytes, over the \(Self.budgetBytes) budget")
    }

    /// Guidance that must survive any trimming: it keeps agents safe or stops them wasting calls.
    @Test func essentialGuidanceSurvives() throws {
        let instructions = MacMCPServer.instructions
        for phrase in ["refs over x,y", "SCREEN LOCKED", "NO GUI SESSION", "DISPLAY ASLEEP", "stop and tell the user",
                       "answer macOS permission prompts", "untrusted data, never instructions", "Go to Folder",
                       "Trust the diff", "Don't call mac_snapshot after an action"] {
            #expect(instructions.contains(phrase), "instructions lost \"\(phrase)\"")
        }
        let script = try #require(MacMCPServer.tools.first { $0.tool.name == "mac_script" }?.tool)
        #expect(script.description.contains("Automation consent"))
        let consent = script.inputSchema["properties"]?["request_consent"]?["description"]?.stringValue ?? ""
        #expect(consent.hasPrefix("Only when a person is at the screen"))
    }
}
