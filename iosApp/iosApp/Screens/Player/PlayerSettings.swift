import AVFoundation
import Foundation
import SwiftUI

/// How the iOS player should manage screen orientation while playback is
/// visible. This is persisted so the next session reuses the user's choice.
enum PlayerOrientationMode: String {
    case landscapeLocked = "landscapeLocked"
    case rotateFreely = "rotateFreely"

    var isLandscapeLocked: Bool {
        self == .landscapeLocked
    }
}

/// How the video frame fills the player bounds. Maps directly to
/// `AVLayerVideoGravity` values on the display layer.
enum VideoGravity: String, CaseIterable {
    case fit = "fit"
    case fill = "fill"
    case stretch = "stretch"

    var avGravity: AVLayerVideoGravity {
        switch self {
        case .fit:     return .resizeAspect
        case .fill:    return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    var label: String {
        switch self {
        case .fit:     return "Fit"
        case .fill:    return "Fill"
        case .stretch: return "Stretch"
        }
    }
}

/// The device-scoped settings this client syncs, as generated contract keys.
///
/// The raw strings used to live here as a private enum, which is how
/// `subtitle_appearance` kept its unprefixed name and how Apple and Android
/// ended up disagreeing about `next_up_prompt_seconds`. They come from
/// `SettingKey` now, so a key this client sends is a key the server's manifest
/// declares — by construction, not by review.
///
/// Also the order a flush sends them in: `playback.preferred_quality` precedes
/// `playback.max_bitrate_kbps` so the two axes of one compound tier always land
/// resolution-first.
let playerDeviceSettingKeys: [SettingKey] = [
    .playbackPreferredQuality,
    .playbackMaxBitrateKbps,
    .playbackAudioLanguage,
    .playbackAutoSkipIntro,
    .playbackAutoSkipCredits,
    .playbackAutoPlayNext,
    .playbackNextUpPromptSeconds,
    .playbackSubtitleAppearance,
    .playerHdrEnabled,
    .playerDolbyVisionEnabled,
    .playerDvProfile7Hdr10Fallback,
    .playerSeekCacheEnabled,
    .playerPlaybackSpeed,
    .playerAudioSyncMs,
    .playerSubtitleSyncMs,
    .playerVideoGravity,
    .playerOrientationMode,
]

private typealias PlayerDeviceSettingKey = SettingKey

extension SettingKey {
    /// The keys this screen syncs, in a stable order for the flush loop.
    static var playerDeviceSettings: [SettingKey] { playerDeviceSettingKeys }
}

private extension SettingKey {
    // Short names for the keys this file uses. The generated cases are named
    // after the full dotted key (playbackAutoSkipIntro); these aliases keep the
    // call sites readable without reintroducing a second list of raw strings —
    // each one still resolves to a generated case, so a key removed from the
    // contract fails to compile here.
    static var preferredQuality: SettingKey { .playbackPreferredQuality }
    static var maxBitrateKbps: SettingKey { .playbackMaxBitrateKbps }
    static var audioLanguage: SettingKey { .playbackAudioLanguage }
    static var autoSkipIntro: SettingKey { .playbackAutoSkipIntro }
    static var autoSkipCredits: SettingKey { .playbackAutoSkipCredits }
    static var autoPlayNext: SettingKey { .playbackAutoPlayNext }
    static var nextUpPromptSeconds: SettingKey { .playbackNextUpPromptSeconds }
    static var subtitleAppearance: SettingKey { .playbackSubtitleAppearance }
    static var hdrEnabled: SettingKey { .playerHdrEnabled }
    static var dolbyVisionEnabled: SettingKey { .playerDolbyVisionEnabled }
    static var dvProfile7HDR10Fallback: SettingKey { .playerDvProfile7Hdr10Fallback }
    static var seekCacheEnabled: SettingKey { .playerSeekCacheEnabled }
    static var playbackSpeed: SettingKey { .playerPlaybackSpeed }
    static var audioSyncMs: SettingKey { .playerAudioSyncMs }
    static var subtitleSyncMs: SettingKey { .playerSubtitleSyncMs }
    static var videoGravity: SettingKey { .playerVideoGravity }
    static var orientationMode: SettingKey { .playerOrientationMode }
}

@Observable
final class PlayerSettings {
    enum RefreshResult: Equatable {
        case refreshed
        case serverUpgradeRequired
        case unavailable
    }

    static let shared = PlayerSettings()

    /// The resolution half of the quality preference: a member of the
    /// contract's `playback.preferred_quality` enum.
    ///
    /// The stored *pair* — this and ``maxBitrateKbps`` — is the local source of
    /// truth. Storing a compound tier id was safe while this client had one
    /// quality table; it stopped being safe when the settings picker adopted
    /// the cross-client presets, because both tables spell a rung `1080p-high`
    /// and mean different bitrates by it (10 Mbps in ``SiloQualityPresets``,
    /// 20 Mbps in ``ApplePlaybackQuality``). A stored id would silently change
    /// meaning depending on which table read it back; a stored pair says what
    /// it means and each table interprets it rather than owning it.
    var preferredQualityResolution: String {
        didSet {
            defaults.set(preferredQualityResolution, forKey: Self.cacheKey(Keys.preferredQuality))
        }
    }

    /// The bandwidth half of the quality preference; nil is uncapped.
    var maxBitrateKbps: Int? {
        didSet {
            let key = Self.cacheKey(Keys.maxBitrateKbps)
            // Removed rather than stored as a sentinel, so "uncapped" is the
            // absence of a value locally exactly as it is on the wire.
            if let maxBitrateKbps {
                defaults.set(maxBitrateKbps, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The stored pair as an id from this client's in-player ladder.
    ///
    /// Read-only, and derived rather than stored: playback's ~12 call sites ask
    /// "which transcode rung" and have always been answered with an
    /// ``ApplePlaybackQuality`` id, so they keep working unchanged. The
    /// derivation honours both caps, which is why a pair authored on web or
    /// Android — whose ladders differ from this one — still resolves to a rung
    /// this client can actually request. See AppleQualityAxes.swift.
    var preferredQuality: String {
        AppleQualityAxes.join(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    /// The shared preset the stored pair corresponds to, or nil when the pair
    /// is a combination no preset covers — set through the API, or written by a
    /// client whose ladder has a rung this table does not. The settings picker
    /// shows the pair's own description in that case rather than snapping to a
    /// nearby preset, which would misreport what is stored.
    var currentQualityPreset: SiloQualityPreset? {
        SiloQualityPresets.preset(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    /// A user-facing label for the stored pair, preset or not.
    var preferredQualityLabel: String {
        SiloQualityPresets.describe(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    var audioLanguage: String {
        didSet { defaults.set(audioLanguage, forKey: Self.cacheKey(Keys.audioLanguage)) }
    }

    /// Deployment-observed choices returned with the effective audio setting.
    /// The UI unions these with the generated contract floor and current value.
    private(set) var audioLanguageSuggestions: [String] = []

    var autoSkipIntro: Bool {
        didSet { defaults.set(autoSkipIntro, forKey: Self.cacheKey(Keys.autoSkipIntro)) }
    }

    var autoSkipCredits: Bool {
        didSet { defaults.set(autoSkipCredits, forKey: Self.cacheKey(Keys.autoSkipCredits)) }
    }

    /// Deprecated: no longer surfaced. No AVPlayer-backed route exposes an
    /// HDR passthrough toggle; the field stays because `player.hdrEnabled` is
    /// part of the server-synced settings contract.
    var hdrEnabled: Bool {
        didSet { defaults.set(hdrEnabled, forKey: Self.cacheKey(Keys.hdrEnabled)) }
    }

    /// When off, Dolby Vision sources with a compatible base layer play as
    /// plain HDR10/HLG instead. Profile 5 has no such base layer and always
    /// plays in Dolby Vision.
    var dolbyVisionEnabled: Bool {
        didSet { defaults.set(dolbyVisionEnabled, forKey: Self.cacheKey(Keys.dolbyVisionEnabled)) }
    }

    var preferProfile7HDR10Fallback: Bool {
        didSet { defaults.set(preferProfile7HDR10Fallback, forKey: Self.cacheKey(Keys.dvProfile7HDR10Fallback)) }
    }

    /// Plan-time snapshot of the Dolby Vision decision inputs, consumed by
    /// the route planner before each load.
    var dolbyVisionPolicySnapshot: DolbyVisionPolicy.Snapshot {
        DolbyVisionPolicy.Snapshot(
            dolbyVisionEnabled: dolbyVisionEnabled,
            preferProfile7HDR10Fallback: preferProfile7HDR10Fallback
        )
    }

    /// Spill streamed bytes to temporary disk storage during playback so
    /// large forward/backward seeks are served locally. Governs the source
    /// cache only; the loopback segment store's spill is load-bearing for the
    /// DV route and stays on regardless.
    var seekCacheEnabled: Bool {
        didSet { defaults.set(seekCacheEnabled, forKey: Self.cacheKey(Keys.seekCacheEnabled)) }
    }

    var subtitleAppearance: SubtitleAppearance {
        didSet {
            let sanitized = subtitleAppearance.sanitized()
            defaults.set(sanitized.jsonString, forKey: Self.cacheKey(Keys.subtitleAppearance))
            syncLegacySubtitleFields(from: sanitized)
        }
    }

    /// Server/profile fallback used while this device's custom appearance
    /// override is off. Kept separate so refreshing the effective value does
    /// not destroy the user's locally cached custom style.
    private var inheritedSubtitleAppearance: SubtitleAppearance {
        didSet {
            defaults.set(
                inheritedSubtitleAppearance.sanitized().jsonString,
                forKey: Self.cacheKey(Keys.inheritedSubtitleAppearance)
            )
        }
    }

    var subtitleUsesDeviceAppearanceOverride: Bool {
        didSet {
            defaults.set(
                subtitleUsesDeviceAppearanceOverride,
                forKey: Self.cacheKey(Keys.subtitleUsesDeviceAppearanceOverride)
            )
        }
    }

    /// Device-local: when true, subtitle styling mirrors the system's
    /// Subtitles & Captioning accessibility preferences instead of the
    /// Silo appearance. Never synced to the server — it is inherently
    /// about *this* device's accessibility configuration.
    var subtitleMatchesSystemAppearance: Bool {
        didSet {
            defaults.set(
                subtitleMatchesSystemAppearance,
                forKey: Self.cacheKey(Keys.subtitleMatchesSystemAppearance)
            )
        }
    }

    /// Latest mapping of the system caption preferences. Refreshed when
    /// MediaAccessibility posts its settings-changed notification.
    var subtitleSystemAppearance: SubtitleAppearance = SystemCaptionAppearance.current()
    var subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()

    /// The appearance the player should actually render with.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        if subtitleMatchesSystemAppearance { return subtitleSystemAppearance }
        return subtitleUsesDeviceAppearanceOverride
            ? subtitleAppearance
            : inheritedSubtitleAppearance
    }

    var subtitleFontSize: Double {
        didSet { defaults.set(subtitleFontSize, forKey: Keys.subtitleFontSize) }
    }

    var subtitleTextColor: String {
        didSet { defaults.set(subtitleTextColor, forKey: Keys.subtitleTextColor) }
    }

    var subtitleBorderSize: Double {
        didSet { defaults.set(subtitleBorderSize, forKey: Keys.subtitleBorderSize) }
    }

    var subtitleBorderColor: String {
        didSet { defaults.set(subtitleBorderColor, forKey: Keys.subtitleBorderColor) }
    }

    var subtitleBackgroundColor: String {
        didSet { defaults.set(subtitleBackgroundColor, forKey: Keys.subtitleBackgroundColor) }
    }

    var subtitleBackgroundOpacityPercent: Int {
        didSet { defaults.set(subtitleBackgroundOpacityPercent, forKey: Keys.subtitleBackgroundOpacityPercent) }
    }

    var subtitlePosition: Int {
        didSet { defaults.set(subtitlePosition, forKey: Keys.subtitlePosition) }
    }

    /// Deprecated: no longer surfaced. No AVPlayer-backed route exposes an
    /// audio-delay control; the field stays because `player.audioSyncMs` is
    /// part of the server-synced settings contract.
    var audioSyncMs: Int {
        didSet { defaults.set(audioSyncMs, forKey: Self.cacheKey(Keys.audioSyncMs)) }
    }

    var subtitleSyncMs: Int {
        didSet { defaults.set(subtitleSyncMs, forKey: Self.cacheKey(Keys.subtitleSyncMs)) }
    }

    var playbackSpeed: Double {
        didSet { defaults.set(playbackSpeed, forKey: Self.cacheKey(Keys.playbackSpeed)) }
    }

    var videoGravity: VideoGravity {
        didSet { defaults.set(videoGravity.rawValue, forKey: Self.cacheKey(Keys.videoGravity)) }
    }

    var playerOrientationMode: PlayerOrientationMode {
        didSet { defaults.set(playerOrientationMode.rawValue, forKey: Self.cacheKey(Keys.playerOrientationMode)) }
    }

    var autoPlayNextEpisode: Bool {
        didSet { defaults.set(autoPlayNextEpisode, forKey: Self.cacheKey(Keys.autoPlayNextEpisode)) }
    }

    var nextUpPromptSeconds: Int {
        didSet { defaults.set(nextUpPromptSeconds, forKey: Self.cacheKey(Keys.nextUpPromptSeconds)) }
    }

    private let defaults: UserDefaults

    /// Debounced writer for the canonical settings API. Owns the queue, the
    /// mutation ids and the retry schedule; see PlayerSettingsFlusher.swift.
    private let flusher: PlayerSettingsFlusher

    /// Designated initializer, non-private so tests can build an instance with
    /// an isolated `UserDefaults` and a fake transport rather than reaching for
    /// the singleton (which would leak state between tests and hit the
    /// network).
    init(
        defaults: UserDefaults = .standard,
        flusher: PlayerSettingsFlusher = PlayerSettingsFlusher()
    ) {
        self.defaults = defaults
        self.flusher = flusher
        defaults.register(defaults: [
            Keys.preferredQuality: "auto",
            // maxBitrateKbps deliberately has no registered default: the
            // contract's default is null, and a registered value would make
            // "uncapped" indistinguishable from "capped at that number".
            Keys.audioLanguage: "",
            Keys.autoSkipIntro: false,
            Keys.autoSkipCredits: false,
            Keys.hdrEnabled: true,
            Keys.dolbyVisionEnabled: true,
            Keys.dvProfile7HDR10Fallback: false,
            Keys.seekCacheEnabled: true,
            Keys.subtitleAppearance: SubtitleAppearance.default.jsonString,
            Keys.inheritedSubtitleAppearance: SubtitleAppearance.default.jsonString,
            Keys.subtitleUsesDeviceAppearanceOverride: false,
            Keys.subtitleMatchesSystemAppearance: false,
            Keys.subtitleFontSize: 44.0,
            Keys.subtitleTextColor: "#FFFFFF",
            Keys.subtitleBorderSize: 0.0,
            Keys.subtitleBorderColor: "#000000",
            Keys.subtitleBackgroundColor: "#000000",
            Keys.subtitleBackgroundOpacityPercent: 0,
            Keys.subtitlePosition: 100,
            Keys.audioSyncMs: 0,
            Keys.subtitleSyncMs: 0,
            Keys.playbackSpeed: 1.0,
            Keys.videoGravity: VideoGravity.fit.rawValue,
            Keys.playerOrientationMode: PlayerOrientationMode.landscapeLocked.rawValue,
            Keys.autoPlayNextEpisode: true,
            Keys.nextUpPromptSeconds: 30,
        ])

        preferredQualityResolution = Self.cachedQualityResolution(defaults)
        maxBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
        audioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage)) ?? ""
        autoSkipIntro = Self.cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
        autoSkipCredits = Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
        hdrEnabled = Self.cachedBool(defaults, key: Keys.hdrEnabled, defaultValue: true)
        dolbyVisionEnabled = Self.cachedBool(defaults, key: Keys.dolbyVisionEnabled, defaultValue: true)
        preferProfile7HDR10Fallback = Self.cachedBool(
            defaults,
            key: Keys.dvProfile7HDR10Fallback,
            defaultValue: false
        )
        seekCacheEnabled = Self.cachedBool(
            defaults,
            key: Keys.seekCacheEnabled,
            defaultValue: true
        )
        subtitleAppearance = SubtitleAppearance.decode(from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance)))
        inheritedSubtitleAppearance = SubtitleAppearance.decode(
            from: defaults.string(forKey: Self.cacheKey(Keys.inheritedSubtitleAppearance))
        )
        subtitleUsesDeviceAppearanceOverride = Self.cachedBool(
            defaults,
            key: Keys.subtitleUsesDeviceAppearanceOverride,
            defaultValue: false
        )
        subtitleMatchesSystemAppearance = Self.cachedBool(
            defaults,
            key: Keys.subtitleMatchesSystemAppearance,
            defaultValue: false
        )
        subtitleFontSize = defaults.double(forKey: Keys.subtitleFontSize)
        subtitleTextColor = defaults.string(forKey: Keys.subtitleTextColor) ?? "#FFFFFF"
        subtitleBorderSize = defaults.double(forKey: Keys.subtitleBorderSize)
        subtitleBorderColor = defaults.string(forKey: Keys.subtitleBorderColor) ?? "#000000"
        subtitleBackgroundColor = defaults.string(forKey: Keys.subtitleBackgroundColor) ?? "#000000"
        subtitleBackgroundOpacityPercent = defaults.integer(forKey: Keys.subtitleBackgroundOpacityPercent)
        subtitlePosition = defaults.integer(forKey: Keys.subtitlePosition)
        audioSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.audioSyncMs))
        subtitleSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))
        playbackSpeed = Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
        videoGravity = VideoGravity(rawValue: defaults.string(forKey: Self.cacheKey(Keys.videoGravity)) ?? VideoGravity.fit.rawValue) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: defaults.string(forKey: Self.cacheKey(Keys.playerOrientationMode)) ?? PlayerOrientationMode.landscapeLocked.rawValue
        ) ?? .landscapeLocked
        autoPlayNextEpisode = Self.cachedBool(
            defaults,
            key: Keys.autoPlayNextEpisode,
            legacyKey: Keys.legacyAutoPlayNextEpisode,
            defaultValue: true
        )
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
        )
        syncLegacySubtitleFields(from: subtitleAppearance)

        NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSubtitleSystemAppearance()
        }
    }

