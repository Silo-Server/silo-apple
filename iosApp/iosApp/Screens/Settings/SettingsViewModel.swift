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

    // Playback preferences (server-backed for this device/profile). Each one
    // reads and writes ``PlayerSettings`` directly. It is observable, so the
    // screens follow a reset, a refresh or an in-player change without a copy.

    /// The selected shared preset's id, or nil when the stored pair is a
    /// combination no preset covers. The picker shows ``preferredQualityLabel``
    /// in that case rather than snapping to a nearby preset, which would show
    /// the user a choice they did not make.
    var preferredQualityPresetId: String? { PlayerSettings.shared.currentQualityPreset?.id }
    /// A label for whatever pair is stored, preset or not.
    var preferredQualityLabel: String { PlayerSettings.shared.preferredQualityLabel }

    var preferredAudioLanguage: String {
        get { PlayerSettings.shared.audioLanguage }
        set { PlayerSettings.shared.setAudioLanguage(newValue) }
    }

    var autoPlayNext: Bool {
        get { PlayerSettings.shared.autoPlayNextEpisode }
        set { PlayerSettings.shared.setAutoPlayNextEpisode(newValue) }
    }

    var nextUpPromptSeconds: Int {
        get { PlayerSettings.shared.nextUpPromptSeconds }
        set { PlayerSettings.shared.setNextUpPromptSeconds(newValue) }
    }

    var introSkipMode: IntroSkipMode {
        get { PlayerSettings.shared.introSkipMode }
        set { PlayerSettings.shared.setIntroSkipMode(newValue) }
    }

    var skipCredits: Bool {
        get { PlayerSettings.shared.autoSkipCredits }
        set { PlayerSettings.shared.setAutoSkipCredits(newValue) }
    }

    var dolbyVisionEnabled: Bool {
        get { PlayerSettings.shared.dolbyVisionEnabled }
        set { PlayerSettings.shared.setDolbyVisionEnabled(newValue) }
    }

    var seekCacheEnabled: Bool {
        get { PlayerSettings.shared.seekCacheEnabled }
        set { PlayerSettings.shared.setSeekCacheEnabled(newValue) }
    }

    /// Local — it describes this device's audio sink, not the profile.
    var losslessAudioEnabled: Bool {
        get { PlayerSettings.shared.losslessAudioEnabled }
        set { PlayerSettings.shared.setLosslessAudioEnabled(newValue) }
    }

    #if !os(tvOS)
    /// Local — it is a habit of this device, not of the profile.
    var backgroundPlaybackEnabled: Bool {
        get { PlayerSettings.shared.backgroundPlaybackEnabled }
        set { PlayerSettings.shared.setBackgroundPlaybackEnabled(newValue) }
    }
    #endif

    /// Local — it spends this device's temporary storage, not the profile's.
    var bufferAhead: BufferAheadMode {
        get { PlayerSettings.shared.bufferAhead }
        set { PlayerSettings.shared.setBufferAhead(newValue) }
    }

    /// Local — it describes this device's GPU, not the profile.
    var deinterlaceMode: DeinterlacePreference {
        get { PlayerSettings.shared.deinterlaceMode }
        set { PlayerSettings.shared.setDeinterlaceMode(newValue) }
    }

    /// Local, for the same reason as ``deinterlaceMode``.
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference {
        get { PlayerSettings.shared.deinterlaceFieldRate }
        set { PlayerSettings.shared.setDeinterlaceFieldRate(newValue) }
    }

    /// Local — what this device plays into is a fact about its room.
    var trueHDAtmosEnabled: Bool {
        get { PlayerSettings.shared.trueHDAtmosEnabled }
        set { PlayerSettings.shared.setTrueHDAtmosEnabled(newValue) }
    }

    // Subtitle styling (local — applies to renderer overrides, not the
    // language/behavior selection that lives server-side). Changed through
    // the subtitle setters below.
    var subtitleAppearance: SubtitleAppearance { PlayerSettings.shared.subtitleAppearance }
    var subtitleUsesDeviceAppearanceOverride: Bool {
        PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }
    var subtitleMatchesSystemAppearance: Bool {
        PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

    /// What the player will actually render with: system captions, the
    /// device override, or the inherited server appearance.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        PlayerSettings.shared.effectiveSubtitleAppearance
    }

    /// False only when the server is known to predate subtitle text opacity.
    var offersSubtitleTextOpacity: Bool {
        PlayerSettings.shared.offersSubtitleTextOpacity
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
    #else
    /// Account card title. Tapping the card switches profiles, so with no
    /// name to show it says that instead.
    var displayName: String {
        if let name = activeProfile?.name, !name.isEmpty {
            return name
        }
        if let username = userInfo?.username, !username.isEmpty {
            return username
        }
        return "Switch Profile"
    }

    /// Account card subtitle: the username when the title is not already
    /// showing it, and the server host.
    var accountSubtitleLine: String {
        let host = serverHost
        let username = userInfo?.username
        switch (username, host) {
        case let (user?, host?) where !user.isEmpty && user != displayName:
            return "\(user) · \(host)"
        case let (_, host?):
            return host
        case let (user?, _) where !user.isEmpty && user != displayName:
            return user
        default:
            return "Tap to switch profile"
        }
    }

    private var serverHost: String? {
        guard let url = URL(string: serverUrl), let host = url.host else {
            return serverUrl.isEmpty ? nil : serverUrl
        }
        return host
    }

    /// The Subtitles row's value: the profile's subtitle language.
    var subtitleLanguageName: String {
        let tag = prefs.subtitleLanguage
        if tag == PlaybackPrefSentinel.none || tag.isEmpty { return "None" }
        return PlaybackLanguageOption.label(forCode: tag)
    }

    /// The app version, with the build number when it adds anything.
    static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String,
              !build.isEmpty,
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }()
    #endif

    /// Main-actor isolated: it publishes into observable state the settings
    /// views are already rendering, and seeds the profile editor, which is
    /// itself main-actor bound.
    @MainActor
    func loadSettings() async {
        prefs.bindProfile(id: AuthService.shared.profileId)
        await PlayerSettings.shared.refreshFromServer()

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
    func setQualityPreset(_ presetId: String) {
        guard let preset = SiloQualityPresets.preset(id: presetId) else { return }
        PlayerSettings.shared.setQualityPreset(preset)
    }

    // MARK: Held and refused playback changes

    /// A device playback change ran out of automatic retries and is held on
    /// this device.
    var hasHeldPlaybackChanges: Bool { !PlayerSettings.shared.heldDeviceSettingKeys.isEmpty }

    /// The server definitively refused a device playback change.
    var playbackChangeWasRejected: Bool { PlayerSettings.shared.rejectedDeviceSettingChange }

    static let rejectedPlaybackChangeMessage =
        "The server didn't accept a change to this device's playback settings, so it wasn't saved."

    /// The held keys a "Discard Held Change" could not discard because the
    /// server was unreachable. The footer says so only while exactly these
    /// keys are still held.
    private var undiscardedHeldPlaybackKeys: [SettingKey]?

    /// The footer for the held playback change rows.
    var heldPlaybackChangesMessage: String {
        let held = PlayerSettings.shared.heldDeviceSettingKeys
        guard !held.isEmpty, undiscardedHeldPlaybackKeys == held else {
            return HeldSettingChange.message
        }
        return HeldSettingChange.discardNeedsServerMessage
    }

    @MainActor
    func retryHeldPlaybackChanges() async {
        undiscardedHeldPlaybackKeys = nil
        await PlayerSettings.shared.retryHeldDeviceSettingChanges()
    }

    @MainActor
    func discardHeldPlaybackChanges() async {
        let held = PlayerSettings.shared.heldDeviceSettingKeys
        let discarded = await PlayerSettings.shared.discardHeldDeviceSettingChanges()
        undiscardedHeldPlaybackKeys = discarded ? nil : held
    }

    /// Clears the notice and repaints what the server holds.
    @MainActor
    func acknowledgeRejectedPlaybackChange() async {
        PlayerSettings.shared.dismissDeviceSettingRejection()
        await PlayerSettings.shared.refreshFromServer()
    }

    @MainActor
    func resetPlaybackDeviceSettings() async {
        await PlayerSettings.shared.resetAllDeviceSettings()
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await PlayerSettings.shared.setSubtitleAppearance(appearance)
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        await PlayerSettings.shared.setSubtitleDeviceOverrideEnabled(enabled)
    }

    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) {
        PlayerSettings.shared.setSubtitleMatchesSystemAppearance(enabled)
    }
}
