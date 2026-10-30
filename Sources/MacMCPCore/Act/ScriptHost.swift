import AppKit
import Carbon
import Foundation
import OSAKit

// sandbox.h has no Swift module. These are the SDK's sandbox.h declarations; flags=0 selects a profile string.
@_silgen_name("sandbox_init")
private func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("sandbox_free_error")
private func sandbox_free_error(_ error: UnsafeMutablePointer<CChar>)

/// Event decisions, separate from descriptor decoding and the OSA callback.
public enum ScriptEventPolicy {
    public enum Target: Equatable, Sendable {
        case host
        case application(bundleID: String, name: String)
        case unknown
    }

    public struct ProcessTarget: Equatable, Sendable {
        public let bundleID: String?
        public let name: String?
        public let executablePath: String?
        public init(bundleID: String? = nil, name: String? = nil, executablePath: String? = nil) {
            self.bundleID = bundleID; self.name = name; self.executablePath = executablePath
        }
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case refuse(String)
    }

    /// Codes verified against `sdef /System/Library/ScriptingAdditions/StandardAdditions.osax`.
    /// Additions can execute in an allowed recipient too. Their dedicated event classes default to denied;
    /// additions in shared app classes are denied by their exact code.
    static let additionsClasses: Set<String> = ["syso", "ears", "earS", "rdwr", "Jons", "GURL", "gurl", "sysd", "gtqp", "fbcs", "faco", "ssrv", "WWWΩ"]
    static let commands = [
        "rdwropen": "open for access", "rdwrread": "read", "rdwrwrit": "write", "rdwrseof": "set eof",
        "rdwrgeof": "get eof", "rdwrclos": "close access", "GURLGURL": "open location",
        "sysodlog": "display dialog", "sysodisA": "display alert", "sysoexec": "do shell script",
        "JonsgClp": "clipboard read", "JonspClp": "clipboard write", "JonsiClp": "clipboard info",
        "fndrgstl": "system attribute", "sysoload": "load script", "sysostor": "store script", "sysodsct": "run script",
        "sysonfo4": "info for", "earslfdr": "list folder", "aevtmvol": "mount volume",
        "earsffdr": "path to", "earslvol": "list disks", "sysorpth": "path to resource", "sysosigt": "system info",
        "sysostdf": "choose file", "gtqpchlt": "choose from list", "sysochur": "choose URL", "sysonotf": "display notification",
        "aevtstvl": "set volume", "ascrpsbr": "native method call",
    ]
    static let safeAdditions: Set<String> = ["sysodela", "misccurd", "sysooffs", "sysorond", "sysorand", "sysontoc", "sysocton", "sysoGMT "]

    public static func decide(target: Target, eventClass: String, eventID: String, policy: Policy,
                              processes: [ProcessTarget] = [], unresolvedProcess: Bool = false,
                              destinationPaths: [String] = [], fileRefusal: String? = nil) -> Decision {
        let code = eventClass + eventID
        func refuse(_ command: String) -> Decision { .refuse("Refused Apple event: \(command). Use the GUI tools.") }
        if let command = commands[code] { return refuse(command) }
        if additionsClasses.contains(eventClass), !safeAdditions.contains(code) { return refuse("Standard Additions \(eventClass)/\(eventID)") }
        if ["aevtrrst", "aevtrsdn", "aevtlogo", "aevtrlgo", "aevtslep", "fndrlogo", "fndrrest", "fndrshut", "fndrslep"].contains(code) {
            return refuse("session control")
        }
        switch target {
        case .unknown: return refuse("unresolved target")
        case .host:
            // Only verified local computations and delay may target the host.
            if safeAdditions.contains(code) { return .allow }
            let command = code == "ascrcmnt" ? "script logging" : "host command \(eventClass)/\(eventID)"
            return refuse(command)
        case let .application(bundleID, name):
            if WindowServer.isPromptProcess(bundleID: bundleID, executablePath: nil, name: name) {
                return refuse("macOS security or permission prompt process")
            }
            if policy.refusal(bundleID: bundleID, name: name) != nil { return refuse("target outside app policy") }
            guard Policy.matches(policy.script.allowedApps, bundleID: bundleID, name: name) else {
                return refuse("target outside script.allowed_apps")
            }
            if pageJavaScriptEvents.contains(code), !policy.web.evalAllowed {
                return refuse("page JavaScript (enable web.eval_allowed)")
            }
            if unresolvedProcess { return refuse("unresolved process target") }
            for process in processes {
                if WindowServer.isPromptProcess(bundleID: process.bundleID, executablePath: process.executablePath, name: process.name) {
                    return refuse("macOS security or permission prompt process")
                }
                guard process.bundleID != nil else { return refuse("unresolved process target") }
                if policy.refusal(bundleID: process.bundleID, name: process.name) != nil {
                    return refuse("process outside app policy")
                }
            }
            let systemEvents = Scripts.isSystemEvents(bundleID: bundleID, name: name)
            let finder = bundleID.lowercased() == "com.apple.finder" || name.lowercased() == "finder"
            if let fileRefusal { return refuse(fileRefusal) }
            if systemEvents {
                guard policy.script.allowSystemEvents else { return refuse("System Events (enable script.allow_system_events)") }
                // Keyboard and mouse input can escape the process named in the event, including hidden key commands.
                if eventClass == "prcs", ["kprs", "kcod", "keyF", "keyU", "clic"].contains(eventID) {
                    return refuse("System Events keyboard or mouse input")
                }
            }
            if finder || systemEvents {
                // Object specifiers, aliases and default handlers cannot be resolved reliably without executing
                // more Finder events. Deny these operations for every file, including indirect references.
                if ["aevtodoc", "aevtoapp", "aevtrapp", "ascrnoop", "miscmvis", "miscslct", "corecrel", "fndrovir"].contains(code) {
                    return refuse("Finder/System Events open, launch, reveal, select or creation")
                }
                if ["coremove", "coreclon"].contains(code) {
                    guard !destinationPaths.isEmpty else { return refuse("unresolved file destination") }
                    if destinationPaths.contains(where: protectedDestination) { return refuse("protected file destination") }
                }
            }
            return .allow
        }
    }

    // Verified against Safari and Google Chrome's installed scripting dictionaries.
    static let pageJavaScriptEvents: Set<String> = ["sfridojs", "CrSuExJa"]

    static func protectedDestination(_ path: String) -> Bool {
        protectedPath(path, mutation: true)
    }

    static func protectedAccess(_ path: String) -> Bool {
        protectedPath(path, mutation: false)
    }

    private static func protectedPath(_ path: String, mutation: Bool) -> Bool {
        guard let destination = canonicalFilePath(path) else { return true }
        if mutation ? ProtectedPaths.isProtectedFromMutation(path) : ProtectedPaths.isProtected(path) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Retain the additional startup locations historically refused by the scripting gate.
        let locations = [".zlogout", ".bash_logout", ".login", ".logout", ".cshrc", ".tcshrc", ".config/fish", ".config/zsh"]
            .map { home + "/" + $0 } + ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin", "/etc/zlogout",
                                       "/etc/profile", "/etc/bashrc", "/etc/csh.cshrc", "/etc/csh.login", "/etc/csh.logout"]
        return locations.contains {
            let protected = canonicalFilePath($0) ?? $0.lowercased()
            // A container may receive a whole folder or a startup file. Without a resolved final filename,
            // its protected descendants must also make it ineligible as a move/duplicate destination.
            return destination == protected || destination.hasPrefix(protected + "/")
                || mutation && protected.hasPrefix(destination == "/" ? "/" : destination + "/")
        }
    }

    private static func canonicalFilePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var pending = path.split(separator: "/").reversed().map(String.init)
        var resolved: [String] = [], links = 0, steps = 0
        while let part = pending.popLast() {
            steps += 1
            guard steps < 4096 else { return nil }
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                links += 1
                guard links < 32 else { return nil }
                if target.hasPrefix("/") { resolved = [] }
                pending.append(contentsOf: target.split(separator: "/").reversed().map(String.init))
            } else { resolved.append(part) }
        }
        // Resolve existing symlink prefixes even when the final file does not exist yet.
        return ("/" + resolved.joined(separator: "/")).lowercased()
    }
}

