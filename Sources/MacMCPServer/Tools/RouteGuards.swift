import AppKit
import Foundation
import MacMCPCore
import Synchronization

/// State-independent refusals can run before queuing. All stateful decisions run again at the actual input step,
/// under the action lock, after focus, activation and coordinate conversion. AX reads stay off the cooperative pool.
enum RouteGuards {
    static func keys(_ specs: [KeySpec], app: String?, repeat count: Int) async -> ToolOutput? {
        if let r = OpenRoutes.appSwitchRefusal(specs, repeat: count) ?? OpenRoutes.keySequenceRefusal(specs, repeat: count) {
            return .error(r, audit: "Refused: key sequence")
        }
        return nil
    }

    static func menu(_ path: [String], app: String?) async -> ToolOutput? {
        OpenRoutes.menuRefusal(path: path).map { .error($0, audit: "Refused: menu route") }
    }

    static func check(_ step: ActionRoute.Step) async throws {
        let info = await MainActor.run { ClipboardSafety.current() }
        let sequence = ActionRoute.keySequence
        let refusal = try await Input.guardWork(pool: .route, timeout: Input.routeTimeout) {
            let policy: Policy
            switch Policy.current() {
            case let .success(p): policy = p
            case let .failure(e): return e.description as String?
            }
            return refusal(step, policy: policy, clipboard: info, sequence: sequence)
        }
        if let refusal { throw ActionError(refusal, audit: "Refused: input route") }
    }

    static func refusal(_ step: ActionRoute.Step, policy: Policy, clipboard: ClipboardInfo,
                        sequence: ActionRoute.KeySequence? = nil) -> String? {
        switch step {
        case let .key(key, pid):
            if let r = OpenRoutes.launcherKeyRefusal([key], policy: policy, appDefines: { key in
                pid.map { OpenRoutes.menuDefines(key, pid: $0) } ?? false
            }) { return r }
            guard let pid else { return nil }
            if let sequence, let r = sequenceRefusal(sequence, selectionContext: { selectionContext(pid) }, editsText: { editsMultilineText(pid) }) { return r }
            if OpenRoutes.activatesMenuItem(key) {
                let menu = OpenRoutes.activeMenuItem(pid: pid)
                if menu.open {
                    guard let item = menu.item else {
                        return "Refused: the highlighted menu command can't be checked. Close the menu and use mac_menu."
                    }
                    return menuItemRefusal(item, pid: pid, policy: policy, clipboard: clipboard)
                }
            }
            if OpenRoutes.isPaste(key), let r = pasteRefusal(policy, pid: pid, clipboard: clipboard) { return r }
            if OpenRoutes.commitsField(key), let r = commitRefusal(pid: pid, target: nil, policy: policy) { return r }
            // Keys in a field (a name being edited, the search field) edit its text; Return commits it, checked above.
            if isFinder(pid), !editsText(pid), OpenRoutes.actsOnSelection(key) || OpenRoutes.needsSelectionRead(key) {
                let selection = OpenRoutes.finderSelection(pid: pid)
                OpenRoutes.noteFinderSelection(selection, pid: pid)
                if let r = OpenRoutes.finderKeyRefusal(key, selection: selection, policy: policy) { return r }
                if OpenRoutes.previewsSelection(key), let r = OpenRoutes.previewRefusal(OpenRoutes.finderView(pid: pid)?.selection) { return r }
                if OpenRoutes.inspectsSelection(key), let r = emptySelectionRefusal(selection, pid: pid) { return r }
                if OpenRoutes.copiesSelection(key), let selection, !selection.isEmpty {
                    ClipboardSafety.noteFinderCopy(selection, changeCount: clipboard.changeCount)
                }
            }
        case let .text(text, pid):
            guard let pid else { return OpenRoutes.typedPathRefusal(text) }
            return editRefusal(text, pid: pid, mode: .insert)
        case let .typing(text, mode, pid):
            if let r = typedKeysRefusal(text, replacing: mode == .replace, pid: pid) { return r }
            return editRefusal(text, pid: pid, mode: mode)
        case let .target(element, point, pid, opens):
            let hit = element ?? point.flatMap { AXElement.systemWide.element(at: $0) }
            guard let hit else {
                return "Refused: the input target can't be checked. Take mac_snapshot and use a ref."
            }
            let hitPID = point.flatMap { WindowServer.owner(at: $0) } ?? hit.pid
            let remote = NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier == OpenRoutes.panelService
            let owner = remote ? pid ?? hitPID : hitPID
            if WindowServer.isSystemPrompt(pid: owner) { return "Refused: a person must answer this macOS prompt." }
            if let running = NSRunningApplication(processIdentifier: owner),
               let r = policy.refusal(bundleID: running.bundleIdentifier, name: running.localizedName) { return r }
            if let r = SessionSafety.refusal(element: hit) ?? OpenRoutes.elementRefusal(hit, pid: owner, policy: policy) { return r }
            if isFinder(owner) { noteFinderHit(hit, pid: owner) }
            let command = OpenRoutes.commandTarget(of: hit)
            if [kAXMenuItemRole, kAXMenuBarItemRole].contains(command.role ?? "") {
                return menuItemRefusal(command, pid: owner, policy: policy, clipboard: clipboard)
            }
            if opens, let r = openingRefusal(hit, pid: owner, policy: policy) { return r }
            if command.role == kAXButtonRole {
                // A button of a window that lists files (its toolbar, the sidebar) acts on that window's selection; one
                // of a window that lists none (the Copy window's Replace, a confirmation) answers what was checked.
                if isFinder(owner), let view = OpenRoutes.finderView(around: command),
                   let r = OpenRoutes.mutationSelectionRefusal(view.selection) { return r }
                return commitRefusal(pid: owner, target: command, policy: policy)
            }
        case let .drag(from, to, pid, modifiers):
            guard let source = AXElement.systemWide.element(at: from), let dest = AXElement.systemWide.element(at: to) else {
                return "Refused: the drag targets can't be checked. Take mac_snapshot and retry."
            }
            let sourceOwner = NSRunningApplication(processIdentifier: WindowServer.owner(at: from) ?? source.pid)?.bundleIdentifier
            if let r = dragModifierRefusal(modifiers, sourceOwner: sourceOwner) { return r }
            for step in dragTargets(source: source, destination: dest, from: from, to: to, pid: pid) {
                if let r = refusal(step, policy: policy, clipboard: clipboard) { return r }
            }
            return dragFilesRefusal(source: source, destination: dest, from: from, to: to)
        }
        return nil
    }

