#if os(iOS)
import Foundation
import Security

enum ApplePushRegistrationError: Error, Equatable {
    /// The installation key or generation handed to the transport is not in
    /// the contract's format. Nothing was sent.
    case invalidInstallation
    /// The server answered 200 with a receipt for a different generation or
    /// payload.
    case invalidReceipt
}

/// The durable owner an Apple push intent was prepared for. Nonsecret: the
/// profile proof is excluded because re-verifying a PIN does not change which
/// profile the registration belongs to, and the server's intent identity
/// ignores it too.
struct ApplePushIntentOwner: Codable, Equatable, Sendable {
    let serverID: String
    let accountID: String
    let accountEpoch: UUID
    let profileID: String

    /// `nil` for temporary playback credentials and for a request with no
    /// selected profile; neither may register this installation.
    init?(_ auth: CapturedDurableAccountAuth) {
        guard case .persistentServer(let serverID) = auth.request.credentialOwner,
              serverID == auth.request.account.serverId,
              let profileID = auth.request.profileId, !profileID.isEmpty else { return nil }
        self.serverID = serverID
        accountID = auth.accountID
        accountEpoch = auth.accountEpoch
        self.profileID = profileID
    }
}

/// One registration intent: who it is for and exactly what it sends.
struct ApplePushInstallationIntent: Codable, Equatable, Sendable {
    let owner: ApplePushIntentOwner
    let body: APIv2ApplePushRegistrationBody
}

/// The registration the server reported for an accepted intent.
struct ApplePushAcceptedRegistration: Codable, Equatable, Sendable {
    let id: String
    let serverDeviceID: String
    let enabled: Bool
    let removed: Bool

    /// Disabled or removed registrations never carry a display credential and
    /// are never renewed: an exact replay would not revive them.
    var isActive: Bool { enabled && !removed }
}

/// What the journal knows about the intent that holds the current generation.
enum ApplePushIntentOutcome: Codable, Equatable, Sendable {
    /// Allocated, and possibly sent, with no answer recorded. Only this exact
    /// intent may be sent with this generation again.
    case pending
    case accepted(ApplePushAcceptedRegistration)
    /// The server refused it (`http_409`, `invalid_receipt`, ...). The same
    /// intent would be refused again, so it is not resent; a changed intent
    /// takes the next generation.
    case refused(reason: String)
}

/// One server's installation state, stored as a single Keychain item.
struct ApplePushInstallationRecord: Codable, Equatable, Sendable {
    struct Latest: Codable, Equatable, Sendable {
        let intent: ApplePushInstallationIntent
        var outcome: ApplePushIntentOutcome
    }

    /// Secret 32-byte installation credential, unpadded base64url. Created
    /// once per server and never rotated.
    let installationKey: String
    /// The highest generation ever allocated; 0 before the first intent.
    var generation: Int64
    /// The intent that holds `generation`.
    var latest: Latest?
}

/// A registration ready to send.
struct ApplePushRegistrationCommand: Equatable, Sendable {
    let installationKey: String
    let generation: Int64
    let intent: ApplePushInstallationIntent
    /// An exact replay of an accepted intent, sent only to renew the display
    /// token. The server does not change the registration for it.
    let isRenewal: Bool
}

/// Ordered installation state for `POST /api/v2/devices/push/apple`, one
/// Keychain item per server.
///
/// The server keys an Apple installation by `device_id` and checks two
/// headers on every registration. `X-Push-Installation-Key` proves this is the
/// installation that registered first; it is created once per server, kept
/// across account and profile switches, and never rotated.
/// `X-Push-Generation` orders intents: every new intent takes the next
/// generation, allocated and persisted before the request leaves the device,
/// and an intent whose answer was lost is sent again with the same
/// generation and the same body. A newer intent supersedes it on the server
/// whether or not the lost one landed, so the journal keeps only the latest.
///
/// The record sits in the same Keychain group, with the same accessibility,
/// as `AppleDeviceIdentity`'s device ID, so the two are kept or lost
/// together: a Keychain reset gives a new device ID, which the server treats
/// as a new installation. If the record alone is lost, the server's proof
/// check refuses every later registration for this device (403, or 409 when
/// the generation falls behind). The contract has no recovery for that, so
/// the client does not guess: a 409 is recorded as a refusal, a 403 holds
/// the intent and is retried after a back-off (the server also answers 403
/// for transient login-authority failures), an unreadable record is never
/// overwritten and nothing is sent for that server, and the
/// Notification Service extension falls back to the access token. Recovery
/// needs the server to drop this device's installation.
struct ApplePushInstallationJournal: Sendable {
    let keychain: SharedKeychain
    let makeInstallationKey: @Sendable () -> String?

