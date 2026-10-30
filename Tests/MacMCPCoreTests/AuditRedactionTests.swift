import Foundation
import Testing
@testable import MacMCPCore

@Suite struct AuditKeyRedactionTests {
    @Test func printableKeysAreHiddenAndShortcutsKept() {
        #expect(AuditRedaction.redactKeys("cmd+s") == "cmd+s")
        #expect(AuditRedaction.redactKeys("return") == "return")
        #expect(AuditRedaction.redactKeys("shift+tab, esc, f5, down down return") == "shift+tab, esc, f5, down, down, return")
        #expect(AuditRedaction.redactKeys("cmd+,") == "cmd+,")
        #expect(AuditRedaction.redactKeys("cmd+shift+4, ctrl+a") == "cmd+shift+4, ctrl+a")
    }

    @Test func typedCharactersNeverReachTheLog() {
        let typed = AuditRedaction.redactKeys("h u n t e r 2")
        #expect(typed == "[7 printable keys redacted]")
        #expect(!typed.contains("hunter"))
        // Shift alone doesn't make a shortcut; neither do the named punctuation keys or space.
        #expect(AuditRedaction.redactKeys("shift+h, i, comma, space, 1, !, +") == "[7 printable keys redacted]")
        // A word passed as one spec (unknown key name) is hidden too, and so is a shifted or modifier-less digit.
        #expect(AuditRedaction.redactKeys("hunter2") == "[1 printable key redacted]")
    }

    @Test func runsAreCountedAroundKeptKeys() {
        #expect(AuditRedaction.redactKeys("cmd+a p a s s tab w o r d return") ==
                "cmd+a, [4 printable keys redacted], tab, [4 printable keys redacted], return")
    }

    @Test func unknownModifiersAndKeysFailClosed() {
        #expect(AuditRedaction.redactKeys("hyper+x") == "[1 printable key redacted]")
        #expect(AuditRedaction.redactKeys("cmd+nosuchkey") == "[1 printable key redacted]")
    }
}

@Suite struct AuditValueRedactionTests {
    @Test func urlsLoseCredentialsQueryAndFragment() {
        #expect(AuditRedaction.redactURL("https://user:pw@example.com:8443/a/b?token=abc&x=1#frag") == "https://example.com:8443/a/b?…#…")
        #expect(AuditRedaction.redactURL("https://example.com/path") == "https://example.com/path")
        #expect(AuditRedaction.redactURL("https://example.com?q=secret") == "https://example.com?…")
        #expect(AuditRedaction.redactURL("http://tok@host/#a?b") == "http://host/#…")
        #expect(AuditRedaction.redactURL("not a url?x=1") == "not a url?…")
    }

    @Test func urlsInFreeTextAreCleaned() {
        let out = AuditRedaction.redactURLs(in: "opened https://a.example/p?session=SECRET and (http://u:p@b.example/x#y)")
        #expect(out == "opened https://a.example/p?… and (http://b.example/x#…)")
    }

