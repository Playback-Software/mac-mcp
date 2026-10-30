import Foundation
import Testing
@testable import MacMCPCore

/// A check resolves the protected locations once, for every path it covers, and the next check resolves them again.
@Suite struct ProtectedPathsResolutionTests {
    /// A scratch home with protected entries, links to them, and ordinary files.
    struct Scratch {
        let dir: String
        var home: String { dir + "/home" }

        init() throws {
            dir = NSTemporaryDirectory() + "protected-roots-\(UUID().uuidString)"
            for sub in ["/home/.ssh", "/home/.config/git", "/home/Applications", "/home/.local/bin", "/home/Documents", "/other"] {
                try FileManager.default.createDirectory(atPath: dir + sub, withIntermediateDirectories: true)
            }
            for file in ["/home/.ssh/id_ed25519", "/home/.gitconfig", "/home/.config/git/credentials", "/home/.config/git/ignore",
                         "/home/Documents/notes.txt", "/home/Applications/.macmcp-stage.1234", "/home/.local/bin/.mac-mcp.new.9"] {
                FileManager.default.createFile(atPath: dir + file, contents: Data("x".utf8))
            }
            try FileManager.default.createSymbolicLink(atPath: dir + "/other/ssh-link", withDestinationPath: dir + "/home/.ssh")
            try FileManager.default.createSymbolicLink(atPath: dir + "/other/config-link", withDestinationPath: dir + "/home/.gitconfig")
            try FileManager.default.linkItem(atPath: dir + "/home/.config/git/credentials", toPath: dir + "/other/hard")
            try FileManager.default.linkItem(atPath: dir + "/home/Documents/notes.txt", toPath: dir + "/other/notes-twin")
        }

        func remove() { try? FileManager.default.removeItem(atPath: dir) }

        /// Protected, ancestors of protected entries, and ordinary paths, written every way a route might name them.
        var paths: [String] {
            [home + "/.ssh/id_ed25519", home + "/.ssh", home + "/.SSH/ID_ed25519", home + "/Documents/../.ssh/id_ed25519",
             home + "/.gitconfig", home + "/.config", home + "/.config/git", home + "/.config/git/credentials",
             home + "/.config/git/ignore", home + "/.config/git/new-file", home + "/Documents/notes.txt",
             home + "/Documents", home, dir, "/", home + "/Applications/.macmcp-stage.1234",
             home + "/Applications/.macmcp-stage.1234/inner", home + "/Applications/Other.app", home + "/.local/bin/.mac-mcp.new.9",
             home + "/.local/bin/other", dir + "/other/ssh-link", dir + "/other/ssh-link/id_ed25519", dir + "/other/config-link",
             dir + "/other/hard", dir + "/other/notes-twin", dir + "/other/missing", "file://" + home + "/.ssh/id_ed25519",
             "~/.ssh/id_ed25519", "~/Library/Application Support/MacMCP", "~/Documents", "relative-name", ""]
        }
    }

