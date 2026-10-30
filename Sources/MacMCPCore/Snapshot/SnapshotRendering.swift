import Foundation

extension Snapshot {
    public struct Rendering: Sendable {
        public let text: String
        public let omitted: Int
        public let shownRows: [Row]
    }

    /// Selects an overview without changing the full rows used for refs, queries and diffs.
    public static func renderOverview(_ rows: [Row], frames: Bool, maxTokens: Int, focusRef: String? = nil) -> Rendering {
        let budget = max(200, min(maxTokens, Int.max / 4)) * 4
        let lines = rows.map { $0.render(frames: frames) }
        let costs = lines.map { $0.count + 1 }
        if costs.reduce(0, +) <= budget {
            return Rendering(text: lines.joined(separator: "\n"), omitted: 0, shownRows: rows)
        }

        // Rendered depth omits unnamed containers. Keep both the subtree end and the nearest named container
        // in one stack pass; selecting a descendant also pays for its context, recursively.
        var ends = Array(repeating: rows.count, count: rows.count)
        var containers = Array<Int?>(repeating: nil, count: rows.count)
        var stack: [Int] = []
        for i in rows.indices {
            while let last = stack.last, rows[last].depth >= rows[i].depth { ends[stack.removeLast()] = i }
            containers[i] = stack.last.flatMap { rows[$0].kind == .context ? $0 : containers[$0] }
            stack.append(i)
        }
        let focused = Set(rows.indices.filter { rows[$0].states.contains("focused") || (focusRef != nil && rows[$0].ref == focusRef) })
        var neighbours = Set<Int>()
        for i in focused { neighbours.formUnion(max(0, i - 1)...min(rows.count - 1, i + 1)) }
        let controlCost = rows.indices.filter { rows[$0].kind == .interactive }.reduce(0) { $0 + costs[$1] }
        let runs = controlCost > budget ? repeatedRuns(rows, ends: ends, protected: neighbours) : []

        // A repeated item and its controls are atomic: a summary counts omitted items exactly, even when a
        // retained example doesn't fit. Other rows are individual units. Groups delimit summary wording.
        struct Unit {
            var range: Range<Int>
            var run: Int?
            var candidate: Bool
        }
        var units: [Unit] = []
        var unitForRow = Array(repeating: 0, count: rows.count)
        var runAt: [Int: Int] = [:]
        for (id, run) in runs.enumerated() { runAt[run.items[0].lowerBound] = id }
        var i = 0
        while i < rows.count {
            if let id = runAt[i] {
                for (item, range) in runs[id].items.enumerated() {
                    for row in range { unitForRow[row] = units.count }
                    units.append(Unit(range: range, run: id, candidate: runs[id].keep.contains(item)))
                }
                i = runs[id].items.last!.upperBound
            } else {
                unitForRow[i] = units.count
                units.append(Unit(range: i..<(i + 1), run: nil, candidate: true))
                i += 1
            }
        }
        var groupEnds = Array(repeating: units.count, count: units.count)
        let unitCosts = units.map { unit in unit.range.reduce(0) { $0 + costs[$1] } }
        for u in units.indices.reversed() where u + 1 < units.count {
            groupEnds[u] = units[u].run == units[u + 1].run ? groupEnds[u + 1] : u + 1
        }
        var selectedCounts = [0]
        for unit in units {
            selectedCounts.append(selectedCounts.last! + (unit.range.contains { rows[$0].states.contains("selected") } ? 1 : 0))
        }
        func kind(_ u: Int) -> Int {
            switch rows[units[u].range.lowerBound].kind {
            case .interactive: 0
            case .context: 1
            case .text: 2
            }
        }
        func priority(_ u: Int) -> Int {
            let range = units[u].range
            if range.contains(where: { focused.contains($0) }) { return 0 }
            if range.contains(where: { rows[$0].states.contains("selected") }) { return 1 }
            return range.contains(where: { neighbours.contains($0) }) ? 2 : 3
        }
        var positions = Array(repeating: [Int](), count: 3)
        for u in units.indices where units[u].candidate { positions[kind(u)].append(u) }
        var edgeDistance = Array(repeating: 0, count: units.count)
        for indices in positions {
            for (offset, u) in indices.enumerated() { edgeDistance[u] = min(offset, indices.count - 1 - offset) }
        }
        let candidates = units.indices.filter { units[$0].candidate }.sorted { a, b in
            if kind(a) != kind(b) { return kind(a) < kind(b) }
            if priority(a) != priority(b) { return priority(a) < priority(b) }
            if edgeDistance[a] != edgeDistance[b] { return edgeDistance[a] < edgeDistance[b] }
            return a < b
        }
        func withContainers(_ u: Int, in shown: Set<Int>, includeSelf: Bool = true) -> Set<Int> {
            var result = shown
            if includeSelf { result.insert(u) }
            var parent = containers[units[u].range.lowerBound]
            while let p = parent {
                result.insert(unitForRow[p])
                parent = containers[p]
            }
            return result
        }

        // Recompute gaps from the actual selection, never from the preliminary folding mask. Charge every
        // marker while selecting, so an interior cut cannot silently join distant rows or exceed the budget.
        func output(_ shown: Set<Int>, detailedRuns: Set<Int>, render: Bool = false) -> (lines: [String], cost: Int) {
            let detailed = detailedRuns.union(shown.compactMap { units[$0].run })
            var out: [String] = []
            var cost = 0
            func marker(_ line: String) {
                cost += line.count + 1
                if render { out.append(line) }
            }
            func gap(_ range: Range<Int>) {
                var start = range.lowerBound
                while start < range.upperBound {
                    var end = min(groupEnds[start], range.upperBound)
                    let folded = units[start].run.map { detailed.contains($0) } ?? false
                    if !folded {
                        while end < range.upperBound, !(units[end].run.map { detailed.contains($0) } ?? false) {
                            end = min(groupEnds[end], range.upperBound)
                        }
                    }
                    let depth = folded ? rows[units[start].range.lowerBound].depth : 0
                    let indent = String(repeating: " ", count: min(depth, 8))
                    if folded {
                        let selected = selectedCounts[end] - selectedCounts[start]
                        let hint = selected > 0 ? "\(selected) selected; use query= or scroll" : "use query= or scroll"
                        marker(indent + "… \(end - start) more rows like this (\(hint))")
                    } else {
                        let count = units[end - 1].range.upperBound - units[start].range.lowerBound
                        marker("… \(count) rows not shown")
                    }
                    start = end
                }
            }
            var next = 0
            for u in shown.sorted() {
                if next < u { gap(next..<u) }
                cost += unitCosts[u]
                if render { out += units[u].range.map { lines[$0] } }
                next = u + 1
            }
            if next < units.count { gap(next..<units.count) }
            return (out, cost)
        }
        var shown = Set<Int>()
        for u in candidates where !shown.contains(u) {
            let proposed = withContainers(u, in: shown)
            if output(proposed, detailedRuns: []).cost <= budget { shown = proposed }
        }
        // Even a run with no affordable example deserves a summary, with its named context when it has one.
        var detailedRuns = Set<Int>()
        for id in runs.indices where !shown.contains(where: { units[$0].run == id }) {
            let u = unitForRow[runs[id].items[0].lowerBound]
            let proposed = withContainers(u, in: shown, includeSelf: false)
            let detailed = detailedRuns.union([id])
            if output(proposed, detailedRuns: detailed).cost <= budget {
                shown = proposed
                detailedRuns = detailed
            }
        }
        let shownRows = shown.sorted().flatMap { units[$0].range.map { rows[$0] } }
        return Rendering(text: output(shown, detailedRuns: detailedRuns, render: true).lines.joined(separator: "\n"),
                         omitted: rows.count - shownRows.count, shownRows: shownRows)
    }

