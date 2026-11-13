import Foundation
import MacMCPCore

/// Only snapshots returned on this connection can be used as a baseline. Relay-supplied session labels cannot
/// grant access to another connection's retained screen content. Storage is bounded across all clients.
actor SnapshotHistory {
    static let shared = SnapshotHistory()
    struct View: Sendable {
        let result: SnapshotResult
        let request: SnapshotRequest
    }
    private var views: [Int: (owner: String, view: View)] = [:]
    private var order: [Int] = []

    func remember(_ result: SnapshotResult, request: SnapshotRequest, owner: String) {
        guard result.snapshot > 0 else { return }
        views[result.snapshot] = (owner, View(result: result, request: request))
        order.append(result.snapshot)
        while order.count > 64 { views[order.removeFirst()] = nil }
    }

    func baseline(_ id: Int, owner: String) -> View? {
        guard let entry = views[id], entry.owner == owner else { return nil }
        return entry.view
    }

    static func compatible(_ before: View, after: SnapshotResult, request: SnapshotRequest) -> Bool {
        before.result.app.pid == after.app.pid && before.result.app.bundleID == after.app.bundleID && before.result.root == after.root
            && before.result.windowTitle == after.windowTitle && before.result.blockers == after.blockers
            && before.request.scope == request.scope && before.request.query == request.query
            && before.request.includeText == request.includeText && before.request.includeOffscreen == request.includeOffscreen
    }

    static func render(_ before: View, after: SnapshotResult, request: SnapshotRequest) -> (text: String, shown: [Row]) {
        guard compatible(before, after: after, request: request) else {
            return ("Snapshot context changed; current state:\n" + after.text, after.shownRows)
        }
        let diff = Diff.compute(before: before.result.rows, after: after.rows, maxLines: 200,
                                showDisappeared: after.stats.textComplete)
        let budget = max(200, min(request.maxTokens, 20_000)) * 4
        var lines: [String] = [], bytes = 0
        for line in diff.lines {
            guard bytes + line.utf8.count <= budget else { break }
            lines.append(line); bytes += line.utf8.count + 1
        }
        let shownRefs = Set(diff.refs.prefix(lines.count))
        let shown = after.rows.filter { $0.ref.map(shownRefs.contains) ?? false }
        if lines.count < diff.lines.count { lines.append("… changes omitted; narrow query= or take a full snapshot") }
        if lines.isEmpty { lines.append("changes: none observed") }
        if !after.stats.textComplete { lines.append("… incomplete read: disappeared rows are not reported") }
        return (Untrusted.wrap(lines: after.headerLines(showing: shown)
            + ["changes since s\(before.result.snapshot):"] + lines)
            + after.notes.filter { !$0.contains("more rows not shown:") }.map { "\n… " + $0 }.joined(), shown)
    }
}
