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
        path: String,
        quietStatuses: Set<Int> = [],
        diagnosticPath: String? = nil
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
        try ensureSuccess(data, response, method: "GET", quietStatuses: quietStatuses)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logDecodingFailure(
                type: String(describing: T.self),
                path: diagnosticPath ?? path,
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
                    #if os(iOS) || os(tvOS)
                    Self.logRefreshRetry(
                        method: method,
                        path: path,
                        outcome: HTTPDiagnosticsOutcome.retried
                    )
                    #endif
                    (data, response) = try await perform(
                        request: request,
                        timeout: timeout,
                        dispatchRevision: dispatchRevision
                    )
                } else {
                    #if os(iOS) || os(tvOS)
                    // Refresh reported success but the recapture disagreed, so
                    // the original 401 stands. Worth its own line: from the
                    // outside this is indistinguishable from "refresh never
                    // ran", and the two have completely different causes.
                    Self.logRefreshRetry(
                        method: method,
                        path: path,
                        outcome: HTTPDiagnosticsOutcome.notRetried
                    )
                    #endif
                }
            } else if response.statusCode == 401, shouldAttemptRefresh(path: path) {
                // Refresh was eligible but declined (wrong credential owner,
                // no refresh token, dispatch blocked). `shouldAttemptRefresh`
                // is re-checked so a 401 from `/auth/login` — an ordinary wrong
                // password, not a refresh failure — is not reported as one.
                #if os(iOS) || os(tvOS)
                Self.logRefreshRetry(
                    method: method,
                    path: path,
                    outcome: HTTPDiagnosticsOutcome.notRetried
                )
                #endif
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
            // `failureCodingPath` rather than `context.codingPath`, so this line
            // and the diagnostics line below can never disagree about where the
            // decode failed — see that function for why the two differ on
            // `keyNotFound`.
            let failurePath = codingPathString(failureCodingPath(decodingError))
            switch decodingError {
            case .keyNotFound(let key, let context):
                detail += "keyNotFound key=\(key.stringValue) path=\(failurePath) — \(context.debugDescription)"
            case .typeMismatch(_, let context):
                detail += "typeMismatch path=\(failurePath) — \(context.debugDescription)"
            case .valueNotFound(_, let context):
                detail += "valueNotFound path=\(failurePath) — \(context.debugDescription)"
            case .dataCorrupted(let context):
                detail += "dataCorrupted path=\(failurePath) — \(context.debugDescription)"
            @unknown default:
                detail += String(describing: decodingError)
            }
        } else {
            detail += String(describing: error)
        }
        logger.error("\(detail, privacy: .public) body=\(bodyPreview, privacy: .private)")
        #if os(iOS) || os(tvOS)
        recordDecodingFailureDiagnostic(type: type, path: path, error: error)
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// The body-free classification of a decode failure, for diagnostics.
    ///
    /// A model/JSON mismatch is close to unreproducible from a bug report: it
    /// depends on one server version, one library's data, and often one item,
    /// none of which the user can describe. The OSLog line above carries the
    /// body at `.private`, which is exactly right for a Console session
    /// attached to a developer's own device and exactly wrong for an uploaded
    /// report — so this records only *shape*: which type, which route, which
    /// `DecodingError` case, and where in the payload.
    ///
    /// **The response body must never reach this function.** It is not a
    /// parameter, so it cannot be interpolated in by a later edit. That is the
    /// invariant; keep it structural rather than a comment on a call site.
    ///
    /// Essential tier despite `error_code`/`msg` being derived text: a decode
    /// failure is rare (a working build produces zero), it breaks a screen
    /// outright, and the same conditions that make it worth capturing make it
    /// impossible to ask the user to reproduce with Debug Logging on.
    private static func recordDecodingFailureDiagnostic(type: String, path: String, error: Error) {
        let codingPath = (error as? DecodingError).map(failureCodingPath(_:)) ?? []
        // The DecodingError's `debugDescription` and its failing value are both
        // deliberately absent: the first quotes payload text and the second is
        // payload. The case name lives in `error_code`; the location lives in
        // the rendered coding path, which templates any server-supplied key.
        DiagTrace.log(
            .essential,
            level: .error,
            category: .network,
            tag: "Decode",
            message: """
                decode failed \
                type=\(HTTPDecodingDiagnostics.typeName(type)) \
                coding path \(HTTPDecodingDiagnostics.codingPath(codingPath))
                """,
            attrs: [
                "path": .string(HTTPDiagnosticsPath.attribute(forRawPath: path)),
                "outcome": .string(HTTPDiagnosticsOutcome.decodeFailed),
                "error_code": .string(HTTPDiagnosticsErrorCode.classify(decoding: error)),
            ]
        )
    }
    #endif

    /// Where in the payload a `DecodingError` actually failed.
    ///
    /// For every case but one this is just `context.codingPath`. `keyNotFound`
    /// is the exception, and the difference is the whole point of this helper:
    /// Foundation supplies the absent key *separately* from the context, whose
    /// `codingPath` describes only the container that was missing it. Reading
    /// the context alone therefore reports a missing top-level field as
    /// `<root>` and a nested one as its enclosing object — dropping the exact
    /// field name, which is the only part of a client/server model mismatch
    /// that identifies what to fix.
    ///
    /// Appending the key is safe for the same reason the rest of the path is: a
    /// `CodingKey` is a compile-time model key for a struct-shaped model, and
    /// for a dictionary-shaped one the renderers template it like any other
    /// server-supplied value. The response body is not involved either way.
    ///
    /// Not `private` so the `keyNotFound` arm can be asserted directly: losing
    /// the key again would be invisible — the log line still renders, just
    /// pointing at the parent container.
    static func failureCodingPath(_ error: DecodingError) -> [CodingKey] {
        switch error {
        case .keyNotFound(let key, let context):
            return context.codingPath + [key]
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            return context.codingPath
        @unknown default:
            return []
        }
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
                #if os(iOS) || os(tvOS)
                Self.logRefreshRetry(
                    method: method,
                    path: path,
                    outcome: HTTPDiagnosticsOutcome.retried
                )
                #endif
                let (retryData, retryResponse) = try await perform(
                    request: retry,
                    timeout: timeout,
                    dispatchRevision: dispatchRevision
                )
                try ensureSuccess(retryData, retryResponse, method: method, quietStatuses: quietStatuses)
                return (retryData, retryResponse)
            }
            #if os(iOS) || os(tvOS)
            // Reached only when the refresh did not yield a usable, still-current
            // credential — no captured auth, the flight failed, or the identity
            // moved underneath it. The original 401 is about to be thrown.
            Self.logRefreshRetry(
                method: method,
                path: path,
                outcome: HTTPDiagnosticsOutcome.notRetried
            )
            #endif
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
        attachIdentityAndTrace(&request, path: path, credentials: attached)
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
        attachIdentityAndTrace(&request, path: path, credentials: attached)
    }

    /// Attaches the shared device/client identity headers and emits the
    /// one-line request trace. Both the ordinary and legacy auth paths end
    /// here so a field added to either the header set or the trace reaches
    /// both instead of drifting between two copies.
    ///
    /// `credentials` is what the caller already attached (auth, profile,
    /// profileToken); nothing here is user data, so the whole line is
    /// logged `.public`.
    private func attachIdentityAndTrace(
        _ request: inout URLRequest,
        path: String,
        credentials: [String]
    ) {
        let device = AppleDeviceIdentity.current
        device.applyHeaders(to: &request)
        let trace = credentials + [
            "device=\(device.platform)/\(device.clientFamily)",
            // Channel included deliberately: it is the only field that
            // separates a re-signed sideload build from the TestFlight build
            // of the same version+build, which is exactly the question a
            // user-supplied log has to answer.
            "client=\(device.clientName) \(device.appVersion) (\(device.appBuild)) \(device.channel)"
        ]
        let method = request.httpMethod ?? ""
        let attachedDesc = trace.joined(separator: ", ")
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
        AppleDeviceIdentity.current.applyHeaders(to: &request)
    }

    // MARK: - Response handling

    /// The one place every *ordinary* request in the app actually hits the
    /// network.
    ///
    /// Network diagnostics are instrumented here rather than at any caller.
    /// There are dozens of call sites above this (`get`, `post`, `requestData`,
    /// the raw and multipart variants, the 401 retries), and instrumenting them
    /// individually would produce a ring full of near-duplicate lines with
    /// inconsistent outcome vocabulary. Every exit below is classified exactly
    /// once, so "one request, one line" holds by construction.
    ///
    /// Token refresh is the sole request shape that does not pass through here —
    /// it is a detached single-flight `Task` with its own identity rules — so it
    /// has a parallel chokepoint in
    /// ``performRefreshTransport(request:session:)``. Those two functions are
    /// the only places in this file that may call `session.data(for:)`; adding a
    /// third would reintroduce an unclassified path.
    private func perform(
        request: URLRequest,
        timeout: HTTPTimeout = .standard,
        dispatchRevision: UInt64,
        reportReachability: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS) || os(tvOS)
        // Templated once, at capture, before anything can log it. `request.url`
        // carries the full absolute URL — host, port, and query string — and
        // none of that may ever reach a log line, so the raw URL is
        // deliberately never held in a variable the emission sites below can
        // reach: they can only see the already-templated string.
        let diagnosticsPath = HTTPDiagnosticsPath.attribute(for: request.url)
        let diagnosticsMethod = request.httpMethod ?? "GET"
        let startedAt = ContinuousClock.now
        #endif
        // A cancellation pass takes asynchronous snapshots of both sessions.
        // Dispatching between those snapshots could let an old-identity
        // request start after its session was already enumerated and survive
        // a registry or temporary-owner transition. Reject it; waiting would
        // send a request built from credentials captured before the switch.
        do {
            try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        } catch {
            #if os(iOS) || os(tvOS)
            // Essential: an identity-change rejection is invisible to the user
            // as anything but "it didn't load", and it is the signature of the
            // server-switch races this class exists to prevent.
            DiagTrace.log(
                .essential,
                level: .warning,
                category: .network,
                tag: "HTTP",
                message: "request rejected",
                attrs: [
                    "method": .string(diagnosticsMethod),
                    "path": .string(diagnosticsPath),
                    "outcome": .string(HTTPDiagnosticsOutcome.identityChanged),
                    "error_code": .string(HTTPDiagnosticsOutcome.identityChanged),
                ]
            )
            #endif
            throw error
        }
        let data: Data
        let response: URLResponse
        do {
            let session = timeout == .extended ? longWaitSession : session
            (data, response) = try await session.data(for: request)
        } catch {
            if isRequestDispatchBlocked || requestDispatchRevision != dispatchRevision {
                #if os(iOS) || os(tvOS)
                DiagTrace.log(
                    .essential,
                    level: .warning,
                    category: .network,
                    tag: "HTTP",
                    message: "request rejected",
                    attrs: [
                        "method": .string(diagnosticsMethod),
                        "path": .string(diagnosticsPath),
                        "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
                        "outcome": .string(HTTPDiagnosticsOutcome.identityChanged),
                        "error_code": .string(HTTPDiagnosticsOutcome.identityChanged),
                    ]
                )
                #endif
                throw HTTPError.requestIdentityChanged
            }
            // Feed ConnectionMonitor from every transport failure so the app
            // learns "server down" passively. Cancellation says nothing about
            // reachability, so it is excluded.
            if reportReachability {
                await Self.noteServerUnreachable(for: error)
            }
            #if os(iOS) || os(tvOS)
            // Split on the same axis reachability does. A cancellation is
            // ordinary (screen dismissed, server switched) and high-volume, so
            // it is verbose; a real transport failure is the "it won't connect"
            // evidence this instrumentation exists for, so it is essential.
            let isCancellation = (error as? URLError)?.code == .cancelled
            DiagTrace.log(
                isCancellation ? .verbose : .essential,
                level: isCancellation ? .debug : .error,
                category: .network,
                tag: "HTTP",
                message: isCancellation ? "request cancelled" : "transport failure",
                attrs: [
                    "method": .string(diagnosticsMethod),
                    "path": .string(diagnosticsPath),
                    "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
                    "outcome": .string(
                        isCancellation
                            ? HTTPDiagnosticsOutcome.cancelled
                            : HTTPDiagnosticsOutcome.transportError
                    ),
                    "error_code": .string(HTTPDiagnosticsErrorCode.classify(transport: error)),
                ]
            )
            #endif
            throw HTTPError.network(underlying: error)
        }
        if let responseReceivedBarrier {
            await responseReceivedBarrier()
        }
        // URLSession cancellation is best-effort: a completed response can
        // race the transition's task enumeration. Reject it before it can
        // update reachability or flow into any response/cache consumer.
        do {
            try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        } catch {
            #if os(iOS) || os(tvOS)
            DiagTrace.log(
                .essential,
                level: .warning,
                category: .network,
                tag: "HTTP",
                message: "response rejected",
                attrs: [
                    "method": .string(diagnosticsMethod),
                    "path": .string(diagnosticsPath),
                    "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
                    "outcome": .string(HTTPDiagnosticsOutcome.identityChanged),
                    "error_code": .string(HTTPDiagnosticsOutcome.identityChanged),
                ]
            )
            #endif
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            #if os(iOS) || os(tvOS)
            DiagTrace.log(
                .essential,
                level: .error,
                category: .network,
                tag: "HTTP",
                message: "non-http response",
                attrs: [
                    "method": .string(diagnosticsMethod),
                    "path": .string(diagnosticsPath),
                    "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
                    "outcome": .string(HTTPDiagnosticsOutcome.invalidResponse),
                    "error_code": .string(HTTPDiagnosticsOutcome.invalidResponse),
                ]
            )
            #endif
            throw HTTPError.invalidResponse
        }
        // Any HTTP response — success or error status — proves the server is
        // alive.
        if reportReachability {
            await MainActor.run {
                ConnectionMonitor.shared.noteServerResponded()
            }
        }
        #if os(iOS) || os(tvOS)
        // Verbose, and this is the highest-leverage volume decision in the
        // whole subsystem: browsing a library issues hundreds of successful
        // requests a minute, and at essential tier they would evict every
        // other category from the 4000-line ring long before the user got to
        // Report a Problem. The failing lines above are what a connectivity
        // report needs; timing and status for the ones that worked is context
        // you opt into with Debug Logging.
        //
        // `outcome` is attached only for 2xx. A non-2xx is not classifiable
        // here — whether a 404 is a fault or the expected answer to an
        // existence probe is knowledge only `ensureSuccess` has — so this line
        // records the status and leaves the verdict to the essential line
        // `ensureSuccess` emits. Guessing here would mean every quiet 404 also
        // reads as an error somewhere in the report.
        var responseAttrs: [String: DiagLogAttributeValue] = [
            "method": .string(diagnosticsMethod),
            "path": .string(diagnosticsPath),
            "status": .int(http.statusCode),
            "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
        ]
        if (200..<300).contains(http.statusCode) {
            responseAttrs["outcome"] = .string(HTTPDiagnosticsOutcome.success)
        }
        DiagTrace.log(
            .verbose,
            level: .debug,
            category: .network,
            tag: "HTTP",
            message: "response received",
            attrs: responseAttrs
        )
        #endif
        return (data, http)
    }

    /// One token-refresh round trip, classified exactly as ``perform`` classifies
    /// an ordinary request.
    ///
    /// Refresh is the one thing in this file that legitimately does not funnel
    /// through `perform`: it runs as a detached single-flight `Task` off the
    /// actor, carries no dispatch revision, and deliberately builds its own
    /// request so it can never pick up the ambient auth headers. That made it
    /// invisible to network diagnostics, and invisible in the worst place — a
    /// refresh that times out, fails TLS, or is rejected outright is the *cause*
    /// of the 401 the user notices, yet it surfaced only as the generic "401 not
    /// retried" line, which records that the retry did not happen and nothing
    /// about why.
    ///
    /// Both refresh implementations (scoped and ordinary) call this so the
    /// classifier exists once. It only observes: the original error is rethrown
    /// untouched, and a non-2xx or non-HTTP response is returned rather than
    /// turned into a throw, so each caller's own cancellation checks,
    /// reachability reporting, and session-invalidation rules are unchanged.
    ///
    /// **No credential can reach a log line from here.** The request body holds a
    /// refresh token and a 2xx response body holds two more, but neither
    /// `httpBody`, `allHTTPHeaderFields`, nor `data` is ever read: the only
    /// values emitted are the method, the templated path, the status, a
    /// duration, and the two closed-vocabulary classifications. The response
    /// body is in scope in this function, so unlike
    /// ``recordDecodingFailureDiagnostic(type:path:error:)`` that is a rule
    /// rather than a structural guarantee — keep the attribute list literal.
    private static func performRefreshTransport(
        request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        #if os(iOS) || os(tvOS)
        // Templated once, at capture, exactly as in `perform`: `request.url` is
        // the absolute refresh URL and carries the server's host, which may
        // never reach a log line. The emission sites below can only see the
        // already-templated string.
        let diagnosticsPath = HTTPDiagnosticsPath.attribute(for: request.url)
        let diagnosticsMethod = request.httpMethod ?? "POST"
        let startedAt = ContinuousClock.now
        #endif
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            #if os(iOS) || os(tvOS)
            // Split on the same axis as `perform`, and for the same reason: a
            // cancelled refresh is ordinary (a server switch tore down the
            // flight) and says nothing about the server, while a real transport
            // failure is the evidence a stuck-auth report needs.
            let isCancellation = (error as? URLError)?.code == .cancelled
            DiagTrace.log(
                isCancellation ? .verbose : .essential,
                level: isCancellation ? .debug : .error,
                category: .network,
                tag: "Auth",
                message: isCancellation ? "refresh cancelled" : "refresh transport failure",
                attrs: [
                    "method": .string(diagnosticsMethod),
                    "path": .string(diagnosticsPath),
                    "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
                    "outcome": .string(
                        isCancellation
                            ? HTTPDiagnosticsOutcome.cancelled
                            : HTTPDiagnosticsOutcome.transportError
                    ),
                    "error_code": .string(HTTPDiagnosticsErrorCode.classify(transport: error)),
                ]
            )
            #endif
            throw error
        }
        #if os(iOS) || os(tvOS)
        // One deliberate divergence from `perform`: there, a non-2xx carries no
        // `outcome` because only `ensureSuccess` knows whether the caller
        // expected it. Nothing downstream of a refresh calls `ensureSuccess` —
        // the status is consumed here and by
        // ``shouldInvalidateSessionAfterRefreshFailure(_:)`` — so this line has
        // to carry the verdict itself or a rejected refresh stays unclassified.
        // Tiering follows: a rejected refresh is rare and terminal for the
        // session, so it is essential, while the successful case is bounded but
        // uninteresting and stays verbose alongside `perform`'s response line.
        let status = (response as? HTTPURLResponse)?.statusCode
        let isSuccess = status.map { (200..<300).contains($0) } ?? false
        let message: String = if status == nil {
            "refresh non-http response"
        } else if isSuccess {
            "refresh succeeded"
        } else {
            "refresh rejected"
        }
        var attrs: [String: DiagLogAttributeValue] = [
            "method": .string(diagnosticsMethod),
            "path": .string(diagnosticsPath),
            "duration_ms": .int(Self.elapsedMilliseconds(since: startedAt)),
        ]
        if let status {
            attrs["status"] = .int(status)
            attrs["outcome"] = .string(
                isSuccess ? HTTPDiagnosticsOutcome.success : HTTPDiagnosticsOutcome.httpError
            )
            if !isSuccess {
                attrs["error_code"] = .string(HTTPDiagnosticsErrorCode.http(status: status))
            }
        } else {
            attrs["outcome"] = .string(HTTPDiagnosticsOutcome.invalidResponse)
            attrs["error_code"] = .string(HTTPDiagnosticsOutcome.invalidResponse)
        }
        DiagTrace.log(
            isSuccess ? .verbose : .essential,
            level: isSuccess ? .debug : .error,
            category: .network,
            tag: "Auth",
            message: message,
            attrs: attrs
        )
        #endif
        return (data, response)
    }

    #if os(iOS) || os(tvOS)
    /// Monotonic elapsed milliseconds. `ContinuousClock` rather than `Date` so
    /// a wall-clock change mid-request cannot put a negative or absurd
    /// `duration_ms` into a report. Saturating arithmetic for the same reason:
    /// a garbage duration is worse than a clamped one.
    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        let milliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        guard !milliseconds.overflow else { return Int(Int32.max) }
        let total = milliseconds.partialValue
            .addingReportingOverflow(attoseconds / 1_000_000_000_000_000)
        guard !total.overflow else { return Int(Int32.max) }
        return Int(max(0, total.partialValue))
    }
    #endif

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
            let isQuiet = quietStatuses.contains(response.statusCode)
            // A status the caller treats as an expected signal (e.g. a 404
            // existence probe) is demoted to debug so it doesn't read as a
            // failure in the log; everything else stays at error level.
            if isQuiet {
                Self.logger.debug("HTTP \(response.statusCode, privacy: .public) \(method, privacy: .public)")
            } else {
                Self.logger.error("HTTP \(response.statusCode, privacy: .public) \(method, privacy: .public)")
            }
            #if os(iOS) || os(tvOS)
            // The quiet/real split has to survive into diagnostics, and on
            // three axes at once, or a report reads as full of errors that
            // never happened: tier (a quiet status is expected traffic, so
            // verbose), level (.debug, not .error), and `outcome` (`quiet`,
            // never `http_error`). A reader filtering a report to errors must
            // not see the 404 that means "this item is not a favorite".
            //
            // This is the only line that carries a real HTTP failure at
            // essential tier — `perform`'s per-response line is verbose — so
            // it has to be self-sufficient. `response.url` is the resolved
            // URL, complete with host and query string, and it goes through
            // ``HTTPDiagnosticsPath`` for exactly that reason: it keeps only
            // the templated path. It is never read any other way here.
            DiagTrace.log(
                isQuiet ? .verbose : .essential,
                level: isQuiet ? .debug : .error,
                category: .network,
                tag: "HTTP",
                message: isQuiet ? "expected status" : "http error",
                attrs: [
                    "method": .string(method),
                    "path": .string(HTTPDiagnosticsPath.attribute(for: response.url)),
                    "status": .int(response.statusCode),
                    "outcome": .string(
                        isQuiet ? HTTPDiagnosticsOutcome.quiet : HTTPDiagnosticsOutcome.httpError
                    ),
                    "error_code": .string(
                        HTTPDiagnosticsErrorCode.http(status: response.statusCode)
                    ),
                ]
            )
            #endif
            throw HTTPError.http(
                statusCode: response.statusCode,
                body: bodyStr
            )
        }
    }

    #if os(iOS) || os(tvOS)
    /// The single emitter for the 401 refresh-retry decision, shared by the
    /// scoped (`requestData`) and ordinary (`performWithAuthRetry`) paths so
    /// both spell the outcome identically.
    ///
    /// Essential tier. A 401 wave is rare, bounded (one refresh per wave, by
    /// construction), and is the exact evidence needed to tell "the user's
    /// session expired and recovered" apart from "the client is stuck in an
    /// auth loop" — the second is invisible in a report without it.
    ///
    /// `attempt: 2` is what distinguishes a retry line from the original
    /// request's line; the original is the `perform` line at attempt 1, which
    /// carries no `attempt` attribute. Only ordinals go in: nothing about the
    /// credential itself — presence, length, prefix, expiry, or whether it
    /// actually rotated — is representable in this call, by design.
    ///
    /// Note on `attempt` and the hosted collector: `network.attempt` is in the
    /// canonical attribute registry, but `attempt` is *also* in the hosted
    /// collector's `FORBIDDEN_KEYS`, so a hosted bundle carrying it would be
    /// privacy-*flagged* (the report still processes to `ready`; only the
    /// `privacy_fields` check fails) on every session containing a routine 401
    /// refresh — all false positives. That conflict is now RESOLVED at the
    /// bundle boundary rather than here: `attempt` is withheld from
    /// `DiagnosticsBundleBuilder.hostedAttributeRegistry`, exactly as
    /// `playback.session_id` is, so it is stripped from hosted bundles while
    /// self-hosted uploads keep it. Emit it unconditionally; do not special-case
    /// destinations in this function.
    ///
    /// That makes `msg` load-bearing, not merely a fallback: on hosted evidence
    /// the attribute genuinely is absent, and "401 retry" versus "401 not
    /// retried" is the only thing carrying the distinction. Keep those two
    /// strings self-sufficient.
    ///
    /// `path` here is the caller's route argument rather than a built URL, and
    /// it still goes through ``HTTPDiagnosticsPath``: callers interpolate ids
    /// into it (`"/api/v1/items/\(contentId)"`), and that helper also truncates
    /// at the first `?` or `#`, so neither an id nor a query string can leak
    /// through this line.
    private static func logRefreshRetry(method: String, path: String, outcome: String) {
        let isRetry = outcome == HTTPDiagnosticsOutcome.retried
        var attrs: [String: DiagLogAttributeValue] = [
            "method": .string(method),
            "path": .string(HTTPDiagnosticsPath.attribute(forRawPath: path)),
            "status": .int(401),
            "outcome": .string(outcome),
        ]
        if isRetry { attrs["attempt"] = .int(2) }
        DiagTrace.log(
            .essential,
            level: isRetry ? .info : .warning,
            category: .network,
            tag: "Auth",
            message: isRetry ? "401 retry" : "401 not retried",
            attrs: attrs
        )
    }
    #endif

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
        let ownerMatchesExpectedServer = switch auth.credentialOwner {
        case .temporary:
            true
        case .persistentServer(let credentialServerId):
            credentialServerId == expected.serverId
        }
        guard ownerMatchesExpectedServer,
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
            let (data, response) = try await performRefreshTransport(
                request: request,
                session: session
            )
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
                        name: disposition == .temporarySessionExpired
                            ? .temporaryRemoteAuthExpired
                            : .continuumSessionExpired,
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
            let (data, response) = try await performRefreshTransport(
                request: request,
                session: session
            )
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

