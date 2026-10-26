// MacMCPAgent: the executable inside MacMCP.app, run by a LaunchAgent in the logged-in GUI (Aqua) session.
// It owns the permission grants and serves MCP over a Unix socket, one server per connection. Clients reach
// it through `mac-mcp` (a byte relay), locally or over SSH.
import AppKit
import ApplicationServices
import Foundation
import MacMCPCore
import MacMCPServer
@preconcurrency import ScreenCaptureKit

// A write to a pipe whose reader is gone (safarimcp or a script child that exited early) must fail with EPIPE,
// not kill the agent with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let audit = AuditLog()

let server = MacMCPServer.definition(audit: audit)

func serve(_ fd: Int32) async {
    await Connection(fd: fd, server: server).run()
    close(fd)
}

let identity = SigningIdentity.current()
let state = SessionState.current()
log("MacMCPAgent \(MacMCPServer.version) starting: pid \(getpid()), \(identity.summary), "
    + "session \(launchdSessionType()), accessibility \(state.accessibility), screen recording \(state.screenRecording)")

// Ask once, from our own stable identity. Both calls are no-ops once granted. Missing permissions don't stop
// the agent: it stays up so mac_doctor can explain what to do (exiting would make launchd respawn us in a loop,
// re-prompting each time).
if !state.accessibility {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
}
if !state.screenRecording {
    _ = CGRequestScreenCaptureAccess()
    // On recent macOS the request alone doesn't always surface a prompt; touching ScreenCaptureKit does
    // (observed in the Phase 0b spike).
    Task.detached { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
}

Task { await HealthMonitor.shared.start() }   // permissions, capture, Secure Input, waiting prompts; every 10 min
OCR.warmUp()   // a cold first load of Vision's recognizer takes about a minute; pay it before anyone waits on it

let listenFD: Int32
do {
    listenFD = try UnixSocket.listen(path: Paths.socket)
} catch {
    log("cannot listen: \(error)")
    exit(1)
}
log("listening on \(Paths.socket)")

Thread {
    while true {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else {
            // EINTR and ECONNABORTED are momentary; anything else (out of file descriptors) would spin a core.
            if errno != EINTR, errno != ECONNABORTED {
                log("accept failed: \(String(cString: strerror(errno))); retrying in 1 s")
                Thread.sleep(forTimeInterval: 1)   // lint:allow-blocking the accept thread is its own, not the pool
            }
            continue
        }
        Task.detached { await serve(client) }
    }
}.start()

// A stalled agent is worse than a restarted one: record what it was doing, tell a person, and exit so launchd's
// KeepAlive starts a fresh agent (relays reconnect on their own).
Watchdog().start { reason in
    log("WATCHDOG: \(reason); restarting the agent")
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let samplePath = Paths.logsDir + "/hang-\(stamp).txt"
    _ = try? Subprocess.runBlocking("/usr/bin/sample", ["\(getpid())", "2", "-file", samplePath], timeout: 20)
    log("WATCHDOG: sample written to \(samplePath)")
    let sent = DispatchSemaphore(value: 0)
    Task.detached {
        await Alerts.shared.notify(.agent, "MacMCP agent stalled (\(reason)) and restarted itself; see \(samplePath).")
        sent.signal()
    }
    _ = sent.wait(timeout: .now() + 5)   // the pool may be the thing that's stuck
    exit(70)
}

// A real AppKit event loop: NSWorkspace only keeps its running-application list (and frontmost app) current while
// its notifications are processed, and a bare RunLoop.main.run() left the list frozen at launch-time contents.
// Accessory policy: no Dock icon or menu bar, matching LSUIElement.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
