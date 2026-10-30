import AppKit
import ApplicationServices
import Foundation

public enum AppControlError: Error, CustomStringConvertible {
    case notInstalled(String)
    case launchFailed(String, String)

    public var description: String {
        switch self {
        case let .notInstalled(q): "No installed app matches \"\(q)\". Pass the exact app name or bundle ID."
        case let .launchFailed(app, why): "Could not launch \(app): \(why)"
        }
    }
}

/// Runs an async operation with a deadline. NSWorkspace's open calls can fail to complete for minutes (asking an
/// already-running Finder to "open" took ~5 min in M5), and they can't be cancelled; past the deadline the result is
/// abandoned and the caller carries on.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await Deadline.run(seconds, operation)
}

public enum AppControl {
    /// Launches (or re-uses) an app, optionally opening a URL or file in it, and waits until it has a window.
    /// An app that's already running is only activated (and handed the URL/file); it is never "re-launched".
    /// `target` must already have passed `OpenRoutes.parse` and `OpenRoutes.refusal`.
    public static func launch(_ query: String, open target: URL? = nil, activate: Bool = true) async throws -> AppInfo {
        try Task.checkCancellation()
        let existing = try? Apps.resolve(query)
        guard let appURL = existing?.bundlePath.map(URL.init(fileURLWithPath:)) ?? Apps.bundleURL(for: query) else {
            throw AppControlError.notInstalled(query)
        }
        if let existing, target == nil {
            if activate { _ = await Self.activate(existing) }
            return existing
        }
        do {
            if let url = target {
                let activates = activate
                _ = try await withDeadline(15) {
                    let c = NSWorkspace.OpenConfiguration()
                    c.activates = activates
                    try Task.checkCancellation()
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: c)
                    return true
                }
            } else {
                let activates = activate
                _ = try await withDeadline(15) {
                    let c = NSWorkspace.OpenConfiguration()
                    c.activates = activates
                    try Task.checkCancellation()
                    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: c)
                    return true
                }
            }
        } catch let e as AppControlError {
            throw e
        } catch {
            throw AppControlError.launchFailed(appURL.lastPathComponent, error.localizedDescription)
        }

        // Wait (≤10 s) for the process to finish launching and show a window.
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular }),
               running.isFinishedLaunching {
                let windows = AXElement.application(pid: running.processIdentifier).elements(kAXWindowsAttribute)
                if !windows.isEmpty { return AppInfo(running) }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return AppInfo(running)   // running but windowless (some apps start that way)
        }
        throw AppControlError.launchFailed(appURL.lastPathComponent, "it did not start within 10 s")
    }

    /// Brings an app to the front. Activation is cooperative since macOS 14 and may be refused for a background
    /// agent, so it falls back to the accessibility "frontmost" attribute. Returns whether the app ended up frontmost.
    @discardableResult
    public static func activate(_ app: AppInfo) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        if running.isHidden {
            guard !Task.isCancelled else { return false }
            running.unhide()
        }
        guard !Task.isCancelled else { return false }
        running.activate()
        if await waitFrontmost(app.pid, timeout: 0.6) { return true }
        AXElement.application(pid: app.pid).set(kAXFrontmostAttribute, kCFBooleanTrue as Any)
        if await waitFrontmost(app.pid, timeout: 0.8) { return true }
        if let path = app.bundlePath, let url = URL(string: "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) {
            _ = try? await withDeadline(3) {
                let c = NSWorkspace.OpenConfiguration()
                c.activates = true
                try Task.checkCancellation()
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: c)
                return true
            }
        }
        return await waitFrontmost(app.pid, timeout: 1.0)
    }

    public static func hide(_ app: AppInfo) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !Task.isCancelled else { return false }
        return running.hide()
    }

    static func waitFrontmost(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !Task.isCancelled else { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        return false
    }

    public enum QuitOutcome: Sendable {
        case quit
        /// Still running: a dialog (e.g. unsaved changes) is holding the quit up.
        case blocked(String)
        case stillRunning
    }

    public static func quit(_ app: AppInfo, force: Bool) async -> QuitOutcome {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return .quit }
        guard !Task.isCancelled else { return .stillRunning }
        _ = force ? running.forceTerminate() : running.terminate()
        let deadline = Date().addingTimeInterval(force ? 3 : 5)
        while Date() < deadline {
            guard !Task.isCancelled else { return .stillRunning }
            if running.isTerminated { return .quit }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let windows = AXElement.application(pid: app.pid).elements(kAXWindowsAttribute)
        for w in windows {
            if let sheet = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSheet" }) {
                return .blocked("a sheet in \"\(w.string(kAXTitleAttribute) ?? "untitled")\": \(Snapshotter.sheetHeading(sheet) ?? "")")
            }
            if let sub = w.subrole, sub == "AXDialog" || sub == "AXSystemDialog" {
                return .blocked("dialog \"\(w.string(kAXTitleAttribute) ?? Snapshotter.sheetHeading(w) ?? "")\"")
            }
        }
        return .stillRunning
    }
}

// MARK: - Windows

