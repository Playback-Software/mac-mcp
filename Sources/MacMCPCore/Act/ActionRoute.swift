import CoreGraphics
import Foundation

/// Installed by the server while holding the action lock. Every input step checks live route state, after
/// activation and coordinate conversion. Cleanup bypasses revocation; drag cleanup calls the read-only route
/// checker directly before choosing a source drop.
public enum ActionRoute {
    public enum Step: Sendable {
        case key(KeySpec, pid: pid_t?)
        case text(String, pid: pid_t?)
        case typing(String, mode: Actions.TypeMode, pid: pid_t)
        case target(AXElement?, point: CGPoint?, pid: pid_t?, opens: Bool)
        /// `modifiers`: the keys held through the drag, its button going down included.
        case drag(from: CGPoint, to: CGPoint, pid: pid_t?, modifiers: CGEventFlags = [])
    }

    @TaskLocal public static var check: (@Sendable (Step) async throws -> Void)?

    /// The keys of the mac_key call a `.key` step belongs to (repeats included) and its place among them. For
    /// mac_type, `typed` is set and the keys stand for its text (see `OpenRoutes.typedKeys`).
    public struct KeySequence: Sendable, Equatable {
        public let keys: [KeySpec]
        public let index: Int
        public let typed: Bool
        public init(keys: [KeySpec], index: Int, typed: Bool = false) { self.keys = keys; self.index = index; self.typed = typed }
    }
    @TaskLocal public static var keySequence: KeySequence?

    static func validate(_ step: Step) async throws {
        try Task.checkCancellation()
        try Input.session?.check()
        try await check?(step)
        try Task.checkCancellation()
        try Input.session?.check()
    }
}
