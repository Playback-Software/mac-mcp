import Foundation
import Synchronization
import Testing
import MacMCPCore
@testable import MacMCPServer

/// A loopback-only fixture. Chrome runs headless with a fresh profile, not the installed agent or a person's GUI.
private final class ChromeFixture: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    let finished = DispatchGroup()
    private let stopped = Mutex(false)
    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        fd = socketFD
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socketFD, 8) == 0 else { Darwin.close(socketFD); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        finished.enter()
        Thread { [self] in
            defer { finished.leave() }
            while !stopped.withLock({ $0 }) {
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 100) > 0 else { continue }
                if stopped.withLock({ $0 }) { return }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 8192)
                _ = Darwin.read(client, &buffer, buffer.count)
                let html = """
                    <!doctype html><html><head><title>MacMCP Chrome fixture</title></head><body>
                    <label>Name <input id="name" aria-label="Name"></label>
                    <button onclick="document.querySelector('#status').textContent='Submitted'">Submit</button>
                    <button onclick="document.querySelector('#status').textContent=confirm('Continue?')?'Confirmed':'Cancelled'">Confirm</button>
                    <p id="status">Ready</p><input type="file" aria-label="Upload">
                    </body></html>
                    """
                let body = Data(html.utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                response.withUnsafeBytes { bytes in _ = send(client, bytes.baseAddress, bytes.count, 0) }
                Darwin.close(client)
            }
        }.start()
    }
    func close() {
        stopped.withLock { $0 = true }
        shutdown(fd, SHUT_RDWR)
        finished.wait() // The listener must stop before this descriptor can be reused by another fixture.
        Darwin.close(fd)
    }
}

