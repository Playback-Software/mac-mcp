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

// MARK: a markdown read and the restore of the text tree are one transaction

/// A gate a fake can block on until the test releases it; waiting honours cancellation.
private actor Gate {
    private var open = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        if open { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters[id] = c
                if Task.isCancelled { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }

    func release() {
        open = true
        for (_, c) in waiters { c.resume() }
        waiters = [:]
    }
}

/// A stand-in for safarimcp: it remembers the page-content format the way Safari does (that of the last
/// get_page_content call), answers navigate_to_url in that format, and can hold the markdown reply until released.
private final class FakeSafari: @unchecked Sendable {
    private let lock = NSLock()
    private var format = "textTree"
    private(set) var calls: [String] = []
    var failRestore = false
    /// Outcomes for the next restores, in order (true: it fails); `failRestore` once they run out.
    var restoreFailures: [Bool] = []
    /// While set, a restore waits for `restoreGate` before it answers.
    var holdRestore = false
    let markdownGate = Gate()
    /// While set, a page_interactions request keeps "running" until `interactionGate` opens, like a click sequence in Safari.
    var holdInteraction = false
    /// While set, browser_dialogs lists one open dialog.
    var dialogOpen = false
    let interactionGate = Gate()
    let restoreGate = Gate()
    /// How many more tool calls answer as a safarimcp that lost its Safari ("Could not create a session").
    var lostSafariReplies = 0

    private func record(_ call: String) { lock.withLock { calls.append(call) } }
    var callLog: [String] { lock.withLock { calls } }

    func exchange(_ method: String, _ params: Value) async throws -> Value {
        let tool = params["name"]?.stringValue ?? method
        let args = params["arguments"]
        func text(_ s: String) -> Value { ["result": ["content": [["type": "text", "text": .string(s)]]]] }
        let lost = lock.withLock { () -> Bool in
            guard lostSafariReplies > 0 else { return false }
            lostSafariReplies -= 1
            return true
        }
        if lost {
            record("lost:\(tool)")
            return ["result": ["isError": true, "content": [["type": "text", "text": .string(
                "Tool error: Error Domain=WebDriverErrorDomain Code=6 \"Could not create a session: The session timed out while "
                + "connecting to a Safari instance.\"")]]]]
        }
        switch tool {
        case "get_page_content":
            let wanted = args?["format"]?.stringValue ?? "textTree"
            record("get_page_content:\(wanted)")
            if wanted == "markdown" {
                lock.withLock { format = "markdown" }
                try await markdownGate.wait()   // the reply is held until the test lets it through
                return text("# Heading\n\nSome article text.")
            }
            if lock.withLock({ holdRestore }) { try await restoreGate.wait() }
            let fail = lock.withLock { restoreFailures.isEmpty ? failRestore : restoreFailures.removeFirst() }
            if fail { return ["error": ["message": "no active tab"]] }
            lock.withLock { format = "textTree" }
            return text("{\"text\":\"heading uid=1 Heading\"}")
        case "page_interactions":
            record(tool)
            if lock.withLock({ holdInteraction }) {
                try await interactionGate.wait()
                record("page_interactions:finished")
            }
            fallthrough
        case "navigate_to_url":
            if tool == "navigate_to_url" { record(tool) }
            let current = lock.withLock { format }
            return text(current == "textTree" ? "{\"url\":\"https://example.test/\",\"text\":\"link uid=2 Example\"}"
                                              : "# Example\n\nmarkdown without uids")
        case "browser_dialogs":
            return text(lock.withLock { dialogOpen } ? "{\"dialogs\":[{\"message\":\"Sure?\"}]}" : "{\"dialogs\":[]}")
        default:
            record(tool)
            return text("{}")
        }
    }

    /// Waits until the fake has seen `call`.
    func seen(_ call: String) async -> Bool {
        await waitUntil("the fake to see \(call)") { callLog.contains(call) }
        return callLog.contains(call)
    }
}

@Suite struct WebFormatTransactionTests {
    /// A navigate queued while a markdown read is in flight must not run between the read and the restore: it
    /// would reply in markdown, without the uids web_act needs.
    @Test(.timeLimit(.minutes(1))) func aQueuedNavigateWaitsForTheTextTreeToBeRestored() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        let markdown = Task { try await bridge.readMarkdown(timeout: 10) }
        #expect(await safari.seen("get_page_content:markdown"))
        let navigate = Task { try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))   // let the navigate queue behind the read
        #expect(!safari.callLog.contains("navigate_to_url"), "the navigate ran while markdown was the active format")
        await safari.markdownGate.release()
        #expect(try await markdown.value.text.hasPrefix("# Heading"))
        let page = try await navigate.value
        #expect(page.text.contains("uid=2"), "the navigate replied without uids: \(page.text)")
        #expect(safari.callLog == ["get_page_content:markdown", "get_page_content:textTree", "navigate_to_url"])
        #expect(!bridge.needsFormatRestore)
    }

    /// Cancelling the markdown read must not skip the restore, or every later call would come back as markdown.
    @Test(.timeLimit(.minutes(1))) func aCancelledMarkdownReadStillRestoresTheTextTree() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        let markdown = Task { try await bridge.readMarkdown(timeout: 10) }
        #expect(await safari.seen("get_page_content:markdown"))
        markdown.cancel()
        await #expect(throws: CancellationError.self) { try await markdown.value }
        #expect(await safari.seen("get_page_content:textTree"), "the restore was skipped after the cancellation")
        // The navigate waits for the restore to finish, and for Safari to answer the abandoned read; it needn't repair anything.
        await safari.markdownGate.release()
        let page = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
        #expect(page.text.contains("uid=2") && !bridge.needsFormatRestore)
        #expect(safari.callLog == ["get_page_content:markdown", "get_page_content:textTree", "navigate_to_url"])
    }

    /// A cancelled read's turn ends at once, but its restore is still on its way: the next read must wait for it.
    /// Otherwise the two transactions interleave, and the first restore's late success clears the second read's mark,
    /// so a failure of the second restore would go unnoticed and later calls would reply without uids.
    @Test(.timeLimit(.minutes(1))) func aCancelledReadsRestoreFinishesBeforeTheNextReadStarts() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        safari.holdRestore = true
        safari.restoreFailures = [false, true]   // the first read's restore works; the second's doesn't
        let first = Task { try await bridge.readMarkdown(timeout: 10) }
        #expect(await safari.seen("get_page_content:markdown"))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await safari.seen("get_page_content:textTree"))   // its restore is under way, held by the fake
        await safari.markdownGate.release()
        let second = Task { try await bridge.readMarkdown(timeout: 10) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(safari.callLog == ["get_page_content:markdown", "get_page_content:textTree"],
                "the second read started while the first one's restore was pending")
        safari.holdRestore = false
        await safari.restoreGate.release()
        #expect(try await second.value.text.hasPrefix("# Heading"))
        #expect(safari.callLog == ["get_page_content:markdown", "get_page_content:textTree",
                                   "get_page_content:markdown", "get_page_content:textTree"])
        #expect(bridge.needsFormatRestore, "the second restore failed, so the format must still be marked unknown")
        // So the next navigate repairs it first, and replies with uids.
        let page = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
        #expect(page.text.contains("uid=2"), "the navigate replied without uids: \(page.text)")
        #expect(safari.callLog.suffix(3) == ["get_page_content:textTree", "get_page_content:textTree", "navigate_to_url"])
    }

    /// A restore that fails is remembered: the next format-dependent call sets the text tree first, and fails
    /// rather than run if that doesn't work either.
    @Test(.timeLimit(.minutes(1))) func aFailedRestoreIsRetriedBeforeTheNextFormatDependentCall() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        safari.failRestore = true
        await safari.markdownGate.release()
        _ = try await bridge.readMarkdown(timeout: 10)
        #expect(bridge.needsFormatRestore, "a failed restore must leave the format marked unknown")
        await #expect(throws: SafariBridge.BridgeError.self) {
            _ = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
        }
        #expect(!safari.callLog.contains("navigate_to_url"), "a navigate must not run in an unknown format")
        // A call that doesn't depend on the format isn't held up.
        _ = try await bridge.call("list_tabs", timeout: 10)
        safari.failRestore = false
        let page = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
        #expect(page.text.contains("uid=2") && !bridge.needsFormatRestore)
        #expect(safari.callLog.suffix(2) == ["get_page_content:textTree", "navigate_to_url"])
        // The interaction path repairs the format the same way.
        safari.failRestore = true
        _ = try await bridge.readMarkdown(timeout: 10)
        safari.failRestore = false
        guard case let .done(reply) = try await bridge.interact(["interactions": []], timeout: 10) else { Issue.record("expected a reply"); return }
        #expect(reply.text.contains("uid=2") && safari.callLog.suffix(2) == ["get_page_content:textTree", "page_interactions"])
    }
}