/// Runs only in a child of the signed MacMCP executable. No agent startup code is entered in this mode.
public enum ScriptHost {
    public static let argument = "--macmcp-script-host"
    static let refusalStatus: Int32 = 77
    static let refusalMarker = "MacMCP-script-refusal: "

    struct Request: Codable {
        enum Phase: String, Codable {
            case compile, execute
            #if DEBUG
            case sandboxProbe, compileEventProbe, documentEventProbe
            #endif
        }
        let source: String
        let language: String
        let policy: Policy
        let requestConsent: Bool
        var phase: Phase = .execute
        var documentGatePath: String?
        #if DEBUG
        var runningApplicationProbe: Bool = true
        var sendModeProbe: Int32 = Int32(kAEWaitReply)
        var runningPIDProbe: pid_t?
        var documentReferenceProbe: Bool = false
        var inventoryPathsProbe: [String?]?
        #endif
    }

    struct Compilation: Codable { let source: String }

    /// This synchronous entry point runs on the helper's main thread, never the agent's cooperative pool.
    public static func main() -> Int32 {
        do {
            let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
            guard let language = Scripts.Language(rawValue: request.language) else { return fail("Unknown script language.") }
            return execute(request, language: language)
        } catch { return fail("Could not read the script host request.") }
    }

    private static func fail(_ message: String) -> Int32 {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        return 1
    }

    private static func refuse(_ message: String) -> Never {
        // Keep a refusal separate from any text the script logged before it. The parent discards that text,
        // including stdout, and accepts only this final marked line with the reserved exit status.
        try? FileHandle.standardError.write(contentsOf: Data(("\n" + refusalMarker + message + "\n").utf8))
        exit(refusalStatus)
    }

    // Compilation can load native frameworks. No writes, child processes, network or app
    // events are permitted, even if the source preflight and Apple's parser disagree. This sandbox is permanent.
    private static func sandboxCompiler(bundles: [String]) -> Bool {
        let paths = ["/System/Library", "/System/Applications", "/System/Cryptexes", "/usr/lib", "/usr/share", "/Library/Apple", "/Library/Frameworks",
                     "/Library/ScriptingAdditions", "/Applications"] + bundles
        let readable = paths.map { path in
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "(subpath \"\(escaped)\")"
        }.joined(separator: " ")
        let profile = """
            (version 1)
            (deny default)
            (allow file-read-metadata)
            (allow file-read-data \(readable) (literal "/dev/null") (literal "/dev/urandom") (literal "/private/etc/localtime"))
            (allow file-map-executable \(readable))
            (allow sysctl-read)
            """
        var error: UnsafeMutablePointer<CChar>?
        let status = sandbox_init(profile, 0, &error)
        if let error { sandbox_free_error(error) }
        return status == 0
    }

    static func sourceRefusal(_ source: String, language: Scripts.Language) -> String? {
        if let bad = Scripts.forbiddenConstruct(in: source, language: language) {
            return "Refused: `\(bad)` is not allowed in mac_script. Use the GUI tools."
        }
        return SessionSafety.refusal(script: source, language: language)
    }

