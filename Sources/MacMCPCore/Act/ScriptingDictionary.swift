import Carbon
import Foundation

/// Reads installed terminology, never compiles or runs a script or asks for Automation consent.
public enum ScriptingDictionary {
    public static func read(bundle: URL, maxEntries: Int = 100) throws -> String {
        var definition: Unmanaged<CFData>?
        guard OSACopyScriptingDefinitionFromURL(bundle as CFURL, 0, &definition) == noErr,
              let data = definition?.takeRetainedValue() as Data? else {
            throw ActionError("This app does not expose a readable scripting dictionary.")
        }
        return try summarize(data, maxEntries: maxEntries)
    }

    public static func summarize(_ data: Data, maxEntries: Int = 100) throws -> String {
        guard data.count <= 2_000_000, let source = String(data: data, encoding: .utf8),
              !source.contains("\0"), !source.contains("<!ENTITY") else {
            throw ActionError("The scripting dictionary is oversized, uses an unsupported encoding or contains entity declarations.")
        }
        let document = try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever)
        guard let root = document.rootElement(), root.name == "dictionary" else {
            throw ActionError("The app did not return a scripting dictionary.")
        }
        var lines: [String] = [], total = 0
        let limit = min(200, max(1, maxEntries))
        func name(_ element: XMLElement, _ key: String) -> String {
            String((element.attribute(forName: key)?.stringValue ?? "").prefix(120))
                .components(separatedBy: .newlines).joined(separator: " ")
        }
        for suite in root.elements(forName: "suite").prefix(100) {
            for entry in (suite.children ?? []).compactMap({ $0 as? XMLElement }) {
                guard ["command", "class", "enumeration"].contains(entry.name ?? "") else { continue }
                total += 1
                guard lines.count < limit else { continue }
                var line = "\(entry.name ?? "") \(name(entry, "name"))"
                let description = name(entry, "description")
                if !description.isEmpty { line += ": " + description }
                let members = (entry.children ?? []).compactMap { $0 as? XMLElement }
                    .filter { ["parameter", "property"].contains($0.name ?? "") }.prefix(12)
                    .map { "\(name($0, "name")): \(name($0, "type"))" }
                if !members.isEmpty { line += " (" + members.joined(separator: ", ") + ")" }
                lines.append(line)
            }
        }
        if total > lines.count { lines.append("… \(total - lines.count) more entries") }
        let output = lines.isEmpty ? "No commands or classes listed." : lines.joined(separator: "\n")
        return output.count > 12_000 ? String(output.prefix(12_000)) + "\n… dictionary output capped" : output
    }
}