// MARK: an abandoned request is still running in Safari

@Suite struct WebAbandonedRequestTests {
    /// A web_act whose caller gave up keeps running in Safari. The next request must not start beside it: it waits for
    /// the interaction's reply.
    @Test(.timeLimit(.minutes(1))) func anAbandonedInteractionFinishesBeforeTheNextRequestStarts() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        safari.holdInteraction = true
        let act = Task { try await bridge.interact(["interactions": []], timeout: 10) }
        #expect(await safari.seen("page_interactions"))
        act.cancel()
        await #expect(throws: CancellationError.self) { _ = try await act.value }
        let navigate = Task { try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!safari.callLog.contains("navigate_to_url"), "the navigate started while the abandoned interaction was running")
        await safari.interactionGate.release()
        #expect(try await navigate.value.text.contains("uid=2"))
        #expect(safari.callLog == ["page_interactions", "page_interactions:finished", "navigate_to_url"])
        #expect(bridge.stopCount == 0, "a request that finished in time must not restart the session")
    }

    /// The same when the tool's deadline, not a cancellation, abandons the interaction.
    @Test(.timeLimit(.minutes(1))) func anInteractionPastItsDeadlineIsWaitedForToo() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        safari.holdInteraction = true
        let act = Task { try await Deadline.run(0.3) { try await bridge.interact(["interactions": []], timeout: 10) } }
        #expect(try await act.value == nil)
        let read = Task { try await bridge.call("get_page_content", ["format": "textTree"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!safari.callLog.contains("get_page_content:textTree"))
        await safari.interactionGate.release()
        _ = try await read.value
        #expect(safari.callLog == ["page_interactions", "page_interactions:finished", "get_page_content:textTree"])
    }

    /// An abandoned request that Safari never answers can't be waited for forever: the session is restarted, which
    /// ends it, and the request that waited says so. The call after that runs on the new session.
    @Test(.timeLimit(.minutes(1))) func anAbandonedInteractionThatNeverAnswersRestartsTheSession() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange, abandonedGrace: 0.3)
        safari.holdInteraction = true
        let act = Task { try await bridge.interact(["interactions": []], timeout: 10) }
        #expect(await safari.seen("page_interactions"))
        act.cancel()
        await #expect(throws: CancellationError.self) { _ = try await act.value }
        do {
            _ = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
            Issue.record("the navigate ran beside an interaction that was still going")
        } catch let error as SafariBridge.BridgeError {
            #expect("\(error)".contains("page_interactions") && "\(error)".contains("restarted"), "\(error)")
        }
        #expect(bridge.stopCount == 1)
        #expect(!safari.callLog.contains("navigate_to_url"))
        let page = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
        #expect(page.text.contains("uid=2") && bridge.stopCount == 1)
        await safari.interactionGate.release()   // the old session's reply arrives late, and changes nothing
    }

    /// Dialogs and tab lists don't touch the page: they must work while an interaction is abandoned (answering a
    /// dialog is how a blocked interaction gets to finish), and they aren't held up for it.
    @Test(.timeLimit(.minutes(1))) func requestsThatDontTouchThePageDontWait() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange, abandonedGrace: 0.3)
        safari.holdInteraction = true
        let act = Task { try await bridge.interact(["interactions": []], timeout: 10) }
        #expect(await safari.seen("page_interactions"))
        act.cancel()
        await #expect(throws: CancellationError.self) { _ = try await act.value }
        _ = try await bridge.call("browser_dialogs", ["action": "list"], timeout: 10)
        _ = try await bridge.call("list_tabs", timeout: 10)
        #expect(bridge.stopCount == 0)
        await safari.interactionGate.release()
    }

    /// An interaction parked behind a dialog that doesn't finish after the dialog is answered is abandoned too.
    @Test(.timeLimit(.minutes(1))) func aParkedInteractionThatDoesntFinishIsWaitedFor() async throws {
        let safari = FakeSafari()
        let bridge = SafariBridge(exchange: safari.exchange)
        safari.holdInteraction = true
        safari.dialogOpen = true
        guard case .dialog = try await bridge.interact(["interactions": []], timeout: 10) else { Issue.record("expected a dialog"); return }
        #expect(await bridge.finishParked(within: 0.2) == nil)
        let navigate = Task { try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!safari.callLog.contains("navigate_to_url"))
        await safari.interactionGate.release()
        _ = try await navigate.value
        #expect(safari.callLog.suffix(2) == ["page_interactions:finished", "navigate_to_url"])
    }
}

