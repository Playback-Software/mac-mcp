import Foundation
import Testing
@testable import MacMCPCore

private func tempPolicy(_ json: String) -> String {
    let path = NSTemporaryDirectory() + "policy-\(UUID().uuidString).json"
    FileManager.default.createFile(atPath: path, contents: Data(json.utf8))
    return path
}

@Suite struct PolicyTests {
    @Test func olderFilesWithMissingKeysGetDefaults() throws {
        let path = tempPolicy(#"{"deny_apps": ["com.bank.app"], "script": {"allowed_apps": ["TextEdit"]}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = try Policy.current(path: path).get()
        #expect(p.denyApps == ["com.bank.app"] && p.script.allowedApps == ["TextEdit"])
        #expect(p.script.timeoutSeconds == 30 && p.clipboardRead && p.rateLimitPerSecond == 10 && p.allowApps.isEmpty)
        #expect(p.alertWebhook == nil && p.alertCooldownMinutes == 10)
    }

    @Test func missingFileMeansDefaults() throws {
        #expect(try Policy.current(path: "/nonexistent/policy.json").get() == Policy.defaults)
    }

    @Test func invalidFilesFailLoudlyInsteadOfFallingBack() {
        for bad in [#"{"deny_apps": "not-a-list"}"#, "{ nope", #"{"rate_limit_per_second": 0}"#] {
            let path = tempPolicy(bad)
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard case let .failure(e) = Policy.current(path: path) else { Issue.record("accepted invalid policy: \(bad)"); continue }
            #expect(e.description.hasPrefix("POLICY INVALID"))
            #expect(Policy.load(path: path) == Policy.defaults)   // non-gating uses still get sane values
        }
    }

    @Test func denyAndAllowLists() {
        var p = Policy(denyApps: ["com.bank.app"])
        #expect(p.refusal(bundleID: "com.bank.app", name: "Bank")?.contains("deny list") == true)
        #expect(p.permits(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        p.allowApps = ["TextEdit", "com.apple.Safari"]
        #expect(p.permits(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        #expect(p.permits(bundleID: "com.apple.Safari", name: "Safari"))
        #expect(p.refusal(bundleID: "com.apple.finder", name: "Finder")?.contains("not in allow_apps") == true)
        p.denyApps = ["Safari"]
        #expect(!p.permits(bundleID: "com.apple.Safari", name: "Safari"))   // deny wins over allow
    }

    @Test func scriptTargetsHonorAllowApps() {
        let p = Policy(allowApps: ["Finder"], script: .init(allowedApps: ["TextEdit", "Finder"], timeoutSeconds: 30))
        let src = "tell application \"TextEdit\" to get name"
        #expect(Scripts.refusal(source: src, language: .applescript, policy: p)?.contains("not in allow_apps") == true)
    }
}

@Suite struct RateLimiterTests {
    @Test func spacesCallsOutWithoutRejecting() async {
        let limiter = RateLimiter()
        let start = Date()
        var waits: [TimeInterval] = []
        for _ in 0..<4 { waits.append(await limiter.acquire(rate: 20, now: Date())) }
        #expect(waits[0] == 0)
        #expect(Date().timeIntervalSince(start) >= 0.14)   // 3 gaps of 50 ms
    }
}

@Suite struct AlertTests {
    final class Sent: @unchecked Sendable { var count = 0 }

    @Test func throttlesPerKindAndNeedsAWebhook() async {
        let sent = Sent()
        let alerts = Alerts { _, _, _ in sent.count += 1; return true }
        let noHook = Policy()
        #expect(await alerts.notify(.session, "locked", policy: noHook) == false)
        let hook = Policy(alertWebhook: "https://ntfy.example/macmcp", alertCooldownMinutes: 10)
        let t0 = Date()
        #expect(await alerts.notify(.prompt, "prompt", policy: hook, now: t0))
        #expect(await alerts.notify(.prompt, "prompt again", policy: hook, now: t0.addingTimeInterval(60)) == false)
        #expect(await alerts.notify(.permission, "other kind", policy: hook, now: t0.addingTimeInterval(60)))
        #expect(await alerts.notify(.prompt, "later", policy: hook, now: t0.addingTimeInterval(11 * 60)))
        #expect(sent.count == 3)
    }

