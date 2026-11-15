import Foundation

/// A connection-local extra restriction. This never approves machine policy, OS prompts, or another connection.
actor SessionConsent {
    static let form: Value = ["mode": "form", "message": "Allow this MacMCP connection to perform actions for this session? Current policy, pause and macOS permission checks still apply. Read-only tools do not need this approval.",
        "requestedSchema": ["type": "object", "properties": ["allow": ["type": "boolean", "title": "Allow actions for this connection"]], "required": ["allow"]]]
    enum Decision { case allowed, challenge(Value), denied }
    private var granted = false
    private var legacy: Task<Bool, Never>?
    private var challenge: (token: String, call: Value, expires: ContinuousClock.Instant)?

    static func accepts(_ response: Value?) -> Bool {
        response?["action"] == "accept" && response?["content"]?["allow"] == true
    }

    func modern(call: Value, state: String?, response: Value?) -> Decision {
        if let state {
            guard let pending = challenge, pending.token == state, pending.call == call,
                  ContinuousClock.now < pending.expires else { return .denied }
            challenge = nil
            guard Self.accepts(response) else { return .denied }
            granted = true
            return .allowed
        }
        if granted { return .allowed }
        let token = UUID().uuidString
        challenge = (token, call, .now.advanced(by: .seconds(120)))
        return .challenge(["resultType": "input_required", "requestState": .string(token),
            "inputRequests": ["consent": ["jsonrpc": "2.0", "id": "consent", "method": "elicitation/create", "params": Self.form]]])
    }

    func authorize(_ ask: @escaping @Sendable () async -> Bool) async -> Bool {
        if granted { return !Task.isCancelled }
        let task: Task<Bool, Never>
        if let checking = legacy { task = checking }
        else { task = Task { await ask() }; legacy = task }
        let accepted = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        legacy = nil
        if accepted && !task.isCancelled { granted = true }
        return granted && !Task.isCancelled
    }
}
