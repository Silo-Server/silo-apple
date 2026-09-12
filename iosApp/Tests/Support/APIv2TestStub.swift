import Foundation
@testable import Silo

/// Scenario wrapper over the shared `StubURLProtocol.Handler` for the API v2
/// wire tests. One persistent catch-all route answers every request from a
/// mutable scenario: a fallback reply, optional per-path replies, an ordered
/// queue of one-shot replies, a transport failure, and a hold that parks the
/// next request until the test releases it. Test bodies read the recorded
/// requests straight from the handler.
///
/// This is not another `URLProtocol`; it only arranges routes on the one stub.
final class APIv2TestStub: @unchecked Sendable {
    enum Reply: Sendable {
        case response(StubURLProtocol.Response)
        case failure(URLError)

        /// A JSON body; problem+json for error statuses, the way the server
        /// answers.
        static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
            var merged = ["Content-Type": status >= 400 ? "application/problem+json" : "application/json"]
            merged.merge(headers) { _, new in new }
            return .response(StubURLProtocol.Response(status: status, headers: merged, body: Data(body.utf8)))
        }

        static func text(_ status: Int, _ body: String, contentType: String) -> Reply {
            .response(.text(body, status: status, contentType: contentType))
        }
    }

    let handler = StubURLProtocol.Handler()
    private let lock = NSLock()
    private var fallback: Reply
    private var routes: [String: Reply] = [:]
    private var queue: [Reply] = []
    private var holdNext = false
    private var gate: StubURLProtocol.Gate?
    private var heldArrived = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(fallback: Reply = .json(200, "{}")) {
        self.fallback = fallback
        installRoute()
    }

    private func installRoute() {
        handler.route(StubURLProtocol.any) { [self] request in
            let (reply, gate) = lock.withLock { () -> (Reply, StubURLProtocol.Gate?) in
                let reply: Reply
                if !queue.isEmpty {
                    reply = queue.removeFirst()
                } else {
                    reply = routes[request.path] ?? fallback
                }
                guard holdNext, let gate = self.gate else { return (reply, nil) }
                holdNext = false
                heldArrived = true
                let waiters = heldWaiters
                heldWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                return (reply, gate)
            }
            if let gate { await gate.wait() }
            switch reply {
            case .response(let response): return response
            case .failure(let error): throw error
            }
        }
    }

    // MARK: Scenario

    /// The reply for every request no queue entry or path route answers.
    func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) {
        lock.withLock { fallback = .json(status, body, headers: headers) }
    }

    func reply(_ reply: Reply) {
        lock.withLock { fallback = reply }
    }

    func reply(path: String, _ status: Int, _ body: String) {
        lock.withLock { routes[path] = .json(status, body) }
    }

    /// Ordered one-shot replies consumed before the path routes and fallback.
    func sequence(_ replies: [Reply]) {
        lock.withLock { queue = replies }
    }

    /// Every following request fails at the transport layer.
    func fail(_ code: URLError.Code = .networkConnectionLost) {
        lock.withLock { fallback = .failure(URLError(code)) }
    }

    /// Parks the next request until `release()`. Requests after the parked
    /// one are answered normally.
    func hold() {
        lock.withLock {
            holdNext = true
            heldArrived = false
            gate = StubURLProtocol.Gate()
        }
    }

    /// Suspends until the parked request has arrived at the stub.
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if heldArrived { return true }
                heldWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Delivers the parked reply.
    func release() {
        let gate = lock.withLock { () -> StubURLProtocol.Gate? in
            holdNext = false
            return self.gate
        }
        guard let gate else { return }
        Task { await gate.open() }
    }

    /// Clears routes, queue, hold, and recorded requests. Sessions created
    /// before the reset keep talking to this stub.
    func reset() {
        lock.withLock {
            routes.removeAll()
            queue.removeAll()
            holdNext = false
            heldArrived = false
        }
        release()
        handler.reset()
        installRoute()
    }

    // MARK: Observation

    var requests: [StubURLProtocol.Request] { handler.requests }
    var requestedPaths: [String] { handler.requests.map(\.path) }
    var methods: [String] { handler.requests.map(\.method) }

    func makeSession() -> URLSession { handler.makeSession() }
}
