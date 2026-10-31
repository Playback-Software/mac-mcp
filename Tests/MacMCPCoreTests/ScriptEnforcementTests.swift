import AppKit
import Carbon
import Foundation
import Testing
@testable import MacMCPCore

@Suite struct ScriptEnforcementTests {
    let policy = Policy(script: .init(allowedApps: ["com.apple.TextEdit"], timeoutSeconds: 30))

    @Test func commentsContinuationsAndStringsHaveOneMeaning() {
        for gap in [" ", " ¬\n ", " (* outer (* inner *) *) ", " -- \"fake\"\n ", " # comment\r "] {
            let source = "tell application\(gap)\"Terminal\" to get name"
            #expect(Scripts.targets(of: source, language: .applescript) == ["Terminal"])
            #expect(Scripts.refusal(source: source, language: .applescript, policy: policy)?.contains("deny list") == true)
        }
        let source = "-- application \"Terminal\"\ntell application \"TextEdit\" to get \"application \\\"Terminal\\\"\""
        #expect(Scripts.targets(of: source, language: .applescript) == ["TextEdit"])
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy) == nil)
        #expect(Scripts.targets(of: #"tell application "A\"B" to get name"#, language: .applescript) == ["A\"B"])
    }

    @Test func appFreeScriptsAreRefused() {
        #expect(Scripts.refusal(source: "return 1", language: .applescript, policy: policy)?.contains("name the app") == true)
        #expect(Scripts.refusal(source: "-- application \"TextEdit\"\nreturn 1", language: .applescript, policy: policy) != nil)
    }

    @Test func dynamicTargetsCannotHideBehindCommentsOrPunctuation() {
        for source in ["tell application (* gap *) target to get name", "tell app ¬\n (target) to get name",
                       "tell application id (* gap *) target to get name", "tell application", "tell app {target}",
                       "tell application process target to get name"] {
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript) != nil, "\(source)")
        }
        for source in ["Application /* gap */ (target)", "Application('TextEdit' + suffix)", "Application(`TextEdit`)",
                       "Application('TextEdit', target)"] {
            #expect(Scripts.forbiddenConstruct(in: source, language: .jxa) != nil, "\(source)")
        }
        #expect(Scripts.targets(of: "Application /* gap */ ('TextEdit').name()", language: .jxa) == ["TextEdit"])
        #expect(Scripts.forbiddenConstruct(in: "Application /* gap */ ('TextEdit').name()", language: .jxa) == nil)
    }

    @Test func standardAdditionsAndLibrariesAreRefused() {
        for command in ["open for access", "set eof", "open location", "display dialog", "display alert",
                        "system attribute", "use script", "use library : script", "info for", "list folder", "mount volume"] {
            let source = "tell application \"TextEdit\"\n" + command.replacingOccurrences(of: " ", with: " (* gap *) ¬\n ") + "\nend tell"
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript) != nil, "\(command)")
        }
        #expect(Scripts.forbiddenConstruct(in: "tell application \"TextEdit\" to get \"read write clipboard\"", language: .applescript) == nil)
    }

    @Test func systemEventsRequiresBothOptInsAndChecksProcesses() {
        var p = Policy(script: .init(allowedApps: ["com.apple.systemevents"], timeoutSeconds: 30))
        let source = "tell application (* gap *) \"System Events\" to get name"
        #expect(Scripts.refusal(source: source, language: .applescript, policy: p)?.contains("allow_system_events") == true)
        p.script.allowSystemEvents = true
        #expect(Scripts.refusal(source: source, language: .applescript, policy: p) == nil)
        for form in ["process", "application process"] {
            #expect(Scripts.refusal(source: "tell application \"System Events\" to tell \(form) (* gap *) \"Terminal\" to get name",
                                    language: .applescript, policy: p)?.contains("deny list") == true)
        }
        p.script.allowedApps = ["TextEdit"]
        #expect(Scripts.refusal(source: source, language: .applescript, policy: p) != nil)
    }

    @Test func systemEventsOptInDecodesAndDefaultsOff() throws {
        let decoder = JSONDecoder()
        #expect(!(try decoder.decode(Policy.self, from: Data(#"{"script": {}}"#.utf8))).script.allowSystemEvents)
        let p = try decoder.decode(Policy.self, from: Data(#"{"script": {"allow_system_events": true}}"#.utf8))
        #expect(p.script.allowSystemEvents)
        #expect(try decoder.decode(Policy.self, from: JSONEncoder().encode(p)) == p)
        #expect(throws: (any Error).self) { try decoder.decode(Policy.self, from: Data(#"{"script": {"allow_system_events": "yes"}}"#.utf8)) }
    }

    @Test func clipboardTermsDoNotReadThePasteboardOrRejectAppProperties() {
        var p = policy
        p.clipboardRead = false
        for command in ["get clipboard format", "get the (* gap *) clipboard", "clipboard ¬\n info", "set the clipboard to \"x\""] {
            #expect(Scripts.refusal(source: "tell application \"TextEdit\" to " + command, language: .applescript, policy: p) == nil)
        }
    }

    @Test func doctorWarnsAboutBroadAccessApps() {
        for name in ["Finder", "System Events", "Terminal", "iTerm2", "Script Editor", "Safari", "com.apple.Safari"] {
            #expect(Scripts.broadAccessWarning(for: name)?.contains("any file or app") == true)
        }
        #expect(Scripts.broadAccessWarning(for: "TextEdit") == nil)
    }
}

@Suite struct ScriptEventEnforcementTests {
    typealias P = ScriptEventPolicy
    let policy = Policy(script: .init(allowedApps: ["com.apple.TextEdit"], timeoutSeconds: 30))
    let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")

    func denied(_ decision: P.Decision) -> Bool { if case .refuse = decision { true } else { false } }

    @Test func selfCommandsDefaultDenyExceptVerifiedComputationsAndDelay() {
        for code in P.safeAdditions {
            #expect(P.decide(target: .host, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy) == .allow)
            #expect(P.decide(target: editor, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy) == .allow)
        }
        for code in ["earsffdr", "ascrgdut", "xxxxzzzz"] {
            #expect(denied(P.decide(target: .host, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy)))
        }
        for (code, command) in P.commands {
            let d = P.decide(target: .host, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy)
            #expect(denied(d), "\(command)")
            #expect(denied(P.decide(target: editor, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy)))
        }
    }

    @Test func compilationOnlyAllowsSafeHostComputations() {
        for command in P.safeAdditions {
            let eventClass = code(String(command.prefix(4))), eventID = code(String(command.suffix(4)))
            #expect(ScriptHost.compilationAllows(target: .host, eventClass: eventClass, eventID: eventID))
            #expect(!ScriptHost.compilationAllows(target: editor, eventClass: eventClass, eventID: eventID))
            #expect(!ScriptHost.compilationAllows(target: .unknown, eventClass: eventClass, eventID: eventID))
        }
        for command in ["ascrgdte", "sysoexec", "earsffdr", "xxxxzzzz"] {
            #expect(!ScriptHost.compilationAllows(target: .host, eventClass: code(String(command.prefix(4))), eventID: code(String(command.suffix(4)))))
        }
    }

    @Test func everyActualTargetMustPassBothLists() {
        #expect(P.decide(target: editor, eventClass: "core", eventID: "getd", policy: policy) == .allow)
        for target in [P.Target.unknown, .application(bundleID: "com.apple.Terminal", name: "Terminal"),
                       .application(bundleID: "com.apple.finder", name: "Finder")] {
            #expect(denied(P.decide(target: target, eventClass: "core", eventID: "getd", policy: policy)))
        }
        var p = policy
        p.denyApps.append("TextEdit")
        #expect(denied(P.decide(target: editor, eventClass: "core", eventID: "getd", policy: p)))
        p = policy; p.allowApps = ["Finder"]
        #expect(denied(P.decide(target: editor, eventClass: "core", eventID: "getd", policy: p)))
    }

    @Test func finderIndirectionCannotOpenOrSelectAnyFile() {
        let p = Policy(script: .init(allowedApps: ["Finder"], timeoutSeconds: 30))
        let target = P.Target.application(bundleID: "com.apple.finder", name: "Finder")
        for code in ["aevtodoc", "aevtoapp", "aevtrapp", "ascrnoop", "miscmvis", "miscslct", "corecrel", "fndrovir"] {
            #expect(denied(P.decide(target: target, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: p)))
        }
        #expect(P.decide(target: target, eventClass: "core", eventID: "getd", policy: p) == .allow)
        #expect(denied(P.decide(target: target, eventClass: "core", eventID: "getd", policy: p,
                               processes: [.init(bundleID: "com.apple.Terminal", name: "Terminal")])))
    }

    @Test func systemEventsCannotAddressDeniedOrUnresolvedProcesses() {
        var p = Policy(script: .init(allowedApps: ["System Events"], timeoutSeconds: 30))
        let target = P.Target.application(bundleID: "com.apple.systemevents", name: "System Events")
        #expect(denied(P.decide(target: target, eventClass: "core", eventID: "getd", policy: p)))
        p.script.allowSystemEvents = true
        #expect(P.decide(target: target, eventClass: "core", eventID: "getd", policy: p) == .allow)
        #expect(denied(P.decide(target: target, eventClass: "core", eventID: "getd", policy: p, processes: [.init(name: "Terminal")])))
        #expect(denied(P.decide(target: target, eventClass: "core", eventID: "getd", policy: p, unresolvedProcess: true)))
        #expect(denied(P.decide(target: target, eventClass: "prcs", eventID: "kcod", policy: p)))
        #expect(denied(P.decide(target: target, eventClass: "prcs", eventID: "kprs", policy: p)))
    }

    @Test func clipboardRefusalsNeverEchoPayload() {
        var p = policy
        p.clipboardRead = false
        for event in ["gClp", "pClp", "iClp"] {
            #expect(denied(P.decide(target: .host, eventClass: "Jons", eventID: event, policy: p)))
            #expect(denied(P.decide(target: editor, eventClass: "Jons", eventID: event, policy: policy)))
        }
    }

    @Test func descriptorDecodingFailsClosedAndFindsNestedProcesses() throws {
        #expect(ScriptHost.resolve(NSAppleEventDescriptor(processIdentifier: getpid())) == .host)
        #expect(ScriptHost.resolve(nil) == .unknown)
        #expect(ScriptHost.resolve(NSAppleEventDescriptor(string: "a-secret-target")) == .unknown)
        let spec = NSAppleEventDescriptor.record()
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code("pcap")), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formName)), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(string: "Terminal"), forKeyword: AEKeyword(keyAEKeyData))
        let object = try #require(spec.coerce(toDescriptorType: typeObjectSpecifier))
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
        let record = try #require(event.coerce(toDescriptorType: typeAERecord))
        var processes: [P.ProcessTarget] = [], unresolved = false
        ScriptHost.inspectProcesses(record, processes: &processes, unresolved: &unresolved)
        #expect(processes.map(\.bundleID) == ["com.apple.Terminal"])
        #expect(processes.map(\.name) == ["Terminal"])
        #expect(processes.first?.executablePath?.hasSuffix("/Terminal.app/Contents/MacOS/Terminal") == true)
        #expect(!unresolved)
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        let unknown = try #require(spec.coerce(toDescriptorType: typeObjectSpecifier))
        ScriptHost.inspectProcesses(unknown, processes: &processes, unresolved: &unresolved)
        #expect(unresolved)
    }

    @Test func bundleURLAndSelfSerialNumberAddressesResolveWithoutLaunchingApps() throws {
        let editor = ScriptEventPolicy.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        #expect(ScriptHost.resolve(NSAppleEventDescriptor(bundleIdentifier: "com.apple.TextEdit")) == editor)
        let url = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
        let address = try #require(NSAppleEventDescriptor(descriptorType: typeApplicationURL, data: Data(url.absoluteString.utf8)))
        #expect(ScriptHost.resolve(address) == editor)
        let serial: [UInt32] = [0, 2]
        let data = serial.withUnsafeBytes { Data($0) }
        let host = try #require(NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber, data: data))
        #expect(ScriptHost.resolve(host) == .host)
        #expect(ScriptHost.resolve(NSAppleEventDescriptor(bundleIdentifier: "invalid.macmcp.missing-app")) == .unknown)
    }

    private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// Safe local host checks: no app events, GUI, policy writes or live-agent access.
