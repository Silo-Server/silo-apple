import Foundation
import OSLog

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

    /// When non-nil, a refresh is in flight. Concurrent 401s await this task
    /// instead of issuing their own refresh request.
    private var inFlightRefresh: Task<Bool, Never>?

    init(session: URLSession? = nil, tokenStore: TokenStore = .shared) {
        // An injected session (tests) serves both timeout classes so mocks
        // observe every request regardless of the caller's timeout choice.
        self.session = session ?? Self.makeSession(requestTimeout: 15)
        self.longWaitSession = session ?? Self.makeSession(requestTimeout: 90)
        self.tokenStore = tokenStore

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
        query: [String: String] = [:]
    ) async throws {
        _ = try await sendRaw(method: "POST", path: path, query: query, body: body)
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
        timeout: HTTPTimeout = .standard
    ) async throws -> HTTPRawResponse {
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
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        for session in [session, longWaitSession] {
            await withCheckedContinuation { continuation in
                session.getAllTasks { tasks in
                    for task in tasks { task.cancel() }
                    continuation.resume()
                }
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
        makeRequest: (String) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let serverUrl = await tokenStore.getServerUrl()
        guard !serverUrl.isEmpty else {
            throw HTTPError.serverUrlNotConfigured
        }

        let tokenBeforeRequest = await tokenStore.getAccessToken()
        var request = try makeRequest(serverUrl)
        await attachAuthHeaders(&request, accessToken: tokenBeforeRequest)
        Self.apply(additionalHeaders, to: &request)

        let (data, response) = try await perform(request: request, timeout: timeout)

        if response.statusCode == 401, shouldAttemptRefresh(path: path) {
            let refreshed = await refreshTokens(tokenAtRequestTime: tokenBeforeRequest)
            if refreshed {
                // Rebuild the request so headers reflect the new access token.
                let refreshedToken = await tokenStore.getAccessToken()
                var retry = try makeRequest(serverUrl)
                await attachAuthHeaders(&retry, accessToken: refreshedToken)
                Self.apply(additionalHeaders, to: &retry)
                let (retryData, retryResponse) = try await perform(request: retry, timeout: timeout)
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

    private func attachAuthHeaders(_ request: inout URLRequest, accessToken: String?) async {
        let path = request.url?.path ?? ""
        // Skip auth injection for /auth/refresh (avoid recursion) and
        // /auth/login (a prior expired token can't authorize a fresh login).
        if path.hasSuffix("/auth/refresh") || path.hasSuffix("/auth/login") {
            return
        }

        var attached: [String] = []
        if let token = accessToken {
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
        attached.append("device=\(device.platform)")
        let method = request.httpMethod ?? ""
        let attachedDesc = attached.joined(separator: ", ")
        Self.logger.debug("→ \(method, privacy: .public) \(path, privacy: .public) headers=[\(attachedDesc, privacy: .public)]")
    }

    // MARK: - Response handling

    private func perform(request: URLRequest, timeout: HTTPTimeout = .standard) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            let session = timeout == .extended ? longWaitSession : session
            (data, response) = try await session.data(for: request)
        } catch {
            // Feed ConnectionMonitor from every transport failure so the app
            // learns "server down" passively. Cancellation says nothing about
            // reachability, so it is excluded.
            if (error as? URLError)?.code != .cancelled {
                Task { @MainActor in
                    ConnectionMonitor.shared.noteServerUnreachable()
                }
            }
            throw HTTPError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        // Any HTTP response — success or error status — proves the server is
        // alive.
        Task { @MainActor in
            ConnectionMonitor.shared.noteServerResponded()
        }
        return (data, http)
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

    // MARK: - Refresh (single-flight)

    /// Refresh tokens at most once per wave of concurrent 401s.
    ///
    /// Algorithm (equivalent to the Kotlin Mutex + double-check):
    /// 1. Check whether another caller already refreshed: if the token now
    ///    stored differs from the token this caller originally sent, it was
    ///    refreshed in the meantime and we can just signal "yes, retry."
    /// 2. Otherwise, if no refresh is in flight, start one; every concurrent
    ///    401 awaits the same `Task` so only one network call is made.
    /// 3. The in-flight task clears itself after completion so the next 401
    ///    wave can start a fresh refresh.
    ///
    /// Re-entrancy note: `await tokenStore.getAccessToken()` releases the
    /// actor, so another 401'd caller may interleave and arrive at the
    /// `inFlightRefresh` check before this caller does. The `inFlightRefresh`
    /// slot is single-assignment per wave, and the `tokenAtRequestTime`
    /// check catches the case where a second caller resumes *after* the
    /// first caller's refresh has already completed and cleared the slot.
    private func refreshTokens(tokenAtRequestTime: String?) async -> Bool {
        if let current = await tokenStore.getAccessToken(),
           current != tokenAtRequestTime {
            return true
        }

        if let existing = inFlightRefresh {
            return await existing.value
        }

        let task = Task<Bool, Never> { [tokenStore, session, decoder, encoder] in
            await Self.performRefresh(
                tokenStore: tokenStore,
                session: session,
                decoder: decoder,
                encoder: encoder
            )
        }
        inFlightRefresh = task
        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    private static func performRefresh(
        tokenStore: TokenStore,
        session: URLSession,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) async -> Bool {
        let serverUrl = await tokenStore.getServerUrl()
        guard !serverUrl.isEmpty else {
            Self.logger.error("Refresh skipped: no server URL configured")
            return false
        }
        guard let refreshToken = await tokenStore.getRefreshToken(),
              !refreshToken.isEmpty else {
            Self.logger.error("Refresh skipped: no refresh token stored")
            return false
        }

        guard let url = URL(string: serverUrl + "/api/v1/auth/refresh") else {
            Self.logger.error("Refresh skipped: invalid server URL")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try encoder.encode(RefreshRequest(refreshToken: refreshToken))
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
            Task { @MainActor in
                ConnectionMonitor.shared.noteServerResponded()
            }
            if (200..<300).contains(http.statusCode) {
                let tokens = try decoder.decode(RefreshResponse.self, from: data)
                await tokenStore.saveTokens(
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken
                )
                return true
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                Self.logger.error("Refresh failed: status=\(http.statusCode, privacy: .public) body=\(body, privacy: .private)")
                let temporaryScopeExpired = await tokenStore.hasTemporaryScope()
                if !temporaryScopeExpired {
                    await tokenStore.clearTokens()
                }
                // Tell the UI to route back to login for the current
                // server. The registry entry (URL + display name) is
                // preserved so the user doesn't have to re-add it.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: temporaryScopeExpired ? .temporaryRemoteAuthExpired : .continuumSessionExpired,
                        object: nil
                    )
                }
                return false
            }
        } catch {
            if (error as? URLError)?.code != .cancelled {
                Task { @MainActor in
                    ConnectionMonitor.shared.noteServerUnreachable()
                }
            }
            Self.logger.error("Refresh threw: \(String(describing: error), privacy: .public)")
            return false
        }
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
