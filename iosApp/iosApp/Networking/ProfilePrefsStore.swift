//  The signed-in profile's preferred subtitle language, for the
//  pre-playback detail screen. Its subtitle selector floats this language
//  to the top, approximating what the player does at playback time with
//  `WatchDetail.effective_subtitle_language`; the catalog `ItemDetail` the
//  detail screen sees carries no effective fields.
//
//  The value comes from `CurrentProfileStore`, which already loads the
//  profile list once per session, so reading it costs no extra request.
//  Settings and onboarding push a newly saved value with
//  `setPreferredSubtitleLanguage(_:)`; `clear()` runs on sign-out and
//  profile switch.

import Foundation

@MainActor
final class ProfilePrefsStore: ObservableObject {

    static let shared = ProfilePrefsStore()

    /// The active profile's preferred subtitle language (ISO code), or nil
    /// when the profile hasn't set one. Read by the detail-page selector.
    @Published private(set) var preferredSubtitleLanguage: String?

    private var hasHydrated = false
    /// Bumped by `clear()` so a read that finishes after a profile switch
    /// does not apply the previous profile's value.
    private var hydrationGeneration = 0

    /// Idempotent first-load. Safe to call from `.task {}` on every view
    /// that wants the preference — subsequent invocations are no-ops until
    /// `clear()` runs.
    func hydrateIfNeeded() async {
        guard !hasHydrated else { return }
        await refresh()
    }

    /// Resolve the active profile's subtitle language from
    /// `CurrentProfileStore`. A failed load leaves `hasHydrated` false so the
    /// next `hydrateIfNeeded()` retries.
    func refresh() async {
        guard let profileId = ServerRegistry.shared.activeProfileId else {
            // No active profile yet — nothing to resolve, but don't mark
            // hydrated so a later sign-in retries.
            return
        }
        let generation = hydrationGeneration
        let profiles = CurrentProfileStore.shared
        await profiles.refresh()
        if profiles.profile?.id != profileId {
            // The cached profile predates a switch that has not reset it yet.
            await profiles.refresh(force: true)
        }
        guard hydrationGeneration == generation,
              ServerRegistry.shared.activeProfileId == profileId,
              let profile = profiles.profile, profile.id == profileId else { return }
        preferredSubtitleLanguage = profile.subtitleLanguage
        hasHydrated = true
    }

    /// Push a known value without a round-trip. Settings calls this after
    /// successfully saving a new subtitle-language preference so the
    /// detail ordering reflects the change immediately.
    func setPreferredSubtitleLanguage(_ language: String?) {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredSubtitleLanguage = (trimmed?.isEmpty ?? true) ? nil : trimmed
        hasHydrated = true
    }

    /// Wipe local state on sign-out / profile switch so the next profile
    /// gets a clean hydration cycle.
    func clear() {
        hydrationGeneration &+= 1
        preferredSubtitleLanguage = nil
        hasHydrated = false
    }
}
