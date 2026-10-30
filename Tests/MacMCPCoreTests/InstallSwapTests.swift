import Foundation
import Testing
@testable import MacMCPCore

/// The install transaction behind scripts/build.sh (lock, journal, swap, rollback, recovery) runs against temp
/// directories with fake files: no signing, no build, nothing outside the temp directory.
@Suite struct InstallSwapTests {
    @Test(.timeLimit(.minutes(2))) func swapRollbackAndRecoveryHoldAtEveryInterruption() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("scripts/test-install-swap.sh").path
        let r = try await Subprocess.run("/bin/zsh", [script], timeout: 90)
        #expect(!r.timedOut && r.status == 0, "\n\(r.stdout.split(separator: "\n").filter { $0.hasPrefix("FAIL") }.joined(separator: "\n"))\n\(r.stderr)")
        #expect(r.stdout.contains(" checks, 0 failed"), "\(r.stdout.suffix(300))")
    }

    @Test func buildScriptsParse() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["build.sh", "install-swap.zsh", "test-install-swap.sh"] {
            let r = try await Subprocess.run("/bin/zsh", ["-n", repo.appendingPathComponent("scripts/\(name)").path], timeout: 20)
            #expect(r.status == 0, "\(name): \(r.stderr)")
        }
    }
}
