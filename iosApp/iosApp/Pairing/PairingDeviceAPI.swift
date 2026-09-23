import Foundation

/// Seam over the device-authorization endpoints so the pairing coordinators
/// can be unit-tested against a scripted fake. `PairingDeviceAPI` is the
/// production conformer.
protocol PairingDeviceAuthorizing: Sendable {
    func start(serverURL: String, deviceName: String, devicePlatform: String) async throws -> DeviceLoginStartResponse
    func poll(serverURL: String, deviceCode: String) async throws -> APIv2DevicePoll
    func lookup(serverURL: String, bearer: String, userCode: String) async throws -> DeviceLookupResponse
    func approve(serverURL: String, bearer: String, userCode: String) async throws
}

/// Device-authorization calls issued against an EXPLICIT server base URL,
/// independent of the app's single active server. Used by both pairing sides:
/// the Receiver calls start/poll against a pushed URL (no auth); the Companion
/// calls lookup/approve against a chosen server (bearer = that server's token).
///
/// Every path is `/api/v2`. These requests bypass `APIv2Client` and its
/// recorded probe verdict (the target is not the active server), so a failure
/// is classified here the way `APIv2Client.mapErrors` does it: a problem
/// document becomes `APIv2Error.problem`, Go's plain 404 from a v1-only
/// server's legacy listener becomes `APIv2Error.serverUpdateRequired`, and any
/// other status becomes `APIv2Error.httpStatus`. Transport failures surface as
/// the `URLError` they are. Nothing here retries: start, poll and approve are
/// each dispatched once.
struct PairingDeviceAPI: PairingDeviceAuthorizing {
    enum APIError: Error { case badURL }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Receiver (unauthenticated)

    /// `POST /api/v2/auth/device/start` (`non_retryable`, 201).
    func start(serverURL: String, deviceName: String, devicePlatform: String) async throws -> DeviceLoginStartResponse {
        let value: APIv2DeviceStart = try await post(
            serverURL, "/api/v2/auth/device/start", bearer: nil, expectedStatus: 201,
            body: Self.encode(DeviceLoginStartRequest(deviceName: deviceName, devicePlatform: devicePlatform))
        )
        return value.presentation
    }

    /// `POST /api/v2/auth/device/poll` (`non_retryable`). Tokens arrive once,
    /// on the first `approved` answer; the validated value is what the caller
    /// installs.
    func poll(serverURL: String, deviceCode: String) async throws -> APIv2DevicePoll {
        let value: APIv2DevicePoll = try await post(
            serverURL, "/api/v2/auth/device/poll", bearer: nil, expectedStatus: 200,
            body: JSONSerialization.data(withJSONObject: ["device_code": deviceCode])
        )
        return try value.validated()
    }

    func remotePlaybackCapability(serverURL: String) async throws -> APIv2DeviceCapability {
        try await get(serverURL, "/api/v2/auth/device/capability", query: [:], bearer: nil)
    }

    func startRemotePlayback(
        serverURL: String,
        deviceName: String,
        devicePlatform: String
    ) async throws -> DeviceLoginStartResponse {
        let value: APIv2DeviceStart = try await post(
            serverURL,
            "/api/v2/auth/device/start",
            bearer: nil,
            expectedStatus: 201,
            body: Self.encode(DeviceLoginStartRequest(
                deviceName: deviceName,
                devicePlatform: devicePlatform,
                clientPurpose: "remote_playback",
                temporary: true
            ))
        )
        return value.presentation
    }

    // MARK: Companion (authenticated with the chosen server's token)

    func lookup(serverURL: String, bearer: String, userCode: String) async throws -> DeviceLookupResponse {
        let value: APIv2DeviceLookup = try await get(serverURL, "/api/v2/auth/device", query: ["code": userCode], bearer: bearer)
        return value.presentation
    }

    /// `POST /api/v2/auth/device/approve`. Sent once with the chosen server's
    /// bearer and never replayed: this path has no refresh, and an answer lost
    /// in transit is reported as a failure rather than approved again.
    func approve(serverURL: String, bearer: String, userCode: String) async throws {
        let value: APIv2DeviceDecision = try await post(
            serverURL, "/api/v2/auth/device/approve", bearer: bearer, expectedStatus: 200,
            body: JSONSerialization.data(withJSONObject: ["code": userCode])
        )
        guard value.status == "approved" else { throw APIv2Error.incompleteAuthResponse }
    }

    // MARK: Transport

    private static func encode(_ body: DeviceLoginStartRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(body)
    }

    private func get<R: Decodable>(_ serverURL: String, _ path: String, query: [String: String], bearer: String?) async throws -> R {
        guard var comps = URLComponents(string: serverURL.appending(path)) else { throw APIError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request, bearer: bearer)
        return try await send(request, expectedStatus: 200)
    }

    private func post<R: Decodable>(
        _ serverURL: String,
        _ path: String,
        bearer: String?,
        expectedStatus: Int,
        body: Data
    ) async throws -> R {
        guard let url = URL(string: serverURL.appending(path)) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        applyHeaders(&request, bearer: bearer)
        return try await send(request, expectedStatus: expectedStatus)
    }

    private func applyHeaders(
        _ request: inout URLRequest,
        bearer: String?
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        AppleDeviceIdentity.current.applyHeaders(to: &request)
    }

    private func send<R: Decodable>(_ request: URLRequest, expectedStatus: Int) async throws -> R {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let decoder = HTTPClient.makeJSONDecoder()
        guard (200..<300).contains(http.statusCode) else {
            if let problem = try? decoder.decode(APIv2Problem.self, from: data) {
                throw APIv2Error.problem(problem)
            }
            // Every path here is `/api/v2`, so Go's plain 404 can only come
            // from a v1-only server's legacy listener.
            if http.statusCode == 404, APIv2Probe.isLegacyNotFound(body: String(data: data, encoding: .utf8)) {
                throw APIv2Error.serverUpdateRequired
            }
            throw APIv2Error.httpStatus(http.statusCode)
        }
        guard http.statusCode == expectedStatus else { throw APIv2Error.incompleteAuthResponse }
        return try decoder.decode(R.self, from: data)
    }
}