#if os(iOS) || os(tvOS)

// MARK: - Network diagnostics vocabulary

/// The single chokepoint through which every `network.path` attribute in this
/// file is produced. Nothing in `HTTPClient` or `ConnectionMonitor` may build a
/// path attribute any other way.
///
/// It is a second pass on top of
/// ``DiagnosticsPathTemplate/templatedPath(forRawPath:)``, not a replacement
/// for it, because that helper answers "does this segment look like an
/// identifier?" while the hosted collector asks a broader question of an
/// `attrs.path` value. Two categories of real Silo route pass the first check
/// and are still rejected:
///
/// * **Dotted segments.** `/api/v1/settings/values/downloads.default_quality`
///   is a static route with a static key, and every segment is a legal
///   identifier — but the collector reads `downloads.default_quality` as a
///   hostname-shaped token and rejects the report. It maintains a hand-curated
///   `SAFE_DOTTED_SETTING_KEYS` allowlist that our generated `SettingKey` table
///   has already outgrown: of 53 shipping keys, 28 are *not* on it, including
///   every `nav.*`, `ui.library_page_state`, and `subtitle.matches_device`. We
///   cannot fix that from this repo and must not gamble a whole bundle on the
///   allowlist being current, so any dotted segment is templated.
/// * **Empty and non-ASCII segments.** `//`, `/a b/`, percent-encoding, and
///   anything outside `[A-Za-z0-9_-]` are all rejected or ambiguous under the
///   collector's decode-then-match pass.
///
/// The rule is therefore an allowlist, not a denylist: a segment survives
/// verbatim only if it is an already-templated `{id}`, or a letter-initial
/// ASCII token that the emission templater also considers safe. Everything
/// else becomes `{id}`. Failing closed costs some route legibility — a
/// settings key reads as `{id}` — and that is the correct trade against
/// silently discarding the user's entire report.
///
/// Verified against `silo-diagnostics/src/privacy.ts` over ~700k generated
/// paths (random text, and route-shaped inputs assembled from real Silo
/// prefixes with adversarial tail segments), plus every route literal scraped
/// from `iosApp/iosApp/Networking/` with realistic runtime substitutions:
/// zero rejections. Re-run that check before relaxing the allowlist.
enum HTTPDiagnosticsPath {
    static func attribute(for url: URL?) -> String {
        guard let url else { return DiagnosticsPathTemplate.placeholder }
        return hardened(DiagnosticsPathTemplate.templatedPath(for: url))
    }