    @Test func anUndeliveredAlertDoesntStartTheCooldown() async {
        final class Flaky: @unchecked Sendable { var calls = 0 }
        let flaky = Flaky()
        let alerts = Alerts { _, _, _ in flaky.calls += 1; return flaky.calls > 1 }
        let hook = Policy(alertWebhook: "https://ntfy.example/macmcp", alertCooldownMinutes: 10)
        let t0 = Date()
        #expect(await alerts.notify(.prompt, "first", policy: hook, now: t0) == false)
        #expect(await alerts.notify(.prompt, "retry", policy: hook, now: t0.addingTimeInterval(5)))
        #expect(await alerts.notify(.prompt, "throttled", policy: hook, now: t0.addingTimeInterval(10)) == false)
    }
}

@Suite struct AuditRotationTests {
    @Test func rotatesWhenTooLarge() async throws {
        let path = NSTemporaryDirectory() + "audit-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".1") }
        let log = AuditLog(path: path, maxBytes: 300)
        for i in 0..<10 {
            await log.record(AuditEntry(client: "t", tool: "mac_click", arguments: ["ref": "e\(i)"], outcome: "ok", durationMs: 1))
        }
        #expect(FileManager.default.fileExists(atPath: path + ".1"))
        let current = try String(contentsOfFile: path, encoding: .utf8)
        #expect(current.utf8.count <= 300 + 200)
        #expect(current.contains("\"e9\""))
    }
}

@Suite struct AppLookupTests {
    @Test func findsAppsOutsideTheApplicationsFolders() {
        let finder = Apps.bundleURL(for: "Finder").flatMap { Bundle(url: $0)?.bundleIdentifier }
        #expect(finder == "com.apple.finder")
        let p = Policy(script: .init(allowedApps: ["com.apple.finder"], timeoutSeconds: 30))
        #expect(Scripts.refusal(source: "tell application \"Finder\" to get name", language: .applescript, policy: p) == nil)
    }
}

@Suite struct PolicyFileTests {
    @Test func unreadablePolicyFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .failure = Policy.current(path: dir.path) else { Issue.record("a directory loaded as a policy"); return }
        guard case .success = Policy.current(path: dir.appendingPathComponent("missing.json").path) else {
            Issue.record("a missing file should mean the defaults"); return
        }
    }
}

@Suite struct WebPolicyTests {
    @Test func trailingDotsAndURLEntriesMatch() {
        let w = Policy.WebPolicy(denyHosts: ["bank.com", "https://Wallet.example:443/login"])
        #expect(w.refusal(url: "https://bank.com./") != nil)
        #expect(w.refusal(url: "https://www.bank.com../x") != nil)
        #expect(w.refusal(url: "https://wallet.example/") != nil)
        #expect(w.refusal(url: "https://notbank.com/") == nil)
    }

    @Test func onlyHTTPAndHostLists() {
        var w = Policy.WebPolicy()
        #expect(w.refusal(url: "https://example.com/a") == nil)
        #expect(w.refusal(url: "about:blank") == nil)
        for bad in ["file:///etc/hosts", "data:text/html,hi", "javascript:alert(1)", "ftp://x.org", "not a url"] {
            #expect(w.refusal(url: bad)?.contains("only open http(s)") == true, "\(bad)")
        }
        w.denyHosts = ["bank.com"]
        #expect(w.refusal(url: "https://www.bank.com/login")?.contains("deny_hosts") == true)
        #expect(w.refusal(url: "https://bank.com")?.contains("deny_hosts") == true)
        #expect(w.refusal(url: "https://notbank.com") == nil)   // a suffix match must be a whole label
        w.allowHosts = ["example.com"]
        #expect(w.refusal(url: "https://docs.example.com") == nil)
        #expect(w.refusal(url: "https://other.org")?.contains("allow_hosts") == true)
        w.enabled = false
        #expect(w.refusal(url: "https://example.com")?.contains("turned off") == true)
    }

