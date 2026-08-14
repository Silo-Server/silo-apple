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