    /// For a route the caller supplied as text. `templatedPath(forRawPath:)`
    /// truncates at the first `?` or `#`, so a query string cannot survive
    /// even if a caller passes one.
    static func attribute(forRawPath rawPath: String) -> String {
        hardened(DiagnosticsPathTemplate.templatedPath(forRawPath: rawPath))
    }

    private static func hardened(_ path: String) -> String {
        // Empty segments are dropped rather than preserved, so a protocol-
        // relative or doubled-slash path cannot reach the collector as `//…`,
        // which it parses as an authority rather than a path.
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment -> String in
                let candidate = String(segment)
                return isSafeSegment(candidate) ? candidate : DiagnosticsPathTemplate.placeholder
            }
        return "/" + segments.joined(separator: "/")
    }

    private static func isSafeSegment(_ value: String) -> Bool {
        // An already-templated segment is the collector's own TEMPLATE_SEGMENT
        // shape and is always accepted.
        if value == DiagnosticsPathTemplate.placeholder { return true }
        guard let first = value.first, first.isASCII, first.isLetter else { return false }
        let isPlainToken = value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
        // The emission-private check is re-applied rather than assumed: this
        // function is also reachable for a segment the caller assembled, and
        // an allowlist that trusted its input would be no allowlist at all.
        return isPlainToken && !DiagnosticsPathTemplate.isEmissionPrivateSegment(value)
    }
}

