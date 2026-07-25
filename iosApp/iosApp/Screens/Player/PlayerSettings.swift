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

private enum PlayerDeviceSettingKey: String, CaseIterable {
    case preferredQuality = "playback.preferred_quality"
    /// Legacy device-scoped audio language. The spoken-language choice now
    /// lives on the profile (`PUT /profiles/{id}` → `language`), which is
    /// what the server actually reads when it resolves the initial audio
    /// track. The case is kept so `resetAllDeviceSettings()` still deletes
    /// rows written by older builds.
    case audioLanguage = "playback.audio_language"
    case autoSkipIntro = "playback.auto_skip_intro"
    case autoSkipCredits = "playback.auto_skip_credits"
    case autoPlayNext = "playback.auto_play_next"
    case nextUpPromptSeconds = "playback.next_up_prompt_seconds"
    case subtitleAppearance = "subtitle_appearance"
    case hdrEnabled = "player.hdr_enabled"
    case dolbyVisionEnabled = "player.dolby_vision_enabled"
    case dvProfile7HDR10Fallback = "player.dv_profile7_hdr10_fallback"
    case seekCacheEnabled = "player.seek_cache_enabled"
    case playbackSpeed = "player.playback_speed"
    case audioSyncMs = "player.audio_sync_ms"
    case subtitleSyncMs = "player.subtitle_sync_ms"
    case videoGravity = "player.video_gravity"
    case orientationMode = "player.orientation_mode"
}

private enum PendingDeviceSettingValue {
    case set(String)
    case delete
}

@Observable
final class PlayerSettings {
    static let shared = PlayerSettings()

    var preferredQuality: String {
        didSet { defaults.set(preferredQuality, forKey: Self.cacheKey(Keys.preferredQuality)) }
    }

    var autoSkipIntro: Bool {
        didSet { defaults.set(autoSkipIntro, forKey: Self.cacheKey(Keys.autoSkipIntro)) }
    }

    var autoSkipCredits: Bool {
        didSet { defaults.set(autoSkipCredits, forKey: Self.cacheKey(Keys.autoSkipCredits)) }
    }

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
    /// the route planner and pushed into PlayerCore before each load.
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
    private var pendingDeviceSettingValues: [PlayerDeviceSettingKey: PendingDeviceSettingValue] = [:]
    private var isFlushingPendingDeviceSettings = false
    private var needsFlushAfterCurrentFlush = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.preferredQuality: "auto",
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

