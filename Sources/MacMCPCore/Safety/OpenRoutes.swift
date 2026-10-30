import AppKit
import ApplicationServices
import Foundation
import UniformTypeIdentifiers

/// The routes that open things on an agent's behalf: `mac_app open=`, a click or drop on a Dock tile or a Finder
/// item, a Services or Quick Actions menu, a launcher hotkey, a name typed into a file panel. Each can reach what the
/// app policy forbids (a denied app, a script that runs on open, a shortcut, MacMCP's own policy), so each asks here.
public enum OpenRoutes {
    /// File types that run something, install something or open a location when opened.
    public static let launcherExtensions: Set<String> = namingLauncherExtensions.union([
        "scpt", "scptd", "applescript", "sh", "zsh", "bash", "csh", "tcsh", "ksh", "jar", "py", "pyw",
    ])

    /// The subset no file panel or Finder may name a file as: these act when opened even when not executable and
    /// written as plain text. Scripts and source files (.sh, .py) aren't here: editors save them all the time, and
    /// opening them is still refused.
    public static let namingLauncherExtensions: Set<String> = [
        "app", "command", "terminal", "tool", "workflow", "wflow", "action", "pkg", "mpkg", "shortcut", "prefpane",
        "mobileconfig", "webloc", "inetloc", "fileloc", "vncloc", "afploc", "ftploc",
    ]

    public static let finder = "com.apple.finder"
    public static let dock = "com.apple.dock"

    // MARK: mac_app open=

    public enum OpenTarget: Equatable, Sendable {
        case web(URL), mail(URL), file(URL)