    /// What a drag carries and where it lands, read at the check before its button goes down. Once a drag is under
    /// way Finder answers hit tests on its lists with the scroll area around them, so neither the dragged items nor
    /// the folder under the drop can be read again, and what the drag carries can't change by then. The later checks
    /// of that drag, and its cleanup's drop back at the source, use this and add what they can still read.
    struct DragPlan {
        var from, to: CGPoint
        var pid: pid_t
        var files: [URL]
        var sourceFolders: [URL]?
        var destinationFolders: [URL]?
        var time: TimeInterval
    }

    static let dragPlan = Mutex<DragPlan?>(nil)

    /// The files a drag carries (Finder drags its window's selection when the item grabbed is part of it), checked
    /// as a copy or move into where the drop lands.
    static func dragFilesRefusal(source: AXElement, destination dest: AXElement, from: CGPoint, to: CGPoint) -> String? {
        let pressed = CGEventSource.buttonState(.hidSystemState, button: .left)
        let now = ProcessInfo.processInfo.systemUptime
        let plan = pressed ? dragPlan.withLock { $0 }.flatMap { $0.from == from && $0.pid == source.pid && now - $0.time < 120 ? $0 : nil } : nil
        if !pressed { dragPlan.withLock { $0 = nil } }
        let files: [URL]
        if let plan {
            files = plan.files
        } else if isFinder(source.pid) {
            guard let dragged = OpenRoutes.draggedFiles(source) else {
                return "Refused: the dragged files can't be checked. Take mac_snapshot and drag a file's name or icon."
            }
            files = dragged
        } else if let sourceURL = OpenRoutes.url(of: source), sourceURL.isFileURL {
            files = [sourceURL]
        } else {
            return nil
        }
        if let r = OpenRoutes.transferRefusal(files, into: []) { return r }
        let destOwner = NSRunningApplication(processIdentifier: WindowServer.owner(at: to) ?? dest.pid)?.bundleIdentifier
        var folders: [URL]?
        if destOwner == OpenRoutes.finder {
            let planned = plan.flatMap { to == $0.from ? $0.sourceFolders : to == $0.to ? $0.destinationFolders : nil }
            let read = OpenRoutes.dropFolders(dest)
            if planned != nil || read != nil { folders = (planned ?? []) + (read ?? []) }
            guard let folders else {
                return "Refused: where this drop lands can't be checked. Drop onto a folder's name or icon, or into a window that lists files."
            }
            if let r = OpenRoutes.transferRefusal(files, into: folders) { return r }
        } else if checksDropFolder(owner: destOwner, panel: OpenRoutes.namingPanel(of: dest) != nil) {
            for file in files {
                if let r = OpenRoutes.moveRefusal(source: file, destinationFolder: OpenRoutes.destinationFolder(of: dest)) { return r }
            }
        }
        if !pressed {
            let sourceFolders = isFinder(source.pid) ? OpenRoutes.dropFolders(source) : nil
            dragPlan.withLock {
                $0 = DragPlan(from: from, to: to, pid: source.pid, files: files, sourceFolders: sourceFolders,
                              destinationFolders: folders, time: now)
            }
        }
        return nil
    }

