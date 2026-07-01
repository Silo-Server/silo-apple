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

    var isUsable: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            profileToken: keychain.get(SharedStorage.mirroredProfileTokenAccount) ?? ""
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

    func fetchDisplay(deliveryID: String, state: ApplePushDisplayAuthState) async throws -> ApplePushDisplayResponse {
        guard let url = ApplePushDisplayWire.displayURL(serverURL: state.serverURL, deliveryID: deliveryID) else {
            throw ApplePushDisplayClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("Bearer \(state.accessToken)", forHTTPHeaderField: "Authorization")
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
