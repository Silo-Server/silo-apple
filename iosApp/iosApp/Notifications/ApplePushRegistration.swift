#if os(iOS)
import Foundation
import OSLog
import Security
import UIKit
import UserNotifications

struct ApplePushRegistrationRequest: Codable, Equatable {
    let deviceId: String
    let apnsToken: String
    let apnsEnvironment: String
    let apnsTopic: String
    let pushMode: String
}

struct ApplePushRegistrationResponse: Decodable {
    let generation: String
    let removed: Bool
    let id: String
    let serverDeviceId: String
    let enabled: Bool
    let pushMode: String
    /// Long-lived, profile-scoped token for the Notification Service
    /// extension's display fetch. Absent on older servers.
    let displayToken: String?
    /// RFC 3339 expiry of `displayToken`. Absent with it.
    let displayTokenExpiresAt: String?
}

/// Persists the registration's display token where the Notification Service
/// extension reads it. Kept separate from `TokenStore`'s access/profile
/// mirrors because it is minted per registration, not per sign-in.
struct ApplePushDisplayTokenStore {
    /// Renew this far ahead of expiry so a token never lapses between two
    /// foregrounds; the server's default lifetime is 30 days.
    static let renewalLeadTime: TimeInterval = 7 * 24 * 60 * 60

    var keychain: SharedKeychain = SharedKeychain(audience: TokenStore.profileCredentialAudience)
    var defaults: SharedDefaults = .shared
    var now: () -> Date = Date.init
    var writeToken: ((String) -> Bool)? = nil

    /// `true` when a token is stored and is not within `renewalLeadTime` of
    /// its expiry. A token with no recorded expiry, or one that fails to
    /// parse, is treated as needing renewal: the metadata is written only
    /// alongside a successful Keychain write, so its absence means the
    /// token's state is unknown and a fresh registration is the safe move.
    func hasCurrentToken() -> Bool {
        let stored = keychain.get(SharedStorage.applePushDisplayTokenAccount) ?? ""
        guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let raw = defaults.string(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey),
              let expiresAt = Self.parseExpiry(raw) else {
            return false
        }
        return expiresAt.timeIntervalSince(now()) > Self.renewalLeadTime
    }

    /// Returns `true` when the token was written, or when there was nothing
    /// to write and any stale token was removed.
    ///
    /// Metadata only follows a Keychain mutation that succeeded. If the write
    /// or delete fails, the previous token and its expiry stay paired, so
    /// `hasCurrentToken()` keeps reporting the old token's real state and
    /// registration retries on the next foreground instead of treating a
    /// stale credential as current.
    @discardableResult
    func store(_ token: String?, expiresAt: String?, serverId: String) -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let removed = keychain.delete(SharedStorage.applePushDisplayTokenAccount)
            if removed {
                defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
                defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenServerIdKey)
            }
            return removed
        }
        let written = writeToken?(trimmed) ?? keychain.set(trimmed, for: SharedStorage.applePushDisplayTokenAccount)
        if written {
            defaults.set(expiresAt, forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
            defaults.set(serverId, forKey: SharedStorage.applePushDisplayTokenServerIdKey)
        }
        return written
    }

    static func parseExpiry(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

enum ApplePushRegistrationWire {
    static let endpoint = "/api/v2/devices/push/apple"
    static let defaultTopic = "org.siloserver.silo"
    static let privatePushMode = "private_push"

    /// The APNs environment is a *signing-time* decision (the
    /// `aps-environment` entitlement from the provisioning profile), not a
    /// compile-time one: the repo ships Release IPAs for sideloading that
    /// get re-signed with development profiles, and a `#if DEBUG` guess
    /// would register those sandbox tokens as "production" — every push
    /// would then fail with BadDeviceToken. Read the embedded profile
    /// instead; App Store installs carry no embedded profile and are
    /// production by definition.
    static var currentAPNsEnvironment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let environment = apnsEnvironment(fromProvisioningProfile: data) {
            return environment
        }
        return "production"
        #endif
    }

    /// Extracts `Entitlements.aps-environment` from a raw
    /// `embedded.mobileprovision` (a CMS blob wrapping an XML plist) and
    /// maps it to the server's wire values. Returns nil when the profile
    /// has no push entitlement or cannot be parsed.
    static func apnsEnvironment(fromProvisioningProfile data: Data) -> String? {
        guard let plistStart = data.range(of: Data("<plist".utf8)),
              let plistEnd = data.range(of: Data("</plist>".utf8), in: plistStart.upperBound..<data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: plistStart.lowerBound..<plistEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else {
            return nil
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }

    static func tokenHex(from data: Data) -> String {
        data.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }
        .joined()
    }

    static func topic(bundleIdentifier: String?) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultTopic : trimmed
    }
}

