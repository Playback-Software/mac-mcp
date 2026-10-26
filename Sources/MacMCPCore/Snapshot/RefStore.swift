import Foundation

/// Hands out element refs (`e12`) and keeps them stable across snapshots.
///
/// The same UI element keeps its ref in later snapshots, matched first by accessibility element identity (CFEqual),
/// then by an unambiguous fingerprint within the same window/sheet/menu bar. Stable refs make diffs readable and let an
/// agent keep using a ref after unrelated UI changes. A ref whose element is gone resolves to nil and the action
/// tools tell the agent to take a new snapshot.
public actor RefStore {
    public static let shared = RefStore()

    public struct Entry: Sendable {
        public let ref: String
        public var element: AXElement?
        public var fingerprint: String
        public var row: Row
        public var pid: pid_t
        public var snapshot: Int
    }

    private var entries: [String: Entry] = [:]
    private var byElement: [AXElement: String] = [:]
    private struct Fingerprint: Hashable {
        let pid: pid_t
        let scope: AXElement?
        let identity: String
    }
    private var byFingerprint: [Fingerprint: Set<String>] = [:]

    private func key(_ row: Row, pid: pid_t) -> Fingerprint {
        Fingerprint(pid: pid, scope: row.refScope, identity: row.fingerprint)
    }

    private func unindex(_ entry: Entry) {
        let k = key(entry.row, pid: entry.pid)
        byFingerprint[k]?.remove(entry.ref)
        if byFingerprint[k]?.isEmpty == true { byFingerprint[k] = nil }
    }
    private var nextRef = 1
    private var nextSnapshot = 1
    /// Rows of recent snapshots, kept for diffs.
    private var recent: [Int: [Row]] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 20_000) { self.maxEntries = maxEntries }

    /// Assigns refs to the interactive rows in place and records the snapshot. Returns the snapshot number.
    public func record(_ rows: inout [Row], pid: pid_t) -> Int {
        let snapshot = nextSnapshot
        nextSnapshot += 1
        var used: Set<String> = []
        let counts = Dictionary(grouping: rows.filter { $0.kind == .interactive }, by: { key($0, pid: pid) }).mapValues(\.count)
        for i in rows.indices where rows[i].kind == .interactive {
            let k = key(rows[i], pid: pid)
            var ref: String?
            if let el = rows[i].element, let r = byElement[el], entries[r]?.pid == pid,
               entries[r]?.row.role == rows[i].role, entries[r]?.row.refScope == rows[i].refScope, !used.contains(r) {
                ref = r
            } else if counts[k] == 1, (rows[i].refScope != nil || rows[i].element == nil),
                      let candidates = byFingerprint[k], candidates.count == 1,
                      let r = candidates.first, !used.contains(r) {
                ref = r
            }
            let assigned = ref ?? { defer { nextRef += 1 }; return "e\(nextRef)" }()
            used.insert(assigned)
            rows[i].ref = assigned
            if let old = entries[assigned] {
                unindex(old)
                if let el = old.element, el != rows[i].element, byElement[el] == assigned { byElement[el] = nil }
            }
            entries[assigned] = Entry(ref: assigned, element: rows[i].element, fingerprint: rows[i].fingerprint,
                                      row: rows[i], pid: pid, snapshot: snapshot)
            if let el = rows[i].element { byElement[el] = assigned }
            byFingerprint[k, default: []].insert(assigned)
        }
        recent[snapshot] = rows
        recent = recent.filter { $0.key > snapshot - 10 }
        if entries.count > maxEntries { evict(keepingFrom: snapshot - 5) }
        return snapshot
    }

    public func entry(_ ref: String) -> Entry? { entries[ref] }

    public func rows(ofSnapshot snapshot: Int) -> [Row]? { recent[snapshot] }

    /// The ref currently assigned to an element, if any.
    public func ref(for element: AXElement) -> String? { byElement[element] }

    private func evict(keepingFrom snapshot: Int) {
        for (ref, e) in entries where e.snapshot < snapshot {
            unindex(e)
            entries[ref] = nil
            if let el = e.element, byElement[el] == ref { byElement[el] = nil }
        }
    }
}
