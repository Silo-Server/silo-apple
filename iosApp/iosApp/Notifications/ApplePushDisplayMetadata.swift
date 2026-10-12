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
        missingParts.isEmpty
    }

    /// The pieces that keep this state from authenticating a fetch, named
    /// for diagnostics: the extension cannot report anything else about why
    /// a notification kept the generic text.
    var missingParts: [String] {
        var missing: [String] = []
        if serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("server_url") }
        if profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("profile") }
        if bearerToken.isEmpty { missing.append("credential") }
        return missing
    }

    /// Which credential a fetch starts with, for diagnostics.
    var credentialKind: String {
        displayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "access" : "display"
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

/// The server deployment and profile a push belongs to.
struct ApplePushTargetName: Equatable, Sendable {
    let serverID: String
    let profileID: String
}

enum ApplePushDisplayWire {
    static let deliveryIDUserInfoKey = "silo_delivery_id"
    static let urlUserInfoKey = "silo_url"
    static let serverIDUserInfoKey = "silo_server_id"
    static let profileIDUserInfoKey = "silo_profile_id"

    static func deliveryID(from userInfo: [AnyHashable: Any]) -> String? {
        string(userInfo[deliveryIDUserInfoKey])
    }

    /// The server and profile the push names, or nil when it does not name
    /// both. Servers and relays that predate target routing send neither.
    static func targetName(from userInfo: [AnyHashable: Any]) -> ApplePushTargetName? {
        guard let serverID = string(userInfo[serverIDUserInfoKey]),
              let profileID = string(userInfo[profileIDUserInfoKey]) else { return nil }
        return ApplePushTargetName(serverID: serverID, profileID: profileID)
    }

    /// Whether the push carries either target key. One without the other
    /// still says the push may belong to another server, so it never falls
    /// back to the active one.
    static func namesTarget(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[serverIDUserInfoKey] != nil || userInfo[profileIDUserInfoKey] != nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
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
            .appendingPathComponent("v2")
            .appendingPathComponent("notifications")
            .appendingPathComponent("push")
            .appendingPathComponent("apple")
            .appendingPathComponent("display")
            .appendingPathComponent(trimmedDeliveryID)
    }
}

/// Where the extension fetches one push's display metadata.
enum ApplePushDisplayRoute: Equatable {
    case fetch(ApplePushDisplayAuthState)
    /// The push names a server and profile this device keeps no target
    /// for. Fetching from the active server instead would ask the wrong
    /// server or profile, so nothing is fetched.
    case unknownTarget
}

struct ApplePushDisplayStateReader {
    var defaults: SharedDefaults = .shared
    var keychain: SharedKeychain = SharedKeychain()

    private var targets: ApplePushDisplayTargetStore {
        ApplePushDisplayTargetStore(keychain: keychain.withAudience(.currentUser))
    }

    /// A push that names its server and profile uses exactly that target's
    /// display token. The mirrored access and profile tokens belong to the
    /// active server and profile, so they join only a target that is both.
    /// A push that names no target keeps the active server and profile.
    func route(for userInfo: [AnyHashable: Any]) -> ApplePushDisplayRoute {
        guard let name = ApplePushDisplayWire.targetName(from: userInfo) else {
            return ApplePushDisplayWire.namesTarget(userInfo) ? .unknownTarget : .fetch(storedState())
        }
        guard let target = targets.target(serverID: name.serverID, profileID: name.profileID) else {
            // An App Store update replaces the extension without launching
            // the app, so the legacy token waits there until the app moves
            // it into a target. Until then, fetch as the build before
            // targets did rather than drop every keyed push.
            return legacyDisplayToken().isEmpty ? .unknownTarget : .fetch(storedState())
        }
        let active = isActive(target)
        return .fetch(ApplePushDisplayAuthState(
            serverURL: target.serverURL,
            profileID: target.profileID,
            accessToken: active ? keychain.get(SharedStorage.mirroredAccessTokenAccount) ?? "" : "",
            profileToken: active ? keychain.get(SharedStorage.mirroredProfileTokenAccount) ?? "" : "",
            displayToken: target.displayToken
        ))
    }

    /// The active server and profile's state, usable or not, so the
    /// extension can say what is missing when it cannot fetch.
    func storedState() -> ApplePushDisplayAuthState {
        let profileID = defaults.string(forKey: SharedStorage.profileIdKey) ?? ""
        let activeTarget = targets.targets().first(where: isActive)
        return ApplePushDisplayAuthState(
            serverURL: defaults.string(forKey: SharedStorage.serverUrlKey) ?? "",
            profileID: profileID,
            accessToken: keychain.get(SharedStorage.mirroredAccessTokenAccount) ?? "",
            profileToken: keychain.get(SharedStorage.mirroredProfileTokenAccount) ?? "",
            displayToken: activeTarget?.displayToken ?? legacyDisplayToken()
        )
    }

    private func isActive(_ target: ApplePushDisplayTarget) -> Bool {
        target.registryServerID == defaults.string(forKey: SharedStorage.activeServerIdKey)
            && target.profileID == defaults.string(forKey: SharedStorage.profileIdKey)
    }

    /// The single token an earlier build stored for the active server,
    /// until the app moves it into a target.
    private func legacyDisplayToken() -> String {
        guard let issuedFor = defaults.string(forKey: SharedStorage.applePushDisplayTokenServerIdKey),
              issuedFor == defaults.string(forKey: SharedStorage.activeServerIdKey) else { return "" }
        return keychain.get(SharedStorage.applePushDisplayTokenAccount) ?? ""
    }
}

enum ApplePushDisplayClientError: Error, Equatable {
    case invalidURL
    case badStatus(Int, retryAfter: TimeInterval? = nil)
}

struct ApplePushDisplayFetchResult {
    let outcome: Result<ApplePushDisplayResponse, Error>
    /// Fetch attempts made, counting a credential fallback as part of the
    /// attempt it rescued.
    let attempts: Int
    /// The credential the last request used: "access" once a refused display
    /// token has fallen back.
    let credential: String
}

final class ApplePushDisplayClient {
    /// The extension gets about 30 s per notification. New attempts stop
    /// inside this budget so the system still gets the content in time.
    static let fetchBudget: TimeInterval = 25
    private static let minimumAttemptTime: TimeInterval = 2
    /// Each attempt is a 0.5, 1, then 2 s wait past the last, so a quick
    /// failure (no route yet) gives up within a few seconds instead of
    /// holding the banner for the whole budget.
    private static let retryBackoff: [TimeInterval] = [0.5, 1, 2]
    private static let maxAttempts = retryBackoff.count + 1
    private static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]
    private static let retryableURLErrors: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .secureConnectionFailed,
    ]

    /// iOS keeps the extension process alive across back-to-back pushes, so
    /// one session lets a burst reuse a connection instead of paying a TLS
    /// handshake per notification.
    private static let sharedSession = makeSession()

    private let session: URLSession

    init(session: URLSession = ApplePushDisplayClient.sharedSession) {
        self.session = session
    }

    /// Fetches display metadata, retrying failures another attempt can fix
    /// (a radio still waking, a dropped connection, a busy server) until
    /// `fetchBudget` runs out. Pushes usually wake an idle phone, and one
    /// short attempt left the generic text on screen.
    func fetchDisplay(deliveryID: String, state: ApplePushDisplayAuthState) async -> ApplePushDisplayFetchResult {
        let deadline = Date().addingTimeInterval(Self.fetchBudget)
        var state = state
        var attempts = 0
        func result(_ outcome: Result<ApplePushDisplayResponse, Error>) -> ApplePushDisplayFetchResult {
            ApplePushDisplayFetchResult(outcome: outcome, attempts: attempts, credential: state.credentialKind)
        }
        while true {
            attempts += 1
            do {
                let response = try await fetchDisplayAuthenticated(deliveryID: deliveryID, state: &state)
                return result(.success(response))
            } catch {
                guard attempts < Self.maxAttempts,
                      !Task.isCancelled,
                      let delay = Self.retryDelay(after: error, attempt: attempts),
                      deadline.timeIntervalSinceNow - delay >= Self.minimumAttemptTime else {
                    return result(.failure(error))
                }
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return result(.failure(error)) }
            }
        }
    }

    /// Fetches with the preferred credential. When the display token is
    /// rejected (expired past the app's renewal window, or revoked) and a
    /// mirrored access token exists, retries once with it: background work
    /// may have refreshed the access token while the app never foregrounded
    /// to renew the display token. `state` keeps the fallback so a later
    /// attempt does not resend the refused token.
    private func fetchDisplayAuthenticated(deliveryID: String, state: inout ApplePushDisplayAuthState) async throws -> ApplePushDisplayResponse {
        do {
            return try await fetchDisplayOnce(deliveryID: deliveryID, state: state)
        } catch ApplePushDisplayClientError.badStatus(let status, let retryAfter) where status == 401 || status == 403 {
            guard let fallback = state.accessTokenFallback, !Task.isCancelled else {
                throw ApplePushDisplayClientError.badStatus(status, retryAfter: retryAfter)
            }
            state = fallback
            return try await fetchDisplayOnce(deliveryID: deliveryID, state: state)
        }
    }

    private func fetchDisplayOnce(deliveryID: String, state: ApplePushDisplayAuthState) async throws -> ApplePushDisplayResponse {
        guard let url = ApplePushDisplayWire.displayURL(serverURL: state.serverURL, deliveryID: deliveryID) else {
            throw ApplePushDisplayClientError.invalidURL
        }
        var request = URLRequest(url: url)
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
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ApplePushDisplayClientError.badStatus(http.statusCode, retryAfter: retryAfter)
        }
        return try JSONDecoder().decode(ApplePushDisplayResponse.self, from: data)
    }

    /// The wait before retrying after `error`, or `nil` when another attempt
    /// cannot help: a missing delivery, a refused credential, a response the
    /// extension cannot read, or a network the user has denied Silo (cellular
    /// off, Low Data Mode) stays that way.
    private static func retryDelay(after error: Error, attempt: Int) -> TimeInterval? {
        let backoff = retryBackoff[min(attempt, retryBackoff.count) - 1]
        switch error {
        case ApplePushDisplayClientError.badStatus(let status, let retryAfter):
            guard retryableStatuses.contains(status) else { return nil }
            return max(backoff, retryAfter ?? 0)
        case let error as URLError:
            guard error.networkUnavailableReason == nil else { return nil }
            return retryableURLErrors.contains(error.code) ? backoff : nil
        default:
            return nil
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = fetchBudget
        // The banner waits for the extension, so a missing route fails fast
        // and the retry backoff decides how long to keep trying.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// What the Notification Service extension did with one push. The extension
/// has no diagnostics pipeline of its own, so it leaves these in the App
/// Group and the app moves them into the breadcrumb journal.
struct ApplePushDisplayOutcome: Codable, Equatable {
    enum Kind: String, Codable {
        case enriched
        case missingState = "missing_state"
        /// The push named a server and profile with no stored target.
        case unknownTarget = "unknown_target"
        case httpStatus = "http_status"
        case network
        case invalidResponse = "invalid_response"
        case expired
    }

    let recordedAt: Date
    let kind: Kind
    /// The HTTP status, URL error code, or missing state behind `kind`.
    let reason: String?
    /// Fetch attempts made; 0 when no fetch ran or none finished.
    let attempts: Int
    let durationMs: Int
    /// "display" or "access": the credential the last request used.
    let credential: String?

    init(kind: Kind, reason: String?, attempts: Int, credential: String?, startedAt: Date, recordedAt: Date = Date()) {
        self.recordedAt = recordedAt
        self.kind = kind
        self.reason = reason
        self.attempts = attempts
        self.durationMs = max(0, Int(recordedAt.timeIntervalSince(startedAt) * 1000))
        self.credential = credential
    }

    init(result: ApplePushDisplayFetchResult, startedAt: Date, recordedAt: Date = Date()) {
        let kind: Kind
        let reason: String?
        switch result.outcome {
        case .success:
            (kind, reason) = (.enriched, nil)
        case .failure(ApplePushDisplayClientError.badStatus(let status, _)):
            (kind, reason) = (.httpStatus, "http_\(status)")
        case .failure(ApplePushDisplayClientError.invalidURL):
            (kind, reason) = (.missingState, "invalid_server_url")
        case .failure(let error as URLError):
            (kind, reason) = (.network, "url_error_\(error.code.rawValue)")
        case .failure:
            (kind, reason) = (.invalidResponse, nil)
        }
        self.init(kind: kind, reason: reason, attempts: result.attempts, credential: result.credential, startedAt: startedAt, recordedAt: recordedAt)
    }
}

/// The App Group hand-off between the extension, which appends one outcome
/// per push, and the app, which drains them into diagnostics. Bounded so a
/// phone that rarely opens Silo keeps only the newest pushes. Best effort:
/// a push handled in the instant the app drains can lose or repeat a record.
enum ApplePushDisplayOutcomeLog {
    static let capacity = 30

    static func append(_ outcome: ApplePushDisplayOutcome, to defaults: UserDefaults = SharedStorage.suite) {
        var outcomes = read(from: defaults)
        outcomes.append(outcome)
        outcomes.removeFirst(max(0, outcomes.count - capacity))
        guard let data = try? JSONEncoder().encode(outcomes) else { return }
        defaults.set(data, forKey: SharedStorage.applePushDisplayOutcomesKey)
    }

    static func drain(from defaults: UserDefaults = SharedStorage.suite) -> [ApplePushDisplayOutcome] {
        let outcomes = read(from: defaults)
        defaults.removeObject(forKey: SharedStorage.applePushDisplayOutcomesKey)
        return outcomes
    }

    private static func read(from defaults: UserDefaults) -> [ApplePushDisplayOutcome] {
        guard let data = defaults.data(forKey: SharedStorage.applePushDisplayOutcomesKey) else { return [] }
        return (try? JSONDecoder().decode([ApplePushDisplayOutcome].self, from: data)) ?? []
    }
}
#endif