public struct WindowEntry: Sendable {
    public let index: Int
    public let element: AXElement
    public let title: String
    public let frame: CGRect?
    public let isMain: Bool
    public let isFocused: Bool
    public let isMinimized: Bool
    public let subrole: String?

    public var line: String {
        var s = "\(index). \"\(title)\""
        if let f = frame { s += " @\(f.minX.safeInt),\(f.minY.safeInt) \(f.width.safeInt)x\(f.height.safeInt)" }
        var flags: [String] = []
        if isFocused { flags.append("focused") }
        if isMain { flags.append("main") }
        if isMinimized { flags.append("minimized") }
        if let sub = subrole, sub != "AXStandardWindow", !isMinimized { flags.append(Snapshot.shortRole("AXWindow", subrole: sub)) }
        return flags.isEmpty ? s : s + " [" + flags.joined(separator: ", ") + "]"
    }
}

public enum WindowControl {
    public static func windows(of app: AppInfo) -> [WindowEntry] {
        let appEl = AXElement.application(pid: app.pid)
        let focused = appEl.element(kAXFocusedWindowAttribute)
        return appEl.elements(kAXWindowsAttribute).enumerated().map { i, w in
            let v = w.read(["AXTitle", "AXPosition", "AXSize", "AXMain", "AXMinimized", "AXSubrole"]) ?? [:]
            return WindowEntry(index: i + 1, element: w, title: v["AXTitle"] as? String ?? "",
                               frame: frame(position: v["AXPosition"], size: v["AXSize"]),
                               isMain: v["AXMain"] as? Bool ?? false, isFocused: w == focused,
                               isMinimized: v["AXMinimized"] as? Bool ?? false, subrole: v["AXSubrole"] as? String)
        }
    }

    /// Picks a window by 1-based index or case-insensitive title substring; default: focused, then main, then first.
    public static func find(_ app: AppInfo, _ selector: String?) -> WindowEntry? {
        pick(windows(of: app), selector)
    }

    /// A number picks by index when there's a window with that index; otherwise it's title text like any other
    /// ("2024" finds the window titled "Budget 2024" in an app with three windows).
    static func pick(_ all: [WindowEntry], _ selector: String?) -> WindowEntry? {
        guard let selector, !selector.isEmpty else { return all.first(where: \.isFocused) ?? all.first(where: \.isMain) ?? all.first }
        if let i = Int(selector), let w = all.first(where: { $0.index == i }) { return w }
        let q = selector.lowercased()
        return all.first { $0.title.lowercased() == q } ?? all.first { $0.title.lowercased().contains(q) }
    }

    /// Why a move or resize can't be done as asked, or nil: a size must be positive, and a move must leave part of
    /// the window (at least 40×40 points) on a display, or a person can't get it back.
    public static func frameRefusal(_ current: CGRect?, origin: CGPoint?, size: CGSize?, displays: [CGRect]) -> String? {
        if let size, size.width < 1 || size.height < 1 { return "width and height must be at least 1 point." }
        guard let origin else { return nil }
        let target = CGRect(origin: origin, size: size ?? current?.size ?? CGSize(width: 1, height: 1))
        let visible = displays.contains { d in
            let v = d.intersection(target)
            return !v.isNull && v.width >= min(40, target.width) && v.height >= min(40, target.height)
        }
        if visible { return nil }
        return "that would put the window off every display. Displays (screen points): "
            + displays.map { "\($0.minX.safeInt),\($0.minY.safeInt) \($0.width.safeInt)x\($0.height.safeInt)" }.joined(separator: "; ")
    }

    public static func focus(_ app: AppInfo, _ w: WindowEntry) async -> Bool {
        if w.isMinimized { w.element.set(kAXMinimizedAttribute, kCFBooleanFalse as Any) }
        w.element.perform(kAXRaiseAction)
        w.element.set(kAXMainAttribute, kCFBooleanTrue as Any)
        let front = await AppControl.activate(app)
        return front && (AXElement.application(pid: app.pid).element(kAXFocusedWindowAttribute) == w.element)
    }

    public static func setFrame(_ w: WindowEntry, origin: CGPoint?, size: CGSize?) -> CGRect? {
        if var p = origin, let v = AXValueCreate(.cgPoint, &p) { w.element.set(kAXPositionAttribute, v) }
        if var s = size, let v = AXValueCreate(.cgSize, &s) { w.element.set(kAXSizeAttribute, v) }
        let v = w.element.read(["AXPosition", "AXSize"]) ?? [:]
        return frame(position: v["AXPosition"], size: v["AXSize"])
    }

    public static func minimize(_ w: WindowEntry, _ on: Bool) -> Bool {
        w.element.set(kAXMinimizedAttribute, (on ? kCFBooleanTrue : kCFBooleanFalse) as Any) == .success
    }

    /// Presses the window's close button (the app may then ask to save: check blockers afterwards).
    public static func close(_ w: WindowEntry) -> Bool {
        guard let button = w.element.element(kAXCloseButtonAttribute) else { return false }
        return button.perform(kAXPressAction) == .success
    }
}