/// The closed vocabulary for `network.outcome` and `network.error_code`.
///
/// Every value here is a fixed literal, chosen so that reading a report means
/// grouping by a small stable set rather than by whatever
/// `localizedDescription` a given OS build produced. Three constraints shaped
/// the list, and all three are easy to violate accidentally:
///
/// 1. **No free-form error text ever becomes an attribute.** `URLError` and
///    `DecodingError` descriptions embed the failing URL, the host, and the
///    coding path; classifying to a literal is what keeps them out.
/// 2. **The hosted collector scans attribute *values*, not just keys.** Its
///    `PRIVATE_ID_IN_TEXT` rule rejects `<prefix>_<8+ chars>` for prefixes
///    including `server`, `request`, and `session` — so `request_identity_changed`
///    (which is `HTTPError.description`) and `server_certificate_untrusted` are
///    both rejected outright, while `identity_changed` and
///    `tls_certificate_untrusted` pass. Every literal below was run through
///    `silo-diagnostics/src/privacy.ts`; do not edit one without re-checking it.
/// 3. **`outcome` and `error_code` are orthogonal.** `outcome` answers "what
///    happened to this request" and is always present; `error_code` narrows
///    *why* and is present only on failures.
enum HTTPDiagnosticsOutcome {
    /// 2xx.
    static let success = "success"
    /// Non-2xx that the caller declared expected via `quietStatuses` (e.g. the
    /// 404 of an existence probe). Deliberately distinct from `http_error`:
    /// `ensureSuccess` demotes these in OSLog and diagnostics must not
    /// re-promote them into something a reader triages as a fault.
    static let quiet = "quiet"
    /// Non-2xx the caller did not expect.
    static let httpError = "http_error"
    /// No HTTP response at all — connection refused, DNS, TLS, timeout.
    static let transportError = "transport_error"
    /// URLSession cancellation. Says nothing about the server, and is
    /// deliberately not a `transport_error`, matching the reachability rule in
    /// ``HTTPClient/noteServerUnreachable(for:)``.
    static let cancelled = "cancelled"
    /// Rejected because the active server/profile changed around the request.
    static let identityChanged = "identity_changed"
    /// A response arrived that was not an `HTTPURLResponse`.
    static let invalidResponse = "invalid_response"
    /// The bytes arrived but did not match the Swift model.
    static let decodeFailed = "decode_failed"
    /// A 401 was retried under a refreshed credential.
    static let retried = "retried"
    /// A 401 refresh either did not run or produced no usable new credential,
    /// so the original 401 stands.
    static let notRetried = "not_retried"
    /// Reachability transitions.
    static let reachable = "reachable"
    static let unreachable = "unreachable"
    static let online = "online"
    static let offline = "offline"
}

