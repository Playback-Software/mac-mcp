import AppKit
import ApplicationServices
import Foundation

/// A running app as the tools see it.
public struct AppInfo: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let isActive: Bool
    public let isHidden: Bool
    public let bundlePath: String?

    public init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        bundleID = app.bundleIdentifier
        isActive = app.isActive
        isHidden = app.isHidden
        bundlePath = app.bundleURL?.path
    }

    public var label: String { bundleID.map { "\(name) (\($0))" } ?? name }
}

public enum AppResolveError: Error, CustomStringConvertible {
    case notRunning(String, suggestions: [String])
    case ambiguous(String, matches: [String])

    public var description: String {
        switch self {
        case let .notRunning(query, suggestions):
            "No running app matches \"\(query)\"."
                + (suggestions.isEmpty ? "" : " Running apps include: \(suggestions.joined(separator: ", ")).")
                + " Use mac_app action=launch to start it."
        case let .ambiguous(query, matches):
            "\"\(query)\" matches several apps: \(matches.joined(separator: ", ")). Use the bundle ID."
        }
    }
}

public enum Apps {
    /// Regular (Dock) apps, refreshed. NSWorkspace's list only updates while a run loop runs; the agent runs one.
    public static func running() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(AppInfo.init)
    }

    public static func frontmost() -> AppInfo? { NSWorkspace.shared.frontmostApplication.map(AppInfo.init) }

    /// Finds a running app by bundle ID, exact name, or unique case-insensitive name prefix/substring.
    /// When several processes share a bundle ID (Chrome runs a headless twin), prefers the one owning on-screen windows.
    public static func resolve(_ query: String) throws -> AppInfo {
        let all = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let q = query.lowercased()
        var candidates = all.filter { $0.bundleIdentifier?.lowercased() == q }
        if candidates.isEmpty { candidates = all.filter { $0.localizedName?.lowercased() == q } }
        if candidates.isEmpty {
            candidates = all.filter { $0.activationPolicy == .regular && ($0.localizedName?.lowercased().hasPrefix(q) ?? false) }
        }
        if candidates.isEmpty {
            candidates = all.filter { $0.activationPolicy == .regular && ($0.localizedName?.lowercased().contains(q) ?? false) }
        }
        guard !candidates.isEmpty else {
            throw AppResolveError.notRunning(query, suggestions: running().map(\.name).sorted().prefix(12).map { $0 })
        }
        if Set(candidates.compactMap(\.bundleIdentifier)).count > 1 {
            throw AppResolveError.ambiguous(query, matches: candidates.map { AppInfo($0).label })
        }
        // "Safari" means the person's Safari: the automation copy that web_* drives is only used if it's all there is.
        let own = candidates.filter { !isAutomationSession($0.processIdentifier) }
        if !own.isEmpty { candidates = own }
        let withWindows = Set(WindowServer.onScreenWindows().map(\.pid))
        let best = candidates.first { withWindows.contains($0.processIdentifier) }
            ?? candidates.first { $0.activationPolicy == .regular }
            ?? candidates[0]
        return AppInfo(best)
    }

    /// Whether a process is a WebDriver automation session (Safari started with `--automation`, as Safari's MCP
    /// server and safaridriver do). Read from the process's arguments.
    public static func isAutomationSession(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        // argc, then the executable path and NUL-separated arguments; a plain byte search is enough here.
        return buffer.prefix(size).split(separator: 0).contains { $0.elementsEqual("--automation".utf8) }
    }

    /// App bundle URL for launching: bundle ID, or an app name looked up via Launch Services and /Applications.
    public static func bundleURL(for query: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) { return url }
        // A name, never a path: "../../Users/x/Downloads/Thing" must not reach a bundle outside the app folders.
        guard !query.contains("/"), query != ".", query != ".." else { return nil }
        let fm = FileManager.default
        let name = query.hasSuffix(".app") ? query : query + ".app"
        if let running = try? resolve(query), let path = running.bundlePath { return URL(fileURLWithPath: path) }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"] {
            let path = dir + "/" + name
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            // Case-insensitive match ("textedit" → TextEdit.app).
            if let match = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.lowercased() == name.lowercased() }) {
                return URL(fileURLWithPath: dir + "/" + match)
            }
        }
        return nil
    }
}

/// Electron and Chromium build their accessibility trees lazily and hide them unless asked. MacMCP asks once per
/// process and keeps the setting, then waits for the tree to grow before the first snapshot (VS Code went from 13
/// to 1,586 nodes about 2 s after enabling in the Phase 0b spike).
public actor AccessibilityEnabler {
    public static let shared = AccessibilityEnabler()
    private var enabled: Set<pid_t> = []

    public enum Engine: String, Sendable { case electron, chromium }

    public static func engine(bundlePath: String?) -> Engine? {
        guard let bundlePath else { return nil }
        let fm = FileManager.default
        let frameworks = bundlePath + "/Contents/Frameworks/"
        if fm.fileExists(atPath: frameworks + "Electron Framework.framework") { return .electron }
        if let items = try? fm.contentsOfDirectory(atPath: frameworks),
           items.contains(where: { $0.hasSuffix(" Framework.framework") && ($0.contains("Chrome") || $0.contains("Chromium")
               || $0.contains("Edge") || $0.contains("Brave") || $0.contains("Arc") || $0.contains("Vivaldi") || $0.contains("Opera")) }) {
            return .chromium
        }
        return nil
    }

    /// Enables the full tree if this app needs it. Returns true when it was enabled just now (callers should wait for
    /// the tree to settle before reading).
    public func ensureEnabled(_ app: AppInfo) -> Bool {
        guard !enabled.contains(app.pid), let engine = Self.engine(bundlePath: app.bundlePath) else { return false }
        let element = AXElement.application(pid: app.pid)
        switch engine {
        case .electron:
            element.set("AXManualAccessibility", kCFBooleanTrue as Any)
        case .chromium:
            element.set("AXEnhancedUserInterface", kCFBooleanTrue as Any)
        }
        enabled.insert(app.pid)
        return true
    }
}
