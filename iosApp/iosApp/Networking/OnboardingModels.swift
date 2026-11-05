import Foundation

/// Server-driven onboarding tour manifest (`GET /api/v2/onboarding/flow`).
/// The server has already filtered steps for disabled features and the
/// requested surface. Unknown step kinds must be skipped, never fail decode —
/// that skip is the forward-compatibility contract that lets the server add
/// stops without an App Store release.
struct OnboardingFlow: Codable {
    let version: Int
    let tourId: String
    let steps: [OnboardingStep]
}

struct OnboardingStep: Codable, Identifiable, Hashable {
    let id: String
    /// Open string on purpose — see `OnboardingFlow` doc.
    let kind: String
    let title: String?
    let body: String?
    /// Client-side asset key; the server never sends image URLs.
    let illustration: String?
    let setting: OnboardingSettingSpec?
    let route: String?
    let actionLabel: String?
}

struct OnboardingSettingSpec: Codable, Hashable {
    /// The write API. The client saves only "profile_field"; steps naming
    /// the retired "setting" and "device_setting" targets are dropped at load.
    let target: String
    let key: String
    let control: String
    let options: [OnboardingSettingOption]?
    let `default`: String?
    let label: String?
}

struct OnboardingSettingOption: Codable, Hashable {
    let value: String
    let label: String
}

struct OnboardingState: Codable {
    let tourId: String
    let lastStep: String?
    let completedAt: String?
    let skippedAt: String?
    let done: Bool
}

/// The `PUT /api/v2/onboarding/progress` body. A nil `lastStep` is omitted.
struct OnboardingProgressRequest: Codable {
    let tourId: String
    let lastStep: String?
    let completed: Bool
    let skipped: Bool
}

/// Onboarding reads and writes that the server answered, but not in a way the
/// client can act on.
enum OnboardingProgressError: LocalizedError, Equatable {
    /// The state, flow, or receipt names a different tour than the one shown.
    case tourChanged
    /// A progress receipt that does not show the requested change.
    case unexpectedReceipt

    var errorDescription: String? {
        switch self {
        case .tourChanged:
            return "The server replaced this tour with a newer one."
        case .unexpectedReceipt:
            return "The server's reply did not confirm your tour progress. Try again."
        }
    }
}

/// Read-only compatibility for a tour preference stored by older builds after
/// an invitation was claimed. New builds never create this marker, but consume
/// an existing account-bound record so an upgrade does not reverse the user's
/// previously accepted `show_tour=false` choice.
enum LegacyInviteTourSuppression {
    private struct Record: Codable, Equatable {
        let serverId: String
        let userId: String
    }

    private static let key = "onboardingTourSuppressedAccount.v2"
    private static let unsafeLegacyKey = "onboardingTourSuppressedServerId.v1"

    static func pendingUserId(
        for serverId: String?,
        defaults: SharedDefaults = .shared
    ) -> String? {
        // The v1 value was not account-bound and is unsafe to consume.
        if defaults.containsObject(forKey: unsafeLegacyKey) {
            defaults.removeObject(forKey: unsafeLegacyKey)
        }
        guard let serverId,
              let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.serverId == serverId else {
            return nil
        }
        return record.userId
    }

    static func clear(
        serverId: String,
        userId: String,
        defaults: SharedDefaults = .shared
    ) {
        guard pendingUserId(for: serverId, defaults: defaults) == userId else { return }
        defaults.removeObject(forKey: key)
    }
}

/// Prevents an unknown future manifest from reopening an empty tour forever
/// when the completion post is temporarily unavailable. The gate retries the
/// same completion silently on later authenticated launches.
///
/// The record names the account too: profile IDs repeat across accounts on
/// one server. A record from before accounts (no account) belongs to the
/// account that owns the server's data from then.
enum UnrenderableOnboardingTourSuppression {
    private struct Record: Codable, Equatable {
        let serverId: String
        let localAccountId: String?
        let profileId: String
        let tourId: String
    }

    private static let key = "unrenderableOnboardingTour.v1"

    /// `localAccountId` defaults to the account selected on `serverId`.
    static func set(serverId: String, localAccountId: String? = nil, profileId: String, tourId: String) {
        let record = Record(
            serverId: serverId,
            localAccountId: localAccountId ?? AccountScope.localAccountId(onServer: serverId),
            profileId: profileId,
            tourId: tourId
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        SharedDefaults.shared.set(data, forKey: key)
    }

    static func pendingTourId(serverId: String?, localAccountId: String? = nil, profileId: String) -> String? {
        guard let serverId,
              let account = localAccountId ?? AccountScope.localAccountId(onServer: serverId),
              let record = record(),
              record.serverId == serverId,
              record.profileId == profileId,
              record.localAccountId == account
                || (record.localAccountId == nil
                    && LegacyLocalDataOwner.localAccountId(forServer: serverId) == account) else {
            return nil
        }
        return record.tourId
    }

    static func clear(serverId: String, localAccountId: String? = nil, profileId: String, tourId: String) {
        guard pendingTourId(serverId: serverId, localAccountId: localAccountId, profileId: profileId) == tourId else {
            return
        }
        SharedDefaults.shared.removeObject(forKey: key)
    }

    /// Removes the record when it belongs to `localAccountId` on `serverId`
    /// (or, with `includingLegacy`, is the server's record from before
    /// accounts). For sign-out (`AccountLocalData.purge`).
    static func purge(localAccountId: String, serverId: String, includingLegacy: Bool) {
        guard let record = record(), record.serverId == serverId,
              record.localAccountId == localAccountId || (includingLegacy && record.localAccountId == nil) else {
            return
        }
        SharedDefaults.shared.removeObject(forKey: key)
    }

    /// Moves the record of a server merged into another (`ServerMerge`) to
    /// the survivor when its account moved or, from before accounts, when
    /// `legacyTarget` takes that data; otherwise it goes.
    static func move(fromServer droppedServerId: String, toServer survivorServerId: String,
                     accounts: Set<String>, legacyTarget: String?) {
        guard let record = record(), record.serverId == droppedServerId else { return }
        let account: String?
        if let recorded = record.localAccountId {
            account = accounts.contains(recorded) ? recorded : nil
        } else {
            account = legacyTarget
        }
        guard let account,
              let data = try? JSONEncoder().encode(Record(serverId: survivorServerId, localAccountId: account,
                                                          profileId: record.profileId, tourId: record.tourId)) else {
            SharedDefaults.shared.removeObject(forKey: key)
            return
        }
        SharedDefaults.shared.set(data, forKey: key)
    }

    private static func record() -> Record? {
        SharedDefaults.shared.data(forKey: key).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }
}
