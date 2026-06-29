#if os(tvOS)
import Foundation

/// State container for the tvOS settings screen.
///
/// Local-only fields (preferred quality, auto-play, subtitle size) live
/// in `UserDefaults`. The subtitle-language / behavior / forced-subs
/// trio is profile-wide on the server and persisted via
/// `PUT /profiles/{id}`. The server cascades profile → library →
/// per-series at playback time, so a single profile-level edit is
/// enough to make subs auto-enable everywhere unless the user later
/// adds a library or series override (web only for now).
@Observable
final class TVSettingsViewModel {
    var userInfo: UserInfo?
    var activeProfile: UserProfile?

    /// Friendly label for the active server. Reads through the registry
    /// so a rename or switch reflects without reloading the screen.
    var serverDisplayName: String {
        ServerRegistry.shared.activeServer?.displayName ?? ""
    }

    /// Raw URL of the active server. Shown as the caption under the
    /// friendly name. Reads through the registry so it tracks switches.
    var serverUrl: String {
        ServerRegistry.shared.activeServerUrl
    }

    // Playback preferences (server-backed for this device/profile).
    var preferredQuality: String = PlayerSettings.shared.preferredQuality
    var preferredAudioLanguage: String = PlayerSettings.shared.audioLanguage
    var autoPlayNext: Bool = PlayerSettings.shared.autoPlayNextEpisode
    var nextUpPromptSeconds: Int = PlayerSettings.shared.nextUpPromptSeconds
    var skipIntros: Bool = PlayerSettings.shared.autoSkipIntro
    var skipCredits: Bool = PlayerSettings.shared.autoSkipCredits
    var preferProfile7HDR10Fallback: Bool = PlayerSettings.shared.preferProfile7HDR10Fallback

    // Subtitle styling (local — applies to renderer overrides, not the
    // language/behavior selection that lives server-side).
    var subtitleSize: String = "medium"
    var subtitleAppearance: SubtitleAppearance = PlayerSettings.shared.subtitleAppearance
    var subtitleUsesDeviceAppearanceOverride: Bool = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride

    // Server-backed profile prefs editor. Each editor field is either
    // the `PlaybackPrefSentinel.none` sentinel ("__none__") or a concrete
    // value. We persist directly to the active profile via PUT /profiles/{id}.
    var editorSubtitleLanguage: String = PlaybackPrefSentinel.none
    var editorSubtitleMode: String = SubtitleMode.auto.rawValue
    /// Tri-state stored as "on" / "off". The server treats nil and
    /// false the same way at the cascade root (false), so we always
    /// send a concrete bool.
    var editorShowForcedSubtitles: String = "on"
    /// Preferred metadata language. `PlaybackPrefSentinel.none` maps to
    /// the empty string ("inherit the library default") on the wire.
    /// Gated on `AICapabilities.shared.metadataEnabled` at the row.
    var editorPreferredMetadataLanguage: String = PlaybackPrefSentinel.none

    /// Surfaces the most recent server save state. Settings UI shows a
    /// transient message when prefSaveState != nil.
    var prefSaveState: PrefSaveState?

    enum PrefSaveState: Equatable {
        case saving
        case saved
        case failed(String)
    }

    // MARK: - Derived

    var isAdmin: Bool { userInfo?.isAdmin == true }

    var displayName: String {
        if let profileName = activeProfile?.name, !profileName.isEmpty {
            return profileName
        }
        return userInfo?.username ?? "Silo"
    }

    var accountSubtitle: String {
        if isAdmin { return "Administrator" }
        if let username = userInfo?.username, !username.isEmpty {
            return username
        }
        return "Signed in"
    }

    var profileAvatar: String? {
        activeProfile?.avatarEmoji
    }

    // MARK: - Load / save

    func load() async {
        await PlayerSettings.shared.refreshFromServer()
        preferredQuality = PlayerSettings.shared.preferredQuality
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        preferProfile7HDR10Fallback = PlayerSettings.shared.preferProfile7HDR10Fallback
        subtitleSize = UserDefaults.standard.string(forKey: "subtitleSize") ?? "medium"
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride

        async let user: UserInfo? = try? ContinuumAPI.shared.get("/api/v1/user/me")
        async let profiles: [UserProfile] = (try? AuthService.shared.getProfiles()) ?? []

        let (loadedUser, loadedProfiles) = await (user, profiles)
        userInfo = loadedUser

        if let activeId = AuthService.shared.profileId {
            activeProfile = loadedProfiles.first(where: { $0.id == activeId })
        } else {
            activeProfile = nil
        }

        projectActiveProfileIntoEditor()
    }

    func saveSubtitleSizePreference() {
        UserDefaults.standard.set(subtitleSize, forKey: "subtitleSize")
    }

    @MainActor
    func setPreferredQuality(_ value: String) async {
        PlayerSettings.shared.setPreferredQuality(value)
        preferredQuality = PlayerSettings.shared.preferredQuality
    }

    @MainActor
    func setPreferredAudioLanguage(_ value: String) async {
        PlayerSettings.shared.setAudioLanguage(value)
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
    }

    @MainActor
    func setAutoPlayNext(_ enabled: Bool) async {
        PlayerSettings.shared.setAutoPlayNextEpisode(enabled)
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
    }

    @MainActor
    func setNextUpPromptSeconds(_ seconds: Int) async {
        PlayerSettings.shared.setNextUpPromptSeconds(seconds)
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
    }

