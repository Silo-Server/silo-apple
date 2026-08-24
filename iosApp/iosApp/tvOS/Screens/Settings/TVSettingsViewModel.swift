#if os(tvOS)
import Foundation

/// State container for the tvOS settings screen. Twin of the iOS
/// ``SettingsViewModel``.
///
/// Two scopes meet here. Playback choices that belong to *this Apple TV*
/// (quality, skip behaviour, sync offsets) go through ``PlayerSettings`` at
/// `profile_device`. The subtitle-language / behavior / forced trio and the
/// metadata language are the *profile's* choices and go through
/// ``ProfileSettingsWriter`` at `profile`. The server resolves series →
/// library → device → profile at playback time, so a profile-level edit
/// applies everywhere unless a narrower override exists.
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
    /// Local — it describes this Apple TV's audio sink, not the profile.
    var losslessAudioEnabled: Bool = PlayerSettings.shared.losslessAudioEnabled
    /// Local — it spends this Apple TV's temporary storage, not the profile's.
    var bufferAhead: BufferAheadMode = PlayerSettings.shared.bufferAhead
    /// Local — it describes this device's GPU, not the profile.
    var deinterlaceMode: DeinterlacePreference = PlayerSettings.shared.deinterlaceMode
    /// Local, for the same reason as ``deinterlaceMode``.
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference =
        PlayerSettings.shared.deinterlaceFieldRate

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

    /// Profile-scoped preferences, written at `scope=profile` through the
    /// canonical settings API. Shared with the iOS screen so the two cannot
    /// drift; the properties below forward to it so this type's existing API
    /// is unchanged for its views.
    let prefs = ProfilePrefsEditor()

    typealias PrefSaveState = ProfilePrefsEditor.PrefSaveState

    var editorSubtitleLanguage: String {
        get { prefs.subtitleLanguage }
        set { prefs.subtitleLanguage = newValue }
    }

    var editorSubtitleMode: String {
        get { prefs.subtitleMode }
        set { prefs.subtitleMode = newValue }
    }

    /// Tri-state bound as "on" / "off".
    var editorShowForcedSubtitles: String {
        get { prefs.showForcedSubtitles }
        set { prefs.showForcedSubtitles = newValue }
    }

    /// Preferred metadata language. `PlaybackPrefSentinel.none` is the
    /// contract's null ("inherit the library default") on the wire.
    /// Gated on `AICapabilities.shared.metadataEnabled` at the row.
    var editorPreferredMetadataLanguage: String {
        get { prefs.preferredMetadataLanguage }
        set { prefs.preferredMetadataLanguage = newValue }
    }

    /// Surfaces the most recent server save state. Settings UI shows a
    /// transient message when prefSaveState != nil.
    var prefSaveState: PrefSaveState? { prefs.saveState }

    /// True when the connected server has no canonical settings API, so the
    /// server-backed controls cannot work and the screens say why.
    var settingsServerUpgradeRequired: Bool { prefs.serverUpgradeRequired }

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
            currentValue: editorSubtitleLanguage,
            runtimeValues: prefs.subtitleLanguageSuggestions
        )
    }

    var metadataLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .catalogMetadataLanguage,
            currentValue: editorPreferredMetadataLanguage,
            runtimeValues: prefs.metadataLanguageSuggestions
        )
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

    /// Server-resolved avatar image URL, preferred over ``profileAvatar``.
    var profileAvatarImageUrl: String? {
        activeProfile?.avatarImageUrl
    }

    // MARK: - Load / save

    /// Main-actor isolated: it publishes into observable state the settings
    /// views are already rendering, and seeds the profile editor, which is
    /// itself main-actor bound.
    @MainActor
    func load() async {
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
        bufferAhead = PlayerSettings.shared.bufferAhead
        deinterlaceMode = PlayerSettings.shared.deinterlaceMode
        deinterlaceFieldRate = PlayerSettings.shared.deinterlaceFieldRate
        subtitleSize = UserDefaults.standard.string(forKey: "subtitleSize") ?? "medium"
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance

        async let user: UserInfo? = try? ContinuumAPI.shared.get("/api/v1/user/me")
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

    func saveSubtitleSizePreference() {
        UserDefaults.standard.set(subtitleSize, forKey: "subtitleSize")
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

    /// Persist the subtitle trio at `profile` scope.
    /// Triggered from the view's `onChange` handlers.
    @MainActor
    func saveProfilePrefs() async {
        await prefs.saveSubtitlePrefs()
    }

    /// Persist the preferred metadata language at `profile` scope.
    /// Triggered from the view's `onChange` handler.
    @MainActor
    func saveMetadataLanguage() async {
        await prefs.saveMetadataLanguage()
    }
}
#endif
