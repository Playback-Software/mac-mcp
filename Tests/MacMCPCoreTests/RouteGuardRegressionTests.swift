import AppKit
import Foundation
import Testing
@testable import MacMCPCore

@Suite struct RouteGuardRegressionTests {
    private func edit(_ text: String, current: String?, selection: CFRange?, mode: Actions.TypeMode = .insert) -> String? {
        OpenRoutes.fieldEditRefusal(text, current: current, selection: selection, mode: mode, naming: true) {
            OpenRoutes.typingRefusal($0, bases: [], scan: { [] })
        }
    }

    @Test func insertedAndPastedFragmentsAreCheckedAsTheResultingName() {
        #expect(edit("h", current: "~/.ss", selection: CFRange(location: 5, length: 0))?.contains("protected") == true)
        #expect(edit("d", current: "payload.comman", selection: CFRange(location: 14, length: 0)) != nil)
        #expect(edit("command", current: "🙂.txt", selection: CFRange(location: 3, length: 3)) != nil)
        #expect(edit("notes.txt", current: "payload.command", selection: CFRange(location: 0, length: 15)) == nil)
        #expect(edit("notes.txt", current: "payload.command", selection: nil, mode: .replace) == nil)
        #expect(edit("d", current: "payload.comman", selection: nil, mode: .append) != nil)
        #expect(edit("x", current: "notes", selection: nil) != nil)
        #expect(edit("x", current: "notes", selection: CFRange(location: 99, length: 0)) != nil)
    }

