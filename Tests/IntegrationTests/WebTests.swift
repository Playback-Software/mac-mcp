import Foundation
import Testing
import MacMCPCore

/// The baseline fixture server (baseline/webserver.py) on 127.0.0.1:8899, started for these tests if needed.
let webFixtures: Process? = {
    if localPortOpen(8899) { return nil }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../baseline")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", root.appendingPathComponent("webserver.py").path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    Thread.sleep(forTimeInterval: 1)
    return p
}()

func localPortOpen(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0
    }
}

/// The fixture server is on 127.0.0.1, which the default policy refuses as a private address.
func withFixtureHost(_ body: () throws -> Void) throws {
    try withPolicy(#"{"web": {"allow_hosts": ["127.0.0.1"]}}"#, body)
}

func uid(_ field: String, in page: String) -> String? {
    page.split(separator: "\n").first { $0.contains("name=\(field)") }
        .flatMap { $0.firstMatch(of: /uid=(\d+)/).map { String($0.1) } }
}

extension Integration {
@Suite struct WebTests {
    init() { _ = webFixtures }

    /// Safari's navigate_to_url replies in the format of the last page read, so a markdown read must not cost the
    /// next navigation its uids.
    @Test func navigationKeepsUIDsAfterAMarkdownRead() throws {
        try withFixtureHost {
            #expect(!(try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])).isError)
            let markdown = try agent().call("web_read", ["as": "markdown"])
            #expect(!markdown.isError && markdown.text.contains("Pizza Order") && !markdown.text.contains("uid="), "\(markdown.text)")
            let page = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/confirm.html"])
            #expect(page.text.contains("uid="), "\(page.text)")
        }
    }

    @Test func fillAndSubmitAFormWithVerifiedTyping() throws {
        try withPolicy(#"{"web": {"eval_allowed": true, "allow_hosts": ["127.0.0.1"]}}"#) {
            let page = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(!page.isError, "\(page.text)")
            let name = try #require(uid("custname", in: page.text)), tel = try #require(uid("custtel", in: page.text))
            let filled = try agent().call("web_act", ["actions": [
                ["do": "type", "node": name, "value": "Grace Hopper"],
                ["do": "type", "node": tel, "value": "555-0199"],
                ["do": "click", "find": "Large"],
            ]])
            #expect(!filled.isError && filled.text.contains("did 3 of 3"), "\(filled.text)")
            let sent = try agent().call("web_act", ["actions": [["do": "click", "find": "Submit order"]]])
            #expect(sent.text.contains("/submit"), "\(sent.text)")
            // What the server received, as its reply page echoes it (JSON in a <pre>). Not baseline/state/web.log: the
            // server on 8899 may have been started from another checkout, and then it logs there.
            let received = try agent().call("web_eval", ["expression": "return JSON.parse(document.querySelector('pre').textContent)"])
            let result = unmarked(received.text).replacing("Result:", with: "")
            let fields = try #require(try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: [String]], "\(received.text)")
            #expect(fields["custname"] == ["Grace Hopper"] && fields["custtel"] == ["555-0199"] && fields["size"] == ["large"])
        }
    }

    @Test func staleNodesAndBadStepsFailLoudly() throws {
        try withFixtureHost {
            let page = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(!page.isError)
            let stale = try agent().call("web_act", ["actions": [["do": "type", "node": "999999", "value": "x"]]])
            #expect(stale.isError, "\(stale.text)")
            let bad = try agent().call("web_act", ["actions": [["do": "type", "node": "1"]]])
            #expect(bad.isError && bad.text.contains("needs value="))
        }
    }

    @Test func policyGatesHostsSchemesAndJavaScript() throws {
        #expect(try agent().call("web_navigate", ["url": "file:///etc/hosts"]).text.contains("only open http(s)"))
        #expect(try agent().call("web_eval", ["expression": "return 1"]).text.contains("web_eval is off"))
        try withPolicy("{}") {
            let r = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(r.isError && r.text.contains("private-network"), "\(r.text)")
        }
        try withPolicy(#"{"web": {"deny_hosts": ["127.0.0.1"]}}"#) {
            let r = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(r.isError && r.text.contains("deny_hosts"), "\(r.text)")
        }
        try withPolicy(#"{"deny_apps": ["com.apple.Safari"]}"#) {
            let r = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            #expect(r.isError && r.text.contains("deny list"), "\(r.text)")
        }
    }

    @Test func dialogsCanBeAnswered() throws {
        try withPolicy(#"{"web": {"eval_allowed": true, "allow_hosts": ["127.0.0.1"]}}"#) {
            _ = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            let r = try agent().call("web_eval", ["expression": "setTimeout(() => alert('Session expired'), 10); return 'ok'"])
            #expect(r.text.contains("ok"), "\(r.text)")
            Thread.sleep(forTimeInterval: 0.5)
            #expect(try agent().call("web_dialog", [:]).text.contains("Session expired"))
            #expect(!(try agent().call("web_dialog", ["action": "dismiss"])).isError)
        }
    }

    @Test func promptInputStaysOutOfTheAuditLog() throws {
        try withPolicy(#"{"web": {"eval_allowed": true, "allow_hosts": ["127.0.0.1"]}}"#) {
            #expect(!(try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])).isError)
            let opened = try agent().call("web_eval", ["expression": "setTimeout(() => prompt('Audit test prompt'), 10); return 'ok'"])
            #expect(!opened.isError, "\(opened.text)")
            Thread.sleep(forTimeInterval: 0.5)
            let started = Date()
            let input = "synthetic-private-input-" + UUID().uuidString
            let response = try agent().call("web_dialog", ["action": "accept", "text": input])
            #expect(!response.isError, "\(response.text)")
            let entry = try #require(UsageReport.load().last { $0.tool == "web_dialog" && $0.time >= started.addingTimeInterval(-1) })
            #expect(entry.arguments["text"]?.hasPrefix("[REDACTED") == true)
            #expect(entry.detail?.contains(input) != true)
        }
    }

    /// A click that opens confirm() blocks the page; web_act must come back with the question instead of hanging,
    /// and web_dialog must answer it and report how the interrupted click ended.
    @Test func clickThatOpensAConfirmDialog() throws {
        try withFixtureHost {
            let page = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/confirm.html"])
            let button = try #require(page.text.split(separator: "\n").first { $0.contains("Delete everything") }
                .flatMap { $0.firstMatch(of: /uid=(\d+)/).map { String($0.1) } })
            let start = Date()
            let clicked = try agent().call("web_act", ["actions": [["do": "click", "node": button]]])
            #expect(clicked.text.contains("Are you sure you want to delete everything?"), "\(clicked.text)")
            #expect(Date().timeIntervalSince(start) < 10)
            let answered = try agent().call("web_dialog", ["action": "dismiss"])
            #expect(!answered.isError && answered.text.contains("Result: cancelled"), "\(answered.text)")
        }
    }

    @Test func screenshotAndAutomationBrowserIsMarked() throws {
        try withFixtureHost {
            _ = try agent().call("web_navigate", ["url": "http://127.0.0.1:8899/form.html"])
            let shot = try agent().call("web_read", ["as": "screenshot", "max_edge": 500])
            #expect(!shot.isError && shot.images.count == 1, "\(shot.text)")
            #expect(try agent().call("mac_app", ["action": "list"]).text.contains("[automation browser: use the web_* tools]"))
        }
    }
}
}
