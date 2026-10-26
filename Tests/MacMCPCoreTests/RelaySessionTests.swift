import Foundation
import Testing
@testable import MacMCPCore

@Suite struct RelaySessionTests {
    func line(_ json: String) -> Data { Data(json.utf8) }
    func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    func texts(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
    let initResult = #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}"#
    let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    func call(_ id: String) -> String { #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"mac_doctor"}}"# }
    func result(_ id: String) -> String { #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[]}}"# }

    /// A session through a completed handshake.
    func handshaken() -> RelaySession {
        var s = RelaySession()
        _ = s.fromClient(line(initialize))
        _ = s.fromAgent(line(initResult))
        _ = s.fromClient(line(initialized))
        return s
    }

    @Test func messagesPassThroughUnchanged() {
        var s = RelaySession()
        let request = line(initialize)
        #expect(s.fromClient(request) == .init(toAgent: [request]))
        let response = line(initResult)
        #expect(s.fromAgent(response) == .init(toClient: [response]))
        let notification = line(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#)
        #expect(s.fromAgent(notification) == .init(toClient: [notification]))
        let garbage = line("not json")
        #expect(s.fromClient(garbage) == .init(toAgent: [garbage]))
    }

    @Test func tracksInFlightRequestsByIdType() {
        var s = handshaken()
        _ = s.fromClient(line(call("7")))
        _ = s.fromClient(line(call(#""7""#)))
        _ = s.fromClient(line(call(#""abc""#)))
        #expect(s.inFlight == ["7", #""7""#, #""abc""#])
        _ = s.fromAgent(line(result(#""7""#)))
        #expect(s.inFlight == ["7", #""abc""#])
        _ = s.fromAgent(line(#"{"jsonrpc":"2.0","id":"abc","error":{"code":-1,"message":"x"}}"#))
        #expect(s.inFlight == ["7"])
        // Notifications and the client's answers to agent requests aren't tracked.
        _ = s.fromClient(line(#"{"jsonrpc":"2.0","id":99,"result":{}}"#))
        _ = s.fromClient(line(#"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#))
        #expect(s.inFlight == ["7"])
    }

    @Test func cancelledRequestsAreNoLongerInFlight() {
        var s = handshaken()
        _ = s.fromClient(line(call("5")))
        _ = s.fromClient(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#))
        #expect(s.inFlight.isEmpty)
    }

    @Test func losingTheAgentAnswersInFlightRequestsWithErrors() {
        var s = handshaken()
        _ = s.fromClient(line(call("3")))
        _ = s.fromClient(line(call(#""x""#)))
        let out = s.agentLost()
        #expect(out.toAgent.isEmpty)
        #expect(out.toClient.count == 2)
        let first = object(out.toClient[0]), second = object(out.toClient[1])
        #expect(first["jsonrpc"] as? String == "2.0")
        #expect(first["id"] as? Int == 3)
        #expect(second["id"] as? String == "x")
        let error = first["error"] as? [String: Any]
        #expect(error?["code"] as? Int == RelaySession.errorCode)
        #expect((error?["message"] as? String)?.contains("restarted") == true)
        #expect(s.inFlight.isEmpty)
        #expect(s.phase == .reconnecting)
    }

    @Test func errorMessagesAreValidJSON() {
        let data = RelaySession.errorResponse(id: #""a\"b""#, message: "quote \" and\nnewline")
        let o = object(data)
        #expect(o["id"] as? String == "a\"b")
        #expect((o["error"] as? [String: Any])?["message"] as? String == "quote \" and\nnewline")
    }

    @Test func reconnectReplaysTheHandshakeAndSwallowsItsResponse() throws {
        var s = handshaken()
        _ = s.fromClient(line(call("1")))
        _ = s.agentLost()

        // Held while the agent is away; the client's answer to the old agent's request is dropped.
        #expect(s.fromClient(line(call("2"))) == .init())
        #expect(s.fromClient(line(#"{"jsonrpc":"2.0","id":42,"result":{}}"#)) == .init())
        #expect(s.held.count == 1)

        let reconnected = s.agentReconnected()
        #expect(s.phase == .replaying)
        #expect(reconnected.toClient.isEmpty)
        let replay = try #require(reconnected.toAgent.first.map(object))
        #expect(reconnected.toAgent.count == 1)
        #expect(replay["method"] as? String == "initialize")
        #expect((replay["params"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        let replayID = try #require(replay["id"] as? String)

        // Still held until the replayed initialize is answered.
        #expect(s.fromClient(line(call("3"))) == .init())

        // An agent request during replay reaches the client.
        let ping = line(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(s.fromAgent(ping) == .init(toClient: [ping]))

        let answered = s.fromAgent(line(#"{"jsonrpc":"2.0","id":"\#(replayID)","result":{"protocolVersion":"2025-11-25"}}"#))
        #expect(answered.toClient.isEmpty)
        #expect(texts(answered.toAgent) == [initialized, call("2"), call("3")])
        #expect(s.phase == .connected)
        #expect(s.inFlight == ["2", "3"])
        #expect(s.held.isEmpty)

        // Back to passing through.
        #expect(s.fromClient(line(call("4"))) == .init(toAgent: [line(call("4"))]))
    }

    @Test func eachReplayUsesAFreshId() throws {
        var s = handshaken()
        _ = s.agentLost()
        let a = try #require(s.agentReconnected().toAgent.first.map(object)?["id"] as? String)
        _ = s.agentLost()  // died during the replay
        #expect(s.phase == .reconnecting)
        let b = try #require(s.agentReconnected().toAgent.first.map(object)?["id"] as? String)
        #expect(a != b)
        // A late answer to the first replay is not mistaken for the second.
        _ = s.fromAgent(line(#"{"jsonrpc":"2.0","id":"\#(a)","result":{}}"#))
        #expect(s.phase == .replaying)
    }

    @Test func withoutACompletedHandshakeHeldMessagesGoStraightOut() {
        // The connection dropped before the client's initialize was answered: it gets an error, and whatever
        // it sends next (likely a fresh initialize) is delivered as-is.
        var s = RelaySession()
        _ = s.fromClient(line(initialize))
        let lost = s.agentLost()
        #expect(object(lost.toClient[0])["id"] as? Int == 0)
        _ = s.fromClient(line(initialize))
        let out = s.agentReconnected()
        #expect(s.phase == .connected)
        #expect(out.toAgent == [line(initialize)])
    }

    @Test func failedInitializeIsNotReplayed() {
        var s = RelaySession()
        _ = s.fromClient(line(initialize))
        _ = s.fromAgent(line(#"{"jsonrpc":"2.0","id":0,"error":{"code":-32602,"message":"bad version"}}"#))
        _ = s.agentLost()
        #expect(s.agentReconnected().toAgent.isEmpty)
        #expect(s.phase == .connected)
    }

    @Test func givingUpAnswersHeldRequests() {
        var s = handshaken()
        _ = s.fromClient(line(call("1")))
        _ = s.agentLost()
        _ = s.fromClient(line(call("2")))
        _ = s.fromClient(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
        let out = s.giveUp(reason: "gone for good")
        #expect(out.toClient.count == 1)
        let error = object(out.toClient[0])
        #expect(error["id"] as? Int == 2)
        #expect((error["error"] as? [String: Any])?["message"] as? String == "gone for good")
        #expect(s.held.isEmpty)
    }

    @Test func lineBufferSplitsAcrossReads() {
        var b = LineBuffer()
        #expect(b.append(Array("{\"a\":".utf8)).isEmpty)
        #expect(texts(b.append(Array("1}\n\n  \r\n{\"b\":2}\n{\"c\"".utf8))) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(texts(b.append(Array(":3}\n".utf8))) == [#"{"c":3}"#])
    }
}