enum HTTPDiagnosticsErrorCode {
    /// Classifies a transport failure into a stable literal.
    ///
    /// A non-`URLError` cannot be classified, and its text is not safe to log,
    /// so it falls through to `transport_other` rather than leaking a
    /// description. Unmapped `URLError` codes render as `urlerror_<n>`: the
    /// numeric code is a documented Foundation constant, carries no user data,
    /// and keeps a novel failure legible instead of collapsing it into "other".
    static func classify(transport error: Error) -> String {
        guard let urlError = error as? URLError else { return "transport_other" }
        switch urlError.code {
        case .cancelled: return "cancelled"
        case .timedOut: return "timed_out"
        case .cannotConnectToHost: return "cannot_connect_to_host"
        case .cannotFindHost: return "cannot_find_host"
        case .dnsLookupFailed: return "dns_lookup_failed"
        case .notConnectedToInternet: return "not_connected_to_internet"
        case .networkConnectionLost: return "network_connection_lost"
        // Renamed from Foundation's `serverCertificate*` spelling on purpose:
        // the collector's PRIVATE_ID_IN_TEXT rule rejects any `server_<token>`
        // value, so `server_certificate_untrusted` would fail the bundle.
        case .secureConnectionFailed: return "tls_handshake_failed"
        case .serverCertificateUntrusted: return "tls_certificate_untrusted"
        case .serverCertificateHasBadDate: return "tls_certificate_expired"
        case .serverCertificateNotYetValid: return "tls_certificate_not_yet_valid"
        case .serverCertificateHasUnknownRoot: return "tls_certificate_unknown_root"
        case .clientCertificateRejected: return "tls_client_certificate_rejected"
        case .appTransportSecurityRequiresSecureConnection: return "app_transport_security_blocked"
        case .internationalRoamingOff: return "international_roaming_off"
        case .dataNotAllowed: return "data_not_allowed"
        case .callIsActive: return "call_is_active"
        case .badServerResponse: return "malformed_reply"
        case .httpTooManyRedirects: return "http_too_many_redirects"
        case .resourceUnavailable: return "resource_unavailable"
        case .cannotLoadFromNetwork: return "cannot_load_from_network"
        default: return "urlerror_\(urlError.code.rawValue)"
        }
    }