    /// ⇧ or ⌘ held as the button goes down on a Finder item adds it, or the items up to it, to the selection (or takes
    /// it out), and the drag carries what is selected then: not what was checked before the button went down.
    static func dragModifierRefusal(_ modifiers: CGEventFlags, sourceOwner: String?) -> String? {
        guard [OpenRoutes.finder, OpenRoutes.panelService].contains(sourceOwner ?? ""),
              !modifiers.intersection([.maskShift, .maskCommand]).isEmpty else { return nil }
        return "Refused: shift or cmd held on a drag from Finder or a file panel changes which files it carries after "
            + "they are checked. Select the files first (mac_click, with modifiers there), then drag without shift or cmd; "
            + "to move rather than copy, use mac_key cmd+c, then alt+cmd+v."
    }

    /// The item a click in Finder lands on, for a rename it may start (`OpenRoutes.renameRefusal`). A click in a text
    /// field (the name being edited, the search field) starts none and leaves the noted item alone.
    static func noteFinderHit(_ hit: AXElement, pid: pid_t) {
        if OpenRoutes.textRoles.contains(hit.role ?? "") { return }
        if case let .item(url) = OpenRoutes.finderHit(hit) {
            OpenRoutes.noteFinderSelection([url], pid: pid)
        } else {
            OpenRoutes.noteFinderSelection(nil, pid: pid)
        }
    }

    static func dragTargets(source: AXElement, destination: AXElement, from: CGPoint, to: CGPoint, pid: pid_t?) -> [ActionRoute.Step] {
        [.target(source, point: from, pid: pid, opens: false), .target(destination, point: to, pid: pid, opens: false)]
    }

    static func checksDropFolder(owner: String?, panel: Bool) -> Bool {
        owner == OpenRoutes.finder || owner == OpenRoutes.panelService || panel
    }

    static func focusedField(_ pid: pid_t) -> AXElement? {
        AXElement.application(pid: pid).element(kAXFocusedUIElementAttribute)
    }

    /// Finder (its Open With chooser included), a file panel, or an open menu: where keys act on a selection.
    static func selectionContext(_ pid: pid_t) -> Bool {
        if isFinder(pid) || OpenRoutes.menuIsOpen(pid: pid, windows: WindowServer.onScreenWindows()) { return true }
        if let focus = focusedField(pid),
           NSRunningApplication(processIdentifier: focus.pid)?.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService" { return true }
        return OpenRoutes.activeNamingPanel(pid: pid).map { OpenRoutes.isFilePanel($0) } ?? false
    }

