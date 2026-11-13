import Foundation
import MacMCPCore

/// CDP in a fresh headless Chrome profile and incognito context. Never attaches to an existing browser or profile.
public actor ChromeBridge {
    public static let shared = ChromeBridge()
    static let executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let executable: String
    private let profileRoot: URL
    private let policy: @Sendable () async throws -> Policy
    private let queue = ChromeQueue()
    private var process: Process?
    private var transport: ChromeTransport?
    private var profile: URL?
    private var contextID: String?
    private var active: String?
    private var tabs: [String: String] = [:] // our target IDs -> flattened CDP session IDs
    private var documents: [String: String] = [:]
    private var nodes: [String: Node] = [:]
    private var byBackend: [String: String] = [:]
    private let incarnation = UUID().uuidString
    private var nextNode = 0
    private struct Node { let backend: Int; let tab: String; let document: String; let name: String; var shownName: String? }
    private var dialog: (session: String, message: String, url: String)?
    private var logs: [Value] = []
    private var parked: Task<SafariBridge.Reply, Error>?
    private var parkedResult: Result<SafariBridge.Reply, Error>?
    private var interactionGeneration: UInt64 = 0

    public init() {
        executable = Self.executable; profileRoot = URL(fileURLWithPath: Paths.supportDir)
        policy = { switch await Policy.current() { case let .success(p): return p; case let .failure(e): throw e } }
    }
    init(executable: String = ChromeBridge.executable, profileRoot: URL,
         policy: @escaping @Sendable () async throws -> Policy) {
        self.executable = executable; self.profileRoot = profileRoot; self.policy = policy
    }
    public var started: Bool { process?.isRunning == true && transport?.isOpen == true }
    public nonisolated static func stopRunning() { ChromeLifecycle.shared.stop() }
    public func stop() { shutdown() }

    public func call(_ tool: String, _ arguments: [String: Value] = [:], timeout: TimeInterval = 45) async throws -> SafariBridge.Reply {
        // A modal JavaScript dialog can hold a page command open. Answer it outside the occupied page turn.
        if tool == "browser_dialogs" {
            try Task.checkCancellation(); try AgentPause.permit?.check(); try await ActionAdmission.check?()
            let p = try await policy()
            if let why = p.refusal(bundleID: "com.google.Chrome", name: "Google Chrome") ?? p.web.refusal(url: "about:blank") {
                throw ActionError(why)
            }
            let result = try await perform(tool, arguments)
            return SafariBridge.Reply(text: String(decoding: result.jsonData(), as: UTF8.self), isError: false)
        }
        return try await queue.run { [self] in
            do {
                try Task.checkCancellation()
                try AgentPause.permit?.check()
                try await ActionAdmission.check?()
                let p = try await self.policy()
                if let why = p.refusal(bundleID: "com.google.Chrome", name: "Google Chrome") ?? p.web.refusal(url: "about:blank") {
                    throw ActionError(why)
                }
                try await start()
                guard let result = try await Deadline.run(timeout, { try await self.perform(tool, arguments) }) else {
                    await self.shutdown()
                    throw ActionError("Chrome automation timed out; its isolated session was closed. Inspect before retrying.")
                }
                return SafariBridge.Reply(text: String(decoding: result.jsonData(), as: UTF8.self), isError: false)
            } catch {
                await self.shutdown()
                throw error
            }
        }
    }

    public func interact(_ arguments: [String: Value]) async throws -> SafariBridge.Interaction {
        guard started else { throw ActionError("Open a page with web_navigate browser=chrome before acting.") }
        guard parked == nil else { throw ActionError("An earlier Chrome interaction is waiting; answer its dialog first.") }
        interactionGeneration &+= 1
        let generation = interactionGeneration
        let operation = Task {
            do {
                let result = try await call("page_interactions", arguments)
                if generation == interactionGeneration { parkedResult = .success(result) }
                return result
            } catch {
                if generation == interactionGeneration { parkedResult = .failure(error) }
                throw error
            }
        }
        parked = operation
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                if let result = parkedResult { parked = nil; parkedResult = nil; return .done(try result.get()) }
                if parked == nil { throw ActionError("Chrome automation ended during the action; inspect before retrying.") }
                if let dialog { return .dialog(dialog.message) }
                try await Task.sleep(for: .milliseconds(20))
            }
        } onCancel: { operation.cancel() }
    }

    public func finishParked() async -> SafariBridge.Reply? {
        guard let operation = parked else { return nil }
        defer { parked = nil; parkedResult = nil }
        do {
            if let result = try await Deadline.run(15, { try await operation.value }) { return result }
            operation.cancel(); shutdown()
            return SafariBridge.Reply(text: "Chrome did not finish the interrupted action; its session was closed. Inspect before retrying.", isError: true)
        } catch { return SafariBridge.Reply(text: "Chrome's interrupted action failed; inspect before retrying.", isError: true) }
    }

    private func shutdown() {
        interactionGeneration &+= 1; parked?.cancel(); parked = nil; parkedResult = nil
        transport?.close(); transport = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; contextID = nil; active = nil; tabs.removeAll(); documents.removeAll()
        nodes.removeAll(); byBackend.removeAll(); dialog = nil; logs.removeAll()
        if let profile { try? FileManager.default.removeItem(at: profile) }; profile = nil
    }

    private func start() async throws {
        if started { return }
        guard !AgentPause.shared.status.paused else { throw ActionError(AgentPause.refusal) }
        shutdown()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ActionError("Chrome automation needs Google Chrome installed in Applications.")
        }
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let directory = profileRoot.appendingPathComponent("chrome-automation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        profile = directory
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--headless=new", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
            "--user-data-dir=" + directory.path, "--no-first-run", "--no-default-browser-check", "--disable-sync",
            "--disable-extensions", "--disable-background-networking", "--disable-component-update", "--use-mock-keychain",
            "--window-size=1280,800", "about:blank"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { _ in try? FileManager.default.removeItem(at: directory) }
        do { try child.run() } catch { shutdown(); throw ActionError("Could not start isolated Chrome.") }
        process = child
        ChromeLifecycle.shared.install { if child.isRunning { child.terminate() }; try? FileManager.default.removeItem(at: directory) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var endpoint: URL?
        while ContinuousClock.now < deadline, child.isRunning {
            try Task.checkCancellation(); try AgentPause.permit?.check()
            if let text = try? String(contentsOf: directory.appendingPathComponent("DevToolsActivePort"), encoding: .utf8) {
                let lines = text.split(separator: "\n")
                if lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port), lines[1].hasPrefix("/devtools/browser/") {
                    endpoint = URL(string: "ws://127.0.0.1:\(port)\(lines[1])"); break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let endpoint else { shutdown(); throw ActionError("Isolated Chrome did not start within 15 seconds.") }
        let connection = ChromeTransport(url: endpoint) { [weak self] method, params, session in
            await self?.event(method, params, session: session)
        }
        transport = connection
        ChromeLifecycle.shared.install {
            connection.close(); if child.isRunning { child.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let created = try await command("Target.createBrowserContext", ["disposeOnDetach": true])
            contextID = created["browserContextId"]?.stringValue
            guard let contextID else { throw ActionError("Chrome could not create an isolated context.") }
            _ = try await command("Browser.setDownloadBehavior", ["behavior": "deny", "browserContextId": .string(contextID)])
        } catch { shutdown(); throw error }
    }

    private func command(_ method: String, _ parameters: [String: Value] = [:], session: String? = nil) async throws -> Value {
        try Task.checkCancellation(); try AgentPause.permit?.check()
        guard let transport, process?.isRunning == true else { throw ActionError("Chrome automation ended; retry to start a fresh session.") }
        do { return try await transport.request(method, parameters, sessionID: session) }
        catch { shutdown(); throw error }
    }

    private func checkURL(_ url: String) async throws {
        let p = try await policy()
        if let why = p.refusal(bundleID: "com.google.Chrome", name: "Google Chrome") ?? p.web.refusal(url: url) { throw ActionError(why) }
    }

    private func newTab() async throws -> String {
        guard tabs.count < 32 else { throw ActionError("Chrome automation has 32 tabs; close some before opening another.") }
        guard let contextID else { throw ActionError("No Chrome automation context.") }
        let result = try await command("Target.createTarget", ["url": "about:blank", "browserContextId": .string(contextID)])
        guard let id = result["targetId"]?.stringValue else { throw ActionError("Chrome could not create a tab.") }
        let attached = try await command("Target.attachToTarget", ["targetId": .string(id), "flatten": true])
        guard let session = attached["sessionId"]?.stringValue else { throw ActionError("Chrome could not attach to its tab.") }
        tabs[id] = session; active = id
        _ = try await command("Page.enable", session: session)
        _ = try await command("Runtime.enable", session: session)
        _ = try await command("Network.enable", session: session)
        _ = try await command("Accessibility.enable", session: session)
        _ = try await command("Page.setInterceptFileChooserDialog", ["enabled": true], session: session)
        _ = try await command("Fetch.enable", ["patterns": [["urlPattern": "*", "requestStage": "Request"]]], session: session)
        return id
    }

    private func currentTab() async throws -> (String, String) {
        let id: String
        if let active, tabs[active] != nil { id = active } else { id = try await newTab() }
        guard let session = tabs[id] else { throw ActionError("No active Chrome tab.") }
        return (id, session)
    }

    private func frame(_ session: String, tab: String) async throws -> Value {
        let result = try await command("Page.getFrameTree", session: session)
        guard let frame = result["frameTree"]?["frame"], let loader = frame["loaderId"]?.stringValue,
              let url = frame["url"]?.stringValue else { throw ActionError("Chrome's document identity is unavailable.") }
        try await checkURL(url)
        if documents[tab] != loader {
            nodes = nodes.filter { $0.value.tab != tab }; byBackend = byBackend.filter { nodes[$0.value] != nil }
            documents[tab] = loader
        }
        return frame
    }

    private func evaluate(_ expression: String, session: String, frame: Value) async throws -> Value {
        guard let frameID = frame["id"]?.stringValue else { throw ActionError("No frame identity.") }
        let world = try await command("Page.createIsolatedWorld", ["frameId": .string(frameID), "worldName": "MacMCP"], session: session)
        guard let context = world["executionContextId"] else { throw ActionError("Could not isolate the page reader.") }
        let result = try await command("Runtime.evaluate", ["expression": .string(expression), "contextId": context,
            "returnByValue": true, "awaitPromise": false], session: session)
        if result["exceptionDetails"] != nil { throw ActionError("The Chrome page operation failed.") }
        return result["result"]?["value"] ?? .null
    }

    private func page(session: String, tab: String, markdown: Bool = false, markShown: Bool = true) async throws -> Value {
        let frame = try await self.frame(session, tab: tab)
        let tree = try await command("Accessibility.getFullAXTree", ["depth": 20], session: session)
        let document = documents[tab] ?? ""
        let interactive: Set<String> = ["button", "link", "textbox", "textField", "combobox", "checkbox", "radio", "menuitem", "option", "slider", "spinbutton", "searchbox", "tab"]
        var lines: [String] = []
        var current: Set<String> = []
        let budget = min(60_000, max(0, AutomationBrowser.maxChars))
        var used = 0, omitted = false
        for entry in (tree["nodes"]?.arrayValue ?? []).prefix(3000) where entry["ignored"] != true {
            let role = entry["role"]?["value"]?.stringValue ?? ""
            let name = String((entry["name"]?["value"]?.stringValue ?? "").prefix(250)).replacingOccurrences(of: "\n", with: " ")
            guard !name.isEmpty || interactive.contains(role) else { continue }
            var prefix = role
            var rowUID: String?
            if interactive.contains(role), let backend = entry["backendDOMNodeId"]?.intValue {
                let key = "\(tab):\(document):\(backend)"
                let uid: String
                if let existing = byBackend[key] { uid = existing }
                else {
                    nextNode += 1; uid = "chrome-\(incarnation)-\(nextNode)"
                    byBackend[key] = uid
                }
                nodes[uid] = Node(backend: backend, tab: tab, document: document, name: name, shownName: nodes[uid]?.shownName)
                current.insert(uid)
                rowUID = uid
                prefix = "uid=\(uid) " + role
            }
            // Never echo editable values (including passwords) into the page tree.
            let line = prefix + " \"" + name + "\""
            if used + line.count + 1 <= budget, !omitted {
                lines.append(line); used += line.count + 1
                if markShown, !markdown, let rowUID { nodes[rowUID]?.shownName = name }
            } else { omitted = true }
        }
        nodes = nodes.filter { $0.value.tab != tab || current.contains($0.key) }
        byBackend = byBackend.filter { nodes[$0.value] != nil }
        let title = try await evaluate("document.title", session: session, frame: frame)
        let content: String
        if markdown {
            content = try await evaluate("document.body ? document.body.innerText.slice(0, \(budget)) : ''", session: session, frame: frame).stringValue ?? ""
        } else { content = lines.joined(separator: "\n") + (omitted ? "\n… Chrome tree omitted rows; raise max_chars or read again" : "") }
        return ["url": frame["url"] ?? "about:blank", "title": title, "content": .string(content)]
    }

    private func navigate(_ url: String, tab: String, session: String) async throws -> Value {
        try await checkURL(url)
        nodes = nodes.filter { $0.value.tab != tab }
        byBackend = byBackend.filter { nodes[$0.value] != nil }
        let result = try await command("Page.navigate", ["url": .string(url)], session: session)
        if result["errorText"] != nil { throw ActionError("Chrome navigation failed or was blocked by web policy.") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let frame = try await self.frame(session, tab: tab)
            let state = try await evaluate("document.readyState", session: session, frame: frame)
            if state == "interactive" || state == "complete" { return try await page(session: session, tab: tab) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ActionError("Chrome's page did not become ready; inspect it before retrying navigation.")
    }

    private func perform(_ tool: String, _ args: [String: Value]) async throws -> Value {
        if tool == "list_tabs" {
            let targets = try await command("Target.getTargets")["targetInfos"]?.arrayValue ?? []
            return .array(targets.filter { $0["browserContextId"]?.stringValue == contextID && $0["type"] == "page" }.map {
                ["handle": .string("chrome-" + ($0["targetId"]?.stringValue ?? "")), "title": $0["title"] ?? "",
                 "url": $0["url"] ?? "", "active": .bool($0["targetId"]?.stringValue == active)]
            })
        }
        if tool == "create_tab" {
            let tab = try await newTab()
            guard let session = tabs[tab] else { throw ActionError("Chrome lost its new tab.") }
            return try await navigate(args["url"]?.stringValue ?? "about:blank", tab: tab, session: session)
        }
        if tool == "switch_tab" || tool == "close_tab" {
            let handle = args["handle"]?.stringValue ?? ""
            guard handle.hasPrefix("chrome-"), let session = tabs[String(handle.dropFirst(7))] else { throw ActionError("Unknown Chrome tab handle.") }
            let tab = String(handle.dropFirst(7))
            if tool == "close_tab" {
                _ = try await command("Target.closeTarget", ["targetId": .string(tab)])
                tabs[tab] = nil; nodes = nodes.filter { $0.value.tab != tab }; byBackend = byBackend.filter { nodes[$0.value] != nil }
                if active == tab { active = tabs.keys.sorted().first }; return ["closed": true]
            }
            _ = try await frame(session, tab: tab); active = tab
            return ["active": .string(handle)]
        }
        if tool == "browser_dialogs" {
            guard let dialog else { return ["dialogs": []] }
            if args["action"] == "list" { return ["message": .string(dialog.message)] }
            let accept = args["action"] == "respond"
            if accept { try await checkURL(dialog.url) }
            var parameters: [String: Value] = ["accept": .bool(accept)]
            if let text = args["inputText"] { parameters["promptText"] = text }
            _ = try await command("Page.handleJavaScriptDialog", parameters, session: dialog.session)
            self.dialog = nil; return ["answered": true]
        }
        if tool == "browser_console_messages" || tool == "list_network_requests" {
            let kind: Value = tool == "list_network_requests" ? "network" : "console"
            let levels = args["level_filter"]?.arrayValue
            return .array(logs.filter { entry in
                entry["kind"] == kind && (kind == "network" || (levels.map { $0.contains(entry["type"] ?? "log") } ?? true))
            })
        }
        let (tab, session) = try await currentTab()
        if tool == "navigate_to_url" {
            if let requested = args["tab_uuid"]?.stringValue {
                let key = requested.hasPrefix("chrome-") ? String(requested.dropFirst(7)) : requested
                guard let target = tabs[key] else { throw ActionError("Unknown Chrome tab handle.") }
                active = key; return try await navigate(args["url"]?.stringValue ?? "about:blank", tab: key, session: target)
            }
            return try await navigate(args["url"]?.stringValue ?? "about:blank", tab: tab, session: session)
        }
        let frame = try await self.frame(session, tab: tab)
        switch tool {
        case "page_info": return ["url": frame["url"] ?? "about:blank"]
        case "get_page_content": return try await page(session: session, tab: tab, markdown: args["format"] == "markdown")
        case "screenshot":
            return try await command("Page.captureScreenshot", ["format": "png", "captureBeyondViewport": false], session: session)
        case "evaluate_javascript":
            let p = try await policy()
            guard p.web.evalAllowed else { throw ActionError("Refused by policy: web_eval is off.") }
            return try await evaluate("(() => {" + (args["expression"]?.stringValue ?? "") + "})()", session: session, frame: frame)
        case "page_interactions":
            let interactions = args["interactions"]?.arrayValue ?? []
            guard interactions.count <= 100 else { throw ActionError("At most 100 web actions per call.") }
            _ = try await page(session: session, tab: tab, markShown: false)
            var done = 0, failure: String?
            for step in interactions {
                do {
                    _ = try await self.frame(session, tab: tab)
                    try await action(step, tab: tab, session: session)
                    done += 1
                    try await Task.sleep(for: .milliseconds(40))
                    if dialog != nil { break }
                } catch { failure = "\(error)"; break }
            }
            var result = dialog == nil ? try await page(session: session, tab: tab) : ["url": frame["url"] ?? "about:blank", "content": "A JavaScript dialog is open."]
            var object = result.objectValue ?? [:]
            object["successful"] = .int(done); object["requested"] = .int(interactions.count)
            if let failure { object["failureReason"] = .string(failure) }
            result = .object(object); return result
        default: throw ActionError("Chrome does not support that browser operation.")
        }
    }

    private func resolve(_ step: Value, tab: String) throws -> Node {
        if let uid = step["node"]?.stringValue {
            guard let node = nodes[uid], node.tab == tab, node.document == documents[tab],
                  let shown = node.shownName, shown == node.name else {
                throw ActionError("Unknown or stale Chrome uid. Read the page with browser=chrome first.")
            }
            return node
        }
        let title = step["text"]?.stringValue ?? ""
        let matches = nodes.values.filter { $0.tab == tab && $0.document == documents[tab] && $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }
        guard matches.count == 1, let node = matches.first else { throw ActionError("Visible text must match exactly one interactive node; use its uid.") }
        return node
    }

    private func function(_ function: String, on node: Node, session: String, arguments: [Value] = []) async throws -> Value {
        let frame = try await self.frame(session, tab: node.tab)
        guard node.document == documents[node.tab], let frameID = frame["id"] else { throw ActionError("Stale Chrome document; read the page again.") }
        let world = try await command("Page.createIsolatedWorld", ["frameId": frameID, "worldName": "MacMCP"], session: session)
        guard let context = world["executionContextId"] else { throw ActionError("Could not isolate the element reader.") }
        let resolved = try await command("DOM.resolveNode", ["backendNodeId": .int(node.backend), "executionContextId": context], session: session)
        guard let object = resolved["object"]?["objectId"] else { throw ActionError("The Chrome node no longer exists.") }
        let result = try await command("Runtime.callFunctionOn", ["objectId": object, "functionDeclaration": .string(function),
            "arguments": .array(arguments.map { ["value": $0] }), "returnByValue": true], session: session)
        _ = try? await command("Runtime.releaseObject", ["objectId": object], session: session)
        guard result["exceptionDetails"] == nil else { throw ActionError("The Chrome element operation failed.") }
        return result["result"]?["value"] ?? .null
    }

    private func action(_ step: Value, tab: String, session: String) async throws {
        try Task.checkCancellation(); try AgentPause.permit?.check(); try await ActionAdmission.check?()
        let type = step["type"]?.stringValue ?? ""
        if type == "scroll" {
            _ = try await command("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": 100, "y": 100, "deltaX": 0,
                "deltaY": .int(min(5000, max(-5000, step["scrollDelta"]?["y"]?.intValue ?? 400)))], session: session); return
        }
        if type == "keyPress" { try await key(step["value"]?.stringValue ?? "", session: session); return }
        let node = try resolve(step, tab: tab)
        let described = try await command("DOM.describeNode", ["backendNodeId": .int(node.backend)], session: session)
        let attributes = described["node"]?["attributes"]?.arrayValue ?? []
        for i in stride(from: 0, to: max(0, attributes.count - 1), by: 2) {
            if type != "hover", attributes[i] == "disabled" || attributes[i] == "aria-disabled" && attributes[i + 1] == "true" {
                throw ActionError("The Chrome control is disabled.")
            }
        }
        for i in stride(from: 0, to: max(0, attributes.count - 1), by: 2) where attributes[i] == "type" && attributes[i + 1].stringValue?.lowercased() == "file" {
            throw ActionError("File uploads require a person; Chrome automation never selects local files.")
        }
        _ = try await command("DOM.scrollIntoViewIfNeeded", ["backendNodeId": .int(node.backend)], session: session)
        if type == "type" {
            let before = try await function("function(){if(!this.isConnected || this.disabled || this.readOnly)throw Error(); if(!['INPUT','TEXTAREA'].includes(this.tagName))throw Error(); return this.value;}", on: node, session: session)
            guard let previous = before.stringValue else { throw ActionError("The field's value cannot be verified; no text was sent.") }
            _ = try await command("DOM.focus", ["backendNodeId": .int(node.backend)], session: session)
            let replace = step["replaceAll"]?.boolValue ?? true
            _ = try await function("function(replace){this.setSelectionRange(replace ? 0 : this.value.length,this.value.length);}", on: node, session: session, arguments: [.bool(replace)])
            let text = step["value"]?.stringValue ?? ""
            _ = try await command("Input.insertText", ["text": .string(text)], session: session)
            let after = try await function("function(){return this.value;}", on: node, session: session)
            guard after.stringValue == (replace ? text : previous + text) else { throw ActionError("Chrome field verification failed after typing; inspect before retrying.") }
            if step["pressReturn"] == true { try await key("Enter", session: session) }
        } else if type == "selectMenuItem" {
            let ok = try await function("function(label){if(this.tagName!=='SELECT'||this.disabled)throw Error(); const matches=Array.from(this.options).filter(x=>x.label===label && !x.disabled); if(matches.length!==1)throw Error(); this.value=matches[0].value; this.dispatchEvent(new Event('input',{bubbles:true})); this.dispatchEvent(new Event('change',{bubbles:true})); return this.value===matches[0].value;}", on: node, session: session, arguments: [step["text"] ?? ""])
            guard ok == true else { throw ActionError("Chrome selection was not verified.") }
        } else {
            let quads = try await command("DOM.getContentQuads", ["backendNodeId": .int(node.backend)], session: session)["quads"]?.arrayValue
            guard let quad = quads?.first?.arrayValue, quad.count == 8 else { throw ActionError("The Chrome element has no visible bounds.") }
            let xs = stride(from: 0, to: 8, by: 2).compactMap { quad[$0].doubleValue }
            let ys = stride(from: 1, to: 8, by: 2).compactMap { quad[$0].doubleValue }
            guard xs.count == 4, ys.count == 4, xs.allSatisfy(\.isFinite), ys.allSatisfy(\.isFinite) else { throw ActionError("Invalid Chrome element bounds.") }
            let x = xs.reduce(0,+) / 4, y = ys.reduce(0,+) / 4
            guard x.isFinite, y.isFinite, (0...10_000_000).contains(x), (0...10_000_000).contains(y) else { throw ActionError("The Chrome element is outside the viewport.") }
            let hit = try await command("DOM.getNodeForLocation", ["x": .int(Int(x)), "y": .int(Int(y)), "includeUserAgentShadowDOM": true], session: session)
            if hit["backendNodeId"]?.intValue != node.backend {
                let within = try await function("function(x,y){const hit=this.ownerDocument.elementFromPoint(x,y);return hit===this||this.contains(hit);}",
                    on: node, session: session, arguments: [.double(x), .double(y)])
                guard within == true else { throw ActionError("The Chrome element is covered; inspect the page before retrying.") }
            }
            _ = try await command("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": .double(x), "y": .double(y)], session: session)
            if type == "click" {
                _ = try await command("Input.dispatchMouseEvent", ["type": "mousePressed", "button": "left", "clickCount": 1, "x": .double(x), "y": .double(y)], session: session)
                _ = try await command("Input.dispatchMouseEvent", ["type": "mouseReleased", "button": "left", "clickCount": 1, "x": .double(x), "y": .double(y)], session: session)
            } else if type != "hover" { throw ActionError("Unsupported Chrome interaction.") }
        }
    }

    private func key(_ key: String, session: String) async throws {
        let names: [String: Int] = ["Enter": 13, "Tab": 9, "Escape": 27, "Backspace": 8, "Delete": 46,
            "ArrowLeft": 37, "ArrowRight": 39, "ArrowUp": 38, "ArrowDown": 40, "Home": 36, "End": 35, "PageUp": 33, "PageDown": 34, " ": 32]
        guard let code = names[key] else {
            if key.count == 1 { _ = try await command("Input.insertText", ["text": .string(key)], session: session); return }
            throw ActionError("Chrome keys support unmodified named keys or one character; use type for text.")
        }
        var params: [String: Value] = ["type": "keyDown", "key": .string(key), "windowsVirtualKeyCode": .int(code)]
        if key == "Enter" { params["text"] = "\r"; params["unmodifiedText"] = "\r" }
        _ = try await command("Input.dispatchKeyEvent", params, session: session)
        params["type"] = "keyUp"; params["text"] = nil; params["unmodifiedText"] = nil
        _ = try await command("Input.dispatchKeyEvent", params, session: session)
    }

    private func event(_ method: String, _ params: Value, session: String?) async {
        guard let session, tabs.values.contains(session) else { return }
        switch method {
        case "Fetch.requestPaused":
            guard let id = params["requestId"], let connection = transport else { return }
            let url = params["request"]?["url"]?.stringValue ?? ""
            let allowed: Bool
            do { try await checkURL(url); allowed = !AgentPause.shared.status.paused } catch { allowed = false }
            _ = try? await connection.request(allowed ? "Fetch.continueRequest" : "Fetch.failRequest",
                allowed ? ["requestId": id] : ["requestId": id, "errorReason": "BlockedByClient"], sessionID: session)
        case "Page.javascriptDialogOpening":
            dialog = (session, String((params["message"]?.stringValue ?? "").prefix(1000)), params["url"]?.stringValue ?? "")
        case "Page.javascriptDialogClosed": dialog = nil
        case "Runtime.consoleAPICalled":
            logs.append(["kind": "console", "type": params["type"] ?? "log", "message": .string((params["args"]?.arrayValue ?? []).map {
                String(($0["value"]?.stringValue ?? $0["description"]?.stringValue ?? "").prefix(300))
            }.prefix(10).joined(separator: " "))])
        case "Network.responseReceived": logs.append(["kind": "network", "url": params["response"]?["url"] ?? "", "status": params["response"]?["status"] ?? .null])
        default: break
        }
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }
}
