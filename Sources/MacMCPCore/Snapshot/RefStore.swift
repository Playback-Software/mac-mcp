import Foundation

/// Hands out element refs (`e12`) and keeps them stable across snapshots.
///
/// The same UI element keeps its ref in later snapshots, matched first by accessibility element identity (CFEqual),
/// then by an unambiguous fingerprint within the same window/sheet/menu bar. Stable refs make diffs readable and let an
/// agent keep using a ref after unrelated UI changes. A ref whose element is gone resolves to nil and the action
/// tools tell the agent to take a new snapshot.
///
/// Identity alone isn't enough for list rows: a virtualised or re-sorted list (Finder's sort, a Mail refresh) reuses
/// the same AXRow object for different items, so "e10 Item 1" would later read "Item 7" under the same ref. Such a
/// row gets a new ref instead, unless a developer identifier (`AXIdentifier`) says it is still the same item, in which
/// case the text is display state (a clock, a progress figure) and the ref stays. For every ref, the store also
/// remembers the label the agent was last shown, so an action can refuse a ref whose element now reads differently
/// (`changeMessage`).
///
/// Ref and snapshot numbers come from `IDBlocks`, so they never repeat across agent restarts: relays keep their
/// clients' sessions through a restart, and a client's old `e1` must not resolve to a new incarnation's first ref.
public actor RefStore {
    public static let shared = RefStore(ids: .shared)

    /// What the agent last saw for a ref: the label (and developer identifier) as rendered to it.
    public struct Shown: Sendable, Equatable {
        public let label: String
        public let identifier: String?
        /// The label was the text beside the control (`Snapshot.associateLabels`), which the control doesn't carry
        /// itself: re-read on its own it is unnamed, and that isn't a change.
        public let labelFromNeighbor: Bool
        public init(label: String, identifier: String?, labelFromNeighbor: Bool = false) {
            self.label = label
            self.identifier = identifier
            self.labelFromNeighbor = labelFromNeighbor
        }
        public init(_ row: Row) { self.init(label: row.label, identifier: row.identifier, labelFromNeighbor: row.labelFromNeighbor) }
    }

    public struct Entry: Sendable {
        public let ref: String
        public var element: AXElement?
        public var fingerprint: String
        public var row: Row
        public var pid: pid_t
        public var snapshot: Int
        /// Set only when the ref is rendered in output the agent receives; nil for a ref it has never seen.
        public var shown: Shown?
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
    private var refs: IDCounter
    private var snapshots: IDCounter
    /// Rows of recent snapshots, kept for diffs.
    private var recent: [Int: [Row]] = [:]
    private let maxEntries: Int

    /// Blocks of 1000 refs and 100 snapshots: a block is written to disk once, and ids grow by that much per restart.
    public init(maxEntries: Int = 20_000, ids: IDBlocks = .ephemeral) {
        self.maxEntries = maxEntries
        refs = IDCounter(prefix: "e", blocks: ids, blockSize: 1000)
        snapshots = IDCounter(prefix: "s", blocks: ids, blockSize: 100)
    }

    /// Roles whose accessibility object is reused for different content, so identity doesn't carry a ref across a
    /// label change.
    static let reusedObjectRoles: Set<String> = ["row", "cell"]

    /// Assigns refs to the interactive rows in place and records the snapshot. Returns the snapshot number. Throws
    /// when a block of ids can't be recorded on disk (`IDBlocksError`): nothing is assigned then.
    public func record(_ rows: inout [Row], pid: pid_t) async throws -> Int {
        // Reserve before touching any state: the reservation suspends, and another snapshot may be recorded meanwhile.
        // Every interactive row may need a fresh ref, so enough are reserved for the worst case.
        while snapshots.blockNeeded() { snapshots.add(try await snapshots.reserveBlock()) }
        let interactive = rows.filter { $0.kind == .interactive }.count
        while refs.blockNeeded(for: interactive) { refs.add(try await refs.reserveBlock()) }
        let snapshot = snapshots.mintNumber()
        var used: Set<String> = []
        let counts = Dictionary(grouping: rows.filter { $0.kind == .interactive }, by: { key($0, pid: pid) }).mapValues(\.count)
        for i in rows.indices where rows[i].kind == .interactive {
            let k = key(rows[i], pid: pid)
            var ref: String?
            if let el = rows[i].element, let r = byElement[el], let old = entries[r], old.pid == pid,
               old.row.role == rows[i].role, old.row.refScope == rows[i].refScope, !used.contains(r),
               !(Self.reusedObjectRoles.contains(old.row.role) && old.row.label != rows[i].label
                 && !Self.sameIdentifiedItem(old.row, rows[i])) {
                ref = r
            } else if counts[k] == 1, (rows[i].refScope != nil || rows[i].element == nil),
                      let candidates = byFingerprint[k], candidates.count == 1,
                      let r = candidates.first, !used.contains(r) {
                ref = r
            }
            let assigned = ref ?? refs.mint()
            used.insert(assigned)
            rows[i].ref = assigned
            let old = entries[assigned]
            if let old {
                unindex(old)
                if let el = old.element, el != rows[i].element, byElement[el] == assigned { byElement[el] = nil }
            }
            entries[assigned] = Entry(ref: assigned, element: rows[i].element, fingerprint: rows[i].fingerprint,
                                      row: rows[i], pid: pid, snapshot: snapshot, shown: old?.shown)
            if let el = rows[i].element { byElement[el] = assigned }
            byFingerprint[k, default: []].insert(assigned)
        }
        recent[snapshot] = rows
        recent = recent.filter { $0.key > snapshot - 10 }
        if entries.count > maxEntries { evict(keepingFrom: snapshot - 5) }
        return snapshot
    }

    /// A row or cell whose developer identifier is meaningful and unchanged is the same item whatever its text says
    /// now: the text is display state (a clock, a progress figure), not a reused object showing another item.
    static func sameIdentifiedItem(_ old: Row, _ new: Row) -> Bool {
        guard reusedObjectRoles.contains(old.role), let id = old.identifier, Snapshot.meaningfulIdentifier(id) != nil else { return false }
        return new.identifier == id
    }

    /// Records that these rows were rendered to the agent, with the label and identifier they were rendered with.
    /// The rows are what was rendered, not the store's current entries: a snapshot recorded in between (an action's
    /// bookkeeping) may already hold a newer label the agent never saw.
    public func markShown(_ rows: some Sequence<Row>) {
        for row in rows {
            guard let r = row.ref, entries[r] != nil else { continue }
            entries[r]?.shown = Shown(row)
        }
    }

    public func entry(_ ref: String) -> Entry? { entries[ref] }

    public func rows(ofSnapshot snapshot: Int) -> [Row]? { recent[snapshot] }

    /// The ref currently assigned to an element, if any.
    public func ref(for element: AXElement) -> String? { byElement[element] }

    /// Why a ref has no entry: minted before the agent restarted, or never minted at all.
    public func missingMessage(_ ref: String) -> String {
        if refs.isFromEarlierIncarnation(ref) {
            return "Ref \(ref) is from before the agent restarted and no longer exists. Take a new mac_snapshot and use its refs."
        }
        return "Unknown ref \(ref). Refs come from mac_snapshot; take a snapshot first."
    }

    /// Why an action on `ref` should be refused because its element no longer reads as the agent last saw it, or
    /// nil. `label` and `identifier` are the element's current ones; `complete` says whether the read that produced
    /// them could vouch for them (a walk cut short inside the element, or a label source or identifier that failed
    /// to read, can lose a label or identifier without anything having changed, and then the identity is unknown
    /// rather than the same: `Row.identityUncertain`). Values of password fields are never echoed. An empty current
    /// label is accepted only from a complete read of a control the agent saw unnamed too, or named by the text
    /// beside it (`associateLabels`), which the control doesn't carry itself: an uncertain read that comes back
    /// empty says nothing, even when the agent saw the control unnamed, since a lost name reads the same way. A
    /// non-empty label that matches is accepted from an uncertain read: the read did deliver the name.
    public static func changeMessage(ref: String, role: String, shown: Shown?, label: String, identifier: String?,
                                     complete: Bool = true) -> String? {
        guard let shown else { return nil }   // never rendered to the agent: nothing it could have relied on
        let retake = "Take a new mac_snapshot."
        let uncertain = "\(ref) couldn't be fully re-read, so it may not be what was shown. \(retake)"
        if let was = shown.identifier {
            guard let now = identifier else {
                return complete ? "\(ref) is now a different element (its identifier is gone). \(retake)" : uncertain
            }
            if was != now { return "\(ref) is now a different element (its identifier changed). \(retake)" }
            if reusedObjectRoles.contains(role), Snapshot.meaningfulIdentifier(was) != nil { return nil }   // same item; its text is display state
        }
        if label.isEmpty, !complete { return uncertain }   // before equality: an empty, uncertain read proves nothing
        guard label != shown.label else { return nil }
        if role == "password" { return "\(ref) (password field) has changed since it was shown. \(retake)" }
        if label.isEmpty {
            if shown.labelFromNeighbor { return nil }
            return "\(ref) was \(Untrusted.inline(shown.label)) but now has no label. \(retake)"
        }
        if shown.label.isEmpty { return "\(ref) had no label but now reads \(Untrusted.inline(label)). \(retake)" }
        return "\(ref) was \(Untrusted.inline(shown.label)) but now reads \(Untrusted.inline(label)). \(retake)"
    }

    private func evict(keepingFrom snapshot: Int) {
        for (ref, e) in entries where e.snapshot < snapshot {
            unindex(e)
            entries[ref] = nil
            if let el = e.element, byElement[el] == ref { byElement[el] = nil }
        }
    }
}
