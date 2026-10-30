import AppKit
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct WindowlessMenuSnapshotTests {
    func result() -> SnapshotResult {
        SnapshotResult(snapshot: 1, app: AppInfo(NSRunningApplication.current), windowTitle: nil,
                       focusRef: nil, blockers: [], rows: [], lines: [], notes: [], shownRows: [])
    }

    @Test func aWindowlessMenuFallsBackWithoutMarkingBookkeepingRefsShown() async throws {
        let request = bookkeepingSnapshot(pid: 123)
        var scopes: [SnapshotScope] = []
        let captured = try await actionSnapshot(request, allowMenubar: true) { next in
            scopes.append(next.scope)
            #expect(next.pid == request.pid && !next.markShown)
            if next.scope == .window { throw SnapshotError.noWindow("fixture") }
            return result()
        }
        #expect(scopes == [.window, .menubar] && captured.snapshot == 1)
    }

    @Test func aMenuThatOpenedAWindowReportsTheWindow() async throws {
        var scopes: [SnapshotScope] = []
        _ = try await actionSnapshot(bookkeepingSnapshot(pid: 123), allowMenubar: true) {
            scopes.append($0.scope)
            return result()
        }
        #expect(scopes == [.window])
    }

    @Test func otherActionsStillNeedTheirWindow() async {
        await #expect(throws: SnapshotError.self) {
            _ = try await actionSnapshot(bookkeepingSnapshot(pid: 123), allowMenubar: false) { next in
                #expect(next.scope == .window)
                throw SnapshotError.noWindow("fixture")
            }
        }
    }

    @Test func aHungAppNeverFallsBackToAMenuBar() async {
        var scopes: [SnapshotScope] = []
        await #expect(throws: SnapshotError.self) {
            _ = try await actionSnapshot(bookkeepingSnapshot(pid: 123), allowMenubar: true) {
                scopes.append($0.scope)
                throw SnapshotError.notResponding("fixture")
            }
        }
        #expect(scopes == [.window])
    }
}
