import Foundation

// The one URLProtocol stub for every networking test in SiloTests and
// SiloTVTests. Do not write another private `URLProtocol` subclass; express
// the scenario as routes on a `StubURLProtocol.Handler`.
//
// Usage
//
//     let stub = StubURLProtocol.Handler()
//     stub.route(.method("GET", path: "/api/v1/health")) { _ in
//         .json(#"{"status":"ok"}"#)
//     }
//     stub.expect(.path("/api/v1/auth/refresh")) { _ in .status(401) }   // one-shot
//     let session = stub.makeSession()                                    // or stub.install(into: config)
//
//     ... exercise the code under test with `session` ...
//
//     XCTAssertEqual(stub.requests.map(\.path), ["/api/v1/health"])
//
// Vocabulary
//
// - A handler owns an ordered list of routes. Each route is a matcher
//   `(Request) -> Bool` and a reply `(Request) async throws -> Response`.
//   The first matching route answers. `expect` adds a one-shot route that is
//   removed after it answers; `route` adds a persistent one. Both live in the
//   same ordered list, so a one-shot placed before a persistent catch-all
//   wins exactly once.
// - A reply returns `Response(status:headers:body:)` or throws. A thrown
//   `URLError` (or any error) reaches the caller as a transport failure, the
//   way a dropped connection would.
// - Replies are `async`. To stall a response until the test says so, await
//   a `StubURLProtocol.Gate` inside the reply and `open()` it from the test.
//   No `DispatchSemaphore`, no blocked loader thread.
// - Every request is recorded, body drained, before it is answered:
//   `requests` is the ordered snapshot, `observe()` is an `AsyncStream` for
//   awaiting requests as they arrive, and `waitForRequest(where:)` is the
//   common "await the request that matches" helper.
// - A request no route matches is answered with HTTP 599 and a body naming
//   the method and path, recorded in `unmatched`, and never left hanging.
//
// Sessions
//
// URLSession instantiates the protocol class itself and gives it no handle
// back to the session, so the handler is found through a per-session marker
// header that `install(into:)` adds through `httpAdditionalHeaders`. The
// marker is stripped before the request is recorded, so tests never see it.
// Two handlers can therefore serve two sessions in the same test without
// stealing each other's requests.

final class StubURLProtocol: URLProtocol {
    // MARK: Request and response records

    /// A recorded request: the original `URLRequest` plus the parts tests
    /// assert on most, decoded once. Header names are lowercased because
    /// URLSession is free to normalize casing.
    struct Request: @unchecked Sendable {
        let underlying: URLRequest
        let method: String
        let url: URL?
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data?

