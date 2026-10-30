import Foundation
import Testing
@testable import MacMCPCore

/// The approved policy is anchored in the keychain: the readable copy beside the agent is never trusted, and once a
/// policy has been approved, a keychain record that goes missing or bad blocks agents instead of re-baselining.
@Suite struct PolicyApprovalKeychainTests {
    private func blockedReason(_ status: PolicyStatus) -> String? {
        guard case let .failure(e) = status.enforced, case .blocked = e else { return nil }
        return e.description
    }

    /// R2: deleting the approved copy and restarting the agent used to approve whatever policy.json said.
    @Test func aRecordDeletedBetweenRunsBlocksInsteadOfRebaselining() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.apple.Terminal"]}"#)
        _ = box.store().status()
        box.keychain.record = nil
        try box.write(#"{"deny_apps": []}"#)
        let reports = PolicyReports()
        let restarted = box.store { message, _ in reports.add(message) }.status()
        let why = try #require(blockedReason(restarted))
        #expect(why.hasPrefix("POLICY BLOCKED") && why.contains("approved on this Mac before") && why.contains("mac-mcp policy approve"))
        #expect(restarted.problems.contains(why) && reports.all.count == 1)
        #expect(box.keychain.record == nil)   // nothing re-baselined
        #expect(restarted.policy.alertWebhook == nil && restarted.policy.denyApps == Policy.defaultDenyApps)
        // The person looks at the file and approves it; that is the new baseline.
        _ = try PolicyStore.approve(box.locations)
        #expect(try box.store().status().enforced.get().denyApps == [])
    }