@Suite(.serialized) struct ChromeBridgeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_MCP_CHROME_TEST"] == "1", "Opt in to isolated headless Chrome tests"))
    func isolatedChromeReadsActsVerifiesAndRejectsStaleOrForbiddenTargets() async throws {
        let fixture = try ChromeFixture(); defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macmcp-chrome-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ChromeBridge(profileRoot: root) {
            var policy = Policy(); policy.web.allowPrivateHosts = true; policy.web.evalAllowed = true; policy.web.denyHosts = ["forbidden.example"]
            return policy
        }
        var phase = "navigation"
        do {
            let page = try await bridge.call("navigate_to_url", ["url": .string("http://127.0.0.1:\(fixture.port)/")])
            let text = try #require(page.json?["content"]?.stringValue)
            #expect(text.contains("MacMCP Chrome fixture") && text.contains("Name"))
            func uid(_ label: String) throws -> String {
                let line = try #require(text.split(separator: "\n").first { $0.hasSuffix("\"\(label)\"") && $0.hasPrefix("uid=") })
                return String(try #require(line.split(separator: " ").first).dropFirst(4))
            }
            let name = try uid("Name"), submit = try uid("Submit"), upload = try uid("Upload")
            phase = "typing and click"
            let typed = try await bridge.call("page_interactions", ["interactions": [
                ["type": "type", "node": .string(name), "value": "Ada", "replaceAll": true],
                ["type": "type", "node": .string(name), "value": " Lovelace", "replaceAll": false],
                ["type": "click", "node": .string(submit)],
            ]])
            #expect(typed.json?["successful"] == 3)
            #expect(typed.json?["content"]?.stringValue?.contains("Submitted") == true)
            phase = "screenshot"
            let screenshot = try await bridge.call("screenshot")
            #expect(Data(base64Encoded: screenshot.json?["data"]?.stringValue ?? "")?.starts(with: [137,80,78,71]) == true)
            let confirm = try uid("Confirm")
            phase = "JavaScript dialog"
            let interaction = try await bridge.interact(["interactions": [["type": "click", "node": .string(confirm)]]])
            if case let .dialog(message) = interaction { #expect(message == "Continue?") }
            else { Issue.record("Chrome did not report the open dialog") }
            _ = try await bridge.call("browser_dialogs", ["action": "respond"])
            let completed = try #require(await bridge.finishParked())
            #expect(completed.json?["successful"] == 1 && completed.json?["content"]?.stringValue?.contains("Confirmed") == true)
            phase = "upload refusal"
            let rejected = try await bridge.call("page_interactions", ["interactions": [["type": "click", "node": .string(upload)]]])
            #expect(rejected.json?["successful"] == 0 && rejected.json?["failureReason"]?.stringValue?.contains("File uploads") == true)
            phase = "changed label refusal"
            _ = try await bridge.call("evaluate_javascript", ["expression": "document.querySelector('button').textContent='Changed'"])
            let changed = try await bridge.call("page_interactions", ["interactions": [["type": "click", "node": .string(submit)]]])
            #expect(changed.json?["successful"] == 0, "Bookkeeping must not pretend a changed label was shown")
            phase = "hidden UID refusal"
            _ = try await bridge.call("evaluate_javascript", ["expression": "const b=document.createElement('button'); b.textContent='Hidden'; b.onclick=()=>document.querySelector('#status').textContent='Hidden hit'; document.body.appendChild(b);"])
            _ = try await AutomationBrowser.$maxChars.withValue(0) {
                try await bridge.call("get_page_content")
            }
            let ordinals = text.split(separator: "\n").filter { $0.hasPrefix("uid=") }.compactMap {
                $0.split(separator: " ").first?.split(separator: "-").last.flatMap { Int($0) }
            }
            let ordinal = try #require(ordinals.max())
            let parts = name.split(separator: "-")
            let guessed = parts.dropLast().joined(separator: "-") + "-" + String(ordinal + 1)
            let hidden = try await bridge.call("page_interactions", ["interactions": [["type": "click", "node": .string(guessed)]]])
            #expect(hidden.json?["successful"] == 0, "An output-truncated UID must not become actionable through bookkeeping")
            phase = "stale UID refusal"
            _ = try await bridge.call("navigate_to_url", ["url": "about:blank"])
            let stale = try await bridge.call("page_interactions", ["interactions": [["type": "click", "node": .string(submit)]]])
            #expect(stale.json?["successful"] == 0)
            phase = "URL refusals"
            await #expect(throws: (any Error).self) { try await bridge.call("navigate_to_url", ["url": "file:///etc/passwd"]) }
            await #expect(throws: (any Error).self) { try await bridge.call("navigate_to_url", ["url": "https://forbidden.example/"]) }
            #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).allSatisfy { $0.lastPathComponent.hasPrefix("chrome-automation-") })
        } catch { Issue.record("Chrome fixture failed during \(phase)"); await bridge.stop(); throw error }
        await bridge.stop()
        #expect(await bridge.started == false)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_MCP_CHROME_TEST"] == "1", "Opt in to isolated headless Chrome tests"))
    func cancellationClosesAStalledBrowserBeforeAnotherTurn() async throws {
        let fixture = try ChromeFixture(); defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macmcp-chrome-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ChromeBridge(profileRoot: root) {
            var p = Policy(); p.web.allowPrivateHosts = true; p.web.evalAllowed = true; return p
        }
        do {
            _ = try await bridge.call("navigate_to_url", ["url": .string("http://127.0.0.1:\(fixture.port)/")])
            let task = Task { try await bridge.call("evaluate_javascript", ["expression": "while(true){}"], timeout: 30) }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            if case .success = await task.result { Issue.record("Cancelled script reported success") }
            #expect(await bridge.started == false)
            let fresh = try await bridge.call("list_tabs")
            #expect(fresh.json?.arrayValue?.isEmpty == true, "A new turn uses a new empty context")
            _ = try await bridge.call("navigate_to_url", ["url": .string("http://127.0.0.1:\(fixture.port)/")])
            await #expect(throws: (any Error).self) {
                try await bridge.call("evaluate_javascript", ["expression": "while(true){}"], timeout: 0.05)
            }
            let next = try await bridge.call("list_tabs")
            #expect(next.json?.arrayValue?.isEmpty == true)
        } catch { await bridge.stop(); throw error }
        await bridge.stop()
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }
}