    private static func execute(_ request: Request, language: Scripts.Language) -> Int32 {
        if request.phase == .execute, language == .applescript,
           let message = sourceRefusal(request.source, language: language) { refuse(message) }
        guard let osaLanguage = OSALanguage(forName: language.osaName) else { return fail("Script language is unavailable.") }
        // OSAKit opens and owns the OpenDefaultComponent instance. The legacy Component Manager declarations
        // aren't exposed to Swift on arm64; compilation and execution below use OpenScripting directly.
        let instance = OSALanguageInstance(language: osaLanguage)
        let component = instance.componentInstance
        var sandboxedCompilation = request.phase != .execute
        #if DEBUG
        if request.phase == .documentEventProbe { sandboxedCompilation = false }
        #endif
        if sandboxedCompilation {
            let bundles = Scripts.targets(of: request.source, language: language).compactMap { Apps.bundleURL(for: $0)?.path }
            guard sandboxCompiler(bundles: bundles) else { return fail("Could not sandbox the script compiler.") }
            #if DEBUG
            if request.phase == .sandboxProbe {
                // Exercise native effects at the exact boundary protecting framework loads/initializers. No OSA
                // filter participates, so removing sandbox installation makes the regression test fail.
                let wrote = FileManager.default.createFile(atPath: request.source, contents: Data("probe".utf8))
                let read = (try? Data(contentsOf: URL(fileURLWithPath: request.source + ".read"))) != nil
                let physical = URL(fileURLWithPath: request.source + ".read").resolvingSymlinksInPath().path
                let dataVolumeRead = (try? Data(contentsOf: URL(fileURLWithPath: "/System/Volumes/Data" + physical))) != nil
                try? FileHandle.standardOutput.write(contentsOf: Data("\(wrote),\(read),\(dataVolumeRead)".utf8))
                return 0
            }
            #endif
        }
        let gate = Gate(policy: request.policy, requestConsent: request.requestConsent, documentGatePath: request.documentGatePath)
        guard OSAGetSendProc(component, &gate.originalSend, &gate.originalRef) == noErr,
              OSASetSendProc(component, send, Unmanaged.passUnretained(gate).toOpaque()) == noErr else {
            return fail("Could not install the script event policy.")
        }
        defer { _ = OSASetSendProc(component, gate.originalSend, gate.originalRef) }
        #if DEBUG
        if request.phase == .compileEventProbe || request.phase == .documentEventProbe {
            // Exercise the installed callback without relying on whether this OS asks a running app for terms.
            let documentProbe = request.phase == .documentEventProbe
            let localProbe = request.phase == .compileEventProbe && request.source.utf8.count == 8
            // No app event leaves this runtime probe even if a document guard regresses.
            if documentProbe || localProbe {
                gate.originalSend = { event, reply, _, _, _, _, _, ref in
                    var copy = AEDesc()
                    guard let event, AEDuplicateDesc(event, &copy) == noErr else { return OSErr(errAEEventNotPermitted) }
                    let descriptor = NSAppleEventDescriptor(aeDescNoCopy: &copy)
                    guard let address = descriptor.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)),
                          address.descriptorType == typeKernelProcessID else { return OSErr(errAEEventNotPermitted) }
                    if let reply {
                        let response: NSAppleEventDescriptor
                        if ScriptHost.propertyCode(descriptor.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))) == "ppth", let ref {
                            let gate = Unmanaged<Gate>.fromOpaque(ref).takeUnretainedValue()
                            response = NSAppleEventDescriptor(eventClass: ScriptHost.codeValue("aevt"), eventID: ScriptHost.codeValue("ansr"), targetDescriptor: nil,
                                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                            if let paths = gate.inventoryPathsProbe {
                                let list = NSAppleEventDescriptor.list()
                                for (index, path) in paths.enumerated() {
                                    list.insert(path.map(NSAppleEventDescriptor.init(string:)) ?? NSAppleEventDescriptor(typeCode: OSType(cMissingValue)), at: index + 1)
                                }
                                response.setParam(list, forKeyword: AEKeyword(keyDirectObject))
                            } else { response.setParam(NSAppleEventDescriptor(int32: -1728), forKeyword: AEKeyword(keyErrorNumber)) }
                        } else { response = NSAppleEventDescriptor(string: "protected reply from fake app") }
                        _ = AEDuplicateDesc(response.aeDesc, reply)
                    }
                    return OSErr(noErr)
                }
                gate.applications = { _ in request.runningApplicationProbe ? [Scripts.RunningApplication(pid: request.runningPIDProbe ?? getpid(), finishedLaunching: true)] : [] }
                gate.originalRef = Unmanaged.passUnretained(gate).toOpaque()
                gate.inventoryPathsProbe = request.inventoryPathsProbe
            }
            gate.compiling = !documentProbe
            let command = localProbe || documentProbe && request.source.utf8.count == 8
                ? request.source : documentProbe ? "coregetd" : "ascrgdte"
            let address = localProbe ? NSAppleEventDescriptor(processIdentifier: getpid())
                : NSAppleEventDescriptor(bundleIdentifier: documentProbe ? "com.apple.TextEdit" : "com.apple.finder")
            let event = NSAppleEventDescriptor(eventClass: codeValue(String(command.prefix(4))), eventID: codeValue(String(command.suffix(4))),
                                               targetDescriptor: address,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            if documentProbe, request.documentReferenceProbe,
               let read = DocumentInventory(property: "ctxt", tabs: false).event(address: address),
               let direct = read.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) {
                event.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
            }
            var reply = AEDesc()
            let status = send(event.aeDesc, &reply, documentProbe ? AESendMode(request.sendModeProbe) : AESendMode(kAEWaitReply), AESendPriority(kAENormalPriority),
                              Int32(kAEDefaultTimeout), nil, nil, Unmanaged.passUnretained(gate).toOpaque())
            AEDisposeDesc(&reply)
            try? FileHandle.standardOutput.write(contentsOf: Data("\(status)".utf8))
            return 0
        }
        #endif
        var script: OSAID = 0, result: OSAID = 0
        defer {
            if result != 0 { OSADispose(component, result) }
            if script != 0 { OSADispose(component, script) }
            withExtendedLifetime(instance) {}
        }
        let source = NSAppleEventDescriptor(string: request.source)
        var status = OSACompile(component, source.aeDesc!, 0, &script)
        if status == noErr, language == .applescript {
            var source = AEDesc()
            guard OSAGetSource(component, script, typeUnicodeText, &source) == noErr else {
                refuse("Refused: could not check compiled AppleScript. Use the GUI tools.")
            }
            guard let canonical = NSAppleEventDescriptor(aeDescNoCopy: &source).stringValue else {
                refuse("Refused: could not read compiled AppleScript. Use the GUI tools.")
            }
            if request.phase == .compile {
                // Transfer only source, never native objects or bytecode from the untrusted compiler process.
                // The parent checks it, and the second host compiles only that checked, normalized text.
                guard let data = try? JSONEncoder().encode(Compilation(source: canonical)) else {
                    return fail("Could not encode compiled AppleScript source.")
                }
                try? FileHandle.standardOutput.write(contentsOf: data)
                return 0
            }
            if let message = sourceRefusal(canonical, language: language) { refuse(message) }
        }
        gate.compiling = false
        if status == noErr { status = OSAExecute(component, script, 0, 0, &result) }
        guard status == noErr else {
            var number = AEDesc()
            let errorNumber: Int32
            if OSAScriptError(component, OSType(kOSAErrorNumber), typeSInt32, &number) == noErr {
                errorNumber = NSAppleEventDescriptor(aeDescNoCopy: &number).int32Value
            } else { errorNumber = status }
            var error = AEDesc()
            if OSAScriptError(component, OSType(kOSAErrorMessage), typeUnicodeText, &error) == noErr {
                let message = NSAppleEventDescriptor(aeDescNoCopy: &error).stringValue ?? "Script failed."
                return fail("\(message) (\(errorNumber))")
            }
            return fail("Script failed (\(errorNumber)).")
        }
        if result != 0 {
            var output = AEDesc()
            let displayed = OSADisplay(component, result, typeUnicodeText, Int32(kOSAModeDisplayForHumans), &output)
            guard displayed == noErr else { return fail("Could not format the script result (\(displayed)).") }
            let text = NSAppleEventDescriptor(aeDescNoCopy: &output).stringValue ?? ""
            try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
        }
        return 0
    }

    private final class Gate {
        let policy: Policy
        let requestConsent: Bool
        let documentGatePath: String?
        var compiling = true
        var originalSend: OSASendUPP?
        var originalRef: UnsafeMutableRawPointer?
        var automation = AutomationChecks()
        var dictionaries: [String: Dictionary] = [:]
        #if DEBUG
        var inventoryPathsProbe: [String?]?
        #endif
        var applications: (String) -> [Scripts.RunningApplication] = { Scripts.runningApplications(bundleID: $0) }
        init(policy: Policy, requestConsent: Bool, documentGatePath: String?) {
            self.policy = policy; self.requestConsent = requestConsent; self.documentGatePath = documentGatePath
        }

        func dictionary(target: ScriptEventPolicy.Target) -> Dictionary {
            guard case let .application(bundleID, _) = target else { return Dictionary(documents: []) }
            if let dictionary = dictionaries[bundleID] { return dictionary }
            let dictionary = Dictionary(target: target)
            dictionaries[bundleID] = dictionary
            return dictionary
        }
    }

    struct AutomationChecks {
        private var granted: Set<String> = []

        mutating func refusal(bundleID: String, check: () -> Scripts.AutomationGrant) -> String? {
            if granted.contains(bundleID) { return nil }
            switch check() {
            case .granted: granted.insert(bundleID)
            case .notAsked, .denied: return "MacMCP is not authorized to control this app (-1743). A person must approve Automation access."
            default: break
            }
            return nil
        }
    }

    private static let send: OSASendUPP = { event, reply, mode, priority, timeout, idle, filter, ref in
        guard let ref else { refuse("Refused Apple event: missing event context. Use the GUI tools.") }
        let gate = Unmanaged<Gate>.fromOpaque(ref).takeUnretainedValue()
        return sendEvent(event, reply: reply, mode: mode, priority: priority, timeout: timeout, idle: idle, filter: filter, gate: gate)
    }

    private static func sendEvent(_ event: UnsafePointer<AppleEvent>?, reply: UnsafeMutablePointer<AppleEvent>?, mode: AESendMode,
                                  priority: AESendPriority, timeout: Int32, idle: AEIdleUPP?, filter: AEFilterUPP?, gate: Gate,
                                  inventoryTarget: ScriptEventPolicy.Target? = nil, expectedInventory: ScriptDocuments.Inventory? = nil) -> OSErr {
        guard let event else { refuse("Refused Apple event: missing event context. Use the GUI tools.") }
        var copy = AEDesc()
        guard AEDuplicateDesc(event, &copy) == noErr else {
            if gate.compiling { return OSErr(errAEEventNotPermitted) }
            refuse("Refused Apple event: unreadable event. Use the GUI tools.")
        }
        let descriptor = NSAppleEventDescriptor(aeDescNoCopy: &copy)
        let target = inventoryTarget ?? resolve(descriptor.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
        // Property initializers can evaluate local additions while compiling. App terminology requests must
        // still fail so AppleScript falls back to the bundle dictionary, without contacting or launching apps.
        if gate.compiling, !compilationAllows(target: target, eventClass: descriptor.eventClass, eventID: descriptor.eventID) {
            return OSErr(errAEEventNotPermitted)
        }
        if gate.compiling {
            guard let original = gate.originalSend else { return OSErr(errAEEventNotPermitted) }
            return original(event, reply, mode, priority, timeout, idle, filter, gate.originalRef)
        }
        var processes: [ScriptEventPolicy.ProcessTarget] = [], unresolved = false
        if let parameters = descriptor.coerce(toDescriptorType: typeAERecord) {
            inspectProcesses(parameters, processes: &processes, unresolved: &unresolved)
        } else if case .application = target {
            unresolved = true
        }
        let dictionary = gate.dictionary(target: target)
        let decision = ScriptEventPolicy.decide(target: target, eventClass: four(descriptor.eventClass),
                                                eventID: four(descriptor.eventID), policy: gate.policy,
                                                processes: processes, unresolvedProcess: unresolved,
                                                destinationPaths: destinationPaths(descriptor), fileRefusal: fileRefusal(descriptor, target: target, dictionary: dictionary))
        // Returning an OSA error lets `try`/`on error` continue execution. End this disposable process instead,
        // so a script cannot suppress a refusal, run more native code or turn it into an unexplained timeout.
        if case let .refuse(message) = decision { refuse(message) }
        var inventory: ScriptDocuments.Inventory?
        var pinnedPID: pid_t?
        if case let .application(bundleID, _) = target {
            let apps = gate.applications(bundleID)
            if let message = Scripts.runningRefusal(apps) { refuse(message) }
            pinnedPID = apps[0].pid
            if let expectedInventory, expectedInventory.pid != apps[0].pid { refuse(ScriptDocuments.Check.unavailableMessage) }
            // Pin delivery to this process. A bundle-ID address could relaunch the app after it quits between
            // the document check and send, restoring documents the parent has never inspected.
            let address = NSAppleEventDescriptor(processIdentifier: apps[0].pid)
            descriptor.setAttribute(address, forKeyword: AEKeyword(keyAddressAttr))
            guard let pinned = descriptor.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)),
                  pinned.descriptorType == address.descriptorType, pinned.data == address.data else {
                refuse("Refused Apple event: could not address the running process. Use the GUI tools.")
            }
            guard mode & AESendMode(kAEWaitReply) == AESendMode(kAEWaitReply) else {
                refuse("Refused Apple event: asynchronous app events cannot be checked after handling. Use the GUI tools.")
            }
            for id in [bundleID] + processes.compactMap(\.bundleID) {
                let snapshot = ScriptDocumentGate.snapshot(path: gate.documentGatePath, bundleID: id)
                if let message = snapshot.check.refusal { refuse(message) }
                if id == bundleID {
                    if let checked = snapshot.inventory, checked.pid != apps[0].pid { refuse(ScriptDocuments.Check.unavailableMessage) }
                    inventory = snapshot.inventory
                    if let expectedInventory, inventory != expectedInventory { refuse(ScriptDocuments.Check.unavailableMessage) }
                }
            }
        }
        if case let .application(bundleID, _) = target, !gate.requestConsent,
           let address = descriptor.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)), let ae = address.aeDesc {
            let message = gate.automation.refusal(bundleID: bundleID) {
                Scripts.AutomationGrant(status: AEDeterminePermissionToAutomateTarget(ae, AEEventClass(typeWildCard), AEEventID(typeWildCard), false))
            }
            if let message { refuse(message) }
        }
        // Only the host-created, path-only query bypasses the document-reference refusal. It still passes
        // policy, PID pinning, Automation and both AX checks through this same send function.
        if inventoryTarget == nil,
           let message = documentRefusal(descriptor, target: target, dictionary: dictionary, inventory: inventory, query: { plan in
               guard let inventory, let query = plan.event(address: NSAppleEventDescriptor(processIdentifier: inventory.pid)) else { return nil }
               var result = AEDesc()
               let status = sendEvent(query.aeDesc, reply: &result, mode: AESendMode(kAEWaitReply), priority: priority,
                                      timeout: timeout, idle: idle, filter: filter, gate: gate, inventoryTarget: target, expectedInventory: inventory)
               let response = NSAppleEventDescriptor(aeDescNoCopy: &result)
               return status == noErr ? response : nil
           }) {
            refuse("Refused Apple event: \(message). Use the GUI tools.")
        }
        guard let original = gate.originalSend else { refuse("Could not send the approved Apple event.") }
        let status = original(descriptor.aeDesc, reply, mode, priority, timeout, idle, filter, gate.originalRef)
        if case let .application(bundleID, _) = target {
            for id in [bundleID] + processes.compactMap(\.bundleID) {
                let snapshot = ScriptDocumentGate.snapshot(path: gate.documentGatePath, bundleID: id)
                if let message = snapshot.check.refusal { refuse(message) }
                if id == bundleID {
                    if let checked = snapshot.inventory, checked.pid != pinnedPID { refuse(ScriptDocuments.Check.unavailableMessage) }
                    if let expectedInventory, snapshot.inventory != expectedInventory { refuse(ScriptDocuments.Check.unavailableMessage) }
                }
            }
        }
        return status
    }

    static func four(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        guard bytes.allSatisfy({ $0 >= 32 }) else { return "unknown" }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "unknown"
    }

    static func compilationAllows(target: ScriptEventPolicy.Target, eventClass: UInt32, eventID: UInt32) -> Bool {
        target == .host && ScriptEventPolicy.safeAdditions.contains(four(eventClass) + four(eventID))
    }

    private static func application(_ url: URL) -> ScriptEventPolicy.Target {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return .unknown }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        return .application(bundleID: id, name: name)
    }

    private static func running(_ pid: pid_t) -> ScriptEventPolicy.Target {
        if pid == getpid() { return .host }
        guard let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return .unknown }
        return application(url)
    }

    static func resolve(_ address: NSAppleEventDescriptor?) -> ScriptEventPolicy.Target {
        guard let address else { return .unknown }
        switch address.descriptorType {
        case typeApplicationBundleID:
            guard let id = address.stringValue ?? String(data: address.data, encoding: .utf8),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return .unknown }
            return application(url)
        case typeKernelProcessID:
            guard address.data.count == MemoryLayout<pid_t>.size else { return .unknown }
            return running(address.data.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) })
        case typeProcessSerialNumber:
            let bytes = address.data
            guard bytes.count == 8 else { return .unknown }
            let high = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let low = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            if high == 0, low == 2 { return .host } // kCurrentProcess
            // PSNs are legacy and their lookup isn't exposed to arm64 Swift. Coercion to a kernel PID resolves
            // concrete app PSNs; if the OS cannot resolve one, fail closed.
            guard let pid = address.coerce(toDescriptorType: typeKernelProcessID) else { return .unknown }
            return resolve(pid)
        case typeApplicationURL:
            guard let string = address.stringValue ?? String(data: address.data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return .unknown }
            return application(url)
        default: return .unknown
        }
    }

    static func destinationPaths(_ event: NSAppleEventDescriptor) -> [String] {
        guard ["coremove", "coreclon", "corecrel"].contains(four(event.eventClass) + four(event.eventID)),
              let destination = event.paramDescriptor(forKeyword: AEKeyword(keyAEInsertHere)) else { return [] }
        return filePaths(destination) ?? []
    }

    static let fileClasses: Set<String> = ["cfol", "cfil", "file", "cdis", "ditm", "alia", "appf", "plif"]
    // TextEdit's writable path is ppth; Finder's read-only URL is pURL (verified with sdef).
    static let fileProperties: Set<String> = ["ppth", "file", "fnam", "posx", "url ", "pURL", "atfn"]

    struct Dictionary {
        let documents: [XMLDocument]

        init(documents: [XMLDocument]) { self.documents = documents }

        init(target: ScriptEventPolicy.Target) {
            guard case let .application(bundleID, _) = target,
                  let url = Apps.bundleURL(for: bundleID), url.isFileURL else {
                documents = []; return
            }
            // The file-URL API reads bundle terminology, including legacy Cocoa script suites, without app events.
            var definition: Unmanaged<CFData>?
            guard OSACopyScriptingDefinitionFromURL(url as CFURL, 0, &definition) == noErr,
                  let data = definition?.takeRetainedValue(),
                  let document = try? XMLDocument(data: data as Data, options: .nodeLoadExternalEntitiesNever) else {
                documents = []; return
            }
            var loaded = [document]
            if Dictionary(documents: loaded).includesCocoaStandard,
               let standard = try? XMLDocument(contentsOf: URL(fileURLWithPath: "/System/Library/ScriptingDefinitions/CocoaStandard.sdef"),
                                               options: .nodeLoadExternalEntitiesNever) { loaded.append(standard) }
            documents = loaded
        }

        // Do not expand arbitrary XML includes or fetch external resources. Cocoa's standard suite is a known
        // local definition; other inherited close definitions retain the conservative save guard.
        var includesCocoaStandard: Bool {
            documents.contains { document in
                ((try? document.nodes(forXPath: "//*[local-name()='include']")) ?? []).contains {
                    guard let element = $0 as? XMLElement,
                          element.uri == "http://www.w3.org/2001/XInclude",
                          let href = element.attribute(forName: "href")?.stringValue else { return false }
                    return href.split(separator: "/").last == "CocoaStandard.sdef"
                }
            }
        }

        var closeCanSave: Bool {
            if includesCocoaStandard { return true }
            let commands = documents.flatMap { (try? $0.nodes(forXPath: "//command[@code='coreclos']")) ?? [] }
            guard !commands.isEmpty else { return true }
            return commands.contains {
                guard let command = $0 as? XMLElement else { return true }
                return command.elements(forName: "parameter").contains { $0.attribute(forName: "code")?.stringValue == "savo" }
            }
        }

        var documentClasses: Set<String> {
            var names: Set<String> = ["document", "tab"]
            let classes = documents.flatMap { (try? $0.nodes(forXPath: "//class")) ?? [] }.compactMap { $0 as? XMLElement }
            for _ in 0..<32 {
                let previous = names
                for element in classes {
                    if let parent = element.attribute(forName: "inherits")?.stringValue, names.contains(parent),
                       let name = element.attribute(forName: "name")?.stringValue { names.insert(name) }
                }
                if names == previous { break }
            }
            return Set(classes.compactMap { element in
                guard let name = element.attribute(forName: "name")?.stringValue, names.contains(name) else { return nil }
                return element.attribute(forName: "code")?.stringValue
            }).union(["docu", "bTab", "CrTb"])
        }

        var documentProperties: Set<String> {
            let classes = documentClasses
            let names = Set(documents.flatMap { (try? $0.nodes(forXPath: "//class")) ?? [] }.compactMap { node -> String? in
                guard let element = node as? XMLElement, let code = element.attribute(forName: "code")?.stringValue,
                      classes.contains(code) else { return nil }
                return element.attribute(forName: "name")?.stringValue
            }).union(["document", "tab"])
            return Set(documents.flatMap { (try? $0.nodes(forXPath: "//property")) ?? [] }.compactMap { node -> String? in
                guard let element = node as? XMLElement else { return nil }
                let types = [element.attribute(forName: "type")?.stringValue ?? ""]
                    + element.elements(forName: "type").compactMap { $0.attribute(forName: "type")?.stringValue }
                guard types.contains(where: names.contains) else { return nil }
                return element.attribute(forName: "code")?.stringValue
            }).union(["docu", "ctab", "acTa"])
        }

        func documentInventory(target: ScriptEventPolicy.Target) -> DocumentInventory? {
            guard case let .application(bundleID, _) = target else { return nil }
            let classes = documents.flatMap { (try? $0.nodes(forXPath: "//class | //class-extension")) ?? [] }.compactMap { $0 as? XMLElement }
            func property(of code: String) -> String? {
                guard let root = classes.first(where: { $0.attribute(forName: "code")?.stringValue == code }),
                      let name = root.attribute(forName: "name")?.stringValue else { return nil }
                var names: Set<String> = [name], properties: [XMLElement] = []
                for _ in 0..<32 {
                    let previous = names
                    for element in classes where names.contains(element.attribute(forName: "name")?.stringValue ?? "")
                        || names.contains(element.attribute(forName: "extends")?.stringValue ?? "") {
                        properties += element.elements(forName: "property")
                        if let parent = element.attribute(forName: "inherits")?.stringValue { names.insert(parent) }
                    }
                    if names == previous { break }
                }
                return ["ppth", "file", "pURL", "URL ", "url "].first { code in
                    properties.contains { $0.attribute(forName: "code")?.stringValue == code && $0.attribute(forName: "access")?.stringValue != "w" }
                }
            }
            if bundleID.lowercased() == "com.apple.safari" {
                guard let key = property(of: "bTab"), ["pURL", "URL ", "url "].contains(key) else { return nil }
                return DocumentInventory(property: key, tabs: true)
            }
            // An unrelated tab class may expose documents outside the app's document collection.
            guard !classes.contains(where: { $0.attribute(forName: "name")?.stringValue == "tab" }),
                  let key = property(of: "docu") else { return nil }
            return DocumentInventory(property: key, tabs: false)
        }

        func fileKeywords(event: String? = nil) -> Set<String> {
            var result: Set<String> = []
            for document in documents {
                var nodes = (try? document.nodes(forXPath: "//property")) ?? []
                if let event {
                    for case let command as XMLElement in (try? document.nodes(forXPath: "//command")) ?? []
                        where command.attribute(forName: "code")?.stringValue == event {
                        nodes += command.elements(forName: "parameter") + command.elements(forName: "direct-parameter")
                    }
                }
                for case let element as XMLElement in nodes {
                    let name = element.attribute(forName: "name")?.stringValue?.lowercased() ?? ""
                    let types = [element.attribute(forName: "type")?.stringValue ?? ""]
                        + element.elements(forName: "type").compactMap { $0.attribute(forName: "type")?.stringValue }
                    let fileType = types.contains { ["file", "alias", "file specification", "file reference"].contains($0.lowercased()) }
                    let fileName = name.split(whereSeparator: { !$0.isLetter }).contains { ["path", "file", "filename", "folder", "directory", "destination", "url"].contains(String($0)) }
                        && !name.contains("format") && !name.contains("type")
                    if fileType || fileName {
                        if element.name == "direct-parameter" { result.insert("----") }
                        else if let key = element.attribute(forName: "code")?.stringValue, key.utf8.count == 4 { result.insert(key) }
                    }
                }
            }
            return result
        }
    }

    struct DocumentInventory: Equatable {
        let property: String
        let tabs: Bool

        func event(address: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            func object(_ desired: String, form: OSType, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
                let record = NSAppleEventDescriptor.record()
                record.setDescriptor(NSAppleEventDescriptor(typeCode: codeValue(desired)), forKeyword: AEKeyword(keyAEDesiredClass))
                record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
                record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
                record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
                return record.coerce(toDescriptorType: typeObjectSpecifier)
            }
            let all = NSAppleEventDescriptor(enumCode: OSType(kAEAll))
            var container = NSAppleEventDescriptor.null()
            if tabs {
                guard let windows = object("cwin", form: OSType(formAbsolutePosition), key: all, container: container) else { return nil }
                container = windows
            }
            guard let items = object(tabs ? "bTab" : "docu", form: OSType(formAbsolutePosition), key: all, container: container),
                  let paths = object("prop", form: OSType(formPropertyID), key: NSAppleEventDescriptor(typeCode: codeValue(property)), container: items) else { return nil }
            let event = NSAppleEventDescriptor(eventClass: codeValue("core"), eventID: codeValue("getd"), targetDescriptor: address,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(paths, forKeyword: AEKeyword(keyDirectObject))
            return event
        }

        func accepts(_ reply: NSAppleEventDescriptor, inventory: ScriptDocuments.Inventory) -> Bool {
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.descriptorType != typeSInt32 || error.int32Value != 0 { return false }
            guard let values = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), values.descriptorType == typeAEList,
                  inventory.tabsPerWindow.count <= 128, inventory.tabsPerWindow.allSatisfy({ (0...512).contains($0) }) else { return false }
            func safe(_ value: NSAppleEventDescriptor) -> Bool {
                // An explicit no-file value is an untitled document, not an unreadable or omitted property.
                if !tabs, value.descriptorType == typeType, value.typeCodeValue == OSType(cMissingValue) { return true }
                if !tabs, value.descriptorType == typeNull { return true }
                if let text = textValue(value) {
                    if text.isEmpty { return !tabs }
                    if let paths = textPaths(text) { return !paths.isEmpty && !paths.contains(where: ScriptEventPolicy.protectedAccess) }
                    guard tabs || ["pURL", "URL ", "url "].contains(property), !text.contains("\0"),
                          let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty,
                          scheme.lowercased() != "file" else { return false }
                    return !["http", "https"].contains(scheme.lowercased()) || url.host?.isEmpty == false
                }
                guard [typeAlias, typeFSRef, typeFileURL].contains(value.descriptorType), let paths = filePaths(value), !paths.isEmpty else { return false }
                return !paths.contains(where: ScriptEventPolicy.protectedAccess)
            }
            if !tabs {
                guard values.numberOfItems == inventory.documentCount else { return false }
                return (0..<values.numberOfItems).allSatisfy { values.atIndex($0 + 1).map(safe) ?? false }
            }
            guard values.numberOfItems == inventory.tabsPerWindow.count else { return false }
            var counts: [Int] = []
            for index in 0..<values.numberOfItems {
                guard let window = values.atIndex(index + 1), window.descriptorType == typeAEList, window.numberOfItems <= 512 else { return false }
                counts.append(window.numberOfItems)
                guard (0..<window.numberOfItems).allSatisfy({ window.atIndex($0 + 1).map(safe) ?? false }) else { return false }
            }
            // AX and scripting need not order windows the same way.
            return counts.sorted() == inventory.tabsPerWindow.sorted()
        }
    }

    /// AX cannot map an arbitrary selector to a window. Check the app's complete path-only inventory before
    /// allowing it to resolve a document, tab, collection, filter or current-document property.
    static func documentRefusal(_ event: NSAppleEventDescriptor, target: ScriptEventPolicy.Target,
                                dictionary: Dictionary? = nil, inventory: ScriptDocuments.Inventory? = nil,
                                query: ((DocumentInventory) -> NSAppleEventDescriptor?)? = nil) -> String? {
        guard case .application = target else { return nil }
        let dictionary = dictionary ?? Dictionary(target: target)
        let classes = dictionary.documentClasses, properties = dictionary.documentProperties
        func inspect(_ desc: NSAppleEventDescriptor, depth: Int = 0) -> Bool {
            guard depth < 64 else { return true }
            if desc.descriptorType == typeObjectSpecifier {
                guard let desired = desc.forKeyword(AEKeyword(keyAEDesiredClass)) else { return true }
                if classes.contains(four(desired.typeCodeValue)) { return true }
                if let property = propertyCode(desc), properties.contains(property) { return true }
            }
            if desc.numberOfItems > 0 {
                for i in 1...desc.numberOfItems {
                    guard let child = desc.atIndex(i), !inspect(child, depth: depth + 1) else { return true }
                }
            }
            return false
        }
        guard let parameters = event.coerce(toDescriptorType: typeAERecord) else { return "unreadable document parameters" }
        guard inspect(parameters) else { return nil }
        if let inventory, let plan = dictionary.documentInventory(target: target), let reply = query?(plan), plan.accepts(reply, inventory: inventory) { return nil }
        return "document or tab reference is not backed by a checked window"
    }

    /// Check file-bearing parameters for every recipient, not just file managers. No Apple events are used to
    /// resolve paths: document IDs, selections and unknown specifiers fail closed when a path is needed.
    static func fileRefusal(_ event: NSAppleEventDescriptor, target: ScriptEventPolicy.Target = .unknown,
                            dictionary: Dictionary? = nil) -> String? {
        let code = four(event.eventClass) + four(event.eventID)
        let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        if ScriptEventPolicy.pageJavaScriptEvents.contains(code) {
            let script = code == "sfridojs" ? direct : event.paramDescriptor(forKeyword: codeValue("JvSc"))
            guard let script, let text = textValue(script) else { return "unreadable page JavaScript" }
            if text.range(of: "file:", options: .caseInsensitive) != nil { return "page JavaScript file URL" }
        }
        let destination = event.paramDescriptor(forKeyword: AEKeyword(keyAEInsertHere))
        let properties = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        let mutating = !["coregetd", "coredoex", "corecnte", "aevtodoc", "aevtpdoc"].contains(code)
        let dictionary = dictionary ?? Dictionary(target: target)
        let pathProperties = fileProperties.union(dictionary.fileKeywords())
        var navigation = false
        if case let .application(bundleID, _) = target, bundleID.lowercased() == "com.apple.finder" {
            navigation = code == "coresetd" && propertyCode(direct) == "fvtg"
        }
        func check(_ descriptor: NSAppleEventDescriptor?, mutation: Bool) -> String? {
            fileParameterRefusal(descriptor, mutation: mutation)
        }
        if ["aevtodoc", "aevtpdoc"].contains(code), let refusal = check(direct, mutation: false) { return refusal }
        if code == "coresave" {
            if let refusal = check(event.paramDescriptor(forKeyword: codeValue("kfil")), mutation: true) { return refusal }
        }
        if ["coremove", "coreclon"].contains(code) {
            if let refusal = check(destination, mutation: true) { return refusal }
            if let refusal = check(direct, mutation: code == "coremove") { return refusal }
        }
        if case let .application(bundleID, name) = target,
           bundleID.lowercased() == "com.apple.finder" || Scripts.isSystemEvents(bundleID: bundleID, name: name) {
            if code == "coredelo", let refusal = check(direct, mutation: true) { return refusal }
            if code == "coresetd", let direct, !containsFileObject(direct), !containsUIObject(direct) {
                return "unresolved Finder/System Events file mutation"
            }
        }
        if code == "coreclos" || code == "aevtquit" {
            if let file = event.paramDescriptor(forKeyword: codeValue("kfil")), let refusal = check(file, mutation: true) { return refusal }
            if event.paramDescriptor(forKeyword: AEKeyword(keyAESaveOptions))?.enumCodeValue != kAENo,
               code == "aevtquit" || !(savesOneDocument(event, direct: direct) || closesWithoutSaving(direct, target: target, dictionary: dictionary)) {
                // Documents, document windows and unresolved objects can save paths known only to the app.
                return "unresolved file save on \(code == "aevtquit" ? "quit" : "close") (use saving no)"
            }
        }
        if code == "corecrel" {
            let desired = event.paramDescriptor(forKeyword: AEKeyword(keyAEObjectClass))?.typeCodeValue
            if let desired, fileClasses.contains(four(desired)), let refusal = check(destination, mutation: true) { return refusal }
            for key in pathProperties.union(["kfil"]) {
                if let value = properties?.forKeyword(codeValue(key)), let refusal = check(value, mutation: true) { return refusal }
            }
            if let value = properties?.forKeyword(codeValue("pnam")), let destination {
                guard let name = value.stringValue, let parents = filePaths(destination), parents.count == 1,
                      validFileName(name) else { return "unresolved file creation name" }
                if ScriptEventPolicy.protectedDestination(URL(fileURLWithPath: parents[0]).appendingPathComponent(name).path) {
                    return "protected file creation name"
                }
            }
        }
        if code == "coresetd", let direct, containsFileProperty(direct, keywords: pathProperties),
           let refusal = check(event.paramDescriptor(forKeyword: AEKeyword(keyAEData)), mutation: true) { return refusal }
        if code == "coresetd", let direct, direct.descriptorType == typeObjectSpecifier,
           let form = direct.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, form == OSType(formPropertyID),
           direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == codeValue("pnam"),
           let container = direct.forKeyword(AEKeyword(keyAEContainer)), containsFileObject(container) {
            guard let paths = filePaths(container),
                  let name = event.paramDescriptor(forKeyword: AEKeyword(keyAEData))?.stringValue,
                  validFileName(name) else { return "unresolved file rename" }
            for path in paths {
                let renamed = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name).path
                if ScriptEventPolicy.protectedDestination(renamed) { return "protected file rename" }
            }
        }
        // Also catch file objects nested in reads, deletes, property-list writes and app-specific commands.
        guard let parameters = event.coerce(toDescriptorType: typeAERecord) else { return "unreadable file parameters" }
        let fileKeywords = pathProperties.union(["kfil", "insh", "dest", "path", "fpth", "furl", "to  "])
            .union(dictionary.fileKeywords(event: code))
        return inspectFiles(parameters, mutation: mutating && !navigation, fileKeywords: fileKeywords, pathProperties: pathProperties,
                            navigation: navigation)
    }

    private static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    private static func codeValue(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func fileParameterRefusal(_ descriptor: NSAppleEventDescriptor?, mutation: Bool) -> String? {
        guard let descriptor, let paths = filePaths(descriptor), !paths.isEmpty else { return "unresolved file parameter" }
        if paths.contains(where: { mutation ? ScriptEventPolicy.protectedDestination($0) : ScriptEventPolicy.protectedAccess($0) }) {
            return mutation ? "protected file mutation" : "protected file access"
        }
        return nil
    }

    private static func containsFileProperty(_ desc: NSAppleEventDescriptor, keywords: Set<String>, depth: Int = 0) -> Bool {
        guard depth < 32 else { return true }
        if desc.descriptorType == typeObjectSpecifier,
           let form = desc.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, form == OSType(formPropertyID),
           let property = desc.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue {
            return keywords.contains(four(property))
        }
        if desc.descriptorType == typeAEList, desc.numberOfItems > 0 {
            return (1...desc.numberOfItems).contains {
                desc.atIndex($0).map { containsFileProperty($0, keywords: keywords, depth: depth + 1) } ?? true
            }
        }
        return false
    }

    private static func propertyCode(_ desc: NSAppleEventDescriptor?) -> String? {
        guard let desc, desc.descriptorType == typeObjectSpecifier,
              desc.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formPropertyID),
              let property = desc.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue else { return nil }
        return four(property)
    }

    private static func savesOneDocument(_ event: NSAppleEventDescriptor, direct: NSAppleEventDescriptor?) -> Bool {
        guard let file = event.paramDescriptor(forKeyword: codeValue("kfil")), filePaths(file)?.count == 1,
              let direct, direct.descriptorType == typeObjectSpecifier,
              direct.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == codeValue("docu"),
              let form = direct.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue,
              let key = direct.forKeyword(AEKeyword(keyAEKeyData)) else { return false }
        if let container = direct.forKeyword(AEKeyword(keyAEContainer)), container.descriptorType != typeNull { return false }
        // Collections, ranges, tests, windows and unresolved objects may save more than the supplied filename.
        return form == OSType(formName) && textValue(key) != nil
            || form == OSType(formUniqueID) && [typeSInt32, typeUnicodeText, typeUTF8Text].contains(key.descriptorType)
            || form == OSType(formAbsolutePosition) && (key.descriptorType == typeSInt32 || [kAEFirst, kAELast, kAEMiddle, kAEAny].map(OSType.init).contains(key.enumCodeValue))
    }

    private static func closesWithoutSaving(_ desc: NSAppleEventDescriptor?, target: ScriptEventPolicy.Target,
                                           dictionary: Dictionary, depth: Int = 0) -> Bool {
        guard depth < 32, let desc else { return false }
        if desc.descriptorType == typeAEList, desc.numberOfItems > 0 {
            return (1...desc.numberOfItems).allSatisfy { closesWithoutSaving(desc.atIndex($0), target: target, dictionary: dictionary, depth: depth + 1) }
        }
        guard case let .application(bundleID, _) = target, desc.descriptorType == typeObjectSpecifier,
              let desired = desc.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue else { return false }
        // Safari tabs aren't documents. Other apps' windows may own documents, so consult their dictionary.
        if bundleID.lowercased() == "com.apple.safari", four(desired) == "bTab" { return true }
        return !dictionary.closeCanSave
    }

    private static func containsFileObject(_ desc: NSAppleEventDescriptor, depth: Int = 0) -> Bool {
        guard depth < 32 else { return true }
        if [typeAlias, typeFSRef, typeFileURL].contains(desc.descriptorType) { return true }
        if desc.descriptorType == typeObjectSpecifier,
           let desired = desc.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue,
           fileClasses.contains(four(desired)) || four(desired) == "plii" { return true }
        if let container = desc.forKeyword(AEKeyword(keyAEContainer)) {
            return containsFileObject(container, depth: depth + 1)
        }
        return false
    }

    private static func containsUIObject(_ desc: NSAppleEventDescriptor, depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        if desc.descriptorType == typeObjectSpecifier,
           let desired = desc.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue,
           ["cwin", "brow", "prcs", "pcap", "pcda"].contains(four(desired)) { return true }
        if let container = desc.forKeyword(AEKeyword(keyAEContainer)) {
            return containsUIObject(container, depth: depth + 1)
        }
        return false
    }

    private static let textTypes: Set<String> = ["utxt", "utf8", "TEXT", "ut16", "itxt", "STXT", "sutx", "encs", "cstr", "pstr", "tTXT", "intl"]
    private static let opaqueFileTypes: Set<String> = ["bmrk", "fss "]

    private static func textValue(_ desc: NSAppleEventDescriptor) -> String? {
        guard textTypes.contains(four(desc.descriptorType)) else { return nil }
        return desc.coerce(toDescriptorType: typeUnicodeText)?.stringValue
    }

    private static func inspectFiles(_ desc: NSAppleEventDescriptor, mutation: Bool, fileKeywords: Set<String>, pathProperties: Set<String>,
                                     navigation: Bool = false, fileContext: Bool = false, depth: Int = 0) -> String? {
        guard depth < 64 else { return "unresolved file parameter nesting" }
        let concrete = [typeAlias, typeFSRef, typeFileURL].contains(desc.descriptorType)
        let fileObject = desc.descriptorType == typeObjectSpecifier
            && desc.forKeyword(AEKeyword(keyAEDesiredClass)).map { fileClasses.contains(four($0.typeCodeValue)) } == true
        if concrete || fileObject {
            return fileParameterRefusal(desc, mutation: mutation)
        }
        if mutation, opaqueFileTypes.contains(four(desc.descriptorType)) { return "unresolved file descriptor" }
        if mutation || navigation, textTypes.contains(four(desc.descriptorType)) {
            guard let text = textValue(desc) else { return fileContext ? "unresolved file text" : "unreadable text parameter" }
            if let paths = textPaths(text) {
                // In body text, a containing directory (or just '/' or '~') is ordinary text. Still reject
                // actual protected paths wherever they occur; only file parameters get mutation/ancestor checks.
                if paths.contains(where: { mutation && fileContext ? ScriptEventPolicy.protectedDestination($0) : ScriptEventPolicy.protectedAccess($0) }) {
                    return mutation ? "protected file mutation" : "protected file access"
                }
            } else if fileContext, text.contains("/") || text.contains(":") || text.hasPrefix("~") || text.contains("\0") {
                return "unresolved file text"
            }
            if !fileContext {
                var relativePaths: [String] = []
                if !text.hasPrefix("/"), text.contains("/"), !text.contains(":"), !text.hasPrefix("~") {
                    relativePaths.append("/" + text)
                }
                if text.hasPrefix(":"), !text.contains("/"), !text.contains("\0"),
                   let url = CFURLCreateWithFileSystemPathRelativeToBase(nil, text as CFString, CFURLPathStyle(rawValue: 1)!,
                                                                       text.hasSuffix(":"), URL(fileURLWithPath: "/", isDirectory: true) as CFURL),
                   let absolute = CFURLCopyAbsoluteURL(url),
                   let path = CFURLCopyFileSystemPath(absolute, .cfurlposixPathStyle) as String? {
                    relativePaths.append(path)
                }
                if relativePaths.contains(where: ScriptEventPolicy.protectedAccess) {
                    return mutation ? "protected file mutation" : "protected file access"
                }
            }
            return nil
        }
        if desc.descriptorType == typeObjectSpecifier,
           desc.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == codeValue("plii") {
            guard let container = desc.forKeyword(AEKeyword(keyAEContainer)), containsFileObject(container) else {
                return "unresolved property list file"
            }
        }
        if desc.numberOfItems > 0 {
            for i in 1...desc.numberOfItems {
                let fileParameter = desc.descriptorType == typeAERecord && fileKeywords.contains(four(desc.keywordForDescriptor(at: i)))
                if mutation, desc.descriptorType == typeAERecord, pathProperties.contains(four(desc.keywordForDescriptor(at: i))),
                   let refusal = fileParameterRefusal(desc.atIndex(i), mutation: true) { return refusal }
                if let child = desc.atIndex(i), let refusal = inspectFiles(child, mutation: mutation, fileKeywords: fileKeywords,
                                                                         pathProperties: pathProperties, navigation: navigation,
                                                                         fileContext: fileContext || fileParameter, depth: depth + 1) { return refusal }
            }
        }
        return nil
    }

    /// Decode only concrete local paths. Never ask Finder or System Events to resolve an object for the gate.
    private static func filePaths(_ desc: NSAppleEventDescriptor, depth: Int = 0) -> [String]? {
        guard depth < 32 else { return nil }
        if desc.descriptorType == typeAEList {
            guard desc.numberOfItems > 0 else { return nil }
            var paths: [String] = []
            for i in 1...desc.numberOfItems {
                guard let child = desc.atIndex(i), let resolved = filePaths(child, depth: depth + 1) else { return nil }
                paths += resolved
            }
            return paths
        }
        if desc.descriptorType == typeAlias || desc.descriptorType == typeFSRef {
            guard let url = desc.coerce(toDescriptorType: typeFileURL) else { return nil }
            return filePaths(url, depth: depth + 1)
        }
        if desc.descriptorType == typeFileURL {
            guard let text = String(data: desc.data, encoding: .utf8), let url = URL(string: text),
                  url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/"), !url.path.contains("\0") else { return nil }
            return [url.path]
        }
        if desc.descriptorType == typeInsertionLoc {
            guard let position = desc.forKeyword(AEKeyword(keyAEPosition))?.enumCodeValue,
                  position == kAEBeginning || position == kAEEnd,
                  let object = desc.forKeyword(AEKeyword(keyAEObject)) else { return nil }
            return filePaths(object, depth: depth + 1)
        }
        if desc.descriptorType == typeObjectSpecifier {
            guard let desired = desc.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue,
                  fileClasses.contains(four(desired)),
                  let form = desc.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, form == formName,
                  let name = desc.forKeyword(AEKeyword(keyAEKeyData))?.stringValue, !name.contains("\0") else { return nil }
            let container = desc.forKeyword(AEKeyword(keyAEContainer))
            if container == nil || container?.descriptorType == typeNull {
                return name.hasPrefix("/") ? [name] : nil
            }
            guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != "..",
                  let container, let parents = filePaths(container, depth: depth + 1), parents.count == 1 else { return nil }
            return [URL(fileURLWithPath: parents[0]).appendingPathComponent(name).path]
        }
        if let text = textValue(desc) { return textPaths(text) }
        return nil
    }

    static func textPaths(_ path: String) -> [String]? {
        guard !path.contains("\0") else { return nil }
        if path.hasPrefix("/") { return [path] }
        if path == "~" || path.hasPrefix("~/") {
            return [FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()]
        }
        if path.lowercased().hasPrefix("file:") {
            guard let url = URL(string: "file:" + path.dropFirst(5)), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.path.hasPrefix("/"), !url.path.contains("\0") else { return nil }
            return [url.path]
        }
        // Leading ':' is relative in HFS syntax. CFURL resolves absolute volume paths locally, including the
        // startup volume, without asking a scripting app to coerce an alias or reveal its working directory.
        guard path.contains(":"), !path.hasPrefix(":"), !path.contains("/"),
              let volume = path.split(separator: ":").first, volume != ".", volume != ".." else { return nil }
        let rootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        guard String(volume).localizedCaseInsensitiveCompare(rootName ?? "") == .orderedSame
                || FileManager.default.fileExists(atPath: "/Volumes/" + volume) else { return nil }
        // The Swift SDK marks the HFS enum case unavailable, but CoreFoundation still supports style 1 for
        // decoding legacy scripting paths. Do not replace this with colon/slash substitution.
        guard let url = CFURLCreateWithFileSystemPath(nil, path as CFString, CFURLPathStyle(rawValue: 1)!, path.hasSuffix(":")),
              let resolved = CFURLCopyFileSystemPath(url, .cfurlposixPathStyle) as String?, resolved.hasPrefix("/") else { return nil }
        return [resolved]
    }

    static func inspectProcesses(_ desc: NSAppleEventDescriptor, processes: inout [ScriptEventPolicy.ProcessTarget],
                                 unresolved: inout Bool, depth: Int = 0) {
        guard depth < 64 else { unresolved = true; return }
        if desc.descriptorType == typeObjectSpecifier,
           let desired = desc.forKeyword(AEKeyword(keyAEDesiredClass)) {
            let code = four(desired.typeCodeValue)
            if ["prcs", "pcap", "pcda"].contains(code) {
                let form = desc.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue
                let data = desc.forKeyword(AEKeyword(keyAEKeyData))
                if let form, form == formName, let name = data?.stringValue {
                    let bundle = Apps.bundleURL(for: name).flatMap { Bundle(url: $0) }
                    processes.append(.init(bundleID: bundle?.bundleIdentifier, name: name, executablePath: bundle?.executableURL?.path))
                } else { unresolved = true }
            }
        }
        if desc.numberOfItems > 0 {
            for index in 1...desc.numberOfItems {
                if let child = desc.atIndex(index) { inspectProcesses(child, processes: &processes, unresolved: &unresolved, depth: depth + 1) }
            }
        }
    }
}
