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

    /// A summary of the quality pair, for the Playback row on the overview.
    var preferredQualityLabel: String { PlayerSettings.shared.preferredQualityLabel }

    /// The Resolution picker's value.
    var qualityResolutionLabel: String {
        SiloQualityPresets.resolutionLabel(PlayerSettings.shared.preferredQualityResolution)
    }

    /// The Maximum Bitrate picker's value.
    var maxBitrateLabel: String {
        SiloQualityPresets.bitrateLabel(PlayerSettings.shared.maxBitrateKbps)
    }

    /// The Maximum Bitrate picker's caps, including a stored cap no choice
    /// covers so it stays visible and selected.
    var maxBitrateChoicesKbps: [Int] {
        SiloQualityPresets.bitrateChoices(including: PlayerSettings.shared.maxBitrateKbps)
    }

    /// What the two quality pickers mean for playback.
    var qualityFooterText: String {
        let resolution = PlayerSettings.shared.preferredQualityResolution
        var text = resolution == SiloQualityPresets.resolutionAuto
            ? "Plays the original file whenever your device and connection can handle it."
            : "Plays the original file up to \(SiloQualityPresets.resolutionLabel(resolution)). Larger files are converted."
        if PlayerSettings.shared.maxBitrateKbps != nil {
            text += " Files above this bitrate are converted to fit."
        }
        return text
    }

    /// The selected cellular preset's id, or nil for a stored pair no preset
    /// covers; the picker then lists ``cellularQualityLabel`` on its own.
    var cellularQualityPresetId: String? { PlayerSettings.shared.currentCellularQualityPreset?.id }
    var cellularQualityLabel: String { PlayerSettings.shared.cellularQualityLabel }
    static let cellularQualityFooterText = "Used on mobile data and metered networks, such as a phone hotspot."

    var bufferingQualityMode: BufferingQualityMode {
        get { PlayerSettings.shared.bufferingQualityMode }
        set { PlayerSettings.shared.setBufferingQualityMode(newValue) }
    }

    /// Hidden where the server's settings don't define
    /// `playback.buffering_quality_mode`; the player then plays `always`.
    var showsBufferingQualityMode: Bool { !PlayerSettings.shared.serverLacksBufferingQualityMode }

    /// The manifest's label and description for `playback.buffering_quality_mode`.
    static let bufferingQualityTitle = "Lower quality when buffering"
    static let bufferingQualityDescription =
        "What Silo does on Auto when playback keeps buffering. Silo always asks before lowering a quality you picked."

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

    /// The player settings the HDR rows edit. Injectable so a test can drive
    /// the screen's bindings against an isolated instance.
    let playerSettings: PlayerSettings

    init(playerSettings: PlayerSettings = .shared) {
        self.playerSettings = playerSettings
    }

    var hdrEnabled: Bool {
        get { playerSettings.hdrEnabled }
        set { playerSettings.setHDREnabled(newValue) }
    }

    /// What turning HDR off does, stated as narrowly as it is true. The
    /// setting only changes what this device tells the server its screen can
    /// show: a video the server converts is then sent as SDR, but an original
    /// file the player opens itself still plays in its own dynamic range, and
    /// on Apple TV the pinned engine still switches the TV to HDR for it when
    /// Match Content is on (it reads the system flag, not this setting).
    /// Dolby Vision is never offered to the server while HDR is off.
    static var hdrFooterText: String {
        #if os(tvOS)
        let original = " Videos that play from the original file can still play in HDR, and the TV can still switch to HDR for them."
        #else
        let original = " Videos that play from the original file can still play in HDR."
        #endif
        return "With HDR off, videos the server converts for this device are sent in SDR, without Dolby Vision."
            + original
    }

    /// Dolby Vision is only offered while HDR is on, so its row reads Off and
    /// cannot be changed while HDR is off. The stored choice is kept.
    var dolbyVisionEnabled: Bool {
        get { playerSettings.hdrEnabled && playerSettings.dolbyVisionEnabled }
        set { playerSettings.setDolbyVisionEnabled(newValue) }
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

    /// Apply a shared preset to the cellular pair.
    func setCellularQualityPreset(_ presetId: String) {
        guard let preset = SiloQualityPresets.preset(id: presetId) else { return }
        PlayerSettings.shared.setCellularQualityPreset(preset)
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

    // MARK: Learned connection limit

    /// The limit the server learned for this device on its current
    /// connection, shown under the buffering row with a Reset action. Nil
    /// hides the row: a server without `buffering_quality_v1`, no limit, or a
    /// failed read.
    private(set) var learnedConnectionLimit: APIv2PlaybackConnection.LearnedLimit?

    /// Set when Reset failed, until the next Reset or load.
    private(set) var learnedLimitResetError: String?
    @ObservationIgnored private var connectionReadGeneration: UInt64 = 0

    static let learnedLimitResetFailedMessage = "Couldn't reset the limit. Try again."

    /// Nil in `never`, whose starts ignore the limit.
    var learnedConnectionLimitText: String? {
        guard bufferingQualityMode != .never else { return nil }
        return learnedConnectionLimit.map { Self.learnedLimitText($0) }
    }

    /// "Limited to 44 Mbps after buffering on Oct 17": the rate as Settings
    /// shows rates, and the date of the most recent lowering, as month and
    /// day in the viewer's locale.
    static func learnedLimitText(
        _ limit: APIv2PlaybackConnection.LearnedLimit,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
        style.timeZone = timeZone
        return "Limited to \(connectionRateText(kbps: limit.kbps)) after buffering on \(limit.observedAt.formatted(style))"
    }

    /// Reads `GET /api/v2/playback/connection` for the learned-limit row and,
    /// with `connection_speed_v1`, the Connection group.
    @MainActor
    func loadPlaybackConnection() async {
        learnedLimitResetError = nil
        // Only the latest read publishes: a cancelled one, or one a newer
        // read overtook, changes nothing.
        connectionReadGeneration &+= 1
        let generation = connectionReadGeneration
        func isLatest() -> Bool { generation == connectionReadGeneration && !Task.isCancelled }
        // Fresh, so a feature the server adds or withdraws while the app runs
        // shows or hides its rows on the next visit.
        let capability = try? await PlaybackV3CapabilityGate.shared.requireNeutralProtocolV3(fresh: true)
        guard isLatest() else { return }
        let showsLearnedLimit = capability?.bufferingQuality ?? false
        showsConnectionGroup = capability?.connectionSpeed ?? false
        let auth = showsLearnedLimit || showsConnectionGroup
            ? await TokenStore.shared.captureOrdinaryRequestAuth()
            : nil
        let connection: APIv2PlaybackConnection? = if let auth {
            try? await SiloAPI.shared.apiV2Client.playbackConnection(auth: auth)
        } else {
            nil
        }
        guard isLatest() else { return }
        guard let connection else {
            learnedConnectionLimit = nil
            connectionProbe = nil
            connectionSample = nil
            autoBudgetKbps = nil
            return
        }
        learnedConnectionLimit = showsLearnedLimit ? connection.learnedLimit : nil
        connectionProbe = showsConnectionGroup ? connection.probe : nil
        connectionSample = showsConnectionGroup ? connection.playbackSample : nil
        autoBudgetKbps = showsConnectionGroup ? connection.autoBudgetKbps : nil
    }

    @MainActor
    func resetLearnedConnectionLimit() async {
        learnedLimitResetError = nil
        do {
            guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth() else {
                throw HTTPError.requestIdentityChanged
            }
            try await SiloAPI.shared.apiV2Client.resetPlaybackLearnedLimit(auth: auth)
            learnedConnectionLimit = nil
            // The server's Auto budget counted the limit. Not awaited, so the
            // caller can move focus off the Reset row before it can vanish.
            if showsConnectionGroup { Task { await loadPlaybackConnection() } }
        } catch {
            learnedLimitResetError = Self.learnedLimitResetFailedMessage
        }
    }

    // MARK: Connection speed

    /// The server advertises `connection_speed_v1`: Playback settings show a
    /// Connection group with the measured speed, **Test speed**, and the Auto
    /// budget.
    private(set) var showsConnectionGroup = false
    /// The server's latest probe for this device on this connection.
    private(set) var connectionProbe: APIv2PlaybackConnection.Probe?
    /// The server's playback sample for this device on this connection.
    private(set) var connectionSample: APIv2PlaybackConnection.PlaybackSample?
    /// `auto_budget_kbps`, computed by the server; nil hides the line.
    private(set) var autoBudgetKbps: Int?
    private(set) var isTestingConnectionSpeed = false
    /// The answer to the last **Test speed**, until the next one. "Try again
    /// in N seconds" clears itself once the N seconds have passed.
    private(set) var connectionSpeedMessage: String?
    @ObservationIgnored private var connectionSpeedMessageExpiry: Task<Void, Never>?
    /// When the measurement the server didn't save was taken. Settings keeps
    /// showing the server's reading rather than that one.
    @ObservationIgnored private var unsavedMeasurementAt: Date?

    static let connectionSectionTitle = "Connection"
    static let connectionSpeedTitle = "Connection speed"
    static let testSpeedAction = "Test speed"
    static let testingSpeedLabel = "Testing…"
    static let notMeasuredText = "Not measured yet"
    static let stopPlaybackToTestMessage = "Stop playback before testing, then try again."
    static let speedTestFailedMessage = "Couldn't measure the connection speed. Try again."
    /// The test measured, but the server did not store the result.
    static let speedTestNotSavedMessage = "Couldn't save the speed test result. Try again."

    /// The Connection speed row's line as of `now`: why speed tests are
    /// skipped on this network, which replaces the speed, or the speed.
    @MainActor
    func connectionSpeedLine(at now: Date) -> String {
        connectionSpeedSkippedText ?? connectionSpeedText(at: now)
    }

    /// "48 Mbps · measured 3 minutes ago on Wi-Fi", or "Faster than 115 Mbps
    /// · …" for a lower bound: the newer of the server's speed test and this
    /// device's own, unless the server didn't save this device's. Without
    /// one, the playback sample: "Faster than 51 Mbps · seen during playback
    /// 2 hours ago". Else "Not measured yet".
    @MainActor
    func connectionSpeedText(at now: Date) -> String {
        let own = BandwidthProbeScheduler.shared.probeReading
        let server = connectionProbe
        if let own, case .probe(let transport) = own.source, own.measuredAt != unsavedMeasurementAt,
           server.map({ own.measuredAt >= $0.measuredAt }) ?? true {
            return Self.connectionSpeedText(
                kbps: own.kbps, lowerBound: own.lowerBound, measuredAt: own.measuredAt, transport: transport, now: now
            )
        }
        if let server {
            return Self.connectionSpeedText(
                kbps: server.kbps, lowerBound: server.lowerBound, measuredAt: server.measuredAt,
                transport: server.transport, now: now
            )
        }
        if let sample = connectionSample {
            return Self.playbackSampleText(kbps: sample.kbps, measuredAt: sample.measuredAt, now: now)
        }
        return Self.notMeasuredText
    }

    /// Why speed tests are skipped on the network in use, or nil when they
    /// run. With a note, neither **Test speed** nor the budget shows.
    @MainActor
    var connectionSpeedSkippedText: String? {
        Self.connectionSpeedSkippedText(
            network: BandwidthProbeScheduler.shared.network,
            cellularQualityApplies: PlayerSettings.offersCellularQuality
        )
    }

    /// "Auto plays videos up to 35 Mbps without converting them." Nil in
    /// `never` while a limit is learned: the server's budget counts the
    /// limit, which that mode's starts ignore.
    @MainActor
    var autoBudgetText: String? {
        guard connectionSpeedSkippedText == nil, let autoBudgetKbps,
              bufferingQualityMode != .never || learnedConnectionLimit == nil else { return nil }
        return "Auto plays videos up to \(Self.connectionRateText(kbps: autoBudgetKbps)) without converting them."
    }

    /// **Test speed**: runs the probe now, reports it, then reads the
    /// connection again for the server's budget.
    @MainActor
    func testConnectionSpeed() async {
        guard !isTestingConnectionSpeed else { return }
        isTestingConnectionSpeed = true
        setConnectionSpeedMessage(nil)
        defer { isTestingConnectionSpeed = false }
        switch await BandwidthProbeScheduler.shared.runNow() {
        case .measured:
            unsavedMeasurementAt = nil
            await loadPlaybackConnection()
        case .notSaved(let measurement):
            unsavedMeasurementAt = measurement.reading.measuredAt
            setConnectionSpeedMessage(Self.speedTestNotSavedMessage)
            await loadPlaybackConnection()
        case .rateLimited(let seconds):
            setConnectionSpeedMessage(Self.tryAgainMessage(seconds: seconds), for: .seconds(seconds))
        case .playbackActive:
            setConnectionSpeedMessage(Self.stopPlaybackToTestMessage)
        case .metered:
            // The row already says speed tests are skipped here.
            break
        case .unavailable, .tooLittleData, .networkError, .offline, .notSupported, .interrupted:
            setConnectionSpeedMessage(Self.speedTestFailedMessage)
        }
    }

    /// "Try again in 12 seconds", "1 second" at one.
    static func tryAgainMessage(seconds: Int) -> String {
        "Try again in \(seconds) \(seconds == 1 ? "second" : "seconds")"
    }

    /// Shows `message`, for `lifetime` when one is given.
    @MainActor
    private func setConnectionSpeedMessage(_ message: String?, for lifetime: Duration? = nil) {
        connectionSpeedMessageExpiry?.cancel()
        connectionSpeedMessageExpiry = nil
        connectionSpeedMessage = message
        guard let lifetime else { return }
        connectionSpeedMessageExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.connectionSpeedMessage = nil
        }
    }

    /// "48 Mbps · measured 3 minutes ago on Wi-Fi", or "Faster than 115 Mbps ·
    /// measured …" for a lower bound.
    static func connectionSpeedText(
        kbps: Int, lowerBound: Bool = false, measuredAt: Date, transport: String, now: Date = Date()
    ) -> String {
        let network = switch transport {
        case "wifi": "Wi-Fi"
        case "ethernet": "Ethernet"
        case "cellular": "cellular"
        default: "this connection"
        }
        return "\(speedText(kbps: kbps, lowerBound: lowerBound)) · measured \(ageText(since: measuredAt, now: now)) on \(network)"
    }

    /// "Faster than 51 Mbps · seen during playback 2 hours ago": a playback
    /// sample, always a lower bound.
    static func playbackSampleText(kbps: Int, measuredAt: Date, now: Date = Date()) -> String {
        "\(speedText(kbps: kbps, lowerBound: true)) · seen during playback \(ageText(since: measuredAt, now: now))"
    }

    private static func speedText(kbps: Int, lowerBound: Bool) -> String {
        lowerBound ? "Faster than \(connectionRateText(kbps: kbps))" : connectionRateText(kbps: kbps)
    }

    /// Under a minute is "just now"; then whole minutes, hours and days,
    /// rounded down. A clock that reads before `date` counts as just now.
    private static func ageText(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case ..<1:
            return "just now"
        case ..<60:
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        case ..<(24 * 60):
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        default:
            let days = minutes / (24 * 60)
            return "\(days) \(days == 1 ? "day" : "days") ago"
        }
    }

    /// A rate as Settings shows it, rounded down so a lower bound or the
    /// budget never overstates the link: kbps below 1 Mbps, one decimal
    /// below 10 Mbps ("4.5 Mbps", "4 Mbps" for a whole one), whole Mbps from
    /// 10, with no digit grouping.
    static func connectionRateText(kbps: Int) -> String {
        let kbps = max(kbps, 0)
        if kbps < 1_000 { return "\(kbps) kbps" }
        if kbps >= 10_000 { return "\(kbps / 1_000) Mbps" }
        let tenths = kbps / 100
        return tenths % 10 == 0 ? "\(tenths / 10) Mbps" : "\(tenths / 10).\(tenths % 10) Mbps"
    }

    static func connectionSpeedSkippedText(network: BandwidthProbeNetwork, cellularQualityApplies: Bool) -> String? {
        guard network.isConnected, network.isMetered else { return nil }
        if network.usesCellular {
            return "Speed tests are skipped on cellular, and the Cellular Quality settings apply."
        }
        return cellularQualityApplies
            ? "Speed tests are skipped on metered networks, and the Cellular Quality settings apply."
            : "Speed tests are skipped on metered networks."
    }

    // MARK: Device value or profile value

    /// Picker tag for "Use Profile Setting": selected while this device has
    /// no value of its own for the row, and choosing it clears that value.
    static let useProfileSettingTag = "__profile__"
    static let useProfileSettingLabel = "Use Profile Setting"
    /// Tag for a stored cellular pair no preset covers. Not a preset id, so
    /// selecting it is a no-op rather than a write.
    static let customQualityTag = "__custom__"
    /// The Maximum Bitrate picker's "No limit".
    static let noBitrateLimitTag = "none"
    static let onTag = "on"
    static let offTag = "off"

    /// Whether the row shows the profile's value rather than this device's.
    func usesProfileSetting(_ setting: ProfileBackedPlaybackSetting) -> Bool {
        !PlayerSettings.shared.hasDeviceOverride(setting)
    }

    /// The selected picker tag for a profile-backed Playback row. Resolution
    /// tags are the contract's members; Maximum Bitrate tags are the cap in
    /// kbps or ``noBitrateLimitTag``.
    func playbackSelectionTag(_ setting: ProfileBackedPlaybackSetting) -> String {
        guard !usesProfileSetting(setting) else { return Self.useProfileSettingTag }
        switch setting {
        case .resolution: return PlayerSettings.shared.preferredQualityResolution
        case .maxBitrate: return PlayerSettings.shared.maxBitrateKbps.map(String.init) ?? Self.noBitrateLimitTag
        case .cellularQuality: return cellularQualityPresetId ?? Self.customQualityTag
        case .bufferingQualityMode: return bufferingQualityMode.wireValue
        case .audioLanguage: return preferredAudioLanguage
        case .introSkipMode: return introSkipMode.wireValue
        case .autoSkipCredits: return skipCredits ? Self.onTag : Self.offTag
        case .autoPlayNext: return autoPlayNext ? Self.onTag : Self.offTag
        case .nextUpPrompt: return String(nextUpPromptSeconds)
        }
    }

    /// Apply a picker choice for a profile-backed Playback row.
    func selectPlayback(_ tag: String, for setting: ProfileBackedPlaybackSetting) {
        // Choosing what is already checked changes nothing — in particular a
        // stored "No preference" re-chosen must not fall back to the profile.
        guard tag != playbackSelectionTag(setting) else { return }
        // "No preference" is not stored on a device either: it clears the
        // device's own language, exactly like "Use Profile Setting".
        if tag == Self.useProfileSettingTag || (setting == .audioLanguage && tag.isEmpty) {
            useProfileSetting(setting)
            return
        }
        switch setting {
        case .resolution:
            guard SiloQualityPresets.resolutionChoices.contains(tag) else { return }
            PlayerSettings.shared.setQualityResolution(tag)
        case .maxBitrate:
            if tag == Self.noBitrateLimitTag {
                PlayerSettings.shared.setMaxBitrateKbps(nil)
            } else if let kbps = Int(tag), kbps > 0 {
                PlayerSettings.shared.setMaxBitrateKbps(kbps)
            }
        case .cellularQuality:
            guard tag != Self.customQualityTag else { return }
            setCellularQualityPreset(tag)
        case .bufferingQualityMode:
            guard let mode = BufferingQualityMode(wireValue: tag) else { return }
            bufferingQualityMode = mode
        case .audioLanguage:
            preferredAudioLanguage = tag
        case .introSkipMode:
            guard let mode = IntroSkipMode(wireValue: tag) else { return }
            introSkipMode = mode
        case .autoSkipCredits:
            skipCredits = tag == Self.onTag
        case .autoPlayNext:
            autoPlayNext = tag == Self.onTag
        case .nextUpPrompt:
            guard let seconds = Int(tag) else { return }
            nextUpPromptSeconds = seconds
        }
    }

    /// Clear this device's own value for one row so the profile's applies.
    func useProfileSetting(_ setting: ProfileBackedPlaybackSetting) {
        guard !usesProfileSetting(setting) else { return }
        Task { @MainActor in
            await PlayerSettings.shared.useProfileSetting(setting)
        }
    }

    /// A device "No preference" left by an earlier build, which stored it as
    /// a value. It gets its own entry so the picker never shows a choice that
    /// is not what is stored; choosing anything else replaces it.
    var hasStoredNoAudioLanguagePreference: Bool {
        !usesProfileSetting(.audioLanguage) && preferredAudioLanguage.isEmpty
    }

    // MARK: Use Profile Settings

    static let useProfileSettingsTitle = "Use your profile's settings on this device?"

    /// The confirmation's message. It says plainly that settings the profile
    /// has no value for — the device-only ones — go back to their defaults,
    /// since there is no profile setting for them to return to.
    var useProfileSettingsMessage: String {
        let count = PlayerSettings.shared.deviceChangedSettingCount
        var message: String
        switch count {
        case 0: message = "This removes any settings changed on this device."
        case 1: message = "This removes the setting changed on this device."
        default: message = "This removes the \(count) settings changed on this device."
        }
        if count == 0 || PlayerSettings.shared.deviceChangesIncludeDeviceOnlySettings {
            message += " Settings that only apply to this device, like Dolby Vision and Buffer Ahead, go back to their defaults."
        }
        return message
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