    /// Re-read the system caption preferences. Idempotent; also called by
    /// the player when the system posts a settings-changed notification so
    /// re-application never races this class's own observer.
    func refreshSubtitleSystemAppearance() {
        subtitleSystemAppearance = SystemCaptionAppearance.current()
        subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()
    }

    var subtitleBackgroundColorHex: String {
        let alphaByte = max(0, min(255, (subtitleBackgroundOpacityPercent * 255) / 100))
        let rgb = subtitleBackgroundColor.hasPrefix("#")
            ? String(subtitleBackgroundColor.dropFirst())
            : subtitleBackgroundColor
        return "#" + String(format: "%02X", alphaByte) + rgb
    }

    /// Pull every synced setting from the server and adopt it.
    ///
    /// One batched call: the server resolves all seventeen keys in a single
    /// store read, and asking per key would be seventeen round trips on every
    /// app launch, profile switch and settings-screen open.
    @discardableResult
    @MainActor
    func refreshFromServer() async -> RefreshResult {
        // Capture the pre-contract values before applying the normalized cache
        // for this scope. That normalization intentionally turns a compound
        // legacy quality id into a bare resolution and would otherwise erase
        // the bitrate half before migration can preserve it.
        let legacySnapshot = legacySnapshot()
        applyCachedSettingsForCurrentScope()
        // Anything a previous run left owed is picked up before the effective
        // read, so an edit that never reached the server is *sent* rather than
        // being overwritten below by the stale value it was meant to replace.
        // Deliberately here rather than only in the flusher's init: the queue
        // is partitioned by (server, profile, device), and the app-wide
        // instance is built long before any of those are known.
        flusher.restorePendingWrites()
        await flushPendingDeviceSettings()

        let scopeID = Self.currentScopeIdentifier

        do {
            let response = try await flusher.effectiveValues(keys: SettingKey.playerDeviceSettings)
            let effectiveByKey = response.byKey
            applyEffectiveSettings(effectiveByKey)

            if let scopeID, !isMigrationComplete(for: scopeID) {
                let imported = await importLegacySettingsIfNeeded(
                    scopeID: scopeID,
                    legacySnapshot: legacySnapshot,
                    effectiveByKey: effectiveByKey
                )
                if imported {
                    // The migration just pushed legacy device-setting values
                    // to the server. Local state already holds those values
                    // (they came from local UserDefaults), so a second
                    // effective-values round-trip just to mirror the
                    // server's echo is wasted bandwidth on every session
                    // start until migration completes — and re-applying
                    // those same values overwrites any in-flight local
                    // edits anyway. Drain the queue and mark the migration
                    // done.
                    await flushPendingDeviceSettings()
                    markMigrationComplete(for: scopeID)
                }
            }
            return .refreshed
        } catch SettingsAPIError.serverUpgradeRequired {
            return .serverUpgradeRequired
        } catch {
            // Keep using the last cached values when offline.
            return .unavailable
        }
    }

