import Foundation
import MacMCPCore

/// Only connects to the random loopback endpoint written by our own private Chrome profile.
final class ChromeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var nextID = 0
    private var closed = false
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var eventReader: Task<Void, Never>?
    private var eventSink: AsyncStream<(String, Value, String?)>.Continuation?
    var isOpen: Bool { lock.withLock { !closed } }

    init(url: URL, events: @escaping @Sendable (String, Value, String?) async -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = StreamIO.frameLimit
        socket.resume()
        let (stream, sink) = AsyncStream<(String, Value, String?)>.makeStream(bufferingPolicy: .bufferingOldest(256))
        eventSink = sink
        eventReader = Task {
            for await (method, params, session) in stream {
                guard !Task.isCancelled else { return }
                await events(method, params, session)
            }
        }
        reader = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case let .data(bytes): data = bytes; case let .string(text): data = Data(text.utf8); @unknown default: continue }
                    let value = try Value.parse(data)
                    if let id = value["id"]?.intValue {
                        if let error = value["error"] {
                            self?.finish(id, .failure(ActionError("Chrome protocol: " + Untrusted.inline(error["message"]?.stringValue ?? "failed"), audit: "Chrome protocol error")))
                        } else { self?.finish(id, .success(value["result"] ?? [:])) }
                    } else if let method = value["method"]?.stringValue {
                        // These two handlers only update dialog state; prompt detection must not wait behind Fetch.
                        if method == "Page.javascriptDialogOpening" || method == "Page.javascriptDialogClosed" {
                            await events(method, value["params"] ?? [:], value["sessionId"]?.stringValue)
                            continue
                        }
                        // Event handling can issue CDP requests. A separate bounded consumer keeps responses flowing.
                        if case .dropped = sink.yield((method, value["params"] ?? [:], value["sessionId"]?.stringValue)) {
                            self?.close(); return
                        }
                    }
                }
            } catch { self?.close() }
        }
    }

    func request(_ method: String, _ parameters: [String: Value] = [:], sessionID: String? = nil,
                 timeout: TimeInterval = 20) async throws -> Value {
        let id = lock.withLock { nextID += 1; return nextID }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let timer = Task {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self.finish(id, .failure(ActionError("Chrome did not answer in time; the automation session will be closed.")))
            }
            defer { timer.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock { () -> Bool in
                    guard !closed, !Task.isCancelled, pending.count < 32 else { return false }
                    pending[id] = continuation; return true
                }
                guard accepted else { continuation.resume(throwing: CancellationError()); return }
                var message: [String: Value] = ["id": .int(id), "method": .string(method), "params": .object(parameters)]
                if let sessionID { message["sessionId"] = .string(sessionID) }
                let data = Value.object(message).jsonData()
                guard data.count <= StreamIO.frameLimit else { finish(id, .failure(ActionError("Chrome command is too large."))); return }
                Task {
                    do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                    catch { finish(id, .failure(error)) }
                }
            }
        } onCancel: { self.finish(id, .failure(CancellationError())) }
    }

    private func finish(_ id: Int, _ result: Result<Value, Error>) {
        lock.withLock { pending.removeValue(forKey: id) }?.resume(with: result)
    }

    func close() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            closed = true; let waiters = Array(pending.values); pending.removeAll(); return waiters
        }
        waiters.forEach { $0.resume(throwing: ActionError("Chrome automation connection closed.")) }
        eventSink?.finish(); eventReader?.cancel()
        reader?.cancel(); socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
}

/// Cancellation keeps the next turn behind the actual end of the previous operation, including browser shutdown.
actor ChromeQueue {
    private var tail: Task<Void, Never>?
    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; try Task.checkCancellation(); return try await body() }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Person-control and process-exit hooks must be synchronous, including while a CDP call is stalled.
final class ChromeLifecycle: @unchecked Sendable {
    static let shared = ChromeLifecycle()
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?
    private init() { atexit { ChromeLifecycle.shared.stop() } }
    func install(_ cleanup: @escaping @Sendable () -> Void) { lock.withLock { self.cleanup = cleanup } }
    func stop() { lock.withLock { let result = cleanup; cleanup = nil; return result }?() }
}