    @MainActor
    func setSkipIntros(_ enabled: Bool) async {
        PlayerSettings.shared.setAutoSkipIntro(enabled)
        skipIntros = PlayerSettings.shared.autoSkipIntro
    }

    @MainActor
    func setSkipCredits(_ enabled: Bool) async {
        PlayerSettings.shared.setAutoSkipCredits(enabled)
        skipCredits = PlayerSettings.shared.autoSkipCredits
    }

    @MainActor
    func setPreferProfile7HDR10Fallback(_ enabled: Bool) async {
        PlayerSettings.shared.setPreferProfile7HDR10Fallback(enabled)
        preferProfile7HDR10Fallback = PlayerSettings.shared.preferProfile7HDR10Fallback
    }

    @MainActor
    func resetPlaybackDeviceSettings() async {
        await PlayerSettings.shared.resetAllDeviceSettings()
        preferredQuality = PlayerSettings.shared.preferredQuality
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        preferProfile7HDR10Fallback = PlayerSettings.shared.preferProfile7HDR10Fallback
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await PlayerSettings.shared.setSubtitleAppearance(appearance)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        await PlayerSettings.shared.setSubtitleDeviceOverrideEnabled(enabled)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    /// Push the current editor state to the server as a profile patch.
    /// Triggered from the view's `onChange` handlers.
    @MainActor
    func saveProfilePrefs() async {
        guard let profileId = activeProfile?.id, !profileId.isEmpty else { return }

        prefSaveState = .saving

        let body = UpdateProfileBody(
            subtitleLanguage: outboundSubtitleLanguage(editorSubtitleLanguage),
            subtitleMode: editorSubtitleMode,
            showForcedSubtitles: editorShowForcedSubtitles == "on"
        )
        do {
            try await ContinuumAPI.shared.updateProfile(profileId: profileId, body: body)
            prefSaveState = .saved
            // Keep the detail-page track-ordering preference in sync.
            ProfilePrefsStore.shared.setPreferredSubtitleLanguage(body.subtitleLanguage)
            // Refresh the local profile snapshot so a re-load reflects
            // what we just wrote.
            if let prof = activeProfile {
                activeProfile = UserProfile(
                    id: prof.id,
                    name: prof.name,
                    avatarEmoji: prof.avatarEmoji,
                    hasPin: prof.hasPin,
                    isChild: prof.isChild,
                    subtitleLanguage: body.subtitleLanguage,
                    subtitleMode: body.subtitleMode,
                    showForcedSubtitles: body.showForcedSubtitles,
                    preferredMetadataLanguage: prof.preferredMetadataLanguage
                )
            }
        } catch {
            prefSaveState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            )
        }
    }

    /// Persist the preferred metadata language as a profile patch. Kept
    /// separate from `saveProfilePrefs()` because it has a side effect the
    /// subtitle prefs don't: when the language actually changes we flush
    /// the cached overviews/taglines (and the tvOS `ItemDetailCache`) so
    /// the next detail/browse fetch picks up the server-side translation.
    @MainActor
    func saveMetadataLanguage() async {
        guard let profileId = activeProfile?.id, !profileId.isEmpty else { return }

        let newValue = outboundSubtitleLanguage(editorPreferredMetadataLanguage)
        let oldValue = activeProfile?.preferredMetadataLanguage ?? ""
        let changed = newValue != oldValue

        prefSaveState = .saving

        let body = UpdateProfileBody(preferredMetadataLanguage: newValue)
        do {
            try await ContinuumAPI.shared.updateProfile(profileId: profileId, body: body)
            prefSaveState = .saved
            if let prof = activeProfile {
                activeProfile = UserProfile(
                    id: prof.id,
                    name: prof.name,
                    avatarEmoji: prof.avatarEmoji,
                    hasPin: prof.hasPin,
                    isChild: prof.isChild,
                    subtitleLanguage: prof.subtitleLanguage,
                    subtitleMode: prof.subtitleMode,
                    showForcedSubtitles: prof.showForcedSubtitles,
                    preferredMetadataLanguage: newValue
                )
            }
            if changed {
                ResponseCache.shared.invalidateAllItemMetadata()
                #if os(tvOS)
                ItemDetailCache.shared.clearAll()
                #endif
            }
        } catch {
            prefSaveState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            )
        }
    }

    // MARK: - Editor projection helpers

    private func projectActiveProfileIntoEditor() {
        let raw = activeProfile?.subtitleLanguage ?? ""
        editorSubtitleLanguage = raw.isEmpty ? PlaybackPrefSentinel.none : raw

        let mode = activeProfile?.subtitleMode ?? ""
        editorSubtitleMode = mode.isEmpty ? SubtitleMode.auto.rawValue : mode

        editorShowForcedSubtitles = (activeProfile?.showForcedSubtitles ?? true) ? "on" : "off"

        let metaLang = activeProfile?.preferredMetadataLanguage ?? ""
        editorPreferredMetadataLanguage = metaLang.isEmpty ? PlaybackPrefSentinel.none : metaLang
    }

    /// `__none__` sentinel maps to the empty string the server expects
    /// to mean "no subtitle preference / no subs".
    private func outboundSubtitleLanguage(_ value: String) -> String {
        value == PlaybackPrefSentinel.none ? "" : value
    }
}
#endif
