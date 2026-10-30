import ApplicationServices
import Foundation
import Testing
@testable import MacMCPCore

@Suite struct RefIsolationTests {
    func window(scope: Int32, control: Int32, title: String = "Same title", label: String = "Save") -> RawNode {
        var root = RawNode(role: "AXWindow", title: title)
        root.element = AXElement.application(pid: scope)
        var button = RawNode(role: "AXButton", title: label)
        button.element = AXElement.application(pid: control)
        root.children = [button]
        return root
    }

    @Test func identicalControlsInDifferentWindowsKeepSeparateRefs() async throws {
        let store = RefStore()
        var a = Snapshot.rows(from: window(scope: 100001, control: 100003), pid: 7)
        var b = Snapshot.rows(from: window(scope: 100002, control: 100004), pid: 7)
        _ = try await store.record(&a, pid: 7)
        _ = try await store.record(&b, pid: 7)
        #expect(a[0].ref != b[0].ref)
        let original = try #require(await store.entry(a[0].ref!))
        #expect(original.element == a[0].element)
        var again = Snapshot.rows(from: window(scope: 100001, control: 100003, title: "Renamed document"), pid: 7)
        _ = try await store.record(&again, pid: 7)
        #expect(again[0].ref == a[0].ref)
    }

    @Test func ambiguousFingerprintsDoNotRetargetAnOldRef() async throws {
        let store = RefStore()
        var root = RawNode(role: "AXWindow")
        root.children = [RawNode(role: "AXButton", title: "Save")]
        var original = Snapshot.rows(from: root, pid: 7)
        _ = try await store.record(&original, pid: 7)
        root.children.append(root.children[0])
        var ambiguous = Snapshot.rows(from: root, pid: 7)
        _ = try await store.record(&ambiguous, pid: 7)
        #expect(Set(ambiguous.compactMap(\.ref)).count == 2)
        #expect(!ambiguous.contains { $0.ref == original[0].ref })
    }

    @Test func renamedElementsDoNotLeaveOldFingerprintAliases() async throws {
        let store = RefStore()
        var first = Snapshot.rows(from: window(scope: 100001, control: 100003), pid: 7)
        _ = try await store.record(&first, pid: 7)
        var renamed = Snapshot.rows(from: window(scope: 100001, control: 100003, label: "Export"), pid: 7)
        _ = try await store.record(&renamed, pid: 7)
        #expect(renamed[0].ref == first[0].ref)
        var replacement = Snapshot.rows(from: window(scope: 100001, control: 100004), pid: 7)
        _ = try await store.record(&replacement, pid: 7)
        #expect(replacement[0].ref != first[0].ref)
    }
}

@Suite struct SnapshotSearchPrivacyTests {
    let secret = "SYNTHETIC-SECRET-DO-NOT-REVEAL"

    @Test func secureValuesAndDescendantsNeverReachLabelsSearchOrRawOutput() {
        var secure = RawNode(role: "AXTextField", subrole: "AXSecureTextField", value: secret, placeholder: "Password")
        secure.children = [RawNode(role: "AXStaticText", value: secret)]
        var parent = RawNode(role: "AXRow")
        parent.children = [secure, RawNode(role: "AXStaticText", value: "Account")]
        let rows = Snapshot.rows(from: parent, pid: 7)
        #expect(!rows.map { $0.render(frames: false) }.joined().contains(secret))
        #expect(!rows.contains { $0.matches(secret) || $0.fingerprint.contains(secret) })
        #expect(!Snapshot.rawDump(parent).contains(secret))
        #expect(Snapshot.label(parent) == "Account")
        #expect(rows.contains { $0.role == "password" && $0.value == "•••" })
    }

    @Test func queriesFindFullValuesLabelsAndTextWithoutExpandingOutput() {
        var root = RawNode(role: "AXWindow")
        root.children = [
            RawNode(role: "AXTextField", title: "Log", value: String(repeating: "x", count: 150) + "NEEDLE"),
            RawNode(role: "AXButton", title: String(repeating: "y", count: 150) + "NEEDLE"),
            RawNode(role: "AXStaticText", value: String(repeating: "z", count: 250) + "NEEDLE"),
        ]
        let rows = Snapshot.rows(from: root, pid: 7)
        #expect(rows.count == 3 && rows.allSatisfy { $0.matches("needle") })
        #expect(rows.allSatisfy { !$0.render(frames: false).contains("NEEDLE") })
        #expect(rows[0].value?.count == 120 && rows[1].label.count == 100 && rows[2].label.count == 200)
    }
}

@Suite struct TypingPrivacyTests {
    @Test func typingMismatchDoesNotEchoEnteredOrExistingPrivateText() throws {
        let secret = "synthetic-private-input"
        for mode in [Actions.TypeMode.replace, .append] {
            do {
                try Actions.verifyTypedValue("private-existing-value", expected: secret, mode: mode)
                Issue.record("A mismatched field was accepted")
            } catch {
                let message = String(describing: error)
                #expect(!message.contains(secret) && !message.contains("private-existing-value"))
                #expect(message.contains("did not match"))
            }
        }
        try Actions.verifyTypedValue(secret, expected: secret, mode: .replace)
        try Actions.verifyTypedValue("prefix" + secret, expected: secret, mode: .append, original: "prefix")
    }
}

@Suite struct MutationCancellationTests {
    @Test func cancelledWorkCannotSendAXRequests() async {
        let calls = Probe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let element = AXElement.application(pid: 100001)
            #expect(element.set(kAXFocusedAttribute, kCFBooleanTrue as Any) == .cannotComplete)
            #expect(element.perform(kAXPressAction) == .cannotComplete)
            #expect(AXElement.mutate { calls.add("request"); return .success } == .cannotComplete)
        }
        await task.value
        #expect(calls.all.isEmpty)
    }

    @Test func lateAXRequestIsSuppressedAfterDeadline() async throws {
        let calls = Probe()
        let finished = Probe(), done = Signal()
        let result: Int? = try await Deadline.run(0.02) {
            try? await Task.sleep(for: .seconds(30))   // cancelled when the deadline passes
            _ = AXElement.mutate { calls.add("late request"); return .success }
            finished.add("finished")
            done.fire()
            return 1
        }
        #expect(result == nil)
        await done.wait()
        #expect(finished.all == ["finished"] && calls.all.isEmpty)
    }

    @Test func cancelledLaunchStopsBeforeLookingUpOrOpeningAnApp() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await AppControl.launch("MissingAuditTestApp") }
        }
        await task.value
    }
}

@Suite struct KeySequenceOrderTests {
    @Test func repeatRepeatsWholeSequence() throws {
        let specs = try KeySpec.parseSequence("tab, space")
        var sent: [KeySpec] = []
        Actions.keys(specs, repeat: 2) { sent.append($0) }
        #expect(sent == specs + specs)
    }

    @Test func cancelledSequenceStopsBetweenPresses() async throws {
        let specs = try KeySpec.parseSequence("tab, space")
        let task = Task {
            var sent: [KeySpec] = []
            Actions.keys(specs, repeat: 2) {
                sent.append($0)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return sent
        }
        #expect(await task.value == [specs[0]])
    }
}
