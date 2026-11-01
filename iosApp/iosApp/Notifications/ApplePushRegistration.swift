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
/// - Shared (403 `push_installation_key_mismatch` for an intent other than a
///   teardown's `off`, when another saved server reports the same
///   deployment identity and lists this address's login session): the same
///   server saved under another address holds the installation with its
///   record's key. This server's record is linked to that one; a new or
///   pending intent registers with its key at its next generation, and a
///   renewal sends nothing and drops this address's display target. An
///   accepted registration removes the display targets of every other
///   address sharing the record, so one deployment keeps one target.
/// - Reset (403 `push_installation_key_mismatch` from a server that reports
///   `installation_reset_available`, for a new or pending intent other than
///   a teardown's `off`, when no saved server proves it shares the
///   deployment): the key the server holds is not this record's,
///   and this account owns the installation. The registrar resets the installation with this record's
///   key, allocates the next generation above the journal's with the same
///   key, and sends the intent once more. That send never resets again. A
///   refused reset holds the refused generation; a reset with no answer
///   leaves the intent pending, and the next trigger resets again, which the
///   contract makes safe.
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
        /// Sent, but the answer was lost or discarded (the registration's,
        /// or the reset's after a key mismatch). Kept for exact replay.
        case uncertain
        /// Nothing was sent.
        case notSent(reason: String)
        /// A removal or sign-out retired the installation on the server.
        case retirement(ApplePushRetirementQueue.Outcome)
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
    /// Every saved server's registry id.
    private let savedServerIDs: @Sendable () async -> [String]
    private let now: @Sendable () -> Date
    /// How long `unregister` waits for the retirement before it also sends
    /// the session `off`, which needs the credentials the caller deletes
    /// after `ApplePushRegistrationCoordinator.unregisterDeadline`.
    private let retirementBudget: Duration
    /// The retirements of servers whose credentials are gone.
    nonisolated let retirements: ApplePushRetirementQueue
    /// Per server: the generation not to send again until the interval ends.
    private var held: [String: (generation: Int64, at: Date)] = [:]
    /// Accounts whose saved server is being signed out of or removed. Only
    /// their `off` runs until the credentials are gone or `restore` lifts
    /// the fence, so a registration already waiting cannot turn pushes back
    /// on. A later sign-in has a new account epoch and is not held back.
    private var departing: [String: (accountID: String, epoch: UUID)] = [:]
    /// Per server, the `unregister` still running. `restore` and a newer
    /// registration end it, so a fallback that finishes after them cannot
    /// turn off or retire what they registered.
    private var teardowns: [String: UUID] = [:]
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
         savedServerIDs: @escaping @Sendable () async -> [String] = {
             await MainActor.run { ServerRegistry.shared.entries.map(\.id) }
         },
         retirements: ApplePushRetirementQueue = .shared,
         retirementBudget: Duration = .seconds(2),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.retirements = retirements
        self.retirementBudget = retirementBudget
        self.tokenStore = tokenStore
        self.journal = journal
        self.displayTargets = displayTargets
        self.savedServers = savedServers
        self.savedServerIdentity = savedServerIdentity
        self.savedServerIDs = savedServerIDs
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
            guard let record = try? journal.load(serverID: serverID), let latest = record.latest else { continue }
            var owner = latest.intent.owner
            // Another address registered last. Once it no longer shares this
            // record, or no longer holds that session (removed, signed out,
            // expired), this address registers again as itself.
            var fallback: ApplePushIntentOwner?
            if owner.serverID != serverID, let own = record.owners?[serverID] {
                await dropStaleLink(of: owner.serverID)
                if !sharesRecord(owner.serverID, with: serverID) {
                    owner = own
                } else if !(await holdsSavedSession(owner)) {
                    owner = own
                } else {
                    fallback = own
                }
            }
            var result = await register(body, savedServer: owner)
            // The other address keeps its session, but the server refused
            // its refresh: register as this one. An unreachable server or
            // provider leaves the installation where it is.
            if let fallback, result == .notSent(reason: Self.credentialRejectedReason) {
                result = await register(body, savedServer: fallback)
            }
            if result != .unchanged {
                Self.logger.info("Saved-server Apple push registration: \(String(describing: result), privacy: .public)")
            }
        }
    }

    /// Stops `serverID`'s pushes to this device before its credentials are
    /// deleted, and holds back every other registration for that account
    /// until they are gone (or `restore`).
    ///
    /// It retires the installation: the journal allocates the next
    /// generation and persists it, the retirement is queued in
    /// `retirements`, and it is sent at once. A retirement needs only the
    /// installation key, which outlives the credentials, so one the server
    /// does not answer now is sent again on a later launch, foreground or
    /// push. A server that has no retirement endpoint, or did not answer, is
    /// also turned `off` with a session while one still exists, which can
    /// reach the server over its verified local route: the active one when
    /// `activeOwner` belongs to that server, otherwise the server's stored
    /// session under its journal's owner. Unless that `off` is accepted, a
    /// retirement at the next generation stays queued.
    ///
    /// Nothing is sent for a server that never registered, whose
    /// registration the server already disabled or removed, or that shares
    /// its record with another address of the same deployment that
    /// registered last: that address holds the installation, and its pushes
    /// go on. It goes ahead of queued registrations.
    func unregister(serverID: String, activeOwner: CapturedDurableAccountAuth?) async -> Result {
        let activeIntentOwner = activeOwner.flatMap(ApplePushIntentOwner.init)
        let usesActiveSession = activeIntentOwner?.serverID == serverID
        // Fence before the first suspension, so neither a `restore` nor a
        // registration for the departing account can slip in while the
        // address's link and last owner are looked up.
        let teardown = UUID()
        teardowns[serverID] = teardown
        if let owner = usesActiveSession ? activeIntentOwner : Self.ownLastOwner(of: serverID,
               in: try? journal.load(serverID: serverID)) {
            departing[serverID] = (owner.accountID, owner.accountEpoch)
        }
        let unlinked = await dropStaleLink(of: serverID)
        let record = try? journal.load(serverID: serverID)
        let latest = record?.latest
        let (ownLastOwner, heldElsewhere) = await lastOwner(of: serverID, in: record)
        // A `restore` or a new sign-in owns the server's pushes now.
        guard teardowns[serverID] == teardown else { return .unchanged }
        if let owner = usesActiveSession ? activeIntentOwner : ownLastOwner {
            departing[serverID] = (owner.accountID, owner.accountEpoch)
        }
        // The record is still the shared one: its key must not go to the
        // server this address reaches now.
        guard unlinked else { return .notSent(reason: Self.unlinkFailedReason) }
        guard let latest, !heldElsewhere else { return .unchanged }
        if case .accepted(let registration) = latest.outcome, !registration.isActive { return .unchanged }
        // A server already retired by an earlier sign-out is retired again at
        // the same generation: its entry may be gone (a `restore` whose
        // registration never allocated, or a queue write that failed), and a
        // server without the endpoint still needs the `off` below.
        let deviceID = latest.intent.body.deviceId
        var retirement: ApplePushRetirementQueue.Outcome?
        if let entry = await allocateRetirement(serverID: serverID, deviceID: deviceID, teardown: teardown) {
            let retirements = self.retirements
            let submitting = Task { await retirements.submit(entry) }
            // An unanswered retirement keeps going while the `off` is sent.
            let answer = await Self.value(of: submitting, within: retirementBudget)
            let outcome = answer.flatMap { $0 } ?? .kept(reason: answer == nil ? "unanswered" : "in_flight")
            switch outcome {
            case .retired, .dropped:
                return .retirement(outcome)
            case .unsupported, .kept:
                retirement = outcome
            }
        }
        // A `restore` or a new sign-in owns the server's pushes now.
        guard teardowns[serverID] == teardown else { return retirement.map(Result.retirement) ?? .unchanged }
        let channel: ApplePushRegistrationChannel?
        if let activeOwner, usesActiveSession {
            channel = activeChannel(for: activeOwner)
        } else {
            channel = ownLastOwner.flatMap { savedServers.channel(for: $0) }
        }
        guard let channel else { return .notSent(reason: "server_url") }
        let off = Self.body(latest.intent.body, pushMode: ApplePushRegistrationWire.offPushMode)
        let result = await register(off, through: channel, ahead: true)
        if case .registered = result {
            // The receipt names `off`, so the server has stopped pushing.
            await retirements.cancel(serverID: serverID, reason: "turned_off")
        } else if let retirement = await allocateRetirement(serverID: serverID, deviceID: deviceID,
                                                            teardown: teardown) {
            // The `off` may not have landed; the retirement takes over above
            // its generation and is retried after the credentials are gone.
            await retirements.enqueue(retirement)
        }
        return result
    }

    /// `task`'s value, or `nil` once `limit` passes first. The task runs on.
    private nonisolated static func value<Value: Sendable>(of task: Task<Value, Never>,
                                                           within limit: Duration) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(returning: await task.value) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(returning: nil)
            }
        }
    }

    /// The retirement for the journal's next generation, persisted to the
    /// journal before it is returned, or the one that already holds the
    /// current generation. `nil` when the server never registered, its
    /// address is unknown, `teardown` has ended, or the journal cannot be
    /// read or written; nothing may then be sent as a retirement.
    private func allocateRetirement(serverID: String, deviceID: String,
                                    teardown: UUID) async -> ApplePushRetirement? {
        guard let serverURL = ServerRegistry.url(forServerId: serverID) else { return nil }
        await waitForTurn(ahead: true)
        defer { finishTurn() }
        guard teardowns[serverID] == teardown else { return nil }
        do {
            guard let record = try journal.load(serverID: serverID),
                  let retiring = try ApplePushInstallationJournal.retiring(record) else { return nil }
            if retiring.allocated {
                try journal.save(retiring.record, serverID: serverID)
            }
            return ApplePushRetirement(serverID: serverID, serverURL: serverURL, deviceID: deviceID,
                generation: retiring.record.generation, queuedAt: now())
        } catch {
            Self.logger.error("Could not allocate an Apple push retirement: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Undoes `unregister` for a server whose sign-out or removal did not
    /// happen: lifts the fence, drops the pending retirement, and turns its
    /// pushes back on with its stored session at a newer generation, so a
    /// server that stays saved and signed in is not left silent. A
    /// retirement already in flight then loses to that generation.
    func restore(serverID: String) async -> Result {
        teardowns[serverID] = nil
        guard departing.removeValue(forKey: serverID) != nil,
              let record = try? journal.load(serverID: serverID), let latest = record.latest else { return .unchanged }
        await retirements.cancel(serverID: serverID, reason: "restored")
        let body = Self.body(latest.intent.body, pushMode: ApplePushRegistrationWire.privatePushMode)
        // The address that registered last, unless it left this record.
        var owner = latest.intent.owner
        let (ownLastOwner, heldElsewhere) = await lastOwner(of: serverID, in: record)
        if !heldElsewhere, let ownLastOwner { owner = ownLastOwner }
        return await register(body, savedServer: owner)
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
            reset: { try await api.resetApplePushInstallation(deviceID: $0, installationKey: $1, auth: owner.request) },
            loginSessions: { try await api.loginSessions(cursor: $0, auth: owner.request) },
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
        guard await dropStaleLink(of: channel.owner.serverID) else {
            return .notSent(reason: Self.unlinkFailedReason)
        }
        let intentOwner = channel.owner
        let serverID = intentOwner.serverID
        let desired = ApplePushInstallationIntent(owner: intentOwner, body: body)
        let planned: (record: ApplePushInstallationRecord, command: ApplePushRegistrationCommand?, allocated: Bool)
        let slot: String
        do {
            let record = try journal.loadOrCreate(serverID: serverID)
            slot = try journal.recordSlot(for: serverID)
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

        let capability: APIv2ApplePushCapability
        do {
            capability = try await channel.capability()
            guard capability.permitsRegistration else {
                Self.logger.info("Ordered Apple push registration is unavailable: state=\(capability.state, privacy: .public) allowed=\(capability.allowed, privacy: .public) registration_available=\(capability.registrationAvailable, privacy: .public)")
                return .unavailable
            }
        } catch {
            if error as? ApplePushSavedServerError == .credentialRejected {
                return .notSent(reason: Self.credentialRejectedReason)
            }
            return .notSent(reason: "capability_\(String(describing: error))")
        }
        return await dispatch(command, allocating: planned.allocated ? planned.record : nil, in: slot, body: body,
                              through: channel, mayResetInstallation: capability.permitsInstallationReset)
    }

    /// Persists `allocating` (the record holding `command`'s new generation)
    /// when given, sends `command`, and records the answer. `slot` is the
    /// Keychain slot the command was planned from.
    /// `mayResetInstallation` allows one owner reset after a
    /// `push_installation_key_mismatch`, followed by a registration at the
    /// next generation; the registration after a reset never resets again.
    /// `mayShareRecord` allows, before that, one link to the record of
    /// another saved address proven to be the same deployment.
    private func dispatch(_ command: ApplePushRegistrationCommand, allocating: ApplePushInstallationRecord?,
                          in slot: String, body: APIv2ApplePushRegistrationBody,
                          through channel: ApplePushRegistrationChannel,
                          mayResetInstallation: Bool, mayShareRecord: Bool = true) async -> Result {
        let intentOwner = channel.owner
        let serverID = intentOwner.serverID
        // The generation reaches the Keychain before the request can leave
        // the device, in the same TokenStore turn as the owner check, so a
        // generation is never allocated for an owner that was already
        // replaced. If it cannot be stored, nothing is sent.
        if let allocated = allocating {
            let journal = self.journal
            do {
                try await channel.commit {
                    // The address was unlinked while this waited
                    // (`dropStaleLink`): the record planned here stays in the
                    // slot it left, and its key is not sent.
                    guard try journal.recordSlot(for: serverID) == slot else {
                        throw ApplePushInstallationJournal.JournalError.linkChanged
                    }
                    try journal.save(allocated, serverID: serverID)
                }
            } catch {
                return .notSent(reason: "allocation_\(error)")
            }
            // A server added again, or signed in to again, registers above
            // its pending retirement, which the server would now refuse.
            if body.pushMode != ApplePushRegistrationWire.offPushMode {
                // Only a registration by someone else ends the teardown: one
                // the departing account started before it is retired above.
                // Another address sharing the record holds the same
                // installation, so this registration ends its teardown too.
                if !isDeparting(intentOwner) {
                    teardowns[serverID] = nil
                    for alias in await otherAddressesSharingRecord(with: serverID) { teardowns[alias] = nil }
                }
                await retirements.cancel(serverID: serverID, before: command.generation, reason: "registered")
            }
        }

        let receipt: APIv2ApplePushRegistrationReceipt
        do {
            receipt = try await channel.send(command.intent.body, command.installationKey, command.generation)
        } catch {
            // The same server saved under another address holds the
            // installation with its own record's key. Once that address
            // proves it is this deployment, both share its record: a new
            // intent registers with its key at its next generation, and a
            // renewal leaves the installation to it.
            if mayShareRecord, command.intent.body.pushMode != ApplePushRegistrationWire.offPushMode,
               Self.isInstallationKeyMismatch(error), let shared = await shareProvenRecord(for: channel) {
                return await registerShared(command, in: shared, body: body, through: channel,
                                            mayResetInstallation: mayResetInstallation)
            }
            // A renewal replays an intent this key had accepted, so a
            // mismatch there means another record on this device (the same
            // server saved under a second address) registered since. A
            // renewal does not take the installation back; only a new intent
            // does, which keeps two such records from trading it on every
            // renewal. A teardown's `off` never does either: the record that
            // holds the installation is the one still saved, and a reset
            // would turn its pushes off.
            if mayResetInstallation, !command.isRenewal,
               command.intent.body.pushMode != ApplePushRegistrationWire.offPushMode,
               Self.isInstallationKeyMismatch(error) {
                return await resetInstallation(after: command, in: slot, body: body, through: channel)
            }
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
        // The deployment holds one installation for this device, so another
        // address sharing this record no longer has a registration of its own.
        let aliases = await otherAddressesSharingRecord(with: serverID)
        let displayTargets = self.displayTargets
        do {
            try await channel.commit { [target] in
                if let target {
                    displayTargets.save(target)
                } else {
                    displayTargets.removeTargets(registeredBy: serverID)
                }
                for alias in aliases {
                    displayTargets.removeTargets(registeredBy: alias)
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

    /// Links `channel`'s saved server to the record of another saved server
    /// that reports the same deployment identity and proves it
    /// (`sharesBackend`), and returns the shared record. `nil` when no saved
    /// server proves it; the reported identity alone never links.
    private func shareProvenRecord(for channel: ApplePushRegistrationChannel) async -> ApplePushInstallationRecord? {
        let serverID = channel.owner.serverID
        guard let identity = ServerIdentity.usable(await savedServerIdentity(serverID)),
              let own = try? journal.recordSlot(for: serverID) else { return nil }
        for candidate in await savedServerIDs() where candidate != serverID {
            // A candidate whose link was proven for another deployment
            // must not lend that deployment's record.
            guard ServerIdentity.usable(await savedServerIdentity(candidate)) == identity,
                  await dropStaleLink(of: candidate),
                  let shared = try? journal.recordSlot(for: candidate), shared != own,
                  let holder = try? journal.load(serverID: candidate)?.latest?.intent.owner,
                  let holderChannel = savedServers.channel(for: holder),
                  await channel.sharesBackend(with: holderChannel) else { continue }
            do {
                try journal.link(serverID, toRecordOf: candidate, provenFor: identity)
                guard let record = try journal.load(serverID: serverID) else { return nil }
                // A retirement queued for the replaced record must not be
                // sent with the shared record's key.
                await retirements.cancel(serverID: serverID, reason: "record_shared")
                // A hold names a generation of the record just replaced, which
                // the shared record may reach with a different intent.
                held[serverID] = nil
                Self.logger.info("Apple push installation record shared with another address of the same server")
                return record
            } catch {
                Self.logger.error("Could not share the Apple push installation record: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// Sends `command`'s intent once more from the shared record `shared`:
    /// a new intent at its next generation, which takes the installation;
    /// a renewal not at all, since the address that registered last holds
    /// the installation, and this address's display target goes.
    private func registerShared(_ command: ApplePushRegistrationCommand, in shared: ApplePushInstallationRecord,
                                body: APIv2ApplePushRegistrationBody, through channel: ApplePushRegistrationChannel,
                                mayResetInstallation: Bool) async -> Result {
        let serverID = channel.owner.serverID
        if command.isRenewal {
            let displayTargets = self.displayTargets
            try? await channel.commit { displayTargets.removeTargets(registeredBy: serverID) }
            return .unchanged
        }
        let planned: (record: ApplePushInstallationRecord, command: ApplePushRegistrationCommand?, allocated: Bool)
        let slot: String
        do {
            planned = try ApplePushInstallationJournal.plan(shared, desired: command.intent, renewDisplayToken: false)
            slot = try journal.recordSlot(for: serverID)
        } catch {
            return .notSent(reason: "journal_\(error)")
        }
        guard let retry = planned.command else { return .unchanged }
        return await dispatch(retry, allocating: planned.allocated ? planned.record : nil, in: slot, body: body,
                              through: channel, mayResetInstallation: mayResetInstallation, mayShareRecord: false)
    }

    /// Unlinks `serverID` from a shared record once the address reports
    /// another deployment than the one it was proven to reach, and drops the
    /// display target it registered there. `false` when that link could not
    /// be removed: the address still resolves to the shared record, so
    /// nothing may be sent for it.
    @discardableResult
    private func dropStaleLink(of serverID: String) async -> Bool {
        guard let identity = ServerIdentity.usable(await savedServerIdentity(serverID)) else { return true }
        do {
            if try journal.dropLink(of: serverID, unlessProvenFor: identity) {
                displayTargets.removeTargets(registeredBy: serverID)
            }
            return true
        } catch {
            Self.logger.error("Could not unlink the Apple push installation record: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Whether `other` and `serverID` share one record.
    private func sharesRecord(_ other: String, with serverID: String) -> Bool {
        guard let theirs = try? journal.recordSlot(for: other),
              let mine = try? journal.recordSlot(for: serverID) else { return false }
        return theirs == mine
    }

    /// Whether `owner` still holds its saved server's stored session.
    private func holdsSavedSession(_ owner: ApplePushIntentOwner) async -> Bool {
        guard let account = await tokenStore.savedSessionAccount(for: owner.serverID) else { return false }
        return account.accountID == owner.accountID && account.epoch == owner.accountEpoch
    }

    /// The other saved servers whose record is `serverID`'s.
    private func otherAddressesSharingRecord(with serverID: String) async -> [String] {
        await savedServerIDs().filter { $0 != serverID && sharesRecord($0, with: serverID) }
    }

    /// The owner of `serverID`'s last intent in `record`: the record's
    /// latest, unless another address registered after it. While that
    /// address still shares the record it holds the installation
    /// (`heldElsewhere`), and its pushes go on. That address's link is ended
    /// first when it now reports another deployment (`dropStaleLink`).
    private func lastOwner(of serverID: String, in record: ApplePushInstallationRecord?) async
        -> (owner: ApplePushIntentOwner?, heldElsewhere: Bool) {
        let own = Self.ownLastOwner(of: serverID, in: record)
        guard let holder = record?.latest?.intent.owner, holder.serverID != serverID else { return (own, false) }
        await dropStaleLink(of: holder.serverID)
        return (own, sharesRecord(holder.serverID, with: serverID))
    }

    /// `serverID`'s own last owner in `record`, read without suspending:
    /// the latest intent's when this address registered last.
    private static func ownLastOwner(of serverID: String, in record: ApplePushInstallationRecord?)
        -> ApplePushIntentOwner? {
        guard let latest = record?.latest?.intent.owner else { return nil }
        return latest.serverID == serverID ? latest : record?.owners?[serverID]
    }

    /// Recovers from a lost installation key: the owner resets the
    /// server's installation with `command`'s key, and the same intent
    /// registers at the next generation with that key. The server's cleared
    /// installation accepts any positive generation, but one above
    /// everything this record sent keeps a retirement or registration still
    /// in flight from before the reset below the new registration, and a
    /// held generation from an earlier attempt from matching it. A
    /// refused reset holds `command`'s generation as any 403 would; one with
    /// no answer leaves it pending for the next trigger.
    private func resetInstallation(after command: ApplePushRegistrationCommand, in slot: String,
                                   body: APIv2ApplePushRegistrationBody,
                                   through channel: ApplePushRegistrationChannel) async -> Result {
        let serverID = channel.owner.serverID
        let mismatch = "http_403_\(Self.installationKeyMismatch)"
        do {
            let receipt = try await channel.reset(command.intent.body.deviceId, command.installationKey)
            Self.logger.info("Apple push installation reset after a key mismatch: generation=\(command.generation, privacy: .public) reset=\(receipt.reset, privacy: .public)")
        } catch {
            guard Self.refusalReason(error) != nil || Self.forbiddenReason(error) != nil else {
                Self.logger.info("Apple push installation reset outcome unknown; keeping generation \(command.generation, privacy: .public) pending: \(String(describing: error), privacy: .public)")
                return .uncertain
            }
            held[serverID] = (command.generation, now())
            Self.logger.error("Apple push installation reset refused; holding generation \(command.generation, privacy: .public): \(String(describing: error), privacy: .public)")
            return .held(reason: mismatch)
        }
        let restarted: (record: ApplePushInstallationRecord, command: ApplePushRegistrationCommand?, allocated: Bool)
        do {
            // The same key, from `command`'s generation: the turn keeps any
            // retirement from allocating past it, so the next one is above
            // everything this record has sent.
            let fresh = ApplePushInstallationRecord(installationKey: command.installationKey,
                generation: command.generation, latest: nil,
                owners: (try? journal.load(serverID: serverID))?.owners)
            restarted = try ApplePushInstallationJournal.plan(fresh, desired: command.intent, renewDisplayToken: false)
        } catch {
            return .notSent(reason: "journal_\(error)")
        }
        guard let retry = restarted.command else { return .notSent(reason: "journal_reset") }
        return await dispatch(retry, allocating: restarted.record, in: slot, body: body, through: channel,
                              mayResetInstallation: false, mayShareRecord: false)
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

    private static let installationKeyMismatch = "push_installation_key_mismatch"
    /// `notSent` reason for a saved server whose session refresh the server
    /// refused (`ApplePushSavedServerError.credentialRejected`).
    static let credentialRejectedReason = "credential_rejected"
    /// `notSent` reason for an address whose stale link to a shared record
    /// could not be removed.
    static let unlinkFailedReason = "journal_unlink"

    /// The server's owner-only 403: this account owns the installation, but
    /// it is bound to another key.
    private static func isInstallationKeyMismatch(_ error: Error) -> Bool {
        guard case APIv2Error.problem(let problem) = error else { return false }
        return problem.status == 403 && problem.identifier == installationKeyMismatch
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

    /// How long sign-out and server removal wait for a server to stop
    /// pushing. They go ahead either way. The retirement is queued before it
    /// is sent and needs no credentials, so one that does not finish in time
    /// is sent again on a later launch, foreground or push; until it lands,
    /// the server's pushes keep the generic text, since the device no longer
    /// holds its target.
    static let unregisterDeadline: Duration = .seconds(5)

    /// Stops a saved server's (`ServerEntry.id`) pushes before its
    /// credentials are cleared: retires this installation on the server,
    /// and, when the server lacks the retirement endpoint or does not
    /// answer, turns pushes off with its session while the credentials
    /// still exist.
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

    /// Sends the retirements still pending for removed or signed-out servers
    /// whose back-off has passed. `afterPush` skips the back-off: a push
    /// arriving is the sign a retired server is still sending them.
    func retryPendingRetirements(afterPush: Bool = false) async {
        await registrar.retirements.retryDue(afterPush: afterPush)
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
                once.resume(returning: ())
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(returning: ())
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

private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: Value) {
        let pending = continuation.withLock { slot -> CheckedContinuation<Value, Never>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume(returning: value)
    }
}
#endif