    @Test func menuCommandsUseMetadataInEveryLanguage() {
        // Pegar / Coller / Einsetzen and Abrir / Ouvrir have identical AX command metadata.
        #expect(OpenRoutes.menuCommand(character: "v", modifiers: 0) == .paste)
        #expect(OpenRoutes.menuCommand(character: "V", modifiers: 3) == .paste)
        #expect(OpenRoutes.menuCommand(character: "v", modifiers: 8) != .paste)
        #expect(OpenRoutes.menuCommand(character: "o", modifiers: 0) == .open)
        #expect(OpenRoutes.menuCommand(character: "o", modifiers: 1) != .open)
        #expect(OpenRoutes.menuCommand(character: "\u{F701}", modifiers: 2) == .open)
        #expect(OpenRoutes.menuCommand(character: nil, modifiers: 0, virtualKey: 125) == .open)
        #expect(OpenRoutes.menuCommand(character: nil, modifiers: nil) == .unknown)
        for key in [36, 76, 49] { #expect(OpenRoutes.activatesMenuItem(KeySpec(key: CGKeyCode(key), flags: []))) }
        #expect(!OpenRoutes.activatesMenuItem(KeySpec(key: 125, flags: [])))
    }

    @Test func explicitUnresolvedHandlersNeverUseTheDefaultApp() {
        let selection = [URL(fileURLWithPath: NSTemporaryDirectory() + "ordinary.txt")]
        #expect(OpenRoutes.explicitHandlerRefusal(app: nil, selection: selection, policy: Policy()) != nil)
        #expect(OpenRoutes.handlerName("TextEdit 1.20 (default)") == "TextEdit")
        #expect(OpenRoutes.handlerName("TextEdit 1.20") == "TextEdit")
        #expect(OpenRoutes.handlerName("Other…") == nil)
        #expect(OpenRoutes.handlerName("Otra…") == nil)
        #expect(OpenRoutes.explicitHandlerRefusal(app: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                selection: selection, policy: Policy()) != nil)
    }

    @Test func installsRollbackAndStagingEntriesAreProtectedWithoutProtectingTheirNeighbors() {
        for path in ["~/.local/bin/mac-mcp", "~/.local/bin/mac-mcp.previous", "~/.local/bin/.mac-mcp.new.123",
                     "~/Applications/MacMCP.app/Contents/MacOS/MacMCPAgent", "~/Applications/MacMCP.app.previous/Contents/Info.plist",
                     "~/Applications/.MacMCP-stage.abcdef/MacMCP.app/Contents/Info.plist", "~/Applications/MacMCPTestHost.app/Contents/MacOS/TestHost"] {
            #expect(ProtectedPaths.isProtected(path), "\(path)")
        }
        for path in ["~/.local/bin", "~/.local", "~/Applications"] {
            #expect(!ProtectedPaths.isProtected(path), "\(path)")
            #expect(ProtectedPaths.isProtectedFromMutation(path), "\(path)")
        }
        for path in ["~/.local/bin/other-tool", "~/Applications/Other.app/Contents/Info.plist", "~/Documents/bin"] {
            #expect(!ProtectedPaths.isProtectedFromMutation(path), "\(path)")
        }
        // A drop/replace into ~/.local/bin is checked with the source's basename, not by blocking the directory.
        #expect(ProtectedPaths.isProtectedFromMutation("mac-mcp", relativeTo: Paths.home + "/.local/bin"))
        #expect(!ProtectedPaths.isProtectedFromMutation("other-tool", relativeTo: Paths.home + "/.local/bin"))
        #expect(OpenRoutes.typingRefusal("mac-mcp", bases: [Paths.home + "/.local/bin"], scan: { [] }) != nil)
        #expect(OpenRoutes.typingRefusal("other-tool", bases: [Paths.home + "/.local/bin"], scan: { [] }) == nil)
    }

    @Test func replacementsCheckTheDestinationEntryAndFailClosedWithoutAFolder() {
        let source = URL(fileURLWithPath: "/tmp/bin")
        #expect(OpenRoutes.moveRefusal(source: source, destinationFolder: URL(fileURLWithPath: Paths.home + "/.local")) != nil)
        #expect(OpenRoutes.moveRefusal(source: URL(fileURLWithPath: "/tmp/other-tool"),
                                       destinationFolder: URL(fileURLWithPath: Paths.home + "/.local/bin")) == nil)
        #expect(OpenRoutes.moveRefusal(source: source, destinationFolder: nil) != nil)
        #expect(OpenRoutes.mutationSelectionRefusal(nil) != nil)
        #expect(OpenRoutes.mutationSelectionRefusal([URL(fileURLWithPath: Paths.home + "/.local/bin")]) != nil)
    }

    @Test func hardLinksToProtectedFilesAreProtectedByIdentity() throws {
        let root = NSTemporaryDirectory() + "route-hardlinks-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.config/gh", withIntermediateDirectories: true)
        for (index, original) in [home + "/.zshrc", home + "/.ssh/config", home + "/.local/bin/mac-mcp",
                                  home + "/.config/gh/hosts.yml", home + "/.netrc"].enumerated() {
            try Data("protected".utf8).write(to: URL(fileURLWithPath: original))
            let alias = root + "/ordinary-\(index).txt"
            try FileManager.default.linkItem(atPath: original, toPath: alias)
            #expect(ProtectedPaths.isProtected(alias, home: home))
            // Replacing the protected file drops the old identity; no stale cached inode remains.
            try FileManager.default.removeItem(atPath: original)
            try Data("replacement".utf8).write(to: URL(fileURLWithPath: original))
            #expect(!ProtectedPaths.isProtected(alias, home: home))
        }
        let a = root + "/a.txt", b = root + "/b.txt"
        try Data("ordinary".utf8).write(to: URL(fileURLWithPath: a))
        try FileManager.default.linkItem(atPath: a, toPath: b)
        #expect(!ProtectedPaths.isProtected(b, home: home))
    }

    @Test func screenSharingInvitationIsASystemPrompt() {
        #expect(WindowServer.isPromptProcess(bundleID: "com.apple.ssinvitationagent", executablePath: nil, name: nil))
        #expect(WindowServer.isPromptProcess(bundleID: nil, executablePath: "/System/Library/CoreServices/SSInvitationAgent.app/Contents/MacOS/SSInvitationAgent", name: nil))
        #expect(WindowServer.isPromptProcess(bundleID: nil, executablePath: nil, name: "SSInvitationAgent"))
        #expect(!WindowServer.isPromptProcess(bundleID: "org.example.app", executablePath: "/tmp/SSInvitationAgent", name: nil))
    }
}