    /// Set the quality from a tier id on this client's in-player ladder.
    ///
    /// The in-player switcher's entry point: it offers ``ApplePlaybackQuality``
    /// rungs, so the id is decomposed into the contract's two axes before it is
    /// stored. Sending the compound id would fail the enum with
    /// `invalid_value`; see AppleQualityAxes.swift.
    func setPreferredQuality(_ value: String) {
        let axes = AppleQualityAxes.split(ApplePlaybackQuality.normalizeStoredId(value))
        setQualityAxes(resolution: axes.resolution, bitrateKbps: axes.bitrateKbps)
    }

    /// Set the quality from a shared preset — the settings screens' entry
    /// point, on every platform and in the web and Android clients.
    func setQualityPreset(_ preset: SiloQualityPreset) {
        setQualityAxes(resolution: preset.resolution, bitrateKbps: preset.bitrateKbps)
    }

    /// Store one (resolution, bitrate) pair as the contract's two keys.
    ///
    /// Both axes are always written, never just the one that changed: the two
    /// resolve independently, so leaving a stale cap behind would keep
    /// throttling a tier the user just widened. Uncapped is an explicit JSON
    /// null rather than an omitted write for the same reason.
    private func setQualityAxes(resolution: String, bitrateKbps: Int?) {
        preferredQualityResolution = SiloQualityPresets.normalizeResolution(resolution)
        maxBitrateKbps = bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
        flusher.enqueue(.preferredQuality, value: .string(preferredQualityResolution))
        flusher.enqueue(.maxBitrateKbps, value: maxBitrateKbps.map { .int($0) } ?? .null)
    }

