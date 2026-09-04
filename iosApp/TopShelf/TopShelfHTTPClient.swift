import Foundation

/// Bare-bones authenticated GET helper for the Top Shelf extension.
///
/// The main app's `HTTPClient` owns a lot we don't need here: token
/// refresh, in-flight request cancellation, cookie storage, logging. The
/// extension runs for a second or two at a time, reads exactly one
/// endpoint, and has no UI surface to refresh into — so a single
/// `URLSession.data(for:)` call with pre-attached headers is sufficient.
///
/// Access token refresh is intentionally absent: Silo's access
/// tokens effectively don't expire, so a 401 here would indicate the
/// user has signed out in the main app. In that case we simply return
/// no content and let the system fall back to the static top-shelf
/// image.
struct TopShelfHTTPClient {
    enum Error: Swift.Error {
        case notAuthenticated
        case invalidURL
        case unexpectedStatus(Int)
    }

    let defaults: SharedDefaults
    let accountKeychain: SharedKeychain
    let profileKeychain: SharedKeychain
    let session: URLSession

    init(defaults: SharedDefaults = .shared,
         keychain: SharedKeychain = SharedKeychain(),
         session: URLSession = .shared) {
        self.defaults = defaults
        self.accountKeychain = keychain.withAudience(.userIndependent)
        self.profileKeychain = keychain.withAudience(.currentUser)
        self.session = session
    }

    var isPersonalizedContentAllowed: Bool {
        guard let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey) else {
            return false
        }
        let state = ProfileLaunchState.load(from: defaults)
        return TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: defaults.string(forKey: SharedStorage.profileIdKey),
            accountEpoch: accountKeychain.get(
                SharedStorage.accountEpochAccount(for: serverID)
            ),
            hasStoredProfileToken: profileKeychain.get(
                SharedStorage.profileTokenAccount(for: serverID)
            ) != nil
        )
    }

    /// Negotiate the same large-image contract as the main tvOS app. Older
    /// servers and transient failures return an empty query, preserving the
    /// extension's existing fallback behavior.
    func fetchImageSizeQuery() async -> [String: String] {
        let capability: ImageSizeCapabilityResponse? = try? await get(
            "/api/v1/images/capability"
        )
        return ImageSizeSelection.queryEntries(
            capability: capability,
            prefersLargeImages: true
        )
    }

    func fetchHomeSections(imageSizeQuery: [String: String]) async throws -> TopShelfSectionsResponse {
        try await get("/api/v1/home/sections", query: imageSizeQuery)
    }

    func fetchSeasons(
        seriesId: String,
        imageSizeQuery: [String: String]
    ) async throws -> TopShelfSeasonsResponse {
        try await get(
            "/api/v1/catalog/series/\(seriesId)/seasons",
            query: imageSizeQuery
        )
    }

    func fetchItemDetail(
        contentId: String,
        imageSizeQuery: [String: String]
    ) async throws -> TopShelfItemDetail {
        try await get(
            "/api/v1/catalog/items/\(contentId)",
            query: imageSizeQuery
        )
    }

    // MARK: - Private

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> T {
        guard let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey),
              isPersonalizedContentAllowed,
              let serverUrl = defaults.string(forKey: SharedStorage.serverUrlKey),
              !serverUrl.isEmpty,
              let accessToken = accountKeychain.get(
                SharedStorage.accessTokenAccount(for: serverID)
              )
        else {
            throw Error.notAuthenticated
        }

        guard var components = URLComponents(string: serverUrl) else {
            throw Error.invalidURL
        }
        let base = components.percentEncodedPath
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        components.percentEncodedPath = trimmed + path
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Error.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let profileId = defaults.string(forKey: SharedStorage.profileIdKey) {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = profileKeychain.get(
            SharedStorage.profileTokenAccount(for: serverID)
        ) {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unexpectedStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.unexpectedStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
