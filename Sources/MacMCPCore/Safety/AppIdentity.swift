import AppKit
import Foundation

/// Every name a policy entry might use for one app: its bundle ID, its bundle and display names (localized too) and
/// its file name. Policy lists are written by people, as either "Terminal" or "com.apple.Terminal"; matching only the
/// string an agent passed let a deny entry written one way miss a launch written the other.
public struct AppIdentity: Sendable, Equatable {
    public var bundleID: String?
    /// Display first: the name refusals show.
    public var names: [String]

    public init(bundleID: String?, names: [String]) {
        self.bundleID = bundleID
        var seen = Set<String>()
        self.names = names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The app at a bundle URL, named every way its bundle says.
    public init(bundleURL url: URL) {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let localized = bundle?.localizedInfoDictionary ?? [:]
        let file = url.deletingPathExtension().lastPathComponent
        let display = FileManager.default.displayName(atPath: url.path)
        let names = [localized["CFBundleDisplayName"], localized["CFBundleName"], info["CFBundleDisplayName"],
                     info["CFBundleName"]].compactMap { $0 as? String }
            + [file, display.hasSuffix(".app") ? String(display.dropLast(4)) : display]
        self.init(bundleID: bundle?.bundleIdentifier, names: names)
    }

    /// An app known by bundle ID and/or name (a running app, a Dock tile), widened with the names of its installed
    /// bundle when the bundle ID finds one.
    public static func of(bundleID: String?, name: String?) -> AppIdentity {
        let installed = bundleID.flatMap { NamesCache.shared.names(for: $0) } ?? []
        return AppIdentity(bundleID: bundleID, names: [name].compactMap { $0 } + installed)
    }

    /// Lowercased, for matching against policy entries.
    public var identifiers: Set<String> {
        Set(([bundleID].compactMap { $0 } + names).map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
    }

    public var label: String { names.first ?? bundleID ?? "this app" }

    /// Bundle names per bundle ID: `permits` runs for every app in a list, and Launch Services lookups aren't free.
    final class NamesCache: @unchecked Sendable {
        static let shared = NamesCache()
        private let lock = NSLock()
        private var cache: [String: [String]] = [:]

        func names(for bundleID: String) -> [String] {
            if let hit = lock.withLock({ cache[bundleID] }) { return hit }
            let names = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { AppIdentity(bundleURL: $0).names } ?? []
            lock.withLock { cache[bundleID] = names }
            return names
        }
    }
}
