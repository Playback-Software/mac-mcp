import AppKit
import Foundation

/// What's on the clipboard, as far as deciding whether an agent may read or paste it.
public struct ClipboardInfo: Sendable, Equatable {
    public var types: [String]
    /// The bundle ID in `org.nspasteboard.source`, the app that says it wrote the contents.
    public var source: String?
    /// The source marker is present but couldn't be read without asking a person (macOS's paste prompt).
    public var sourceUnread: Bool
    public var changeCount: Int
    /// The files on it, when macOS lets MacMCP read them without asking a person; nil otherwise.
    public var fileURLs: [URL]?

    public init(types: [String], source: String? = nil, sourceUnread: Bool = false, changeCount: Int = 0, fileURLs: [URL]? = nil) {
        self.types = types
        self.source = source
        self.sourceUnread = sourceUnread
        self.changeCount = changeCount
        self.fileURLs = fileURLs
    }
}

/// Keeps what a person copied from password managers and denied apps away from agents, whether read directly
/// (mac_clipboard) or pasted into a document and read back. Uses the nspasteboard.org markers that 1Password, Apple
/// Passwords and other password managers set: concealed (a secret) and transient (meant to vanish), plus the source
/// app.
public enum ClipboardSafety {
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"
    public static let sourceType = "org.nspasteboard.source"

    /// Why the clipboard's contents mustn't reach an agent, read or pasted, or nil.
    public static func secretRefusal(_ info: ClipboardInfo, policy: Policy) -> String? {
        if info.types.contains(concealedType) || info.types.contains(transientType) {
            return "Refused: the clipboard holds something a password manager marked as secret (a copied password or "
                + "code). Agents can't read or paste it. To paste text, put it there first with mac_clipboard action=set."
        }
        if info.sourceUnread {
            return "Refused: the clipboard says which app it came from, and MacMCP can't check that app without a "
                + "person answering macOS's paste prompt. To paste text, put it there first with mac_clipboard action=set."
        }
        if let source = info.source, !source.isEmpty, source.lowercased() != Paths.bundleID.lowercased(),
           policy.refusal(bundleID: source, name: nil) != nil {
            let app = AppIdentity.of(bundleID: source, name: nil).label
            return "Refused: the clipboard was copied from \(app), which the policy denies (\(Policy.fileRef)). Agents "
                + "can't read or paste it. To paste text, put it there first with mac_clipboard action=set."
        }
        return nil
    }

    /// Why pasting now would leak something, or nil. Besides secrets: with clipboard_read off, pasting what a person
    /// copied into a document and taking a snapshot would read it anyway, so only what MacMCP put there may be pasted.
    public static func pasteRefusal(_ info: ClipboardInfo, policy: Policy, ownChangeCount: Int?) -> String? {
        if let secret = secretRefusal(info, policy: policy) { return secret }
        if !policy.clipboardRead, info.changeCount != ownChangeCount, !holdsFinderCopy(info), !info.types.isEmpty {
            return "Refused: clipboard reading is off (clipboard_read in \(Policy.fileRef)), and pasting what a person "
                + "copied would show it to you anyway. Put the text there with mac_clipboard action=set, then paste."
        }
        return nil
    }

