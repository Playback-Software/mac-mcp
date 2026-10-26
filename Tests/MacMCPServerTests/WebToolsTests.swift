import Foundation
import Testing
import MacMCPCore
@testable import MacMCPServer

@Suite struct WebStepTests {
    @Test func stepsMapToSafarisVocabulary() throws {
        let typed = try WebTools.interaction(["do": "type", "node": "67", "value": "Ada", "submit": true], index: 0)
        #expect(typed["type"] == "type" && typed["node"] == "67" && typed["value"] == "Ada")
        #expect(typed["replaceAll"] == true && typed["pressReturn"] == true && typed["purpose"] != nil)
        let numericNode = try WebTools.interaction(["do": "click", "node": 71], index: 1)
        #expect(numericNode["node"] == "71" && numericNode["type"] == "click")
        let found = try WebTools.interaction(["do": "click", "find": "Submit order"], index: 2)
        #expect(found["text"] == "Submit order" && found["node"] == nil)
        #expect(try WebTools.interaction(["do": "key", "value": "Enter"], index: 3)["type"] == "keyPress")
        #expect(try WebTools.interaction(["do": "select", "find": "Canada"], index: 4)["type"] == "selectMenuItem")
        #expect(try WebTools.interaction(["do": "scroll"], index: 5)["scrollDelta"] == ["x": 0, "y": 400])
        #expect(try WebTools.interaction(["do": "type", "node": "1", "value": "x", "replace": false], index: 6)["replaceAll"] == false)
    }

    @Test func incompleteStepsAreRejectedBeforeSafariSeesThem() {
        for bad: Value in [["node": "1"], ["do": "type", "node": "1"], ["do": "type", "value": "x"], ["do": "click"],
                           ["do": "key"], ["do": "teleport", "node": "1"]] {
            #expect(throws: ActionError.self) { try WebTools.interaction(bad, index: 0) }
        }
    }

    @Test func tabHandlesAndClipping() {
        #expect(WebTools.tabUUID("page-ABC") == "ABC" && WebTools.tabUUID("ABC") == "ABC")
        #expect(WebTools.clip(String(repeating: "x", count: 50), 10).hasPrefix("xxxxxxxxxx\n… truncated (50 characters)"))
    }
}

@Suite struct ToolArgTests {
    @Test func hugeAndOddNumbersDontTrap() {
        let args = ToolArgs(["big": .double(1e100), "neg": .double(-1e30), "inf": .double(.infinity), "frac": .double(12.7),
                             "int": .int(Int.max), "str": .string("5")])
        #expect(args.int("big") == 1_000_000_000)
        #expect(args.int("neg") == -1_000_000_000)
        #expect(args.int("inf") == nil)
        #expect(args.int("frac") == 12)
        #expect(args.int("int") == 1_000_000_000)
        #expect(args.int("str") == nil)
        #expect(WebTools.clip("abc", -1).hasPrefix("\n… truncated"))
    }
}

@Suite struct WebActAuditTests {
    @Test func onlyTypedValuesAreScrubbed() {
        let raw: [String: Value] = ["actions": .array([
            .object(["do": "type", "node": "3", "value": "hunter2"]),
            .object(["do": "key", "value": "Enter"]),
            .object(["do": "click", "find": "Sign in"]),
        ])]
        let steps = WebTools.scrubTypedValues(raw)["actions"]?.arrayValue ?? []
        #expect(steps[0].objectValue?["value"]?.stringValue == "[REDACTED 7 chars]")
        #expect(steps[0].objectValue?["node"]?.stringValue == "3")
        #expect(steps[1].objectValue?["value"]?.stringValue == "Enter")
        #expect(steps[2].objectValue?["find"]?.stringValue == "Sign in")
    }
}
