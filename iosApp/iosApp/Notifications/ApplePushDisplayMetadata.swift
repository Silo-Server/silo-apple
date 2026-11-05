#if os(iOS)
import Foundation
import Synchronization
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
    /// More than one saved server claims the server and profile the push
    /// names, so nothing is fetched from any of them.
    case ambiguousTarget
}

struct ApplePushDisplayStateReader {
    var defaults: SharedDefaults = .shared
    var keychain: SharedKeychain = SharedKeychain()

    private var targets: ApplePushDisplayTargetStore {
        ApplePushDisplayTargetStore(keychain: keychain.withAudience(.currentUser))
    }

    /// A push that names its server and profile uses exactly that target's
    /// display token and nothing else. The mirrored access and profile
    /// tokens follow whichever server is active, which can change between
    /// two reads, so they never travel with a target's address. A push that
    /// names no target keeps the active server and profile.
    func route(for userInfo: [AnyHashable: Any]) -> ApplePushDisplayRoute {
        guard let name = ApplePushDisplayWire.targetName(from: userInfo) else {
            return ApplePushDisplayWire.namesTarget(userInfo) ? .unknownTarget : .fetch(storedState())
        }
        let claims = targets.targets(serverID: name.serverID, profileID: name.profileID)
        guard claims.count <= 1 else { return .ambiguousTarget }
        guard let target = claims.first else {
            // An App Store update replaces the extension without launching
            // the app, so the legacy token waits there until the app moves
            // it into a target. Until then, fetch as the build before
            // targets did rather than drop every keyed push.
            return legacyDisplayToken().isEmpty ? .unknownTarget : .fetch(storedState())
        }
        return .fetch(ApplePushDisplayAuthState(
            serverURL: target.serverURL,
            profileID: target.profileID,
            accessToken: "",
            profileToken: "",
            displayToken: target.displayToken
        ))
    }