@Suite(.serialized) struct ScriptHostProcessTests {
    @Test func propertyInitializersCanUseLocalSafeAdditions() async throws {
        let source = "property today : current date\nreturn class of today is date"
        let result = try await Scripts.run(source, language: .applescript, timeout: 30)   // cold hosts start slowly on CI
        #expect(result.status == 0 && result.stdout == "true", "\(result.stderr)")
        #if DEBUG
        // This OS may implement `current date` internally. Exercise a compile-time send explicitly too.
        for command in ["misccurd", "sysoexec"] {
            var request = ScriptHost.Request(source: command, language: "applescript", policy: Policy(), requestConsent: false)
            request.phase = .compileEventProbe
            let probe = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                                 input: JSONEncoder().encode(request), timeout: 5)
            #expect(probe.status == 0 && probe.stdout == "\(command == "misccurd" ? noErr : OSStatus(errAEEventNotPermitted))")
        }
        #endif
    }

    #if DEBUG
    @Test func eventDeliveryUsesAnExistingProcessAndNeverLaunchesAnApp() async throws {
        let gate = try ScriptDocumentGate(check: { _ in .safe })
        defer { gate.stop() }
        for (running, mode) in [(false, kAEWaitReply), (true, kAENoReply), (true, kAEQueueReply), (true, kAEWaitReply)] {
            var request = ScriptHost.Request(source: "coregetd", language: "applescript",
                                             policy: Policy(script: .init(allowedApps: ["TextEdit"], timeoutSeconds: 30)), requestConsent: true)
            request.phase = .documentEventProbe
            request.documentGatePath = gate.path
            request.runningApplicationProbe = running
            request.sendModeProbe = Int32(mode)
            let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                                  input: JSONEncoder().encode(request), timeout: 5)
            if running && mode == kAEWaitReply {
                // The fake sender returns noErr only if the bundle address has been replaced with a PID.
                #expect(result.status == 0 && result.stdout == "0", "\(result.stderr)")
            } else {
                #expect(result.status == ScriptHost.refusalStatus && result.stdout.isEmpty)
                #expect(result.stderr.contains(running ? "asynchronous" : "already be running"))
            }
        }
    }

    @Test func replyIsDiscardedWhenAnEventRevealsAProtectedDocument() async throws {
        final class Documents: @unchecked Sendable {
            let lock = NSLock()
            let after: ScriptDocuments.Check
            var checks = 0
            init(after: ScriptDocuments.Check) { self.after = after }
            func check(_ bundleID: String) -> ScriptDocuments.Check {
                lock.withLock {
                    checks += 1
                    return checks == 1 ? .safe : after
                }
            }
        }
        for after in [ScriptDocuments.Check.protected, .unavailable] {
            let documents = Documents(after: after)
            let gate = try ScriptDocumentGate(check: { documents.check($0) })
            defer { gate.stop() }
            var request = ScriptHost.Request(source: "coregetd", language: "applescript",
                                             policy: Policy(script: .init(allowedApps: ["TextEdit"], timeoutSeconds: 30)), requestConsent: true)
            request.phase = .documentEventProbe
            request.documentGatePath = gate.path
            let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                                  input: JSONEncoder().encode(request), timeout: 5)
            #expect(result.status == ScriptHost.refusalStatus && result.stdout.isEmpty)
            #expect(result.stderr.contains(after == .protected ? "protected document" : "could not be checked"))
            #expect(documents.lock.withLock { documents.checks } == 2)
        }
    }

    @Test func documentReferencesQueryThroughTheGateBeforeDelivery() async throws {
        final class Documents: @unchecked Sendable {
            let lock = NSLock()
            let refuseAt: Int?
            let changeCountAt: Int?
            var checks = 0
            init(refuseAt: Int? = nil, changeCountAt: Int? = nil) { self.refuseAt = refuseAt; self.changeCountAt = changeCountAt }
            func inspect(_ bundleID: String) -> ScriptDocuments.Snapshot {
                lock.withLock {
                    checks += 1
                    if checks == refuseAt { return .init(.protected) }
                    return .init(.safe, inventory: .init(pid: 42, tabsPerWindow: checks == changeCountAt ? [0, 0] : [0]))
                }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for paths in [["/tmp/safe.txt"], [nil], [home + "/.ssh/id_rsa"], [], nil] as [[String?]?] {
            let documents = Documents()
            let gate = try ScriptDocumentGate(inspect: { documents.inspect($0) })
            defer { gate.stop() }
            let result = try await inventoryProbe(gate: gate, paths: paths)
            let allowed = paths == ["/tmp/safe.txt"] || paths == [nil]
            #expect(result.status == (allowed ? 0 : ScriptHost.refusalStatus), "\(result.stderr)")
            #expect(result.stdout == (allowed ? "0" : ""))
            #expect(documents.lock.withLock { documents.checks } == (allowed ? 4 : 3))
            if !allowed { #expect(result.stderr.contains("document or tab reference is not backed by a checked window")) }
            #expect(!result.stdout.contains("protected reply"))
        }
        // The query gets its own before/after AX checks; the user's event keeps its post-reply check too.
        for step in [2, 3, 4] {
            let documents = Documents(refuseAt: step)
            let gate = try ScriptDocumentGate(inspect: { documents.inspect($0) })
            defer { gate.stop() }
            let result = try await inventoryProbe(gate: gate, paths: ["/tmp/safe.txt"])
            #expect(result.status == ScriptHost.refusalStatus && result.stdout.isEmpty)
            #expect(result.stderr.contains("protected document"))
            #expect(documents.lock.withLock { documents.checks } == step)
        }
        for step in [2, 3] {
            let documents = Documents(changeCountAt: step)
            let gate = try ScriptDocumentGate(inspect: { documents.inspect($0) })
            defer { gate.stop() }
            let result = try await inventoryProbe(gate: gate, paths: ["/tmp/safe.txt"])
            #expect(result.status == ScriptHost.refusalStatus && result.stdout.isEmpty)
            #expect(result.stderr.contains("could not be checked"))
        }
    }

    private func inventoryProbe(gate: ScriptDocumentGate, paths: [String?]?) async throws -> Subprocess.Output {
        var request = ScriptHost.Request(source: "coregetd", language: "applescript",
                                         policy: Policy(script: .init(allowedApps: ["TextEdit"], timeoutSeconds: 30)), requestConsent: true)
        request.phase = .documentEventProbe
        request.documentGatePath = gate.path
        request.runningPIDProbe = 42
        request.documentReferenceProbe = true
        request.inventoryPathsProbe = paths
        return try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                        input: JSONEncoder().encode(request), timeout: 5)
    }

    @Test func parentRechecksDocumentsBeforeEveryEventAndFailsClosed() async throws {
        final class Documents: @unchecked Sendable {
            let lock = NSLock()
            var checks = 0
            func check(_ bundleID: String) -> ScriptDocuments.Check {
                lock.withLock {
                    checks += 1
                    return checks == 1 ? .safe : .protected
                }
            }
        }
        let documents = Documents()
        let gate = try ScriptDocumentGate(check: { documents.check($0) })
        defer { gate.stop() }
        #expect(await gate.checkBeforeExecution(bundleID: "com.apple.TextEdit") == .safe)
        for (command, path) in [("coregetd", gate.path), ("coresetd", gate.path), ("coregetd", nil)] as [(String, String?)] {
            var request = ScriptHost.Request(source: command, language: "applescript",
                                             policy: Policy(script: .init(allowedApps: ["TextEdit"], timeoutSeconds: 30)), requestConsent: true)
            request.phase = .documentEventProbe
            request.documentGatePath = path
            let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                                  input: JSONEncoder().encode(request), timeout: 5)
            #expect(result.status == ScriptHost.refusalStatus && result.stdout.isEmpty)
            #expect(result.stderr.contains(path == nil ? "could not be checked" : "protected document"), "\(result.stderr)")
        }
        #expect(documents.lock.withLock { documents.checks } == 3)
        gate.stop()
        #expect(ScriptDocumentGate.query(path: gate.path, bundleID: "com.apple.TextEdit") == .unavailable)
    }

    @Test func compilerTerminologyRequestsReturnAnErrorWithoutAborting() async throws {
        var request = ScriptHost.Request(source: "", language: "applescript", policy: Policy(), requestConsent: false)
        request.phase = .compileEventProbe
        let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                              input: JSONEncoder().encode(request), timeout: 5)
        #expect(result.status == 0 && result.stdout == "\(errAEEventNotPermitted)", "\(result.stderr)")
    }
    #endif

    @Test func runningFinderTerminologyCompilesWithoutSendingAppEvents() async throws {
        #expect(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty)
        let source = "tell application \"Finder\" to get name of every file of desktop"
        var request = ScriptHost.Request(source: source, language: "applescript", policy: Policy(), requestConsent: false)
        request.phase = .compile
        let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                              input: JSONEncoder().encode(request), timeout: 5)
        #expect(result.status == 0, "\(result.stderr)")
        guard result.status == 0 else { return }
        let canonical = try JSONDecoder().decode(ScriptHost.Compilation.self, from: Data(result.stdout.utf8)).source
        #expect(canonical.contains("name of every file of desktop"), "\(canonical)")
        #expect(Scripts.forbiddenConstruct(in: canonical, language: .applescript) == nil)
    }

    @Test func executionHostAlsoCompilesRunningAppTermsWithoutSendingEvents() async throws {
        // Exercise the second compilation directly; the only executable statement is a local return.
        let source = "if false then\ntell application \"Finder\" to get name of every file of desktop\nend if\nreturn true"
        let request = ScriptHost.Request(source: source, language: "applescript", policy: Policy(), requestConsent: false)
        let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                              input: JSONEncoder().encode(request), timeout: 5)
        #expect(result.status == 0 && result.stdout == "true", "\(result.stderr)")
    }

    @Test func installedAppDictionariesResolveInTheCompileSandbox() async throws {
        for (app, command) in [("TextEdit", "get path of every document"), ("Mail", "get read status of every message of inbox"),
                               ("System Events", "get name of every disk item of desktop folder")] {
            var request = ScriptHost.Request(source: "tell application \"\(app)\" to \(command)", language: "applescript",
                                             policy: Policy(), requestConsent: false)
            request.phase = .compile
            let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                                  input: JSONEncoder().encode(request), timeout: 5)
            #expect(result.status == 0, "\(app): \(result.stderr)")
            guard result.status == 0 else { continue }
            let canonical = try JSONDecoder().decode(ScriptHost.Compilation.self, from: Data(result.stdout.utf8)).source
            #expect(canonical.contains(command), "\(app): \(canonical)")
            #expect(Scripts.forbiddenConstruct(in: canonical, language: .applescript) == nil)
        }
    }

    @Test func implicitNativeMethodAliasesAreRefused() async throws {
        for expression in ["my NSHomeDirectory()", "NSHomeDirectory() of me", "NSHomeDirectory()"] {
            let result = try await Scripts.run("return \(expression)", language: .applescript, timeout: 5)
            #expect(result.status != 0 && result.stdout.isEmpty, "\(expression): \(result.stdout)")
        }
    }

    @Test func pureAdditionsSupportCalendarAndRemindersDates() async throws {
        for (app, body) in [
            ("Calendar", "make new event at end of events of calendar \"Home\" with properties {summary:\"Review\", start date:today, end date:tomorrow}"),
            ("Reminders", "make new reminder at end of reminders of list \"Reminders\" with properties {name:\"Review\", due date:tomorrow}"),
        ] {
            // Compile realistic app terms but keep every app event unreachable: these tests never launch an app.
            let source = """
                set today to current date
                set tomorrow to today + days
                if false then
                    tell application "\(app)"
                        \(body)
                    end tell
                end if
                return (tomorrow - today) is days
                """
            let request = ScriptHost.Request(source: source, language: "applescript", policy: Policy(), requestConsent: false)
            let result = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                                  input: JSONEncoder().encode(request), timeout: 5)
            #expect(result.status == 0 && result.stdout == "true", "\(app): \(result.stderr)")
        }
        for (source, expected) in [("offset of \"b\" in \"abc\"", "2"), ("round 1.6", "2"),
                                   ("random number from 7 to 7", "7"), ("ASCII character 65", "A"),
                                   ("ASCII number \"A\"", "65"), ("class of (time to GMT) is integer", "true")] {
            let result = try await Scripts.run(source, language: .applescript, timeout: 5)
            #expect(result.status == 0 && result.stdout == expected, "\(source): \(result.stderr)")
        }
    }

    @Test func nativePropertyInitializerCannotCreateAFile() async throws {
        let root = URL(fileURLWithPath: "/tmp/macmcp-compile-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("compile-effect").path
        let source = """
            use framework "Foundation"
            property probe : ((current application's NSFileManager's defaultManager())'s createFileAtPath:"\(path)" |contents|:(missing value) attributes:(missing value))
            return 1
            """
        let result = try await Scripts.run(source, language: .applescript, timeout: 5)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(result.status == ScriptHost.refusalStatus && result.stderr.contains("use framework"))
        #if DEBUG
        try Data("private compiler fixture".utf8).write(to: URL(fileURLWithPath: path + ".read"))
        var request = ScriptHost.Request(source: path, language: "applescript", policy: Policy(), requestConsent: false)
        request.phase = .sandboxProbe
        let probe = try await Subprocess.run(try #require(Scripts.hostExecutable).path, [ScriptHost.argument],
                                             input: JSONEncoder().encode(request), timeout: 5)
        #expect(probe.status == 0 && probe.stdout == "false,false,false", "\(probe.stderr)")
        #expect(!FileManager.default.fileExists(atPath: path))
        #endif
    }

    @Test func hostLatencyMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["MAC_MCP_SCRIPT_BENCHMARK"] == "1" else { return }
        var samples: [Double] = []
        for i in 0..<21 {
            let start = ContinuousClock.now
            let result = try await Scripts.run("return 1", language: .applescript, timeout: 5)
            #expect(result.status == 0 && result.stdout == "1")
            let duration = start.duration(to: .now)
            if i > 0 { samples.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) }
        }
        samples.sort()
        print("Script host latency (20 warm samples): median \(samples[10]) ms, p95 \(samples[18]) ms")
    }

    @Test func standardAdditionsCannotReadTheEnvironment() async throws {
        let result = try await Scripts.run("system attribute \"HOME\"", language: .applescript, timeout: 5)
        #expect(result.status != 0 && result.stdout.isEmpty)
        #expect(result.stderr.contains("Refused:") && result.stderr.contains("system attribute"))
    }

    @Test func unlistedSelfEventsCannotBeCaughtToReturnSecrets() async throws {
        let secret = "DO_NOT_RETURN_SCRIPT_SECRET"
        let source = "try\nset p to path to home folder\non error\nreturn \"\(secret)\"\nend try"
        let result = try await Scripts.run(source, language: .applescript, timeout: 5)
        #expect(result.status != 0 && result.stdout.isEmpty)
        #expect(result.stderr.contains("path to") && !result.stderr.contains(secret))
    }

    @Test func caughtRefusalsAbortBeforeAHandlerCanLoop() async throws {
        let source = "try\nset p to path to home folder\non error\nrepeat\nend repeat\nend try"
        let result = try await Scripts.run(source, language: .applescript, timeout: 3)
        #expect(result.status != 0 && !result.timedOut && result.stdout.isEmpty)
        #expect(result.stderr.contains("path to"))
    }

    @Test func fileReadIsStoppedBeforeAccessAndDoesNotEchoContents() async throws {
        let path = "/tmp/macmcp-script-test-\(UUID()).txt"
        let secret = "FILE_CONTENT_MUST_NOT_ESCAPE"
        try Data(secret.utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await Scripts.run("read POSIX file \"\(path)\"", language: .applescript, timeout: 5)
        #expect(result.status != 0 && result.stdout.isEmpty)
        #expect(result.stderr.contains("read") && !result.stderr.contains(secret) && !result.stderr.contains(path))
    }

    @Test func jxaStandardAdditionsAlsoPassThroughTheSendGate() async throws {
        let source = "var a = Application.currentApplication(); a.includeStandardAdditions = true; a.systemAttribute('HOME')"
        let result = try await Scripts.run(source, language: .jxa, timeout: 5)
        #expect(result.status != 0 && result.stdout.isEmpty)
        #expect(result.stderr == "Refused Apple event: system attribute. Use the GUI tools.")
    }

    @Test func refusalsDiscardAnythingLoggedBeforeTheBlockedEvent() async throws {
        let secret = "EARLIER_SCRIPT_LOG_MUST_NOT_ESCAPE"
        let source = "console.log('\(secret)'); var a=Application.currentApplication(); a.includeStandardAdditions=true; a.systemAttribute('HOME')"
        let result = try await Scripts.run(source, language: .jxa, timeout: 5)
        #expect(result.status != 0 && result.stdout.isEmpty)
        // JXA console logging is itself a host event, so the gate refuses it before it can emit text.
        #expect(result.stderr == "Refused Apple event: script logging. Use the GUI tools.")
        #expect(!result.stderr.contains(secret))
        let message = "Refused Apple event: system attribute. Use the GUI tools."
        let pipes = Subprocess.Output(stdout: secret, stderr: secret + "\n" + ScriptHost.refusalMarker + message,
                                      status: ScriptHost.refusalStatus, timedOut: false)
        let sanitized = Scripts.hostOutput(pipes)
        #expect(sanitized.stdout.isEmpty && sanitized.stderr == message)
        let malformed = Scripts.hostOutput(.init(stdout: secret, stderr: secret, status: ScriptHost.refusalStatus, timedOut: false))
        #expect(malformed.stdout.isEmpty && !malformed.stderr.contains(secret))
    }

    @Test func resultFormattingMatchesTheOldHumanReadableOutput() async throws {
        for (source, expected) in [("return \"hello\"", "hello"), ("return {1, \"two\", true}", "1, two, true")] {
            let result = try await Scripts.run(source, language: .applescript, timeout: 5)
            #expect(result.status == 0 && result.stdout == expected)
        }
    }
}

