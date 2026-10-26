import AppKit
import Foundation
import Testing
import MacMCPCore

extension Integration {
@Suite struct HardeningTests {
    init() throws { try closeMenus(); try hostURL("dismiss"); try hostURL("reset") }

    var hostPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.playbacksoftware.macmcp.testhost").first?.processIdentifier
    }

    /// A hung app (SIGSTOP: it accepts no events and answers no accessibility requests) must cost one bounded,
    /// explained failure, not a frozen agent. Afterwards the action lock is free for the next call.
    @Test func actionOnAHungAppReturnsInTimeAndFreesTheLock() throws {
        let submit = try refFor("button \"Submit\"")
        let pid = try #require(hostPID)
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGCONT) }
        let start = Date()
        let r = try agent().call("mac_click", ["ref": submit])
        let took = Date().timeIntervalSince(start)
        #expect(r.isError, "clicking a stopped app reported success: \(r.text)")
        #expect(r.text.contains("isn't responding") || r.text.contains("abandoned"), "\(r.text)")
        #expect(took < 30, "took \(Int(took)) s")
        kill(pid, SIGCONT)
        // The lock moved on: another app can be driven right away.
        let finder = try agent().call("mac_snapshot", ["app": "Finder", "max_tokens": 200])
        #expect(!finder.isError)
        let doctor = try agent().call("mac_doctor").text
        #expect(doctor.contains("action lock: idle"), "\(doctor)")
        // And the host recovers.
        _ = try agent().call("mac_wait", ["app": hostApp, "until": "settled", "timeout": 5])
        #expect(!(try agent().call("mac_click", ["ref": try refFor("button \"Submit\"")])).isError)
    }

    /// While a lease is held, clients without its token may look but not touch.
    @Test func leaseHolderActsOthersOnlyRead() throws {
        // Under scripts/integration.sh this process already holds the lease; otherwise take one for the test.
        var taken: Lease?
        let token: String
        if let own = LeaseStore.ownToken, LeaseStore.current()?.token == own {
            token = own
        } else {
            taken = try LeaseStore.acquire(holder: "lease-test", reason: "integration", minutes: 2, pid: getpid())
            token = taken!.token
        }
        defer { if let taken { LeaseStore.release(token: taken.token) } }

        let outsider = try AgentClient(clientName: "outsider", version: "1", lease: nil)
        let refused = try outsider.call("mac_key", ["keys": "esc", "app": hostApp])
        #expect(refused.isError && refused.text.contains("leased by"), "\(refused.text)")
        #expect(!(try outsider.call("mac_snapshot", ["app": hostApp, "max_tokens": 200])).isError)
        #expect(!(try outsider.call("mac_app", ["action": "list"])).isError)   // looking, not changing
        #expect(try outsider.call("mac_app", ["action": "activate", "app": "Finder"]).text.contains("leased by"))
        #expect(try outsider.call("mac_doctor").text.contains("GUI lease: held by"))

        let holder = try AgentClient(clientName: "holder", version: "1", lease: token)
        #expect(!(try holder.call("mac_key", ["keys": "esc", "app": hostApp])).isError)
    }
}
}