    @Test func olderPolicyFilesGetWebDefaults() throws {
        let path = tempPolicy(#"{"deny_apps": []}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = try Policy.current(path: path).get()
        #expect(p.web == Policy.WebPolicy() && p.web.enabled && !p.web.evalAllowed)
        let custom = tempPolicy(#"{"web": {"eval_allowed": true, "deny_hosts": ["x.com"]}}"#)
        defer { try? FileManager.default.removeItem(atPath: custom) }
        let q = try Policy.current(path: custom).get()
        #expect(q.web.evalAllowed && q.web.denyHosts == ["x.com"] && q.web.enabled)
    }
}

@Suite struct SaferDefaultTests {
    @Test func shellAndSecretAppsAreDeniedByDefault() {
        let p = Policy()
        for id in ["com.apple.Terminal", "com.apple.keychainaccess", "com.apple.systempreferences", "com.apple.ScriptEditor2"] {
            #expect(p.refusal(bundleID: id, name: nil)?.contains("deny list") == true, "\(id)")
        }
        #expect(p.permits(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        // A file without deny_apps gets the defaults; one that sets it gets exactly what it says.
        let absent = try! JSONDecoder().decode(Policy.self, from: Data("{}".utf8))
        #expect(absent.denyApps == Policy.defaultDenyApps)
        let set = try! JSONDecoder().decode(Policy.self, from: Data(#"{"deny_apps": []}"#.utf8))
        #expect(set.permits(bundleID: "com.apple.Terminal", name: "Terminal"))
    }

    @Test func privateAddressesNeedAnOptIn() {
        let w = Policy.WebPolicy()
        for url in ["http://localhost:3000/", "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/",
                    "http://10.0.0.5/", "http://172.20.1.1/", "http://192.168.1.1/", "http://169.254.169.254/latest/",
                    "http://[::1]/", "http://[fe80::1]/", "http://[fd00::2]/", "http://[::ffff:192.168.0.1]/",
                    "http://printer.local/", "http://app.localhost/", "http://0.0.0.0/", "http://100.64.0.1/"] {
            #expect(w.refusal(url: url)?.contains("private-network") == true, "\(url)")
        }
        for url in ["https://example.com/", "http://8.8.8.8/", "http://172.32.0.1/", "http://[2606:4700::1111]/",
                    "https://cafe.be/", "https://deadbeef.example/"] {
            #expect(w.refusal(url: url) == nil, "\(url)")
        }
        #expect(Policy.WebPolicy(allowPrivateHosts: true).refusal(url: "http://127.0.0.1/") == nil)
        #expect(Policy.WebPolicy(allowHosts: ["127.0.0.1"]).refusal(url: "http://127.0.0.1:8899/") == nil)
        #expect(Policy.WebPolicy(allowHosts: ["127.0.0.1"]).refusal(url: "http://10.0.0.1/") != nil)
    }
}

@Suite struct HardeningDefaultsTests {
    @Test func appNamesAreNotPaths() {
        #expect(Apps.bundleURL(for: "../System/Applications/TextEdit") == nil)
        #expect(Apps.bundleURL(for: "/System/Applications/TextEdit.app") == nil)
        #expect(Apps.bundleURL(for: "TextEdit") != nil)
    }

    @Test func leaseFilesAreNeverReadableByOthers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(UUID().uuidString).json").path
        defer { unlink(path) }
        try LeaseStore.writePrivately(Data("{}".utf8), to: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(FileManager.default.contents(atPath: path) == Data("{}".utf8))
    }

    @Test func windowMovesStayOnADisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let current = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowControl.frameRefusal(current, origin: nil, size: CGSize(width: 0, height: 300), displays: displays) != nil)
        #expect(WindowControl.frameRefusal(current, origin: nil, size: CGSize(width: -5, height: 300), displays: displays) != nil)
        #expect(WindowControl.frameRefusal(current, origin: CGPoint(x: 5000, y: 5000), size: nil, displays: displays) != nil)
        #expect(WindowControl.frameRefusal(current, origin: CGPoint(x: -790, y: 0), size: nil, displays: displays) != nil)
        #expect(WindowControl.frameRefusal(current, origin: CGPoint(x: -700, y: 0), size: nil, displays: displays) == nil)
        #expect(WindowControl.frameRefusal(current, origin: CGPoint(x: 200, y: 50), size: CGSize(width: 640, height: 480), displays: displays) == nil)
    }

    @Test func numericWindowSelectorsFallBackToTitles() {
        func w(_ i: Int, _ title: String) -> WindowEntry {
            WindowEntry(index: i, element: .systemWide, title: title, frame: nil, isMain: i == 1, isFocused: i == 1,
                        isMinimized: false, subrole: nil)
        }
        let all = [w(1, "Inbox"), w(2, "Budget 2024"), w(3, "Notes")]
        #expect(WindowControl.pick(all, "2")?.title == "Budget 2024")
        #expect(WindowControl.pick(all, "2024")?.title == "Budget 2024")
        #expect(WindowControl.pick(all, "notes")?.index == 3)
        #expect(WindowControl.pick(all, "9") == nil)
    }
}

@Suite struct DisplayOrderTests {
    @Test func mainFirstThenLeftToRightThenTopToBottom() {
        let order = Displays.order([(id: 3, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080)),
                                    (id: 7, bounds: CGRect(x: -1280, y: -200, width: 1280, height: 800)),
                                    (id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                                    (id: 9, bounds: CGRect(x: 1440, y: -1080, width: 1920, height: 1080))], main: 1)
        #expect(order.map(\.id) == [1, 7, 9, 3])
    }

    @Test func findsByIndexIDOrMain() {
        let ds = [Displays.Display(index: 1, id: 69_734_208, bounds: .zero, scale: 2, isMain: true, name: "Built-in"),
                  Displays.Display(index: 2, id: 5, bounds: .zero, scale: 1, isMain: false, name: "DELL")]
        #expect(Displays.find("2", in: ds)?.name == "DELL")
        #expect(Displays.find("69734208", in: ds)?.index == 1)
        #expect(Displays.find("main", in: ds)?.index == 1)
        #expect(Displays.find("3", in: ds) == nil)
    }
}