    /// Classifies a decode failure by `DecodingError` case only. The failing
    /// value, the response body, and the debug description are all excluded —
    /// each can contain server data — and the coding path travels in `msg`,
    /// where it is rendered separately.
    static func classify(decoding error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "decoding_other" }
        switch decodingError {
        case .keyNotFound: return "key_not_found"
        case .typeMismatch: return "type_mismatch"
        case .valueNotFound: return "value_not_found"
        case .dataCorrupted: return "data_corrupted"
        @unknown default: return "decoding_other"
        }
    }

    /// `http_<status>`, so a report can be grouped by status without parsing
    /// the numeric `status` attribute out of every line.
    static func http(status: Int) -> String {
        "http_\(status)"
    }
}

/// Renders the two free-text parts of a decode-failure line — the Swift type
/// and the `DecodingError` coding path — into `msg`.
///
/// This is the one place in network instrumentation where model-derived text,
/// rather than a fixed literal, reaches a log line, so it is the one place that
/// needs its own escape analysis. The response body never appears here; only a
/// Swift type name and `CodingKey`s do. Both are compile-time constants *for a
/// struct-shaped model*, but not for a dictionary-shaped one: the settings API
/// decodes opaque JSON whose object keys are server-defined setting keys, so a
/// `CodingKey` there is runtime data, not source text.
///
/// The rules below are deliberately stricter than
/// ``DiagnosticsPathTemplate/isEmissionPrivateSegment(_:)``, which answers a
/// *path-context* question. `msg` is scanned in *text* context, where the
/// hosted collector applies rules a path segment never sees — notably
/// `PRIVATE_ID_IN_TEXT` (`session_<8+>`, `server_<8+>`, `item_<8+>`, …),
/// unanchored compact-UUID, and a bare 12-hex MAC shape. A value that is a
/// perfectly legal path segment can still reject the bundle from inside `msg`.
///
/// Verified by running these exact rules against
/// `silo-diagnostics/src/privacy.ts` over ~400k randomized type names and
/// coding paths (including hex-biased alphabets): zero rejections. Re-run that
/// check before loosening anything here — the failure mode is not a bad log
/// line, it is the whole report being thrown away.
enum HTTPDecodingDiagnostics {
    /// Rendered when the error carries no coding path (a top-level failure).
    /// Angle brackets keep it from ever reading as a real key.
    static let rootCodingPath = "<root>"
    /// Rendered when a type name survives sanitizing as nothing usable.
    static let unknownType = "unknown"