@Suite struct ScriptReviewRegressionTests {
    @Test func allCurrentApplicationFormsAndProcessCollectionsAreRefusedEarly() {
        for source in ["NSHomeDirectory() of current application", "tell current application to NSHomeDirectory()",
                       "tell (current app) to NSHomeDirectory()", "set host to current application\nreturn host's NSHomeDirectory()",
                       "return NSHomeDirectory() of (current (* gap *) application)",
                       "return current application's NSHomeDirectory()"] {
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript)?.contains("current application") == true)
        }
        for collection in ["every process", "each application process", "application processes", "processes whose visible is true"] {
            let source = "tell application \"System Events\" to get name of \(collection)"
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript)?.contains("name each process literally") == true)
        }
    }

    @Test func promptProcessesAreRefusedIndependentlyOfAppPolicy() {
        var policy = Policy(denyApps: [], script: .init(allowedApps: ["System Events"], timeoutSeconds: 30))
        policy.script.allowSystemEvents = true
        let target = ScriptEventPolicy.Target.application(bundleID: "com.apple.systemevents", name: "System Events")
        for id in WindowServer.systemPromptBundleIDs.union(WindowServer.mixedPromptBundleIDs) {
            let result = ScriptEventPolicy.decide(target: target, eventClass: "actn", eventID: "perf", policy: policy,
                                                  processes: [.init(bundleID: id, name: "unrelated")])
            guard case let .refuse(message) = result else { Issue.record("Allowed prompt \(id)"); continue }
            #expect(message.contains("security or permission prompt"))
        }
        for executable in WindowServer.systemPromptExecutables.union(WindowServer.mixedPromptExecutables) {
            let result = ScriptEventPolicy.decide(target: target, eventClass: "core", eventID: "setd", policy: policy,
                                                  processes: [.init(bundleID: "test", name: "unrelated", executablePath: "/System/Library/\(executable)")])
            guard case let .refuse(message) = result else { Issue.record("Allowed prompt \(executable)"); continue }
            #expect(message.contains("security or permission prompt"))
        }
        for name in ["CoreServicesUIAgent", "UserNotificationCenter", "SecurityAgent", "sharingd", "loginwindow"] {
            #expect(Scripts.refusal(source: "tell application \"System Events\" to tell process \"\(name)\" to perform action \"AXPress\" of button 1 of window 1",
                                    language: .applescript, policy: policy)?.contains("prompt process") == true)
            #expect(Scripts.refusal(source: "tell application \"\(name)\" to get name",
                                    language: .applescript, policy: policy)?.contains("prompt process") == true)
        }
    }

    @Test func parserSensitiveAndLibrarySyntaxIsRefused() {
        for source in ["<<event sysoexec>>", "<<class capp>>", "name of window 1 of «class pcap» \"Terminal\"",
                       "«class prcs»", "«class pcda»", "«class\tpcap»", "tell script \"LibName\" to run",
                       "return current application's NSString"] {
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript) != nil, "\(source)")
        }
    }

    @Test func ordinaryAppTermsAndUseBoilerplateAreAllowed() {
        let scripts = [
            "tell application \"Mail\"\nset m to item 1 of messages of inbox\nset read status of m to true\nend tell",
            "tell application \"TextEdit\"\nget name of every document\nend tell",
            "tell application \"Finder\" to get name of every file of desktop",
            "tell application \"Finder\" to get read write of file 1 of desktop",
            "tell application \"Example\" to get clipboard format",
        ]
        var policy = Policy(script: .init(allowedApps: ["Mail", "TextEdit", "Finder", "Example", "System Events"], timeoutSeconds: 30))
        policy.script.allowSystemEvents = true
        policy.clipboardRead = false
        for script in scripts {
            for prefix in ["", "use AppleScript version \"2.4\"\nuse scripting additions\n"] {
                #expect(Scripts.forbiddenConstruct(in: prefix + script, language: .applescript) == nil, "\(prefix + script)")
                #expect(Scripts.refusal(source: prefix + script, language: .applescript, policy: policy) == nil, "\(prefix + script)")
            }
        }
    }

    @Test func standardAdditionsDefaultDenyForAllowedApps() {
        let policy = Policy(script: .init(allowedApps: ["TextEdit"], timeoutSeconds: 30))
        let target = ScriptEventPolicy.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        // Side-effecting or unverified commands in this macOS Standard Additions dictionary.
        for code in ["sysobeep", "sysoppcb", "sysochcl", "sysostdf", "sysonwfl", "sysostfl", "gtqpchlt", "sysochra",
                     "sysochur", "sysodisA", "sysodlog", "sysonotf", "sysottos", "sysonfo4", "earslvol", "earslfdr",
                     "earsffdr", "sysorpth", "sysolocS", "fbcssumm", "JonspClp",
                     "JonsgClp", "JonsiClp", "rdwropen", "rdwrclos", "rdwrread", "rdwrwrit", "rdwrgeof", "rdwrseof",
                     "sysoload", "sysostor", "sysodsct", "sysocpls", "sysoexec", "sysogtvl",
                     "aevtstvl", "fndrgstl", "sysosigt", "facofopn", "facofclo", "facofsiz",
                     "facofget", "facoflos", "aevtmvol", "GURLGURL", "WWWΩsdoc", "sysdxxxx", "earSxxxx", "sysoxxxx", "rdwrxxxx",
                     "Jonsxxxx", "GURLxxxx", "ascrpsbr"] {
            let decision = ScriptEventPolicy.decide(target: target, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy)
            if case .allow = decision { Issue.record("Allowed \(code)") }
        }
        #expect(ScriptEventPolicy.decide(target: target, eventClass: "syso", eventID: "dela", policy: policy) == .allow)
        #expect(ScriptEventPolicy.decide(target: target, eventClass: "fndr", eventID: "getd", policy: policy) == .allow)
    }

    @Test func systemEventsCannotLaunchCreateOrInjectInput() {
        var policy = Policy(script: .init(allowedApps: ["System Events"], timeoutSeconds: 30))
        policy.script.allowSystemEvents = true
        let target = ScriptEventPolicy.Target.application(bundleID: "com.apple.systemevents", name: "System Events")
        for code in ["aevtodoc", "aevtoapp", "ascrnoop", "corecrel", "prcskeyF", "prcskeyU", "prcsclic", "coremove", "coreclon"] {
            let decision = ScriptEventPolicy.decide(target: target, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy)
            if case .allow = decision { Issue.record("Allowed \(code)") }
        }
    }

    @Test func compiledAppleScriptIsCheckedBeforeExecution() async throws {
        let source = "use framework \"Foundation\"\nreturn (current application's NSString's stringWithString:\"x\") as text"
        let result = try await Scripts.run(source, language: .applescript, timeout: 5)
        #expect(result.stderr.contains("use framework"))
        #expect(result.stdout.isEmpty)
    }

    @Test func scriptErrorsKeepTheirActualNumber() async throws {
        // Starting the compile and execution hosts can take seconds while the rest of the suite runs.
        let result = try await Scripts.run("error \"Test authorization failure\" number -1743", language: .applescript, timeout: 30)
        #expect(result.status != 0)
        #expect(result.stderr.contains("Test authorization failure") && result.stderr.contains("-1743"), "\(result.stderr)")
    }
}

