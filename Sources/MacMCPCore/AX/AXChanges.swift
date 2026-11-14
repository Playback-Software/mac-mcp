import ApplicationServices
import Foundation
import AppKit

/// An advisory event counter. Missing or unsupported notifications never replace signature verification.
final class AXChanges: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        // Keep the bridged CFStrings alive: remote observer registration can finish asynchronously.
        let names: [CFString] = [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
            kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXValueChangedNotification,
            kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification].map { $0 as CFString }
        var entries: [pid_t: (Date?, AXChanges)] = [:]
        var order: [pid_t] = []
    }
    private static let registry = Registry()
    static func forApp(_ pid: pid_t) -> AXChanges {
        let birth = NSRunningApplication(processIdentifier: pid)?.launchDate
        return registry.lock.withLock {
            if let (date, observer) = registry.entries[pid], date == birth { return observer }
            registry.entries.removeValue(forKey: pid)?.1.stop()
            registry.order.removeAll { $0 == pid }
            let observer = AXChanges(pid: pid)
            registry.entries[pid] = (birth, observer); registry.order.append(pid)
            while registry.order.count > 8 {
                registry.entries.removeValue(forKey: registry.order.removeFirst())?.1.stop()
            }
            return observer
        }
    }
    private let lock = NSLock()
    private var count: UInt64 = 0
    private var observing = false
    private var stopped = false
    private var loop: CFRunLoop?
    var generation: UInt64? { lock.withLock { observing ? count : nil } }

    init(pid: pid_t) {
        let thread = Thread { [self] in
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                let changes = Unmanaged<AXChanges>.fromOpaque(context).takeUnretainedValue()
                changes.lock.withLock { changes.count &+= 1 }
            }, &observer) == .success, let observer else { return }
            let app = AXElement.application(pid: pid, timeout: 0.1)
            let notifications = Self.registry.names
            let context = Unmanaged.passUnretained(self).toOpaque()
            let registered = notifications.filter { AXObserverAddNotification(observer, app.raw, $0, context) == .success }
            guard !registered.isEmpty else { return }
            let runLoop = CFRunLoopGetCurrent()
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            let run = lock.withLock { () -> Bool in loop = runLoop; observing = true; return !stopped }
            if run { CFRunLoopRun() }
            for name in registered { AXObserverRemoveNotification(observer, app.raw, name) }
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            lock.withLock { loop = nil; observing = false }
        }
        thread.name = "mac-mcp.ax-changes"; thread.start()
    }

    func stop() {
        let runLoop = lock.withLock { stopped = true; return loop }
        if let runLoop {
            // A stop arriving just before CFRunLoopRun must not leave a newly started observer running forever.
            CFRunLoopPerformBlock(runLoop, "kCFRunLoopDefaultMode" as CFString) { CFRunLoopStop(runLoop) }
            CFRunLoopWakeUp(runLoop)
        }
    }
}