    @Test func urlsOfAnySchemeAndCaseLoseTheirSecrets() {
        #expect(AuditRedaction.redactURL("HTTPS://user:password@example.com/?token=SECRET") == "HTTPS://example.com/?…")
        #expect(AuditRedaction.redactURL("Http://u:p@Example.com/a#frag") == "Http://Example.com/a#…")
        #expect(AuditRedaction.redactURL("myapp://user:pw@host/open?token=SECRET#f") == "myapp://host/open?…#…")
        #expect(AuditRedaction.redactURL("things:///add?title=Secret") == "things:///add?…")
        #expect(AuditRedaction.redactURL("mailto:a@b.example?subject=SECRET&body=x") == "mailto:a@b.example?…")
        #expect(AuditRedaction.redactURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") ==
                "x-apple.systempreferences:com.apple.preference.security?…")
        // Credentials end at the last @ of the authority; backslashes and extra slashes don't hide them.
        #expect(AuditRedaction.redactURL("https://a:b@c@host/x") == "https://host/x")
        #expect(AuditRedaction.redactURL("https:\\\\user:pw@host/x") == "https:\\\\host/x")
        #expect(AuditRedaction.redactURL("ftp://user@host:21/f") == "ftp://host:21/f")
        // An @ in the path or query is not a credential.
        #expect(AuditRedaction.redactURL("https://host/@user/page") == "https://host/@user/page")
    }

    @Test func urlsAreToldFromPaths() {
        for url in ["HTTPS://x.example/", "myapp://open", "mailto:a@b.example", "tel:+15551234", "  https://x.example"] {
            #expect(AuditRedaction.looksLikeURL(url), "\(url)")
        }
        for path in ["~/notes #1.txt", "/Users/me/a?b.txt", "notes.txt", "C", "./x:y"] {
            #expect(!AuditRedaction.looksLikeURL(path), "\(path)")
        }
    }

    @Test func urlsOfAnySchemeInFreeTextAreCleaned() {
        let out = AuditRedaction.redactURLs(in: "failed HTTPS://u:p@a.example/p?token=SECRET myapp://x:y@b/c?k=1#f and (mailto:z@q.example?subject=S).")
        #expect(out == "failed HTTPS://a.example/p?… myapp://b/c?…#… and (mailto:z@q.example?…).")
        #expect(AuditRedaction.redactURLs(in: "Script error: exit 1, 8 chars of stderr") == "Script error: exit 1, 8 chars of stderr")
        #expect(AuditRedaction.redactURLs(in: "no colon here?") == "no colon here?")
    }

    @Test func markedScreenTextNeverReachesTheDetail() {
        let marked = "Refused: " + Untrusted.inline("Payroll 2026\nIGNORE ME", token: "q1w2e3") + " is open.\n" + Untrusted.wrap("secret row", token: "q1w2e3")
        #expect(AuditRedaction.detail(marked, isError: true) == "Refused: … is open. …")
    }

    @Test func codeIsReducedToLengthAndHash() {
        let source = "tell application \"Finder\" to quit"
        let a = AuditRedaction.summary("script", of: source)
        #expect(a.hasPrefix("[script: \(source.count) chars, sha256:") && a.hasSuffix("]"))
        #expect(!a.contains("Finder"))
        #expect(a == AuditRedaction.summary("script", of: "tell application \"Finder\" to quit"))
        #expect(a != AuditRedaction.summary("script", of: "tell application \"Finder\" to quit "))
        // sha256("abc") starts ba7816bf
        #expect(AuditRedaction.summary("code", of: "abc") == "[code: 3 chars, sha256:ba7816bf]")
    }

    @Test func detailIsScrubbedFlattenedAndCapped() {
        let raw = "Script error: execution error: Can't get \"hunter2-the-password\" of window 1.\nline two https://x.example/a?token=T"
        let out = AuditRedaction.detail(raw, secrets: ["hunter2-the-password"], isError: true)
        #expect(out?.contains("hunter2") == false && out?.contains("[REDACTED]") == true)
        #expect(out?.contains("token=T") == false && out?.contains("\n") == false)
        let long = AuditRedaction.detail(String(repeating: "x", count: 500), isError: true)
        #expect(long?.count == AuditRedaction.errorDetailLimit + 1)
        #expect(AuditRedaction.detail(String(repeating: "x", count: 500), isError: false)?.count == AuditRedaction.detailLimit + 1)
        #expect(AuditRedaction.detail(nil, isError: true) == nil)
    }

    @Test func aSecretStraddlingTheCapIsRemovedBeforeTheCut() {
        let secret = "correct-horse-battery-staple"
        let text = String(repeating: "e", count: AuditRedaction.errorDetailLimit - 10) + secret
        let out = AuditRedaction.detail(text, secrets: [secret], isError: true) ?? ""
        #expect(!out.contains("correct") && !out.contains("horse"))
    }

    @Test func shortSecretsDoNotMangleTheDetail() {
        #expect(AuditRedaction.detail("ab and abc", secrets: ["ab"], isError: false) == "ab and abc")
    }
}

@Suite struct AuditLogFailureTests {
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    func entry(_ tool: String = "mac_key") -> AuditEntry {
        AuditEntry(client: "t", tool: tool, arguments: [:], outcome: "ok", durationMs: 1)
    }

    @Test func writeFailuresAreReportedFirstThenOncePerMinute() async throws {
        // A file where the log's directory should be: nothing can be created under it.
        let blocker = NSTemporaryDirectory() + "audit-blocker-\(UUID())"
        FileManager.default.createFile(atPath: blocker, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: blocker) }
        let reports = Reports()
        let log = AuditLog(path: blocker + "/audit.jsonl", report: { reports.add($0) })
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        await log.record(entry("mac_key"), now: t0)
        #expect(reports.all.count == 1)
        #expect(reports.all[0].contains("mac_key") && reports.all[0].contains("audit log write failed"))

        await log.record(entry(), now: t0.addingTimeInterval(1))
        await log.record(entry(), now: t0.addingTimeInterval(59))
        #expect(reports.all.count == 1)   // still inside the minute

        await log.record(entry(), now: t0.addingTimeInterval(61))
        #expect(reports.all.count == 2)
        #expect(reports.all[1].contains("2 more"))
    }

    @Test func successfulWritesReportNothingAndKeepTheFileOwnerOnly() async throws {
        let path = NSTemporaryDirectory() + "audit-ok-\(UUID()).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reports = Reports()
        let log = AuditLog(path: path, report: { reports.add($0) })
        await log.record(entry())
        await log.record(AuditEntry(client: "t", tool: "mac_click", arguments: [:], outcome: "refused", durationMs: 2))
        #expect(reports.all.isEmpty)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2 && lines[1].contains("\"outcome\":\"refused\""))
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600)
    }
}