    /// R1: the readable copy is an ordinary file an agent might reach. Rewriting it loosens nothing, and it is put
    /// back from the keychain.
    @Test func editingTheReadableCopyChangesNothing() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["com.apple.Terminal"]}"#)
        let store = box.store()
        _ = store.status()
        try box.write(#"{"deny_apps": []}"#, to: box.locations.approved)
        try box.write(#"{"deny_apps": []}"#)
        for status in [store.status(), box.store().status()] {
            #expect(status.source == .approved && status.pending.first?.key == "deny_apps")
            #expect(try status.enforced.get().denyApps == ["com.apple.Terminal"])
        }
        #expect(box.contents(box.locations.approved) == #"{"deny_apps": ["com.apple.Terminal"]}"#)
    }

    @Test func aDeletedReadableCopyIsHarmlessAndRewritten() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = box.store().status()
        box.remove(box.locations.approved)
        let status = box.store().status()
        #expect(status.source == .user && status.problems.isEmpty)
        #expect(box.contents(box.locations.approved) == #"{"deny_apps": ["a"]}"#)
    }

    /// Only the readable copy's presence counts, as a sign that something was approved here before.
    @Test func withNeitherRecordNorCopyItIsAFirstRun() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = box.store().status()
        box.keychain.record = nil
        box.remove(box.locations.approved)
        let status = box.store().status()
        #expect(status.source == .user && status.approval?.by == "MacMCP's first run")
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": ["a"]}"#)
    }

    @Test func anUnreadableKeychainBlocksAFreshAgent() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"alert_webhook": "https://ntfy.example/t"}"#)
        box.keychain.failing = "the keychain is locked"
        let status = box.store().status()
        let why = try #require(blockedReason(status))
        #expect(why.contains("can't read its approved policy from the test keychain (the keychain is locked)"))
        // Even the webhook can't come from a file nothing vouches for.
        #expect(status.policy.alertWebhook == nil)
        #expect(box.keychain.writes == 0 && box.contents(box.locations.approved) == nil)
    }

    @Test func anUnreadableKeychainKeepsWhatARunningAgentRead() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        _ = store.status()
        box.keychain.failing = "the keychain is locked"
        let locked = store.status()
        #expect(try locked.enforced.get().denyApps == ["a"])
        #expect(locked.problems.isEmpty && locked.notices.contains { $0.contains("keeps enforcing the one it read before") })
        // A tightening still applies at once; that it couldn't be recorded is a problem a person hears about.
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        let tighter = store.status()
        #expect(try tighter.enforced.get().denyApps == ["a", "b"])
        #expect(tighter.problems.contains { $0.contains("Could not record the approved policy") })
        // Loosening back to the recorded policy still counts against what this agent knows.
        try box.write(#"{"deny_apps": ["a"]}"#)
        #expect(store.status().pending.first?.key == "deny_apps")
        box.keychain.failing = nil
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        #expect(store.status().problems.isEmpty && box.keychain.approvedPolicy == #"{"deny_apps": ["a", "b"]}"#)
    }

    @Test func aRecordFromANewerMacMCPOrWithAnInvalidPolicyBlocks() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{}"#)
        var newer = ApprovalRecord(policy: Data("{}".utf8), by: "a newer MacMCP")
        newer.format = ApprovalRecord.currentFormat + 1
        box.keychain.record = newer.encoded
        #expect(try #require(blockedReason(box.store().status())).contains("newer MacMCP"))
        box.keychain.record = ApprovalRecord(policy: Data(#"{"deny_apps": "nope"}"#.utf8), by: "test").encoded
        #expect(try #require(blockedReason(box.store().status())).contains("damaged"))
    }

    /// A first run whose baseline isn't recorded serves nothing: otherwise an edit made meanwhile would become the
    /// baseline at the next start. It retries on each load.
    @Test func aFirstRunWhoseRecordCantBeWrittenBlocksUntilItIs() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        box.keychain.rejectingWrites = "the keychain is locked"
        let store = box.store()
        let status = store.status()
        let why = try #require(blockedReason(status))
        #expect(why.contains("couldn't record \(box.locations.user) as the first approved policy in the test keychain"))
        #expect(why.contains("the keychain is locked") && why.contains("mac-mcp policy approve"))
        #expect(box.keychain.record == nil && box.contents(box.locations.approved) == nil)
        // The defaults as the baseline, with no file, likewise.
        box.remove(box.locations.user)
        #expect(try #require(blockedReason(store.status())).contains("couldn't record the built-in defaults"))
        // Recorded at the next load once the keychain takes it.
        try box.write(#"{"deny_apps": ["a"]}"#)
        box.keychain.rejectingWrites = nil
        let recorded = store.status()
        #expect(try recorded.enforced.get().denyApps == ["a"] && recorded.approval?.by == "MacMCP's first run")
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": ["a"]}"# && box.contents(box.locations.approved) != nil)
    }

    /// A tightening the keychain didn't take outlives the keychain becoming readable again: the older record still
    /// there doesn't replace it, so putting policy.json back is a loosening that waits for approval.
    @Test func anUnrecordedTighteningSurvivesTheOlderRecord() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        _ = store.status()
        box.keychain.failing = "the keychain is locked"
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b"])
        // Readable again, but still not taking writes: the record from before the tightening is all it holds.
        box.keychain.failing = nil
        box.keychain.rejectingWrites = "the keychain refused MacMCP access"
        try box.write(#"{"deny_apps": ["a"]}"#)
        let restored = store.status()
        #expect(restored.source == .approved && restored.pending.first?.key == "deny_apps")
        #expect(try restored.enforced.get().denyApps == ["a", "b"])
        #expect(restored.problems.contains { $0.contains("Could not record the approved policy") && $0.contains("tries again") })
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": ["a"]}"#)
        // Once writes work, the next evaluation records it.
        box.keychain.rejectingWrites = nil
        let retried = store.status()
        #expect(retried.pending.first?.key == "deny_apps" && box.keychain.approvedPolicy == #"{"deny_apps": ["a", "b"]}"#)
        #expect(!retried.problems.contains { $0.contains("Could not record") })
    }

    /// What does replace an unrecorded tightening: a person's later approval, or a record that is no looser.
    @Test func anUnrecordedTighteningGivesWayToALaterApproval() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        _ = store.status()
        let old = try #require(box.keychain.record)
        box.keychain.rejectingWrites = "the keychain is locked"
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b"])
        // An older record a person made doesn't count, nor does a newer one MacMCP made on its own.
        var stale = try ApprovalRecord.decode(old).get()
        stale.byPerson = true
        box.keychain.record = stale.encoded
        try box.write(#"{"deny_apps": ["a"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b"])
        box.keychain.record = ApprovalRecord(policy: Data(#"{"deny_apps": ["a"]}"#.utf8), by: "MacMCP",
                                             approvedAt: Date() + 5).encoded
        try box.write(#"{"deny_apps": ["a"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b"])
        // A tighter record does, and so does a person's approval made after the tightening.
        box.keychain.record = ApprovalRecord(policy: Data(#"{"deny_apps": ["a", "b", "c"]}"#.utf8), by: "MacMCP").encoded
        try box.write(#"{"deny_apps": ["a", "b", "c"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b", "c"])
        try box.write(#"{"deny_apps": ["a", "b", "c", "d"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b", "c", "d"])   // unrecorded again
        box.keychain.record = ApprovalRecord(policy: Data(#"{"deny_apps": ["a"]}"#.utf8), by: "`mac-mcp policy approve`",
                                             byPerson: true, sequence: 1, approvedAt: Date() + 5).encoded
        try box.write(#"{"deny_apps": ["a"]}"#)
        let approved = store.status()
        #expect(approved.source == .user && approved.pending.isEmpty && approved.problems.isEmpty)
        #expect(try approved.enforced.get().denyApps == ["a"])
    }

    /// A person's approval with the same sequence replaces an unrecorded tightening without relying on the clock.
    @Test func aPersonsApprovalInTheSameSecondAsAnUnrecordedTighteningWins() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        _ = store.status()
        box.keychain.rejectingWrites = "the keychain is locked"
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        let tightening = try #require(store.status().approval)
        #expect(tightening.by.contains("tightened") && box.keychain.approvedPolicy == #"{"deny_apps": ["a"]}"#)
        box.keychain.rejectingWrites = nil
        try box.write(#"{"deny_apps": []}"#)
        _ = try PolicyStore.approve(box.locations)
        let person = try ApprovalRecord.decode(try #require(box.keychain.record)).get()
        #expect(person.byPerson && person.sequence == tightening.sequence && person.isNewer(than: tightening))
        let after = store.status()
        #expect(after.source == .user && after.pending.isEmpty && after.problems.isEmpty)
        #expect(try after.enforced.get().denyApps == [])
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": []}"#, "the tightening's retry overwrote the approval")
    }

    /// Sequence orders transactions regardless of the clock; for equal sequences a person's record wins.
    @Test func approvalRecordsAreOrderedBySequenceThenPersonThenTime() throws {
        let second = 1_800_000_000.0
        let tight = Data(#"{"deny_apps": ["a", "b"]}"#.utf8), loose = Data(#"{"deny_apps": []}"#.utf8)
        let known = (policy: try Policy.decode(tight).get(),
                     record: ApprovalRecord(policy: tight, by: "MacMCP", sequence: 2, approvedAt: Date(timeIntervalSince1970: second + 0.1)))
        let loosePolicy = try Policy.decode(loose).get()
        func person(_ sequence: Int, _ at: TimeInterval) throws -> ApprovalRecord {
            // Through the keychain's bytes, as the agent would read it.
            try ApprovalRecord.decode(ApprovalRecord(policy: loose, by: "`mac-mcp policy approve`", byPerson: true,
                                                     sequence: sequence, approvedAt: Date(timeIntervalSince1970: at)).encoded).get()
        }
        #expect(PolicyStore.supersedes(try person(2, second + 0.8), loosePolicy, known))
        #expect(PolicyStore.supersedes(try person(2, second + 0.05), loosePolicy, known))
        #expect(PolicyStore.supersedes(try person(2, second + 0.1), loosePolicy, known))   // a person's record wins the tie
        #expect(!PolicyStore.supersedes(try person(1, second + 30), loosePolicy, known))   // made before the tightening's base
        #expect(PolicyStore.supersedes(try person(3, second - 30), loosePolicy, known))
        // A record from before 0.1.1 has whole seconds and no sequence: 0.
        let legacy = try ApprovalRecord.decode(Data(#"{"approved_at":"2027-01-15T08:00:00Z","by":"test","by_person":true,"format":1,"policy":"e30="}"#.utf8)).get()
        #expect(legacy.sequence == 0 && legacy.approvedAt == Date(timeIntervalSince1970: second))
        #expect(!legacy.isNewer(than: known.record) && known.record.isNewer(than: legacy))
    }

    /// The eval harness writes policy.json, then approves it: an edit made in between mustn't be what gets approved.
    @Test func approveWithAnExpectedHashApprovesOnlyThoseBytes() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = try PolicyStore.approve(box.locations)
        let written = Data(#"{"deny_apps": ["a"], "clipboard_read": false}"#.utf8)
        let hash = PolicyStore.sha256(written)
        #expect(hash.count == 64)
        try box.write(#"{"deny_apps": []}"#)   // someone else's edit, after the script wrote its own
        #expect {
            try PolicyStore.approve(box.locations, expectSHA256: hash)
        } throws: { error in
            "\(error)".contains("Nothing was approved") && "\(error)".contains("not \(hash)")
        }
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": ["a"]}"#)
        box.remove(box.locations.user)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations, expectSHA256: hash) }
        #expect(box.contents(box.locations.user) == nil)   // not put back either
        try written.write(to: URL(fileURLWithPath: box.locations.user))
        _ = try PolicyStore.approve(box.locations, expectSHA256: hash.uppercased())
        #expect(box.keychain.approvedPolicy == String(decoding: written, as: UTF8.self))
    }

    @Test func approveMarksItsRecordAsAPersons() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = box.store().status()
        #expect(try ApprovalRecord.decode(try #require(box.keychain.record)).get().byPerson == false)
        _ = try PolicyStore.approve(box.locations)
        #expect(try ApprovalRecord.decode(try #require(box.keychain.record)).get().byPerson == true)
        // A record from before the field existed reads as MacMCP's own.
        let legacy = Data(#"{"approved_at":"2026-10-01T00:00:00Z","by":"test","format":1,"policy":"e30="}"#.utf8)
        #expect(try ApprovalRecord.decode(legacy).get().byPerson == false)
    }

    @Test func theManagedPolicyWinsWithoutReadingTheKeychain() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        box.keychain.failing = "the keychain is locked"
        try box.write(#"{"deny_apps": ["com.apple.TextEdit"]}"#, to: box.locations.managed)
        chmod(box.locations.managed, 0o644)
        let status = box.store().status()
        #expect(status.source == .managed && status.problems.isEmpty)
        #expect(try status.enforced.get().denyApps == ["com.apple.TextEdit"])
    }

    @Test func aStoreThatOnlyReadsNeverWritesTheKeychain() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        #expect(box.store(writes: false).status().source == .user)
        #expect(box.keychain.writes == 0 && box.contents(box.locations.approved) == nil)
    }

    /// `mac-mcp policy approve` and the readable copy are rewritten together; a change made to the keychain alone is
    /// picked up at the next recheck.
    @Test func keychainChangesAreReadOnChangeAndOnRecheck() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = PolicyStore(locations: box.locations, recheck: 3600)
        _ = store.status()
        try box.write(#"{"deny_apps": []}"#)
        #expect(store.status().source == .approved)
        _ = try PolicyStore.approve(box.locations)   // rewrites the readable copy too, so it's noticed at once
        #expect(store.status().source == .user)
        box.keychain.record = ApprovalRecord(policy: Data(#"{"deny_apps": ["a"]}"#.utf8), by: "test").encoded
        #expect(store.status().source == .user)   // cached until the recheck
        #expect(box.store().status().source == .approved)
    }

    @Test func approveRecordsTheKeychainAndTheCopy() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": []}"#)
        let approval = try PolicyStore.approve(box.locations, by: "a test")
        #expect(approval.notes.contains { $0.contains("first approval") })
        #expect(approval.notes.contains { $0.contains("Compared with the built-in defaults") && $0.contains("deny_apps") })
        let record = try ApprovalRecord.decode(try #require(box.keychain.record)).get()
        #expect(record.by == "a test" && record.policy == Data(#"{"deny_apps": []}"#.utf8))
        #expect(box.contents(box.locations.approved) == #"{"deny_apps": []}"#)
    }

    @Test func approveAfterALostRecordSaysSoAndAlertsSetupWontGuess() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = try PolicyStore.approve(box.locations)
        box.keychain.record = nil
        try box.write(#"{"deny_apps": [], "alert_webhook": "https://ntfy.example/t"}"#)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations, onlyKeys: ["alert_webhook"]) }
        #expect(box.keychain.record == nil)
        let approval = try PolicyStore.approve(box.locations)
        #expect(approval.notes.contains { $0.contains("is missing; this replaces it") })
        box.keychain.record = Data("garbage".utf8)
        #expect(try PolicyStore.approve(box.locations).notes.contains { $0.contains("is damaged") })
    }

    @Test func approveFailsWhenTheKeychainRefuses() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = try PolicyStore.approve(box.locations)
        try box.write(#"{"deny_apps": []}"#)
        box.keychain.rejectingWrites = "the keychain is locked"
        #expect {
            try PolicyStore.approve(box.locations)
        } throws: { error in
            "\(error)".contains("Could not record the approval in your login keychain: the keychain is locked")
        }
        #expect(box.keychain.approvedPolicy == #"{"deny_apps": ["a"]}"#)
        #expect(box.contents(box.locations.approved) == #"{"deny_apps": ["a"]}"#)
    }

    @Test func approvalRecordsRoundTripAndRejectGarbage() throws {
        let record = ApprovalRecord(policy: Data(#"{"deny_apps": ["a"]}"#.utf8), by: "test",
                                    approvedAt: Date(timeIntervalSince1970: 1_800_000_000.7))
        #expect(try ApprovalRecord.decode(record.encoded).get() == record)
        #expect(record.approvedAt == Date(timeIntervalSince1970: 1_800_000_000.7))
        // Whole seconds stay in `approved_at`, which older builds read.
        #expect(String(decoding: record.encoded, as: UTF8.self).contains(#""approved_at":"2027-01-15T08:00:00Z""#))
        #expect((try? ApprovalRecord.decode(Data("{}".utf8)).get()) == nil)
        #expect((try? ApprovalRecord.decode(Data(#"{"deny_apps": []}"#.utf8)).get()) == nil)
    }

    /// Every record is a new item: the first run, each tightening and each approval add one, in order. The agent never
    /// changes or deletes one, which for an item another build made macOS would ask a person about.
    @Test func everyRecordIsANewItemAndTheAgentDeletesNone() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        _ = store.status()
        box.keychain.build = "build 2"   // rebuilt: a stranger to the first record
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        _ = store.status()
        try box.write(#"{"deny_apps": ["a", "b", "c"]}"#)
        #expect(try store.status().enforced.get().denyApps == ["a", "b", "c"])
        let ledger = box.keychain.ledger
        #expect(ledger.entries.map(\.record.sequence) == [1, 2, 3] && Set(box.keychain.accounts).count == 3)
        #expect(ledger.entries.allSatisfy { $0.stored.account.hasPrefix("approval.\($0.record.sequence).") })
        #expect(ledger.inForce?.record.by.contains("tightened") == true && box.keychain.prompts == 0)
        // A fresh agent, after another rebuild, reads them all and adds nothing.
        box.keychain.build = "build 3"
        #expect(try box.store().status().enforced.get().denyApps == ["a", "b", "c"])
        #expect(box.keychain.accounts.count == 3 && box.keychain.writes == 3)
    }

    /// The one item MacMCP kept before 0.1.1 is a record like any other, at sequence 0 if it has none, and the next
    /// record comes after it.
    @Test func theItemFromBefore011IsReadAsARecord() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        let old = Data(#"{"approved_at":"2026-10-01T00:00:00Z","by":"`mac-mcp policy approve`","by_person":true,"format":1,"policy":"eyJkZW55X2FwcHMiOiBbImEiXX0="}"#.utf8)
        box.keychain.record = old   // policy {"deny_apps": ["a"]}
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        let status = store.status()
        #expect(status.source == .user && status.problems.isEmpty && status.notices.isEmpty)
        #expect(status.approval?.sequence == 0 && status.approval?.by == "`mac-mcp policy approve`" && box.keychain.writes == 0)
        try box.write(#"{"deny_apps": []}"#)
        #expect(store.status().pending.first?.key == "deny_apps")
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        _ = store.status()
        #expect(box.keychain.ledger.entries.map { String($0.stored.account.prefix(11)) } == ["approved-po", "approval.1."])
        // Approving keeps the old item, which this build can't delete without asking, and says so.
        let approval = try PolicyStore.approve(box.locations)
        #expect(approval.notes.contains { $0.contains("older record") && $0.contains("mac-mcp policy prune") })
        #expect(box.keychain.accounts.first == ApprovalLedger.legacyAccount && box.keychain.prompts == 0)
    }

    /// A damaged record older than the one in force changes nothing, but a person hears it's there.
    @Test func anOlderDamagedRecordIsIgnoredAndReported() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        box.keychain.damage()   // before anything was approved: sequence 1
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = try PolicyStore.approve(box.locations)
        let status = box.store().status()
        #expect(status.source == .user && status.problems.isEmpty && status.approval?.sequence == 2)
        #expect(status.notices.contains { $0.contains("ignores a record") && $0.contains("can't read") && $0.contains("prune") })
    }

    /// The newest record damaged: a running agent keeps what it read and a fresh one blocks, until a person approves the
    /// policy again, which then applies. Nothing in between writes to the keychain.
    @Test func aDamagedNewestRecordWaitsForAPersonsApproval() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        let store = box.store()
        _ = store.status()
        box.keychain.build = "build 2"
        let garbage = box.keychain.damage()
        try box.write(#"{"deny_apps": []}"#)
        let running = store.status()
        #expect(try running.enforced.get().denyApps == ["a"] && running.problems.contains { $0.contains("is damaged") })
        #expect(try #require(blockedReason(box.store().status())).contains("is damaged"))
        #expect(box.keychain.writes == 1)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.prune(box.locations, ask: nil) }
        let approval = try PolicyStore.approve(box.locations)
        #expect(approval.notes.contains { $0.contains("is damaged (it isn't an approval record); this replaces it") })
        #expect(approval.notes.contains { $0.contains("2 older records") })   // the first run's, and the damaged one
        for status in [store.status(), box.store().status()] {
            #expect(status.source == .user && status.pending.isEmpty && status.problems.isEmpty)
            #expect(try status.enforced.get().denyApps == [])
            #expect(status.notices.contains { $0.contains("ignores a record") })
        }
        #expect(box.keychain.accounts.contains(garbage) && box.keychain.prompts == 0)
    }

    /// `mac-mcp policy approve` deletes the records it replaces that this build made, and leaves the rest. `prune`, a
    /// person at Terminal, deletes those too, saying first how many macOS will ask about.
    @Test func approveDeletesItsOwnOldRecordsAndPruneTheRest() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps": ["a"]}"#)
        _ = box.store().status()
        try box.write(#"{"deny_apps": ["a", "b"]}"#)
        _ = box.store().status()
        box.keychain.build = "build 2"
        try box.write(#"{"deny_apps": []}"#)
        #expect(try PolicyStore.approve(box.locations).notes.contains { $0.contains("2 older records") })
        try box.write(#"{"deny_apps": ["x"]}"#)
        #expect(try PolicyStore.approve(box.locations).notes.contains { $0.contains("2 older records") })   // its own went
        #expect(box.keychain.accounts.count == 3)
        let kept = try PolicyStore.prune(box.locations, ask: nil)
        #expect(kept.deleted == 0 && kept.kept == 2 && box.keychain.prompts == 0)
        let asked = PolicyReports()
        let pruned = try PolicyStore.prune(box.locations) { asked.add("\($0)") }
        #expect(pruned.deleted == 2 && pruned.kept == 0 && asked.all == ["2"] && box.keychain.prompts == 2)
        #expect(box.keychain.accounts.count == 1 && box.keychain.approvedPolicy == #"{"deny_apps": ["x"]}"#)
        #expect(try PolicyStore.prune(box.locations, ask: nil).deleted == 0)
        #expect(try box.store().status().enforced.get().denyApps == ["x"])
        // `uninstall --purge` deletes the last one too.
        #expect(try PolicyStore.forgetApproval(box.locations, ask: nil).deleted == 1 && box.keychain.accounts.isEmpty)
    }

    /// Records are placed by sequence, then time; one that can't be read by the sequence in its account or, without
    /// one, by when the keychain last changed it. Unclear means it may be newer.
    @Test func theLedgerOrdersRecordsAndPlacesDamagedOnes() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func valid(_ account: String, _ sequence: Int, _ at: TimeInterval, modified: TimeInterval = 0) -> StoredApproval {
            StoredApproval(account: account, data: ApprovalRecord(policy: Data("{}".utf8), by: "test", sequence: sequence,
                                                                  approvedAt: t + at).encoded, modified: t + modified)
        }
        func garbage(_ account: String, modified: TimeInterval? = 0) -> StoredApproval {
            StoredApproval(account: account, data: Data("garbage".utf8), modified: modified.map { t + $0 })
        }
        let records = [valid("approval.2.bbbb", 2, 1), valid("approval.2.aaaa", 2, 2), valid(ApprovalLedger.legacyAccount, 1, 50)]
        let ledger = ApprovalLedger(records)
        #expect(ledger.entries.map(\.stored.account) == [ApprovalLedger.legacyAccount, "approval.2.bbbb", "approval.2.aaaa"])
        #expect(ledger.inForce?.stored.account == "approval.2.aaaa" && ledger.nextSequence == 3)
        #expect(ApprovalLedger(records + [garbage("approval.1.cccc")]).inForce != nil)
        #expect(ApprovalLedger(records + [garbage("approval.2.cccc")]).damagedNewest != nil)   // same sequence: unclear
        #expect(ApprovalLedger(records + [garbage("approval.7.cccc")]).nextSequence == 8)
        #expect(ApprovalLedger(records + [garbage(ApprovalLedger.legacyAccount, modified: -10)]).inForce != nil)
        #expect(ApprovalLedger(records + [garbage("someone-else", modified: 10)]).inForce == nil)
        #expect(ApprovalLedger(records + [garbage("someone-else", modified: nil)]).inForce == nil)
        #expect(ApprovalLedger([garbage("approval.1.cccc")]).damagedNewest?.why == "it isn't an approval record")
        #expect(ApprovalLedger([]).nextSequence == 1 && ApprovalLedger([]).isEmpty)
        #expect(ApprovalLedger.sequence(of: ApprovalLedger.account(sequence: 12)) == 12)
        #expect(ApprovalLedger.sequence(of: "approval.x.y") == nil && ApprovalLedger.sequence(of: "approval.1") == nil)
    }

    /// Pause the first writer after comparison as the second tries to enter. The lock must refuse the second
    /// immediately; on retry it must read the first writer's append before comparing again.
    @Test(arguments: [false, true]) func approvalWritersTakeTurns(personFirst: Bool) async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        let original = #"{"deny_apps":["a"],"rate_limit_per_second":10}"#
        let person = #"{"deny_apps":["a","com.apple.Preview"],"rate_limit_per_second":10}"#
        let agent = #"{"deny_apps":["a"],"rate_limit_per_second":2}"#
        try box.write(original)
        let store = box.store()
        _ = await store.status()
        try box.write(personFirst ? person : agent)
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        box.keychain.beforeNextAdd {
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        let first = Task {
            defer { entered.continuation.finish() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global().async {
                    do {
                        if personFirst { _ = try PolicyStore.approve(box.locations) }
                        else { _ = store.status() }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        var signals = entered.stream.makeAsyncIterator()
        _ = await signals.next()
        try box.write(personFirst ? agent : person)
        let start = Date()
        if personFirst {
            let waiting = await box.store().status()
            #expect(blockedReason(waiting) != nil)
        } else {
            #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations) }
        }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(box.keychain.writes == 1 && box.keychain.prompts == 0)
        release.signal()
        try await first.value
        if !personFirst { _ = try PolicyStore.approve(box.locations) }
        try box.write(agent)
        let after = await store.status()
        #expect(after.source == .approved && after.pending.contains { $0.key == "deny_apps" })
        #expect(try after.enforced.get().denyApps.contains("com.apple.Preview"))
        #expect(box.keychain.ledger.inForce?.record.byPerson == true)
        #expect(box.keychain.prompts == 0)
    }

    @Test func anUnrecordedTighteningCannotOverrideAnIncomparableRecordedTightening() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        let first = box.store()
        _ = first.status()
        box.keychain.rejectingWrites = "locked"
        try box.write(#"{"deny_apps":["a"],"rate_limit_per_second":2}"#)
        _ = first.status()   // held only in memory
        box.keychain.rejectingWrites = nil
        try box.write(#"{"deny_apps":["a","com.apple.Preview"]}"#)
        _ = box.store().status()   // another agent records a different tightening
        let writes = box.keychain.writes
        #expect(blockedReason(first.status()) != nil)
        #expect(box.keychain.writes == writes)
        #expect(box.keychain.approvedPolicy == #"{"deny_apps":["a","com.apple.Preview"]}"#)
    }

    @Test func anAgentNeverAppendsWithoutReadingTheCurrentLedger() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        let store = box.store()
        _ = store.status()
        box.keychain.rejectingReads = "attributes unavailable"
        try box.write(#"{"deny_apps":["a","b"]}"#)
        let status = store.status()
        #expect(try status.enforced.get().denyApps == ["a", "b"])
        #expect(status.problems.contains { $0.contains("Could not record") })
        #expect(box.keychain.writes == 1)
        box.keychain.rejectingReads = nil
        _ = store.status()
        #expect(box.keychain.writes == 2)
    }

    @Test func aTimedOutAddKeepsTheTransactionUntilItFinishes() async throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{"deny_apps":["a"]}"#)
        let store = box.store()
        _ = await store.status()
        try box.write(#"{"deny_apps":["a"],"rate_limit_per_second":2}"#)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = AsyncStream<Void>.makeStream()
        box.keychain.timeOutNextAdd(before: { #expect(release.wait(timeout: .now() + 10) == .success) },
                                   finished: { finished.continuation.yield(()) })
        let timedOut = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: store.status()) }
        }
        #expect(timedOut.problems.contains { $0.contains("didn't answer in time") })
        try box.write(#"{"deny_apps":["a","com.apple.Preview"]}"#)
        #expect(throws: PolicyStore.ApprovalError.self) { try PolicyStore.approve(box.locations) }
        #expect(box.keychain.writes == 1)
        release.signal()
        var signals = finished.stream.makeAsyncIterator()
        _ = await signals.next()
        // The queue releases the retained transaction as it returns from the Security call.
        var released = false
        for _ in 0..<100 where !released {
            do {
                let transaction = try ApprovalTransaction(path: box.locations.approvalLock)
                withExtendedLifetime(transaction) {}
                released = true
            } catch { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(released)
        _ = try PolicyStore.approve(box.locations)
        #expect(box.keychain.ledger.inForce?.record.sequence == 3)   // includes the late sequence 2 append
        try box.write(#"{"deny_apps":["a"],"rate_limit_per_second":2}"#)
        let after = await store.status()
        #expect(after.pending.contains { $0.key == "deny_apps" })
        #expect(try after.enforced.get().denyApps.contains("com.apple.Preview"))
        #expect(box.keychain.prompts == 0)
    }

    @Test(arguments: [ApprovalLedger.legacyAccount, "unrecognized"])
    func anUnreadableRecordWithEqualModificationTimeBlocks(account: String) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let readable = StoredApproval(account: "approval.4.valid", data: ApprovalRecord(policy: Data("{}".utf8), by: "test",
                                                                                      sequence: 4).encoded, modified: now)
        let damaged = StoredApproval(account: account, data: Data("garbage".utf8), modified: now)
        #expect(ApprovalLedger([readable, damaged]).inForce == nil)
        #expect(ApprovalLedger([damaged, readable]).damagedNewest != nil)
    }

    @Test func tiedRecordsPreferAPersonThenDeterministicContents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let agent = ApprovalRecord(policy: Data("{}".utf8), by: "agent", sequence: 2, approvedAt: now + 30)
        let person = ApprovalRecord(policy: Data(#"{"clipboard_read":false}"#.utf8), by: "person", byPerson: true,
                                    sequence: 2, approvedAt: now - 30)
        #expect(person.isNewer(than: agent))
        func stored(_ account: String, _ record: ApprovalRecord) -> StoredApproval {
            StoredApproval(account: account, data: record.encoded, modified: now)
        }
        #expect(ApprovalLedger([stored("approval.2.zzzz", agent), stored("approval.2.aaaa", person)]).inForce?.record == person)
        let a = ApprovalRecord(policy: Data("{}".utf8), by: "a", sequence: 3, approvedAt: now)
        let b = ApprovalRecord(policy: Data("{}".utf8), by: "b", sequence: 3, approvedAt: now)
        let first = ApprovalLedger([stored("approval.3.zzzz", a), stored("approval.3.aaaa", b)])
        let renamed = ApprovalLedger([stored("approval.3.aaaa", a), stored("approval.3.zzzz", b)])
        #expect(first.inForce?.record == renamed.inForce?.record)
        #expect(a.isNewer(than: b) != b.isNewer(than: a))
    }

    @Test func statusSaysWhenAndHowThePolicyWasApproved() throws {
        let box = try PolicySandbox()
        defer { box.cleanUp() }
        try box.write(#"{}"#)
        _ = try PolicyStore.approve(box.locations)
        let line = try #require(box.store().status().approvalLine)
        #expect(line.hasPrefix("approved ") && line.contains("by `mac-mcp policy approve`") && line.contains("login keychain"))
    }
}

/// The real login keychain, on throwaway items that are deleted afterwards. Opt in with MAC_MCP_KEYCHAIN_TESTS=1: it
/// writes to the login keychain of whoever runs it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_MCP_KEYCHAIN_TESTS"] == "1"))
struct LoginKeychainApprovalTests {
    @Test func addsReadsAndDeletesWithoutPrompting() throws {
        let keychain = LoginKeychainApproval(service: "com.playbacksoftware.macmcp.test-\(UUID().uuidString)")
        defer { if case let .found(items) = keychain.read() { _ = keychain.delete(items.map(\.account), interactive: false) } }
        #expect(keychain.read() == .found([]))
        let first = ApprovalRecord(policy: Data("{}".utf8), by: "test", sequence: 1).encoded
        let a = try keychain.add(first, sequence: 1, interactive: false)
        let second = ApprovalRecord(policy: Data(String(repeating: " ", count: 16_000).utf8 + Data("{}".utf8)), by: "test",
                                    sequence: 2).encoded
        let b = try keychain.add(second, sequence: 2, interactive: false)
        guard case let .success(ledger) = keychain.ledger() else { Issue.record("can't read the records back"); return }
        #expect(ledger.entries.map(\.stored.account) == [a, b] && ledger.inForce?.stored.data == second)
        #expect(ledger.entries.allSatisfy { $0.stored.modified != nil })
        // This process made them, so it deletes them without anything shown.
        #expect(keychain.delete([a, b, "approval.9.missing"], interactive: false).isEmpty)
        #expect(keychain.read() == .found([]))
    }
}