        public var url: URL {
            switch self { case let .web(u), let .mail(u), let .file(u): u }
        }
    }

    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    /// What `open=` names: an http(s) or mailto URL, or a file that exists (a path or a file: URL). Any other
    /// scheme is refused: x-apple.systempreferences: changes settings, shortcuts: runs shortcuts, and an app's own
    /// scheme can launch it.
    public static func parse(_ target: String) -> Result<OpenTarget, Refusal> {
        let s = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("/"), !s.hasPrefix("~"), let url = URL(string: s), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard url.host?.isEmpty == false else { return .failure(Refusal("\"\(Untrusted.inline(s, limit: 200))\" has no host.")) }
                return .success(.web(url))
            case "mailto":
                return .success(.mail(url))
            case "file":
                guard FileManager.default.fileExists(atPath: url.path) else { return .failure(notFound(s)) }
                return .success(.file(URL(fileURLWithPath: url.path)))
            default:
                return .failure(Refusal("Refused: open= takes an http(s) or mailto URL or a file path. \(Untrusted.inline(scheme)): URLs can "
                    + "launch apps, run shortcuts or change settings, so MacMCP doesn't open them. Launch an app with "
                    + "mac_app action=launch app=<name>."))
            }
        }
        let path = (s as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return .failure(notFound(s)) }
        return .success(.file(URL(fileURLWithPath: path)))
    }

    static func notFound(_ s: String) -> Refusal {
        Refusal("Cannot open \"\(Untrusted.inline(s, limit: 200))\": not an http(s) or mailto URL, or an existing file path.")
    }

    /// Why opening `target` with the app at `appURL` would get round the policy, or nil. Opening through Finder means
    /// the default handler, so that's the app checked; any other app opens it itself.
    public static func refusal(opening target: OpenTarget, with appURL: URL, policy: Policy) -> String? {
        refusal(opening: target, explicitApp: Bundle(url: appURL)?.bundleIdentifier == finder ? nil : appURL, policy: policy)
    }

    /// `explicitApp` nil: the default handler opens it.
    static func refusal(opening target: OpenTarget, explicitApp: URL?, policy: Policy) -> String? {
        switch target {
        case let .web(url):
            if let host = url.host, Policy.WebPolicy.covers(policy.web.denyHosts, host: host) {
                return "Refused by policy: \(Untrusted.inline(host)) is on web.deny_hosts (\(Policy.fileRef))."
            }
            return explicitApp == nil ? handlerRefusal(url, name: url.host ?? "that link", policy: policy) : nil
        case let .mail(url):
            return explicitApp == nil ? handlerRefusal(url, name: "that mail link", policy: policy) : nil
        case let .file(url):
            return fileRefusal(url, explicitApp: explicitApp, policy: policy)
        }
    }

    /// Why a file mustn't be opened (with `explicitApp`, or else its default handler), or nil: a protected path, an
    /// app or launcher, anything executable, or a handler the policy denies. Links and aliases are followed.
    public static func fileRefusal(_ url: URL, explicitApp: URL?, policy: Policy) -> String? {
        let path = url.path
        if let r = ProtectedPaths.refusal(path) { return r }
        let resolved = URL(fileURLWithPath: ProtectedPaths.aliasTarget(ProtectedPaths.physical(path)) ?? ProtectedPaths.physical(path))
        let name = url.lastPathComponent
        for u in [url, resolved] {
            if let why = launcherReason(u) {
                return "Refused: \(Untrusted.inline(name)) \(why), so MacMCP doesn't open it. A person can."
            }
        }
        if let explicitApp { return policy.refusal(appAt: explicitApp) }
        return handlerRefusal(resolved, name: name, policy: policy)
    }

    /// Why this file counts as a launcher, or nil.
    static func launcherReason(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if launcherExtensions.contains(ext) { return "is a .\(ext) file, which runs or installs something (or opens a location) when opened" }
        let v = try? url.resourceValues(forKeys: [.isApplicationKey, .contentTypeKey])
        if v?.isApplication == true { return "is an app; launch apps with mac_app action=launch instead" }
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o111 != 0 else { return nil }
        // Every file on a FAT or SMB volume has the bit; a document's type still decides what opens it, so only a
        // file macOS would treat as a program or script counts.
        let type = v?.contentType
        if ext.isEmpty || type.map({ $0.conforms(to: .executable) || $0.conforms(to: .script) }) ?? true {
            return "is executable (it would run as a program)"
        }
        return nil
    }

    /// Whether the app that opens `url` by default is one the policy denies.
    static func handlerRefusal(_ url: URL, name: String, policy: Policy) -> String? {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url), let r = policy.refusal(appAt: handler) else { return nil }
        return "Refused: \(Untrusted.inline(name)) would open in \(Untrusted.inline(AppIdentity(bundleURL: handler).label)). " + r
    }

    // MARK: Elements that stand for files and apps

    /// The URL an element stands for (a Dock tile, a Finder item, a file row in a panel), from AXURL on it or up to
    /// `levels` of its ancestors.
    public static func url(of element: AXElement, levels: Int = 2) -> URL? {
        var e: AXElement? = element
        for _ in 0...levels {
            guard let cur = e else { return nil }
            if let u = cur.attribute(kAXURLAttribute) as? URL { return resolved(u) }
            if let s = cur.attribute(kAXURLAttribute) as? String, let u = URL(string: s), u.scheme != nil { return resolved(u) }
            e = cur.element(kAXParentAttribute)
        }
        return nil
    }

    /// Finder gives file reference URLs (`file:///.file/id=…`); one that no longer resolves (an item being created or
    /// renamed) names no file, rather than an empty path taken as the home folder.
    static func resolved(_ url: URL) -> URL? {
        // Foundation turns a reference it can't resolve into this scheme, with an empty path.
        if url.scheme == "com-apple-unresolvable-file-reference-url" { return nil }
        guard url.isFileURL || url.scheme?.lowercased() == "file" else { return url }
        let path = (url as NSURL).filePathURL?.path ?? url.path
        return path.hasPrefix("/") && !path.hasPrefix("/.file/") ? URL(fileURLWithPath: path) : nil
    }

    static func ownerBundleID(_ pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    /// Why an action may not land on this element because of what it stands for, or nil: a protected file anywhere;
    /// a Dock tile (a click or a drop opens it) for a denied app, a launcher or a denied handler; an app icon (a drop
    /// opens the file with it) for a denied app.
    public static func elementRefusal(_ element: AXElement, pid: pid_t, policy: Policy) -> String? {
        guard let url = url(of: element) else { return nil }
        return elementRefusal(url: url, owner: ownerBundleID(pid), policy: policy)
    }

    /// The decision for an element standing for `url`, in the app with bundle ID `owner`.
    static func elementRefusal(url: URL, owner: String?, policy: Policy) -> String? {
        if url.isFileURL, let r = ProtectedPaths.refusal(url.path) { return r }
        if owner == dock { return tileRefusal(url, policy: policy) }
        if url.isFileURL, isAppBundle(url) { return policy.refusal(appAt: url) }
        // A link with an app's scheme (shortcuts:, x-apple.systempreferences:, ssh:) opens that app.
        if let scheme = url.scheme?.lowercased(), !pageSchemes.contains(scheme) {
            return handlerRefusal(url, name: "that link", policy: policy)
        }
        return nil
    }

    /// Schemes a page uses for itself, which open nothing else.
    static let pageSchemes: Set<String> = ["http", "https", "mailto", "file", "javascript", "about", "data", "blob"]

    /// A Dock tile: an app is launched, a document or folder opened by its handler, a link by the browser.
    public static func tileRefusal(_ url: URL, policy: Policy) -> String? {
        if url.isFileURL {
            if let r = ProtectedPaths.refusal(url.path) { return r }
            if isAppBundle(url) { return policy.refusal(appAt: url) }
            if isPlainFolder(url) { return nil }
            return fileRefusal(url, explicitApp: nil, policy: policy)
        }
        switch parse(url.absoluteString) {
        case let .success(target): return refusal(opening: target, explicitApp: nil, policy: policy)
        case let .failure(r): return r.description
        }
    }

    /// A double-click on a Finder item opens it: an app is launched, anything else goes to its default handler.
    public static func openingRefusal(_ element: AXElement, pid: pid_t, policy: Policy) -> String? {
        guard ownerBundleID(pid) == finder, let url = url(of: element) else { return nil }
        return openingRefusal(url: url, policy: policy)
    }

    public static func openingRefusal(url: URL, policy: Policy) -> String? {
        guard url.isFileURL else { return nil }
        if let r = ProtectedPaths.refusal(url.path) { return r }
        if isAppBundle(url) { return policy.refusal(appAt: url) }
        if isPlainFolder(url) { return nil }
        return fileRefusal(url, explicitApp: nil, policy: policy)
    }

    static func isAppBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app" || (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true
    }

    static func isPlainFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    // MARK: Opening Finder's selection

    /// ⌘O and ⌘↓ (⌥⌘O and ⌥⌘↓ too: they open it and close the window) open Finder's selection; ⇧⌘O goes to Documents.
    public static func opensSelection(_ key: KeySpec) -> Bool {
        let mods = key.flags.intersection(modifierMask).subtracting(.maskAlternate)
        return [31, 125].contains(key.key) && mods == .maskCommand
    }

    /// A Finder menu path that opens the selection ("File > Open", "File > Open With > TextEdit"), and the app named
    /// for Open With.
    public static func opensSelection(menuPath path: [String]) -> (opens: Bool, app: String?) {
        let steps = path.map(normalized)
        if let i = steps.firstIndex(where: { $0 == "open with" }) { return (true, i + 1 < path.count ? path[i + 1] : nil) }
        return (steps.contains { $0 == "open" || $0.hasPrefix("open in new") }, nil)
    }

    /// Keys that act on Finder's selection (move, copy, rename, delete, inspect it) rather than move around.
    public static func actsOnSelection(_ key: KeySpec) -> Bool {
        key.flags.contains(.maskCommand) || [36, 76, 51, 117, 49].contains(key.key)   // return, enter, delete, fwd delete, space
    }

    /// A Finder menu that only goes somewhere or manages windows, never touching the selection. Not the View menu:
    /// as Columns, as Gallery and Show Preview show the selected file (see `finderViewMenuRefusal`).
    public static func leavesSelectionAlone(menuPath path: [String]) -> Bool {
        guard let top = path.first.map(normalized) else { return true }
        return ["go", "window", "help"].contains(top)
    }

    /// Why Finder mustn't act on a selection that includes a protected file or folder (move it, copy it, rename it,
    /// delete it, get its info), or nil. An unreadable selection is let through here, since most chords leave the
    /// selection alone: `finderKeyRefusal` and `mutationSelectionRefusal` refuse it for the keys that depend on it.
    public static func protectedSelectionRefusal(_ urls: [URL]?) -> String? {
        urls?.lazy.compactMap { ProtectedPaths.refusal($0.path) }.first
    }

    /// Why opening these selected files (with `explicitApp`, or each one's default handler) must be refused, or nil.
    /// A selection that couldn't be read is refused: there's no telling what it would open.
    public static func selectionRefusal(_ urls: [URL]?, explicitApp: URL?, policy: Policy) -> String? {
        guard let urls else {
            return "Refused: MacMCP can't read what's selected in Finder, so it can't check what that would open. "
                + "Double-click the item, or use mac_app action=launch app=<App> open=<path>."
        }
        if let explicitApp, let r = policy.refusal(appAt: explicitApp) { return r }
        for url in urls {
            if let r = explicitApp == nil ? openingRefusal(url: url, policy: policy)
                : ProtectedPaths.refusal(url.path) ?? launcherReason(url).map({ "Refused: \(Untrusted.inline(url.lastPathComponent)) \($0), so MacMCP doesn't open it." }) {
                return r
            }
        }
        return nil
    }

    // MARK: Menus

    /// Services and Finder's Quick Actions run shortcuts, workflows and other apps' commands outside mac_shortcut's
    /// allowlist. Their titles in every language macOS ships: AppKit's own "Services" and Finder's "Quick Actions",
    /// read from their localizations, with the English ones in case those can't be read.
    static let shortcutMenus: Set<String> = {
        let appKit = Bundle(for: NSApplication.self).url(forResource: "Services", withExtension: "loctable")
        let finderApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finder).flatMap(Bundle.init(url:))
        return Set((["Services", "Quick Actions"] + LocalizedTitles.loctable(appKit, keys: ["Services"])
            + LocalizedTitles.strings(finderApp, table: "LocalizableMerged", english: ["Quick Actions"])).map(normalized))
    }()

    /// Items only a Services menu holds, whatever the app titled the menu itself: AppKit adds "Services Settings…" at
    /// the end of every one (after "No Services Apply" when none fits), in the app's language.
    static let servicesMenuItems: Set<String> = {
        // AppKit's table spells the ellipsis in the key as the six characters \U2026.
        let keys = ["Services Settings\\U2026", "Services Settings\u{2026}", "No Services Apply"]
        let appKit = Bundle(for: NSApplication.self).url(forResource: "Services", withExtension: "loctable")
        return Set((["Services Settings", "Services Preferences", "No Services Apply"]
            + LocalizedTitles.loctable(appKit, keys: Set(keys))).map(normalized))
    }()

    static let shortcutRefusal = "Refused: the Services and Quick Actions menus run shortcuts, workflows and other apps' "
        + "commands. Shortcuts run only through mac_shortcut, and only those in shortcuts.allowed (\(Paths.policyFile))."

    static func normalized(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A mac_menu path through Services or Quick Actions, by title in any language. `Actions.menu` checks the items it
    /// finds again with `menuRefusal(element:)`, which also knows a Services menu by what's in it.
    public static func menuRefusal(path: [String]) -> String? {
        path.contains { shortcutMenus.contains(normalized($0)) } ? shortcutRefusal : nil
    }

    /// A menu item (clicked by ref or point) that is, or is inside, Services or Quick Actions: an item above it has
    /// one of their titles, or a menu above it ends the way only a Services menu does.
    public static func menuRefusal(element: AXElement) -> String? {
        menuRefusal(element: element, role: { $0.role ?? "" }, title: { $0.string(kAXTitleAttribute) ?? "" },
                    children: { $0.elements(kAXChildrenAttribute) }, parent: { $0.element(kAXParentAttribute) })
    }

    /// The same ancestry walk for keyboard activation, mac_menu and pointer input; metadata access is injectable.
    static func menuRefusal<Node>(element: Node, role: (Node) -> String, title: (Node) -> String,
                                  children: (Node) -> [Node], parent: (Node) -> Node?) -> String? {
        guard [kAXMenuItemRole, kAXMenuBarItemRole].contains(role(element)) else { return nil }
        var node: Node? = element
        for _ in 0..<10 {
            guard let n = node else { return nil }
            let kind = role(n)
            if kind == kAXMenuItemRole || kind == kAXMenuBarItemRole, shortcutMenus.contains(normalized(title(n))) {
                return shortcutRefusal
            }
            if kind == kAXMenuRole, isServicesMenu(children(n).suffix(3).map(title)) { return shortcutRefusal }
            if kind == kAXApplicationRole { return nil }
            node = parent(n)
        }
        return nil
    }

    /// Whether a menu whose last items have these titles is a Services menu.
    static func isServicesMenu(_ lastTitles: [String]) -> Bool {
        lastTitles.contains { servicesMenuItems.contains(normalized($0)) }
    }

    /// "Paste", "Paste and Match Style", "Paste Style" …
    public static func isPasteTitle(_ title: String) -> Bool { normalized(title).hasPrefix("paste") }

    /// A menu item element that pastes.
    public static func isPasteItem(_ element: AXElement) -> Bool {
        element.role == kAXMenuItemRole && (menuCommand(element) == .paste || isPasteTitle(element.string(kAXTitleAttribute) ?? ""))
    }

    // MARK: Keys

    /// ⌘V and its variants (⌥⇧⌘V paste and match style, ⇧⌘V).
    public static func isPaste(_ key: KeySpec) -> Bool { key.key == 9 && key.flags.contains(.maskCommand) }

    /// Spotlight's search and Finder-search hotkeys, as the person set them (⌘Space and ⌥⌘Space by default).
    public static func spotlightHotkeys(_ symbolic: [String: Any]? = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
        .dictionary(forKey: "AppleSymbolicHotKeys")) -> [KeySpec] {
        let defaults = ["64": KeySpec(key: 49, flags: .maskCommand), "65": KeySpec(key: 49, flags: [.maskCommand, .maskAlternate])]
        return defaults.keys.sorted().compactMap { id in
            guard let entry = symbolic?[id] as? [String: Any] else { return defaults[id] }
            if (entry["enabled"] as? NSNumber)?.boolValue == false { return nil }
            guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], params.count == 3 else { return defaults[id] }
            return KeySpec(key: CGKeyCode(params[1].intValue), flags: CGEventFlags(rawValue: params[2].uint64Value))
        }
    }

    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Keys that bring another app forward: ⌘Tab, ⌘`, ⌘Q, ⌘H, ⌥⌘Esc (Force Quit), ⌃ with an arrow (Spaces, Mission
    /// Control), and Mission Control and Launchpad keys.
    public static func switchesApp(_ key: KeySpec) -> Bool {
        let cmd = key.flags.contains(.maskCommand)
        if cmd, [48, 50, 12, 4].contains(key.key) { return true }
        if cmd, key.flags.contains(.maskAlternate), key.key == 53 { return true }
        if key.flags.contains(.maskControl), (123...126).contains(key.key) { return true }
        return [160, 130, 131].contains(key.key)
    }

    /// Keys sent after one that switches apps go to whichever app comes forward, a denied one as likely as not,
    /// and the app check ran only for the first.
    public static func appSwitchRefusal(_ keys: [KeySpec], repeat count: Int) -> String? {
        guard let i = keys.firstIndex(where: switchesApp), i < keys.count - 1 || (count > 1 && keys.count > 1) else { return nil }
        let names: [CGKeyCode: String] = [48: "tab", 50: "`", 12: "q", 4: "h", 53: "esc", 123: "left", 124: "right",
                                          125: "down", 126: "up", 160: "Mission Control", 130: "Launchpad", 131: "Launchpad"]
        let mods = KeySpec.describe(keys[i].flags)
        let key = (mods.isEmpty ? "" : mods + "+") + (names[keys[i].key] ?? "that key")
        return "Refused: keys after \(key) would go to whichever app comes forward, which MacMCP can't check first. "
            + "Send them in another mac_key call (with app= for where they go)."
    }

    /// Keys that open Spotlight while the policy denies it: from there an agent could launch any app or run a
    /// shortcut.
    /// `appDefines`: the frontmost app's own menus give the keys an enabled command, which runs instead of a Service.
    public static func launcherKeyRefusal(_ keys: [KeySpec], policy: Policy, hotkeys: [KeySpec] = spotlightHotkeys(), serviceKeys: [KeySpec]? = nil,
                                          serviceRefusal: ((KeySpec) -> String?)? = nil,
                                          appDefines: (KeySpec) -> Bool = { _ in false }) -> String? {
        for key in keys {
            let refusal = serviceRefusal.map { $0(key) }
                ?? serviceKeys.map { $0.contains { ServiceHotkeys.matches($0, key) } ? ServiceHotkeys.keyRefusal : nil }
                ?? ServiceHotkeys.refusal(key)
            if let refusal, !appDefines(key) { return refusal }
        }
        guard policy.refusal(bundleID: "com.apple.Spotlight", name: "Spotlight") != nil else { return nil }
        for k in keys where hotkeys.contains(where: { $0.key == k.key && $0.flags.intersection(modifierMask) == k.flags.intersection(modifierMask) }) {
            return "Refused: \(KeySpec.describe(k.flags))+\(k.key == 49 ? "space" : "that key") opens Spotlight, which the "
                + "policy denies: it launches apps and runs shortcuts. Use mac_app action=launch to start an app."
        }
        return nil
    }

    // MARK: Typing into file panels and Finder

    /// Why typing `text` into `field` would reach a protected location or give a file a launcher's name, or nil.
    /// A line that is a path (`/…`, `~…`, `file:…`) is checked in any field: a Go to Folder sheet, a dialog that isn't
    /// a file panel, an address bar. A bare name, and a launcher's extension, only matter in a file panel (Open,
    /// Save, Go to Folder: see `namingPanel`) or Finder (renaming), and are checked against the folders shown there
    /// (from AXURL and AXDocument around the field, and `folders` known otherwise) and the home folder.
    public static func typingRefusal(_ text: String, into field: AXElement, pid: pid_t, folders known: [String] = []) -> String? {
        if let r = typedPathRefusal(text) { return r }
        guard field.subrole != "AXSearchField" else { return nil }
        var inPanel = false
        var panelRoot: AXElement?
        var bases = known
        var node: AXElement? = field
        for _ in 0..<14 {
            guard let n = node else { break }
            let v = n.read([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXURLAttribute, kAXDocumentAttribute]) ?? [:]
            let role = v[kAXRoleAttribute] as? String ?? ""
            if panelRoot == nil, let kind = FilePanelScan.Kind(role: role, subrole: v[kAXSubroleAttribute] as? String ?? "",
                                                               identifier: v[kAXIdentifierAttribute] as? String ?? ""),
               isFilePanel(n, kind: kind) {
                inPanel = true
                panelRoot = n
            }
            bases += folders(for: v[kAXURLAttribute]) + folders(for: v[kAXDocumentAttribute])
            if role == kAXApplicationRole { break }
            node = n.element(kAXParentAttribute)
        }
        guard inPanel || ownerBundleID(pid) == finder else { return nil }
        return typingRefusal(text, bases: bases, names: true) { panelRoot.map { scanFolders($0) } ?? [] }
    }

    /// Whether `field` names files: a text field in a file panel (Open, Save, Go to Folder) or anywhere in Finder,
    /// other than a search field. A field in another dialog, sheet or floating panel doesn't.
    public static func isNamingField(_ field: AXElement, pid: pid_t) -> Bool {
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(field.role ?? ""),
              field.subrole != "AXSearchField", field.subrole != "AXSecureTextField" else { return false }
        if ownerBundleID(pid) == finder { return true }
        return namingPanel(of: field) != nil
    }

    /// A typed line that is a path to a protected location, whatever field it goes into.
    public static func typedPathRefusal(_ text: String) -> String? {
        typingRefusal(text, bases: [], names: false, scan: { [] })
    }

    /// The decision, given the folders known around the field and a (costly) way to find the ones the panel shows.
    /// `names`: the field names files (a panel or Finder), so bare names and extensions count too.
    static func typingRefusal(_ text: String, bases known: [String], names: Bool = true, scan: () -> [String]) -> String? {
        var bases = known
        let lines = text.components(separatedBy: CharacterSet.newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var scanned = false
        for line in lines {
            if !names {
                guard line.hasPrefix("/") || line.hasPrefix("~") || line.lowercased().hasPrefix("file:") else { continue }
                if let r = ProtectedPaths.refusal(line) { return r }
                continue
            }
            let name = (line as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            if namingLauncherExtensions.contains(ext) {
                return "Refused: a file named \"\(Untrusted.inline(name, limit: 80))\" would run or install something when opened. MacMCP "
                    + "doesn't name, save or rename files as .\(ext); pick another name."
            }
            if line.hasPrefix("/") || line.hasPrefix("~") || line.lowercased().hasPrefix("file:") {
                if let r = ProtectedPaths.refusal(line) { return r }
                continue
            }
            if protectedNames.contains(name.lowercased()) { return ProtectedPaths.refusal(Paths.home + "/" + name) ?? protectedNameRefusal(name) }
            if !scanned {
                bases += scan()
                scanned = true
            }
            for base in bases + [Paths.home] {
                if let r = ProtectedPaths.refusal(line, relativeTo: base) { return r }
            }
        }
        return nil
    }

    /// Names of protected files, refused whatever folder a panel shows: its folder can't always be read.
    static var protectedNames: Set<String> {
        Set(ProtectedPaths.shellStartupFiles.map { $0.lowercased() }
            + ["policy.approved.json", "authorized_keys", "login.keychain-db", "mac-mcp-signing.keychain-db", "signing-keychain.pass",
               "mac-mcp", "mac-mcp.previous"])
    }

    static func protectedNameRefusal(_ name: String) -> String {
        "Refused: \"\(Untrusted.inline(name, limit: 80))\" is the name of a file MacMCP protects (its policy, keychains, SSH keys or shell "
            + "startup files). Pick another name."
    }

    /// The folders an AXURL or AXDocument value points at or into.
    static func folders(for value: Any?) -> [String] {
        guard let url = fileURL(from: value) else { return [] }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return isDir ? [url.path, url.deletingLastPathComponent().path] : [url.deletingLastPathComponent().path]
    }

    /// Folders shown inside a panel (its file list, path control, sidebar), from the AXURLs of a bounded walk.
    static func scanFolders(_ root: AXElement, limit: Int = 250) -> [String] {
        var queue = [root], found: [String] = [], visited = 0
        while !queue.isEmpty, visited < limit {
            let e = queue.removeFirst()
            visited += 1
            found += folders(for: e.attribute(kAXURLAttribute))
            queue += e.elements(kAXChildrenAttribute)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }
}

/// Strings as macOS shows them in every language it ships, read from a framework's or app's own localizations.
enum LocalizedTitles {
    /// The values of `keys` in every language of a .loctable (language → key → string).
    static func loctable(_ url: URL?, keys: Set<String>) -> [String] {
        guard let url, let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return table.values.compactMap { $0 as? [String: Any] }.flatMap { strings in keys.compactMap { strings[$0] as? String } }
    }

    /// Every language's text for the strings whose English text is one of `english`, from `table`.strings in each of
    /// a bundle's .lproj folders. The keys (Finder's are codes like N270) are found through English, so they may
    /// change between releases.
    static func strings(_ bundle: Bundle?, table: String, english: Set<String>) -> [String] {
        guard let bundle else { return [] }
        func load(_ localization: String) -> [String: String] {
            bundle.path(forResource: table, ofType: "strings", inDirectory: nil, forLocalization: localization)
                .flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
        }
        let keys = load("en").filter { english.contains($0.value) }.map(\.key)
        guard !keys.isEmpty else { return [] }
        return bundle.localizations.flatMap { localization in
            let strings = load(localization)
            return keys.compactMap { strings[$0] }
        }
    }
}
