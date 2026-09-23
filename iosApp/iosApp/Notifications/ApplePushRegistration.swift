#if os(iOS)
import Foundation
import OSLog
import UIKit
import UserNotifications

/// Persists the registration's display token where the Notification Service
/// extension reads it. Kept separate from `TokenStore`'s access/profile
/// mirrors because it is minted per registration, not per sign-in.
struct ApplePushDisplayTokenStore {
    /// Renew this far ahead of expiry so a token never lapses between two
    /// foregrounds; the server's default lifetime is 30 days.
    static let renewalLeadTime: TimeInterval = 7 * 24 * 60 * 60

    var keychain: SharedKeychain = SharedKeychain(audience: TokenStore.profileCredentialAudience)
    var defaults: SharedDefaults = .shared
    var now: @Sendable () -> Date = { Date() }

    /// `true` when a token issued by `serverID` is stored and is not within
    /// `renewalLeadTime` of its expiry. A token with no recorded expiry, or
    /// one that fails to parse, is treated as needing renewal: the metadata is
    /// written only alongside a successful Keychain write, so its absence
    /// means the token's state is unknown and a fresh registration is the
    /// safe move.
    func hasCurrentToken(forServerID serverID: String) -> Bool {
        guard defaults.string(forKey: SharedStorage.applePushDisplayTokenServerIdKey) == serverID else { return false }
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
        let written = keychain.set(trimmed, for: SharedStorage.applePushDisplayTokenAccount)
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

    /// Why the server's `ApplePushRegistrationBody` schema would refuse
    /// `body`, or `nil` when it fits. Checked before a generation is
    /// allocated so a body the server can only answer with 422 never
    /// consumes one; a build signed with another bundle ID stops here.
    static func contractViolation(in body: APIv2ApplePushRegistrationBody) -> String? {
        if !(1...128).contains(body.deviceId.count) { return "device_id" }
        if !(64...512).contains(body.apnsToken.count) { return "apns_token" }
        if !["production", "sandbox"].contains(body.apnsEnvironment) { return "apns_environment" }
        if body.apnsTopic != defaultTopic { return "apns_topic" }
        if !["off", "in_app_only", privatePushMode].contains(body.pushMode) { return "push_mode" }
        return nil
    }
}

/// Runs one ordered registration: journal allocation, the capability check,
/// the send, and the receipt. An actor so Keychain reads and writes stay off
/// the main actor and at most one registration runs at a time.
///
/// Outcomes (`docs/native-api-v2.md`):
/// - Accepted: the journal records the receipt; the display token is stored
///   (or cleared for a disabled or removed registration) under the captured
///   durable owner.
/// - Refused (400, 404, 406, 409, 413, 415, 422, or a receipt for another
///   generation): the journal records the refusal and the intent is not sent
///   again. The next changed intent (APNs token, account, login, profile)
///   takes the next generation. There is no generation rebase and no new key.
/// - Held (403, or a refused display-token renewal other than 409): the
///   journal keeps what it had, `pending` or `accepted`, and the same
///   generation is not sent again for `heldGenerationRetryInterval`. The
///   server answers 403 both for a bad installation proof and for a login
///   authority check that can fail transiently, with the same problem type,
///   so a 403 is not a verdict on the intent. A renewal is an exact replay of
///   an accepted intent, and the server never changes a registration for it,
///   so its refusal leaves the accepted registration in place. A 409 on a
///   renewal means the server has moved past this generation and is recorded
///   as a refusal.
/// - Anything else (no answer, 401 after refresh, 408, 429, 5xx, owner change
///   while in flight): the intent stays pending with its generation and is
///   sent again exactly, same key, generation and body, on the next trigger
///   under the same owner. The operation's retry safety is `domain_identity`,
///   and the contract asks for exactly this replay after uncertainty.
actor ApplePushRegistrar {
    enum Result: Equatable, Sendable {
        case registered(ApplePushAcceptedRegistration)
        /// Nothing to send: the intent is already accepted with a current
        /// display token, or it was refused.
        case unchanged
        /// The server does not offer ordered Apple registration to this owner.
        case unavailable
        case refused(reason: String)
        /// The server refused this send without a verdict on the intent. The
        /// journal is unchanged and the generation is held for a while.
        case held(reason: String)
        /// Sent, but the answer was lost or discarded. Kept for exact replay.
        case uncertain
        /// Nothing was sent.
        case notSent(reason: String)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePush"
    )
    /// How long a held generation is not sent again: after a registration
    /// accepted without a display token (so a server upgrade is noticed), a
    /// 403, or a refused renewal. The hold is in memory, so a relaunch also
    /// retries.
    static let heldGenerationRetryInterval: TimeInterval = 6 * 60 * 60
    private static let refusalStatuses: Set<Int> = [400, 404, 406, 409, 413, 415, 422]

    private let api: APIv2Client
    private let tokenStore: TokenStore
    private let journal: ApplePushInstallationJournal
    private let displayTokens: ApplePushDisplayTokenStore
    private let now: @Sendable () -> Date
    /// Per server: the generation not to send again until the interval ends.
    private var held: [String: (generation: Int64, at: Date)] = [:]

    init(api: APIv2Client = SiloAPI.shared.apiV2Client, tokenStore: TokenStore = .shared,
         journal: ApplePushInstallationJournal = ApplePushInstallationJournal(),
         displayTokens: ApplePushDisplayTokenStore = ApplePushDisplayTokenStore(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.tokenStore = tokenStore
        self.journal = journal
        self.displayTokens = displayTokens
        self.now = now
    }

    func register(_ body: APIv2ApplePushRegistrationBody, owner: CapturedDurableAccountAuth) async -> Result {
        guard let intentOwner = ApplePushIntentOwner(owner) else { return .notSent(reason: "owner") }
        if let field = ApplePushRegistrationWire.contractViolation(in: body) {
            return .notSent(reason: "invalid_\(field)")
        }
        let serverID = intentOwner.serverID
        let desired = ApplePushInstallationIntent(owner: intentOwner, body: body)
        let planned: (record: ApplePushInstallationRecord, command: ApplePushRegistrationCommand?, allocated: Bool)
        do {
            let record = try journal.loadOrCreate(serverID: serverID)
            planned = try ApplePushInstallationJournal.plan(record, desired: desired,
                renewDisplayToken: needsDisplayToken(serverID: serverID, generation: record.generation))
        } catch {
            return .notSent(reason: "journal_\(error)")
        }
        guard let command = planned.command else { return .unchanged }
        // A held pending intent. A held accepted intent never gets here:
        // `needsDisplayToken` already declined its renewal.
        if !planned.allocated, isHeld(serverID: serverID, generation: command.generation) {
            return .notSent(reason: "held")
        }

        do {
            let capability = try await api.applePushRegistrationCapability(auth: owner.request)
            guard capability.permitsRegistration else {
                Self.logger.info("Ordered Apple push registration is unavailable: state=\(capability.state, privacy: .public) allowed=\(capability.allowed, privacy: .public) registration_available=\(capability.registrationAvailable, privacy: .public)")
                return .unavailable
            }
        } catch {
            return .notSent(reason: "capability_\(String(describing: error))")
        }

        // The generation reaches the Keychain before the request can leave
        // the device, in the same TokenStore turn as the owner check, so a
        // generation is never allocated for an owner that was already
        // replaced. If it cannot be stored, nothing is sent.
        if planned.allocated {
            let journal = self.journal
            let allocated = planned.record
            do {
                try await tokenStore.withCurrentDurableAuthority(owner) {
                    try journal.save(allocated, serverID: serverID)
                }
            } catch {
                return .notSent(reason: "allocation_\(error)")
            }
        }

        let receipt: APIv2ApplePushRegistrationReceipt
        do {
            receipt = try await api.registerApplePush(command.intent.body, installationKey: command.installationKey,
                generation: command.generation, auth: owner.request)
        } catch {
            if let reason = Self.refusalReason(error), !command.isRenewal || Self.isGenerationConflict(error) {
                record(.refused(reason: reason), for: command, serverID: serverID)
                Self.logger.error("Apple push registration refused: generation=\(command.generation, privacy: .public) reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return .refused(reason: reason)
            }
            if let reason = Self.refusalReason(error) ?? Self.forbiddenReason(error) {
                held[serverID] = (command.generation, now())
                Self.logger.error("Apple push registration held: generation=\(command.generation, privacy: .public) renewal=\(command.isRenewal, privacy: .public) reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return .held(reason: reason)
            }
            Self.logger.info("Apple push registration outcome unknown; keeping generation \(command.generation, privacy: .public) for exact replay: \(String(describing: error), privacy: .public)")
            return .uncertain
        }

        let registration = ApplePushAcceptedRegistration(id: receipt.id, serverDeviceID: receipt.serverDeviceId,
            enabled: receipt.enabled, removed: receipt.removed)
        record(.accepted(registration), for: command, serverID: serverID)
        // Always store, even when nil: a disabled or removed registration, or
        // a server that cannot mint a token, must not leave an older token in
        // the extension's slot. The write runs in the same TokenStore turn as
        // the owner check, so a sign-out or profile switch that already
        // cleared the slot cannot be undone by this late answer.
        let token = registration.isActive ? receipt.displayToken : nil
        let displayTokens = self.displayTokens
        let expiresAt = token == nil ? nil : receipt.displayTokenExpiresAt
        do {
            try await tokenStore.withCurrentDurableAuthority(owner) {
                displayTokens.store(token, expiresAt: expiresAt, serverId: serverID)
            }
        } catch {
            Self.logger.info("Discarding Apple push display token: owner changed while in flight")
        }
        held[serverID] = registration.isActive && receipt.displayToken == nil
            ? (command.generation, now()) : nil
        Self.logger.info("Registered APNs token with Silo generation=\(command.generation, privacy: .public) renewal=\(command.isRenewal, privacy: .public) server_device_id=\(receipt.serverDeviceId, privacy: .private) enabled=\(receipt.enabled, privacy: .public) removed=\(receipt.removed, privacy: .public) displayToken=\(token != nil, privacy: .public)")
        return .registered(registration)
    }

    private func needsDisplayToken(serverID: String, generation: Int64) -> Bool {
        !displayTokens.hasCurrentToken(forServerID: serverID) && !isHeld(serverID: serverID, generation: generation)
    }

    private func isHeld(serverID: String, generation: Int64) -> Bool {
        guard let entry = held[serverID], entry.generation == generation else { return false }
        return now().timeIntervalSince(entry.at) < Self.heldGenerationRetryInterval
    }

    /// Records the answer for `command`. A failed write leaves the intent
    /// pending, which only costs one exact replay.
    private func record(_ outcome: ApplePushIntentOutcome, for command: ApplePushRegistrationCommand, serverID: String) {
        do {
            guard let stored = try journal.load(serverID: serverID),
                  let next = ApplePushInstallationJournal.recording(outcome, for: command, in: stored) else { return }
            try journal.save(next, serverID: serverID)
        } catch {
            Self.logger.error("Could not record the Apple push registration outcome: \(String(describing: error), privacy: .public)")
        }
    }

    /// A definite refusal of this exact intent, or `nil` when the outcome is
    /// unknown or the refusal is not about the intent (401, 403, 408, 410,
    /// 429, 5xx, a v1-only server).
    private static func refusalReason(_ error: Error) -> String? {
        switch error {
        case ApplePushRegistrationError.invalidReceipt:
            return "invalid_receipt"
        case APIv2Error.problem(let problem) where refusalStatuses.contains(problem.status):
            return "http_\(problem.status)_\(problem.identifier)"
        case APIv2Error.httpStatus(let status) where refusalStatuses.contains(status):
            return "http_\(status)"
        default:
            return nil
        }
    }

    /// A 403: a bad installation proof, or a login authority check that
    /// failed, possibly transiently. The server uses one problem type for
    /// both, so the client cannot tell them apart.
    private static func forbiddenReason(_ error: Error) -> String? {
        switch error {
        case APIv2Error.problem(let problem) where problem.status == 403:
            return "http_403_\(problem.identifier)"
        case APIv2Error.httpStatus(403):
            return "http_403"
        default:
            return nil
        }
    }

    /// A 409: the server holds a newer generation, or another intent for this
    /// one.
    private static func isGenerationConflict(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.problem(let problem): return problem.status == 409
        case APIv2Error.httpStatus(let status): return status == 409
        default: return false
        }
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
    private let registrar = ApplePushRegistrar()
    private var registrationRunning = false
    private var registrationRequested = false

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

    /// Registers the current APNs token for the current owner. A call while a
    /// registration is running asks for one more pass after it, so a token or
    /// profile change during the send is not lost and two sends never race
    /// for a generation.
    func registerCurrentDeviceTokenIfPossible() async {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile, lastDeviceToken != nil else {
            return
        }
        registrationRequested = true
        guard !registrationRunning else { return }
        registrationRunning = true
        defer { registrationRunning = false }
        while registrationRequested {
            registrationRequested = false
            await registerOnce()
        }
    }

    private func registerOnce() async {
        guard let lastDeviceToken else { return }
        // The cached token can outlive the user's permission: if they revoke
        // notification authorization in Settings, a later foreground or
        // profile switch must not re-upload the token for the new context.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }
        // Registration is durable work for one verified account, login and
        // profile. Temporary playback credentials and unverified sessions
        // cannot capture this owner, so they never register the installation.
        guard let owner = await TokenStore.shared.captureDurableAccountAuth() else {
            Self.logger.info("Skipping Apple push registration: no verified account owner to register under")
            return
        }
        let result = await registrar.register(makeRegistrationRequest(deviceToken: lastDeviceToken), owner: owner)
        if case .notSent(let reason) = result {
            Self.logger.info("Apple push registration not sent: \(reason, privacy: .public)")
        }
    }

    private func makeRegistrationRequest(deviceToken: Data) -> APIv2ApplePushRegistrationBody {
        APIv2ApplePushRegistrationBody(
            deviceId: AppleDeviceIdentity.current.id,
            apnsToken: ApplePushRegistrationWire.tokenHex(from: deviceToken),
            apnsEnvironment: ApplePushRegistrationWire.currentAPNsEnvironment,
            apnsTopic: ApplePushRegistrationWire.topic(bundleIdentifier: Bundle.main.bundleIdentifier),
            pushMode: ApplePushRegistrationWire.privatePushMode
        )
    }
}
#endif