private actor RouteGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; let all = waiting; waiting = []; all.forEach { $0.resume() } }
}

private final class RouteState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "safe.txt"
    private var keys: [CGKeyCode] = []
    private var mouseDowns = 0
    var current: String { lock.withLock { value } }
    var postedKeys: [CGKeyCode] { lock.withLock { keys } }
    var clicks: Int { lock.withLock { mouseDowns } }
    func set(_ value: String) { lock.withLock { self.value = value } }
    func post(_ e: CGEvent) {
        lock.withLock {
            if e.type == .keyDown {
                let key = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
                keys.append(key)
                if key == 125 { value = "run.command" }
                if key == 2 { value += "d" }
            }
            if e.type == .leftMouseDown { mouseDowns += 1 }
        }
    }
}

@Suite struct RouteStepRegressionTests {
    @Test(arguments: ["cmd+o", "cmd+down", "space"])
    func selectionIsReadImmediatelyBeforeEachOpeningKey(_ command: String) async throws {
        let state = RouteState()
        let environment = Input.Environment(check: { _, _ in }, post: { state.post($0) })
        await #expect(throws: ActionError.self) {
            try await ActionRoute.$check.withValue({ step in
                if case let .key(key, _) = step, OpenRoutes.opensSelection(key) || key.key == 49 {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory() + state.current)
                    if let r = OpenRoutes.selectionRefusal([url], explicitApp: nil, policy: Policy()) { throw ActionError(r) }
                }
            }) {
                try await Input.$environment.withValue(environment) {
                    for spec in try KeySpec.parseSequence("down, " + command) { try await Input.press(spec, pid: 42) }
                }
            }
        }
        #expect(state.postedKeys == [125])
    }

    @Test(arguments: ["return", "enter", "tab", "carriage-return", "space", "ctrl+m", "cmd+s"])
    func printableKeysAndTypedControlCharactersRecheckTheActualField(_ command: String) async throws {
        let state = RouteState()
        state.set("payload.comman")
        let environment = Input.Environment(check: { _, _ in }, post: { state.post($0) })
        await #expect(throws: ActionError.self) {
            try await ActionRoute.$check.withValue({ step in
                if case let .key(key, _) = step, OpenRoutes.commitsField(key),
                   let r = OpenRoutes.typingRefusal(state.current, bases: [], scan: { [] }) { throw ActionError(r) }
            }) {
                try await Input.$environment.withValue(environment) {
                    try await Input.press(KeySpec.parse("d"), pid: 42)
                    if command == "carriage-return" { try await Input.type("\r", pid: 42) }
                    else if command == "return" { try await Input.type("\n", pid: 42) }
                    else if command == "tab" { try await Input.type("\t", pid: 42) }
                    else { try await Input.press(KeySpec.parse(command), pid: 42) }
                }
            }
        }
        #expect(state.postedKeys == [2])
    }

    @Test func queuedDoubleClickRechecksTheChangedTargetInsideTheLock() async throws {
        let lock = ActionLock(), started = RouteGate(), proceed = RouteGate(), queued = RouteGate()
        let state = RouteState()
        let first = Task {
            try await lock.run("rearrange") {
                await started.open()
                await proceed.wait()
                state.set("run.command")
            }
        }
        await started.wait()
        let second = Task {
            await queued.open()
            try await lock.run("double-click") {
                try await ActionRoute.$check.withValue({ step in
                    if case let .target(_, point, _, opens) = step, opens {
                        #expect(point == CGPoint(x: 20, y: 30))
                        let url = URL(fileURLWithPath: NSTemporaryDirectory() + state.current)
                        if let r = OpenRoutes.openingRefusal(url: url, policy: Policy()) { throw ActionError(r) }
                    }
                }) {
                    try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { state.post($0) })) {
                        try await Input.click(at: CGPoint(x: 20, y: 30), count: 2, pid: 42)
                    }
                }
            }
        }
        await queued.wait()
        await proceed.open()
        try await first.value
        await #expect(throws: ActionError.self) { try await second.value }
        #expect(state.clicks == 0)
    }

    @Test func clipboardAndMenuStateAreRecheckedForEachRepeatedActivation() async throws {
        let state = RouteState()
        await #expect(throws: ActionError.self) {
            try await ActionRoute.$check.withValue({ step in
                if case let .key(key, _) = step, OpenRoutes.activatesMenuItem(key), !state.postedKeys.isEmpty {
                    throw ActionError("Refused: clipboard changed to a concealed value.")
                }
            }) {
                try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { state.post($0) })) {
                    try await Input.press(KeySpec.parse("return"), repeat: 2, pid: 42)
                }
            }
        }
        #expect(state.postedKeys == [36])
    }

    // MARK: Finder's selection

    private let documents = URL(fileURLWithPath: Paths.home + "/Documents/notes.txt")
    private let privateKey = URL(fileURLWithPath: Paths.home + "/.ssh/id_rsa")
    private let selectionKeys = ["cmd+c", "alt+cmd+c", "cmd+x", "cmd+v", "alt+cmd+v", "cmd+d", "cmd+l", "cmd+delete", "cmd+i",
                                 "alt+cmd+i", "cmd+y", "cmd+r", "cmd+o", "cmd+down", "return", "enter", "space", "delete",
                                 "forwarddelete", "alt+space", "alt+cmd+down", "alt+cmd+o", "ctrl+cmd+n", "ctrl+cmd+a", "ctrl+cmd+t",
                                 "ctrl+cmd+1", "ctrl+cmd+w", "ctrl+cmd+up"]
    private let leavingKeys = ["cmd+n", "cmd+shift+n", "cmd+w", "cmd+f", "cmd+a", "cmd+z", "cmd+1", "cmd+2", "cmd+3", "cmd+4",
                               "cmd+[", "cmd+]", "cmd+up", "cmd+t", "cmd+comma", "cmd+shift+g", "cmd+shift+c", "cmd+shift+d",
                               "cmd+shift+l", "cmd+shift+i", "cmd+shift+r", "cmd+shift+h", "cmd+h", "tab", "down", "esc"]

    @Test func credentialFilesAreRefusedByOpenTypingAndFinderRoutes() throws {
        let duplicate = try KeySpec.parse("cmd+d")
        for file in [".config/gh/hosts.yml", ".aws/credentials", ".netrc", ".git-credentials", ".docker/config.json",
                     ".kube/config", ".gnupg/private-keys-v1.d/key", ".npmrc", ".pypirc", ".config/gcloud/credentials.db",
                     ".azure/msal_token_cache.json", ".password-store/example.gpg", ".config/op/config", ".config/hub",
                     ".terraform.d/credentials.tfrc.json"] {
            let url = URL(fileURLWithPath: Paths.home + "/" + file)
            #expect(OpenRoutes.refusal(opening: .file(url), explicitApp: nil, policy: Policy())?.contains("protected") == true, "\(file)")
            #expect(OpenRoutes.typedPathRefusal("~/" + file)?.contains("protected") == true, "\(file)")
            #expect(OpenRoutes.typingRefusal(url.lastPathComponent, bases: [url.deletingLastPathComponent().path], scan: { [] }) != nil, "\(file)")
            #expect(OpenRoutes.finderKeyRefusal(duplicate, selection: [documents, url], policy: Policy())?.contains("protected") == true, "\(file)")
        }
    }

    @Test func anUnreadableFinderSelectionRefusesEveryKeyThatActsOnIt() throws {
        for spec in selectionKeys {
            let key = try KeySpec.parse(spec)
            #expect(OpenRoutes.needsSelectionRead(key), "\(spec)")
            #expect(OpenRoutes.finderKeyRefusal(key, selection: nil, policy: Policy()) != nil, "\(spec)")
        }
        let copy = try KeySpec.parse("cmd+c")
        #expect(OpenRoutes.mutatesSelection(copy))   // copy used to pass with a selection nobody could read
        #expect(OpenRoutes.finderKeyRefusal(copy, selection: nil, policy: Policy()) == OpenRoutes.unreadableSelectionRefusal)
    }

    @Test func anUnreadableFinderSelectionLeavesNavigationAndWindowKeysAlone() throws {
        for spec in leavingKeys {
            let key = try KeySpec.parse(spec)
            #expect(!OpenRoutes.needsSelectionRead(key), "\(spec)")
            #expect(OpenRoutes.finderKeyRefusal(key, selection: nil, policy: Policy()) == nil, "\(spec)")
        }
    }

    @Test func aProtectedFinderSelectionRefusesEveryKeyThatActsOnIt() throws {
        for spec in selectionKeys {
            let key = try KeySpec.parse(spec)
            #expect(OpenRoutes.finderKeyRefusal(key, selection: [documents, privateKey], policy: Policy())?.contains("protected") == true, "\(spec)")
        }
    }

    /// The only command keys that work with a protected item selected.
    private let safeWithProtectedSelection = ["cmd+n", "cmd+w", "cmd+t", "cmd+[", "cmd+]", "cmd+up", "cmd+f", "cmd+comma", "cmd+h",
                                              "cmd+1", "cmd+2",
                                              "cmd+shift+g", "cmd+shift+d", "cmd+shift+h", "cmd+shift+a", "cmd+shift+u", "cmd+shift+o",
                                              "cmd+shift+c", "cmd+shift+r", "cmd+shift+i", "cmd+shift+f", "cmd+shift+k"]

    @Test func aProtectedFinderSelectionLeavesOnlyTheListedNavigationAndWindowKeysAlone() throws {
        for spec in safeWithProtectedSelection {
            let key = try KeySpec.parse(spec)
            #expect(!OpenRoutes.needsSelectionRead(key), "\(spec)")
            #expect(OpenRoutes.finderKeyRefusal(key, selection: [privateKey], policy: Policy()) == nil, "\(spec)")
            #expect(OpenRoutes.finderKeyRefusal(key, selection: [documents, privateKey], policy: Policy()) == nil, "\(spec)")
        }
        // Keys that don't read the selection and aren't command chords never reach the check.
        for spec in ["tab", "down", "esc", "a"] {
            #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse(spec), selection: [privateKey], policy: Policy()) == nil, "\(spec)")
        }
    }

    /// ⌘3 and ⇧⌘P show the selected file (column view and Preview pane), ⌥⌘O opens it: all passed with a protected
    /// selection because the check refused only the keys on a list of commands that act on the selection.
    @Test func aProtectedFinderSelectionRefusesEveryOtherCommandKey() throws {
        let others = ["cmd+3", "cmd+4", "cmd+shift+p", "alt+cmd+o", "alt+cmd+p", "cmd+j", "cmd+k", "cmd+e",
                      "cmd+shift+l", "cmd+shift+n", "cmd+shift+period", "alt+cmd+l",
                      "cmd+a", "cmd+z", "cmd+5", "cmd+6", "ctrl+cmd+f", "alt+cmd+y", "alt+cmd+s", "cmd+shift+t", "cmd+shift+4"]
        for spec in others + selectionKeys {
            let key = try KeySpec.parse(spec)
            #expect(OpenRoutes.finderKeyRefusal(key, selection: [privateKey], policy: Policy())?.contains("protected") == true, "\(spec)")
            #expect(OpenRoutes.finderKeyRefusal(key, selection: [documents, privateKey], policy: Policy())?.contains("protected") == true, "\(spec)")
            // Without a protected item they are the same keys as before.
            #expect(OpenRoutes.protectedSelectionKeyRefusal(key, selection: [documents]) == nil, "\(spec)")
            #expect(OpenRoutes.protectedSelectionKeyRefusal(key, selection: nil) == nil, "\(spec)")
        }
    }

    @Test func optionCommandOOpensTheSelectionLikeCommandO() throws {
        #expect(OpenRoutes.opensSelection(try KeySpec.parse("alt+cmd+o")))
        #expect(OpenRoutes.opensSelection(try KeySpec.parse("cmd+o")))
        #expect(!OpenRoutes.opensSelection(try KeySpec.parse("shift+cmd+o")))   // Go to Documents
        #expect(!OpenRoutes.opensSelection(try KeySpec.parse("ctrl+cmd+o")))
        // An app bundle or denied handler selected in Finder is refused for ⌥⌘O as it is for ⌘O.
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let denied = Policy(denyApps: ["com.apple.Terminal"])
        #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse("cmd+o"), selection: [app], policy: denied) != nil)
        #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse("alt+cmd+o"), selection: [app], policy: denied) != nil)
    }

    @Test func aReadableSafeFinderSelectionKeepsFinderUsable() throws {
        for spec in selectionKeys.filter({ !["cmd+o", "alt+cmd+o", "cmd+down", "alt+cmd+down", "space", "alt+space"].contains($0) }) + leavingKeys {
            #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse(spec), selection: [documents], policy: Policy()) == nil, "\(spec)")
        }
        #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse("cmd+c"), selection: [], policy: Policy()) == nil)
    }

    @Test func copyingAFolderThatHoldsProtectedItemsIsRefusedButInspectingItIsNot() throws {
        for path in [Paths.home, Paths.home + "/.config", Paths.home + "/.docker", Paths.home + "/.terraform.d"] {
            let folder = URL(fileURLWithPath: path)
            for spec in ["cmd+c", "cmd+d", "cmd+x", "alt+cmd+v", "cmd+delete", "return", "delete"] {
                #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse(spec), selection: [folder], policy: Policy()) != nil, "\(path): \(spec)")
            }
            for spec in ["cmd+i", "cmd+y"] + leavingKeys {
                #expect(OpenRoutes.finderKeyRefusal(try KeySpec.parse(spec), selection: [folder], policy: Policy()) == nil, "\(path): \(spec)")
            }
            #expect(OpenRoutes.fileRefusal(folder, explicitApp: nil, policy: Policy()) == nil, "\(path)")
            #expect(OpenRoutes.typedPathRefusal(path) == nil, "\(path)")
        }
    }

    @Test func aSelectionItemWithoutAFileIsUnreadable() {
        let readable = URL(fileURLWithPath: "/tmp/a.txt")
        func read(_ rows: [String], places: Set<String> = []) -> OpenRoutes.SelectionRead {
            OpenRoutes.selectionRead(rows, url: { $0 == "file" ? readable : nil }, isPlace: places.contains)
        }
        #expect(read(["file", "file"]) == .urls([readable, readable]))
        #expect(read(["file", "missing"]) == .unreadable)
        #expect(read(["missing"]) == .unreadable)
        #expect(read(["file", "missing"], places: ["missing"]) == .places)
        #expect(read(["sidebar"], places: ["sidebar"]) == .places)
        #expect(read(["sidebar", "missing"], places: ["sidebar"]) == .unreadable)
    }

    @Test func finderMenuItemsAreCheckedByTheirPositionFromTheEndOfTheBar() {
        // Apple, Finder, File, Edit, View, Go, Window, Help; the Apple item may or may not be a child of the bar.
        for count in [7, 8] {
            let acting = (0..<count).filter { OpenRoutes.finderMenuActsOnSelection(index: $0, count: count) }
            #expect(acting == [count - 7, count - 6, count - 5], "\(count)")
        }
        #expect(OpenRoutes.finderMenuActsOnSelection(index: 3, count: 8))   // Edit: Copy, Cut, Paste Item
        #expect(!OpenRoutes.finderMenuActsOnSelection(index: 5, count: 8))   // Go
        #expect(OpenRoutes.finderMenuActsOnSelection(index: 0, count: 3))    // an unfamiliar bar is checked throughout
    }

    @Test func aMenuItemDependsOnTheSelectionUnlessItsKeyEquivalentSaysOtherwise() {
        func needs(_ character: String?, _ modifiers: Int?, _ virtualKey: Int? = nil) -> Bool {
            OpenRoutes.menuNeedsSelectionRead(character: character, modifiers: modifiers, virtualKey: virtualKey)
        }
        #expect(needs("C", 0) && needs("X", 0) && needs("V", 0) && needs("D", 0) && needs("I", 0) && needs("Y", 0))
        #expect(needs("L", 0) && needs("O", 0) && needs("C", 2))               // alias, open, copy path
        #expect(needs("", 0, 51) && needs("", 0, 125) && needs("N", 4))        // trash, open, new folder with selection
        #expect(needs(nil, nil) && needs("", 0) && needs("", 8))               // Compress, Rename: no usable key equivalent
        #expect(!needs("N", 0) && !needs("W", 0) && !needs("A", 0) && !needs("Z", 0) && !needs("N", 1))
        #expect(!needs("C", 1) && !needs("D", 1))                              // Go ▸ Computer, Desktop
    }

    /// View ▸ as Columns, as Gallery and Show Preview show the selected file as ⌘3, ⌘4 and ⇧⌘P do; through mac_menu
    /// they went unchecked because the View menu was taken to leave the selection alone.
    @Test func finderViewMenuCommandsAreHeldToTheRulesOfTheirKeys() throws {
        #expect(OpenRoutes.finderMenuShowsSelection(index: 4, count: 8))    // View, with the Apple menu
        #expect(OpenRoutes.finderMenuShowsSelection(index: 3, count: 7))    // and without
        #expect(!OpenRoutes.finderMenuShowsSelection(index: 5, count: 8))   // Go
        #expect(!OpenRoutes.finderMenuShowsSelection(index: 3, count: 8))   // Edit is checked as acting on the selection
        // Known by their key equivalents, as AX reports them (shift from the modifier bits).
        #expect(OpenRoutes.menuKey(character: "3", modifiers: 0, virtualKey: nil).map(OpenRoutes.previewsSelection) == true)
        #expect(OpenRoutes.menuKey(character: "4", modifiers: 0, virtualKey: nil).map(OpenRoutes.previewsSelection) == true)
        #expect(OpenRoutes.menuKey(character: "P", modifiers: 1, virtualKey: nil).map(OpenRoutes.previewsSelection) == true)
        #expect(OpenRoutes.menuKey(character: "P", modifiers: 2, virtualKey: nil).map(OpenRoutes.previewsSelection) == false)
        for spec in ["cmd+3", "cmd+4", "cmd+shift+p", "cmd+y", "space"] {
            let key = try KeySpec.parse(spec)
            #expect(OpenRoutes.previewsSelection(key), "\(spec)")
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: [documents, privateKey])?.contains("protected") == true, "\(spec)")
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: nil) == OpenRoutes.unreadableSelectionRefusal, "\(spec)")
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: [documents]) == nil, "\(spec)")
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: []) == nil, "\(spec)")
        }
        // as Icons and as List leave a protected selection alone.
        for spec in ["cmd+1", "cmd+2"] {
            #expect(OpenRoutes.finderViewMenuRefusal(key: try KeySpec.parse(spec), shown: [privateKey]) == nil, "\(spec)")
        }
        // Other items (Show Path Bar, items without a key equivalent) are refused only with a protected item selected.
        for key in [try KeySpec.parse("alt+cmd+p"), try KeySpec.parse("cmd+j"), nil] {
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: [privateKey])?.contains("protected") == true)
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: nil) == nil)
            #expect(OpenRoutes.finderViewMenuRefusal(key: key, shown: [documents]) == nil)
        }
        #expect(!OpenRoutes.previewsSelection(try KeySpec.parse("cmd+1")))
        #expect(!OpenRoutes.previewsSelection(try KeySpec.parse("cmd+shift+4")))
    }

    @Test func aFinderMenuCommandNeedsAReadableSelectionOnlyWhenItDependsOnIt() {
        #expect(OpenRoutes.menuSelectionRefusal(nil, dependsOnSelection: true) == OpenRoutes.unreadableSelectionRefusal)
        #expect(OpenRoutes.menuSelectionRefusal(nil, dependsOnSelection: false) == nil)
        #expect(OpenRoutes.menuSelectionRefusal([privateKey], dependsOnSelection: false)?.contains("protected") == true)
        #expect(OpenRoutes.menuSelectionRefusal([privateKey], dependsOnSelection: true)?.contains("protected") == true)
        #expect(OpenRoutes.menuSelectionRefusal([documents], dependsOnSelection: true) == nil)
    }
}