@Suite struct ScriptDescriptorRegressionTests {
    typealias P = ScriptEventPolicy

    @Test func browserPageJavaScriptRequiresTheWebEvalGrant() throws {
        for (command, id, name) in [("sfridojs", "com.apple.Safari", "Safari"), ("CrSuExJa", "com.google.Chrome", "Google Chrome")] {
            let target = P.Target.application(bundleID: id, name: name)
            var policy = Policy(script: .init(allowedApps: [id], timeoutSeconds: 30))
            #expect(P.decide(target: target, eventClass: String(command.prefix(4)), eventID: String(command.suffix(4)), policy: policy) != .allow)
            policy.web.evalAllowed = true
            #expect(P.decide(target: target, eventClass: String(command.prefix(4)), eventID: String(command.suffix(4)), policy: policy) == .allow)
        }
    }

    @Test func browserJavaScriptRefusesFileURLsIncludingCaseVariants() {
        for (command, key) in [("sfridojs", "----"), ("CrSuExJa", "JvSc")] {
            let script = event(command)
            #expect(ScriptHost.fileRefusal(script) != nil)
            for text in ["location.href = 'file:///Users/me/.ssh/id_rsa'", "window.open('FiLe:///tmp/file')"] {
                script.setParam(NSAppleEventDescriptor(string: text), forKeyword: code(key))
                #expect(ScriptHost.fileRefusal(script)?.contains("JavaScript file URL") == true)
            }
            script.setParam(NSAppleEventDescriptor(string: "document.title"), forKeyword: code(key))
            #expect(ScriptHost.fileRefusal(script) == nil)
        }
    }