    init(keychain: SharedKeychain = SharedKeychain(audience: .userIndependent),
         makeInstallationKey: @escaping @Sendable () -> String? = { randomInstallationKey() }) {
        self.keychain = keychain
        self.makeInstallationKey = makeInstallationKey
    }

    enum JournalError: Error, Equatable {
        /// The Keychain could not be read, or the stored record does not
        /// decode. The record is left as it is.
        case unreadable
        case writeFailed
        case keyUnavailable
        case generationExhausted
    }

    static func account(for serverID: String) -> String {
        "com.continuum.push.apple.installation.\(serverID)"
    }

    /// The stored record, `nil` only when no record exists for `serverID`.
    func load(serverID: String) throws -> ApplePushInstallationRecord? {
        let raw: String?
        do {
            raw = try keychain.getChecked(Self.account(for: serverID))
        } catch {
            throw JournalError.unreadable
        }
        guard let raw else { return nil }
        guard let record = try? JSONDecoder().decode(ApplePushInstallationRecord.self, from: Data(raw.utf8)),
              Self.isInstallationKey(record.installationKey), record.generation >= 0 else {
            throw JournalError.unreadable
        }
        return record
    }

    func save(_ record: ApplePushInstallationRecord, serverID: String) throws {
        let data = try JSONEncoder().encode(record)
        guard keychain.set(String(decoding: data, as: UTF8.self), for: Self.account(for: serverID)) else {
            throw JournalError.writeFailed
        }
    }

    /// The stored record, or a new one with a fresh key when none exists. A
    /// new record is not saved here; it reaches the Keychain with its first
    /// allocated intent.
    func loadOrCreate(serverID: String) throws -> ApplePushInstallationRecord {
        if let record = try load(serverID: serverID) { return record }
        guard let key = makeInstallationKey(), Self.isInstallationKey(key) else {
            throw JournalError.keyUnavailable
        }
        return ApplePushInstallationRecord(installationKey: key, generation: 0, latest: nil)
    }

    /// Decides what to send for `desired`.
    ///
    /// - The same intent, still pending: replay it exactly.
    /// - The same intent, accepted and active: replay it exactly only when
    ///   `renewDisplayToken` is set; otherwise nothing to send.
    /// - The same intent, accepted but disabled or removed, or refused:
    ///   nothing to send.
    /// - Any other intent: allocate the next generation. `allocated` tells the
    ///   caller to persist the returned record before sending.
    static func plan(_ record: ApplePushInstallationRecord, desired: ApplePushInstallationIntent,
                     renewDisplayToken: Bool) throws
        -> (record: ApplePushInstallationRecord, command: ApplePushRegistrationCommand?, allocated: Bool) {
        if let latest = record.latest, latest.intent == desired {
            let replay = ApplePushRegistrationCommand(installationKey: record.installationKey,
                generation: record.generation, intent: desired, isRenewal: latest.outcome != .pending)
            switch latest.outcome {
            case .pending:
                return (record, replay, false)
            case .accepted(let registration):
                return (record, renewDisplayToken && registration.isActive ? replay : nil, false)
            case .refused:
                return (record, nil, false)
            }
        }
        guard record.generation < Int64.max else { throw JournalError.generationExhausted }
        var next = record
        next.generation += 1
        next.latest = .init(intent: desired, outcome: .pending)
        let command = ApplePushRegistrationCommand(installationKey: next.installationKey,
            generation: next.generation, intent: desired, isRenewal: false)
        return (next, command, true)
    }

    /// `record` with `outcome` applied to `command`, or `nil` when the record
    /// no longer holds that command.
    static func recording(_ outcome: ApplePushIntentOutcome, for command: ApplePushRegistrationCommand,
                          in record: ApplePushInstallationRecord) -> ApplePushInstallationRecord? {
        guard record.installationKey == command.installationKey, record.generation == command.generation,
              var latest = record.latest, latest.intent == command.intent else { return nil }
        latest.outcome = outcome
        var next = record
        next.latest = latest
        return next
    }

    /// 43 characters of unpadded base64url that decode to 32 bytes.
    static func isInstallationKey(_ key: String) -> Bool {
        guard key.utf8.count == 43,
              key.utf8.allSatisfy({ byte in
                  (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                      || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
              }) else { return false }
        let standard = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        return base64URL(bytes) == key
    }

    static func randomInstallationKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
