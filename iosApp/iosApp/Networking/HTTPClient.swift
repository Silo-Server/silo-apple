import Foundation
import OSLog

/// Immutable routing identity for a request that must not follow the app's
/// mutable active server/profile. Settings outbox work captures this before it
/// enters a queue; ``TokenStore`` then verifies and snapshots matching auth in
/// one actor turn before any bytes are sent.
struct HTTPRequestIdentity: Equatable, Sendable {
    let serverId: String
    let serverURL: String
    let profileId: String
    let clientFamily: String
}

enum CapturedHTTPRequestCredentialOwner: Equatable, Sendable {
    case persistentServer(serverId: String)
    case temporary
}

struct CapturedHTTPRequestAuth: Sendable {
    let account: RefreshAccountIdentity
    let serverURL: String
    let accessToken: String?
    let refreshToken: String?
    let profileId: String
    let profileToken: String?
    let credentialOwner: CapturedHTTPRequestCredentialOwner

    init(
        account: RefreshAccountIdentity,
        serverURL: String,
        accessValue: String?,
        refreshValue value: String?,
        profileId: String,
        profileValue otherValue: String?,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) {
        self.account = account
        self.serverURL = serverURL
        accessToken = accessValue
        refreshToken = value
        self.profileId = profileId
        profileToken = otherValue
        self.credentialOwner = credentialOwner
    }
}

/// Test-visible signal for proving that two request paths reached the same
/// keyed refresh flight before its owner is released.
enum RefreshFlightJoinKind: Sendable {
    case scoped
    case ordinary
}

/// Exclusive lease spanning an identity switch from its first cancellation
/// through the final defaults/TokenStore commit. Requests are rejected while
/// a lease is held so they cannot capture a half-retargeted credential set.
struct HTTPIdentityTransitionLease: Hashable, Sendable {
    fileprivate let id: UUID
}

