import Foundation

/// State container for the Apple settings screens.
///
/// Two scopes meet here. Playback choices that belong to *this device* (quality,
/// skip behaviour, sync offsets) go through ``PlayerSettings`` at
/// `profile_device`. The subtitle-language / behavior / forced trio and the
/// metadata language are the *profile's* choices and go through
/// ``ProfileSettingsWriter`` at `profile` — the same keys, scope and wire
/// values the web and Android clients use, so an edit made on any of them reads
/// back the same on the others.
@Observable
final class SettingsViewModel {
    var userInfo: UserInfo?
    var activeProfile: UserProfile?
    var isLoading = false
    var error: String?

    /// Active server URL. Reads through the registry so a server switch
    /// reflects here without a reload. Used by the account-card subtitle
    /// to derive a short host label.
    var serverUrl: String { ServerRegistry.shared.activeServerUrl }

    /// Friendly label for the active server, shown in the Settings
    /// `Server` row. User override → server-advertised name → URL.
    var serverDisplayName: String {
        #if os(tvOS)
        ServerRegistry.shared.activeServer?.displayName ?? ""
        #else
        ServerRegistry.shared.activeServer?.displayName ?? "Not configured"
        #endif
    }

    // Playback preferences (server-backed for this device/profile).

    /// The selected shared preset's id, or nil when the stored pair is a
    /// combination no preset covers. The picker shows ``preferredQualityLabel``
    /// in that case rather than snapping to a nearby preset, which would show
    /// the user a choice they did not make.
    var preferredQualityPresetId: String? = PlayerSettings.shared.currentQualityPreset?.id
    /// A label for whatever pair is stored, preset or not.
    var preferredQualityLabel: String = PlayerSettings.shared.preferredQualityLabel
    var preferredAudioLanguage: String = PlayerSettings.shared.audioLanguage
    var autoPlayNext: Bool = PlayerSettings.shared.autoPlayNextEpisode
    var nextUpPromptSeconds: Int = PlayerSettings.shared.nextUpPromptSeconds
    var skipIntros: Bool = PlayerSettings.shared.autoSkipIntro
    var skipCredits: Bool = PlayerSettings.shared.autoSkipCredits
    var dolbyVisionEnabled: Bool = PlayerSettings.shared.dolbyVisionEnabled
    var seekCacheEnabled: Bool = PlayerSettings.shared.seekCacheEnabled
    /// Local — it describes this device's audio sink, not the profile.
    var losslessAudioEnabled: Bool = PlayerSettings.shared.losslessAudioEnabled
    #if !os(tvOS)
    /// Local — it is a habit of this device, not of the profile.
    var backgroundPlaybackEnabled: Bool = PlayerSettings.shared.backgroundPlaybackEnabled
    #endif
    /// Local — it spends this device's temporary storage, not the profile's.
    var bufferAhead: BufferAheadMode = PlayerSettings.shared.bufferAhead
    /// Local — it describes this device's GPU, not the profile.
    var deinterlaceMode: DeinterlacePreference = PlayerSettings.shared.deinterlaceMode
    /// Local, for the same reason as ``deinterlaceMode``.
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference =
        PlayerSettings.shared.deinterlaceFieldRate

    // Subtitle styling (local — applies to renderer overrides, not the
    // language/behavior selection that lives server-side).
    var subtitleAppearance: SubtitleAppearance = PlayerSettings.shared.subtitleAppearance
    var subtitleUsesDeviceAppearanceOverride: Bool = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    var subtitleMatchesSystemAppearance: Bool = PlayerSettings.shared.subtitleMatchesSystemAppearance