    @Test func batchChecksAgreeWithCheckingEachPathAlone() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let roots = ProtectedPaths.Roots(home: scratch.home)
        for path in scratch.paths {
            let alone = ProtectedPaths.isProtected(path, home: scratch.home)
            let aloneMutation = ProtectedPaths.isProtectedFromMutation(path, home: scratch.home)
            #expect(ProtectedPaths.isProtected(path, roots: roots) == alone, "\(path)")
            #expect(ProtectedPaths.isProtectedFromMutation(path, roots: roots) == aloneMutation, "\(path)")
            #expect((ProtectedPaths.firstRefusal([path], roots: roots) != nil) == alone, "\(path)")
            #expect((ProtectedPaths.firstMutationRefusal([path], roots: roots) != nil) == aloneMutation, "\(path)")
        }
        // The expectations the cases above are meant to hold, so a wrong answer in both ways can't pass.
        let expected: [String: (Bool, Bool)] = [   // (protected, protected from mutation)
            scratch.home + "/.ssh/id_ed25519": (true, true), scratch.home + "/.SSH/ID_ed25519": (true, true),
            scratch.home + "/Documents/../.ssh/id_ed25519": (true, true), scratch.home + "/.config": (false, true),
            scratch.home + "/.config/git/ignore": (false, false), scratch.home + "/Documents": (false, false),
            scratch.home: (false, true), scratch.home + "/Applications/.macmcp-stage.1234/inner": (true, true),
            scratch.home + "/Applications/Other.app": (false, false), scratch.dir + "/other/ssh-link/id_ed25519": (true, true),
            scratch.dir + "/other/config-link": (true, true), scratch.dir + "/other/hard": (true, true),
            scratch.dir + "/other/notes-twin": (false, false),
        ]
        for (path, want) in expected {
            #expect(ProtectedPaths.isProtected(path, home: scratch.home) == want.0, "\(path)")
            #expect(ProtectedPaths.isProtectedFromMutation(path, home: scratch.home) == want.1, "\(path)")
        }
    }

    @Test func firstRefusalNamesTheFirstProtectedPathInOrder() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let roots = ProtectedPaths.Roots(home: scratch.home)
        // Each message carries its own random mark token.
        func text(_ message: String?) -> String? { message.map { Untrusted.strip($0) } }
        let ordinary = scratch.home + "/Documents/notes.txt"
        let first = scratch.home + "/.gitconfig", second = scratch.home + "/.ssh/id_ed25519"
        #expect(text(ProtectedPaths.firstRefusal([ordinary, first, second], roots: roots)) == text(ProtectedPaths.message(first)))
        #expect(text(ProtectedPaths.firstRefusal([ordinary, second, first], roots: roots)) == text(ProtectedPaths.message(second)))
        #expect(ProtectedPaths.firstRefusal([ordinary], roots: roots) == nil)
        #expect(ProtectedPaths.firstRefusal([String](), roots: roots) == nil)
        #expect(text(ProtectedPaths.firstMutationRefusal([ordinary, scratch.home + "/.config"], roots: roots)) == text(ProtectedPaths.message(scratch.home + "/.config")))
        // The public forms still say what they said.
        #expect(text(ProtectedPaths.refusal("~/.ssh/id_ed25519")) == text(ProtectedPaths.message("~/.ssh/id_ed25519")))
        #expect(text(ProtectedPaths.mutationRefusal("~/.config")) == text(ProtectedPaths.message("~/.config")))
        #expect(ProtectedPaths.refusal("~/.config") == nil)
    }

    @Test func oneCheckResolvesTheLocationsOnce() throws {
        let count = ProtectedPaths.ResolutionCount()
        let urls = (0..<50).map { URL(fileURLWithPath: NSTemporaryDirectory() + "selection-\($0).txt") }
        let folders = (0..<3).map { URL(fileURLWithPath: NSTemporaryDirectory() + "folder-\($0)") }
        ProtectedPaths.$resolutions.withValue(count) {
            #expect(ProtectedPaths.isProtected("~/Documents/a.txt") == false)
            #expect(count.value == 1)
            #expect(ProtectedPaths.isProtectedFromMutation("~/Documents/a.txt") == false)   // protected + ancestors: still one
            #expect(count.value == 2)
            #expect(OpenRoutes.protectedSelectionRefusal(urls) == nil)
            #expect(count.value == 3)
            #expect(OpenRoutes.mutationSelectionRefusal(urls) == nil)
            #expect(count.value == 4)
            #expect(OpenRoutes.transferRefusal(urls, into: folders) == nil)   // 50 files, 150 landing names
            #expect(count.value == 5)
            #expect(OpenRoutes.moveRefusal(sources: urls, destinationFolder: folders[0]) == nil)
            #expect(count.value == 6)
            #expect(OpenRoutes.selectionRefusal(urls, explicitApp: nil, policy: Policy(denyApps: [])) == nil)   // opening: 50 items
            #expect(count.value == 7)
            #expect(ProtectedPaths.firstRefusal(urls.map(\.path)) == nil)
            #expect(count.value == 8)
        }
    }

    @Test func nothingToCheckResolvesNothing() {
        let count = ProtectedPaths.ResolutionCount()
        ProtectedPaths.$resolutions.withValue(count) {
            #expect(OpenRoutes.protectedSelectionRefusal([]) == nil)
            #expect(OpenRoutes.mutationSelectionRefusal([]) == nil)
            #expect(OpenRoutes.transferRefusal([], into: [URL(fileURLWithPath: "/tmp")]) == nil)
            #expect(OpenRoutes.moveRefusal(sources: [], destinationFolder: nil) == nil)
            #expect(OpenRoutes.selectionRefusal([], explicitApp: nil, policy: Policy(denyApps: [])) == nil)
            #expect(count.value == 0)
        }
    }

    @Test func eachCheckResolvesAgainAndSeesALinkSwappedInBetween() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let count = ProtectedPaths.ResolutionCount()
        let target = scratch.dir + "/other/swap"
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: scratch.home + "/Documents")
        ProtectedPaths.$resolutions.withValue(count) {
            #expect(!ProtectedPaths.isProtected(target + "/id_ed25519", home: scratch.home))
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: scratch.home + "/.ssh")
            #expect(ProtectedPaths.isProtected(target + "/id_ed25519", home: scratch.home))   // no answer kept from before
            #expect(count.value == 2)
        }
    }
}
