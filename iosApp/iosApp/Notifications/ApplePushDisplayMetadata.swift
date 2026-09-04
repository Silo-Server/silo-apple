#if os(iOS)
import Foundation
import UserNotifications

struct ApplePushDisplayResponse: Decodable, Equatable {
    let deliveryID: String
    let title: String
    let body: String?
    let threadID: String?
    let category: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case deliveryID = "delivery_id"
        case title
        case body
        case threadID = "thread_id"
        case category
        case url
    }

    func apply(to content: UNMutableNotificationContent) {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.title = title
        }
        if let body {
            content.body = body
        }
        if let threadID, !threadID.isEmpty {
            content.threadIdentifier = threadID
        }
        if !category.isEmpty {
            content.categoryIdentifier = category
        }
        var userInfo = content.userInfo
        userInfo[ApplePushDisplayWire.deliveryIDUserInfoKey] = deliveryID
        userInfo[ApplePushDisplayWire.urlUserInfoKey] = url
        content.userInfo = userInfo
    }
}

struct ApplePushDisplayAuthState: Equatable {
    let serverURL: String
    let profileID: String
    let accessToken: String
    /// Mirrored profile-verification token. Empty when the active profile
    /// has no PIN; required by the server for PIN-protected profiles, whose
    /// display fetches otherwise 403 with `profile_unverified`.
    let profileToken: String
    /// Long-lived display token from Apple push registration. Preferred over
    /// `accessToken`: the extension cannot refresh an expired access token,
    /// and access tokens expire within hours while pushes arrive whenever.
    /// Empty on servers that predate the token; the access token then
    /// remains the credential.
    let displayToken: String

    init(serverURL: String, profileID: String, accessToken: String, profileToken: String, displayToken: String = "") {
        self.serverURL = serverURL
        self.profileID = profileID
        self.accessToken = accessToken
        self.profileToken = profileToken
        self.displayToken = displayToken
    }

    var isUsable: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bearerToken.isEmpty
    }

    /// The credential sent as `Authorization: Bearer`.
    var bearerToken: String {
        let display = displayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty { return display }
        return accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same state with the display token dropped, so the mirrored
    /// access token becomes the bearer. `nil` when there is no distinct
    /// access token to fall back to.
    var accessTokenFallback: ApplePushDisplayAuthState? {
        let access = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !access.isEmpty else {
            return nil
        }
        return ApplePushDisplayAuthState(
            serverURL: serverURL,
            profileID: profileID,
            accessToken: access,
            profileToken: profileToken
        )
    }
}

enum ApplePushDisplayWire {
    static let deliveryIDUserInfoKey = "silo_delivery_id"
    static let urlUserInfoKey = "silo_url"

    static func deliveryID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let raw = userInfo[deliveryIDUserInfoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func displayURL(serverURL: String, deliveryID: String) -> URL? {
        let trimmedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeliveryID = deliveryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerURL.isEmpty,
              !trimmedDeliveryID.isEmpty,
              let baseURL = URL(string: trimmedServerURL) else {
            return nil
        }
        return baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("notifications")
            .appendingPathComponent("push")
            .appendingPathComponent("apple")
            .appendingPathComponent("display")
            .appendingPathComponent(trimmedDeliveryID)
    }
}

struct ApplePushDisplayStateReader {
    var defaults: SharedDefaults = .shared
    var keychain: SharedKeychain = SharedKeychain()

    func currentState() -> ApplePushDisplayAuthState? {
        let state = ApplePushDisplayAuthState(
            serverURL: defaults.string(forKey: SharedStorage.serverUrlKey) ?? "",
            profileID: defaults.string(forKey: SharedStorage.profileIdKey) ?? "",
            accessToken: keychain.get(SharedStorage.mirroredAccessTokenAccount) ?? "",
            profileToken: keychain.get(SharedStorage.mirroredProfileTokenAccount) ?? "",
            displayToken: keychain.get(SharedStorage.applePushDisplayTokenAccount) ?? ""
        )
        return state.isUsable ? state : nil
    }
}

enum ApplePushDisplayClientError: Error, Equatable {
    case invalidURL
    case badStatus(Int)
}

final class ApplePushDisplayClient {
    private let session: URLSession

    init(session: URLSession = ApplePushDisplayClient.makeSession()) {
        self.session = session
    }

    /// Fetches display metadata with the preferred credential. When the
    /// display token is rejected (expired past the app's renewal window, or
    /// revoked) and a mirrored access token exists, retries once with it:
    /// background work may have refreshed the access token while the app
    /// never foregrounded to renew the display token. Both fetches share
    /// the extension's short time budget.
    func fetchDisplay(deliveryID: String, state: ApplePushDisplayAuthState) async throws -> ApplePushDisplayResponse {
        do {
            return try await fetchDisplayOnce(deliveryID: deliveryID, state: state)
        } catch ApplePushDisplayClientError.badStatus(let status) where status == 401 || status == 403 {
            guard let fallback = state.accessTokenFallback, !Task.isCancelled else { throw ApplePushDisplayClientError.badStatus(status) }
            return try await fetchDisplayOnce(deliveryID: deliveryID, state: fallback)
        }
    }

    private func fetchDisplayOnce(deliveryID: String, state: ApplePushDisplayAuthState) async throws -> ApplePushDisplayResponse {
        guard let url = ApplePushDisplayWire.displayURL(serverURL: state.serverURL, deliveryID: deliveryID) else {
            throw ApplePushDisplayClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("Bearer \(state.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(state.profileID, forHTTPHeaderField: "X-Profile-Id")
        if !state.profileToken.isEmpty {
            request.setValue(state.profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApplePushDisplayClientError.badStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ApplePushDisplayClientError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ApplePushDisplayResponse.self, from: data)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
#endif
