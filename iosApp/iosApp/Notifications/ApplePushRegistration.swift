#if os(iOS)
import Foundation
import OSLog
import Synchronization
import UIKit
import UserNotifications

extension ApplePushDisplayTarget {
    /// Renew this far ahead of expiry so a token never lapses between two
    /// foregrounds; the server's default lifetime is 30 days.
    static let renewalLeadTime: TimeInterval = 7 * 24 * 60 * 60

    /// Whether the token outlives the renewal window. A token with no
    /// recorded or readable expiry is renewed: its state is unknown.
    func isCurrent(at now: Date) -> Bool {
        guard !displayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = expiresAt, let expiry = Self.parseExpiry(raw) else { return false }
        return expiry.timeIntervalSince(now) > Self.renewalLeadTime
    }

    static func parseExpiry(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

extension ApplePushDisplayTargetStore {
    /// Moves the one display token an earlier build kept into a target for
    /// the server and profile it was minted for, which were active then:
    /// that build dropped the token whenever either changed. Without a
    /// known deployment identity the target is stored for renewal, whose
    /// receipt names the identity. The old token is deleted once a target
    /// holds it, or at once when it no longer matches the active server.
    func migrateLegacyToken(defaults: SharedDefaults, savedServer: (String) -> ServerEntry?) {
        guard let token = keychain.get(SharedStorage.applePushDisplayTokenAccount) else { return }
        let registryServerID = defaults.string(forKey: SharedStorage.applePushDisplayTokenServerIdKey) ?? ""
        if registryServerID == defaults.string(forKey: SharedStorage.activeServerIdKey),
           let profileID = defaults.string(forKey: SharedStorage.profileIdKey), !profileID.isEmpty,
           let server = savedServer(registryServerID) {
            let serverID = ServerIdentity.usable(server.verifiedServerId)
            let migrated = save(ApplePushDisplayTarget(
                serverID: serverID,
                profileID: profileID,
                registryServerID: registryServerID,
                serverURL: server.url,
                displayToken: token,
                expiresAt: serverID == nil ? nil : defaults.string(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
            ))
            guard migrated else { return }
        }
        guard keychain.delete(SharedStorage.applePushDisplayTokenAccount) else { return }
        defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
        defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenServerIdKey)
    }
}

enum ApplePushRegistrationWire {
    static let defaultTopic = "org.siloserver.silo"
    static let privatePushMode = "private_push"
    static let offPushMode = "off"

    /// The APNs environment is a *signing-time* decision (the
    /// `aps-environment` entitlement from the provisioning profile), not a
    /// compile-time one: the repo ships Release IPAs for sideloading that
    /// get re-signed with development profiles, and a `#if DEBUG` guess
    /// would register those sandbox tokens as "production" — every push
    /// would then fail with BadDeviceToken. Read the embedded profile
    /// instead; App Store installs carry no embedded profile and are
    /// production by definition.
    /// Read once: the profile can't change while the app runs.
    static let currentAPNsEnvironment: String = {
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
    }()

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
/// the main actor; registrations queue so at most one runs at a time, for
/// any server.
///
/// The active server registers through `HTTPClient` under the captured
/// durable owner. Every other saved server with a display target registers
/// through its own stored session (`ApplePushSavedServerClient`), so its
/// display token stays current while another server is in use.
///
/// Outcomes (`docs/native-api-v2.md`):
/// - Accepted: the journal records the receipt; the server's display target
///   is stored (or removed for a disabled, removed, or non-push
///   registration) while the owner still holds the server's credentials.
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
    private let displayTargets: ApplePushDisplayTargetStore
    private let savedServers: ApplePushSavedServerClient
    /// The deployment identity the registry knows for a saved server, for a
    /// receipt that does not name one.
    private let savedServerIdentity: @Sendable (String) async -> String?
    private let now: @Sendable () -> Date
    /// Per server: the generation not to send again until the interval ends.
    private var held: [String: (generation: Int64, at: Date)] = [:]
    /// Accounts whose saved server is being signed out of or removed. Only
    /// their `off` runs until the credentials are gone or `restore` lifts
    /// the fence, so a registration already waiting cannot turn pushes back
    /// on. A later sign-in has a new account epoch and is not held back.
    private var departing: [String: (accountID: String, epoch: UUID)] = [:]
    private var isRegistering = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    init(api: APIv2Client = SiloAPI.shared.apiV2Client, tokenStore: TokenStore = .shared,
         journal: ApplePushInstallationJournal = ApplePushInstallationJournal(),
         displayTargets: ApplePushDisplayTargetStore = ApplePushDisplayTargetStore(
             keychain: SharedKeychain(audience: TokenStore.profileCredentialAudience)),
         savedServers: ApplePushSavedServerClient = ApplePushSavedServerClient(),
         savedServerIdentity: @escaping @Sendable (String) async -> String? = { serverID in
             await MainActor.run { ServerRegistry.shared.entry(with: serverID)?.verifiedServerId }
         },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.tokenStore = tokenStore
        self.journal = journal
        self.displayTargets = displayTargets
        self.savedServers = savedServers
        self.savedServerIdentity = savedServerIdentity
        self.now = now
    }

    /// Registers the active server under its captured durable owner.
    func register(_ body: APIv2ApplePushRegistrationBody, owner: CapturedDurableAccountAuth) async -> Result {
        guard let channel = activeChannel(for: owner) else { return .notSent(reason: "owner") }
        return await register(body, through: channel)
    }

    /// Registers a saved server under `owner`, the owner of its journal's
    /// latest intent, with that server's stored session.
    func register(_ body: APIv2ApplePushRegistrationBody, savedServer owner: ApplePushIntentOwner) async -> Result {
        guard let channel = savedServers.channel(for: owner) else { return .notSent(reason: "server_url") }
        return await register(body, through: channel)
    }

    /// Keeps the registration of every other saved server in `serverIDs`
    /// current, each with its own stored session: renews a display token
    /// nearing expiry, moves the registration to a new APNs token, and sends
    /// again an intent whose answer was lost or that came back without a
    /// token. It follows each server's journal rather than its display
    /// target, which a lost answer or a tokenless receipt leaves stale or
    /// missing. A server turned off for a sign-out or removal that did not
    /// happen is turned back on while its stored session still works.
    /// `activeServerID` was just registered through the active session and
    /// is skipped. A cancelled pass stops between servers.
    func registerSavedServers(_ body: APIv2ApplePushRegistrationBody, among serverIDs: [String],
                              skipping activeServerID: String?) async {
        for serverID in serverIDs where serverID != activeServerID {
            guard !Task.isCancelled else { return }
            guard let latest = try? journal.load(serverID: serverID)?.latest else { continue }
            let result = await register(body, savedServer: latest.intent.owner)
            if result != .unchanged {
                Self.logger.info("Saved-server Apple push registration: \(String(describing: result), privacy: .public)")
            }
        }
    }

    /// Turns pushes off for `serverID` while its credentials still exist,
    /// and holds back every other registration for that account until they
    /// are gone (or `restore`). Uses the active session when `activeOwner`
    /// belongs to that server, otherwise the server's stored session under
    /// its journal's owner. Nothing is sent for a server that never
    /// registered, or whose registration the server already disabled or
    /// removed. It goes ahead of queued registrations: the credentials it
    /// needs are about to be deleted.
    func unregister(serverID: String, activeOwner: CapturedDurableAccountAuth?) async -> Result {
        let latest = try? journal.load(serverID: serverID)?.latest
        let activeIntentOwner = activeOwner.flatMap(ApplePushIntentOwner.init)
        let usesActiveSession = activeIntentOwner?.serverID == serverID
        if let owner = usesActiveSession ? activeIntentOwner : latest?.intent.owner {
            departing[serverID] = (owner.accountID, owner.accountEpoch)
        }
        guard let latest else { return .unchanged }
        if case .accepted(let registration) = latest.outcome, !registration.isActive { return .unchanged }
        let channel: ApplePushRegistrationChannel?
        if let activeOwner, usesActiveSession {
            channel = activeChannel(for: activeOwner)
        } else {
            channel = savedServers.channel(for: latest.intent.owner)
        }
        guard let channel else { return .notSent(reason: "server_url") }
        let off = Self.body(latest.intent.body, pushMode: ApplePushRegistrationWire.offPushMode)
        return await register(off, through: channel, ahead: true)
    }

    /// Undoes `unregister` for a server whose sign-out or removal did not
    /// happen: lifts the fence and turns its pushes back on with its stored
    /// session, so a server that stays saved and signed in is not left
    /// silent.
    func restore(serverID: String) async -> Result {
        guard departing.removeValue(forKey: serverID) != nil,
              let latest = try? journal.load(serverID: serverID)?.latest else { return .unchanged }
        let body = Self.body(latest.intent.body, pushMode: ApplePushRegistrationWire.privatePushMode)
        return await register(body, savedServer: latest.intent.owner)
    }

    private static func body(_ body: APIv2ApplePushRegistrationBody, pushMode: String) -> APIv2ApplePushRegistrationBody {
        APIv2ApplePushRegistrationBody(deviceId: body.deviceId, apnsToken: body.apnsToken,
            apnsEnvironment: body.apnsEnvironment, apnsTopic: body.apnsTopic, pushMode: pushMode)
    }

    private func activeChannel(for owner: CapturedDurableAccountAuth) -> ApplePushRegistrationChannel? {
        guard let intentOwner = ApplePushIntentOwner(owner) else { return nil }
        let api = self.api, tokenStore = self.tokenStore
        return ApplePushRegistrationChannel(
            owner: intentOwner,
            serverURL: owner.request.account.serverURL,
            capability: { try await api.applePushRegistrationCapability(auth: owner.request) },
            send: { try await api.registerApplePush($0, installationKey: $1, generation: $2, auth: owner.request) },
            commit: { try await tokenStore.withCurrentDurableAuthority(owner, operation: $0) }
        )
    }

    private func register(_ body: APIv2ApplePushRegistrationBody, through channel: ApplePushRegistrationChannel,
                          ahead: Bool = false) async -> Result {
        await waitForTurn(ahead: ahead)
        defer { finishTurn() }
        if body.pushMode != ApplePushRegistrationWire.offPushMode, isDeparting(channel.owner) {
            return .notSent(reason: "departing")
        }
        if let field = ApplePushRegistrationWire.contractViolation(in: body) {
            return .notSent(reason: "invalid_\(field)")
        }
        let intentOwner = channel.owner
        let serverID = intentOwner.serverID
        let desired = ApplePushInstallationIntent(owner: intentOwner, body: body)
        let planned: (record: ApplePushInstallationRecord, command: ApplePushRegistrationCommand?, allocated: Bool)
        do {
            let record = try journal.loadOrCreate(serverID: serverID)
            // Only a push registration carries a display token to renew; an
            // accepted `off` is never replayed.
            let renew = body.pushMode == ApplePushRegistrationWire.privatePushMode
                && needsDisplayToken(owner: intentOwner, generation: record.generation)
            planned = try ApplePushInstallationJournal.plan(record, desired: desired, renewDisplayToken: renew)
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
            let capability = try await channel.capability()
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
                try await channel.commit {
                    try journal.save(allocated, serverID: serverID)
                }
            } catch {
                return .notSent(reason: "allocation_\(error)")
            }
        }

        let receipt: APIv2ApplePushRegistrationReceipt
        do {
            receipt = try await channel.send(command.intent.body, command.installationKey, command.generation)
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
        // Always written, even without a token: a disabled, removed, or
        // non-push registration, or a server that cannot mint a token, must
        // not leave an older target behind. The write runs in the same
        // TokenStore turn as the owner check, so a sign-out that already
        // removed the target cannot be undone by this late answer.
        let token = receipt.displayToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var target: ApplePushDisplayTarget?
        if registration.isActive, body.pushMode == ApplePushRegistrationWire.privatePushMode, !token.isEmpty {
            var deploymentID = ServerIdentity.usable(receipt.serverId)
            if deploymentID == nil {
                deploymentID = ServerIdentity.usable(await savedServerIdentity(serverID))
            }
            target = ApplePushDisplayTarget(serverID: deploymentID, profileID: intentOwner.profileID,
                registryServerID: serverID, serverURL: channel.serverURL, displayToken: token,
                expiresAt: receipt.displayTokenExpiresAt)
        }
        let displayTargets = self.displayTargets
        do {
            try await channel.commit { [target] in
                if let target {
                    displayTargets.save(target)
                } else {
                    displayTargets.removeTargets(registeredBy: serverID)
                }
            }
        } catch {
            Self.logger.info("Discarding Apple push display token: owner changed while in flight")
        }
        held[serverID] = registration.isActive && receipt.displayToken == nil
            ? (command.generation, now()) : nil
        Self.logger.info("Registered APNs token with Silo generation=\(command.generation, privacy: .public) renewal=\(command.isRenewal, privacy: .public) push_mode=\(body.pushMode, privacy: .public) server_device_id=\(receipt.serverDeviceId, privacy: .private) enabled=\(receipt.enabled, privacy: .public) removed=\(receipt.removed, privacy: .public) displayToken=\(target != nil, privacy: .public)")
        return .registered(registration)
    }

    private func needsDisplayToken(owner: ApplePushIntentOwner, generation: Int64) -> Bool {
        if let target = displayTargets.target(registeredBy: owner.serverID), target.profileID == owner.profileID,
           target.isCurrent(at: now()) {
            return false
        }
        return !isHeld(serverID: owner.serverID, generation: generation)
    }

    private func isDeparting(_ owner: ApplePushIntentOwner) -> Bool {
        guard let leaving = departing[owner.serverID] else { return false }
        return leaving.accountID == owner.accountID && leaving.epoch == owner.accountEpoch
    }

    /// `ahead` takes the next turn, before every registration already
    /// waiting.
    private func waitForTurn(ahead: Bool) async {
        guard isRegistering else {
            isRegistering = true
            return
        }
        await withCheckedContinuation { continuation in
            if ahead {
                queued.insert(continuation, at: 0)
            } else {
                queued.append(continuation)
            }
        }
    }

    /// Hands the turn to the next queued registration, if any.
    private func finishTurn() {
        if queued.isEmpty {
            isRegistering = false
        } else {
            queued.removeFirst().resume()
        }
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

/// The system calls the coordinator needs to decide on and request
/// notification permission. `live` wraps UNUserNotificationCenter,
/// UIApplication and AuthService; tests substitute closures.
struct ApplePushAuthorizationClient {
    var hasAuthenticatedProfile: @MainActor () -> Bool
    var authorizationStatus: @MainActor () async -> UNAuthorizationStatus
    var requestAuthorization: @MainActor () async throws -> Bool
    var registerForRemoteNotifications: @MainActor () -> Void

    static var live: ApplePushAuthorizationClient {
        ApplePushAuthorizationClient(
            hasAuthenticatedProfile: {
                AuthService.shared.hasServer && AuthService.shared.hasProfile
            },
            authorizationStatus: {
                await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            },
            registerForRemoteNotifications: {
                UIApplication.shared.registerForRemoteNotifications()
            }
        )
    }
}

@MainActor
final class ApplePushRegistrationCoordinator {
    static let shared = ApplePushRegistrationCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePush"
    )

    private let authorization: ApplePushAuthorizationClient
    private let registrar: ApplePushRegistrar
    private var lastDeviceToken: Data?
    private var registrationRunning = false
    private var registrationRequested = false
    /// The running pass, which `unregister` cancels.
    private var registrationPass: Task<Void, Never>?
    /// Sign-outs and removals turning a server off right now. No pass starts
    /// while one runs; a pass asked for meanwhile runs after it.
    private var teardowns = 0
    private var authorizationRequest: Task<Void, Never>?

    /// The permission request that is still waiting for the user's answer, if
    /// any. Tests await its `value` to observe what the answer led to.
    var pendingAuthorizationRequest: Task<Void, Never>? { authorizationRequest }

    init(authorization: ApplePushAuthorizationClient = .live,
         registrar: ApplePushRegistrar = ApplePushRegistrar()) {
        self.authorization = authorization
        self.registrar = registrar
    }

    /// Registers for remote notifications when permission is granted, and asks
    /// for it when it is undetermined. It never waits for the user's answer:
    /// ContentView awaits this on the session hydration chain, and download
    /// capability, scope activation and queued Downloads links must not wait
    /// on a system alert. A grant registers from the background request.
    func prepareForAuthenticatedProfile() async {
        guard authorization.hasAuthenticatedProfile() else {
            return
        }

        switch await authorization.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            authorization.registerForRemoteNotifications()
        case .notDetermined:
            requestAuthorizationInBackground()
        case .denied:
            Self.logger.info("Apple push notification authorization is denied")
        @unknown default:
            Self.logger.info("Apple push notification authorization is in an unknown state")
        }
    }

    /// Starts the permission request unless one is already waiting for the
    /// user, and registers for remote notifications if they allow it.
    private func requestAuthorizationInBackground() {
        guard authorizationRequest == nil else { return }
        authorizationRequest = Task { [self] in
            defer { authorizationRequest = nil }
            do {
                let granted = try await authorization.requestAuthorization()
                guard granted else {
                    Self.logger.info("User declined Apple push notification authorization")
                    return
                }
                authorization.registerForRemoteNotifications()
            } catch {
                Self.logger.error("Apple push authorization request failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Keeps saved servers' registrations current while no profile is in
    /// use (Who's Watching, a timed-out profile), so their display tokens do
    /// not lapse there. It never asks for permission. With permission
    /// already granted and no APNs token yet, it asks for the token, whose
    /// arrival runs the pass.
    func maintainWithoutProfile() async {
        switch await authorization.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            guard lastDeviceToken != nil else {
                authorization.registerForRemoteNotifications()
                return
            }
            await registerCurrentDeviceTokenIfPossible()
        default:
            return
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        lastDeviceToken = deviceToken
        await registerCurrentDeviceTokenIfPossible()
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        Self.logger.error("APNs device-token registration failed: \(String(describing: error), privacy: .public)")
    }

    /// Registers the current APNs token for the current owner, then keeps
    /// every other saved server's registration current. Saved servers are
    /// kept current with or without a profile in use. A call while a pass is
    /// running asks for one more pass after it, so a token or profile change
    /// during the send is not lost.
    func registerCurrentDeviceTokenIfPossible() async {
        guard AuthService.shared.hasServer, lastDeviceToken != nil else {
            return
        }
        registrationRequested = true
        guard !registrationRunning, teardowns == 0 else { return }
        registrationRunning = true
        defer {
            registrationRunning = false
            registrationPass = nil
        }
        while registrationRequested, teardowns == 0 {
            registrationRequested = false
            let pass = Task { await registerOnce() }
            registrationPass = pass
            await pass.value
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
        let body = makeRegistrationRequest(deviceToken: lastDeviceToken)
        // Registration is durable work for one verified account, login and
        // profile. Temporary playback credentials and unverified sessions
        // cannot capture this owner, so they never register the installation.
        var activeServerID: String?
        if let owner = await TokenStore.shared.captureDurableAccountAuth() {
            activeServerID = ApplePushIntentOwner(owner)?.serverID
            let result = await registrar.register(body, owner: owner)
            if case .notSent(let reason) = result {
                Self.logger.info("Apple push registration not sent: \(reason, privacy: .public)")
            }
        } else {
            Self.logger.info("Skipping Apple push registration: no verified account owner to register under")
        }
        await registrar.registerSavedServers(body, among: ServerRegistry.shared.entries.map(\.id),
                                             skipping: activeServerID)
    }

    /// How long sign-out and server removal wait for a server to turn pushes
    /// off. They go ahead either way; the server's later pushes then keep
    /// the generic text, since the device no longer holds its target.
    static let unregisterDeadline: Duration = .seconds(5)

    /// Turns pushes off for a saved server (`ServerEntry.id`) before its
    /// credentials are cleared. Once they are gone nothing can tell the
    /// server, which would keep pushing notifications this device cannot
    /// display.
    func unregister(serverID: String) async {
        // Turning a server off outranks keeping registrations current. The
        // running pass stops at its next request, no new one starts until
        // this ends, and the next pass sends whatever was left pending.
        teardowns += 1
        registrationPass?.cancel()
        let registrar = self.registrar
        let owner = await TokenStore.shared.captureDurableAccountAuth()
        await Self.waitAtMost(Self.unregisterDeadline) {
            _ = await registrar.unregister(serverID: serverID, activeOwner: owner)
        }
        teardowns -= 1
        if teardowns == 0, registrationRequested {
            Task { await registerCurrentDeviceTokenIfPossible() }
        }
    }

    /// Turns pushes back on for a server whose sign-out or removal failed
    /// after `unregister` turned them off.
    func restore(serverID: String) async {
        let registrar = self.registrar
        await Self.waitAtMost(Self.unregisterDeadline) {
            _ = await registrar.restore(serverID: serverID)
        }
    }

    /// Moves an earlier build's single display token into a target. Runs at
    /// launch, before a registration pass could renew it.
    static func migrateLegacyDisplayToken() {
        ApplePushDisplayTargetStore(keychain: SharedKeychain(audience: TokenStore.profileCredentialAudience))
            .migrateLegacyToken(defaults: .shared) { ServerRegistry.shared.entry(with: $0) }
    }

    /// Waits for `operation` at most `limit`. Past that it runs on unawaited;
    /// its owner fence refuses anything it would still write once the
    /// credentials are gone.
    nonisolated static func waitAtMost(_ limit: Duration, for operation: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                await operation()
                once.resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume()
            }
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

private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        let pending = continuation.withLock { slot -> CheckedContinuation<Void, Never>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume()
    }
}
#endif