/// URLSession-backed HTTP client for the Silo server.
///
/// Responsibilities:
/// - Resolve relative paths against the configured server URL from ``TokenStore``.
/// - Attach `Authorization: Bearer <token>`, `X-Profile-Id`, and
///   `X-Profile-Token` headers on every request except `/auth/refresh`.
/// - On `401`, collapse concurrent failures into a single refresh using an
///   in-flight `Task`; retry the original request once with the refreshed
///   token. Semantics mirror `AuthInterceptorImpl.kt` in the shared Kotlin
///   module, which used a `Mutex` + double-check for the same purpose.
/// - Serialize bodies and decode responses via snake_case-aware JSON
///   coders. The decoder uses `.convertFromSnakeCase` and the encoder uses
///   `.convertToSnakeCase`, so Swift models can use plain camelCase
///   properties without any `CodingKeys` boilerplate. Only add an explicit
///   `CodingKeys` entry when the wire field name is NOT a clean snake_case
///   of the Swift property (e.g. server sends `title` where Swift has
///   `name`). Explicit `CodingKeys` override the strategy per-field.
actor HTTPClient {
    static let shared = HTTPClient()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "HTTPClient"
    )

    private let session: URLSession
    /// Session for endpoints that legitimately hold the connection open well
    /// past the fail-fast window (see ``HTTPTimeout/extended``). A separate
    /// session (rather than per-request `timeoutInterval`) keeps the
    /// effective timeout unambiguous.
    private let longWaitSession: URLSession
    private let tokenStore: TokenStore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let refreshFlightJoinObserver: (@Sendable (RefreshFlightJoinKind) -> Void)?
    /// Test barrier used to make overlapping cancellation attempts
    /// deterministic. Production passes nil.
    private let cancellationPassBarrier: (@Sendable () async -> Void)?
    /// Test barrier after each URLSession cancellation snapshot. Production
    /// passes nil; requests are rejected while any such pass remains active.
    private let cancellationSessionBarrier: (@Sendable (Int) async -> Void)?
    /// Test barrier between a successful scoped refresh and its retry
    /// recapture. Production passes nil. The recapture after this suspension
    /// is deliberately generation-checked against the original request.
    private let scopedRefreshRetryBarrier: (@Sendable () async -> Void)?
    private let requestCaptureBarrier: (@Sendable () async -> Void)?
    private let responseReceivedBarrier: (@Sendable () async -> Void)?

    /// Refresh tokens rotate at server-account scope. Ordinary requests and
    /// captured-identity settings requests therefore share this one keyed
    /// flight registry; neither path may submit the same credential while the
    /// other owns its rotation.
    private var inFlightRefreshes: [RefreshAccountIdentity: RefreshFlight] = [:]

    private struct RefreshFlight {
        let id: UUID
        let task: Task<Bool, Never>
    }

    /// Global URLSession enumeration is asynchronous. Queue cancellation
    /// passes so a replacement identity can await its own pass before it is
    /// installed, without an older pass later enumerating replacement work.
    private var cancellationTail: CancellationFlight?

    private struct CancellationFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var activeIdentityTransitionLease: HTTPIdentityTransitionLease?
    private var identityTransitionWaiters: [IdentityTransitionWaiter] = []
    private var requestDispatchWaiters: [RequestDispatchWaiter] = []
    /// Invalidates request captures even when a short transition begins and
    /// completes entirely while the request is suspended on another actor.
    private var requestDispatchRevision: UInt64 = 0

    private struct IdentityTransitionWaiter {
        let id: UUID
        let lease: HTTPIdentityTransitionLease
        let continuation: CheckedContinuation<HTTPIdentityTransitionLease?, Never>
    }

    private struct RequestDispatchWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    init(
        session: URLSession? = nil,
        tokenStore: TokenStore = .shared,
        refreshFlightJoinObserver: (@Sendable (RefreshFlightJoinKind) -> Void)? = nil,
        cancellationPassBarrier: (@Sendable () async -> Void)? = nil,
        cancellationSessionBarrier: (@Sendable (Int) async -> Void)? = nil,
        scopedRefreshRetryBarrier: (@Sendable () async -> Void)? = nil,
        requestCaptureBarrier: (@Sendable () async -> Void)? = nil,
        responseReceivedBarrier: (@Sendable () async -> Void)? = nil
    ) {
        // An injected session (tests) serves both timeout classes so mocks
        // observe every request regardless of the caller's timeout choice.
        self.session = session ?? Self.makeSession(requestTimeout: 15)
        self.longWaitSession = session ?? Self.makeSession(requestTimeout: 90)
        self.tokenStore = tokenStore
        self.refreshFlightJoinObserver = refreshFlightJoinObserver
        self.cancellationPassBarrier = cancellationPassBarrier
        self.cancellationSessionBarrier = cancellationSessionBarrier
        self.scopedRefreshRetryBarrier = scopedRefreshRetryBarrier
        self.requestCaptureBarrier = requestCaptureBarrier
        self.responseReceivedBarrier = responseReceivedBarrier

        self.decoder = Self.makeJSONDecoder()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = Self.isoFractional.date(from: str) { return date }
            if let date = Self.isoWhole.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO-8601 date: \(str)"
            )
        }
        return decoder
    }

    /// `URLSession` configured for an auth-gated REST API: no shared HTTP
    /// cache, and every request bypasses any local cache. The default
    /// `URLSession.shared` is keyed by URL only — `Authorization`,
    /// `X-Profile-Id`, and `X-Profile-Token` don't participate in the cache
    /// key, so a cached 401/404 or a response fetched under one profile
    /// can be served to a later request under different auth.
    private static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Fail fast when the server is down: the default 60s idle timeout
        // leaves a dead-but-routable server spinning for a minute before the
        // user sees anything. The timeout is the max quiet gap between
        // bytes, not a total budget, so slow-but-alive responses are
        // unaffected.
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }

    /// Parser for the fractional-second ISO-8601 timestamps the Continuum
    /// server emits (e.g. `2026-04-13T04:46:42.211273Z`). The default
    /// `.iso8601` decoder strategy rejects fractional seconds outright.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public API

    func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: Optional<String>.none)
    }

    /// Probe a candidate server without mutating global routing state or
    /// attaching credentials from the currently active server.
    func getUnauthenticated<T: Decodable>(
        serverURL: String,
        path: String
    ) async throws -> T {
        let dispatchRevision = try captureRequestDispatchRevision()
        let request = try buildRequest(
            serverUrl: ServerRegistry.normalize(url: serverURL),
            method: "GET",
            path: path,
            query: [:],
            body: Optional<String>.none
        )
        let (data, response) = try await perform(
            request: request,
            dispatchRevision: dispatchRevision,
            reportReachability: false
        )
        try ensureSuccess(data, response, method: "GET")
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logDecodingFailure(
                type: String(describing: T.self),
                path: path,
                error: error,
                data: data
            )
            throw HTTPError.decodingFailed(type: String(describing: T.self), underlying: error)
        }
    }

    func post<T: Decodable>(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:],
        timeout: HTTPTimeout = .standard
    ) async throws -> T {
        try await send(method: "POST", path: path, query: query, body: body, timeout: timeout)
    }

    func postVoid(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:],
        expectedAccount: RefreshAccountIdentity? = nil
    ) async throws {
        _ = try await performWithAuthRetry(
            method: "POST",
            path: path,
            quietStatuses: [],
            timeout: .standard,
            expectedAccount: expectedAccount
        ) { serverUrl in
            try self.buildRequest(
                serverUrl: serverUrl,
                method: "POST",
                path: path,
                query: query,
                body: body
            )
        }
    }

    func postMultipart<T: Decodable>(
        _ path: String,
        parts: [HTTPMultipartPart],
        timeout: HTTPTimeout = .extended
    ) async throws -> T {
        let boundary = "SiloDiagnostics-\(UUID().uuidString)"
        return try await sendRawBody(
            method: "POST",
            path: path,
            body: Self.multipartBody(parts: parts, boundary: boundary),
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: timeout
        )
    }

    /// POST a pre-encoded body verbatim. Exists for callers whose payload
    /// cannot go through `JSONEncoder` — e.g. diagnostics chunked-upload init,
    /// which embeds an already-serialized manifest byte-for-byte (re-encoding
    /// could reorder keys and break the server's manifest equality check).
    func postRaw<T: Decodable>(
        _ path: String,
        body: Data,
        contentType: String,
        timeout: HTTPTimeout = .standard
    ) async throws -> T {
        try await sendRawBody(method: "POST", path: path, body: body, contentType: contentType, timeout: timeout)
    }

    /// PUT a raw binary body (e.g. one diagnostics bundle chunk).
    func putRaw<T: Decodable>(
        _ path: String,
        body: Data,
        contentType: String,
        timeout: HTTPTimeout = .extended
    ) async throws -> T {
        try await sendRawBody(method: "PUT", path: path, body: body, contentType: contentType, timeout: timeout)
    }

    func put<T: Decodable>(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:]
    ) async throws -> T {
        try await send(method: "PUT", path: path, query: query, body: body)
    }

    func putVoid(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:]
    ) async throws {
        _ = try await sendRaw(method: "PUT", path: path, query: query, body: body)
    }

    func delete(_ path: String, query: [String: String] = [:]) async throws {
        _ = try await sendRaw(method: "DELETE", path: path, query: query, body: Optional<String>.none)
    }

    func patch<T: Decodable>(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:]
    ) async throws -> T {
        try await send(method: "PATCH", path: path, query: query, body: body)
    }

    func patchVoid(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:]
    ) async throws {
        _ = try await sendRaw(method: "PATCH", path: path, query: query, body: body)
    }

    /// GET an endpoint that returns raw bytes (not JSON) — e.g. the
    /// download artwork/subtitle proxies. Goes through the same auth +
    /// 401-refresh path as the decoding `get`, but hands the caller the
    /// undecoded body.
    func getData(_ path: String, query: [String: String] = [:]) async throws -> Data {
        try await sendRaw(method: "GET", path: path, query: query, body: Optional<String>.none)
    }

    /// Send a request with a caller-supplied body and extra headers, doing no
    /// JSON coding, and hand back the status and response headers alongside
    /// the bytes.
    ///
    /// Exists for endpoints the shared coders cannot serve. The canonical
    /// settings API is the motivating case: its values are opaque JSON whose
    /// object keys must survive verbatim, so it codes with its own
    /// strategy-free coders; it also sends a per-request header
    /// (`X-Silo-Mutation-Id`) and reads a response header
    /// (`X-Silo-Idempotent-Replay`) that a decoded body cannot carry.
    ///
    /// `headers` are applied after the auth/profile/device headers, so a
    /// caller can address a profile other than the session default. Everything
    /// else — server URL resolution, 401 refresh, non-2xx translation — is the
    /// path every other request takes.
    func requestData(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        quietStatuses: Set<Int> = [],
        timeout: HTTPTimeout = .standard,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> HTTPRawResponse {
        if let requestIdentity {
            let dispatchRevision = try captureRequestDispatchRevision()
            if let requestCaptureBarrier {
                await requestCaptureBarrier()
            }
            var auth = try await tokenStore.captureRequestAuth(expected: requestIdentity)
            var request = try scopedRequest(
                method: method,
                path: path,
                query: query,
                body: body,
                contentType: contentType,
                headers: headers,
                auth: auth
            )
            var (data, response) = try await perform(
                request: request,
                timeout: timeout,
                dispatchRevision: dispatchRevision
            )

            if response.statusCode == 401,
               shouldAttemptRefresh(path: path),
               await refreshScopedTokens(
                   auth: auth,
                   expected: requestIdentity,
                   dispatchRevision: dispatchRevision
               ) {
                let originalAuth = auth
                if let scopedRefreshRetryBarrier {
                    await scopedRefreshRetryBarrier()
                }
                // The caller-supplied routing identity does not contain the
                // process-local credential epoch. Re-capture after every
                // suspension and retry only under the exact owner/generation
                // that sent the rejected request.
                if let refreshedAuth = try? await tokenStore.captureRequestAuth(
                    expected: requestIdentity
                ),
                   refreshedAuth.account == originalAuth.account,
                   refreshedAuth.credentialOwner == originalAuth.credentialOwner,
                   refreshedAuth.accessToken != nil,
                   refreshedAuth.accessToken != originalAuth.accessToken
                       || refreshedAuth.refreshToken != originalAuth.refreshToken {
                    auth = refreshedAuth
                    request = try scopedRequest(
                        method: method,
                        path: path,
                        query: query,
                        body: body,
                        contentType: contentType,
                        headers: headers,
                        auth: auth
                    )
                    (data, response) = try await perform(
                        request: request,
                        timeout: timeout,
                        dispatchRevision: dispatchRevision
                    )
                }
            }
            try ensureSuccess(data, response, method: method, quietStatuses: quietStatuses)
            return HTTPRawResponse(
                data: data,
                statusCode: response.statusCode,
                headers: response.allHeaderFields
            )
        }

        let (data, response) = try await performWithAuthRetry(
            method: method,
            path: path,
            additionalHeaders: headers,
            quietStatuses: quietStatuses,
            timeout: timeout
        ) { serverUrl in
            var request = try self.buildRequest(
                serverUrl: serverUrl,
                method: method,
                path: path,
                query: query,
                body: Optional<String>.none
            )
            if let body {
                request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            return request
        }
        return HTTPRawResponse(data: data, statusCode: response.statusCode, headers: response.allHeaderFields)
    }

    private func scopedRequest(
        method: String,
        path: String,
        query: [String: String],
        body: Data?,
        contentType: String,
        headers: [String: String],
        auth: CapturedHTTPRequestAuth
    ) throws -> URLRequest {
        var request = try buildRequest(
            serverUrl: auth.serverURL,
            method: method,
            path: path,
            query: query,
            body: Optional<String>.none
        )
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        attachCapturedAuthHeaders(&request, auth: auth)
        Self.apply(headers, to: &request)
        return request
    }

    /// Cancel all in-flight tasks on the shared session and drop any
    /// pending refresh. Called by the registry *before* retargeting
    /// `TokenStore` on a server switch so a response from the old server
    /// cannot be routed into the new server's token slot.
    ///
    /// `URLSession.shared` can't be invalidated, but cancelling per-task
    /// is sufficient. The `getAllTasks` callback is asynchronous, so we
    /// bridge it with a continuation — the caller must be able to wait
    /// for cancellation to actually complete before retargeting.
    func cancelInFlightRequests() async {
        requestDispatchRevision &+= 1
        let previous = cancellationTail?.task
        let flightId = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performCancellationPass()
        }
        cancellationTail = .init(id: flightId, task: task)
        await task.value
        if cancellationTail?.id == flightId {
            cancellationTail = nil
        }
        resumeRequestDispatchWaitersIfOpen()
    }

    /// Wait until a caller can safely begin capturing request identity.
    ///
    /// Unlike an ordinary request, this is used before any URL or credential
    /// snapshot exists. Waiting is therefore safe: identity transitions and
    /// URLSession cancellation passes may finish, and the caller captures only
    /// the fully committed identity after the gate reopens.
    func waitForRequestDispatchOpen() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isRequestDispatchBlocked else { return true }

        let waiterID = UUID()
        let opened = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if !isRequestDispatchBlocked {
                    continuation.resume(returning: true)
                } else {
                    requestDispatchWaiters.append(.init(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelRequestDispatchWaiter(id: waiterID) }
        }
        return opened && !Task.isCancelled
    }

    /// Acquire the exclusive gate for a complete server or temporary-owner
    /// transition. Concurrent transitions queue in acquisition order; request
    /// entry, credential refresh, and final dispatch remain closed until the
    /// holder explicitly commits or rolls back and releases the lease.
    func beginIdentityTransition() async -> HTTPIdentityTransitionLease? {
        guard !Task.isCancelled else { return nil }
        let lease = HTTPIdentityTransitionLease(id: UUID())
        guard activeIdentityTransitionLease != nil else {
            requestDispatchRevision &+= 1
            activeIdentityTransitionLease = lease
            if Task.isCancelled {
                endIdentityTransition(lease)
                return nil
            }
            return lease
        }
        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<HTTPIdentityTransitionLease?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    identityTransitionWaiters.append(.init(
                        id: waiterID,
                        lease: lease,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelIdentityTransitionWaiter(id: waiterID) }
        }
        guard let granted else { return nil }
        if Task.isCancelled {
            endIdentityTransition(granted)
            return nil
        }
        return granted
    }

    func endIdentityTransition(_ lease: HTTPIdentityTransitionLease) {
        guard activeIdentityTransitionLease == lease else { return }
        guard !identityTransitionWaiters.isEmpty else {
            activeIdentityTransitionLease = nil
            resumeRequestDispatchWaitersIfOpen()
            return
        }
        let next = identityTransitionWaiters.removeFirst()
        activeIdentityTransitionLease = next.lease
        next.continuation.resume(returning: next.lease)
    }

    private func cancelIdentityTransitionWaiter(id: UUID) {
        guard let index = identityTransitionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = identityTransitionWaiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func cancelRequestDispatchWaiter(id: UUID) {
        guard let index = requestDispatchWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = requestDispatchWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func resumeRequestDispatchWaitersIfOpen() {
        guard !isRequestDispatchBlocked, !requestDispatchWaiters.isEmpty else {
            return
        }
        let waiters = requestDispatchWaiters
        requestDispatchWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: true)
        }
    }

    func isIdentityTransitionActive(_ lease: HTTPIdentityTransitionLease) -> Bool {
        activeIdentityTransitionLease == lease
    }

    func pendingIdentityTransitionCount() -> Int {
        identityTransitionWaiters.count
    }

    func pendingRequestDispatchWaiterCount() -> Int {
        requestDispatchWaiters.count
    }

    private func performCancellationPass() async {
        if let cancellationPassBarrier {
            await cancellationPassBarrier()
        }
        inFlightRefreshes.values.forEach { $0.task.cancel() }
        inFlightRefreshes.removeAll()
        for (index, session) in [session, longWaitSession].enumerated() {
            await withCheckedContinuation { continuation in
                session.getAllTasks { tasks in
                    for task in tasks { task.cancel() }
                    continuation.resume()
                }
            }
            if let cancellationSessionBarrier {
                await cancellationSessionBarrier(index + 1)
            }
        }
    }

    /// GET an endpoint that signals existence via HTTP status only (e.g.
    /// `/favorites/{id}` — 204 = yes, 404 = no). Returns `true` for any 2xx,
    /// `false` for 404, and rethrows for anything else. Bypasses body
    /// decoding, which would otherwise throw on an empty 204 response.
    func exists(_ path: String, query: [String: String] = [:]) async throws -> Bool {
        do {
            // A 404 here is the documented "not found" signal, not a failure,
            // so mark it quiet to keep it out of the error log.
            _ = try await sendRaw(
                method: "GET",
                path: path,
                query: query,
                body: Optional<String>.none,
                quietStatuses: [404]
            )
            return true
        } catch HTTPError.http(let code, _) where code == 404 {
            return false
        }
    }

    // MARK: - Core send

    private func send<T: Decodable>(
        method: String,
        path: String,
        query: [String: String],
        body: (any Encodable)?,
        timeout: HTTPTimeout = .standard
    ) async throws -> T {
        let data = try await sendRaw(method: method, path: path, query: query, body: body, timeout: timeout)
        if data.isEmpty, let empty = EmptyResponse.empty as? T {
            return empty
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logDecodingFailure(type: String(describing: T.self), path: path, error: error, data: data)
            throw HTTPError.decodingFailed(type: String(describing: T.self), underlying: error)
        }
    }

    /// Diagnostic log for decoding failures. Emits the endpoint, the specific
    /// DecodingError case (keyNotFound / typeMismatch / valueNotFound /
    /// dataCorrupted) with its codingPath, and a truncated dump of the raw
    /// response body so mismatches between server JSON and Swift models can
    /// be identified from a Console snapshot without rebuilding the app.
    private static func logDecodingFailure(type: String, path: String, error: Error, data: Data) {
        let bodyPreview = String(data: data.prefix(1024), encoding: .utf8) ?? "<non-utf8 body>"
        var detail = "decode(\(type)) failed at \(path): "
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
                detail += "keyNotFound key=\(key.stringValue) path=\(codingPathString(context.codingPath)) — \(context.debugDescription)"
            case .typeMismatch(_, let context):
                detail += "typeMismatch path=\(codingPathString(context.codingPath)) — \(context.debugDescription)"
            case .valueNotFound(_, let context):
                detail += "valueNotFound path=\(codingPathString(context.codingPath)) — \(context.debugDescription)"
            case .dataCorrupted(let context):
                detail += "dataCorrupted path=\(codingPathString(context.codingPath)) — \(context.debugDescription)"
            @unknown default:
                detail += String(describing: decodingError)
            }
        } else {
            detail += String(describing: error)
        }
        logger.error("\(detail, privacy: .public) body=\(bodyPreview, privacy: .private)")
    }

    private static func codingPathString(_ path: [CodingKey]) -> String {
        path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    /// Returns raw response body bytes. Handles auth injection, 401 retry,
    /// and non-2xx status translation.
    private func sendRaw(
        method: String,
        path: String,
        query: [String: String],
        body: (any Encodable)?,
        quietStatuses: Set<Int> = [],
        timeout: HTTPTimeout = .standard
    ) async throws -> Data {
        try await performWithAuthRetry(
            method: method,
            path: path,
            quietStatuses: quietStatuses,
            timeout: timeout
        ) { serverUrl in
            try self.buildRequest(
                serverUrl: serverUrl,
                method: method,
                path: path,
                query: query,
                body: body
            )
        }.0
    }

    /// Shared server-URL/auth/401-refresh/success skeleton for every request
    /// shape. `makeRequest` builds a fresh, unauthenticated request per
    /// attempt; auth headers are attached here so the retry after a token
    /// refresh carries the new token while keeping the caller's body and
    /// Content-Type intact.
    ///
    /// `additionalHeaders` are applied after the auth/profile/device headers,
    /// so a caller can override the session default (e.g. address a specific
    /// profile) or add a per-request header the client doesn't know about.
    private func performWithAuthRetry(
        method: String,
        path: String,
        additionalHeaders: [String: String] = [:],
        quietStatuses: Set<Int> = [],
        timeout: HTTPTimeout,
        expectedAccount: RefreshAccountIdentity? = nil,
        makeRequest: (String) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let dispatchRevision = try captureRequestDispatchRevision()
        if let requestCaptureBarrier {
            await requestCaptureBarrier()
        }
        let capturedAuth = await tokenStore.captureOrdinaryRequestAuth()
        if let expectedAccount,
           capturedAuth?.account != expectedAccount {
            throw HTTPError.requestIdentityChanged
        }
        let serverUrl = if let capturedAuth {
            capturedAuth.account.serverURL
        } else {
            await tokenStore.getServerUrl()
        }
        guard !serverUrl.isEmpty else {
            throw HTTPError.serverUrlNotConfigured
        }

        var request = try makeRequest(serverUrl)
        if let capturedAuth {
            attachOrdinaryAuthHeaders(&request, auth: capturedAuth)
        } else {
            await attachLegacyAuthHeaders(&request)
        }
        Self.apply(additionalHeaders, to: &request)

        let (data, response) = try await perform(
            request: request,
            timeout: timeout,
            dispatchRevision: dispatchRevision
        )

        if response.statusCode == 401, shouldAttemptRefresh(path: path) {
            if let capturedAuth,
               let refreshedAuth = await refreshTokens(
                   expected: capturedAuth,
                   dispatchRevision: dispatchRevision
               ),
               refreshedAuth.accessToken != nil,
               await tokenStore.currentOrdinaryRequestAuth(
                   matchingIdentityOf: refreshedAuth
               ) == refreshedAuth {
                // Rebuild from one account-owner/profile snapshot. If any of
                // those identities changed during the shared flight, keep the
                // original 401 instead of sending mixed credentials.
                var retry = try makeRequest(serverUrl)
                attachOrdinaryAuthHeaders(&retry, auth: refreshedAuth)
                Self.apply(additionalHeaders, to: &retry)
                let (retryData, retryResponse) = try await perform(
                    request: retry,
                    timeout: timeout,
                    dispatchRevision: dispatchRevision
                )
                try ensureSuccess(retryData, retryResponse, method: method, quietStatuses: quietStatuses)
                return (retryData, retryResponse)
            }
        }

        try ensureSuccess(data, response, method: method, quietStatuses: quietStatuses)
        return (data, response)
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func sendRawBody<T: Decodable>(
        method: String,
        path: String,
        body: Data,
        contentType: String,
        timeout: HTTPTimeout
    ) async throws -> T {
        let data = try await sendRawBodyData(
            method: method,
            path: path,
            body: body,
            contentType: contentType,
            timeout: timeout
        )
        if data.isEmpty, let empty = EmptyResponse.empty as? T {
            return empty
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logDecodingFailure(type: String(describing: T.self), path: path, error: error, data: data)
            throw HTTPError.decodingFailed(type: String(describing: T.self), underlying: error)
        }
    }

    private func sendRawBodyData(
        method: String,
        path: String,
        body: Data,
        contentType: String,
        timeout: HTTPTimeout
    ) async throws -> Data {
        try await performWithAuthRetry(method: method, path: path, timeout: timeout) { serverUrl in
            var request = try self.buildRequest(
                serverUrl: serverUrl,
                method: method,
                path: path,
                query: [:],
                body: Optional<String>.none
            )
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }.0
    }

    // MARK: - Request building

    private func buildRequest(
        serverUrl: String,
        method: String,
        path: String,
        query: [String: String],
        body: (any Encodable)?
    ) throws -> URLRequest {
        guard var components = URLComponents(string: serverUrl) else {
            throw HTTPError.invalidURL(serverUrl)
        }

        // `path` arrives either as `/api/v1/foo` or `api/v1/foo`; normalize.
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let basePath = components.percentEncodedPath
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.percentEncodedPath = trimmedBase + normalizedPath

        if !query.isEmpty {
            components.queryItems = query
                .sorted(by: { $0.key < $1.key })
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw HTTPError.invalidURL(components.description)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(AnyEncodable(body))
            } catch {
                throw HTTPError.encodingFailed(underlying: error)
            }
        }

        return request
    }

    static func multipartBody(parts: [HTTPMultipartPart], boundary: String) -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(
                "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.filename)\"\r\n".utf8
            ))
            body.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Compatibility path for the pre-registry/no-active-server state. Normal
    /// authenticated requests use `attachOrdinaryAuthHeaders`, whose complete
    /// credential snapshot is captured in one TokenStore actor turn.
    private func attachLegacyAuthHeaders(_ request: inout URLRequest) async {
        let path = request.url?.path ?? ""
        // Skip auth injection for /auth/refresh (avoid recursion) and
        // /auth/login (a prior expired token can't authorize a fresh login).
        if path.hasSuffix("/auth/refresh") || path.hasSuffix("/auth/login") {
            return
        }

        var attached: [String] = []
        if let token = await tokenStore.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            attached.append("auth")
        }
        if let profileId = await tokenStore.getProfileId() {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
            attached.append("profile")
        }
        if let profileToken = await tokenStore.getProfileToken() {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
            attached.append("profileToken")
        }
        let device = AppleDeviceIdentity.current
        request.setValue(device.id, forHTTPHeaderField: "X-Silo-Device-Id")
        request.setValue(device.name, forHTTPHeaderField: "X-Silo-Device-Name")
        request.setValue(device.platform, forHTTPHeaderField: "X-Silo-Device-Platform")
        request.setValue(device.clientFamily, forHTTPHeaderField: "X-Silo-Client-Family")
        attached.append("device=\(device.platform)/\(device.clientFamily)")
        let method = request.httpMethod ?? ""
        let attachedDesc = attached.joined(separator: ", ")
        Self.logger.debug("→ \(method, privacy: .public) \(path, privacy: .public) headers=[\(attachedDesc, privacy: .public)]")
    }

    /// Attach the immutable account-owner/profile snapshot captured before the
    /// request was built. There are no actor hops between the individual
    /// headers, so temporary handoff or profile changes cannot mix identities.
    private func attachOrdinaryAuthHeaders(
        _ request: inout URLRequest,
        auth: CapturedOrdinaryRequestAuth
    ) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/auth/refresh") || path.hasSuffix("/auth/login") {
            return
        }

        var attached: [String] = []
        if let token = auth.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            attached.append("auth")
        }
        if let profileId = auth.profileId {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
            attached.append("profile")
        }
        if let profileToken = auth.profileToken {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
            attached.append("profileToken")
        }
        let device = AppleDeviceIdentity.current
        request.setValue(device.id, forHTTPHeaderField: "X-Silo-Device-Id")
        request.setValue(device.name, forHTTPHeaderField: "X-Silo-Device-Name")
        request.setValue(device.platform, forHTTPHeaderField: "X-Silo-Device-Platform")
        request.setValue(device.clientFamily, forHTTPHeaderField: "X-Silo-Client-Family")
        attached.append("device=\(device.platform)/\(device.clientFamily)")
        let method = request.httpMethod ?? ""
        let attachedDesc = attached.joined(separator: ", ")
        Self.logger.debug("→ \(method, privacy: .public) \(path, privacy: .public) headers=[\(attachedDesc, privacy: .public)]")
    }

    /// Attach one actor-consistent auth snapshot. Scoped requests deliberately
    /// do not use the global refresh path: after an identity switch, a 401 is
    /// safer than refreshing or storing credentials in the wrong server slot.
    private func attachCapturedAuthHeaders(
        _ request: inout URLRequest,
        auth: CapturedHTTPRequestAuth
    ) {
        if let token = auth.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(auth.profileId, forHTTPHeaderField: "X-Profile-Id")
        if let profileToken = auth.profileToken {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        let device = AppleDeviceIdentity.current
        request.setValue(device.id, forHTTPHeaderField: "X-Silo-Device-Id")
        request.setValue(device.name, forHTTPHeaderField: "X-Silo-Device-Name")
        request.setValue(device.platform, forHTTPHeaderField: "X-Silo-Device-Platform")
        request.setValue(device.clientFamily, forHTTPHeaderField: "X-Silo-Client-Family")
    }

    // MARK: - Response handling

    private func perform(
        request: URLRequest,
        timeout: HTTPTimeout = .standard,
        dispatchRevision: UInt64,
        reportReachability: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        // A cancellation pass takes asynchronous snapshots of both sessions.
        // Dispatching between those snapshots could let an old-identity
        // request start after its session was already enumerated and survive
        // a registry or temporary-owner transition. Reject it; waiting would
        // send a request built from credentials captured before the switch.
        try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        let data: Data
        let response: URLResponse
        do {
            let session = timeout == .extended ? longWaitSession : session
            (data, response) = try await session.data(for: request)
        } catch {
            if isRequestDispatchBlocked || requestDispatchRevision != dispatchRevision {
                throw HTTPError.requestIdentityChanged
            }
            // Feed ConnectionMonitor from every transport failure so the app
            // learns "server down" passively. Cancellation says nothing about
            // reachability, so it is excluded.
            if reportReachability {
                await Self.noteServerUnreachable(for: error)
            }
            throw HTTPError.network(underlying: error)
        }
        if let responseReceivedBarrier {
            await responseReceivedBarrier()
        }
        // URLSession cancellation is best-effort: a completed response can
        // race the transition's task enumeration. Reject it before it can
        // update reachability or flow into any response/cache consumer.
        try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        // Any HTTP response — success or error status — proves the server is
        // alive.
        if reportReachability {
            await MainActor.run {
                ConnectionMonitor.shared.noteServerResponded()
            }
        }
        return (data, http)
    }

    /// Only the absence of an HTTP response is a reachability signal. Decode,
    /// validation, and other response-processing errors still prove that the
    /// server answered and must not start the offline reprobe loop.
    private static func noteServerUnreachable(for error: Error) async {
        guard let urlError = error as? URLError,
              urlError.code != .cancelled else { return }
        await MainActor.run {
            ConnectionMonitor.shared.noteServerUnreachable()
        }
    }

    private func ensureSuccess(_ data: Data, _ response: HTTPURLResponse, method: String, quietStatuses: Set<Int> = []) throws {
        guard (200..<300).contains(response.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            // A status the caller treats as an expected signal (e.g. a 404
            // existence probe) is demoted to debug so it doesn't read as a
            // failure in the log; everything else stays at error level.
            if quietStatuses.contains(response.statusCode) {
                Self.logger.debug("HTTP \(response.statusCode, privacy: .public) \(method, privacy: .public)")
            } else {
                Self.logger.error("HTTP \(response.statusCode, privacy: .public) \(method, privacy: .public)")
            }
            throw HTTPError.http(
                statusCode: response.statusCode,
                body: bodyStr
            )
        }
    }

    private func shouldAttemptRefresh(path: String) -> Bool {
        // Matches the guard in AuthInterceptorImpl.kt:96.
        !path.hasSuffix("/auth/refresh") && !path.hasSuffix("/auth/login")
    }

    private var isRequestDispatchBlocked: Bool {
        cancellationTail != nil || activeIdentityTransitionLease != nil
    }

    private func captureRequestDispatchRevision() throws -> UInt64 {
        try ensureRequestDispatchAllowed(expectedRevision: requestDispatchRevision)
        return requestDispatchRevision
    }

    private func ensureRequestDispatchAllowed(expectedRevision: UInt64) throws {
        guard !isRequestDispatchBlocked,
              requestDispatchRevision == expectedRevision else {
            throw HTTPError.requestIdentityChanged
        }
    }

    private func refreshScopedTokens(
        auth: CapturedHTTPRequestAuth,
        expected: HTTPRequestIdentity,
        dispatchRevision: UInt64
    ) async -> Bool {
        guard !isRequestDispatchBlocked,
              requestDispatchRevision == dispatchRevision else { return false }
        guard case .persistentServer(let credentialServerId) = auth.credentialOwner,
              credentialServerId == expected.serverId,
              auth.account.serverId == expected.serverId,
              auth.account.serverURL == ServerRegistry.normalize(url: expected.serverURL),
              let refreshValue = auth.refreshToken, !refreshValue.isEmpty,
              URL(string: auth.serverURL + "/api/v1/auth/refresh") != nil else {
            return false
        }
        if await scopedCredentialsChanged(since: auth, expected: expected) {
            return true
        }
        guard !isRequestDispatchBlocked,
              requestDispatchRevision == dispatchRevision else { return false }

        let key = auth.account
        if let existing = inFlightRefreshes[key] {
            refreshFlightJoinObserver?(.scoped)
            _ = await existing.task.value
            return await scopedCredentialsChanged(since: auth, expected: expected)
        }

        let task = Task<Bool, Never> { [tokenStore, session, decoder, encoder] in
            await Self.performScopedRefresh(
                auth: auth,
                tokenStore: tokenStore,
                session: session,
                decoder: decoder,
                encoder: encoder
            )
        }
        let flightId = UUID()
        inFlightRefreshes[key] = .init(id: flightId, task: task)
        _ = await task.value
        if inFlightRefreshes[key]?.id == flightId {
            inFlightRefreshes.removeValue(forKey: key)
        }
        return await scopedCredentialsChanged(since: auth, expected: expected)
    }

    private func scopedCredentialsChanged(
        since auth: CapturedHTTPRequestAuth,
        expected: HTTPRequestIdentity
    ) async -> Bool {
        guard let current = try? await tokenStore.captureRequestAuth(expected: expected),
              current.account == auth.account,
              current.credentialOwner == auth.credentialOwner,
              current.accessToken != nil else { return false }
        return current.accessToken != auth.accessToken
            || current.refreshToken != auth.refreshToken
    }

    private static func performScopedRefresh(
        auth: CapturedHTTPRequestAuth,
        tokenStore: TokenStore,
        session: URLSession,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) async -> Bool {
        guard let refreshValue = auth.refreshToken,
              let url = URL(string: auth.serverURL + "/api/v1/auth/refresh") else {
            return false
        }
        let captured = CapturedRefreshCredential(
            account: auth.account,
            refreshToken: refreshValue,
            owner: auth.credentialOwner
        )
        guard await tokenStore.captureRefreshCredential(expected: auth.account) == captured else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try encoder.encode(RefreshRequest(refreshValue))
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return false }
            guard let http = response as? HTTPURLResponse else {
                Self.logger.error("Scoped refresh: non-HTTP response")
                return false
            }
            await MainActor.run {
                ConnectionMonitor.shared.noteServerResponded()
            }
            if (200..<300).contains(http.statusCode) {
                let tokens = try decoder.decode(RefreshResponse.self, from: data)
                return await tokenStore.saveRefreshedTokens(
                    tokens.accessToken,
                    tokens.refreshToken,
                    replacing: captured
                )
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error(
                "Scoped refresh failed: status=\(http.statusCode, privacy: .public) body=\(body, privacy: .private)"
            )
            guard shouldInvalidateSessionAfterRefreshFailure(http.statusCode) else {
                return false
            }
            let disposition = await tokenStore.invalidateRejectedRefresh(captured)
            if let disposition,
               !Task.isCancelled,
               await tokenStore.shouldConsumeSessionExpiryEvent(
                   SessionExpiryEvent(account: captured.account, disposition: disposition)
               ),
               !Task.isCancelled {
                let event = SessionExpiryEvent(
                    account: captured.account,
                    disposition: disposition
                )
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    NotificationCenter.default.post(
                        name: .continuumSessionExpired,
                        object: event
                    )
                }
            }
            return false
        } catch {
            await noteServerUnreachable(for: error)
            Self.logger.error("Scoped refresh threw: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Refresh (single-flight)

    /// Refresh tokens at most once per wave of concurrent 401s.
    ///
    /// Algorithm (equivalent to the Kotlin Mutex + double-check):
    /// 1. Check whether another caller already refreshed: if the token now
    ///    stored differs from the token this caller originally sent, it was
    ///    refreshed in the meantime and we can just signal "yes, retry."
    /// 2. Otherwise, if no account refresh is in flight, start one; ordinary
    ///    and captured-identity 401s await the same `Task` so only one network
    ///    call is made.
    /// 3. The in-flight task clears itself after completion so the next 401
    ///    wave can start a fresh refresh.
    ///
    /// Re-entrancy note: each TokenStore check re-captures account owner,
    /// temporary generation, access token, and profile together. A caller can
    /// use a token rotated by another flight only when the rest of that exact
    /// request identity is still current.
    private func refreshTokens(
        expected: CapturedOrdinaryRequestAuth,
        dispatchRevision: UInt64
    ) async -> CapturedOrdinaryRequestAuth? {
        guard !isRequestDispatchBlocked,
              requestDispatchRevision == dispatchRevision else { return nil }
        guard let current = await tokenStore.currentOrdinaryRequestAuth(
            matchingIdentityOf: expected
        ) else {
            return nil
        }
        if current.accessToken != expected.accessToken,
           current.accessToken != nil {
            return current
        }
        guard !isRequestDispatchBlocked,
              requestDispatchRevision == dispatchRevision else { return nil }

        let key = expected.account
        if let existing = inFlightRefreshes[key] {
            refreshFlightJoinObserver?(.ordinary)
            _ = await existing.task.value
            if let current = await tokenStore.currentOrdinaryRequestAuth(
                matchingIdentityOf: expected
            ), current.accessToken != expected.accessToken,
               current.accessToken != nil {
                return current
            }
            return nil
        }

        let task = Task<Bool, Never> { [tokenStore, session, decoder, encoder] in
            await Self.performRefresh(
                expected: key,
                tokenStore: tokenStore,
                session: session,
                decoder: decoder,
                encoder: encoder
            )
        }
        let flightId = UUID()
        inFlightRefreshes[key] = .init(id: flightId, task: task)
        _ = await task.value
        if inFlightRefreshes[key]?.id == flightId {
            inFlightRefreshes.removeValue(forKey: key)
        }
        if let current = await tokenStore.currentOrdinaryRequestAuth(
            matchingIdentityOf: expected
        ), current.accessToken != expected.accessToken,
           current.accessToken != nil {
            return current
        }
        return nil
    }

    private static func performRefresh(
        expected: RefreshAccountIdentity,
        tokenStore: TokenStore,
        session: URLSession,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) async -> Bool {
        guard let captured = await tokenStore.captureRefreshCredential(expected: expected) else {
            Self.logger.error("Refresh skipped: no refresh token stored")
            return false
        }

        guard let url = URL(string: expected.serverURL + "/api/v1/auth/refresh") else {
            Self.logger.error("Refresh skipped: invalid server URL")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try encoder.encode(RefreshRequest(refreshToken: captured.refreshToken))
        } catch {
            Self.logger.error("Refresh encode failed: \(String(describing: error), privacy: .public)")
            return false
        }

        do {
            let (data, response) = try await session.data(for: request)
            // If the surrounding registry switch cancelled us while the
            // network call was in flight, drop the response on the floor
            // rather than writing tokens into what may now be a different
            // server's Keychain slot.
            if Task.isCancelled {
                Self.logger.info("Refresh cancelled post-response; skipping token save")
                return false
            }
            guard let http = response as? HTTPURLResponse else {
                Self.logger.error("Refresh: non-HTTP response")
                return false
            }
            // Refresh bypasses perform(), so feed reachability from here too.
            await MainActor.run {
                ConnectionMonitor.shared.noteServerResponded()
            }
            if (200..<300).contains(http.statusCode) {
                let tokens = try decoder.decode(RefreshResponse.self, from: data)
                return await tokenStore.saveRefreshedTokens(
                    tokens.accessToken,
                    tokens.refreshToken,
                    replacing: captured
                )
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                Self.logger.error("Refresh failed: status=\(http.statusCode, privacy: .public) body=\(body, privacy: .private)")
                guard shouldInvalidateSessionAfterRefreshFailure(http.statusCode) else {
                    return false
                }
                let disposition = await tokenStore.invalidateRejectedRefresh(captured)
                let event = disposition.map {
                    SessionExpiryEvent(account: captured.account, disposition: $0)
                }
                guard let disposition,
                      let event,
                      !Task.isCancelled,
                      await tokenStore.shouldConsumeSessionExpiryEvent(event),
                      !Task.isCancelled else { return false }
                // Tell the UI to route back to login for the current
                // server. The registry entry (URL + display name) is
                // preserved so the user doesn't have to re-add it.
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    NotificationCenter.default.post(
                        name: disposition == .temporarySessionExpired
                            ? .temporaryRemoteAuthExpired
                            : .continuumSessionExpired,
                        object: event
                    )
                }
                return false
            }
        } catch {
            await noteServerUnreachable(for: error)
            Self.logger.error("Refresh threw: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Match Android's refresh-failure classifier. Client/auth rejection is
    /// terminal; rate limits, gateway failures, and server faults are
    /// retryable and must preserve the current credential snapshot.
    static func shouldInvalidateSessionAfterRefreshFailure(_ statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 401 || statusCode == 403
    }
}

// MARK: - Timeout class

/// Per-request timeout class. `.standard` (15s idle) fails fast so a dead
/// server is detected in seconds. `.extended` (90s idle) is for endpoints
/// that legitimately hold the connection while the server does slow work —
/// e.g. subtitle provider fan-out searches (20–30s documented) or playback
/// session planning.
enum HTTPTimeout {
    case standard
    case extended
}

struct HTTPMultipartPart {
    let name: String
    let filename: String
    let contentType: String
    let data: Data
}

// MARK: - Undecoded response

/// A 2xx response handed back undecoded, for callers that need the status or a
/// response header as well as the body. See ``HTTPClient/requestData``.
struct HTTPRawResponse: Sendable {
    let data: Data
    let statusCode: Int
    /// Header names are lowercased on the way in, because HTTP header names
    /// are case-insensitive and a lookup must not depend on the server's
    /// casing.
    let headers: [String: String]

    init(data: Data, statusCode: Int, headers: [AnyHashable: Any]) {
        self.data = data
        self.statusCode = statusCode
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            if let name = name as? String, let value = value as? String {
                normalized[name.lowercased()] = value
            }
        }
        self.headers = normalized
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

// MARK: - Error

enum HTTPError: LocalizedError, CustomStringConvertible {
    case serverUrlNotConfigured
    case requestIdentityChanged
    case invalidURL(String)
    case invalidResponse
    case network(underlying: Error)
    case encodingFailed(underlying: Error)
    case decodingFailed(type: String, underlying: Error)
    case http(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .serverUrlNotConfigured:
            return "Server URL is not configured."
        case .requestIdentityChanged:
            return "The active server or profile changed before the request could start."
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid server response."
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode request body: \(error.localizedDescription)"
        case .decodingFailed(let type, let error):
            return "Failed to decode \(type): \(error.localizedDescription)"
        case .http(let statusCode, let body):
            if let message = Self.parseServerMessage(body) {
                return message
            }
            return "Server returned status \(statusCode)"
        }
    }

    /// A log-safe representation that never includes request URLs, response
    /// bodies, auth material, or the localized text of an underlying error.
    var description: String {
        switch self {
        case .serverUrlNotConfigured:
            return "server_url_not_configured"
        case .requestIdentityChanged:
            return "request_identity_changed"
        case .invalidURL:
            return "invalid_url"
        case .invalidResponse:
            return "invalid_response"
        case .network:
            return "network_error"
        case .encodingFailed:
            return "encoding_failed"
        case .decodingFailed(let type, _):
            return "decoding_failed(type: \(type))"
        case .http(let statusCode, _):
            return "http_error(status: \(statusCode))"
        }
    }

    var statusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    /// Machine-readable identifier from the server's JSON error envelope
    /// (e.g. `profile_limit_reached`). Callers that want to branch on the
    /// specific condition — rather than just showing `errorDescription` —
    /// can match on this without re-parsing the body.
    var serverErrorCode: String? {
        if case .http(_, let body) = self {
            return Self.parseServerError(body)?.error
        }
        return nil
    }

    /// The server's JSON error shape, mirrored from Go `errorResponse` in
    /// `internal/api/handlers/auth.go`. Both fields are optional because
    /// not every failing endpoint emits a body, and some middleware emits
    /// just plain text (e.g. router 404s).
    private struct ServerError: Decodable {
        let error: String?
        let message: String?
    }

    private static func parseServerError(_ body: String?) -> ServerError? {
        guard let body, !body.isEmpty,
              let data = body.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ServerError.self, from: data)
        else { return nil }
        return parsed
    }

    private static func parseServerMessage(_ body: String?) -> String? {
        guard let parsed = parseServerError(body) else { return nil }
        if let message = parsed.message, !message.isEmpty { return message }
        return nil
    }
}

// MARK: - Internal helpers

/// Sentinel used to satisfy `send<T>` for generic calls that expect an
/// empty/void response. Not public.
private struct EmptyResponse: Decodable {
    static let empty = EmptyResponse()
    init() {}
    init(from decoder: Decoder) throws {}
}

/// Type-erased `Encodable` so `send` can accept `(any Encodable)?` bodies
/// and hand them to `JSONEncoder` (which needs a concrete conforming type).
private struct AnyEncodable: Encodable {
    private let wrapped: any Encodable

    init(_ wrapped: any Encodable) {
        self.wrapped = wrapped
    }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}
