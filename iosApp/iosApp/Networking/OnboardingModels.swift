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
enum OnboardingTourSuppression {
    private static let key = "onboardingTourSuppressedServerId.v1"

    static func set(for serverId: String) {
        SharedDefaults.shared.set(serverId, forKey: key)
    }

    static func applies(to serverId: String?) -> Bool {
        guard let serverId else { return false }
        return SharedDefaults.shared.string(forKey: key) == serverId
    }

    static func clear() {
        SharedDefaults.shared.removeObject(forKey: key)
    }
}