enum ApplePushOrderedError: Error {
    case persistence, invalidAuthority, conflict, invalidReceipt
}

struct ApplePushOrderedAuthority: Codable, Equatable {
    let serverID: String
    let serverURL: String
    let epoch: UUID
    let profileID: String
    let profileToken: String?
    let accessToken: String

    init(_ auth: CapturedOrdinaryRequestAuth) throws {
        guard case .persistentServer(let serverID) = auth.credentialOwner,
              serverID == auth.account.serverId, let profile = auth.profileId, !profile.isEmpty,
              let access = auth.accessToken, !access.isEmpty else { throw ApplePushOrderedError.invalidAuthority }
        self.serverID = serverID
        serverURL = auth.account.serverURL
        epoch = auth.account.credentialGenerationID
        profileID = profile
        profileToken = auth.profileToken
        accessToken = access
    }

    var auth: CapturedOrdinaryRequestAuth {
        CapturedOrdinaryRequestAuth(account: RefreshAccountIdentity(serverId: serverID, serverURL: serverURL,
            credentialGenerationID: epoch), credentialOwner: .persistentServer(serverId: serverID),
            accessToken: accessToken, profileId: profileID, profileToken: profileToken)
    }

    func sameOwner(as other: Self) -> Bool {
        serverID == other.serverID && serverURL == other.serverURL && epoch == other.epoch
            && profileID == other.profileID && profileToken == other.profileToken
    }
}

struct ApplePushAcceptedState: Codable {
    let id: String
    let serverDeviceID: String
    let enabled: Bool
    let removed: Bool
}

struct ApplePushOrderedIntent: Codable {
    let installationKey: String
    let generation: Int64
    let body: ApplePushRegistrationRequest
    let authority: ApplePushOrderedAuthority
    var receipt: ApplePushAcceptedState?
    var renewAfter: Date?
    var displayApplied: Bool?
}

private enum ApplePushJournalLock { static let value = NSRecursiveLock() }

/// One private, checked Keychain record owns the installation sequence.
/// Historical commands remain intact; retries never reconstruct them from UI state.
@MainActor
final class ApplePushRegistrationJournal {
    private struct Record: Codable {
        let installationKey: String
        var intents: [ApplePushOrderedIntent]
        var requiresReconciliation: Bool
    }
    private let keychain: SharedKeychain
    private let writer: (String) -> Bool
    private let account = "apple-push-ordered-intents-v1"

    init(keychain: SharedKeychain = SharedKeychain(), writer: ((String) -> Bool)? = nil) {
        self.keychain = keychain
        self.writer = writer ?? { keychain.set($0, for: "apple-push-ordered-intents-v1") }
    }

    private func load() throws -> Record? {
        try ApplePushJournalLock.value.withLock {
            guard let raw = try keychain.getChecked(account) else { return nil }
            return try JSONDecoder().decode(Record.self, from: Data(raw.utf8))
        }
    }

    private func save(_ record: Record) throws {
        let raw = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        guard ApplePushJournalLock.value.withLock({ writer(raw) }) else { throw ApplePushOrderedError.persistence }
    }

    func latest() throws -> ApplePushOrderedIntent? { try load()?.intents.last }

    /// Serialize the journal currency check and credential write with every
    /// journal save, including a newer same-owner APNs intent.
    func credentialEffect(for intent: ApplePushOrderedIntent, clearing: Bool,
                          effect: @escaping @Sendable () throws -> Void) -> @Sendable () throws -> Void {
        let keychain = self.keychain
        let account = self.account
        return {
            try ApplePushJournalLock.value.withLock {
                guard let raw = try keychain.getChecked(account),
                      let record = try? JSONDecoder().decode(Record.self, from: Data(raw.utf8)),
                      let last = record.intents.last, last.generation == intent.generation,
                      last.installationKey == intent.installationKey, last.body == intent.body,
                      last.authority == intent.authority, clearing || !record.requiresReconciliation else {
                    throw ApplePushOrderedError.conflict
                }
                try effect()
            }
        }
    }

