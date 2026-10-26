import Foundation
import Testing
@testable import MacMCPCore

@Suite struct ClaimsTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func aSecondSessionIsKeptOutUntilTheClaimLapses() async {
        let claims = Claims(idle: 60, maxWait: 0)
        #expect(await claims.tryBegin("gui", session: "a", client: "claude-code", origin: "local", now: t0) == nil)
        await claims.finish("gui", session: "a", now: t0.addingTimeInterval(1))
        // b is refused while a's claim is fresh, and told who holds it.
        let held = await claims.tryBegin("gui", session: "b", client: "claude-code", origin: "ssh:10.0.0.2", now: t0.addingTimeInterval(30))
        #expect(held?.session == "a")
        // a keeps acting without interference; its idle clock restarts.
        #expect(await claims.tryBegin("gui", session: "a", client: "claude-code", origin: "local", now: t0.addingTimeInterval(40)) == nil)
        await claims.finish("gui", session: "a", now: t0.addingTimeInterval(41))
        #expect(await claims.tryBegin("gui", session: "b", client: "c", origin: nil, now: t0.addingTimeInterval(100)) != nil)
        // 60 s after a's last action, b gets it.
        #expect(await claims.tryBegin("gui", session: "b", client: "c", origin: nil, now: t0.addingTimeInterval(102)) == nil)
    }

    @Test func aClaimNeverLapsesWhileACallIsRunning() async {
        let claims = Claims(idle: 60, maxWait: 0)
        _ = await claims.tryBegin("gui", session: "a", client: "x", origin: nil, now: t0)
        #expect(await claims.tryBegin("gui", session: "b", client: "y", origin: nil, now: t0.addingTimeInterval(500)) != nil)
    }

    @Test func disconnectFreesEverythingAtOnce() async {
        let claims = Claims(idle: 60, maxWait: 0)
        _ = await claims.tryBegin("gui", session: "a", client: "x", origin: nil, now: t0)
        _ = await claims.tryBegin("web", session: "a", client: "x", origin: nil, now: t0)
        await claims.release(session: "a")
        #expect(await claims.all(now: t0).isEmpty)
        #expect(await claims.tryBegin("gui", session: "b", client: "y", origin: nil, now: t0) == nil)
    }

    @Test func webAndGUIAreSeparate() async {
        let claims = Claims(idle: 60, maxWait: 0)
        _ = await claims.tryBegin("web", session: "a", client: "x", origin: nil, now: t0)
        #expect(await claims.tryBegin("gui", session: "b", client: "y", origin: nil, now: t0) == nil)
        #expect(await claims.tryBegin("web", session: "b", client: "y", origin: nil, now: t0) != nil)
    }

    @Test func waitingSucceedsWhenTheHolderLeaves() async {
        let claims = Claims(idle: 60, maxWait: 5)
        _ = await claims.tryBegin("gui", session: "a", client: "x", origin: nil)
        Task { try? await Task.sleep(for: .milliseconds(300)); await claims.release(session: "a") }
        #expect(await claims.begin("gui", session: "b", client: "y", origin: nil) == nil)
    }

    @Test func refusalSaysWhoAndWhatToDo() async {
        let claims = Claims(idle: 60, maxWait: 30)
        _ = await claims.tryBegin("gui", session: "ab12", client: "claude-code 2.1.294", origin: "ssh:10.0.0.2", now: t0)
        await claims.finish("gui", session: "ab12", now: t0)
        let h = await claims.holder("gui", now: t0)!
        let text = await claims.refusal("gui", held: h, now: t0.addingTimeInterval(12))
        #expect(text.contains("claude-code 2.1.294 (ssh:10.0.0.2, session ab12)") && text.contains("last acted 12 s ago"))
        #expect(text.contains("lapses after 60 s"))
    }
}