    @Test func windowCountsCannotAuthorizeUnbackedDocumentOrTabSelectors() throws {
        let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        let dictionary = ScriptHost.Dictionary(documents: [try XMLDocument(xmlString: """
            <dictionary><suite>
              <class name="document" code="docu"/>
              <class name="drawing" code="draw" inherits="document"/>
              <property name="current drawing" code="draw" type="drawing"/>
            </suite></dictionary>
            """)])
        for kind in ["docu", "bTab", "CrTb", "draw"] {
            let read = event("coregetd")
            read.setParam(try property("ctxt", of: object(kind, name: "Background", container: object("cwin", name: "Window"))),
                          forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: dictionary) != nil, "\(kind)")
        }
        for key in ["docu", "ctab", "acTa", "draw"] {
            let read = event("coregetd")
            read.setParam(try property("ctxt", of: property(key, of: object("cwin", name: "Window"))), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: dictionary) != nil, "\(key)")
        }
        let read = event("coregetd")
        read.setParam(try property("pnam", of: object("cwin", name: "Window")), forKeyword: AEKeyword(keyDirectObject))
        #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: dictionary) == nil)
    }

    @Test func documentTextRequiresASafeCompleteAppInventory() throws {
        let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        let dictionary = inventoryDictionary(property: "ppth")
        let read = event("coregetd")
        read.setParam(try property("ctxt", of: indexedObject("docu")), forKeyword: AEKeyword(keyDirectObject))
        let inventory = ScriptDocuments.Inventory(pid: 42, tabsPerWindow: [0, 0])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safe = inventoryReply([NSAppleEventDescriptor(string: "/tmp/one.txt"), NSAppleEventDescriptor(string: "/tmp/two.txt")])
        var queries = 0
        func refusal(_ reply: NSAppleEventDescriptor?) -> String? {
            ScriptHost.documentRefusal(read, target: editor, dictionary: dictionary, inventory: inventory) { plan in
                queries += 1
                #expect(plan == .init(property: "ppth", tabs: false))
                return reply
            }
        }
        #expect(refusal(safe) == nil) // `text of document 1`, even though AX cannot map that selector.
        #expect(queries == 1)
        for bad in [nil, inventoryReply([]), inventoryReply([NSAppleEventDescriptor(string: "/tmp/one.txt")]),
                    inventoryReply([NSAppleEventDescriptor(string: "/tmp/one.txt"), NSAppleEventDescriptor(string: home + "/.ssh/id_rsa")]),
                    inventoryReply([NSAppleEventDescriptor(string: "/tmp/one.txt"), NSAppleEventDescriptor(string: "relative.txt")]),
                    inventoryReply([NSAppleEventDescriptor(string: "/tmp/one.txt"), NSAppleEventDescriptor(int32: 7)])] as [NSAppleEventDescriptor?] {
            #expect(refusal(bad) == "document or tab reference is not backed by a checked window")
        }
        safe.setParam(NSAppleEventDescriptor(int32: -1728), forKeyword: AEKeyword(keyErrorNumber))
        #expect(refusal(safe) != nil) // An unreadable property cannot be mistaken for an untitled document.
        safe.setParam(NSAppleEventDescriptor(string: "unreadable error"), forKeyword: AEKeyword(keyErrorNumber))
        #expect(refusal(safe) != nil)
        #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: inventoryDictionary(property: "name"), inventory: inventory) { _ in
            Issue.record("Queried an app with no readable file property"); return safe
        } != nil)
    }

    @Test func untitledDocumentsAndLocalFileDescriptorsAreAllowed() throws {
        let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        let read = event("coregetd")
        read.setParam(try property("ctxt", of: indexedObject("docu")), forKeyword: AEKeyword(keyDirectObject))
        let inventory = ScriptDocuments.Inventory(pid: 42, tabsPerWindow: [0])
        let file = try #require(NSAppleEventDescriptor(descriptorType: typeFileURL, data: Data("file:///tmp/safe.txt".utf8)))
        for value in [NSAppleEventDescriptor(typeCode: OSType(cMissingValue)), NSAppleEventDescriptor.null(), NSAppleEventDescriptor(string: ""), file] {
            #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: inventoryDictionary(property: "ppth"), inventory: inventory) { _ in
                inventoryReply([value])
            } == nil)
        }
        let protected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_rsa")
        let protectedFile = try #require(NSAppleEventDescriptor(descriptorType: typeFileURL, data: Data(protected.absoluteString.utf8)))
        #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: inventoryDictionary(property: "file"), inventory: inventory) { _ in
            inventoryReply([protectedFile])
        } != nil)
    }

    @Test func safariTabURLsAndCountsMustCoverEveryWindow() throws {
        let safari = P.Target.application(bundleID: "com.apple.Safari", name: "Safari")
        let dictionary = ScriptHost.Dictionary(target: safari)
        #expect(dictionary.documentInventory(target: safari) == .init(property: "pURL", tabs: true))
        let inventory = ScriptDocuments.Inventory(pid: 42, tabsPerWindow: [2, 1])
        let read = event("coregetd")
        read.setParam(try property("pURL", of: indexedObject("bTab", container: indexedObject("cwin"))), forKeyword: AEKeyword(keyDirectObject))
        func refusal(_ windows: [[String?]]) -> String? {
            let reply = inventoryReply(windows.map { paths in
                let list = NSAppleEventDescriptor.list()
                for (index, path) in paths.enumerated() { list.insert(path.map(NSAppleEventDescriptor.init(string:)) ?? NSAppleEventDescriptor(typeCode: OSType(cMissingValue)), at: index + 1) }
                return list
            })
            return ScriptHost.documentRefusal(read, target: safari, dictionary: dictionary, inventory: inventory) { _ in reply }
        }
        #expect(refusal([["https://example.com"], ["https://example.org", "about:blank"]]) == nil)
        #expect(refusal([["https://example.com", "https://example.org"], ["file:///tmp/safe.txt"]]) == nil)
        let protected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_rsa").absoluteString
        for windows in [[["https://example.com", protected], ["https://example.org"]],
                        [["https://example.com", nil], ["https://example.org"]],
                        [["https://example.com", ""], ["https://example.org"]],
                        [["https://example.com", "file://remote/tmp/unknown"], ["https://example.org"]],
                        [["https://example.com", "relative"], ["https://example.org"]],
                        [["https://example.com", "https://example.org", "https://example.net"]],
                        [["https://example.com"], ["https://example.org"]]] as [[[String?]]] {
            #expect(refusal(windows) != nil)
        }
        let close = event("coreclos")
        close.setParam(try indexedObject("bTab", container: indexedObject("cwin")), forKeyword: AEKeyword(keyDirectObject))
        let one = ScriptDocuments.Inventory(pid: 42, tabsPerWindow: [1])
        #expect(ScriptHost.documentRefusal(close, target: safari, dictionary: dictionary, inventory: one) { _ in
            let list = NSAppleEventDescriptor.list(); list.insert(NSAppleEventDescriptor(string: "https://example.com"), at: 1)
            return inventoryReply([list])
        } == nil)
    }

    @Test func inventoryQueriesReadOnlyPathsAndOrdinaryEventsNeedNoQuery() throws {
        for (app, property, tabs) in [("com.apple.TextEdit", "ppth", false), ("com.apple.Preview", "ppth", false), ("com.apple.Safari", "pURL", true)] {
            let target = P.Target.application(bundleID: app, name: app)
            let dictionary = ScriptHost.Dictionary(target: target)
            let plan = try #require(dictionary.documentInventory(target: target))
            #expect(plan == .init(property: property, tabs: tabs))
            let query = try #require(plan.event(address: NSAppleEventDescriptor(processIdentifier: 42)))
            #expect(ScriptHost.four(query.eventClass) + ScriptHost.four(query.eventID) == "coregetd")
            #expect(query.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.descriptorType == typeKernelProcessID)
            let paths = try #require(query.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
            #expect(paths.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == code(property))
            let items = try #require(paths.forKeyword(AEKeyword(keyAEContainer)))
            #expect(items.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == code(tabs ? "bTab" : "docu"))
            #expect(items.forKeyword(AEKeyword(keyAEKeyData))?.enumCodeValue == OSType(kAEAll))
            #expect(ScriptHost.fileRefusal(query, target: target, dictionary: dictionary) == nil)
            let ordinary = event("coregetd")
            ordinary.setParam(try self.property("pnam", of: indexedObject("cwin")), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.documentRefusal(ordinary, target: target, dictionary: dictionary, inventory: .init(pid: 42, tabsPerWindow: [0])) { _ in
                Issue.record("An ordinary window property queried document paths"); return nil
            } == nil)
        }
    }

    @Test func appInventoryCoversCollectionsSubclassesAndCurrentDocumentProperties() throws {
        let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        let dictionary = inventoryDictionary(property: "file")
        let one = ScriptDocuments.Inventory(pid: 42, tabsPerWindow: [2])
        let reply = inventoryReply([NSAppleEventDescriptor(string: "/tmp/one.txt"), NSAppleEventDescriptor(string: "/tmp/two.txt")])
        let all = try #require(ScriptHost.DocumentInventory(property: "file", tabs: false).event(address: NSAppleEventDescriptor(processIdentifier: 42)))
        for reference in [try indexedObject("draw"), try property("curD", of: NSAppleEventDescriptor.null()),
                          try #require(all.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))] {
            let read = event("coregetd")
            read.setParam(try property("ctxt", of: reference), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: dictionary, inventory: one) { _ in reply } == nil)
            #expect(ScriptHost.documentRefusal(read, target: editor, dictionary: dictionary, inventory: one) { _ in nil } != nil)
        }
    }

    private func inventoryDictionary(property: String) -> ScriptHost.Dictionary {
        ScriptHost.Dictionary(documents: [try! XMLDocument(xmlString: """
            <dictionary><suite><class name="document" code="docu"><property name="file" code="\(property)" type="file"/></class>
            <class name="drawing" code="draw" inherits="document"/><property name="current document" code="curD" type="document"/></suite></dictionary>
            """)])
    }

    private func inventoryReply(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let reply = event("aevtansr"), list = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() { list.insert(value, at: index + 1) }
        reply.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        return reply
    }

    private func indexedObject(_ desired: String, container: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(desired)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return try #require(record.coerce(toDescriptorType: typeObjectSpecifier))
    }

    @Test func documentGateRefusesStoppedLaunchingAndAmbiguousProcesses() {
        let running = Scripts.RunningApplication(pid: 42, finishedLaunching: true)
        let launching = Scripts.RunningApplication(pid: 42, finishedLaunching: false)
        for apps in [[], [launching], [running, running]] as [[Scripts.RunningApplication]] {
            #expect(Scripts.runningRefusal(apps) != nil)
            let source = documentSource(apps: apps)
            #expect(ScriptDocuments.check(bundleID: "com.apple.TextEdit", source: source) == .unavailable)
        }
        #expect(Scripts.runningRefusal([running]) == nil)
        #expect(ScriptDocuments.check(bundleID: "com.apple.TextEdit", source: documentSource()) == .safe)
    }

    @Test func documentGateRefusesWindowsMissingFromAXIncludingOtherSpaces() {
        for count in [nil, 0, 2] as [Int?] {
            #expect(ScriptDocuments.check(bundleID: "com.apple.TextEdit", source: documentSource(windowCount: count)) == .unavailable)
        }
        let protected = FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/config"
        let source = documentSource(reads: [1: AXElement.Read(values: [kAXDocumentAttribute: protected])])
        #expect(ScriptDocuments.check(bundleID: "com.apple.TextEdit", source: source) == .protected)
    }

    @Test func documentGateChecksEverySafariAndNativeTab() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for id in ["com.apple.Safari", "com.apple.TextEdit"] {
            var reads = [
                1: AXElement.Read(values: [kAXDocumentAttribute: "https://example.com", kAXChildrenAttribute: [2]]),
                2: AXElement.Read(values: [kAXRoleAttribute: kAXTabGroupRole, kAXTabsAttribute: [3, 4]]),
                3: AXElement.Read(values: [kAXURLAttribute: "https://example.com"]),
                4: AXElement.Read(values: [kAXURLAttribute: URL(fileURLWithPath: home + "/.ssh/id_rsa")]),
            ]
            #expect(ScriptDocuments.check(bundleID: id, source: documentSource(reads: reads)) == .protected)
            reads[4] = AXElement.Read(values: [:])
            #expect(ScriptDocuments.check(bundleID: id, source: documentSource(reads: reads)) == .unavailable)
            reads[4] = AXElement.Read(values: [kAXURLAttribute: "https://example.org"])
            #expect(ScriptDocuments.check(bundleID: id, source: documentSource(reads: reads)) == .safe)
            // The same tab may appear in AXChildren and AXTabs. Count it only once.
            reads[2] = AXElement.Read(values: [kAXRoleAttribute: kAXTabGroupRole, kAXTabsAttribute: [3, 4], kAXChildrenAttribute: [3, 4]])
            let snapshot = ScriptDocuments.snapshot(bundleID: id, source: documentSource(reads: reads))
            #expect(snapshot.inventory == .init(pid: 42, tabsPerWindow: [2]))
            reads[4] = AXElement.Read(values: [:], errors: [kAXURLAttribute: .cannotComplete])
            #expect(ScriptDocuments.check(bundleID: id, source: documentSource(reads: reads)) == .unavailable)
        }
        #expect(ScriptDocuments.check(bundleID: "com.apple.Safari", source: documentSource()) == .unavailable)
    }

    private func documentSource(apps: [Scripts.RunningApplication] = [.init(pid: 42, finishedLaunching: true)],
                                windowCount: Int? = 1, reads: [Int: AXElement.Read] = [1: .init(values: [:])]) -> ScriptDocuments.Source<Int> {
        ScriptDocuments.Source(applications: { _ in apps }, trusted: { true }, windowCount: { _ in windowCount },
                               windows: { _ in [1] }, read: { reads[$0] }, elements: { $0 as? [Int] })
    }

    @Test func finderNavigationChecksProtectedTextWithoutRejectingHome() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let finder = P.Target.application(bundleID: "com.apple.finder", name: "Finder")
        let navigate = event("coresetd")
        navigate.setParam(try property("fvtg", of: object("brow", name: "Window")), forKeyword: AEKeyword(keyDirectObject))
        let hfs = try #require(CFURLCopyFileSystemPath(URL(fileURLWithPath: home + "/.ssh") as CFURL, CFURLPathStyle(rawValue: 1)!)) as String
        for path in [home + "/.ssh", URL(fileURLWithPath: home + "/.ssh").absoluteString, hfs] {
            navigate.setParam(NSAppleEventDescriptor(string: path), forKeyword: AEKeyword(keyAEData))
            #expect(ScriptHost.fileRefusal(navigate, target: finder)?.contains("protected") == true, "\(path)")
        }
        navigate.setParam(NSAppleEventDescriptor(string: home), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(navigate, target: finder) == nil)
    }

    @Test func unknownBodyParametersCheckRelativeAndHFSText() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hfs = try #require(CFURLCopyFileSystemPath(URL(fileURLWithPath: home + "/.ssh/id_rsa") as CFURL, CFURLPathStyle(rawValue: 1)!)) as String
        let relativeHFS = String(hfs[try #require(hfs.firstIndex(of: ":"))...])
        for path in [String((home + "/.ssh/id_rsa").dropFirst()), hfs, relativeHFS] {
            let write = event("testexpr")
            let nested = NSAppleEventDescriptor.list()
            nested.insert(NSAppleEventDescriptor(string: path), at: 1)
            write.setParam(nested, forKeyword: code("body"))
            #expect(ScriptHost.fileRefusal(write)?.contains("protected") == true, "\(path)")
        }
        for text in ["~5 minutes", "Time: 5", "Users/me/ordinary.txt", "/", "~", home] {
            let write = event("testexpr")
            write.setParam(NSAppleEventDescriptor(string: text), forKeyword: code("body"))
            #expect(ScriptHost.fileRefusal(write) == nil, "\(text)")
        }
    }

    @Test func openDocumentPathsProtectReadsAndImplicitAutosaves() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/.aws/credentials", home + "/.zshrc", home + "/Library/Logs/MacMCP/agent.log"] {
            #expect(ScriptDocuments.check(values: [path]) == .protected)
            #expect(ScriptDocuments.check(values: [URL(fileURLWithPath: path).absoluteString]) == .protected)
        }
        #expect(ScriptDocuments.check(values: []) == .safe)
        #expect(ScriptDocuments.check(values: [home, "/tmp/ordinary-document.rtf", "https://example.com/"]) == .safe)
        #expect(ScriptDocuments.check(values: ["file://remote/tmp/document"]) == .unavailable)
        #expect(ScriptDocuments.Check.protected.refusal?.contains("close it") == true)
    }

    @Test func includedStandardSuiteRetainsCloseSavingGuard() throws {
        let document = try XMLDocument(xmlString: """
            <dictionary xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="file://localhost/System/Library/ScriptingDefinitions/CocoaStandard.sdef"/>
              <suite><command name="close" code="coreclos"><direct-parameter type="specifier"/></command></suite>
            </dictionary>
            """)
        let dictionary = ScriptHost.Dictionary(documents: [document])
        #expect(dictionary.includesCocoaStandard && dictionary.closeCanSave)
        let close = event("coreclos")
        close.setParam(try object("cwin", name: "Document window"), forKeyword: AEKeyword(keyDirectObject))
        let target = P.Target.application(bundleID: "com.example.document-app", name: "Document app")
        #expect(ScriptHost.fileRefusal(close, target: target, dictionary: dictionary) != nil)
        close.setParam(NSAppleEventDescriptor(enumCode: OSType(kAENo)), forKeyword: AEKeyword(keyAESaveOptions))
        #expect(ScriptHost.fileRefusal(close, target: target, dictionary: dictionary) == nil)
    }

    @Test func dictionaryFileTypesAndParameterNamesIdentifyDestinations() throws {
        let dictionary = ScriptHost.Dictionary(documents: [try XMLDocument(xmlString: """
            <dictionary><suite>
              <command name="export" code="testexpr">
                <parameter name="to" code="outp"><type type="file"/></parameter>
                <parameter name="output path" code="pth2" type="text"/>
                <parameter name="body" code="body" type="text"/>
              </command>
              <property name="output file" code="outf" type="file"/>
            </suite></dictionary>
            """)])
        for key in ["outp", "pth2"] {
            for path in ["Users/me/.zshrc", "~5 minutes", "file://remote/tmp/output"] {
                let export = event("testexpr")
                export.setParam(NSAppleEventDescriptor(string: path), forKeyword: code(key))
                #expect(ScriptHost.fileRefusal(export, dictionary: dictionary) != nil)
                let body = event("testexpr")
                body.setParam(NSAppleEventDescriptor(string: path), forKeyword: code("body"))
                #expect(ScriptHost.fileRefusal(body, dictionary: dictionary) == nil)
            }
        }
        let write = event("coresetd")
        write.setParam(try property("outf", of: object("docu", name: "Note")), forKeyword: AEKeyword(keyDirectObject))
        write.setParam(NSAppleEventDescriptor(string: "Users/me/.zshrc"), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(write, dictionary: dictionary) != nil)
        write.setParam(try property("pALL", of: object("docu", name: "Note")), forKeyword: AEKeyword(keyDirectObject))
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: "relative.txt"), forKeyword: code("outf"))
        write.setParam(properties, forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(write, dictionary: dictionary) != nil)
    }

    @Test func rawDataLiteralsCannotHideFileDescriptors() {
        for source in ["return «data ut16FEFF002F»", "return «data\talis0000»", "return <<data utf82F>>"] {
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript) != nil)
        }
        #expect(Scripts.forbiddenConstruct(in: "return \"«data ut16FEFF002F»\"", language: .applescript) == nil)
        #expect(Scripts.forbiddenConstruct(in: "-- «data ut16FEFF002F»\nreturn 1", language: .applescript) == nil)
    }

    @Test func encodedTextAndOpaqueFileDescriptorsCannotBypassWrites() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.zshrc"
        let text = NSAppleEventDescriptor(string: path)
        for kind in ["ut16", "utf8", "TEXT", "utxt", "itxt", "STXT", "sutx", "encs", "cstr", "pstr", "tTXT", "intl"] {
            let type = code(kind)
            let value: NSAppleEventDescriptor
            if let coerced = text.coerce(toDescriptorType: type) { value = coerced }
            else { value = try #require(NSAppleEventDescriptor(descriptorType: type, data: Data(path.utf8))) }
            let export = event("testexpr")
            let nested = NSAppleEventDescriptor.list()
            nested.insert(value, at: 1)
            export.setParam(nested, forKeyword: code("dest"))
            #expect(ScriptHost.fileRefusal(export) != nil, "\(kind)")
            if let safe = NSAppleEventDescriptor(string: "/tmp/macmcp-encoded-export.txt").coerce(toDescriptorType: type) {
                export.setParam(safe, forKeyword: code("dest"))
                #expect(ScriptHost.fileRefusal(export) == nil, "\(kind)")
            }
        }
        for kind in ["bmrk", "fss ", "alis", "fsrf"] {
            let export = event("testexpr")
            export.setParam(try #require(NSAppleEventDescriptor(descriptorType: code(kind), data: Data([0, 1]))), forKeyword: code("with"))
            #expect(ScriptHost.fileRefusal(export) != nil, "\(kind)")
        }
    }

    @Test func hfsAndRelativeExportDestinationsAreChecked() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hfs = try #require(CFURLCopyFileSystemPath(URL(fileURLWithPath: home + "/.zshrc") as CFURL, CFURLPathStyle(rawValue: 1)!)) as String
        for path in [hfs, String((home + "/.zshrc").dropFirst()), ":Users:me:.zshrc", "Users/me/.zshrc", "relative:file"] {
            let export = event("testexpr")
            export.setParam(NSAppleEventDescriptor(string: path), forKeyword: code("dest"))
            #expect(ScriptHost.fileRefusal(export) != nil, "\(path)")
        }
        let safe = try #require(CFURLCopyFileSystemPath(URL(fileURLWithPath: "/tmp/macmcp-export.txt") as CFURL, CFURLPathStyle(rawValue: 1)!)) as String
        let export = event("testexpr")
        export.setParam(NSAppleEventDescriptor(string: safe), forKeyword: code("dest"))
        #expect(ScriptHost.fileRefusal(export) == nil)
    }

    @Test func ordinaryBodyTextAndFinderNavigationStayUsable() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/", "~", "~5 minutes", "file:", "file://remote/tmp/x", home, "Users/me/note", "Time: 5"] {
            let write = event("coresetd")
            write.setParam(try property("ctxt", of: object("docu", name: "Note")), forKeyword: AEKeyword(keyDirectObject))
            write.setParam(NSAppleEventDescriptor(string: path), forKeyword: AEKeyword(keyAEData))
            for id in ["com.apple.TextEdit", "com.apple.mail", "com.apple.MobileSMS"] {
                #expect(ScriptHost.fileRefusal(write, target: .application(bundleID: id, name: id)) == nil, "\(path)")
            }
        }
        let navigate = event("coresetd")
        navigate.setParam(try property("fvtg", of: object("brow", name: "Window")), forKeyword: AEKeyword(keyDirectObject))
        navigate.setParam(try object("cfol", name: home), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(navigate, target: .application(bundleID: "com.apple.finder", name: "Finder")) == nil)
        navigate.setParam(try property("cusr", of: NSAppleEventDescriptor.null()), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(navigate, target: .application(bundleID: "com.apple.finder", name: "Finder")) == nil)
    }

    @Test func closingOneDocumentCanSaveToAnExplicitSafeFile() throws {
        let close = event("coreclos")
        let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        close.setParam(try object("docu", name: "Note"), forKeyword: AEKeyword(keyDirectObject))
        close.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEYes)), forKeyword: AEKeyword(keyAESaveOptions))
        close.setParam(NSAppleEventDescriptor(string: "/tmp/macmcp-close.rtf"), forKeyword: code("kfil"))
        #expect(ScriptHost.fileRefusal(close, target: editor) == nil)
        let indexed = try object("docu", name: "Note").coerce(toDescriptorType: typeAERecord)
        let index = try #require(indexed)
        index.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        for key in [NSAppleEventDescriptor(int32: 1), NSAppleEventDescriptor(enumCode: OSType(kAEFirst))] {
            index.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
            close.setParam(try #require(index.coerce(toDescriptorType: typeObjectSpecifier)), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.fileRefusal(close, target: editor) == nil)
        }
        index.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(kAEAll)), forKeyword: AEKeyword(keyAEKeyData))
        close.setParam(try #require(index.coerce(toDescriptorType: typeObjectSpecifier)), forKeyword: AEKeyword(keyDirectObject))
        #expect(ScriptHost.fileRefusal(close, target: editor) != nil)
        let documents = NSAppleEventDescriptor.list()
        documents.insert(try object("docu", name: "Note"), at: 1)
        documents.insert(try object("docu", name: "Other"), at: 2)
        for direct in [documents, try object("cwin", name: "Note"), NSAppleEventDescriptor.null(),
                       try object("docu", name: "Note", container: documents)] {
            close.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.fileRefusal(close, target: editor) != nil)
        }
    }

    @Test func documentPathPropertiesRequireResolvableSafeWritePaths() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for key in ["ppth", "file", "fnam", "posx", "url ", "pURL", "atfn"] {
            let write = event("coresetd")
            write.setParam(try property(key, of: object("docu", name: "Document")), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.fileRefusal(write)?.contains("unresolved") == true, "\(key)")
            write.setParam(NSAppleEventDescriptor(string: home + "/.zshrc"), forKeyword: AEKeyword(keyAEData))
            #expect(ScriptHost.fileRefusal(write)?.contains("protected") == true, "\(key)")
            for value in [NSAppleEventDescriptor(string: "relative.txt"), NSAppleEventDescriptor(int32: 1)] {
                write.setParam(value, forKeyword: AEKeyword(keyAEData))
                #expect(ScriptHost.fileRefusal(write)?.contains("unresolved") == true, "\(key)")
            }
            write.setParam(NSAppleEventDescriptor(string: "/tmp/macmcp-safe-document.txt"), forKeyword: AEKeyword(keyAEData))
            #expect(ScriptHost.fileRefusal(write) == nil, "\(key)")
        }
        let write = event("coresetd")
        write.setParam(try property("pALL", of: object("docu", name: "Document")), forKeyword: AEKeyword(keyDirectObject))
        let values = NSAppleEventDescriptor.record()
        values.setDescriptor(NSAppleEventDescriptor(string: "relative.txt"), forKeyword: code("ppth"))
        write.setParam(values, forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(write)?.contains("unresolved") == true)
    }

    @Test func quittingCannotImplicitlySaveDocuments() {
        let quit = event("aevtquit")
        for option in [nil, kAEYes, kAEAsk] as [UInt32?] {
            if let option { quit.setParam(NSAppleEventDescriptor(enumCode: option), forKeyword: AEKeyword(keyAESaveOptions)) }
            #expect(ScriptHost.fileRefusal(quit)?.contains("saving no") == true)
        }
        quit.setParam(NSAppleEventDescriptor(enumCode: OSType(kAENo)), forKeyword: AEKeyword(keyAESaveOptions))
        #expect(ScriptHost.fileRefusal(quit) == nil)
    }

    @Test func appSpecificWritesInspectNestedTextPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/Library/LaunchAgents/x.plist", "~/.zshrc", "file://" + home + "/.zshrc",
                     "FILE://" + home + "/.zshrc", "~other/file", "file://remote/tmp/export.txt", "/tmp/bad\0path"] {
            let export = event("testexpr")
            let record = NSAppleEventDescriptor.record()
            let list = NSAppleEventDescriptor.list()
            list.insert(NSAppleEventDescriptor(string: path), at: 1)
            record.setDescriptor(list, forKeyword: code("dest"))
            export.setParam(record, forKeyword: code("with"))
            #expect(ScriptHost.fileRefusal(export) != nil, "\(path)")
        }
        for path in ["/tmp/macmcp-export.txt", "file:///tmp/macmcp-export.txt", "~/Documents/macmcp-export.txt", "ordinary text"] {
            let export = event("testexpr")
            export.setParam(NSAppleEventDescriptor(string: path), forKeyword: code("dest"))
            #expect(ScriptHost.fileRefusal(export) == nil, "\(path)")
        }
        for command in ["coregetd", "corecnte", "coredoex"] {
            let read = event(command)
            read.setParam(NSAppleEventDescriptor(string: home + "/.zshrc"), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.fileRefusal(read) == nil)
        }
    }

    @Test func closingTabsAndFinderWindowsDoesNotRequireSavingNo() throws {
        let finder = P.Target.application(bundleID: "com.apple.finder", name: "Finder")
        let safari = P.Target.application(bundleID: "com.apple.Safari", name: "Safari")
        for (target, kind) in [(finder, "cwin"), (finder, "brow"), (safari, "bTab")] {
            let close = event("coreclos")
            close.setParam(try object(kind, name: "Window or tab"), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.fileRefusal(close, target: target) == nil, "\(kind)")
        }
        let editor = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        for kind in ["docu", "cwin"] {
            let close = event("coreclos")
            close.setParam(try object(kind, name: "Document"), forKeyword: AEKeyword(keyDirectObject))
            #expect(ScriptHost.fileRefusal(close, target: editor) != nil)
            close.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEYes)), forKeyword: AEKeyword(keyAESaveOptions))
            close.setParam(NSAppleEventDescriptor(string: FileManager.default.homeDirectoryForCurrentUser.path + "/.zshrc"), forKeyword: code("kfil"))
            #expect(ScriptHost.fileRefusal(close, target: editor)?.contains("protected") == true)
        }
    }

    @Test func documentAppsCannotOpenPrintSaveOrMoveProtectedFiles() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let policy = Policy(script: .init(allowedApps: ["TextEdit"], timeoutSeconds: 30))
        let target = P.Target.application(bundleID: "com.apple.TextEdit", name: "TextEdit")
        for path in [home + "/.ssh/id_ed25519", home + "/Library/LaunchAgents/x.plist", home + "/.zshrc",
                     home + "/Library/Keychains/keychain-db", home + "/Library/Logs/MacMCP/audit.jsonl",
                     home + "/.local/bin/mac-mcp", home + "/Applications/MacMCP.app/Contents/Info.plist"] {
            for (code, key) in [("aevtodoc", AEKeyword(keyDirectObject)), ("aevtpdoc", AEKeyword(keyDirectObject)),
                                ("coresave", self.code("kfil")), ("coremove", AEKeyword(keyAEInsertHere)),
                                ("coreclon", AEKeyword(keyAEInsertHere))] {
                let event = event(code)
                let url = URL(fileURLWithPath: path)
                event.setParam(try #require(NSAppleEventDescriptor(descriptorType: typeFileURL, data: Data(url.absoluteString.utf8))), forKeyword: key)
                let refusal = ScriptHost.fileRefusal(event)
                #expect(refusal?.contains("protected") == true, "\(code), \(path)")
                #expect(P.decide(target: target, eventClass: String(code.prefix(4)), eventID: String(code.suffix(4)), policy: policy,
                                 destinationPaths: ScriptHost.destinationPaths(event), fileRefusal: refusal) != .allow)
            }
        }
        for (code, key) in [("aevtodoc", AEKeyword(keyDirectObject)), ("aevtpdoc", AEKeyword(keyDirectObject)),
                            ("coresave", self.code("kfil")), ("coremove", AEKeyword(keyAEInsertHere))] {
            let event = event(code)
            #expect(ScriptHost.fileRefusal(event) != nil)
            event.setParam(NSAppleEventDescriptor(int32: 1), forKeyword: key)
            #expect(ScriptHost.fileRefusal(event) != nil)
            event.setParam(NSAppleEventDescriptor(string: "/tmp/macmcp-invalid\0name"), forKeyword: key)
            #expect(ScriptHost.fileRefusal(event) != nil)
            event.setParam(NSAppleEventDescriptor(string: "/tmp/macmcp-safe-file"), forKeyword: key)
            if code == "coremove" {
                #expect(ScriptHost.fileRefusal(event) != nil)
                event.setParam(NSAppleEventDescriptor(string: "/tmp/macmcp-safe-source"), forKeyword: AEKeyword(keyDirectObject))
            }
            #expect(ScriptHost.fileRefusal(event) == nil)
        }
        let close = event("coreclos")
        #expect(ScriptHost.fileRefusal(close) != nil)
        close.setParam(NSAppleEventDescriptor(enumCode: OSType(kAENo)), forKeyword: AEKeyword(keyAESaveOptions))
        #expect(ScriptHost.fileRefusal(close) == nil)
    }

    @Test func creationPropertiesAndNestedFileObjectsAreChecked() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let create = event("corecrel")
        let properties = NSAppleEventDescriptor.record()
        create.setParam(NSAppleEventDescriptor(typeCode: code("file")), forKeyword: AEKeyword(keyAEObjectClass))
        #expect(ScriptHost.fileRefusal(create) != nil)
        create.setParam(NSAppleEventDescriptor(string: "/tmp/macmcp-safe-folder"), forKeyword: AEKeyword(keyAEInsertHere))
        properties.setDescriptor(NSAppleEventDescriptor(string: home + "/Library/LaunchAgents/x.plist"), forKeyword: code("file"))
        create.setParam(properties, forKeyword: AEKeyword(keyAEPropData))
        #expect(ScriptHost.fileRefusal(create)?.contains("protected") == true)
        properties.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: code("file"))
        create.setParam(properties, forKeyword: AEKeyword(keyAEPropData))
        #expect(ScriptHost.fileRefusal(create)?.contains("unresolved") == true)
        let open = event("aevtodoc")
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(string: "/tmp/macmcp-safe-file"), at: 1)
        files.insert(try object("file", name: home + "/.ssh/id_ed25519"), at: 2)
        open.setParam(files, forKeyword: AEKeyword(keyDirectObject))
        #expect(ScriptHost.fileRefusal(open)?.contains("protected") == true)
        files.insert(NSAppleEventDescriptor(int32: 1), at: 3)
        open.setParam(files, forKeyword: AEKeyword(keyDirectObject))
        #expect(ScriptHost.fileRefusal(open)?.contains("unresolved") == true)
    }

    @Test func fileAndPropertyListWritesCannotMutateProtectedPathsOrRenameIntoThem() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/Library/LaunchAgents/x.plist", home + "/Library", home + "/.config", home + "/.local/bin"] {
            let file = try object("plif", name: path)
            let item = try object("plii", name: "RunAtLoad", container: file)
            let write = event("coresetd")
            write.setParam(try property("valL", of: item), forKeyword: AEKeyword(keyDirectObject))
            write.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(keyAEData))
            #expect(ScriptHost.fileRefusal(write)?.contains("protected") == true)
        }
        for file in [try object("cfol", name: "LaunchAgents"), try object("file", name: "selection")] {
            let write = event("coresetd")
            write.setParam(try property("pnam", of: file), forKeyword: AEKeyword(keyDirectObject))
            write.setParam(NSAppleEventDescriptor(string: "safe"), forKeyword: AEKeyword(keyAEData))
            #expect(ScriptHost.fileRefusal(write)?.contains("unresolved") == true)
        }
        let rename = event("coresetd")
        rename.setParam(try property("pnam", of: object("cfol", name: home + "/Library/OrdinaryFolder")), forKeyword: AEKeyword(keyDirectObject))
        rename.setParam(NSAppleEventDescriptor(string: "LaunchAgents"), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(rename)?.contains("protected file rename") == true)
        rename.setParam(NSAppleEventDescriptor(string: "OtherFolder"), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(rename) == nil)
        let uiWrite = event("coresetd")
        uiWrite.setParam(try property("pnam", of: object("cwin", name: "window")), forKeyword: AEKeyword(keyDirectObject))
        #expect(ScriptHost.fileRefusal(uiWrite) == nil)
        let finder = P.Target.application(bundleID: "com.apple.finder", name: "Finder")
        #expect(ScriptHost.fileRefusal(uiWrite, target: finder) == nil)
        let selected = event("coresetd")
        selected.setParam(try property("pnam", of: property("sele", of: NSAppleEventDescriptor.null())), forKeyword: AEKeyword(keyDirectObject))
        selected.setParam(NSAppleEventDescriptor(string: "LaunchAgents"), forKeyword: AEKeyword(keyAEData))
        #expect(ScriptHost.fileRefusal(selected, target: finder)?.contains("unresolved") == true)
    }

    private func property(_ name: String, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return try #require(record.coerce(toDescriptorType: typeObjectSpecifier))
    }

    @Test func compilerCommentAndEscapedIdentifierRulesAreRespected() {
        let source = "(* \"(*\" *)\ntell application \"Terminal\" to get name"
        #expect(Scripts.targets(of: source, language: .applescript) == ["Terminal"])
        #expect(Scripts.forbiddenConstruct(in: "(* \"(*\" *)\nuse framework \"Foundation\"", language: .applescript) == "use framework")
        #expect(Scripts.forbiddenConstruct(in: "(* \"*) use framework\" *)\nreturn 1", language: .applescript) == nil)
        #expect(Scripts.lex(#"set |a\|b| to 1"#, language: .applescript).tokens == [
            .word("set"), .word("a|b"), .word("to"), .word("1"),
        ])
        for source in ["use framework \"Foundation\"", "use script \"Library\"", "use unknown", "use library : script \"Library\"",
                       "tell script id \"Library\" to run", "tell script (libraryName) to run"] {
            #expect(Scripts.forbiddenConstruct(in: source, language: .applescript) != nil)
        }
    }

    @Test func nestedProcessContainersAreInspectedBeforeDelivery() throws {
        var policy = Policy(script: .init(allowedApps: ["System Events"], timeoutSeconds: 30))
        policy.script.allowSystemEvents = true
        let target = P.Target.application(bundleID: "com.apple.systemevents", name: "System Events")
        for processClass in ["pcap", "prcs", "pcda"] {
            let process = try object(processClass, name: "Terminal")
            let window = try object("cwin", name: "Window", container: process)
            let property = NSAppleEventDescriptor.record()
            property.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
            property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
            property.setDescriptor(NSAppleEventDescriptor(typeCode: code("pnam")), forKeyword: AEKeyword(keyAEKeyData))
            property.setDescriptor(window, forKeyword: AEKeyword(keyAEContainer))
            let nested = try #require(property.coerce(toDescriptorType: typeObjectSpecifier))
            let event = event("coregetd")
            event.setParam(nested, forKeyword: AEKeyword(keyDirectObject))
            var processes: [P.ProcessTarget] = [], unresolved = false
            ScriptHost.inspectProcesses(try #require(event.coerce(toDescriptorType: typeAERecord)), processes: &processes, unresolved: &unresolved)
            #expect(processes.map(\.bundleID) == ["com.apple.Terminal"])
            #expect(processes.map(\.name) == ["Terminal"])
            #expect(processes.first?.executablePath?.hasSuffix("/Terminal.app/Contents/MacOS/Terminal") == true)
            #expect(!unresolved)
            let decision = P.decide(target: target, eventClass: "core", eventID: "getd", policy: policy,
                                    processes: processes, unresolvedProcess: unresolved)
            if case .allow = decision { Issue.record("Nested denied process was allowed") }
        }
    }

    @Test func fileDestinationsMustResolveAndAvoidProtectedLocations() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["Library/LaunchAgents", ".config/mac-mcp", "Library/Application Support/MacMCP", ".ssh",
                         ".zshenv", ".zprofile", ".zshrc", ".zlogin", ".profile", ".bash_profile", ".bashrc", ".config/fish"]
        var policy = Policy(script: .init(allowedApps: ["Finder", "System Events"], timeoutSeconds: 30))
        policy.script.allowSystemEvents = true
        for target in [P.Target.application(bundleID: "com.apple.finder", name: "Finder"),
                       .application(bundleID: "com.apple.systemevents", name: "System Events")] {
            for code in ["coremove", "coreclon", "corecrel"] {
                for path in protected.map({ home + "/" + $0 }) + [home, home + "/Library", home + "/.config", home + "/.SSH/key"] {
                    let event = event(code)
                    event.setParam(NSAppleEventDescriptor(string: path), forKeyword: AEKeyword(keyAEInsertHere))
                    let paths = ScriptHost.destinationPaths(event)
                    #expect(paths == [path])
                    let decision = P.decide(target: target, eventClass: "core", eventID: String(code.suffix(4)), policy: policy, destinationPaths: paths)
                    if case .allow = decision { Issue.record("Protected destination was allowed: \(path)") }
                }
                #expect(P.decide(target: target, eventClass: "core", eventID: String(code.suffix(4)), policy: policy) != .allow)
            }
            for id in ["move", "clon"] {
                #expect(P.decide(target: target, eventClass: "core", eventID: id, policy: policy,
                                 destinationPaths: ["/tmp/macmcp-safe-destination"]) == .allow)
            }
        }
        for destination in [NSAppleEventDescriptor(string: ":Users:unknown:"), NSAppleEventDescriptor(int32: 1),
                            try object("cfol", name: "LaunchAgents"), try object("cwin", name: "/tmp/unknown")] {
            let event = event("coremove")
            event.setParam(destination, forKeyword: AEKeyword(keyAEInsertHere))
            #expect(ScriptHost.destinationPaths(event).isEmpty)
        }
        let parent = try object("cfol", name: home + "/Library")
        let destination = try object("cfol", name: "LaunchAgents", container: parent)
        let nested = event("coreclon")
        nested.setParam(destination, forKeyword: AEKeyword(keyAEInsertHere))
        #expect(ScriptHost.destinationPaths(nested) == [home + "/Library/LaunchAgents"])
        let url = URL(fileURLWithPath: home + "/.ssh")
        let fileURL = try #require(NSAppleEventDescriptor(descriptorType: typeFileURL, data: Data(url.absoluteString.utf8)))
        nested.setParam(fileURL, forKeyword: AEKeyword(keyAEInsertHere))
        #expect(ScriptHost.destinationPaths(nested) == [url.path])
        let mixed = NSAppleEventDescriptor.list()
        mixed.insert(fileURL, at: 1)
        mixed.insert(NSAppleEventDescriptor(int32: 1), at: 2)
        nested.setParam(mixed, forKeyword: AEKeyword(keyAEInsertHere))
        #expect(ScriptHost.destinationPaths(nested).isEmpty)
    }

    @Test func destinationChecksResolveSymlinksAndDotSegments() throws {
        let root = URL(fileURLWithPath: "/tmp/macmcp-destinations-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let link = root.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: home)
        #expect(P.protectedDestination(link.appendingPathComponent(".ssh/key").path))
        let dangling = root.appendingPathComponent("startup-link")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: home + "/.zshenv")
        #expect(P.protectedDestination(dangling.path))
        let documents = root.appendingPathComponent("documents-link")
        try FileManager.default.createSymbolicLink(atPath: documents.path, withDestinationPath: home + "/Documents")
        #expect(P.protectedDestination(documents.path + "/../.ssh/key"))
        let cycle = root.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(atPath: cycle.path, withDestinationPath: cycle.path)
        #expect(P.protectedDestination(cycle.path))
        #expect(P.protectedDestination(home + "/Documents/../.config/mac-mcp/policy.json"))
        #expect(P.protectedDestination("/etc/zshrc"))
        #expect(P.protectedDestination(home + "/.config/zsh/.zshrc"))
        #expect(!P.protectedDestination(root.appendingPathComponent("safe").path))
    }

    @Test func grantedAutomationTargetsAreCheckedOncePerHost() {
        var checks = ScriptHost.AutomationChecks()
        var calls = 0
        for _ in 0..<3 {
            #expect(checks.refusal(bundleID: "com.apple.TextEdit") { calls += 1; return .granted } == nil)
        }
        #expect(calls == 1)
        #expect(checks.refusal(bundleID: "com.apple.finder") { calls += 1; return .denied }?.contains("-1743") == true)
        #expect(calls == 2)
        #expect(checks.refusal(bundleID: "com.apple.finder") { calls += 1; return .notAsked } != nil)
        #expect(calls == 3)
    }

    @Test func developmentFallbackIsDebugOnly() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if DEBUG
        let host = try #require(Scripts.hostExecutable)
        let expected = root.appendingPathComponent(".build/debug/MacMCPAgent")
        #expect(Scripts.developmentHostExecutable() == expected)
        #expect(host.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath())
        let result = try await Scripts.run("return 1", language: .applescript, timeout: 5)
        #expect(result.status == 0 && result.stdout == "1")
        #else
        #expect(Scripts.developmentHostExecutable() == nil)
        #expect(Scripts.hostExecutable == nil)
        #endif
    }

    @Test func canonicalCheckHandlesCommentQuotesAndNativeForms() async throws {
        for source in ["(* \"(*\" *)\nuse framework \"Foundation\"\nreturn 1",
                       "return current application's NSString", "return current application's NSHomeDirectory()"] {
            let result = try await Scripts.run(source, language: .applescript, timeout: 5)
            #expect(result.status == ScriptHost.refusalStatus && result.stdout.isEmpty)
            #expect(result.stderr.contains("not allowed in mac_script"))
        }
        for source in ["set |a\\|b| to 1\nreturn |a\\|b|", "(* \"*) use framework\" *)\nreturn 1",
                       "use AppleScript version \"2.4\"\nuse scripting additions\nreturn 1"] {
            let result = try await Scripts.run(source, language: .applescript, timeout: 5)
            #expect(result.status == 0 && result.stdout == "1")
        }
    }

    private func event(_ text: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code(String(text.prefix(4))), eventID: code(String(text.suffix(4))), targetDescriptor: nil,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private func object(_ desired: String, name: String, container: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(desired)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formName)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return try #require(record.coerce(toDescriptorType: typeObjectSpecifier))
    }

    private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