    func prepare(body: ApplePushRegistrationRequest, auth: CapturedOrdinaryRequestAuth) throws -> ApplePushOrderedIntent {
        let authority = try ApplePushOrderedAuthority(auth)
        var record: Record
        if let existing = try load() { record = existing } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ApplePushOrderedError.persistence }
            let key = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            record = Record(installationKey: key, intents: [], requiresReconciliation: false)
        }
        guard !record.requiresReconciliation else { throw ApplePushOrderedError.conflict }
        if let last = record.intents.last, last.body == body, last.authority.sameOwner(as: authority) { return last }
        let previous = record.intents.last?.generation ?? 0
        guard previous < Int64.max else { throw ApplePushOrderedError.conflict }
        let intent = ApplePushOrderedIntent(installationKey: record.installationKey, generation: previous + 1,
            body: body, authority: authority)
        record.intents.append(intent)
        try save(record)
        return intent
    }

    func isCurrent(_ intent: ApplePushOrderedIntent) throws -> Bool {
        guard let record = try load(), !record.requiresReconciliation, let last = record.intents.last else { return false }
        return last.generation == intent.generation && last.installationKey == intent.installationKey
            && last.body == intent.body && last.authority == intent.authority
    }

    func requireReconciliation(_ intent: ApplePushOrderedIntent) throws {
        guard var record = try load(), record.intents.last?.generation == intent.generation else { return }
        record.requiresReconciliation = true
        try save(record)
    }

    func markDisplayApplied(_ intent: ApplePushOrderedIntent) throws {
        guard var record = try load(), try isCurrent(intent) else { return }
        record.intents[record.intents.count - 1].displayApplied = true
        try save(record)
    }

    func accept(_ response: ApplePushRegistrationResponse, for intent: ApplePushOrderedIntent, now: Date) throws {
        guard var record = try load(), try isCurrent(intent), let last = record.intents.last else { throw ApplePushOrderedError.conflict }
        guard response.generation == String(intent.generation), response.pushMode == intent.body.pushMode,
              !response.id.isEmpty, !response.serverDeviceId.isEmpty,
              last.receipt.map({ $0.id == response.id && $0.serverDeviceID == response.serverDeviceId }) ?? true else {
            throw ApplePushOrderedError.invalidReceipt
        }
        let index = record.intents.count - 1
        record.intents[index].receipt = ApplePushAcceptedState(id: response.id, serverDeviceID: response.serverDeviceId,
            enabled: response.enabled, removed: response.removed)
        record.intents[index].displayApplied = false
        record.intents[index].renewAfter = response.displayToken == nil ? now.addingTimeInterval(6 * 60 * 60) : nil
        try save(record)
    }
}

@MainActor
final class ApplePushOrderedRegistration {
    private let api: APIv2Client
    private let tokens: TokenStore
    private let journal: ApplePushRegistrationJournal
    private let display: ApplePushDisplayTokenStore
    private let now: () -> Date
    private var inFlight = Set<Int64>()

    init(api: APIv2Client = APIv2Client(), tokens: TokenStore = .shared,
         journal: ApplePushRegistrationJournal? = nil,
         display: ApplePushDisplayTokenStore = ApplePushDisplayTokenStore(), now: @escaping () -> Date = Date.init) {
        self.api = api; self.tokens = tokens; self.journal = journal ?? ApplePushRegistrationJournal(); self.display = display; self.now = now
    }