        init(_ request: URLRequest, body: Data?) {
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: StubURLProtocol.markerHeader)
            underlying = stripped
            method = request.httpMethod ?? "GET"
            url = request.url
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            path = components?.path ?? ""
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            self.query = query
            var headers: [String: String] = [:]
            for (name, value) in request.allHTTPHeaderFields ?? [:]
            where name.caseInsensitiveCompare(StubURLProtocol.markerHeader) != .orderedSame {
                headers[name.lowercased()] = value
            }
            self.headers = headers
            self.body = body
        }

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }

        var bodyString: String? {
            body.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            var merged = ["Content-Type": "application/json"]
            merged.merge(headers) { _, new in new }
            return Response(status: status, headers: merged, body: Data(body.utf8))
        }

        static func text(_ body: String, status: Int = 200, contentType: String = "text/plain") -> Response {
            Response(status: status, headers: ["Content-Type": contentType], body: Data(body.utf8))
        }

        static func data(_ body: Data, status: Int = 200, contentType: String) -> Response {
            Response(status: status, headers: ["Content-Type": contentType], body: body)
        }

        /// An empty body with only a status code.
        static func status(_ status: Int) -> Response {
            Response(status: status)
        }
    }

    typealias Matcher = @Sendable (Request) -> Bool
    typealias Reply = @Sendable (Request) async throws -> Response

    // MARK: Matchers

    static let any: Matcher = { _ in true }

    static func path(_ path: String) -> Matcher {
        { $0.path == path }
    }

    static func method(_ method: String, path: String) -> Matcher {
        { $0.method == method && $0.path == path }
    }

    static func method(_ method: String) -> Matcher {
        { $0.method == method }
    }

    static func pathPrefix(_ prefix: String) -> Matcher {
        { $0.path.hasPrefix(prefix) }
    }

    static func pathSuffix(_ suffix: String) -> Matcher {
        { $0.path.hasSuffix(suffix) }
    }

    // MARK: Gate

    /// An async latch for stalling a reply until the test releases it.
    /// `wait()` suspends until `open()` runs; opening is idempotent and
    /// releases every current and future waiter.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init() {}

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let released = waiters
            waiters.removeAll()
            for waiter in released {
                waiter.resume()
            }
        }
    }

    // MARK: Handler

    final class Handler: @unchecked Sendable {
        private struct Route {
            let matcher: Matcher
            let reply: Reply
            let oneShot: Bool
        }

        let id = UUID().uuidString
        private let lock = NSLock()
        private var routes: [Route] = []
        private var recorded: [Request] = []
        private var unmatchedRecorded: [Request] = []
        private var observers: [UUID: AsyncStream<Request>.Continuation] = [:]

        init() {
            StubURLProtocol.register(self)
        }

        deinit {
            for observer in observers.values {
                observer.finish()
            }
        }

        // Routing

        /// Adds a persistent route. First match in insertion order wins.
        func route(_ matcher: @escaping Matcher, _ reply: @escaping Reply) {
            lock.withLock { routes.append(Route(matcher: matcher, reply: reply, oneShot: false)) }
        }

        /// Adds a one-shot route that is removed after it answers once.
        func expect(_ matcher: @escaping Matcher, _ reply: @escaping Reply) {
            lock.withLock { routes.append(Route(matcher: matcher, reply: reply, oneShot: true)) }
        }

        /// Removes every route and recorded request. Observers stay attached.
        func reset() {
            lock.withLock {
                routes.removeAll()
                recorded.removeAll()
                unmatchedRecorded.removeAll()
            }
        }

        // Observation

        /// Every request this handler answered, in arrival order.
        var requests: [Request] {
            lock.withLock { recorded }
        }

        /// Requests no route matched. A test that cares asserts this is empty.
        var unmatched: [Request] {
            lock.withLock { unmatchedRecorded }
        }

        /// A stream of requests as they arrive. Each call creates an
        /// independent stream; requests recorded before the call are not
        /// replayed, use `requests` or `waitForRequest` for those.
        func observe() -> AsyncStream<Request> {
            let key = UUID()
            return AsyncStream { continuation in
                lock.withLock { observers[key] = continuation }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { _ = self.observers.removeValue(forKey: key) }
                }
            }
        }

        /// Returns the first request matching `predicate`, waiting for it to
        /// arrive if it has not already. Throws after `timeout`.
        @discardableResult
        func waitForRequest(
            timeout: Duration = .seconds(5),
            where predicate: @escaping Matcher
        ) async throws -> Request {
            let stream = observe()
            if let existing = requests.first(where: predicate) {
                return existing
            }
            return try await withThrowingTaskGroup(of: Request.self) { group in
                group.addTask {
                    for await request in stream where predicate(request) {
                        return request
                    }
                    throw StubError.handlerReleased
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw StubError.timedOut
                }
                guard let first = try await group.next() else {
                    throw StubError.timedOut
                }
                group.cancelAll()
                return first
            }
        }

        // Sessions

        /// Points `configuration` at this handler. Every request the session
        /// issues is answered by this handler's routes.
        func install(into configuration: URLSessionConfiguration) {
            configuration.protocolClasses = [StubURLProtocol.self]
            var headers = configuration.httpAdditionalHeaders ?? [:]
            headers[StubURLProtocol.markerHeader] = id
            configuration.httpAdditionalHeaders = headers
        }

        /// An ephemeral session that talks only to this handler.
        func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            install(into: configuration)
            return URLSession(configuration: configuration)
        }

        // Dispatch

        fileprivate func record(_ request: Request) {
            let observers = lock.withLock {
                recorded.append(request)
                return Array(self.observers.values)
            }
            for observer in observers {
                observer.yield(request)
            }
        }

        fileprivate func reply(for request: Request) -> Reply? {
            lock.withLock {
                guard let index = routes.firstIndex(where: { $0.matcher(request) }) else {
                    unmatchedRecorded.append(request)
                    return nil
                }
                let route = routes[index]
                if route.oneShot {
                    routes.remove(at: index)
                }
                return route.reply
            }
        }
    }

    enum StubError: Error {
        case timedOut
        case handlerReleased
    }

    // MARK: Registry

    static let markerHeader = "X-Silo-Test-Stub-Handler"

    private final class WeakHandler {
        weak var handler: Handler?
        init(_ handler: Handler) { self.handler = handler }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: WeakHandler] = [:]

    private static func register(_ handler: Handler) {
        registryLock.withLock {
            registry = registry.filter { $0.value.handler != nil }
            registry[handler.id] = WeakHandler(handler)
        }
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let id = request.value(forHTTPHeaderField: markerHeader) else { return nil }
        return registryLock.withLock { registry[id]?.handler }
    }

    // MARK: URLProtocol

    // `task` is a URLProtocol property; this is the in-flight reply.
    private let replyLock = NSLock()
    private var pendingReply: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.drainBody(of: request)
        let recorded = Request(request, body: body)
        guard let client else { return }
        guard let url = request.url else {
            client.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let handler = Self.handler(for: request) else {
            deliver(
                .text("StubURLProtocol: no handler installed for this session (\(recorded.method) \(recorded.path))", status: 599),
                url: url,
                client: client
            )
            return
        }
        handler.record(recorded)
        guard let reply = handler.reply(for: recorded) else {
            deliver(
                .text("StubURLProtocol: no route matched \(recorded.method) \(recorded.path)", status: 599),
                url: url,
                client: client
            )
            return
        }
        let pending = Task { [weak self] in
            let outcome: Result<Response, Error>
            do {
                outcome = .success(try await reply(recorded))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let response):
                self.deliver(response, url: url, client: client)
            case .failure(let error):
                client.urlProtocol(self, didFailWithError: error)
            }
        }
        replyLock.withLock { pendingReply = pending }
    }

    override func stopLoading() {
        let pending = replyLock.withLock { () -> Task<Void, Never>? in
            defer { pendingReply = nil }
            return pendingReply
        }
        pending?.cancel()
    }

    private func deliver(_ response: Response, url: URL, client: URLProtocolClient) {
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            client.urlProtocol(self, didLoad: response.body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands outgoing bodies to a protocol as a stream, not
    /// `httpBody`; drain whichever is present.
    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