    /// The rules for a key that belongs to a call's sequence of keys: mac_key's, or mac_type's text.
    static func sequenceRefusal(_ sequence: ActionRoute.KeySequence, selectionContext: () -> Bool, editsText: () -> Bool) -> String? {
        if let r = OpenRoutes.selectionSequenceRefusal(sequence, selectionContext: selectionContext) { return r }
        return sequence.typed ? OpenRoutes.typedReturnRefusal(sequence.keys, at: sequence.index, editsText: editsText) : nil
    }

    /// The newlines and tabs of mac_type text are Return and Tab keys: apply the mac_key sequence rules to them and the
    /// text before them, before the first character goes in. Each is checked again as it is sent.
    static func typedKeysRefusal(_ text: String, replacing: Bool, pid: pid_t) -> String? {
        typedKeysRefusal(text, replacing: replacing, selectionContext: { selectionContext(pid) }, editsText: { editsMultilineText(pid) })
    }

    static func typedKeysRefusal(_ text: String, replacing: Bool, selectionContext: () -> Bool, editsText: () -> Bool) -> String? {
        guard let keys = OpenRoutes.typedKeys(text, replacing: replacing) else { return nil }
        if let r = OpenRoutes.selectionSequenceRefusal(ActionRoute.KeySequence(keys: keys, index: 0, typed: true),
                                                       selectionContext: selectionContext) { return r }
        for index in keys.indices {
            if let r = OpenRoutes.typedReturnRefusal(keys, at: index, editsText: editsText) { return r }
        }
        return nil
    }

    /// The focused element is a multi-line text area, where Return breaks the line and nothing else.
    static func editsMultilineText(_ pid: pid_t) -> Bool {
        focusedField(pid)?.role == kAXTextAreaRole
    }

    static func isFinder(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == OpenRoutes.finder
    }

    /// Whether the app's keyboard focus is in a text field, where keys and paste edit text rather than act on files.
    static func editsText(_ pid: pid_t) -> Bool { OpenRoutes.textRoles.contains(focusedField(pid)?.role ?? "") }

    static func editRefusal(_ text: String, pid: pid_t, mode: Actions.TypeMode) -> String? {
        guard let field = focusedField(pid) else { return OpenRoutes.typedPathRefusal(text) }
        if field.subrole == "AXSecureTextField" { return OpenRoutes.typedPathRefusal(text) }
        let rename = finderRename(field, pid: pid)
        if let r = rename?.refusal { return r }
        let values = field.read([kAXValueAttribute, kAXSelectedTextRangeAttribute]) ?? [:]
        return OpenRoutes.fieldEditRefusal(text, current: values[kAXValueAttribute] as? String,
                                          selection: values[kAXSelectedTextRangeAttribute] as? CFRange, mode: mode,
                                          naming: OpenRoutes.isNamingField(field, pid: pid)) {
            OpenRoutes.typingRefusal($0, into: field, pid: pid, folders: rename?.folders ?? [])
        }
    }

    /// Finder can enter inline renaming through a second single click, without a Return key. Check the original
    /// item as well as its new name, so a containing directory cannot be renamed out from under the install.
    static func finderRename(_ field: AXElement, pid: pid_t) -> (refusal: String?, folders: [String])? {
        guard isFinder(pid), OpenRoutes.isNamingField(field, pid: pid), OpenRoutes.namingPanel(of: field) == nil else { return nil }
        return OpenRoutes.finderRenameCheck(field, pid: pid)
    }

    /// With nothing selected, Finder shows the info of the window's folder.
    static func emptySelectionRefusal(_ selection: [URL]?, pid: pid_t) -> String? {
        guard selection?.isEmpty == true else { return nil }
        let folders = OpenRoutes.finderView(pid: pid)?.folders ?? []
        if folders.isEmpty { return OpenRoutes.unreadableSelectionRefusal }
        return OpenRoutes.protectedSelectionRefusal(folders)
    }