    func register(body: ApplePushRegistrationRequest, auth: CapturedOrdinaryRequestAuth) async throws {
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else { throw HTTPError.requestIdentityChanged }
        let intent: ApplePushOrderedIntent
        do { intent = try journal.prepare(body: body, auth: auth) }
        catch ApplePushOrderedError.conflict {
            if let latest = try journal.latest() { try await storeDisplay(nil, expiry: nil, intent: latest) }
            throw ApplePushOrderedError.conflict
        }
        let original = intent.authority.auth
        if let receipt = intent.receipt, !receipt.enabled || receipt.removed {
            try await storeDisplay(nil, expiry: nil, intent: intent)
            return
        }
        if intent.receipt != nil && intent.displayApplied == true && (display.hasCurrentToken() || (intent.renewAfter.map { $0 > now() } ?? false)) { return }
        guard inFlight.insert(intent.generation).inserted else { return }
        defer { inFlight.remove(intent.generation) }
        do {
            let capability = try await api.applePushRegistrationCapability(auth: original)
            guard capability.revision == "ordered_apple_v1", capability.registrationAvailable else { return }
            guard try journal.isCurrent(intent), !Task.isCancelled else { return }
            let response = try await api.registerApplePush(intent: intent)
            guard try journal.isCurrent(intent), !Task.isCancelled else { return }
            if let token = response.displayToken, response.enabled && !response.removed, !token.isEmpty {
                guard let raw = response.displayTokenExpiresAt, let expiry = ApplePushDisplayTokenStore.parseExpiry(raw),
                      expiry > now() else { throw ApplePushOrderedError.invalidReceipt }
            }
            try journal.accept(response, for: intent, now: now())
            // Disabled/removed current receipts never install credentials,
            // even if an invalid server response includes one.
            let token = response.enabled && !response.removed ? response.displayToken : nil
            try await storeDisplay(token, expiry: token == nil ? nil : response.displayTokenExpiresAt, intent: intent)
            try journal.markDisplayApplied(intent)
        } catch {
            let conflict: Bool
            switch error {
            case APIv2Error.problem(let problem): conflict = problem.status == 409
            case APIv2Error.httpStatus(let status): conflict = status == 409
            case ApplePushOrderedError.invalidReceipt: conflict = true
            default: conflict = false
            }
            if conflict, try journal.isCurrent(intent) {
                try journal.requireReconciliation(intent)
                try await storeDisplay(nil, expiry: nil, intent: intent)
            }
            throw error
        }
    }

    private func storeDisplay(_ token: String?, expiry: String?, intent: ApplePushOrderedIntent) async throws {
        let display = self.display
        let auth = intent.authority.auth
        let effect = journal.credentialEffect(for: intent, clearing: token == nil) {
            guard display.store(token, expiresAt: expiry, serverId: auth.account.serverId) else { throw ApplePushOrderedError.persistence }
        }
        try await tokens.withCurrentOrdinaryAuthority(auth, operation: effect)
    }

}

@MainActor
final class ApplePushRegistrationCoordinator {
    static let shared = ApplePushRegistrationCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePush"
    )

    private var lastDeviceToken: Data?
    private let ordered = ApplePushOrderedRegistration()

    private init() {}

    func prepareForAuthenticatedProfile() async {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    Self.logger.info("User declined Apple push notification authorization")
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                Self.logger.error("Apple push authorization request failed: \(String(describing: error), privacy: .public)")
            }
        case .denied:
            Self.logger.info("Apple push notification authorization is denied")
        @unknown default:
            Self.logger.info("Apple push notification authorization is in an unknown state")
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        lastDeviceToken = deviceToken
        await registerCurrentDeviceTokenIfPossible()
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        Self.logger.error("APNs device-token registration failed: \(String(describing: error), privacy: .public)")
    }

    func registerCurrentDeviceTokenIfPossible() async {
        guard let lastDeviceToken,
              let owner = await TokenStore.shared.captureDurableAccountAuth(), owner.request.profileId != nil else { return }
        let request = makeRegistrationRequest(deviceToken: lastDeviceToken)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        do {
            // Requires migrated storage and guarded writers on every serving
            // node. The local capability is not a fleet rollout receipt.
            try await ordered.register(body: request, auth: owner.request)
        } catch {
            Self.logger.info("Ordered Apple registration was not completed; retained intent requires retry or reconciliation")
        }
    }

    private func makeRegistrationRequest(deviceToken: Data) -> ApplePushRegistrationRequest {
        ApplePushRegistrationRequest(
            deviceId: AppleDeviceIdentity.current.id,
            apnsToken: ApplePushRegistrationWire.tokenHex(from: deviceToken),
            apnsEnvironment: ApplePushRegistrationWire.currentAPNsEnvironment,
            apnsTopic: ApplePushRegistrationWire.topic(bundleIdentifier: Bundle.main.bundleIdentifier),
            pushMode: ApplePushRegistrationWire.privatePushMode
        )
    }

}
#endif