        preferredQuality = ApplePlaybackQuality.normalizeStoredId(
            defaults.string(forKey: Self.cacheKey(Keys.preferredQuality))
        )
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
    }

    var subtitleBackgroundColorHex: String {
        let alphaByte = max(0, min(255, (subtitleBackgroundOpacityPercent * 255) / 100))
        let rgb = subtitleBackgroundColor.hasPrefix("#")
            ? String(subtitleBackgroundColor.dropFirst())
            : subtitleBackgroundColor
        return "#" + String(format: "%02X", alphaByte) + rgb
    }

    @MainActor
    func refreshFromServer() async {
        applyCachedSettingsForCurrentScope()
        await flushPendingDeviceSettings()

        let scopeID = Self.currentScopeIdentifier
        let legacySnapshot = legacySnapshot()
        let legacySubtitleOverrideEnabled = subtitleUsesDeviceAppearanceOverride

        do {
            let response = try await ContinuumAPI.shared.effectiveSettings(
                keys: PlayerDeviceSettingKey.allCases.map(\.rawValue)
            )
            let effectiveByKey = Dictionary(uniqueKeysWithValues: response.map { ($0.key, $0) })
            applyEffectiveSettings(effectiveByKey)

            if let scopeID, !isMigrationComplete(for: scopeID) {
                let imported = await importLegacySettingsIfNeeded(
                    scopeID: scopeID,
                    legacySnapshot: legacySnapshot,
                    legacySubtitleOverrideEnabled: legacySubtitleOverrideEnabled,
                    effectiveByKey: effectiveByKey
                )
                if imported {
                    // The migration just pushed legacy device-setting values
                    // to the server. Local state already holds those values
                    // (they came from local UserDefaults), so a second
                    // `effectiveSettings` round-trip just to mirror the
                    // server's echo is wasted bandwidth on every session
                    // start until migration completes — and re-applying
                    // those same values overwrites any in-flight local
                    // edits anyway. Drain the queue and mark the migration
                    // done.
                    await flushPendingDeviceSettings()
                    markMigrationComplete(for: scopeID)
                }
            }
        } catch {
            // Keep using the last cached values when offline.
        }
    }

    func setPreferredQuality(_ value: String) {
        let normalized = ApplePlaybackQuality.normalizeStoredId(value)
        preferredQuality = normalized
        enqueueDeviceSetting(.preferredQuality, operation: .set(normalized))
    }

    func setAutoSkipIntro(_ enabled: Bool) {
        autoSkipIntro = enabled
        enqueueDeviceSetting(.autoSkipIntro, operation: .set(boolString(enabled)))
    }

    func setAutoSkipCredits(_ enabled: Bool) {
        autoSkipCredits = enabled
        enqueueDeviceSetting(.autoSkipCredits, operation: .set(boolString(enabled)))
    }

    func setAutoPlayNextEpisode(_ enabled: Bool) {
        autoPlayNextEpisode = enabled
        enqueueDeviceSetting(.autoPlayNext, operation: .set(boolString(enabled)))
    }

    func setNextUpPromptSeconds(_ seconds: Int) {
        let normalized = Self.clampNextUpPromptSeconds(seconds)
        nextUpPromptSeconds = normalized
        enqueueDeviceSetting(.nextUpPromptSeconds, operation: .set(String(normalized)))
    }

    func setHDREnabled(_ enabled: Bool) {
        hdrEnabled = enabled
        enqueueDeviceSetting(.hdrEnabled, operation: .set(boolString(enabled)))
    }

    func setDolbyVisionEnabled(_ enabled: Bool) {
        dolbyVisionEnabled = enabled
        enqueueDeviceSetting(.dolbyVisionEnabled, operation: .set(boolString(enabled)))
    }

    func setPreferProfile7HDR10Fallback(_ enabled: Bool) {
        preferProfile7HDR10Fallback = enabled
        enqueueDeviceSetting(.dvProfile7HDR10Fallback, operation: .set(boolString(enabled)))
    }

    func setSeekCacheEnabled(_ enabled: Bool) {
        seekCacheEnabled = enabled
        enqueueDeviceSetting(.seekCacheEnabled, operation: .set(boolString(enabled)))
    }

    func setPlaybackSpeed(_ rate: Double) {
        let normalized = max(0.25, min(rate, 3.0))
        playbackSpeed = normalized
        enqueueDeviceSetting(.playbackSpeed, operation: .set(numberString(normalized)))
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        videoGravity = gravity
        enqueueDeviceSetting(.videoGravity, operation: .set(gravity.rawValue))
    }

    func setPlayerOrientationMode(_ mode: PlayerOrientationMode) {
        playerOrientationMode = mode
        enqueueDeviceSetting(.orientationMode, operation: .set(mode.rawValue))
    }

    func setAudioSyncMs(_ milliseconds: Int) {
        audioSyncMs = max(-5000, min(milliseconds, 5000))
        enqueueDeviceSetting(.audioSyncMs, operation: .set(String(audioSyncMs)))
    }

    func setSubtitleSyncMs(_ milliseconds: Int) {
        subtitleSyncMs = max(-10000, min(milliseconds, 10000))
        enqueueDeviceSetting(.subtitleSyncMs, operation: .set(String(subtitleSyncMs)))
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        let sanitized = appearance.sanitized()
        subtitleAppearance = sanitized
        subtitleUsesDeviceAppearanceOverride = true
        // A manual edit takes over from the system-matching source.
        subtitleMatchesSystemAppearance = false
        enqueueDeviceSetting(.subtitleAppearance, operation: .set(sanitized.jsonString))
        await flushPendingDeviceSettings()
    }

    /// Toggle mirroring the device's Subtitles & Captioning accessibility
    /// preferences. Purely local; the saved Silo appearance is untouched
    /// so switching back restores it.
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) {
        guard enabled != subtitleMatchesSystemAppearance else { return }
        if enabled {
            subtitleSystemAppearance = SystemCaptionAppearance.current()
        }
        subtitleMatchesSystemAppearance = enabled
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        guard enabled != subtitleUsesDeviceAppearanceOverride else { return }
        subtitleUsesDeviceAppearanceOverride = enabled
        if enabled {
            enqueueDeviceSetting(.subtitleAppearance, operation: .set(subtitleAppearance.sanitized().jsonString))
            await flushPendingDeviceSettings()
            return
        }

        enqueueDeviceSetting(.subtitleAppearance, operation: .delete)
        await flushPendingDeviceSettings()
        await refreshFromServer()
    }

    @MainActor
    func resetAllDeviceSettings() async {
        await resetDeviceSettings(PlayerDeviceSettingKey.allCases)
    }

    private func resetDeviceSettings(_ keys: [PlayerDeviceSettingKey]) async {
        for key in keys {
            enqueueDeviceSetting(key, operation: .delete)
        }
        await flushPendingDeviceSettings()
        await refreshFromServer()
    }

    @MainActor
    func flushPendingDeviceSettings() async {
        if isFlushingPendingDeviceSettings {
            needsFlushAfterCurrentFlush = true
            return
        }
        isFlushingPendingDeviceSettings = true
        defer {
            isFlushingPendingDeviceSettings = false
            if needsFlushAfterCurrentFlush {
                needsFlushAfterCurrentFlush = false
                Task { @MainActor [weak self] in
                    await self?.flushPendingDeviceSettings()
                }
            }
        }

        for key in PlayerDeviceSettingKey.allCases {
            guard let pendingValue = pendingDeviceSettingValues[key] else { continue }
            do {
                switch pendingValue {
                case .set(let value):
                    try await ContinuumAPI.shared.setDeviceSetting(key: key.rawValue, value: value)
                case .delete:
                    try await ContinuumAPI.shared.deleteDeviceSetting(key: key.rawValue)
                }
                pendingDeviceSettingValues.removeValue(forKey: key)
            } catch {
                continue
            }
        }
    }

    private func enqueueDeviceSetting(_ key: PlayerDeviceSettingKey, operation: PendingDeviceSettingValue) {
        pendingDeviceSettingValues[key] = operation
        Task { @MainActor [weak self] in
            await self?.flushPendingDeviceSettings()
        }
    }

    private func applyEffectiveSettings(_ effectiveByKey: [String: EffectiveSettingResponse]) {
        preferredQuality = ApplePlaybackQuality.normalizeStoredId(
            effectiveString(for: .preferredQuality, in: effectiveByKey, fallback: "auto")
        )
        autoSkipIntro = effectiveBool(for: .autoSkipIntro, in: effectiveByKey, fallback: false)
        autoSkipCredits = effectiveBool(for: .autoSkipCredits, in: effectiveByKey, fallback: false)
        autoPlayNextEpisode = effectiveBool(for: .autoPlayNext, in: effectiveByKey, fallback: true)
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            effectiveInt(for: .nextUpPromptSeconds, in: effectiveByKey, fallback: 30)
        )
        hdrEnabled = effectiveBool(for: .hdrEnabled, in: effectiveByKey, fallback: true)
        dolbyVisionEnabled = effectiveBool(for: .dolbyVisionEnabled, in: effectiveByKey, fallback: true)
        preferProfile7HDR10Fallback = effectiveBool(
            for: .dvProfile7HDR10Fallback,
            in: effectiveByKey,
            fallback: false
        )
        seekCacheEnabled = effectiveBool(
            for: .seekCacheEnabled,
            in: effectiveByKey,
            fallback: true
        )
        playbackSpeed = effectiveDouble(for: .playbackSpeed, in: effectiveByKey, fallback: 1.0)
        audioSyncMs = effectiveInt(for: .audioSyncMs, in: effectiveByKey, fallback: 0)
        subtitleSyncMs = effectiveInt(for: .subtitleSyncMs, in: effectiveByKey, fallback: 0)
        videoGravity = VideoGravity(
            rawValue: effectiveString(for: .videoGravity, in: effectiveByKey, fallback: VideoGravity.fit.rawValue)
        ) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: effectiveString(
                for: .orientationMode,
                in: effectiveByKey,
                fallback: PlayerOrientationMode.landscapeLocked.rawValue
            )
        ) ?? .landscapeLocked

        if let entry = effectiveByKey[PlayerDeviceSettingKey.subtitleAppearance.rawValue] {
            subtitleUsesDeviceAppearanceOverride = entry.hasDeviceOverride
            let effectiveAppearance = SubtitleAppearance.decode(from: entry.effectiveValue)
            if entry.hasDeviceOverride {
                subtitleAppearance = effectiveAppearance
            } else {
                inheritedSubtitleAppearance = effectiveAppearance
            }
        } else {
            subtitleUsesDeviceAppearanceOverride = false
            inheritedSubtitleAppearance = .default
        }
    }

    private func legacySnapshot() -> [PlayerDeviceSettingKey: String] {
        [
            .preferredQuality: ApplePlaybackQuality.normalizeStoredId(
                defaults.string(forKey: Self.cacheKey(Keys.preferredQuality))
                    ?? defaults.string(forKey: Keys.preferredQuality)
            ),
            .autoSkipIntro: boolString(
                Self.cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
            ),
            .autoSkipCredits: boolString(
                Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
            ),
            .autoPlayNext: boolString(
                Self.cachedBool(
                    defaults,
                    key: Keys.autoPlayNextEpisode,
                    legacyKey: Keys.legacyAutoPlayNextEpisode,
                    defaultValue: true
                )
            ),
            .nextUpPromptSeconds: String(
                Self.clampNextUpPromptSeconds(
                    Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
                )
            ),
            .subtitleAppearance: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance))
                ?? defaults.string(forKey: Keys.subtitleAppearance)
                ?? SubtitleAppearance.default.jsonString,
            .hdrEnabled: boolString(
                Self.cachedBool(defaults, key: Keys.hdrEnabled, defaultValue: true)
            ),
            .playbackSpeed: numberString(
                Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
            ),
            .audioSyncMs: String(defaults.integer(forKey: Self.cacheKey(Keys.audioSyncMs))),
            .subtitleSyncMs: String(defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))),
            .videoGravity: defaults.string(forKey: Self.cacheKey(Keys.videoGravity)) ?? VideoGravity.fit.rawValue,
            .orientationMode: defaults.string(forKey: Self.cacheKey(Keys.playerOrientationMode))
                ?? PlayerOrientationMode.landscapeLocked.rawValue,
        ]
    }

    private func applyCachedSettingsForCurrentScope() {
        preferredQuality = ApplePlaybackQuality.normalizeStoredId(
            defaults.string(forKey: Self.cacheKey(Keys.preferredQuality))
        )
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
        playbackSpeed = Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
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

    @MainActor
    private func importLegacySettingsIfNeeded(
        scopeID: String,
        legacySnapshot: [PlayerDeviceSettingKey: String],
        legacySubtitleOverrideEnabled: Bool,
        effectiveByKey: [String: EffectiveSettingResponse]
    ) async -> Bool {
        var importedAny = false

        for key in PlayerDeviceSettingKey.allCases {
            guard let legacyValue = legacySnapshot[key] else { continue }
            guard let entry = effectiveByKey[key.rawValue], !entry.hasDeviceOverride else { continue }
            if key == .subtitleAppearance && !legacySubtitleOverrideEnabled {
                continue
            }
            if legacyValue == entry.effectiveValue {
                continue
            }
            pendingDeviceSettingValues[key] = .set(legacyValue)
            importedAny = true
        }

        if !importedAny {
            markMigrationComplete(for: scopeID)
            return false
        }

        await flushPendingDeviceSettings()
        return pendingDeviceSettingValues.isEmpty
    }

    private func effectiveString(
        for key: PlayerDeviceSettingKey,
        in effectiveByKey: [String: EffectiveSettingResponse],
        fallback: String
    ) -> String {
        effectiveByKey[key.rawValue]?.effectiveValue ?? fallback
    }

    private func effectiveBool(
        for key: PlayerDeviceSettingKey,
        in effectiveByKey: [String: EffectiveSettingResponse],
        fallback: Bool
    ) -> Bool {
        let value = effectiveString(for: key, in: effectiveByKey, fallback: boolString(fallback))
        // Servers return an entry with an empty effectiveValue for keys they
        // have no registry default or stored override for (source "unset").
        // An empty string is never a valid bool, so treat it as absent —
        // otherwise every default-ON toggle flips off on the first refresh
        // against a server that predates the key.
        guard !value.isEmpty else { return fallback }
        return boolValue(value)
    }

    private func effectiveInt(
        for key: PlayerDeviceSettingKey,
        in effectiveByKey: [String: EffectiveSettingResponse],
        fallback: Int
    ) -> Int {
        Int(effectiveString(for: key, in: effectiveByKey, fallback: String(fallback))) ?? fallback
    }

    private func effectiveDouble(
        for key: PlayerDeviceSettingKey,
        in effectiveByKey: [String: EffectiveSettingResponse],
        fallback: Double
    ) -> Double {
        Double(effectiveString(for: key, in: effectiveByKey, fallback: numberString(fallback))) ?? fallback
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

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func boolValue(_ value: String) -> Bool {
        value == "true"
    }

    private func numberString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static var currentScopeIdentifier: String? {
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

    private static func cacheKey(_ baseKey: String) -> String {
        guard let scopeID = currentScopeIdentifier else {
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

    private enum Keys {
        static let preferredQuality = "preferredQuality"
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