    /// A double-click on a Finder item opens it, wherever on the item it lands (a list view row's date column carries
    /// no URL); one on an item whose file can't be read is refused.
    static func openingRefusal(_ hit: AXElement, pid: pid_t, policy: Policy) -> String? {
        guard isFinder(pid) else { return OpenRoutes.openingRefusal(hit, pid: pid, policy: policy) }
        switch OpenRoutes.finderHit(hit) {
        case let .item(url): return OpenRoutes.openingRefusal(url: url, policy: policy)
        case .unreadable: return "Refused: the item under the double-click can't be checked. Take mac_snapshot and double-click its name or icon."
        case .background: return nil
        }
    }

    /// Pasting in Finder's file list (not a field) copies the clipboard's files into the window's folder, or moves
    /// them (⌥⌘V); anything else becomes a new clipping file there. So it is checked as a copy: the files, and each
    /// name in each folder the paste could land in (in column view, the focused column's; see `FinderView`).
    static func finderPasteRefusal(pid: pid_t, clipboard: ClipboardInfo) -> String? {
        guard let view = OpenRoutes.finderView(pid: pid), view.selection != nil else { return OpenRoutes.unreadableSelectionRefusal }
        let folders = view.pasteFolders
        if folders.isEmpty { return OpenRoutes.unknownFolderRefusal }
        if let files = ClipboardSafety.pastedFiles(clipboard) { return OpenRoutes.transferRefusal(files, into: folders) }
        if ClipboardSafety.holdsFiles(clipboard) {
            return "Refused: the files on the clipboard can't be checked. Select them in Finder and copy them with mac_key "
                + "cmd+c, then paste. A file copied that way and since deleted can't be pasted."
        }
        return folders.lazy.compactMap { ProtectedPaths.refusal($0.appendingPathComponent("Pasted").path) }.first
    }

    static func pasteRefusal(_ policy: Policy, pid: pid_t, clipboard: ClipboardInfo) -> String? {
        if let r = ClipboardSafety.pasteRefusal(clipboard, policy: policy, ownChangeCount: ClipboardSafety.ownChangeCount) { return r }
        if isFinder(pid), !editsText(pid) { return finderPasteRefusal(pid: pid, clipboard: clipboard) }
        guard let field = focusedField(pid) else { return nil }
        let inPanel = OpenRoutes.activeNamingPanel(pid: pid) != nil
        guard OpenRoutes.isNamingField(field, pid: pid) || inPanel || isFinder(pid) else {
            // Any other field takes any text, but a path to a protected location is refused wherever it goes.
            return ClipboardSafety.ownText(changeCount: clipboard.changeCount).flatMap(OpenRoutes.typedPathRefusal)
        }
        guard let text = ClipboardSafety.ownText(changeCount: clipboard.changeCount) else {
            return "Refused: paste into a file panel or Finder needs text set with mac_clipboard action=set. Use mac_type instead."
        }
        if inPanel, !OpenRoutes.isNamingField(field, pid: pid) {
            return "Refused: the panel's insertion point can't be checked while a menu is open. Close it and use mac_type."
        }
        return editRefusal(text, pid: pid, mode: .insert)
    }