    /// The general pasteboard now. Only the type list is read unless macOS allows silent reads: reading contents can
    /// raise the "paste from other apps" prompt, which nobody may be there to answer.
    @MainActor
    public static func current() -> ClipboardInfo {
        let pb = NSPasteboard.general
        let types = pb.types?.map(\.rawValue) ?? []
        var info = ClipboardInfo(types: types, changeCount: pb.changeCount)
        if types.contains(sourceType) {
            if pb.accessBehavior == .alwaysAllow { info.source = pb.string(forType: .init(sourceType)) } else { info.sourceUnread = true }
        }
        if pb.accessBehavior == .alwaysAllow, types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            // A file that no longer resolves makes them unknown, not an empty path.
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(OpenRoutes.resolved)
            info.fileURLs = urls.flatMap { $0.contains(nil) ? nil : $0.compactMap { $0 } }
        }
        return info
    }

    /// The source marker as well, for mac_clipboard get, which reads the contents (and so asks once) anyway.
    @MainActor
    public static func currentForReading() -> ClipboardInfo {
        var info = current()
        if info.sourceUnread {
            info.source = NSPasteboard.general.string(forType: .init(sourceType))
            info.sourceUnread = false
        }
        return info
    }

    /// The change count right after MacMCP last set the clipboard: until someone copies something else, pasting is
    /// pasting the agent's own text.
    public static var ownChangeCount: Int? { own.withLock { $0?.changeCount } }

    /// The text MacMCP last put there, so a paste into a file panel can be checked like typing it.
    public static func ownText(changeCount: Int) -> String? { own.withLock { $0?.changeCount == changeCount ? $0?.text : nil } }

    public static func noteOwnWrite(changeCount: Int, text: String) { own.withLock { $0 = (changeCount, text) } }

    private static let own = Locked<(changeCount: Int, text: String)?>(nil)

    /// Types Finder pastes as files: copied files and file promises. Anything else it pastes as a new clipping file.
    public static let fileTypes: Set<String> = [
        "public.file-url", "NSFilenamesPboardType", "com.apple.finder.noderef", "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type", "com.apple.NSFilePromiseItemMetaData", "NSPromiseContentsPboardType",
        "Apple files promise pasteboard type",
    ]

    public static func holdsFiles(_ info: ClipboardInfo) -> Bool { info.types.contains(where: fileTypes.contains) }

    /// Notes that Finder is about to copy `urls` (its selection, checked) at an agent's request, with the clipboard at
    /// `changeCount`. Finder's copy bumps the count once, so while it reads one more, the clipboard holds those files:
    /// a paste can be checked without reading it, which could raise macOS's paste prompt. Each file's identity (a file
    /// reference URL) is kept too: renamed or moved before the paste, Finder pastes it under its new name.
    public static func noteFinderCopy(_ urls: [URL], changeCount: Int) {
        let files = urls.map { CopiedFile(url: $0, reference: OpenRoutes.fileReference($0)) }
        finderCopied.withLock { $0 = (changeCount, files) }
    }

    struct CopiedFile {
        var url: URL
        /// nil when the file's identity couldn't be had when it was copied.
        var reference: NSURL?
    }

    /// Whether the clipboard holds what Finder copied at an agent's request.
    public static func holdsFinderCopy(_ info: ClipboardInfo) -> Bool { finderCopied(info) != nil }

    /// The files Finder copied at an agent's request, while the clipboard still holds them: where each was copied
    /// from and where it is now. Nil when any of them can't be found by its identity.
    public static func finderCopy(_ info: ClipboardInfo) -> [URL]? { finderCopied(info).flatMap { currentFiles($0) } }

    private static func finderCopied(_ info: ClipboardInfo) -> [CopiedFile]? {
        finderCopied.withLock { copied in
            guard let copied, info.changeCount == copied.changeCount + 1, info.types.contains("public.file-url") else { return nil }
            return copied.files
        }
    }

    /// Each file's path when copied and its path now, found by its identity; nil when one can't be found. Both count:
    /// Finder's clipboard names a file by reference, but another file may have taken the old path.
    static func currentFiles(_ files: [CopiedFile]) -> [URL]? {
        var urls: [URL] = []
        for file in files {
            guard let reference = file.reference, let now = OpenRoutes.currentURL(of: reference) else { return nil }
            urls += [file.url, now]
        }
        return OpenRoutes.unique(urls)
    }

    /// The files a paste in Finder would copy, when they can be known.
    public static func pastedFiles(_ info: ClipboardInfo) -> [URL]? { info.fileURLs ?? finderCopy(info) }

    private static let finderCopied = Locked<(changeCount: Int, files: [CopiedFile])?>(nil)
}

/// A value behind a lock, for the few process-wide facts kept outside actors.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