    private struct RepeatedRun {
        var items: [Range<Int>]
        var keep: Set<Int>
    }

    /// A row and its interactive children form one item. Only matching structural siblings are folded.
    private static func repeatedRuns(_ rows: [Row], ends: [Int], protected: Set<Int>) -> [RepeatedRun] {
        func shape(_ range: Range<Int>) -> [String] {
            range.map { i in
                let row = rows[i]
                let states = row.states.filter { $0 != "focused" && $0 != "selected" }.joined(separator: ",")
                return "\(row.kind)|\(row.role)|\(row.depth)|\(row.value != nil)|\(row.label.components(separatedBy: " | ").count)|\(states)"
            }
        }
        var runs: [RepeatedRun] = []
        var i = 0
        while i < rows.count {
            guard rows[i].role == "row" else { i += 1; continue }
            let first = i..<ends[i]
            let signature = shape(first)
            var items = [first]
            var next = first.upperBound
            while next < rows.count, rows[next].role == "row", rows[next].depth == rows[i].depth,
                  rows[next].refScope == rows[i].refScope, rows[next].parentPath == rows[i].parentPath,
                  shape(next..<ends[next]) == signature {
                items.append(next..<ends[next])
                next = ends[next]
            }
            i = next
            guard items.count >= 6 else { continue }
            var keep = Set([0, 1, 2, items.count - 1])
            for (index, item) in items.enumerated() where item.contains(where: { protected.contains($0) }) {
                keep.formUnion(max(0, index - 1)...min(items.count - 1, index + 1))
            }
            let selected = items.indices.filter { item in items[item].contains { rows[$0].states.contains("selected") } }
            keep.formUnion(selected.prefix(3))
            keep.formUnion(selected.suffix(3))
            runs.append(RepeatedRun(items: items, keep: keep))
        }
        return runs
    }
}
