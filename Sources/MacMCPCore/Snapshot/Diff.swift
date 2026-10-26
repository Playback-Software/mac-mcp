import Foundation

/// What changed between two snapshots of the same UI. Refs are stable, so interactive elements are compared by
/// ref (appeared, disappeared, changed label/value/state); text has no identity and is compared as lines.
public enum Diff {
    public static func lines(before: [Row], after: [Row], maxLines: Int = 30) -> [String] {
        var out: [String] = []
        let beforeByRef = Dictionary(before.compactMap { r in r.ref.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let afterRefs = Set(after.compactMap(\.ref))

        for r in after {
            guard let ref = r.ref else { continue }
            guard let old = beforeByRef[ref] else { out.append("+ " + flat(r)); continue }
            var changes: [String] = []
            if old.label != r.label { changes.append("label \"\(old.label)\" → \"\(r.label)\"") }
            if old.value != r.value { changes.append("value \"\(old.value ?? "")\" → \"\(r.value ?? "")\"") }
            let added = r.states.filter { !old.states.contains($0) }, removed = old.states.filter { !r.states.contains($0) }
            if !added.isEmpty || !removed.isEmpty {
                changes.append("states " + (added.map { "+" + $0 } + removed.map { "-" + $0 }).joined(separator: " "))
            }
            if !changes.isEmpty { out.append("~ \(ref) \(r.role) \"\(r.label)\": " + changes.joined(separator: ", ")) }
        }
        for r in before where r.ref != nil && !afterRefs.contains(r.ref!) {
            out.append("- \(r.ref!) \(r.role) \"\(r.label)\"")
        }

        // Text and context rows: multiset difference of their rendered lines.
        var counts: [String: Int] = [:]
        for r in before where r.ref == nil { counts[flat(r), default: 0] += 1 }
        var appeared: [String] = []
        for r in after where r.ref == nil {
            let line = flat(r)
            if let c = counts[line], c > 0 { counts[line] = c - 1 } else { appeared.append(line) }
        }
        out += appeared.map { "+ " + $0 }
        out += counts.flatMap { line, c in Array(repeating: "- " + line, count: c) }.sorted()

        if out.count > maxLines {
            let extra = out.count - maxLines
            out = Array(out.prefix(maxLines)) + ["… \(extra) more changes (call mac_snapshot for the full state)"]
        }
        return out
    }

    static func flat(_ r: Row) -> String { r.render(frames: false).trimmingCharacters(in: .whitespaces) }
}