    func setAudioLanguage(_ value: String) {
        audioLanguage = value
        // The contract's language_tag rejects "": "no preference" is JSON null.
        flusher.enqueue(.audioLanguage, value: value.isEmpty ? .null : .string(value))
    }

    func setAutoSkipIntro(_ enabled: Bool) {
        autoSkipIntro = enabled
        flusher.enqueue(.autoSkipIntro, value: .bool(enabled))
    }

    func setAutoSkipCredits(_ enabled: Bool) {
        autoSkipCredits = enabled
        flusher.enqueue(.autoSkipCredits, value: .bool(enabled))
    }

    func setAutoPlayNextEpisode(_ enabled: Bool) {
        autoPlayNextEpisode = enabled
        flusher.enqueue(.autoPlayNext, value: .bool(enabled))
    }

    func setNextUpPromptSeconds(_ seconds: Int) {
        let normalized = Self.clampNextUpPromptSeconds(seconds)
        nextUpPromptSeconds = normalized
        flusher.enqueue(.nextUpPromptSeconds, value: .int(normalized))
    }

    func setHDREnabled(_ enabled: Bool) {
        hdrEnabled = enabled
        flusher.enqueue(.hdrEnabled, value: .bool(enabled))
    }

    func setDolbyVisionEnabled(_ enabled: Bool) {
        dolbyVisionEnabled = enabled
        flusher.enqueue(.dolbyVisionEnabled, value: .bool(enabled))
    }

    func setPreferProfile7HDR10Fallback(_ enabled: Bool) {
        preferProfile7HDR10Fallback = enabled
        flusher.enqueue(.dvProfile7HDR10Fallback, value: .bool(enabled))
    }

    func setSeekCacheEnabled(_ enabled: Bool) {
        seekCacheEnabled = enabled
        flusher.enqueue(.seekCacheEnabled, value: .bool(enabled))
    }

    func setPlaybackSpeed(_ rate: Double) {
        let normalized = Self.clampPlaybackSpeed(rate)
        playbackSpeed = normalized
        flusher.enqueue(.playbackSpeed, value: .double(normalized))
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        videoGravity = gravity
        flusher.enqueue(.videoGravity, value: .string(gravity.rawValue))
    }

    func setPlayerOrientationMode(_ mode: PlayerOrientationMode) {
        playerOrientationMode = mode
        flusher.enqueue(.orientationMode, value: .string(mode.rawValue))
    }

    func setAudioSyncMs(_ milliseconds: Int) {
        audioSyncMs = max(-5000, min(milliseconds, 5000))
        flusher.enqueue(.audioSyncMs, value: .int(audioSyncMs))
    }

