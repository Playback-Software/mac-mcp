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

        let focused = rows.indices.filter { rows[$0].states.contains("focused") || (focusRef != nil && rows[$0].ref == focusRef) }
        var neighbours = Set<Int>()
        for i in focused {
            neighbours.formUnion(max(0, i - 1)...min(rows.count - 1, i + 1))
        }
        let controlCost = rows.indices.filter { rows[$0].kind == .interactive }.reduce(0) { $0 + costs[$1] }
        let runs = controlCost > budget ? repeatedRuns(rows, protected: neighbours) : []
        var collapsed = Set<Int>()
        var runForRow: [Int: Int] = [:]
        for (id, run) in runs.enumerated() {
            collapsed.formUnion(run.hidden)
            for i in run.range { runForRow[i] = id }
        }

        func kind(_ i: Int) -> Int {
            switch rows[i].kind {
            case .interactive: 0
            case .context: 1
            case .text: 2
            }
        }
        var positions = Array(repeating: [Int](), count: 3)
        for i in rows.indices where !collapsed.contains(i) { positions[kind(i)].append(i) }
        var edgeDistance = Array(repeating: 0, count: rows.count)
        for indices in positions {
            for (offset, i) in indices.enumerated() { edgeDistance[i] = min(offset, indices.count - 1 - offset) }
        }
        let focusSet = Set(focused)
        func priority(_ i: Int) -> Int { focusSet.contains(i) ? 0 : neighbours.contains(i) ? 1 : 2 }
        let candidates = rows.indices.filter { !collapsed.contains($0) }.sorted { a, b in
            if kind(a) != kind(b) { return kind(a) < kind(b) }
            if priority(a) != priority(b) { return priority(a) < priority(b) }
            if edgeDistance[a] != edgeDistance[b] { return edgeDistance[a] < edgeDistance[b] }
            return a < b
        }

        var shown = Set<Int>()
        var activeRuns = Set<Int>()
        var used = 0
        for i in candidates {
            let run = runForRow[i]
            let summaryCost = run.flatMap { activeRuns.contains($0) ? nil : runs[$0].cost } ?? 0
            let cost = costs[i] + summaryCost
            guard cost <= budget - used else { continue }
            shown.insert(i)
            used += cost
            if let run { activeRuns.insert(run) }
        }
        var summaries: [Int: String] = [:]
        for id in activeRuns {
            for (index, line) in runs[id].summaries { summaries[index] = line }
        }
        var output: [String] = []
        for i in rows.indices {
            if let summary = summaries[i] { output.append(summary) }
            if shown.contains(i) { output.append(lines[i]) }
        }
        let shownRows = rows.indices.filter { shown.contains($0) }.map { rows[$0] }
        return Rendering(text: output.joined(separator: "\n"), omitted: rows.count - shownRows.count, shownRows: shownRows)
    }

    private struct RepeatedRun {
        var range: Range<Int>
        var hidden: Set<Int>
        var summaries: [(Int, String)]
        var cost: Int { summaries.reduce(0) { $0 + $1.1.count + 1 } }
    }

    /// A row and its interactive children form one item. Only matching sibling shapes are folded.
    private static func repeatedRuns(_ rows: [Row], protected: Set<Int>) -> [RepeatedRun] {
        var ends = Array(repeating: rows.count, count: rows.count)
        var stack: [Int] = []
        for i in rows.indices {
            while let last = stack.last, rows[last].depth >= rows[i].depth { ends[stack.removeLast()] = i }
            stack.append(i)
        }
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
                  rows[next].refScope == rows[i].refScope, shape(next..<ends[next]) == signature {
                items.append(next..<ends[next])
                next = ends[next]
            }
            i = next
            guard items.count >= 6 else { continue }
            var keep = Set([0, 1, 2, items.count - 1])
            for (index, item) in items.enumerated() where item.contains(where: { protected.contains($0) }) {
                keep.formUnion(max(0, index - 1)...min(items.count - 1, index + 1))
            }
            var hidden = Set<Int>()
            var summaries: [(Int, String)] = []
            var start = 0
            while start < items.count {
                if keep.contains(start) { start += 1; continue }
                var end = start + 1
                while end < items.count, !keep.contains(end) { end += 1 }
                hidden.formUnion(items[start].lowerBound..<items[end - 1].upperBound)
                let line = String(repeating: " ", count: min(rows[first.lowerBound].depth, 8))
                    + "… \(end - start) more rows like this (use query= or scroll)"
                summaries.append((items[start].lowerBound, line))
                start = end
            }
            if !hidden.isEmpty { runs.append(RepeatedRun(range: first.lowerBound..<next, hidden: hidden, summaries: summaries)) }
        }
        return runs
    }
}
