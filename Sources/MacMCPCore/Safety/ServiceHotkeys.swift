import AppKit
import Foundation
import SQLite3

/// Services bypass both app routing and shortcuts.allowed. Discover their key equivalents without launching any
/// provider. The cache is short-lived; discovery runs on a route guard's GCD worker, never the cooperative pool.
enum ServiceHotkeys {
    struct Snapshot {
        var keys: [KeySpec]
        var complete: Bool
        var expires: TimeInterval
    }
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Snapshot?
        func get(now: TimeInterval, load: () -> Snapshot) -> Snapshot {
            lock.withLock {
                if let cached, cached.expires > now { return cached }
                let result = load()
                cached = result
                return result
            }
        }
    }
    private static let cache = Cache()
    static let keyRefusal = "Refused: this key runs a Service, Quick Action or global Shortcut. Use mac_shortcut with shortcuts.allowed instead."

    static let incompleteRefusal = "Refused: this key may run a Service, and MacMCP couldn't list every installed Service. "
        + "Use mac_menu, or mac_shortcut with shortcuts.allowed."

    static func refusal(_ key: KeySpec) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = cache.get(now: now) {
            let status = UserDefaults(suiteName: "pbs")?.persistentDomain(forName: "pbs")?["NSServicesStatus"] as? [String: Any] ?? [:]
            var (keys, complete) = inventory(status: status, scan: serviceDeclarations(deadline: now + 0.8), registered: registeredServices())
            for domain in ["com.apple.shortcuts", "com.apple.WorkflowKit", "com.apple.siri.shortcuts"] {
                keys += shortcutEquivalents(UserDefaults(suiteName: domain)?.persistentDomain(forName: domain) ?? [:])
            }
            keys += shortcutDatabaseKeys()
            return Snapshot(keys: keys, complete: complete, expires: now + 2)
        }
        return refusal(key, in: snapshot)
    }

    /// What the scan found plus what macOS registered. What macOS registered only adds keys: its cache is a file in
    /// the person's Caches folder, so it can't vouch that nothing is missing, and a scan that ran out of time leaves
    /// the inventory incomplete whatever it says.
    static func inventory(status: [String: Any], scan: (entries: [[String: Any]], complete: Bool),
                          registered: [[String: Any]]) -> (keys: [KeySpec], complete: Bool) {
        (serviceKeys(status: status, services: scan.entries + registered, complete: scan.complete), scan.complete)
    }

    static func refusal(_ key: KeySpec, in snapshot: Snapshot) -> String? {
        if snapshot.keys.contains(where: { matches($0, key) }) { return keyRefusal }
        return !snapshot.complete && couldBeServiceKey(key) ? incompleteRefusal : nil
    }

    /// With the inventory incomplete, a Service nobody found could own any chord a provider may declare: ⌘ with ⇧
    /// (a Service's key equivalent without ⇧ is rare, and ⌘ alone belongs to the app's menus). The caller still lets the
    /// frontmost app's own enabled command take the chord, so ⇧⌘Z in an editor keeps working.
    static func couldBeServiceKey(_ key: KeySpec) -> Bool {
        key.flags.contains([.maskCommand, .maskShift])
    }

    /// A scan cut short may have missed a provider: it adds the keys macOS's own Services declare, and the caller
    /// refuses the chords an unknown Service could use (`couldBeServiceKey`), rather than refusing every key.
    static func serviceKeys(status: [String: Any], services: [[String: Any]], complete: Bool) -> [KeySpec] {
        equivalents(status: status, services: services) + (complete ? [] : knownDefaults)
    }

    /// The key equivalents macOS's own Services declare (Terminal's man pages, Safari's search, Spotlight, Stickies,
    /// Script Editor, Bluetooth File Exchange, Chinese text conversion), whether or not they are enabled.
    static let knownDefaults: [KeySpec] = ["M", "A", "L", "F", "Y", "*", "B", "$^@C", "$^~@C"].compactMap(equivalent)

    static func matches(_ a: KeySpec, _ b: KeySpec) -> Bool {
        a.key == b.key && a.flags.intersection(OpenRoutes.modifierMask) == b.flags.intersection(OpenRoutes.modifierMask)
    }

    /// Cocoa key equivalents use @=command, ^=control, ~=option, $=shift. Services imply command when no
    /// modifier prefix is present, and an uppercase character implies shift (Terminal's default is "M").
    static func equivalent(_ value: String) -> KeySpec? {
        guard !value.isEmpty else { return nil }
        var flags: CGEventFlags = [], text = value[...], explicit = false
        let symbols: [Character: CGEventFlags] = ["@": .maskCommand, "^": .maskControl, "~": .maskAlternate, "$": .maskShift]
        while let first = text.first, let modifier = symbols[first] {
            explicit = true
            flags.insert(modifier)
            text.removeFirst()
        }
        guard text.count == 1 else { return nil }
        var char = String(text)
        if !explicit { flags.insert(.maskCommand) }
        if char != char.lowercased() { flags.insert(.maskShift) }
        // A shifted symbol is its key with shift on a US layout (Script Editor's ⌘* is ⇧⌘8).
        let shifted: [String: String] = ["!": "1", "#": "3", "%": "5", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
                                         "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/"]
        if let base = shifted[char] { char = base; flags.insert(.maskShift) }
        let names = [" ": "space", "\r": "return", "\t": "tab", "\u{1b}": "esc"]
        guard let parsed = try? KeySpec.parse(names[char] ?? char.lowercased()) else { return nil }
        return KeySpec(key: parsed.key, flags: flags.union(parsed.flags))
    }

    static func enabled(_ entry: [String: Any]) -> Bool {
        if let enabled = entry["enabled"] as? NSNumber, !enabled.boolValue { return false }
        if let modes = entry["presentation_modes"] as? [String: Any],
           ["ServicesMenu", "ContextMenu"].allSatisfy({ (modes[$0] as? NSNumber)?.boolValue == false }) { return false }
        return !(["enabled_services_menu", "enabled_context_menu"].allSatisfy { (entry[$0] as? NSNumber)?.boolValue == false })
    }

    static func equivalents(status: [String: Any], services: [[String: Any]]) -> [KeySpec] {
        let overrides = status.compactMap { key, value -> (String, [String: Any])? in
            (value as? [String: Any]).map { (key, $0) }
        }
        var result = overrides.filter { enabled($0.1) }.compactMap { ($0.1["key_equivalent"] as? String).flatMap(equivalent) }
        for service in services {
            let titles = Array((service["NSMenuItem"] as? [String: String] ?? [:]).values)
            let message = service["NSMessage"] as? String
            let matching = overrides.filter { key, _ in
                let parts = key.components(separatedBy: " - ")
                return !titles.isEmpty ? titles.contains(where: parts.contains)
                    : message.map { !$0.isEmpty && parts.contains($0) } == true
            }
            // A configured equivalent (including an empty string) replaces the declared default.
            if matching.contains(where: { $0.1["key_equivalent"] != nil }) { continue }
            if !matching.isEmpty, matching.allSatisfy({ !enabled($0.1) }) { continue }
            result += (service["NSKeyEquivalent"] as? [String: String] ?? [:]).values.compactMap(equivalent)
        }
        return result
    }

    static var servicesCachePath: String { ProtectedPaths.servicesCache(home: Paths.home) }

    /// The Services macOS has registered, from the cache `pbs` keeps (`ServicesCache`: each provider's NSServices, found
    /// wherever it sits, inside other bundles too), when it is the person's own plain file. It adds the keys of
    /// providers the scan didn't reach; it never stands for the scan (see `inventory`), and agents can't write it
    /// (`ProtectedPaths`). Read-only; `pbs` is never run.
    static func registeredServices(path: String = servicesCachePath) -> [[String: Any]] {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0, info.st_size <= 20_000_000,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cache = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [] }
        return registeredServices(cache) { FileManager.default.fileExists(atPath: $0) }
    }

    static func registeredServices(_ cache: [String: Any], exists: (String) -> Bool) -> [[String: Any]] {
        guard let providers = cache["ServicesCache"] as? [String: Any] else { return [] }
        // A provider that is gone keeps its keys until `pbs` notices; they stay refused only while its bundle does.
        return providers.sorted { $0.key < $1.key }.filter { exists($0.key) }
            .flatMap { ($0.value as? [String: Any])?["service_dicts"] as? [[String: Any]] ?? [] }
    }

    static let serviceRoots = ["/System/Library/Services", "/Library/Services", Paths.home + "/Library/Services",
                               "/System/Applications", "/System/Library/CoreServices", "/Applications", Paths.home + "/Applications"]

    /// Providers publish their services in their top-level Info.plist. Read the bundles in each root and in its
    /// folders (/Applications/Utilities), never inside a bundle or deeper: a large folder of documents can only cut
    /// the scan short, and a short scan falls back to `knownDefaults` rather than refusing every key.
    static func serviceDeclarations(roots: [String] = serviceRoots, deadline: TimeInterval) -> (entries: [[String: Any]], complete: Bool) {
        let bundles: Set<String> = ["app", "service", "workflow", "bundle"]
        var entries: [[String: Any]] = [], visited = 0
        func children(_ path: String) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? []).sorted { $0.path < $1.path }
        }
        for root in roots {
            var level = children(root), depth = 0
            while !level.isEmpty {
                var folders: [URL] = []
                for url in level {
                    visited += 1
                    guard visited <= 5000, ProcessInfo.processInfo.systemUptime < deadline else { return (entries, false) }
                    if bundles.contains(url.pathExtension.lowercased()) {
                        if let services = plist(url.appendingPathComponent("Contents/Info.plist"))?["NSServices"] as? [[String: Any]] {
                            entries += services
                        }
                    } else if depth == 0, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        folders.append(url)
                    }
                }
                guard depth == 0 else { break }
                depth += 1
                level = folders.flatMap { children($0.path) }
            }
        }
        return (entries, true)
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Decode explicit key-code/modifier records from preference dictionaries and Core Data blobs, without
    /// instantiating archived classes or interpreting workflow actions and names as input.
    static func shortcutEquivalents(_ value: Any, depth: Int = 0) -> [KeySpec] {
        guard depth < 12 else { return [] }
        if let data = value as? Data, data.count <= 1_000_000,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return shortcutEquivalents(plist, depth: depth + 1)
        }
        if let list = value as? [Any] { return list.prefix(2000).flatMap { shortcutEquivalents($0, depth: depth + 1) } }
        guard let dict = value as? [String: Any] else { return [] }
        let code = dict.first { $0.key.lowercased().hasSuffix("keycode") }?.value as? NSNumber
        let modifiers = dict.first { $0.key.lowercased().hasSuffix("modifierflags") }?.value as? NSNumber
        if let code, let modifiers, (0...255).contains(code.intValue) {
            return [KeySpec(key: CGKeyCode(code.intValue), flags: CGEventFlags(rawValue: modifiers.uint64Value))]
        }
        return dict.values.prefix(2000).flatMap { shortcutEquivalents($0, depth: depth + 1) }
    }

    private static func shortcutDatabaseKeys() -> [KeySpec] {
        var result: [KeySpec] = []
        for path in [Paths.home + "/Library/Shortcuts/Shortcuts.sqlite",
                     Paths.home + "/Library/Group Containers/group.com.apple.shortcuts/Shortcuts.sqlite"] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 20)
            let stop = UnsafeMutablePointer<TimeInterval>.allocate(capacity: 1)
            stop.initialize(to: ProcessInfo.processInfo.systemUptime + 0.1)
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
            }, stop)
            defer { sqlite3_progress_handler(db, 0, nil, nil); stop.deinitialize(count: 1); stop.deallocate() }
            result += databaseKeys(db, deadline: stop.pointee)
        }
        return result
    }

    /// Read records stored directly or inside the Quick Action configuration. Discover only
    /// those columns; a schema we cannot read contributes no keys, and never causes execution of a workflow.
    static func databaseKeys(_ db: OpaquePointer?, deadline: TimeInterval) -> [KeySpec] {
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' LIMIT 100", -1, &schema, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(schema) }
        func identifier(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var result: [KeySpec] = []
        while ProcessInfo.processInfo.systemUptime < deadline, sqlite3_step(schema) == SQLITE_ROW {
            guard let text = sqlite3_column_text(schema, 0) else { continue }
            let table = String(cString: text), upper = table.uppercased()
            guard upper == "ZWORKFLOW" || upper.contains("QUICKACTION") || upper.contains("KEYBOARD") || upper.contains("HOTKEY") else { continue }
            var columns: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(" + identifier(table) + ")", -1, &columns, nil) == SQLITE_OK else { continue }
            var names: [String] = []
            while sqlite3_step(columns) == SQLITE_ROW, names.count < 200 {
                if let text = sqlite3_column_text(columns, 1) { names.append(String(cString: text)) }
            }
            sqlite3_finalize(columns)
            names = names.filter { name in
                let upper = name.uppercased()
                return upper.contains("KEYBOARD") || upper.contains("HOTKEY") || upper.contains("QUICKACTIONCONFIGURATION")
            }
            for name in names {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return result }
                var rows: OpaquePointer?
                let sql = "SELECT " + identifier(name) + " FROM " + identifier(table) + " WHERE " + identifier(name) + " IS NOT NULL LIMIT 2000"
                guard sqlite3_prepare_v2(db, sql, -1, &rows, nil) == SQLITE_OK else { continue }
                while ProcessInfo.processInfo.systemUptime < deadline, sqlite3_step(rows) == SQLITE_ROW {
                    let count = Int(sqlite3_column_bytes(rows, 0))
                    if count > 0, count <= 1_000_000, let bytes = sqlite3_column_blob(rows, 0) {
                        result += shortcutEquivalents(Data(bytes: bytes, count: count))
                    }
                }
                sqlite3_finalize(rows)
            }
        }
        return result
    }
}