    static func menuItemRefusal(_ item: AXElement, pid: pid_t, policy: Policy, clipboard: ClipboardInfo) -> String? {
        if let r = OpenRoutes.menuRefusal(element: item) { return r }
        let command = OpenRoutes.menuCommand(item)
        if command == .paste || OpenRoutes.isPasteItem(item), let r = pasteRefusal(policy, pid: pid, clipboard: clipboard) { return r }
        let submenu = !item.elements(kAXChildrenAttribute).isEmpty
        if !submenu, command != .paste, command != .open,
           let r = ClipboardSafety.pasteRefusal(clipboard, policy: policy, ownChangeCount: ClipboardSafety.ownChangeCount) { return r }
        if !submenu, let r = commitRefusal(pid: pid, target: item, policy: policy) { return r }
        guard isFinder(pid), item.role == kAXMenuItemRole, !submenu else { return nil }
        let key = OpenRoutes.menuKey(item)
        // A command that shows the selection (as Columns, Show Preview, Quick Look) wherever it is: the window's.
        if key.map(OpenRoutes.previewsSelection) == true,
           let r = OpenRoutes.previewRefusal(OpenRoutes.finderView(pid: pid)?.selection) { return r }
        if let position = OpenRoutes.menuBarPosition(of: item),
           !OpenRoutes.finderMenuActsOnSelection(index: position.index, count: position.count) {
            guard OpenRoutes.finderMenuShowsSelection(index: position.index, count: position.count) else { return nil }
            return OpenRoutes.finderViewMenuRefusal(key: key, shown: OpenRoutes.finderView(pid: pid)?.selection)
        }
        let selection = OpenRoutes.finderSelection(pid: pid)
        OpenRoutes.noteFinderSelection(selection, pid: pid)
        if OpenRoutes.menuCopiesSelection(item), let selection, !selection.isEmpty {
            ClipboardSafety.noteFinderCopy(selection, changeCount: clipboard.changeCount)
        }
        if OpenRoutes.isExplicitHandlerItem(item) {
            let url = OpenRoutes.url(of: item, levels: 0)
            let name = OpenRoutes.handlerName(item.string(kAXTitleAttribute) ?? "")
            let app = url.flatMap { $0.isFileURL && $0.pathExtension.lowercased() == "app" ? $0 : nil }
                ?? name.flatMap { Apps.bundleURL(for: $0) }
            return OpenRoutes.explicitHandlerRefusal(app: app, selection: selection, policy: policy)
        }
        if command == .open { return OpenRoutes.selectionRefusal(selection, explicitApp: nil, policy: policy) }
        // An item whose key equivalent leaves the selection alone (New Folder, New Finder Window) doesn't read it.
        let depends = OpenRoutes.menuNeedsSelectionRead(item)
        if let r = OpenRoutes.menuSelectionRefusal(selection, dependsOnSelection: depends) { return r }
        if depends, OpenRoutes.menuInspectsSelection(item), let r = emptySelectionRefusal(selection, pid: pid) { return r }
        if depends, command == .unknown || command == .other {
            if let r = OpenRoutes.selectionRefusal(selection, explicitApp: nil, policy: policy) { return r }
            // A command in a File submenu might be an unidentifiable explicit handler. Never substitute the default.
            if OpenRoutes.inFileOrContextMenu(item),
               item.element(kAXParentAttribute)?.element(kAXParentAttribute)?.role == kAXMenuItemRole {
                return OpenRoutes.unresolvedHandlerRefusal
            }
        }
        return nil
    }

    /// Return, Tab and panel buttons read actual values, including when the field lost focus to the default button.
    /// Selected app rows are checked too: the Open With application chooser must not launch a denied app.
    static func commitRefusal(pid: pid_t, target: AXElement?, policy: Policy) -> String? {
        let field = focusedField(pid)
        if let button = target ?? field, let panel = OpenRoutes.namingPanel(of: button),
           panel.element(kAXCancelButtonAttribute) == button { return nil }
        if let field, OpenRoutes.isNamingField(field, pid: pid) {
            let rename = finderRename(field, pid: pid)
            if let r = rename?.refusal { return r }
            guard let value = field.string(kAXValueAttribute) else {
                return "Refused: the file name can't be read. Take mac_snapshot and retry."
            }
            if let r = OpenRoutes.typingRefusal(value, into: field, pid: pid, folders: rename?.folders ?? []) { return r }
        }
        if let element = target ?? field, let r = panelRefusal(element, pid: pid, policy: policy) { return r }
        return OpenRoutes.activeNamingPanel(pid: pid).flatMap { panelRefusal($0, pid: pid, policy: policy) }
    }
}

/// Refuses to manage a window or app that is a macOS security or permission prompt (closing, hiding or quitting one
/// answers it as surely as clicking its button).
func promptGuard(_ app: AppInfo) async -> ToolOutput? {
    guard WindowServer.isSystemPrompt(pid: app.pid) else { return nil }
    await Alerts.shared.notify(.prompt, "An agent tried to manage a macOS security/permission prompt; it needs a person.")
    return .error("Refused: \(Untrusted.inline(app.name)) is a macOS security or permission prompt. A person must answer it (via Remote "
        + "Access); MacMCP never moves, closes, hides or quits these.")
}
