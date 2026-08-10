import Foundation

@MainActor
protocol OnboardingRuntimeSettingsRefreshing {
    func refreshAfterProfileWrite(key: String, value: String) async
}

/// Adopts an onboarding profile write immediately, then rehydrates the
/// server-backed stores that were loaded before the tour opened.
@MainActor
final class OnboardingRuntimeSettingsRefresher: OnboardingRuntimeSettingsRefreshing {
    func refreshAfterProfileWrite(key: String, value: String) async {
        applyImmediateValue(key: key, value: value)

        // Reconcile all player settings in case the server normalized the
        // value or policy changed its effective result.
        _ = await PlayerSettings.shared.refreshFromServer()

        // Profile selection and detail screens may already hold the cached
        // profile returned before onboarding. Replace it with a fresh copy.
        ResponseCache.shared.remove(CacheKey.profiles)
        if let profiles = try? await StartupContentPrefetcher.fetchProfiles(),
           let profileId = AuthService.shared.profileId,
           let profile = profiles.first(where: { $0.id == profileId }) {
            ProfilePrefsStore.shared.setPreferredSubtitleLanguage(profile.subtitleLanguage)
        }
    }

    private func applyImmediateValue(key: String, value: String) {
        switch key {
        case "quality_preference":
            if let preset = SiloQualityPresets.preset(id: value) {
                PlayerSettings.shared.preferredQualityResolution = preset.resolution
                PlayerSettings.shared.maxBitrateKbps = preset.bitrateKbps
            } else {
                PlayerSettings.shared.preferredQualityResolution =
                    SiloQualityPresets.normalizeResolution(value)
                PlayerSettings.shared.maxBitrateKbps = nil
            }
        case "subtitle_language":
            ProfilePrefsStore.shared.setPreferredSubtitleLanguage(value)
        case "auto_skip_intro":
            if let enabled = Self.boolean(value) {
                PlayerSettings.shared.autoSkipIntro = enabled
            }
        case "auto_skip_credits":
            if let enabled = Self.boolean(value) {
                PlayerSettings.shared.autoSkipCredits = enabled
            }
        default:
            break
        }
    }

    private static func boolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: nil
        }
    }
}
