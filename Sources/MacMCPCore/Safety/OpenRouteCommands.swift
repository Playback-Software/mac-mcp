import AppKit
import ApplicationServices
import Foundation

extension OpenRoutes {
    public enum MenuCommand: Sendable, Equatable { case paste, open, other, unknown }

    /// AX menu modifier bits are shift=1, option=2, control=4, no-command=8 (command is implicit).
    /// Titles are deliberately absent: these commands must work with localized menus.
    public static func menuCommand(character: String?, modifiers: Int?, virtualKey: Int? = nil) -> MenuCommand {
        guard let modifiers else { return .unknown }
        let command = modifiers & 8 == 0
        let character = character?.lowercased() ?? ""
        if command, character == "v" || virtualKey == 9 { return .paste }
        if command, (character == "o" && modifiers == 0)
            || (["↓", "\u{F701}"].contains(character) || virtualKey == 125) && modifiers & ~2 == 0 { return .open }
        return character.isEmpty && virtualKey == nil ? .unknown : .other
    }

    public static func menuCommand(_ item: AXElement) -> MenuCommand {
        let values = item.read([kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute]) ?? [:]
        return menuCommand(character: values[kAXMenuItemCmdCharAttribute] as? String,
                           modifiers: (values[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue,
                           virtualKey: (values[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber)?.intValue)
    }

    /// The keys of a menu item's key equivalent. Shift comes only from the modifier bits: AX reports letters in
    /// capitals whether or not shift is part of the equivalent.
    static func menuKey(character: String?, modifiers: Int?, virtualKey: Int?) -> KeySpec? {
        guard let modifiers else { return nil }
        var flags: CGEventFlags = modifiers & 8 == 0 ? .maskCommand : []
        for (bit, flag) in [(1, CGEventFlags.maskShift), (2, .maskAlternate), (4, .maskControl)] where modifiers & bit != 0 { flags.insert(flag) }
        if let character, character.count == 1, let code = KeySpec.keyCodes[character.lowercased()] { return KeySpec(key: code, flags: flags) }
        guard (character ?? "").isEmpty, let virtualKey, virtualKey > 0 else { return nil }
        return KeySpec(key: CGKeyCode(virtualKey), flags: flags)
    }

    /// Whether the app's own menus, other than the application menu (which holds Services), give these keys an enabled
    /// command. AppKit runs the app's command then, and a Service with the same keys never sees them. A menu that
    /// can't be read in time defines nothing.
    public static func menuDefines(_ key: KeySpec, pid: pid_t, limit: Int = 1500, budget: TimeInterval = 0.5) -> Bool {
        let app = AXElement.application(pid: pid, timeout: 0.25)
        guard let bar = app.element(kAXMenuBarAttribute) else { return false }
        let names = [kAXRoleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
                     kAXMenuItemCmdVirtualKeyAttribute, kAXChildrenAttribute]
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var queue = Array(bar.elements(kAXChildrenAttribute).dropFirst()), visited = 0
        while !queue.isEmpty, visited < limit, ProcessInfo.processInfo.systemUptime < deadline {
            let e = queue.removeFirst()
            visited += 1
            guard let v = e.read(names) else { continue }
            if v[kAXRoleAttribute] as? String == kAXMenuItemRole, v[kAXEnabledAttribute] as? Bool == true,
               let spec = menuKey(character: v[kAXMenuItemCmdCharAttribute] as? String,
                                  modifiers: (v[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue,
                                  virtualKey: (v[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber)?.intValue),
               ServiceHotkeys.matches(spec, key) { return true }
            queue += (v[kAXChildrenAttribute] as? [Any] ?? []).compactMap(AXElement.from)
        }
        return false
    }

    public static func activatesMenuItem(_ key: KeySpec) -> Bool { [36, 76, 49].contains(key.key) }

    /// No AX read can prove a previously queued key was processed, so a key's check can't see a panel or menu that an
    /// earlier key of the same call opened. Wherever the target is, a commit (Return, Space, ⌘S, ⌘O, paste) can't
    /// follow a key that may open one (Return, Space, a command chord other than editing, a function key). Space may
    /// follow Space: paging. What the target shows already is checked at each key (`selectionSequenceRefusal`).
    public static func keySequenceRefusal(_ keys: [KeySpec], repeat count: Int) -> String? {
        guard count > 0 else { return nil }
        var opened = false, spaced = false
        // A second round shows everything a repeat adds.
        for key in Array(repeating: keys, count: min(count, 2)).flatMap({ $0 }) {
            let space = key.key == 49 && key.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            if commitsAfterOpening(key), opened || (spaced && !space) {
                return "Refused: a committing key after a key that can open a panel or menu could act on one MacMCP hasn't checked yet. Send it in a separate mac_key call after mac_snapshot, or use mac_menu."
            }
            if space { spaced = true } else if mayOpenPanelOrMenu(key) { opened = true }
        }
        return nil
    }

    /// The keys mac_type sends for `text`, for the sequence rules: Return for a newline, Tab for a tab, Space for a
    /// space and one ordinary key for each other character (it type-selects in a list), after ⌘A when it replaces.
    /// nil when the text holds no newline or tab: plain text is checked as text, never as keys.
    public static func typedKeys(_ text: String, replacing: Bool) -> [KeySpec]? {
        let typed = text.map { ch -> KeySpec in
            switch ch {
            case "\n", "\r", "\r\n": KeySpec(key: 36, flags: [])
            case "\t": KeySpec(key: 48, flags: [])
            case " ": KeySpec(key: 49, flags: [])
            default: KeySpec(key: 0, flags: [])
            }
        }
        guard typed.contains(where: { [36, 48].contains($0.key) }) else { return nil }
        return (replacing ? [KeySpec(key: 0, flags: .maskCommand)] : []) + typed
    }

    /// A newline typed after another can't be told from `return, return`: the first may have pressed a default button
    /// that opened a panel, which the second would commit before accessibility shows it. In a text area both just break
    /// the line (`editsText`), so multiline text still goes in.
    public static func typedReturnRefusal(_ keys: [KeySpec], at index: Int, editsText: () -> Bool) -> String? {
        guard keys.indices.contains(index), keys[index].key == 36, keys[..<index].contains(where: { $0.key == 36 }),
              !editsText() else { return nil }
        return "Refused: a second newline outside a multi-line text area could press a button that opened a panel MacMCP "
            + "hasn't checked yet. Type the lines in separate mac_type calls, or use mac_key after mac_snapshot."
    }

    static let functionKeys: Set<CGKeyCode> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Return and Space press buttons; command chords (other than editing ones) run menu commands; ⌃F2 and the like
    /// move into the menu bar.
    static func mayOpenPanelOrMenu(_ key: KeySpec) -> Bool {
        let editing: Set<CGKeyCode> = [0, 6, 7, 8, 9, 11, 32, 34, 51, 117, 123, 124, 125, 126]   // a z x c v b u i, deletes, arrows
        if [36, 76, 49].contains(key.key) || functionKeys.contains(key.key) { return true }
        if key.flags.contains(.maskCommand) { return !editing.contains(key.key) }
        if key.flags.contains(.maskControl) { return [38, 46].contains(key.key) || !isTypeSelect(KeySpec(key: key.key, flags: [])) }
        return false
    }

    static func commitsAfterOpening(_ key: KeySpec) -> Bool {
        (commitsField(key) && key.key != 48 && !(key.key == 34 && key.flags.contains(.maskControl))) || opensSelection(key) || isPaste(key)
    }

    /// A key that types a character: in a list, it selects the item whose name starts with it.
    static func isTypeSelect(_ key: KeySpec) -> Bool {
        key.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty && typeSelectKeys.contains(key.key)
    }
    static let typeSelectKeys = Set(KeySpec.keyCodes.filter { $0.key.count == 1 }.values)

    /// Keys that act on what Finder, a file panel, the Open With chooser or a menu has selected, or (type-select after
    /// navigation) change it.
    static func actsOnSelection(in keys: [KeySpec], at index: Int) -> Bool {
        let key = keys[index]
        if commitsField(key) || opensSelection(key) || key.flags.contains(.maskCommand) || [51, 117].contains(key.key) { return true }
        return isTypeSelect(key) && keys[..<index].contains { !isTypeSelect($0) }
    }

    /// While the target is Finder, a file panel, the Open With chooser or an open menu, a key that acts on the
    /// selection must be the first of its call: it is checked against the selection just before it is sent, and an
    /// earlier key (sent 50 ms before, maybe not yet handled) would leave that check reading the old one. Asked at
    /// each key, about it and the keys after it, so a sequence is refused before its first key when it can be.
    public static func selectionSequenceRefusal(_ sequence: ActionRoute.KeySequence, selectionContext: () -> Bool) -> String? {
        let keys = sequence.keys
        guard sequence.index < keys.count,
              keys.indices.dropFirst(max(sequence.index, 1)).contains(where: { actsOnSelection(in: keys, at: $0) }),
              selectionContext() else { return nil }
        return "Refused: in Finder, a file panel or an open menu, a key that acts on the selection (Return, Space, Tab, Delete, "
            + "a command chord, type-select after moving) must come first in its \(sequence.typed ? "mac_type" : "mac_key") call, so it is "
            + "checked against the current selection. "
            + (sequence.typed ? "A newline or tab in the text counts; use submit=true to press Return after the text, or send it in a separate mac_key call."
                : "Send it in a separate mac_key call after mac_snapshot.")
    }

    /// A menu is tracking in the app: focus in a menu, a pop-up-menu-level window of the app, or a menu child.
    public static func menuIsOpen(pid: pid_t, windows: [WindowInfo]) -> Bool {
        let app = AXElement.application(pid: pid, timeout: 0.5)
        if [kAXMenuRole, kAXMenuItemRole].contains(app.element(kAXFocusedUIElementAttribute)?.role ?? "") { return true }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if windows.contains(where: { $0.pid == pid && $0.layer == menuLevel && $0.bounds.height > 10 }) { return true }
        return app.elements(kAXChildrenAttribute).contains { $0.role == kAXMenuRole }
    }

    /// A file panel (Open, Save, Go to Folder, an app chooser), as opposed to any sheet or dialog. Uses the same
    /// positive evidence as typing and paste checks (`FilePanelScan`: a file browser, file URLs, the panel service,
    /// AppKit's panel identifiers); a container that kind of scan doesn't classify gets the plain scan below, where
    /// anything unreadable or served by another process counts as a file panel.
    public static func isFilePanel(_ panel: AXElement, limit: Int = 400) -> Bool {
        let v = panel.read([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute]) ?? [:]
        if let kind = FilePanelScan.Kind(role: v[kAXRoleAttribute] as? String ?? "", subrole: v[kAXSubroleAttribute] as? String ?? "",
                                         identifier: v[kAXIdentifierAttribute] as? String ?? "") {
            return isFilePanel(panel, kind: kind)
        }
        let host = panel.pid
        var queue = [panel], visited = 0
        while !queue.isEmpty {
            guard visited < limit else { return true }
            let e = queue.removeFirst()
            visited += 1
            guard e.pid == host, let v = e.read([kAXRoleAttribute, kAXIdentifierAttribute, kAXURLAttribute, kAXChildrenAttribute]) else { return true }
            if v[kAXRoleAttribute] as? String == kAXBrowserRole || v[kAXIdentifierAttribute] as? String == "saveAsNameTextField" { return true }
            if fileURL(from: v[kAXURLAttribute]) != nil { return true }
            queue += (v[kAXChildrenAttribute] as? [Any] ?? []).compactMap(AXElement.from)
        }
        return false
    }

    /// Letter keys of Finder's commands that copy, cut, paste, duplicate, alias, eject or print the selection
    /// (c x v d l e p). With ⇧ the same letters go places (⇧⌘C Computer, ⇧⌘D Desktop, ⇧⌘L Downloads).
    static let selectionLetterKeys: Set<CGKeyCode> = [8, 7, 9, 2, 37, 14, 35]
    /// Letter keys of the commands that show the selection: Get Info, Quick Look, Show Original (i y r).
    static let inspectionLetterKeys: Set<CGKeyCode> = [34, 16, 15]

    /// Keys that rename, trash, copy, cut, paste, duplicate or alias Finder's selection, or move it into a new folder
    /// (⌃⌘N). Any ⌃⌘ chord counts: ⌃⌘A makes an alias, ⌃⌘T adds to the sidebar.
    public static func mutatesSelection(_ key: KeySpec) -> Bool {
        if [36, 76, 51, 117].contains(key.key) { return true }
        let mods = key.flags.intersection(modifierMask)
        guard mods.contains(.maskCommand) else { return false }
        if mods.contains(.maskControl) || [7, 9].contains(key.key) { return true }
        return !mods.contains(.maskShift) && selectionLetterKeys.contains(key.key)
    }

    /// Keys that show Finder's selection (Get Info, the inspector, Quick Look, Show Original). Opening it (⌘O, ⌘↓,
    /// Space) is `opensSelection`.
    public static func inspectsSelection(_ key: KeySpec) -> Bool {
        let mods = key.flags.intersection(modifierMask)
        return mods.contains(.maskCommand) && !mods.contains(.maskShift) && inspectionLetterKeys.contains(key.key)
    }

    /// Whether Finder's response to this key depends on what is selected, so that it must not be sent when the
    /// selection can't be read. Navigation, windows and views (⌘N, ⌘W, ⌘F, ⌘1–4, ⌘[, Go shortcuts) don't.
    public static func needsSelectionRead(_ key: KeySpec) -> Bool {
        opensSelection(key) || key.key == 49 || mutatesSelection(key) || inspectsSelection(key)
    }

    /// The only command keys that leave a selected protected item alone: new window and tab, close, back and forward,
    /// enclosing folder, Find, Settings, Hide, and the icon and list views. Every other chord is refused while one is
    /// selected, however harmless it looks: ⌘3 (column view), ⌘4 (gallery view) and ⇧⌘P (Preview pane) show the
    /// selected file, and ⌥⌘O opens it.
    static let protectedSelectionSafeKeys: [KeySpec] = ["cmd+n", "cmd+w", "cmd+t", "cmd+[", "cmd+]", "cmd+up", "cmd+f", "cmd+comma",
                                                       "cmd+h", "cmd+1", "cmd+2",
                                                       // The Go menu: each goes to a fixed place and leaves the selection alone.
                                                       "cmd+shift+g", "cmd+shift+d", "cmd+shift+h", "cmd+shift+a", "cmd+shift+u",
                                                       "cmd+shift+o", "cmd+shift+c", "cmd+shift+r", "cmd+shift+i", "cmd+shift+f",
                                                       "cmd+shift+k"].compactMap { try? KeySpec.parse($0) }

    /// Why a key that Finder reads the selection for (any command chord, Return, Enter, Delete, Space) can't be sent
    /// while the selection includes a protected item, or nil. Unlike `finderKeyRefusal`'s other checks this is an
    /// allowlist: what isn't known to leave the selection alone is refused.
    public static func protectedSelectionKeyRefusal(_ key: KeySpec, selection: [URL]?) -> String? {
        guard actsOnSelection(key), !leavesProtectedSelectionAlone(key) else { return nil }
        return protectedSelectionRefusal(selection)
    }

    static func leavesProtectedSelectionAlone(_ key: KeySpec) -> Bool {
        protectedSelectionSafeKeys.contains { ServiceHotkeys.matches($0, key) }
    }

    /// Keys that show the selected file's contents whichever list holds focus: column view (⌘3), gallery view (⌘4),
    /// the Preview pane (⇧⌘P), Quick Look (⌘Y, ⌥⌘Y, Space).
    static let previewKeys: [KeySpec] = ["cmd+3", "cmd+4", "cmd+shift+p", "cmd+y", "alt+cmd+y", "space", "alt+space"]
        .compactMap { try? KeySpec.parse($0) }

    public static func previewsSelection(_ key: KeySpec) -> Bool { previewKeys.contains { ServiceHotkeys.matches($0, key) } }

    /// Why a command that previews the window's selection (`previewsSelection`, read from every file list of the
    /// window rather than the focused one: with focus in the sidebar, the selection in the files is what is shown)
    /// can't run, or nil: it can't be read, or it holds a protected item.
    public static func previewRefusal(_ shown: [URL]?) -> String? {
        guard let shown else { return unreadableSelectionRefusal }
        return protectedSelectionRefusal(shown)
    }

    /// Finder's decision for a key on its selection (`nil` when it can't be read): a selection that includes a
    /// protected item is refused for every key that acts on it, an unreadable one for every key that depends on it.
    /// Copying, cutting, duplicating and the like also refuse a folder that contains protected items (the home
    /// folder, ~/Library, ~/.config): their copy would hold the protected files too.
    public static func finderKeyRefusal(_ key: KeySpec, selection: [URL]?, policy: Policy) -> String? {
        if let r = protectedSelectionKeyRefusal(key, selection: selection) { return r }
        // Space opens Quick Look; it can invoke a file handler as well.
        if opensSelection(key) || key.key == 49, let r = selectionRefusal(selection, explicitApp: nil, policy: policy) { return r }
        if needsSelectionRead(key), let r = protectedSelectionRefusal(selection) { return r }
        if mutatesSelection(key), let r = mutationSelectionRefusal(selection) { return r }
        if inspectsSelection(key), selection == nil { return unreadableSelectionRefusal }
        return nil
    }

    /// Finder's menu bar is Apple, Finder, File, Edit, View, Go, Window, Help; counted from the end so that a bar
    /// with or without the Apple item reads alike. File, Edit and the Finder menu can act on the selection; the
    /// last four only change the view or go somewhere. A bar of another shape is checked throughout.
    public static func finderMenuActsOnSelection(index: Int, count: Int) -> Bool {
        guard count >= 7 else { return true }
        return (5...7).contains(count - index)
    }

    /// Finder's View menu (fourth from the end): its commands don't change the selection, but some show it (as
    /// Columns, as Gallery, Show Preview), so it is held to the keys' rules (`finderViewMenuRefusal`).
    public static func finderMenuShowsSelection(index: Int, count: Int) -> Bool { count >= 7 && count - index == 4 }

    /// A Finder View menu item, known by its key equivalent as keys are: one that previews (`previewsSelection`) needs
    /// the window's selection readable and free of protected items; any other, unless its key is one that leaves a
    /// protected selection alone (as Icons, as List), needs it free of protected items. An item with no key
    /// equivalent counts as any other.
    public static func finderViewMenuRefusal(key: KeySpec?, shown: [URL]?) -> String? {
        if let key, previewsSelection(key) { return previewRefusal(shown) }
        if let key, leavesProtectedSelectionAlone(key) { return nil }
        return protectedSelectionRefusal(shown)
    }

    /// Where `item` sits in its app's menu bar, or nil for an item outside it (a contextual menu).
    public static func menuBarPosition(of item: AXElement) -> (index: Int, count: Int)? {
        var node: AXElement? = item
        for _ in 0..<16 {
            guard let e = node, let parent = e.element(kAXParentAttribute) else { return nil }
            if parent.role == kAXMenuBarRole {
                let siblings = parent.elements(kAXChildrenAttribute)
                return siblings.firstIndex(of: e).map { ($0, siblings.count) }
            }
            node = parent
        }
        return nil
    }

    /// Whether a Finder menu item's key equivalent says it depends on the selection; an item without one does.
    public static func menuNeedsSelectionRead(_ item: AXElement) -> Bool {
        let values = item.read([kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute]) ?? [:]
        return menuNeedsSelectionRead(character: values[kAXMenuItemCmdCharAttribute] as? String,
                                      modifiers: (values[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue,
                                      virtualKey: (values[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber)?.intValue)
    }

    static func menuNeedsSelectionRead(character: String?, modifiers: Int?, virtualKey: Int?) -> Bool {
        menuKey(character: character, modifiers: modifiers, virtualKey: virtualKey).map(needsSelectionRead) ?? true
    }

    /// ⌘C: Finder copies its selection to the clipboard.
    public static func copiesSelection(_ key: KeySpec) -> Bool { key.key == 8 && key.flags.intersection(modifierMask) == .maskCommand }

    /// The key equivalent of a menu item, read from it.
    public static func menuKey(_ item: AXElement) -> KeySpec? {
        let values = item.read([kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute]) ?? [:]
        return menuKey(character: values[kAXMenuItemCmdCharAttribute] as? String,
                       modifiers: (values[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue,
                       virtualKey: (values[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber)?.intValue)
    }

    /// Copy (⌘C) in Finder's Edit menu or a contextual menu.
    public static func menuCopiesSelection(_ item: AXElement) -> Bool { menuKey(item).map(copiesSelection) ?? false }

    /// Get Info, the inspector, Quick Look and Show Original.
    public static func menuInspectsSelection(_ item: AXElement) -> Bool { menuKey(item).map(inspectsSelection) ?? false }

    /// A Finder File or Edit item, or a contextual-menu item, against the selection. A protected item in a readable
    /// selection refuses every command; an unreadable selection refuses all but the commands with a key equivalent
    /// that doesn't depend on it (New Finder Window, Select All, Undo).
    public static func menuSelectionRefusal(_ urls: [URL]?, dependsOnSelection: Bool) -> String? {
        if urls == nil, !dependsOnSelection { return nil }
        return mutationSelectionRefusal(urls)
    }

    public static func commitsField(_ key: KeySpec) -> Bool {
        [36, 76, 48, 49].contains(key.key)
            || (key.flags.contains(.maskControl) && [34, 38, 46].contains(key.key)) // control-I/J/M
            || (key.flags.contains(.maskCommand) && [1, 31].contains(key.key)) // Save/Open
    }

    /// Menus can track a selected child without moving keyboard focus. Prefer the deepest highlighted item.
    public static func activeMenuItem(pid: pid_t) -> (open: Bool, item: AXElement?) {
        let app = AXElement.application(pid: pid)
        let focus = app.element(kAXFocusedUIElementAttribute)
        let focusIsMenu = [kAXMenuRole, kAXMenuItemRole].contains(focus?.role ?? "")
        // Native tracking menus have their own window above the app. Avoid walking an entire document before
        // every Return when no menu is tracking. A menu whose selection can't be read still returns open=true.
        let trackingWindow = WindowServer.onScreenWindows().contains { $0.pid == pid && $0.layer > 0 && $0.bounds.height > 10 }
        let menus = app.elements(kAXChildrenAttribute).filter { $0.role == kAXMenuRole }
        guard focusIsMenu || trackingWindow || !menus.isEmpty else { return (false, nil) }
        var queue = [focus, app.element(kAXMenuBarAttribute), app.element(kAXFocusedWindowAttribute)].compactMap { $0 } + menus
        var seen = Set<AXElement>(), found = focus?.role == kAXMenuItemRole ? focus : nil
        var open = focusIsMenu || trackingWindow, visited = 0, depth = 0
        func itemDepth(_ element: AXElement) -> Int {
            var node: AXElement? = element, count = 0
            for _ in 0..<16 {
                guard let e = node else { break }
                if e.role == kAXMenuItemRole { count += 1 }
                node = e.element(kAXParentAttribute)
            }
            return count
        }
        if let found { depth = itemDepth(found) }
        while !queue.isEmpty, visited < 1200 {
            let e = queue.removeFirst()
            guard seen.insert(e).inserted else { continue }
            visited += 1
            let values = e.read([kAXRoleAttribute, kAXChildrenAttribute, kAXSelectedChildrenAttribute, kAXSelectedAttribute]) ?? [:]
            let role = values[kAXRoleAttribute] as? String
            if role == kAXMenuRole {
                let selected = e.elements(kAXSelectedChildrenAttribute)
                if let last = selected.last, itemDepth(last) >= depth { found = last; depth = itemDepth(last); open = true }
            }
            if role == kAXMenuItemRole, values[kAXSelectedAttribute] as? Bool == true, itemDepth(e) >= depth {
                found = e; depth = itemDepth(e); open = true
            }
            queue += e.elements(kAXChildrenAttribute)
        }
        return (open, found)
    }

    /// Whether a menu item is in Finder's File menu or a contextual menu (outside the menu bar), where Open With sits
    /// right after Open. Position counts from the end of the bar (see `finderMenuActsOnSelection`).
    public static func inFileOrContextMenu(_ item: AXElement) -> Bool {
        guard let position = menuBarPosition(of: item) else { return true }
        return position.count < 7 || position.count - position.index == 6
    }

    /// An Open With child, including localized Finder menus and contextual menus. A handler's AXURL is preferred
    /// to its decorated title. The submenu immediately after Open is Open With in Finder's File/context menus.
    public static func isExplicitHandlerItem(_ item: AXElement) -> Bool {
        guard let menu = item.element(kAXParentAttribute), let parent = menu.element(kAXParentAttribute),
              parent.role == kAXMenuItemRole else { return false }
        if normalized(parent.string(kAXTitleAttribute) ?? "") == "open with" { return true }
        if let container = parent.element(kAXParentAttribute) {
            let siblings = container.elements(kAXChildrenAttribute).filter { $0.role == kAXMenuItemRole }
            if let index = siblings.firstIndex(of: parent), index > 0 {
                if menuCommand(siblings[index - 1]) == .open { return true }
                if index == 1, inFileOrContextMenu(parent) { return true }
            }
        }
        return url(of: item, levels: 0).map { $0.isFileURL && isAppBundle($0) } ?? false
    }

    public static let unresolvedHandlerRefusal = "Refused: this Open With handler can't be checked. Use mac_app action=launch app=<App> open=<path> instead."

    /// Strip only decorations whose meaning is known. A failed lookup never falls back to the default handler.
    public static func handlerName(_ title: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("…") || name.hasSuffix("...") { return nil } // Other… (in any language) opens a chooser
        return name.replacingOccurrences(of: #"\s+\([^)]*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\d+(?:\.\d+)*(?:\s.*)?$"#, with: "", options: .regularExpression)
    }

    public static func explicitHandlerRefusal(app: URL?, selection: [URL]?, policy: Policy) -> String? {
        guard let app else { return unresolvedHandlerRefusal }
        return selectionRefusal(selection, explicitApp: app, policy: policy)
    }

    /// A replacement is checked as one value, using AX's UTF-16 selection offsets. Unreadable naming fields fail
    /// closed; ordinary editors that hide their text still accept text, with standalone paths checked as before.
    public static func fieldEditRefusal(_ text: String, current: String?, selection: CFRange?, mode: Actions.TypeMode,
                                        naming: Bool, validate: (String) -> String?) -> String? {
        if let r = typedPathRefusal(text) { return r }
        guard let result = Actions.expectedTypedValue(original: current, text: text, mode: mode, selection: selection) else {
            return naming ? "Refused: the file name or caret can't be read. Take mac_snapshot and type with ref and mode=replace." : nil
        }
        return validate(result)
    }

    public static let unreadableSelectionRefusal = "Refused: Finder's selection couldn't be checked; select the items again or use a path you can see."

    public static func mutationSelectionRefusal(_ urls: [URL]?) -> String? {
        guard let urls else { return unreadableSelectionRefusal }
        return urls.lazy.compactMap { ProtectedPaths.mutationRefusal($0.path) }.first
    }

    /// The file panel (Open, Save, Go to Folder) holding `element`, or nil: the nearest sheet, popover, dialog or
    /// floating window around it that shows signs of one (see `FilePanelScan`). Other dialogs and panels aren't.
    public static func namingPanel(of element: AXElement) -> AXElement? {
        var node: AXElement? = element
        for _ in 0..<16 {
            guard let e = node else { break }
            let v = e.read([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute]) ?? [:]
            let role = v[kAXRoleAttribute] as? String ?? ""
            if let kind = FilePanelScan.Kind(role: role, subrole: v[kAXSubroleAttribute] as? String ?? "",
                                             identifier: v[kAXIdentifierAttribute] as? String ?? ""),
               isFilePanel(e, kind: kind) { return e }
            if role == kAXApplicationRole { break }
            node = e.element(kAXParentAttribute)
        }
        return nil
    }

    /// Coordinate hit tests can return a menu item's label or a button's image rather than the command itself.
    public static func commandTarget(of element: AXElement) -> AXElement {
        var node: AXElement? = element
        for _ in 0..<8 {
            guard let e = node else { break }
            if [kAXMenuItemRole, kAXMenuBarItemRole, kAXButtonRole].contains(e.role ?? "") { return e }
            if [kAXWindowRole, kAXApplicationRole].contains(e.role ?? "") { break }
            node = e.element(kAXParentAttribute)
        }
        return element
    }

    /// What a set of selected rows stands for.
    enum SelectionRead: Equatable {
        case urls([URL])
        /// Only sidebar places, which stand for the folder shown and not for a selected item.
        case places
        case unreadable
    }

    /// Reads selected rows as files. A row that stands for no file is unreadable, unless every such row is a place.
    static func selectionRead<Row>(_ rows: [Row], url: (Row) -> URL?, isPlace: (Row) -> Bool) -> SelectionRead {
        let urls = rows.map(url)
        if urls.allSatisfy({ $0 != nil }) { return .urls(urls.compactMap { $0 }) }
        let unresolved = zip(rows, urls).filter { $0.1 == nil }.map(\.0)
        return unresolved.allSatisfy(isPlace) ? .places : .unreadable
    }

    /// The file a selected item of a file list stands for: AXURL on the item or up to two levels into it. An icon or
    /// gallery item holds it on its image, a column view's item on its name field, a list view's row on the name
    /// field in its first cell.
    public static func itemURL(of item: AXElement) -> URL? { itemURL(of: item, tree: .accessibility) }

    static func itemURL<N>(of item: N, tree t: SelectionTree<N>) -> URL? {
        var level = [item]
        for _ in 0..<3 {
            if let url = level.lazy.compactMap(t.url).first { return url }
            level = level.flatMap { t.children($0) ?? [] }
        }
        return nil
    }

    /// A selected row of a sidebar (Favorites, Locations, Tags) holds a place's name as static text, with no file name
    /// field in it; a list view's row holds one, carrying the file's URL.
    public static func isSidebarPlace(_ row: AXElement, in list: AXElement) -> Bool {
        isSidebarPlace(row, in: list, tree: .accessibility)
    }

    static func isSidebarPlace<N>(_ row: N, in list: N, tree t: SelectionTree<N>) -> Bool {
        guard t.role(list) == kAXOutlineRole, t.role(row) == kAXRowRole else { return false }
        guard let cells = t.children(row) else { return false }
        let parts = cells.flatMap { t.children($0) ?? [] }
        return !parts.isEmpty && !parts.contains { t.role($0) == kAXTextFieldRole }
    }

    /// The file panel on top in `pid`'s focused window, through its sheets.
    public static func activeNamingPanel(pid: pid_t) -> AXElement? {
        guard var window = AXElement.application(pid: pid).element(kAXFocusedWindowAttribute) else { return nil }
        for _ in 0..<8 {
            if let sheet = window.elements("AXSheets").last { window = sheet }
            else { return namingPanel(of: window) }
        }
        return nil
    }

    /// Finder exposes the directory of a blank drop area as AXDocument on its enclosing window, rather than AXURL
    /// on the hit element. Resolving that directory is necessary to check a replacement by the source's basename.
    public static func destinationFolder(of element: AXElement) -> URL? {
        var node: AXElement? = element
        for _ in 0..<16 {
            guard let e = node else { break }
            let values = e.read([kAXURLAttribute, kAXDocumentAttribute]) ?? [:]
            for value in [values[kAXURLAttribute], values[kAXDocumentAttribute]] {
                let url = value as? URL ?? (value as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0) }
                if let url, url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return url }
            }
            node = e.element(kAXParentAttribute)
        }
        return nil
    }

    public static func moveRefusal(source: URL, destinationFolder: URL?) -> String? {
        if let r = ProtectedPaths.mutationRefusal(source.path) { return r }
        guard let destinationFolder else { return "Refused: the destination folder can't be checked. Take mac_snapshot and use folder refs." }
        return ProtectedPaths.mutationRefusal(destinationFolder.appendingPathComponent(source.lastPathComponent).path)
    }
}