    /// A dot-free, text-safe rendering of the decoded Swift type.
    ///
    /// Only letter-initial alphanumeric runs are kept, joined with `_`. That
    /// drops module qualification punctuation (`Silo.MediaItem` →
    /// `Silo_MediaItem`), generic brackets (`Array<MediaItem>` →
    /// `Array_MediaItem`), and anything non-ASCII, while preserving enough of
    /// the name to identify the model. Dots specifically must go: a dotted
    /// token in text is scanned as a hostname-or-path candidate and rejected.
    static func typeName(_ rawType: String) -> String {
        var tokens: [String] = []
        var current = ""
        for character in rawType {
            if character.isASCII, character.isLetter {
                current.append(character)
            } else if character.isASCII, character.isNumber, !current.isEmpty {
                // A digit only continues a token that already began with a
                // letter, so a bare number never becomes a token of its own.
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return unknownType }
        let joined = String(tokens.joined(separator: "_").prefix(96))
        // Joining can *manufacture* a private shape that neither token had
        // ("Session" + "Abcdefgh" -> "Session_Abcdefgh" matches
        // PRIVATE_ID_IN_TEXT). Test the finished string, not the pieces, and
        // fail closed: a type name is a nicety, the report is not.
        return isTextPrivate(joined) ? unknownType : joined
    }

    /// `items > 0 > title`. ` > ` rather than `.` because a dotted key path
    /// (`items.0.title`) is scanned as a hostname/route candidate and rejects
    /// the bundle; the spaced arrow is inert in every text rule.
    static func codingPath(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return rootCodingPath }
        return path.map(rendered(key:)).joined(separator: " > ")
    }

