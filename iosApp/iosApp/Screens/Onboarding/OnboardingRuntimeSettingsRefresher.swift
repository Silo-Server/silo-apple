import Foundation

@MainActor
protocol OnboardingRuntimeSettingsRefreshing {
    func refreshAfterProfileWrite(key: String, value: String, owner: CapturedDurableAccountAuth?) async
}

/// Reconciles a profile write without letting a different profile's ambient
/// cache or async loader take ownership of the result.
@MainActor
final class OnboardingRuntimeSettingsRefresher: OnboardingRuntimeSettingsRefreshing {
    func refreshAfterProfileWrite(key: String, value: String, owner: CapturedDurableAccountAuth?) async {
        guard let owner else { return }
        let settings = CanonicalProfileSettingsV2()
        do {
            try await settings.requireCurrent(owner)
            try await PlayerSettings.shared.refreshFromServer(owner: owner)
            try await settings.requireCurrent(owner)
            let response = try await settings.read([.playbackSubtitleLanguage], owner: owner)
            try await settings.requireCurrent(owner)
            ProfilePrefsStore.shared.setPreferredSubtitleLanguage(
                response.value(for: .playbackSubtitleLanguage)?.value.stringValue ?? ""
            )
            ResponseCache.shared.remove(CacheKey.profiles)
        } catch {
            // The save receipt is already owned. A failed or stale refresh
            // cannot project values into the next owner's runtime state.
        }
    }
}
