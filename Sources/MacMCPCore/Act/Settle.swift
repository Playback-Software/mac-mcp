import AppKit
import ApplicationServices
import Foundation

/// Waits until the UI stops changing, instead of sleeping a fixed time.
///
/// A sample is a signature of what an agent would see: the frontmost app, the target app's windows (window server
/// ids and bounds), its focused element, and a hash of its focused window's rows. The UI is settled once the
/// signature holds for `quiet` milliseconds. Capped by `timeout`; a UI that keeps changing (a progress bar, a
/// clock) is reported as not settled rather than blocking forever.
public enum Settle {
    public struct Result: Sendable {
        public let settled: Bool
        public let milliseconds: Int
    }

    static func signature(pid: pid_t) -> Int {
        var h = Hasher()
        h.combine(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        for w in WindowServer.onScreenWindows() where w.pid == pid || w.layer != 0 {
            h.combine(w.id)
            h.combine(Int(w.bounds.minX)); h.combine(Int(w.bounds.minY))
            h.combine(Int(w.bounds.width)); h.combine(Int(w.bounds.height))
        }
        let app = AXElement.application(pid: pid, timeout: 0.5)
        if let focused = app.element(kAXFocusedUIElementAttribute) { h.combine(focused) }
        if let window = app.element(kAXFocusedWindowAttribute) {
            var options = Walker.Options()
            options.maxNodes = 1500
            options.timeLimit = 0.4
            options.clip = Walker.screenBounds
            let (tree, _) = Walker.walk(window, options: options)
            for row in Snapshot.rows(from: tree, pid: pid) { h.combine(row.render(frames: true)) }
        }
        return h.finalize()
    }

    public static func wait(pid: pid_t, quiet: Int = 250, timeout: TimeInterval = 2.0) async -> Result {
        let started = Date()
        try? await Task.sleep(for: .milliseconds(60))   // let the app start reacting
        var last = signature(pid: pid)
        var stableSince = Date()
        while Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(80))
            let now = signature(pid: pid)
            if now != last {
                last = now
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) * 1000 >= Double(quiet) {
                return Result(settled: true, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            }
        }
        return Result(settled: false, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}