    private static func rendered(key: CodingKey) -> String {
        if let index = key.intValue {
            // Array indices are positional, not identifying, and are the most
            // useful part of the path when only one element of a collection
            // mismatches — so they stay literal. The bound is a privacy rule,
            // not a sanity check: a 7+ digit run reads as a numeric identifier
            // to the collector. Real payload indices are far below it.
            return (0...999_999).contains(index) ? String(index) : DiagnosticsPathTemplate.placeholder
        }
        let value = key.stringValue
        // Anything that is not a plain letter-initial identifier is a
        // server-supplied key rather than a Swift property name, so it is
        // templated wholesale rather than inspected further.
        guard isPlainIdentifier(value), !isTextPrivate(value) else {
            return DiagnosticsPathTemplate.placeholder
        }
        return value
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Whether this token would be rejected by the collector's *text-context*
    /// scan. Mirrors privacy.ts `PRIVATE_ID_IN_TEXT`, `UUID_VALUE`,
    /// `COMPACT_UUID_VALUE`, the bare-MAC arm of `MAC_ADDRESS`, and
    /// `HEX_ID_SEGMENT`. Keep in sync with that file.
    private static func isTextPrivate(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return textPrivateRegexes.contains { $0.firstMatch(in: value, range: range) != nil }
    }

    private static let textPrivateRegexes: [NSRegularExpression] = [
        // PRIVATE_ID_IN_TEXT
        try! NSRegularExpression(
            pattern: #"(?i)(?:^|[^A-Za-z0-9])(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-](?:[0-9]+|[A-Za-z0-9][A-Za-z0-9_-]{7,})(?=$|[^A-Za-z0-9_-])"#
        ),
        // UUID_VALUE (unanchored, version-agnostic)
        try! NSRegularExpression(
            pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        ),
        // COMPACT_UUID_VALUE
        try! NSRegularExpression(pattern: #"(?i)(?:^|[^0-9a-f])[0-9a-f]{32}(?=$|[^0-9a-f])"#),
        // MAC_ADDRESS, bare-hex arm
        try! NSRegularExpression(pattern: #"(?i)(?:^|[^0-9a-f-])[0-9a-f]{12}(?=$|[^0-9a-f-])"#),
        // HEX_ID_SEGMENT
        try! NSRegularExpression(pattern: #"(?i)^[0-9a-f]{16,}$"#),
    ]
}
#endif
