#if os(tvOS)
import Foundation

/// State container for the tvOS settings screen.
///
/// Local-only fields (preferred quality, auto-play, subtitle size) live
/// in `UserDefaults`. The spoken-language choice and the
/// subtitle-language / behavior / forced-subs trio are profile-wide on
/// the server and persisted via
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
    var autoPlayNext: Bool = PlayerSettings.shared.autoPlayNextEpisode
    var nextUpPromptSeconds: Int = PlayerSettings.shared.nextUpPromptSeconds
    var skipIntros: Bool = PlayerSettings.shared.autoSkipIntro
    var skipCredits: Bool = PlayerSettings.shared.autoSkipCredits
    var dolbyVisionEnabled: Bool = PlayerSettings.shared.dolbyVisionEnabled
    var preferProfile7HDR10Fallback: Bool = PlayerSettings.shared.preferProfile7HDR10Fallback
    var seekCacheEnabled: Bool = PlayerSettings.shared.seekCacheEnabled

    // Subtitle styling (local — applies to renderer overrides, not the
    // language/behavior selection that lives server-side).
    var subtitleSize: String = "medium"
    var subtitleAppearance: SubtitleAppearance = PlayerSettings.shared.subtitleAppearance
    var subtitleUsesDeviceAppearanceOverride: Bool = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    var subtitleMatchesSystemAppearance: Bool = PlayerSettings.shared.subtitleMatchesSystemAppearance

    /// What the player will actually render with: system captions, the
    /// device override, or the inherited server appearance.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        PlayerSettings.shared.effectiveSubtitleAppearance
    }

    // Server-backed profile prefs editor. Each editor field is either
    // the `PlaybackPrefSentinel.none` sentinel ("__none__") or a concrete
    // value. We persist directly to the active profile via PUT /profiles/{id}.
    /// Preferred spoken (audio) language. Profile-wide, not per-device:
    /// the server resolves the initial audio track from the profile's
    /// `language` field, so this is the only value that actually reaches
    /// playback. `PlaybackPrefSentinel.none` maps to the empty string
    /// ("no preference") on the wire.
    var editorAudioLanguage: String = PlaybackPrefSentinel.none
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

    /// Save state for the three profile-backed writes, kept apart by which
    /// row produced them. A single shared field misattributes results, and
    /// worse here than on iOS: the rail switches panes live on focus, with no
    /// navigation, so a failed subtitle save would show under Audio Language
    /// the instant focus moved to Playback.
    var audioSaveState: PrefSaveState?
    var subtitleSaveState: PrefSaveState?
    var metadataSaveState: PrefSaveState?
    private var isSavingMetadataLanguage = false
    private var pendingMetadataLanguageValue: String?
    private var isSavingAudioLanguage = false
    private var pendingAudioLanguageValue: String?

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
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        dolbyVisionEnabled = PlayerSettings.shared.dolbyVisionEnabled
        preferProfile7HDR10Fallback = PlayerSettings.shared.preferProfile7HDR10Fallback
        seekCacheEnabled = PlayerSettings.shared.seekCacheEnabled
        subtitleSize = UserDefaults.standard.string(forKey: "subtitleSize") ?? "medium"
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance

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
    func setDolbyVisionEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setDolbyVisionEnabled(enabled)
        dolbyVisionEnabled = PlayerSettings.shared.dolbyVisionEnabled
    }

    @MainActor
    func setPreferProfile7HDR10Fallback(_ enabled: Bool) async {
        PlayerSettings.shared.setPreferProfile7HDR10Fallback(enabled)
        preferProfile7HDR10Fallback = PlayerSettings.shared.preferProfile7HDR10Fallback
    }

    @MainActor
    func setSeekCacheEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setSeekCacheEnabled(enabled)
        seekCacheEnabled = PlayerSettings.shared.seekCacheEnabled
    }

    @MainActor
    func resetPlaybackDeviceSettings() async {
        await PlayerSettings.shared.resetAllDeviceSettings()
        preferredQuality = PlayerSettings.shared.preferredQuality
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        dolbyVisionEnabled = PlayerSettings.shared.dolbyVisionEnabled
        preferProfile7HDR10Fallback = PlayerSettings.shared.preferProfile7HDR10Fallback
        seekCacheEnabled = PlayerSettings.shared.seekCacheEnabled
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await PlayerSettings.shared.setSubtitleAppearance(appearance)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        await PlayerSettings.shared.setSubtitleDeviceOverrideEnabled(enabled)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    @MainActor
    func resetSubtitleAppearance() async {
        await PlayerSettings.shared.setSubtitleAppearance(.default)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

    @MainActor
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) async {
        PlayerSettings.shared.setSubtitleMatchesSystemAppearance(enabled)
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

    /// Push the current editor state to the server as a profile patch.
    /// Triggered from the view's `onChange` handlers.
    @MainActor
    func saveProfilePrefs() async {
        guard let profileId = activeProfile?.id, !profileId.isEmpty else { return }

        subtitleSaveState = .saving

        let body = UpdateProfileBody(
            subtitleLanguage: outboundProfileLanguage(editorSubtitleLanguage),
            subtitleMode: editorSubtitleMode,
            showForcedSubtitles: editorShowForcedSubtitles == "on"
        )
        do {
            try await ContinuumAPI.shared.updateProfile(profileId: profileId, body: body)
            subtitleSaveState = .saved
            // Keep the detail-page track-ordering preference in sync.
            ProfilePrefsStore.shared.setPreferredSubtitleLanguage(body.subtitleLanguage)
            // Refresh the local profile snapshot so a re-load reflects
            // what we just wrote.
            if let prof = activeProfile {
                activeProfile = prof.with(subtitleLanguage: body.subtitleLanguage, subtitleMode: body.subtitleMode, showForcedSubtitles: body.showForcedSubtitles)
            }
        } catch {
            subtitleSaveState = .failed(
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
        guard activeProfile?.id.isEmpty == false else { return }
        pendingMetadataLanguageValue = outboundProfileLanguage(editorPreferredMetadataLanguage)
        guard !isSavingMetadataLanguage else { return }

        isSavingMetadataLanguage = true
        defer { isSavingMetadataLanguage = false }

        while let newValue = pendingMetadataLanguageValue {
            pendingMetadataLanguageValue = nil
            await saveMetadataLanguageValue(newValue)
        }
    }

    @MainActor
    private func saveMetadataLanguageValue(_ newValue: String) async {
        guard let profileId = activeProfile?.id, !profileId.isEmpty else { return }
        let oldValue = activeProfile?.preferredMetadataLanguage ?? ""
        guard newValue != oldValue else { return }

        metadataSaveState = .saving

        let body = UpdateProfileBody(preferredMetadataLanguage: newValue)
        do {
            try await ContinuumAPI.shared.updateProfile(profileId: profileId, body: body)
            guard activeProfile?.id == profileId else { return }
            // Record the write before deciding whether to report, so a queued
            // follow-up compares against the value the server now holds.
            if let prof = activeProfile {
                activeProfile = prof.with(preferredMetadataLanguage: newValue)
            }
            // Reported unconditionally: the write landed, and a still-queued
            // value will overwrite this message when it lands in turn. Gating
            // on "no newer value pending" strands the footer on "Saving…"
            // whenever the user re-picks the value already being written,
            // because the queued pass then no-ops on the equality guard above.
            metadataSaveState = .saved
            ResponseCache.shared.invalidateAllItemMetadata()
            ItemDetailCache.shared.clearAll()
        } catch {
            guard activeProfile?.id == profileId else { return }
            metadataSaveState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            )
        }
    }

    /// Persist the preferred spoken (audio) language as a profile patch.
    ///
    /// This is deliberately a profile field rather than a per-device one:
    /// the server picks the initial audio track from `profile.language`
    /// and reports the result as `effective_audio_track_index`, which the
    /// player forwards at session start. A device-scoped value would
    /// never be read by anything.
    @MainActor
    func saveAudioLanguage() async {
        // Serialized the same way as saveMetadataLanguage: the picker fires on
        // every change, so two quick selections would otherwise race across the
        // await and leave the server holding the first value while the row
        // shows the second.
        guard activeProfile?.id.isEmpty == false else {
            audioSaveState = .failed("No active profile to save to.")
            return
        }
        pendingAudioLanguageValue = outboundProfileLanguage(editorAudioLanguage)
        guard !isSavingAudioLanguage else { return }

        isSavingAudioLanguage = true
        defer { isSavingAudioLanguage = false }

        while let newValue = pendingAudioLanguageValue {
            pendingAudioLanguageValue = nil
            await saveAudioLanguageValue(newValue)
        }
    }

    @MainActor
    private func saveAudioLanguageValue(_ newValue: String) async {
        guard let profileId = activeProfile?.id, !profileId.isEmpty else { return }
        guard newValue != (activeProfile?.language ?? "") else { return }

        audioSaveState = .saving

        do {
            try await ContinuumAPI.shared.updateProfile(
                profileId: profileId,
                body: UpdateProfileBody(language: newValue)
            )
            guard activeProfile?.id == profileId else { return }
            // The write landed. Record it even if the user has since moved on
            // to another value: the queue above will save that one next, and
            // leaving `activeProfile` stale would make the follow-up save
            // compare against the wrong baseline and skip itself.
            if let prof = activeProfile {
                activeProfile = prof.with(language: newValue)
            }
            // Reported unconditionally rather than only when nothing is queued.
            // Suppressing it stranded the footer on "Saving…" forever when the
            // user re-selected the value already in flight: the queued pass then
            // matches `activeProfile.language` and returns at the guard above,
            // so nothing ever reached `.saved` — and the caches never flushed,
            // leaving detail screens on the old track. A queued value that
            // differs will overwrite this message when it lands.
            audioSaveState = .saved
            // Detail screens render the server-resolved audio track out of
            // the cached item payloads, which have no TTL. Drop them so the
            // new selection shows up without a relaunch. Playback itself
            // always refetches `/watch`, so this is display consistency
            // only — it is not what makes the setting take effect.
            ResponseCache.shared.invalidateAllItemMetadata()
            ItemDetailCache.shared.clearAll()
        } catch {
            guard activeProfile?.id == profileId else { return }
            // Reported even when a newer value is already queued: the user needs
            // to know this save failed, and the queued one will overwrite the
            // message if it succeeds.
            audioSaveState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            )
        }
    }

    // MARK: - Editor projection helpers

    private func projectActiveProfileIntoEditor() {
        let audioLang = activeProfile?.language ?? ""
        editorAudioLanguage = audioLang.isEmpty ? PlaybackPrefSentinel.none : audioLang

        let raw = activeProfile?.subtitleLanguage ?? ""
        editorSubtitleLanguage = raw.isEmpty ? PlaybackPrefSentinel.none : raw

        let mode = activeProfile?.subtitleMode ?? ""
        editorSubtitleMode = mode.isEmpty ? SubtitleMode.auto.rawValue : mode

        editorShowForcedSubtitles = (activeProfile?.showForcedSubtitles ?? true) ? "on" : "off"

        let metaLang = activeProfile?.preferredMetadataLanguage ?? ""
        editorPreferredMetadataLanguage = metaLang.isEmpty ? PlaybackPrefSentinel.none : metaLang
    }

    /// `__none__` sentinel maps to the empty string the server expects
    /// to mean "no preference" for any of the profile language fields
    /// (spoken, subtitle, metadata).
    private func outboundProfileLanguage(_ value: String) -> String {
        value == PlaybackPrefSentinel.none ? "" : value
    }
}
#endif
