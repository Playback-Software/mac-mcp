import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct PolicyDoctorTests {
    private func status(_ source: PolicyStatus.Source, pending: [Loosening] = [], problems: [String] = [],
                        enforced: Result<Policy, Policy.LoadError> = .success(Policy())) -> PolicyStatus {
        PolicyStatus(enforced: enforced, source: source, pending: pending, problems: problems, fallback: Policy(),
                     file: source == .managed ? Paths.managedPolicyFile : Paths.policyFile)
    }

    @Test func showsWhichPolicyIsInForceAndWarnsWhileUsersCanWriteIt() {
        let user = DoctorTool.policyLines(status(.user)).joined(separator: "\n")
        #expect(user.contains("OK  in force: \(Paths.policyFile), as approved"))
        #expect(user.contains("warning:") && user.contains("managed policy"))
        let managed = DoctorTool.policyLines(status(.managed)).joined(separator: "\n")
        #expect(managed.contains("in force: the managed policy") && !managed.contains("warning:"))
    }

    @Test func pendingLooseningSaysWhatAndWhoMustApproveIt() {
        let lines = DoctorTool.policyLines(status(.approved, pending: [Loosening("deny_apps", "no longer lists com.apple.Terminal")]))
            .joined(separator: "\n")
        #expect(lines.contains("!!  in force: the last approved policy"))
        #expect(lines.contains("deny_apps: no longer lists com.apple.Terminal"))
        #expect(lines.contains("a person runs `mac-mcp policy approve` in Terminal"))
    }

    @Test func saysWhenThePolicyWasApprovedAndWhereItIsKept() {
        var s = status(.user)
        s.approval = ApprovalRecord(policy: Data("{}".utf8), by: "`mac-mcp policy approve`")
        let lines = DoctorTool.policyLines(s).joined(separator: "\n")
        #expect(lines.contains("      approved ") && lines.contains("by `mac-mcp policy approve`; kept in your login keychain"))
        var managed = status(.managed)
        managed.approval = s.approval
        #expect(!DoctorTool.policyLines(managed).joined().contains("approved "))
    }

    @Test func aBlockedApprovalNamesTheCommandThatFixesIt() {
        let e = Policy.LoadError.blocked("The approved policy in your login keychain is missing.")
        let lines = DoctorTool.policyLines(status(.approved, problems: [e.description], enforced: .failure(e)))
        #expect(lines.contains { $0.hasPrefix("  !!  POLICY BLOCKED") && $0.contains("mac-mcp policy approve") })
        #expect(lines.contains { $0.contains("!!  in force: the last approved policy") })
    }

    @Test func aHeldUpKeychainCallShowsHowLongAndWhatToDo() {
        let call = KeychainCall(what: "adding an approval record", since: Date(timeIntervalSince1970: 1_800_000_000))
        let lines = DoctorTool.policyLines(status(.user, problems: [call.message]), keychainCall: call, now: call.since + 73)
        #expect(lines.contains { $0.hasPrefix("  !!  keychain call held up for 73 s") && $0.contains("`mac-mcp restart`") })
        #expect(lines.filter { $0.contains("hasn't returned since") }.count == 1)
        #expect(lines.contains { $0.hasPrefix("  !!  in force") })
        let quiet = DoctorTool.policyLines(status(.user))
        #expect(!quiet.contains { $0.contains("keychain call") } && quiet.contains { $0.hasPrefix("  OK  in force") })
    }

    @Test func anInvalidPolicyIsReportedOnce() {
        let e = Policy.LoadError.invalid(Paths.policyFile, "bad")
        let lines = DoctorTool.policyLines(status(.user, problems: [e.description], enforced: .failure(e)))
        #expect(lines.filter { $0.contains("POLICY INVALID") }.count == 1)
        #expect(lines.contains { $0.hasPrefix("  !!  POLICY INVALID") })
        #expect(!lines.contains { $0.contains("deny_apps:") })
    }
}
