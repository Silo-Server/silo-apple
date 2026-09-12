import CryptoKit
import Foundation

// Type definitions the v2 wire layer needs for sequenced playback mutations and
// canonical settings commands. Only the shapes that cross the wire or name a
// wire outcome live here. The journals, stores, and coordinators that sequence
// these commands belong to the write-surface PRs and build on
// `DurableCommandStore`; their barrier logic (target matching, held states) is
// deliberately not part of these definitions.

// MARK: Sequenced playback

/// The negotiated feature changes mutation semantics, not the playback URL prefix.
enum PlaybackSequencedContract {
    static let feature = "sequenced_progress_v1"
}

struct PlaybackSequencedSample: Codable, Equatable, Sendable {
    let sequence: Int64
    let position: Double
    let isPaused: Bool
    let timelineId: String?
    let itemPosition: Double?

    init(sequence: Int64, position: Double, isPaused: Bool, timelineId: String? = nil, itemPosition: Double? = nil) throws {
        guard sequence > 0, position.isFinite, position >= 0 else { throw PlaybackSequencedError.invalidSample }
        self.sequence = sequence
        self.position = position
        self.isPaused = isPaused
        self.timelineId = timelineId
        self.itemPosition = itemPosition
    }

    enum CodingKeys: String, CodingKey { case sequence, position, isPaused = "is_paused", timelineId = "timeline_id", itemPosition = "item_position" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sequence: values.decode(Int64.self, forKey: .sequence),
            position: values.decode(Double.self, forKey: .position), isPaused: values.decode(Bool.self, forKey: .isPaused),
            timelineId: values.decodeIfPresent(String.self, forKey: .timelineId),
            itemPosition: values.decodeIfPresent(Double.self, forKey: .itemPosition))
    }
}

enum PlaybackSequencedError: LocalizedError {
    case invalidSample, invalidResponse, invalidSession, authorityChanged, pendingStart
    var errorDescription: String? {
        switch self {
        case .pendingStart: return "A previous playback start is unresolved. Retry it before starting another item."
        case .invalidSample: return "Playback progress could not be recorded."
        case .invalidResponse: return "The server returned an invalid playback response."
        case .invalidSession: return "This playback session is no longer available."
        case .authorityChanged: return "The account or profile changed. Playback was not retried."
        }
    }
}

// MARK: Canonical settings commands

/// Nonsecret identity captured with a new settings command. A later login or
/// profile proof cannot take ownership of an earlier command.
struct SettingsMutationAuthority: Codable, Equatable, Sendable {
    let serverID: String
    let origin: String
    let accountID: String
    let accountEpoch: UUID
    let credentialGeneration: UUID
    let profileID: String
    let profileProofHash: String?
    let deviceID: String
    let clientFamily: String

    init(_ auth: CapturedDurableAccountAuth, deviceID: String = AppleDeviceIdentity.current.id,
         clientFamily: String = AppleDeviceIdentity.current.clientFamily) throws {
        guard case .persistentServer = auth.request.credentialOwner,
              let profile = auth.request.profileId, !profile.isEmpty, !deviceID.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        serverID = auth.request.account.serverId
        origin = auth.request.account.serverURL
        accountID = auth.accountID
        accountEpoch = auth.accountEpoch
        credentialGeneration = auth.request.account.credentialGenerationID
        profileID = profile
        profileProofHash = auth.request.profileToken.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        self.deviceID = deviceID
        self.clientFamily = clientFamily
    }

    /// Credential generations and profile proofs are transport snapshots, not
    /// durable queue ownership. A cold TokenStore must still see this target's
    /// unresolved commands under the same persisted account epoch. This is the
    /// predicate a settings store passes to `DurableCommandStore.snapshot(owner:)`.
    func sameDurableOwner(as other: Self) -> Bool {
        serverID == other.serverID && origin == other.origin && accountID == other.accountID
            && accountEpoch == other.accountEpoch && profileID == other.profileID
            && deviceID == other.deviceID && clientFamily == other.clientFamily
    }
}

/// One canonical settings mutation as dispatched: exact method, path, query and
/// body bytes under the authority captured when it was prepared. It is the
/// record `DurableCommandStore<SettingsMutationCommand>` persists, so it
/// carries the shared lifecycle `state` and `updatedAt` stamp; the settings
/// write surface adds its target-matching barrier on top, not here.
struct SettingsMutationCommand: DurableCommandRecord, Equatable {
    let id: UUID
    let authority: SettingsMutationAuthority
    let key: String
    let method: String
    let path: String
    let query: [String: String]
    let body: Data?
    var state: DurableCommandState
    var updatedAt: Date
}

enum SettingsMutationHold: LocalizedError {
    case legacy, uncertain, noAuthority
    var errorDescription: String? {
        switch self {
        case .legacy: return "An earlier settings change is held for its original owner. It has not been sent again."
        case .uncertain: return "A settings change has an unknown outcome. Further changes to that setting are held."
        case .noAuthority: return "Reload settings for this profile before saving a server preference."
        }
    }
}
