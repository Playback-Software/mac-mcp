import AppKit
import ApplicationServices
import Foundation

extension Input {
    public static let guardTimeout: TimeInterval = 0.25
    public static let routeTimeout: TimeInterval = 2
    static let focusTimeout: Float = 0.08
    @TaskLocal static var guardWindows: [WindowInfo]?

    /// Where a guard runs. Route checks resolve paths (lstat, aliases, hard links), and on an unresponsive network
    /// mount those block in the kernel indefinitely; they get their own workers so they can't starve the focus and
    /// cleanup guards. A pool whose workers are all stuck for 10× its timeout adds a replacement, up to a cap.
    public struct GuardPool: Sendable {
        let name: String
        let threads: DedicatedThreads

        init(name: String, count: Int, stuckAfter: TimeInterval, max: Int) {
            self.name = name
            threads = DedicatedThreads(name: "guard-\(name)", count: count, growth: .init(after: stuckAfter, max: max))
        }

        public static let focus = GuardPool(name: "focus", count: 4, stuckAfter: 10 * Input.guardTimeout, max: 12)
        public static let route = GuardPool(name: "route", count: 4, stuckAfter: 10 * Input.routeTimeout, max: 16)
        static let all = [focus, route]
    }

    /// Stuck guard workers per pool, for `mac_doctor` and the health check: workers busy for 10× their pool's timeout.
    public static func stuckGuardWorkers() -> [(pool: String, count: Int, oldest: TimeInterval)] {
        GuardPool.all.compactMap { pool in
            let status = pool.threads.status
            return status.stuck > 0 ? (pool.name, status.stuck, status.oldest) : nil
        }
    }

    private static let guardTimer = DedicatedThreads(name: "input-guard-timeout")

    /// Guards only read state. A late IPC reply may finish, but can never post input or delay drag cleanup.
    public static func guardWork<T: Sendable>(pool: GuardPool = .focus, timeout: TimeInterval = guardTimeout,
                                            _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let reply = GuardReply<T>()
        let token = Untrusted.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.start(continuation)
                pool.threads.async {
                    guard reply.isPending else { return }
                    reply.finish(Result { try Untrusted.$responseToken.withValue(token) { try work() } })
                }
                guardTimer.async(after: timeout) {
                    reply.finish(.failure(ActionError("Input targeting could not be checked quickly. Input stopped; take mac_snapshot and retry.")))
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }

    private final class GuardReply<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        var isPending: Bool { lock.withLock { result == nil } }
        func start(_ c: CheckedContinuation<T, Error>) {
            let early = lock.withLock {
                if result == nil { continuation = c }
                return result
            }
            if let early { c.resume(with: early) }
        }
        func finish(_ value: Result<T, Error>) {
            let c = lock.withLock {
                guard result == nil else { return nil as CheckedContinuation<T, Error>? }
                result = value
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: value)
        }
    }

    static func systemElement() -> AXElement {
        let raw = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(raw, focusTimeout)
        return AXElement(raw)
    }

    /// A remote child can have a helper pid while its window belongs to the host application.
    static func windowOwner(of element: AXElement) -> pid_t? {
        var current: AXElement? = element, owner: pid_t?
        var seen = Set<AXElement>()
        for _ in 0..<512 {
            guard let e = current, seen.insert(e).inserted else { break }
            AXUIElementSetMessagingTimeout(e.raw, focusTimeout)
            if e.role == "AXWindow" { owner = e.pid }
            if let window = e.element(kAXWindowAttribute), window != e, !seen.contains(window) {
                // Follow remote windows through to an outer host window when one is exposed.
                current = window
            } else {
                current = e.element(kAXParentAttribute)
            }
        }
        return owner
    }

    static func focusOwner(elementPID: pid_t?, windowPID: pid_t?, applicationPID: pid_t?, helper: Bool) -> pid_t? {
        guard let elementPID else { return applicationPID }
        if let windowPID, windowPID != elementPID { return windowPID }
        // Only recognized Apple remote view services may use the focused application as their host.
        if helper, let applicationPID { return applicationPID }
        return windowPID ?? elementPID
    }

