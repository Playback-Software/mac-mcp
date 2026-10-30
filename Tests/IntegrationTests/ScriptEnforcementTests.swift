import Foundation
import Testing
@testable import MacMCPCore

extension Integration {
@Suite struct ScriptEnforcementTests {
    let policy = Policy(script: .init(allowedApps: ["com.apple.TextEdit"], timeoutSeconds: 30))

    // The unused target satisfies the source preflight without sending any events to TextEdit. `path to` isn't
    // text-blocked, but the actual Standard Additions event must be refused by the host's default-deny rule.
    // Keep this fixture independent of TextEdit's terminology. Compiler-time terminology requests (ascr/gdte)
    // now receive an error locally, letting AppleScript fall back to the bundle without an Automation grant.
    var targetDeclaration: String { "if false then\nget application \"TextEdit\"\nend if\n" }

    /// Exercise the disposable host's event gate directly. Parent document preflight would otherwise refuse an
    /// absent or unreadable TextEdit before these deliberately forbidden events reach the gate under test. With no
    /// document-gate socket, an accidentally allowed app event still fails closed before delivery.
    private func runEventHost(_ source: String, language: Scripts.Language, policy: Policy) async throws -> Scripts.Output {
        let request = ScriptHost.Request(source: source, language: language.rawValue, policy: policy, requestConsent: false)
        let output = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                              input: JSONEncoder().encode(request), timeout: 5)
        return Scripts.hostOutput(output)
    }

    @Test func sourcePassingTheFilterStillCannotRunUnapprovedSelfEvents() async throws {
        let source = targetDeclaration + "return path to home folder"
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy) == nil)
        let result = try await runEventHost(source, language: .applescript, policy: policy)
        #expect(result.status != 0 && result.stderr.contains("Refused Apple event"))
        #expect(result.stderr.contains("path to"))
        #expect(result.stdout.isEmpty)
    }

    @Test func catchingAnEventRefusalCannotReturnAResultOrEchoSecrets() async throws {
        let secret = "SCRIPT_RESULT_MUST_NOT_ESCAPE"
        let source = targetDeclaration + "try\nset x to path to home folder\non error\nreturn \"\(secret)\"\nend try"
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy) == nil)
        let result = try await runEventHost(source, language: .applescript, policy: policy)
        #expect(result.status != 0 && result.stderr.contains("Refused Apple event"))
        #expect(result.stdout.isEmpty && !result.stderr.contains(secret))
    }

    @Test func jxaComputedAppFactoryStillCannotReachADeniedTarget() async throws {
        var p = policy
        p.script.jxa = true
        // `.name()` of an application is answered locally without an event; counting windows sends one to Terminal.
        let source = "if (false) Application('TextEdit'); var factory = this['Appli' + 'cation']; factory('Terminal').windows.length"
        #expect(Scripts.refusal(source: source, language: .jxa, policy: p) == nil)
        let result = try await runEventHost(source, language: .jxa, policy: p)
        #expect(result.status != 0 && result.stderr.contains("Refused Apple event"))
    }

    static let grantedApps = ["Mail", "TextEdit", "Finder"]
    /// Whether macOS has granted MacMCP Automation for every app below, as mac_doctor reports it once they're in
    /// script.allowed_apps. Only a person at the screen can grant it, so without it the test is skipped, not failed.
    static let automationGranted: Bool = {
        guard integrationEnabled else { return false }
        var doctor = ""
        let apps = grantedApps.map { "\"\($0)\"" }.joined(separator: ",")
        try? withPolicy(#"{"script":{"allowed_apps":[\#(apps)]}}"#) { doctor = try agent().call("mac_doctor").text }
        return grantedApps.allSatisfy { doctor.contains("OK  \($0): granted") }
    }()

    /// Runs through the installed agent (mac_script), whose signed executable holds the grants; the test runner's
    /// unsigned build of the host has none. These scripts only read app data.
    @Test(.enabled(if: automationGranted, "needs MacMCP Automation grants for Mail, TextEdit and Finder (approved by a person at the screen)"))
    func ordinaryDocumentAutomationAcceptsUseBoilerplate() throws {
        let scripts = [
            ("Mail", "tell application \"Mail\"\nif (count of messages of inbox) > 0 then\nget read status of message 1 of inbox\nelse\nreturn true\nend if\nend tell"),
            ("TextEdit", "tell application \"TextEdit\" to get name of every document"),
            ("Finder", "tell application \"Finder\" to get name of every file of desktop"),
        ]
        for (app, script) in scripts {
            try withPolicy(#"{"script":{"allowed_apps":["\#(app)"],"timeout_seconds":30}}"#) {
                for prefix in ["", "use AppleScript version \"2.4\"\nuse scripting additions\n"] {
                    let result = try agent().call("mac_script", ["source": prefix + script, "timeout": 10])
                    #expect(!result.isError, "\(app): \(result.text)")
                }
            }
        }
    }

    @Test func additionsAddressedToAnAllowedAppAreStillRefused() async throws {
        for command in ["system info", "path to home folder", "list disks"] {
            // Use a variable to avoid app terminology: the addition is still addressed to TextEdit at runtime.
            let source = "use scripting additions\nset target to application \"TextEdit\"\ntell target to " + command
            #expect(Scripts.refusal(source: source, language: .applescript, policy: policy) == nil)
            let result = try await runEventHost(source, language: .applescript, policy: policy)
            #expect(result.status != 0 && result.stdout.isEmpty)
            #expect(result.stderr.contains("Refused Apple event"), "\(command): \(result.stderr)")
        }
    }

    @Test func systemEventsCannotOpenEvenAnIndirectDiskItem() async throws {
        var p = Policy(script: .init(allowedApps: ["System Events"], timeoutSeconds: 30))
        p.script.allowSystemEvents = true
        let source = "tell application \"System Events\" to open disk item \"/tmp/macmcp-missing-\(UUID()).command\""
        #expect(Scripts.refusal(source: source, language: .applescript, policy: p) == nil)
        let result = try await runEventHost(source, language: .applescript, policy: p)
        #expect(result.status != 0 && result.stdout.isEmpty)
        #expect(result.stderr.contains("Refused Apple event") && result.stderr.contains("open"))
    }
}
}