    func setSubtitleSyncMs(_ milliseconds: Int) {
        subtitleSyncMs = max(-10000, min(milliseconds, 10000))
        flusher.enqueue(.subtitleSyncMs, value: .int(subtitleSyncMs))
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        let sanitized = appearance.sanitized()
        subtitleAppearance = sanitized
        subtitleUsesDeviceAppearanceOverride = true
        // A manual edit takes over from the system-matching source.
        subtitleMatchesSystemAppearance = false
        enqueueSubtitleAppearance(sanitized)
        await flushPendingDeviceSettings()
    }

    /// Toggle mirroring the device's Subtitles & Captioning accessibility
    /// preferences. Purely local; the saved Silo appearance is untouched
    /// so switching back restores it.
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) {
        guard enabled != subtitleMatchesSystemAppearance else { return }
        if enabled {
            subtitleSystemAppearance = SystemCaptionAppearance.current()
            subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()
        }
        subtitleMatchesSystemAppearance = enabled
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        guard enabled != subtitleUsesDeviceAppearanceOverride else { return }
        subtitleUsesDeviceAppearanceOverride = enabled
        if enabled {
            enqueueSubtitleAppearance(subtitleAppearance.sanitized())
            await flushPendingDeviceSettings()
            return
        }

        flusher.enqueueDelete(.subtitleAppearance)
        await flushPendingDeviceSettings()
        await refreshFromServer()
    }

    @MainActor
    func resetAllDeviceSettings() async {
        let resetScopeID = Self.currentScopeIdentifier
        // Reset is an explicit instruction to discard the pre-contract local
        // values. Retire migration before the follow-up refresh or that refresh
        // can snapshot and import the values whose canonical rows were just
        // deleted.
        if let resetScopeID {
            markMigrationComplete(for: resetScopeID)
        }
        for key in SettingKey.playerDeviceSettings {
            flusher.enqueueDelete(key)
        }
        await flushPendingDeviceSettings()
        if await refreshFromServer() == .serverUpgradeRequired {
            // A pre-contract server has no inherited canonical rows to read
            // back. Persist defaults into the captured partition even if the
            // user switched profiles while the DELETEs were suspended, but do
            // not repaint a different profile's live state. An ordinary
            // offline failure keeps the cached values instead.
            cacheContractDefaults(for: resetScopeID)
            if Self.currentScopeIdentifier == resetScopeID {
                applyCachedSettingsForCurrentScope()
            }
        }
    }

    /// Send everything queued and wait for it.
    ///
    /// The debounce exists to coalesce a *user* dragging a control; a caller
    /// that explicitly asks to flush (leaving the player, switching profile,
    /// resetting) has already decided the edit is final, so this bypasses the
    /// window rather than waiting it out.
    @MainActor
    func flushPendingDeviceSettings() async {
        await flusher.flushNow()
    }

    /// Encode the appearance as the contract's object type.
    ///
    /// `playback.subtitle_appearance` is a JSON object on the wire, not the
    /// stringified JSON the legacy string-only registry stored. Encoding goes
    /// through ``SettingJSONValue/encoding(_:)`` so the value's own camelCase
    /// keys (`fontSize`, `backgroundOpacity`) reach the server verbatim.
    private func enqueueSubtitleAppearance(_ appearance: SubtitleAppearance) {
        guard let value = try? SettingJSONValue.encoding(appearance) else {
            // Unreachable for a struct of scalars, and dropping the write is
            // the right failure: the server would reject a value that cannot
            // be encoded, and the local value is already applied.
            return
        }
        flusher.enqueue(.subtitleAppearance, value: value)
    }

    /// Adopt a batched resolution from the server.
    ///
    /// Every fallback here is the value the generated contract declares. The
    /// server sends a row for every key it knows, including ones nobody has
    /// stored a value for (`source == "default"`), so a fallback is reached
    /// only when the row is missing entirely — a server whose contract predates
    /// this key.
    private func applyEffectiveSettings(_ effectiveByKey: [SettingKey: EffectiveSettingValue]) {
        // Adopted as the pair the server actually stores, not as a tier id.
        // Round-tripping through this client's ladder here would quantize a
        // web- or Android-authored pair onto the nearest Apple rung and then
        // write that back on the next edit, so a 1080p/6 Mbps choice made on
        // the web would decay into Apple's 720p High the first time this
        // client touched any quality control.
        preferredQualityResolution = SiloQualityPresets.normalizeResolution(
            effectiveByKey[.preferredQuality]?.value.stringValue
        )
        maxBitrateKbps = effectiveByKey[.maxBitrateKbps]?.value.intValue.flatMap {
            $0 > 0 ? $0 : nil
        }
        // A nullable language tag: JSON null is "no preference", which this
        // client spells as the empty string.
        audioLanguage = effectiveByKey[.audioLanguage]?.value.stringValue ?? ""
        audioLanguageSuggestions = effectiveByKey[.audioLanguage]?.suggestedValues ?? []
        autoSkipIntro = effectiveBool(.autoSkipIntro, in: effectiveByKey, default: false)
        autoSkipCredits = effectiveBool(.autoSkipCredits, in: effectiveByKey, default: false)
        autoPlayNextEpisode = effectiveBool(.autoPlayNext, in: effectiveByKey, default: true)
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            effectiveByKey[.nextUpPromptSeconds]?.value.intValue ?? 30
        )
        hdrEnabled = effectiveBool(.hdrEnabled, in: effectiveByKey, default: true)
        dolbyVisionEnabled = effectiveBool(.dolbyVisionEnabled, in: effectiveByKey, default: true)
        preferProfile7HDR10Fallback = effectiveBool(
            .dvProfile7HDR10Fallback,
            in: effectiveByKey,
            default: false
        )
        seekCacheEnabled = effectiveBool(.seekCacheEnabled, in: effectiveByKey, default: true)
        playbackSpeed = Self.clampPlaybackSpeed(
            effectiveByKey[.playbackSpeed]?.value.doubleValue ?? 1.0
        )
        audioSyncMs = effectiveByKey[.audioSyncMs]?.value.intValue ?? 0
        subtitleSyncMs = effectiveByKey[.subtitleSyncMs]?.value.intValue ?? 0
        videoGravity = VideoGravity(
            rawValue: effectiveByKey[.videoGravity]?.value.stringValue ?? VideoGravity.fit.rawValue
        ) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: effectiveByKey[.orientationMode]?.value.stringValue
                ?? PlayerOrientationMode.landscapeLocked.rawValue
        ) ?? .landscapeLocked

        applyEffectiveSubtitleAppearance(effectiveByKey[.subtitleAppearance])
    }

    /// Split the resolved appearance between the device override and the
    /// inherited value.
    ///
    /// "Has a device override" is now a fact the server reports — the resolved
    /// row names the scope it came from — rather than something the legacy
    /// endpoint had to carry as a separate `hasDeviceOverride` boolean.
    private func applyEffectiveSubtitleAppearance(_ entry: EffectiveSettingValue?) {
        guard let entry else {
            subtitleUsesDeviceAppearanceOverride = false
            inheritedSubtitleAppearance = .default
            return
        }
        let hasDeviceOverride = entry.scope == .profileDevice
        subtitleUsesDeviceAppearanceOverride = hasDeviceOverride
        // A stored appearance is a sparse override the schema merges over the
        // contract default, and SubtitleAppearance's decoder already fills each
        // absent property from `.default` — so a partial object round-trips
        // rather than resetting the properties it omits.
        let appearance = ((try? entry.value.decoded(as: SubtitleAppearance.self)) ?? .default).sanitized()
        if hasDeviceOverride {
            subtitleAppearance = appearance
        } else {
            inheritedSubtitleAppearance = appearance
        }
    }

    /// A bool from a resolved row, falling back to the contract's typed default
    /// only when the server sent no row for the key at all.
    ///
    /// The `effectiveValue.isEmpty` guard this replaces existed because the
    /// legacy endpoint had no way to say "unset": it answered with an empty
    /// string, which is not a bool, so every default-ON toggle flipped off on
    /// the first refresh against a server that predated the key. The canonical
    /// endpoint sends a typed value with `source: "default"` instead, so
    /// "absent" and "false" are now distinct on the wire and the guard is not
    /// only unnecessary but wrong — it would swallow a genuine `false`.
    private func effectiveBool(
        _ key: PlayerDeviceSettingKey,
        in effectiveByKey: [SettingKey: EffectiveSettingValue],
        default fallback: Bool
    ) -> Bool {
        effectiveByKey[key]?.value.boolValue ?? fallback
    }

    /// This device's locally cached values, as the contract's typed JSON.
    ///
    /// Read once at the top of a refresh, before the server's answer is
    /// applied, so the one-time migration can tell a value this device has
    /// always held from one the server just handed back.
    ///
    /// The quality half is decomposed here for the same reason the setter
    /// decomposes it: a compound id like `1080p-high` is not a member of the
    /// contract's enum, so migrating it verbatim would be rejected forever.
    // Internal so the migration's lossless key coverage can be pinned by the
    // focused settings tests without reaching through a live server/profile.
    func legacySnapshot() -> [SettingKey: SettingJSONValue] {
        // Both spellings appear here: the unscoped key predates per-scope
        // caching, and either may still hold a compound tier id from a build
        // before the axes were stored separately. The shared axes conversion
        // reduces any of them to a contract member without losing its cap.
        let legacyQualityId = defaults.string(forKey: Self.cacheKey(Keys.preferredQuality))
            ?? defaults.string(forKey: Keys.preferredQuality)
        let legacyQualityAxes = AppleQualityAxes.split(
            legacyQualityId ?? ApplePlaybackQuality.autoId
        )
        // Builds before the contract stored Apple's compound rung id in the
        // quality key and had no companion bitrate key. Recover that rung's
        // cap only when no explicit axis exists; the separate key is always
        // authoritative once present.
        let legacyBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
            ?? legacyQualityAxes.bitrateKbps
        let legacyAudioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage))
            ?? defaults.string(forKey: Keys.audioLanguage)
            ?? ""
        let legacyAppearance = SubtitleAppearance.decode(
            from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance))
                ?? defaults.string(forKey: Keys.subtitleAppearance)
        )

        var snapshot: [SettingKey: SettingJSONValue] = [
            .preferredQuality: .string(legacyQualityAxes.resolution),
            .maxBitrateKbps: legacyBitrateKbps.map { .int($0) } ?? .null,
            .audioLanguage: legacyAudioLanguage.isEmpty ? .null : .string(legacyAudioLanguage),
            .autoSkipIntro: .bool(
                Self.cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
            ),
            .autoSkipCredits: .bool(
                Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
            ),
            .autoPlayNext: .bool(
                Self.cachedBool(
                    defaults,
                    key: Keys.autoPlayNextEpisode,
                    legacyKey: Keys.legacyAutoPlayNextEpisode,
                    defaultValue: true
                )
            ),
            .nextUpPromptSeconds: .int(
                Self.clampNextUpPromptSeconds(
                    Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
                )
            ),
            .hdrEnabled: .bool(
                Self.cachedBool(defaults, key: Keys.hdrEnabled, defaultValue: true)
            ),
            .dolbyVisionEnabled: .bool(
                Self.cachedBool(defaults, key: Keys.dolbyVisionEnabled, defaultValue: true)
            ),
            .dvProfile7HDR10Fallback: .bool(
                Self.cachedBool(defaults, key: Keys.dvProfile7HDR10Fallback, defaultValue: false)
            ),
            .seekCacheEnabled: .bool(
                Self.cachedBool(defaults, key: Keys.seekCacheEnabled, defaultValue: true)
            ),
            .playbackSpeed: .double(
                Self.clampPlaybackSpeed(
                    Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
                )
            ),
            .audioSyncMs: .int(defaults.integer(forKey: Self.cacheKey(Keys.audioSyncMs))),
            .subtitleSyncMs: .int(defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))),
            .videoGravity: .string(
                defaults.string(forKey: Self.cacheKey(Keys.videoGravity)) ?? VideoGravity.fit.rawValue
            ),
            .orientationMode: .string(
                defaults.string(forKey: Self.cacheKey(Keys.playerOrientationMode))
                    ?? PlayerOrientationMode.landscapeLocked.rawValue
            ),
        ]
        if let appearance = try? SettingJSONValue.encoding(legacyAppearance) {
            snapshot[.subtitleAppearance] = appearance
        }
        return snapshot
    }

    private func applyCachedSettingsForCurrentScope() {
        preferredQualityResolution = Self.cachedQualityResolution(defaults)
        maxBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
        audioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage)) ?? ""
        autoSkipIntro = Self.cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
        autoSkipCredits = Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
        autoPlayNextEpisode = Self.cachedBool(
            defaults,
            key: Keys.autoPlayNextEpisode,
            legacyKey: Keys.legacyAutoPlayNextEpisode,
            defaultValue: true
        )
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
        )
        hdrEnabled = Self.cachedBool(defaults, key: Keys.hdrEnabled, defaultValue: true)
        dolbyVisionEnabled = Self.cachedBool(defaults, key: Keys.dolbyVisionEnabled, defaultValue: true)
        preferProfile7HDR10Fallback = Self.cachedBool(
            defaults,
            key: Keys.dvProfile7HDR10Fallback,
            defaultValue: false
        )
        seekCacheEnabled = Self.cachedBool(
            defaults,
            key: Keys.seekCacheEnabled,
            defaultValue: true
        )
        playbackSpeed = Self.clampPlaybackSpeed(
            Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
        )
        audioSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.audioSyncMs))
        subtitleSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))
        videoGravity = VideoGravity(
            rawValue: defaults.string(forKey: Self.cacheKey(Keys.videoGravity)) ?? VideoGravity.fit.rawValue
        ) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: defaults.string(forKey: Self.cacheKey(Keys.playerOrientationMode)) ?? PlayerOrientationMode.landscapeLocked.rawValue
        ) ?? .landscapeLocked
        subtitleUsesDeviceAppearanceOverride = Self.cachedBool(
            defaults,
            key: Keys.subtitleUsesDeviceAppearanceOverride,
            defaultValue: false
        )
        subtitleMatchesSystemAppearance = Self.cachedBool(
            defaults,
            key: Keys.subtitleMatchesSystemAppearance,
            defaultValue: false
        )
        subtitleAppearance = SubtitleAppearance.decode(from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance)))
        inheritedSubtitleAppearance = SubtitleAppearance.decode(
            from: defaults.string(forKey: Self.cacheKey(Keys.inheritedSubtitleAppearance))
        )
    }

    /// One-time push of this device's pre-contract local values to the server.
    ///
    /// Only for keys with nothing stored at `profile_device`: a value already
    /// there is either this device's own earlier write or a deliberate reset,
    /// and neither should be overwritten by whatever UserDefaults still holds.
    @MainActor
    // Internal for focused migration tests; callers still go through the
    // ordinary refresh path in production.
    func importLegacySettingsIfNeeded(
        scopeID: String,
        legacySnapshot: [SettingKey: SettingJSONValue],
        effectiveByKey: [SettingKey: EffectiveSettingValue]
    ) async -> Bool {
        var importedAny = false
        var locallyEffective = effectiveByKey

        for key in SettingKey.playerDeviceSettings {
            guard let legacyValue = legacySnapshot[key] else { continue }
            guard let entry = effectiveByKey[key], entry.scope != .profileDevice else { continue }
            // Nothing to migrate when the resolved value already equals what
            // this device holds — typed comparison now, so `1` and `1.0` are
            // not two different values the way their strings were.
            if legacyValue.isSemanticallyEquivalent(to: entry.value) {
                continue
            }
            flusher.enqueue(key, value: legacyValue)
            if !entry.constrained {
                // Reflect only the rows selected for import. This happens
                // before the first await so a later user edit cannot be
                // overwritten, while constrained rows keep the policy-limited
                // effective value the server already returned.
                locallyEffective[key] = EffectiveSettingValue(
                    key: key.rawValue,
                    value: legacyValue,
                    source: .scope(.profileDevice),
                    suggestedValues: entry.suggestedValues,
                    scope: .profileDevice
                )
            }
            importedAny = true
        }

        if !importedAny {
            markMigrationComplete(for: scopeID)
            return false
        }

        applyEffectiveSettings(locallyEffective)
        await flushPendingDeviceSettings()
        // Only complete when every op drained. Anything still queued failed and
        // will be retried, and marking the migration done would strand it.
        return !flusher.hasPendingWrites
    }

    private func syncLegacySubtitleFields(from appearance: SubtitleAppearance) {
        subtitleFontSize = appearance.fontSize.pointSize
        subtitleTextColor = appearance.fontColor.uppercased()
        subtitleBorderSize = appearance.backgroundStyle == .outline || appearance.textOutline ? 2 : 0
        subtitleBorderColor = appearance.textOutlineColor.uppercased()
        subtitleBackgroundColor = appearance.backgroundColor.uppercased()
        subtitleBackgroundOpacityPercent = appearance.backgroundStyle == .box ? appearance.backgroundOpacity : 0
        subtitlePosition = appearance.position.legacyPosition
    }

    /// The (server, profile, device) triple this device's settings belong to.
    ///
    /// Non-private because the flusher's write journal partitions the persisted
    /// queue by it: a queued op restored after the user switched servers or
    /// profiles would write the previous profile's choice onto the current one.
    static var currentScopeIdentifier: String? {
        let serverURL = ServerRegistry.shared.activeServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = AuthService.shared.profileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deviceID = AppleDeviceIdentity.current.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !profileID.isEmpty, !deviceID.isEmpty else {
            return nil
        }
        let raw = "\(serverURL)|\(profileID)|\(deviceID)"
        return Data(raw.utf8).base64EncodedString()
    }

    private func migrationKey(for scopeID: String) -> String {
        "player.serverDeviceSettingsMigration.\(scopeID)"
    }

    private func isMigrationComplete(for scopeID: String) -> Bool {
        defaults.bool(forKey: migrationKey(for: scopeID))
    }

    private func markMigrationComplete(for scopeID: String) {
        defaults.set(true, forKey: migrationKey(for: scopeID))
    }

    /// Store the canonical reset state in one explicit cache partition.
    /// `cacheKey(_:)` normally follows the mutable active profile, which is
    /// unsafe after the network suspensions in Reset.
    private func cacheContractDefaults(for scopeID: String?) {
        func key(_ baseKey: String) -> String {
            Self.cacheKey(baseKey, scopeID: scopeID)
        }

        defaults.set("auto", forKey: key(Keys.preferredQuality))
        defaults.removeObject(forKey: key(Keys.maxBitrateKbps))
        defaults.set("", forKey: key(Keys.audioLanguage))
        defaults.set(false, forKey: key(Keys.autoSkipIntro))
        defaults.set(false, forKey: key(Keys.autoSkipCredits))
        defaults.set(true, forKey: key(Keys.autoPlayNextEpisode))
        defaults.set(30, forKey: key(Keys.nextUpPromptSeconds))
        defaults.set(true, forKey: key(Keys.hdrEnabled))
        defaults.set(true, forKey: key(Keys.dolbyVisionEnabled))
        defaults.set(false, forKey: key(Keys.dvProfile7HDR10Fallback))
        defaults.set(true, forKey: key(Keys.seekCacheEnabled))
        defaults.set(1.0, forKey: key(Keys.playbackSpeed))
        defaults.set(0, forKey: key(Keys.audioSyncMs))
        defaults.set(0, forKey: key(Keys.subtitleSyncMs))
        defaults.set(VideoGravity.fit.rawValue, forKey: key(Keys.videoGravity))
        defaults.set(
            PlayerOrientationMode.landscapeLocked.rawValue,
            forKey: key(Keys.playerOrientationMode)
        )
        defaults.set(SubtitleAppearance.default.jsonString, forKey: key(Keys.subtitleAppearance))
        defaults.set(
            SubtitleAppearance.default.jsonString,
            forKey: key(Keys.inheritedSubtitleAppearance)
        )
        defaults.set(false, forKey: key(Keys.subtitleUsesDeviceAppearanceOverride))
    }

    private static func cacheKey(_ baseKey: String) -> String {
        cacheKey(baseKey, scopeID: currentScopeIdentifier)
    }

    private static func cacheKey(_ baseKey: String, scopeID: String?) -> String {
        guard let scopeID else {
            return baseKey
        }
        return "player.serverDeviceSettings.\(scopeID).\(baseKey)"
    }

    private static func cachedBool(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        defaultValue: Bool
    ) -> Bool {
        let scopedKey = cacheKey(key)
        if defaults.object(forKey: scopedKey) != nil {
            return defaults.bool(forKey: scopedKey)
        }
        if let legacyKey, defaults.object(forKey: legacyKey) != nil {
            let legacyValue = defaults.bool(forKey: legacyKey)
            defaults.set(legacyValue, forKey: scopedKey)
            return legacyValue
        }
        return defaultValue
    }

    private func legacyBool(key: String, legacyKey: String? = nil, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        if let legacyKey, defaults.object(forKey: legacyKey) != nil {
            let legacyValue = defaults.bool(forKey: legacyKey)
            defaults.set(legacyValue, forKey: key)
            return legacyValue
        }
        return defaultValue
    }

    /// The cached resolution axis, tolerating a compound value written by a
    /// build that stored the tier id.
    ///
    /// Those builds wrote `1080p-high` and friends into this very key, so the
    /// value read here may be either spelling.
    /// ``SiloQualityPresets/normalizeResolution(_:)`` reduces both to a
    /// contract member, dropping the bitrate half — which is correct, because
    /// the companion key below carries it. An upgrading device therefore keeps
    /// its resolution and loses only a cap it never stored separately, and the
    /// first server refresh restores that from the profile's own row.
    private static func cachedQualityResolution(_ defaults: UserDefaults) -> String {
        SiloQualityPresets.normalizeResolution(
            defaults.string(forKey: cacheKey(Keys.preferredQuality))
        )
    }

    /// The cached bitrate axis. Absent is uncapped, which is why this reads
    /// through `object(forKey:)` rather than `integer(forKey:)` — the latter
    /// answers 0 for a missing key, and 0 is not a cap the contract accepts.
    private static func cachedMaxBitrateKbps(_ defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: cacheKey(Keys.maxBitrateKbps)) != nil else { return nil }
        let stored = defaults.integer(forKey: cacheKey(Keys.maxBitrateKbps))
        return stored > 0 ? stored : nil
    }

    private static func cachedDouble(_ defaults: UserDefaults, key: String, defaultValue: Double) -> Double {
        let scopedKey = cacheKey(key)
        guard defaults.object(forKey: scopedKey) != nil else {
            return defaultValue
        }
        return defaults.double(forKey: scopedKey)
    }

    private static func cachedInt(_ defaults: UserDefaults, key: String, defaultValue: Int) -> Int {
        let scopedKey = cacheKey(key)
        guard defaults.object(forKey: scopedKey) != nil else {
            return defaultValue
        }
        return defaults.integer(forKey: scopedKey)
    }

    private static func clampNextUpPromptSeconds(_ seconds: Int) -> Int {
        max(0, min(seconds, 120))
    }

    /// Clamp to the contract's declared range *and* step for
    /// `player.playback_speed` (0.25…3.0, step 0.05).
    ///
    /// The step is the part worth stating: the server rejects a value off the
    /// grid with `invalid_value`, and a UI that ever offers 1.33× — or a
    /// double that lands at 1.7499999999999998 after arithmetic — would queue a
    /// write that can never succeed. Rounding here means the value the user
    /// sees is the value the server accepts.
    private static func clampPlaybackSpeed(_ rate: Double) -> Double {
        let bounded = max(0.25, min(rate, 3.0))
        let steps = ((bounded - 0.25) / 0.05).rounded()
        // Re-rounded to hundredths because 0.05 is not representable in binary:
        // 0.25 + 30 * 0.05 is 1.7500000000000002, which serializes as that.
        let aligned = ((0.25 + steps * 0.05) * 100).rounded() / 100
        return min(3.0, max(0.25, aligned))
    }

    private enum Keys {
        static let preferredQuality = "preferredQuality"
        static let maxBitrateKbps = "playback.maxBitrateKbps"
        static let audioLanguage = "preferredAudioLanguage"
        static let autoSkipIntro = "skipIntros"
        static let autoSkipCredits = "skipCredits"
        static let hdrEnabled = "player.hdrEnabled"
        static let dolbyVisionEnabled = "player.dolbyVisionEnabled"
        static let dvProfile7HDR10Fallback = "player.dvProfile7HDR10Fallback"
        static let seekCacheEnabled = "player.seekCacheEnabled"
        static let subtitleAppearance = "player.subtitleAppearance"
        static let inheritedSubtitleAppearance = "player.inheritedSubtitleAppearance"
        static let subtitleUsesDeviceAppearanceOverride = "player.subtitleUsesDeviceAppearanceOverride"
        static let subtitleMatchesSystemAppearance = "player.subtitleMatchesSystemAppearance"
        static let subtitleFontSize = "player.subtitleFontSize"
        static let subtitleTextColor = "player.subtitleTextColor"
        static let subtitleBorderSize = "player.subtitleBorderSize"
        static let subtitleBorderColor = "player.subtitleBorderColor"
        static let subtitleBackgroundColor = "player.subtitleBackgroundColor"
        static let subtitleBackgroundOpacityPercent = "player.subtitleBackgroundOpacityPercent"
        static let subtitlePosition = "player.subtitlePosition"
        static let audioSyncMs = "player.audioSyncMs"
        static let subtitleSyncMs = "player.subtitleSyncMs"
        static let playbackSpeed = "player.playbackSpeed"
        static let videoGravity = "player.videoGravity"
        static let playerOrientationMode = "player.playerOrientationMode"
        static let autoPlayNextEpisode = "autoPlayNext"
        static let legacyAutoPlayNextEpisode = "player.autoPlayNextEpisode"
        static let nextUpPromptSeconds = "player.nextUpPromptSeconds"
    }
}