    /// With unreadable AX focus, a nonactivating panel above the target may own the keyboard. Chrome that is always in
    /// front and never takes it doesn't count: the menu bar's status items and the Dock.
    static func unknownFocusBlocked(target: pid_t, windows: [WindowInfo], displays: [CGRect] = [], dock: Set<pid_t> = []) -> Bool {
        let menuBars = windows.filter { $0.owner == "Window Server" && $0.layer == Int(CGWindowLevelForKey(.mainMenuWindow)) }
        let visible = windows.filter {
            $0.alpha > 0.01 && $0.bounds.width > 1 && $0.bounds.height > 1 && $0.owner != "Window Server"
                && !isSystemChrome($0, displays: displays, menuBars: menuBars, dock: dock)
        }
        guard let front = visible.firstIndex(where: { $0.pid == target && $0.isNormalLayer }) else { return true }
        return visible[..<front].contains { $0.pid != target }
    }

    /// The focused application alone doesn't say which window has the keyboard: a nonactivating panel of another
    /// process can, while the target stays the focused application. So an unreadable focused element is enough.
    static func unreadableFocusRefusal(elementRead: Bool, target: pid_t, windows: [WindowInfo], displays: [CGRect],
                                       dock: Set<pid_t>) -> String? {
        guard !elementRead, unknownFocusBlocked(target: target, windows: windows, displays: displays, dock: dock) else { return nil }
        return "Keyboard focus can't be checked while another window is above the target. Dismiss it and retry."
    }