    /// The active server and profile's state, usable or not, so the
    /// extension can say what is missing when it cannot fetch. The active
    /// target's display token goes only to the address it was minted for.
    func storedState() -> ApplePushDisplayAuthState {
        let serverURL = defaults.string(forKey: SharedStorage.serverUrlKey) ?? ""
        let profileID = defaults.string(forKey: SharedStorage.profileIdKey) ?? ""
        let activeServerID = defaults.string(forKey: SharedStorage.activeServerIdKey)
        let activeTarget = targets.targets().first {
            $0.registryServerID == activeServerID && $0.profileID == profileID && $0.serverURL == serverURL
        }
        return ApplePushDisplayAuthState(
            serverURL: serverURL,
            profileID: profileID,
            accessToken: keychain.get(SharedStorage.mirroredAccessTokenAccount) ?? "",
            profileToken: keychain.get(SharedStorage.mirroredProfileTokenAccount) ?? "",
            displayToken: activeTarget?.displayToken ?? legacyDisplayToken()
        )
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
    /// The extension gets about 30 s per notification. Every request,
    /// backoff and credential fallback ends inside this budget, leaving the
    /// rest to record the outcome and hand the system its content.
    static let fetchBudget: TimeInterval = 25
    private static let requestTimeout: TimeInterval = 8
    private static let minimumAttemptTime: TimeInterval = 2
    /// Each attempt is a 0.5, 1, then 2 s wait past the last, so a quick
    /// failure (no route yet) gives up within a few seconds instead of
    /// holding the banner for the whole budget.
    private static let retryBackoff: [TimeInterval] = [0.5, 1, 2]
    private static let maxAttempts = retryBackoff.count + 1
    /// 520-524 are Cloudflare's answers for trouble reaching the origin, which
    /// Silo servers behind Cloudflare return while the server is briefly away.
    private static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
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
    private let budget: TimeInterval

    init(session: URLSession = ApplePushDisplayClient.sharedSession,
         budget: TimeInterval = ApplePushDisplayClient.fetchBudget) {
        self.session = session
        self.budget = budget
    }

    /// Fetches display metadata, retrying failures another attempt can fix
    /// (a radio still waking, a dropped connection, a busy server) until
    /// the budget runs out. Pushes usually wake an idle phone, and one
    /// short attempt left the generic text on screen.
    ///
    /// `progress` hears each request as it goes out, with its attempt and
    /// credential, so an extension that expires mid-fetch can say how far
    /// the fetch got.
    func fetchDisplay(deliveryID: String, state: ApplePushDisplayAuthState,
                      progress: @escaping @Sendable (_ attempts: Int, _ credential: String) -> Void = { _, _ in })
        async -> ApplePushDisplayFetchResult {
        let deadline = Date().addingTimeInterval(budget)
        var state = state
        var attempts = 0
        func result(_ outcome: Result<ApplePushDisplayResponse, Error>) -> ApplePushDisplayFetchResult {
            ApplePushDisplayFetchResult(outcome: outcome, attempts: attempts, credential: state.credentialKind)
        }
        while true {
            attempts += 1
            do {
                let response = try await fetchDisplayAuthenticated(deliveryID: deliveryID, state: &state,
                    deadline: deadline) { progress(attempts, $0) }
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
    private func fetchDisplayAuthenticated(deliveryID: String, state: inout ApplePushDisplayAuthState, deadline: Date,
                                           sending: (_ credential: String) -> Void) async throws -> ApplePushDisplayResponse {
        do {
            return try await fetchDisplayOnce(deliveryID: deliveryID, state: state, deadline: deadline, sending: sending)
        } catch ApplePushDisplayClientError.badStatus(let status, let retryAfter) where status == 401 || status == 403 {
            guard let fallback = state.accessTokenFallback, !Task.isCancelled,
                  deadline.timeIntervalSinceNow >= Self.minimumAttemptTime else {
                throw ApplePushDisplayClientError.badStatus(status, retryAfter: retryAfter)
            }
            state = fallback
            return try await fetchDisplayOnce(deliveryID: deliveryID, state: state, deadline: deadline, sending: sending)
        }
    }

    private func fetchDisplayOnce(deliveryID: String, state: ApplePushDisplayAuthState, deadline: Date,
                                  sending: (_ credential: String) -> Void) async throws -> ApplePushDisplayResponse {
        guard let url = ApplePushDisplayWire.displayURL(serverURL: state.serverURL, deliveryID: deliveryID) else {
            throw ApplePushDisplayClientError.invalidURL
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        var request = URLRequest(url: url, timeoutInterval: min(Self.requestTimeout, remaining))
        request.setValue("Bearer \(state.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(state.profileID, forHTTPHeaderField: "X-Profile-Id")
        if !state.profileToken.isEmpty {
            request.setValue(state.profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        sending(state.credentialKind)
        let (data, response) = try await data(for: request, before: deadline)
        guard let http = response as? HTTPURLResponse else {
            throw ApplePushDisplayClientError.badStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw ApplePushDisplayClientError.badStatus(http.statusCode, retryAfter: retryAfter)
        }
        return try JSONDecoder().decode(ApplePushDisplayResponse.self, from: data)
    }

    /// The response, or `URLError(.timedOut)` at `deadline`. The session's
    /// timeouts restart with every byte received, so they cannot bound a
    /// slow response by themselves.
    private func data(for request: URLRequest, before deadline: Date) async throws -> (Data, URLResponse) {
        let session = self.session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// The wait a `Retry-After` header asks for, as delay-seconds or an
    /// HTTP date (RFC 9110). Nil for anything else, including a negative or
    /// non-finite number.
    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        return httpDate.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
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
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = fetchBudget
        // The banner waits for the extension, so a missing route fails fast
        // and the retry backoff decides how long to keep trying.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration,
                          delegate: InsecureRedirectRefusingDelegate.shared,
                          delegateQueue: nil)
    }
}

/// Hands one push's content to the system exactly once, with the outcome
/// of whichever comes first: the fetch finishing or the extension's time
/// running out. The extension's callbacks arrive on system-owned threads
/// while the fetch finishes on the Swift concurrency pool.
final class ApplePushDisplayCompletion: @unchecked Sendable {
    private struct State {
        var handler: ((UNNotificationContent) -> Void)?
        var startedAt = Date()
        /// What the system gets if time runs out first.
        var fallback: UNNotificationContent?
        var fetch: Task<Void, Never>?
        var attempts = 0
        var credential: String?
    }

    private let state = Mutex(State())
    private let record: @Sendable (ApplePushDisplayOutcome) -> Void

    init(record: @escaping @Sendable (ApplePushDisplayOutcome) -> Void) {
        self.record = record
    }

    func begin(handler: @escaping (UNNotificationContent) -> Void, startedAt: Date) {
        state.withLock {
            $0.handler = handler
            $0.startedAt = startedAt
        }
    }

    func setFallback(_ content: UNNotificationContent) {
        state.withLock { $0.fallback = content }
    }

    /// Keeps the fetch so expiry can stop it, or stops it at once when the
    /// push has already completed.
    func attach(_ fetch: Task<Void, Never>) {
        let completed = state.withLock { state in
            guard state.handler != nil else { return true }
            state.fetch = fetch
            return false
        }
        if completed { fetch.cancel() }
    }

    /// How far the fetch got, for an outcome recorded at expiry.
    func progress(attempts: Int, credential: String) {
        state.withLock { state in
            guard state.handler != nil else { return }
            state.attempts = attempts
            state.credential = credential
        }
    }

    /// Only the call that hands over the content records `outcome`, so a
    /// fetch finishing after expiry cannot record a second one.
    func complete(with content: UNNotificationContent, outcome: ApplePushDisplayOutcome? = nil) {
        let handler = state.withLock { state in
            defer { state = State() }
            return state.handler
        }
        guard let handler else { return }
        finish(handler, content: content, outcome: outcome)
    }

    /// Claims the completion before stopping the fetch: a fetch that ends
    /// because it was cancelled must not record its own outcome in place of
    /// `expired`.
    func expire() {
        let expiring = state.withLock { state -> State? in
            guard state.handler != nil, state.fallback != nil else { return nil }
            defer { state = State() }
            return state
        }
        guard let expiring, let handler = expiring.handler, let fallback = expiring.fallback else { return }
        expiring.fetch?.cancel()
        finish(handler, content: fallback, outcome: ApplePushDisplayOutcome(kind: .expired, reason: nil,
            attempts: expiring.attempts, credential: expiring.credential, startedAt: expiring.startedAt))
    }

    private func finish(_ handler: (UNNotificationContent) -> Void, content: UNNotificationContent,
                        outcome: ApplePushDisplayOutcome?) {
        if let outcome { record(outcome) }
        handler(content)
    }
}

/// What the Notification Service extension did with one push. The extension
/// has no diagnostics pipeline of its own, so it leaves these in the App
/// Group and the app moves them into the breadcrumb journal.
struct ApplePushDisplayOutcome: Codable, Equatable {
    enum Kind: String, Codable {
        case enriched
        case missingState = "missing_state"
        /// The push named a server and profile with no stored target, or
        /// with several (reason `ambiguous_target`).
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
    /// Fetch attempts made, counting one still in flight at expiry; 0 when
    /// no request went out.
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

/// The App Group hand-off between the extension, which records one outcome
/// per push, and the app, which drains them into diagnostics. Each outcome
/// is its own file, so pushes finishing at once in the extension and a
/// drain in the app never rewrite each other's records. Bounded so a phone
/// that rarely opens Silo keeps only the newest pushes.
enum ApplePushDisplayOutcomeLog {
    static let capacity = 30
    static let defaultDirectory = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.appGroup)?
        .appendingPathComponent("PushDisplayOutcomes", isDirectory: true)

    static func append(_ outcome: ApplePushDisplayOutcome, in directory: URL? = defaultDirectory) {
        guard let directory, let data = try? JSONEncoder().encode(outcome) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Named by time so the oldest sort first; the UUID keeps outcomes
        // recorded in the same microsecond apart.
        let name = String(format: "%016lld-", Int64(outcome.recordedAt.timeIntervalSince1970 * 1_000_000))
            + UUID().uuidString + ".json"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return
        }
        for record in records(in: directory).dropLast(capacity) {
            try? files.removeItem(at: record)
        }
    }

    static func drain(from directory: URL? = defaultDirectory) -> [ApplePushDisplayOutcome] {
        guard let directory else { return [] }
        return records(in: directory).compactMap { record in
            defer { try? FileManager.default.removeItem(at: record) }
            guard let data = try? Data(contentsOf: record) else { return nil }
            return try? JSONDecoder().decode(ApplePushDisplayOutcome.self, from: data)
        }
    }

    /// Oldest first.
    private static func records(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }
}
#endif
