import Foundation

/// Server-driven onboarding tour manifest (server: /api/v1/onboarding/*).
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
    /// "profile_field" | "setting" | "device_setting" — selects the write API.
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

struct OnboardingProgressRequest: Codable {
    let tourId: String
    let lastStep: String?
    let completed: Bool
    let skipped: Bool
}

/// Bridges an invitation's `show_tour=false` hint across profile creation.
/// The server cannot record profile-scoped progress until a profile exists,
/// so the authenticated gate posts the skip and clears this durable hint.
/// Binding the marker to the newly claimed user prevents a later account on
/// the same server from consuming another invitee's preference.
enum OnboardingTourSuppression {
    private struct Record: Codable, Equatable {
        let serverId: String
        let userId: String
    }

    private static let key = "onboardingTourSuppressedAccount.v2"
    private static let legacyKey = "onboardingTourSuppressedServerId.v1"

    static func set(
        for serverId: String,
        userId: String,
        defaults: SharedDefaults = .shared
    ) {
        guard let data = try? JSONEncoder().encode(Record(serverId: serverId, userId: userId)) else {
            return
        }
        defaults.removeObject(forKey: legacyKey)
        defaults.set(data, forKey: key)
    }

    static func pendingUserId(
        for serverId: String?,
        defaults: SharedDefaults = .shared
    ) -> String? {
        // The v1 value was not account-bound and is unsafe to consume.
        if defaults.containsObject(forKey: legacyKey) {
            defaults.removeObject(forKey: legacyKey)
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
enum UnrenderableOnboardingTourSuppression {
    private struct Record: Codable, Equatable {
        let serverId: String
        let profileId: String
        let tourId: String
    }

    private static let key = "unrenderableOnboardingTour.v1"

    static func set(serverId: String, profileId: String, tourId: String) {
        let record = Record(serverId: serverId, profileId: profileId, tourId: tourId)
        guard let data = try? JSONEncoder().encode(record) else { return }
        SharedDefaults.shared.set(data, forKey: key)
    }

    static func pendingTourId(serverId: String?, profileId: String) -> String? {
        guard let serverId,
              let data = SharedDefaults.shared.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.serverId == serverId,
              record.profileId == profileId else {
            return nil
        }
        return record.tourId
    }

    static func clear(serverId: String, profileId: String, tourId: String) {
        guard pendingTourId(serverId: serverId, profileId: profileId) == tourId else { return }
        SharedDefaults.shared.removeObject(forKey: key)
    }
}