    /// A status item (above the normal layer, in a display's top strip, no taller than its menu bar), or a Dock window
    /// at the Dock's level (Mission Control and Launchpad are above it, and count).
    static func isSystemChrome(_ w: WindowInfo, displays: [CGRect], menuBars: [WindowInfo], dock: Set<pid_t>) -> Bool {
        if dock.contains(w.pid), w.layer == Int(CGWindowLevelForKey(.dockWindow)) { return true }
        guard w.layer > 0 else { return false }
        return displays.contains { d in
            let bar = menuBars.first { $0.bounds.intersects(d) && abs($0.bounds.minY - d.minY) <= 1 }?.bounds.height ?? 24
            return abs(w.bounds.minY - d.minY) <= 1 && w.bounds.height <= bar && d.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY))
        }
    }

    /// The Dock's processes, for `unknownFocusBlocked`.
    static func dockPIDs() -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
    }

    static func isRemoteService(_ pid: pid_t) -> Bool {
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        return id == "com.apple.appkit.xpc.openAndSavePanelService"
            || id == "com.apple.WebKit.WebContent" || id.hasPrefix("com.apple.WebKit.WebContent.")
            || id == "com.apple.Safari.SafariViewService" || id == "com.apple.AuthenticationServices.AuthorizationUI"
    }

    static let offscreen = CGPoint(x: -1_000_000, y: -1_000_000)

    struct DragCleanupState: Sendable {
        var prompts: Bool
        var focused: pid_t?
        var owner: pid_t?
        var fallback: CGPoint = Input.offscreen
        /// `fallback` is over the menu bar, checked to be the window server's at that point, rather than off screen.
        var fallbackSafe = false
    }

    struct DragCleanup: Sendable {
        var escape: Bool
        var source: Bool
        var fallback: CGPoint
        var fallbackSafe = false
    }

    /// Where an abandoned drag can be released without dropping on anything: the menu bar's left end, before the
    /// Apple menu, on a display where the window server's menu bar is the frontmost window there. Status items (which
    /// can take drops) and every other window rule a point out. Nil when no display has one (a full-screen app hides
    /// the menu bar).
    static func safeDropPoint(windows: [WindowInfo], displays: [CGRect]) -> CGPoint? {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        for d in displays {
            guard let bar = windows.first(where: {
                $0.owner == "Window Server" && $0.layer == menuLevel && $0.alpha > 0.01 && abs($0.bounds.minY - d.minY) <= 1
                    && $0.bounds.minX <= d.minX + 6 && $0.bounds.maxX > d.minX + 6
            }) else { continue }
            let p = CGPoint(x: d.minX + 6, y: bar.bounds.midY)
            // Front to back: any other process's window there, even a whole-display overlay, rules the point out.
            if windows.first(where: { $0.alpha > 0.01 && $0.bounds.contains(p) })?.owner == "Window Server" { return p }
        }
        return nil
    }

    static func dragCleanupState(at point: CGPoint, pid: pid_t?, environment: Environment?) throws -> DragCleanupState {
        if let environment {
            return try environment.dragCleanup?(point, pid)
                ?? DragCleanupState(prompts: false, focused: pid, owner: pid)
        }
        let windows = WindowServer.onScreenWindows(), system = systemElement()
        let focus = system.element(kAXFocusedUIElementAttribute)
        let app = system.element(kAXFocusedApplicationAttribute)?.pid
        let owner = focusOwner(elementPID: focus?.pid, windowPID: focus.flatMap { windowOwner(of: $0) },
                               applicationPID: app, helper: focus.map { isRemoteService($0.pid) } ?? false)
        var displays = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        CGGetActiveDisplayList(32, &displays, &count)
        let frames = displays.prefix(Int(count)).map(CGDisplayBounds)
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        let safe = safeDropPoint(windows: windows, displays: frames)
        // With no safe point, the least harmful release is far outside every display. The window server may clamp it
        // to the nearest display's top-left corner, which is usually the menu bar's, but can't be checked.
        return DragCleanupState(prompts: !WindowServer.systemPrompts(in: windows).isEmpty,
                                focused: owner, owner: WindowServer.owner(at: point),
                                fallback: safe ?? (bounds.isNull ? offscreen : CGPoint(x: bounds.minX - 10000, y: bounds.minY - 10000)),
                                fallbackSafe: safe != nil)
    }

    /// Cleanup must run even on cancellation/revocation, but may only read state until this decision returns.
    /// A failed check releases outside displays instead of deliberately choosing an unchecked window.
    static func dragCleanup(at point: CGPoint, pid: pid_t?) async -> DragCleanup {
        let environment = environment, route = ActionRoute.check, token = Untrusted.current
        return await Task.detached {
            await Input.$environment.withValue(environment) {
                await Untrusted.scope(token: token) {
                    let initial = try? await guardWork { try dragCleanupState(at: point, pid: pid, environment: environment) }
                    var safe = false
                    if let initial, initial.owner == pid, pid != nil || environment != nil {
                        do {
                            // Recheck the *drop*, including current window ownership and protected replacement paths.
                            if let route { try await route(.drag(from: point, to: point, pid: pid)) }
                            safe = route != nil || environment != nil
                        } catch { safe = false }
                    }
                    let final = try? await guardWork { try dragCleanupState(at: point, pid: pid, environment: environment) }
                    safe = safe && final != nil && final?.owner == initial?.owner
                    // The release point is the latest reading's, never an earlier one checked against other windows.
                    return DragCleanup(escape: safe && final?.prompts == false && final?.focused == pid,
                                       source: safe, fallback: final?.fallback ?? offscreen, fallbackSafe: final?.fallbackSafe ?? false)
                }
            }
        }.value
    }

    static func checkBlocking(pid: pid_t?, keyboard: Bool, windows: [WindowInfo]) throws {
        let running = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        if promptBlocks(hasPrompts: !WindowServer.systemPrompts(in: windows).isEmpty,
                        targetIsPrompt: running?.localizedName.map { WindowServer.systemPromptOwners.contains($0) } ?? false,
                        focusIsPrompt: false, focusKnown: false) {
            throw ActionError(promptRefusal)
        }
        if pid != nil, running == nil || running?.isTerminated == true {
            throw ActionError("The target app quit. Open it and take a new mac_snapshot before sending input.")
        }
        guard keyboard else { return }
        guard let pid, pid > 0 else { throw ActionError("No target app for keyboard input. Take mac_snapshot and retry with app=.") }
        let system = systemElement()
        let focused = system.element(kAXFocusedUIElementAttribute)
        let application = system.element(kAXFocusedApplicationAttribute)?.pid
        let owner = focusOwner(elementPID: focused?.pid, windowPID: focused.flatMap { windowOwner(of: $0) },
                               applicationPID: application, helper: focused.map { isRemoteService($0.pid) } ?? false)
        if let refusal = unreadableFocusRefusal(elementRead: focused != nil, target: pid, windows: windows,
                                                displays: WindowServer.activeDisplays(), dock: dockPIDs()) {
            throw ActionError(refusal)
        }
        if let refusal = keyboardRefusal(target: pid, exists: true,
                                        frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                        focused: owner, focusName: owner.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }) {
            throw ActionError(refusal)
        }
    }
}