@Suite struct WebLostSafariTests {
    /// safarimcp outlives an automation Safari that was quit or killed and then refuses every request; the bridge
    /// starts a new one and retries once, instead of leaving the web tools down until the agent restarts.
    @Test(.timeLimit(.minutes(1))) func aSafarimcpThatLostItsSafariIsRestartedAndTheCallRetried() async throws {
        let safari = FakeSafari()
        safari.lostSafariReplies = 1
        let bridge = SafariBridge(exchange: safari.exchange)
        let page = try await bridge.call("navigate_to_url", ["url": "https://example.test/"], timeout: 10)
        #expect(!page.isError && page.text.contains("uid=2"), "\(page.text)")
        #expect(safari.callLog == ["lost:navigate_to_url", "navigate_to_url"])
        #expect(bridge.stopCount == 1)
    }

    /// A second refusal in a row is reported, not retried again.
    @Test(.timeLimit(.minutes(1))) func itIsRetriedOnlyOnce() async throws {
        let safari = FakeSafari()
        safari.lostSafariReplies = 2
        let bridge = SafariBridge(exchange: safari.exchange)
        let page = try await bridge.call("list_tabs", [:], timeout: 10)
        #expect(page.isError && SafariBridge.lostSafari(page.text))
        #expect(safari.callLog == ["lost:list_tabs", "lost:list_tabs"])
    }

    @Test func otherErrorsAreNotTakenForALostSafari() {
        #expect(!SafariBridge.lostSafari("Tool error: no such element"))
        #expect(SafariBridge.lostSafari("Error Domain=WebDriverErrorDomain Code=6 \"Could not create a session\""))
    }
}