    /// What the player will actually render with: system captions, the
    /// device override, or the inherited server appearance.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        PlayerSettings.shared.effectiveSubtitleAppearance
    }

    /// Profile-scoped preferences written through the canonical settings API.
    let prefs = ProfilePrefsEditor()

    var audioLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .playbackAudioLanguage,
            currentValue: preferredAudioLanguage,
            runtimeValues: PlayerSettings.shared.audioLanguageSuggestions
        )
    }

    var subtitleLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .playbackSubtitleLanguage,
            currentValue: prefs.subtitleLanguage,
            runtimeValues: prefs.subtitleLanguageSuggestions
        )
    }

    var metadataLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .catalogMetadataLanguage,
            currentValue: prefs.preferredMetadataLanguage,
            runtimeValues: prefs.metadataLanguageSuggestions
        )
    }

    #if os(tvOS)
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

    /// Server-resolved avatar image URL, preferred over ``profileAvatar``.
    var profileAvatarImageUrl: String? {
        activeProfile?.avatarImageUrl
    }
    #endif

    /// Main-actor isolated: it publishes into observable state the settings
    /// views are already rendering, and seeds the profile editor, which is
    /// itself main-actor bound.
    @MainActor
    func loadSettings() async {
        prefs.bindProfile(id: AuthService.shared.profileId)
        await PlayerSettings.shared.refreshFromServer()
        adoptQualityFromPlayerSettings()
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        dolbyVisionEnabled = PlayerSettings.shared.dolbyVisionEnabled
        seekCacheEnabled = PlayerSettings.shared.seekCacheEnabled
        losslessAudioEnabled = PlayerSettings.shared.losslessAudioEnabled
        #if !os(tvOS)
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
        #endif
        bufferAhead = PlayerSettings.shared.bufferAhead
        deinterlaceMode = PlayerSettings.shared.deinterlaceMode
        deinterlaceFieldRate = PlayerSettings.shared.deinterlaceFieldRate
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance

        async let user: UserInfo? = try? SiloAPI.shared.currentUser()
        async let profiles: [UserProfile] = (try? AuthService.shared.getProfiles()) ?? []

        let (loadedUser, loadedProfiles) = await (user, profiles)
        userInfo = loadedUser

        let activeProfileId = AuthService.shared.profileId
        if let activeProfileId {
            activeProfile = loadedProfiles.first(where: { $0.id == activeProfileId })
        } else {
            activeProfile = nil
        }

        // Paint the profile's own values first, then let the batched effective
        // read replace them: it is the only source that accounts for a library,
        // series or device override winning over the profile row.
        prefs.bindProfile(id: activeProfileId)
        prefs.seed(from: activeProfile)
        await prefs.load()
    }

    /// Apply a shared quality preset, which stores the contract's two axes.
    @MainActor
    func setQualityPreset(_ presetId: String) async {
        guard let preset = SiloQualityPresets.preset(id: presetId) else { return }
        PlayerSettings.shared.setQualityPreset(preset)
        adoptQualityFromPlayerSettings()
    }

    private func adoptQualityFromPlayerSettings() {
        preferredQualityPresetId = PlayerSettings.shared.currentQualityPreset?.id
        preferredQualityLabel = PlayerSettings.shared.preferredQualityLabel
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
    func setDolbyVisionEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setDolbyVisionEnabled(enabled)
        dolbyVisionEnabled = PlayerSettings.shared.dolbyVisionEnabled
    }

    @MainActor
    func setSeekCacheEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setSeekCacheEnabled(enabled)
        seekCacheEnabled = PlayerSettings.shared.seekCacheEnabled
    }

    @MainActor
    func setLosslessAudioEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setLosslessAudioEnabled(enabled)
        losslessAudioEnabled = PlayerSettings.shared.losslessAudioEnabled
    }

    #if !os(tvOS)
    @MainActor
    func setBackgroundPlaybackEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setBackgroundPlaybackEnabled(enabled)
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
    }
    #endif

    @MainActor
    func setBufferAhead(_ mode: BufferAheadMode) async {
        PlayerSettings.shared.setBufferAhead(mode)
        bufferAhead = PlayerSettings.shared.bufferAhead
    }

    @MainActor
    func setDeinterlaceMode(_ mode: DeinterlacePreference) async {
        PlayerSettings.shared.setDeinterlaceMode(mode)
        deinterlaceMode = PlayerSettings.shared.deinterlaceMode
    }

    @MainActor
    func setDeinterlaceFieldRate(_ rate: DeinterlaceFieldRatePreference) async {
        PlayerSettings.shared.setDeinterlaceFieldRate(rate)
        deinterlaceFieldRate = PlayerSettings.shared.deinterlaceFieldRate
    }

    @MainActor
    func resetPlaybackDeviceSettings() async {
        await PlayerSettings.shared.resetAllDeviceSettings()
        adoptQualityFromPlayerSettings()
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        dolbyVisionEnabled = PlayerSettings.shared.dolbyVisionEnabled
        seekCacheEnabled = PlayerSettings.shared.seekCacheEnabled
        // The device-local rows are restored by the same reset, so the screen
        // has to re-adopt them too or it keeps showing the old choice.
        losslessAudioEnabled = PlayerSettings.shared.losslessAudioEnabled
        #if !os(tvOS)
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
        #endif
        bufferAhead = PlayerSettings.shared.bufferAhead
        deinterlaceMode = PlayerSettings.shared.deinterlaceMode
        deinterlaceFieldRate = PlayerSettings.shared.deinterlaceFieldRate
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
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) async {
        PlayerSettings.shared.setSubtitleMatchesSystemAppearance(enabled)
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }
}
