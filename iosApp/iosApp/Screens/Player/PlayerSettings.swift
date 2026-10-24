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

/// How much of the source Aether may buffer ahead of the playhead.
///
/// Maps to `LoadOptions.forwardBufferSegments`, whose unit is one ~4 s HLS
/// segment. The engine clamps to 4...2700; beyond roughly 150 segments the real
/// bound is the session's disk retention budget rather than the count, and 4K
/// HEVC runs about 10 MB per segment — which is why the rungs below stop at a
/// five-minute window before jumping to "as much as safely fits".
///
/// Device-local, and deliberately not a contract key: how much temporary
/// storage a buffer may take is a fact about *this* device's free space, not a
/// preference that should follow the profile onto a phone.
enum BufferAheadMode: String, CaseIterable {
    /// Preserves the historical mapping, which is derived from the synced Seek
    /// Cache toggle rather than chosen here.
    case automatic = "automatic"
    /// The engine's own default window, ~40 s.
    case standard = "standard"
    /// ~5 minutes, for links that drop out for longer than a few seconds.
    case extended = "extended"
    /// Buffer until the session retention budget is full.
    case unlimited = "unlimited"

    /// The segment count to send, or nil for ``automatic`` — which has no count
    /// of its own and defers to the Seek Cache preference at load time.
    var forwardBufferSegments: Int? {
        switch self {
        case .automatic: return nil
        case .standard:  return 10
        case .extended:  return 75
        case .unlimited: return Int.max
        }
    }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .standard:  return "Standard (40 seconds)"
        case .extended:  return "Extended (5 minutes)"
        case .unlimited: return "Unlimited"
        }
    }
}

/// Which deinterlacer Aether uses on the software-decode path.
///
/// Maps to `LoadOptions.deinterlaceMode`. Interlaced MPEG-2, VC-1 and H.264
/// route through software decode because AVPlayer will not deinterlace them, so
/// this is the only place the choice can be made.
///
/// Device-local, and deliberately not a contract key: whether the Metal /
/// VideoToolbox graph is the better deinterlacer is a fact about *this*
/// device's GPU, not a preference that should follow the profile onto another
/// one.
enum DeinterlacePreference: String, CaseIterable {
    /// The engine's own default: try the hardware graph, fall back to CPU bwdif
    /// when the linked FFmpeg build or the runtime has no Metal device.
    case automatic = "auto"
    /// Force the CPU bwdif/yadif path.
    case software = "software"

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .software:  return "Software"
        }
    }
}

/// The output cadence of the hardware deinterlacer.
///
/// Maps to `LoadOptions.deinterlaceFieldRate`. Only the hardware path honours
/// it; the software fallback always emits frame rate, because doubling a CPU
/// bwdif is the wrong trade. Device-local for the same reason as
/// ``DeinterlacePreference``.
enum DeinterlaceFieldRatePreference: String, CaseIterable {
    /// The engine's own default: one output frame per field (25i to 50p,
    /// 29.97i to 59.94p).
    case fullMotion = "field"
    /// One output frame per field pair (25i to 25p).
    case film = "frame"

    var label: String {
        switch self {
        case .fullMotion: return "Full Motion"
        case .film:       return "Film"
        }
    }
}

extension SettingKey {
    /// The settings this client syncs. Generated contract keys, so every key
    /// this client sends is one the server's manifest declares. Most are
    /// saved for this device; subtitle appearance and timing are saved for
    /// the profile unless this device keeps its own.
    ///
    /// Also the order a flush sends them in: `playback.preferred_quality`
    /// precedes `playback.max_bitrate_kbps` so the two axes of one compound
    /// tier always land resolution-first.
    static let playerDeviceSettings: [SettingKey] = [
        .playbackPreferredQuality,
        .playbackMaxBitrateKbps,
        .playbackAudioLanguage,
        .playbackIntroSkipMode,
        .playbackAutoSkipCredits,
        .playbackAutoPlayNext,
        .playbackNextUpPromptSeconds,
        .playbackSubtitleAppearance,
        .playerHdrEnabled,
        .playerDolbyVisionEnabled,
        .playerSeekCacheEnabled,
        .playerPlaybackSpeed,
        .playerSubtitleSyncMs,
        .playerVideoGravity,
        .playerOrientationMode,
    ]

    /// Profile settings the player follows but has no Apple setting for.
    /// `playback.auto_skip_recap` is set from the profile, for example on the
    /// web, so the player never writes or migrates it. The web can still give
    /// this device its own value, which "Use Profile Settings" clears like any
    /// other.
    static let playerFollowedSettings: [SettingKey] = [.playbackAutoSkipRecap]

    /// What a player refresh reads: the synced keys plus the followed ones.
    static let playerReadSettings: [SettingKey] = playerDeviceSettings + playerFollowedSettings

    /// The cellular quality pair (iPhone and iPad), resolution first like the
    /// main pair. Kept out of ``playerReadSettings``: the pair arrived in
    /// manifest revision 20, and a batch fails as a whole on a key the server
    /// does not define, so it is read in a batch of its own once the server
    /// reports that revision. Written at the same scope as the main pair.
    static let playerCellularQualitySettings: [SettingKey] = [
        .playbackCellularPreferredQuality,
        .playbackCellularMaxBitrateKbps,
    ]

    /// `playback.buffering_quality_mode`, read in a batch of its own like the
    /// cellular pair: it arrived in manifest revision 23.
    static let playerBufferingQualitySettings: [SettingKey] = [.playbackBufferingQualityMode]
}

/// A Playback setting the profile can hold as well as this device, so the
/// device can either keep its own value or go back to the profile's.
///
/// The main quality is two settings, one per picker, as on the web: a device
/// can keep its own resolution and still follow the profile's bitrate cap.
/// The cellular quality is one preset stored as two keys, written and cleared
/// together.
enum ProfileBackedPlaybackSetting: CaseIterable {
    case resolution
    case maxBitrate
    /// iPhone and iPad only; see ``PlayerSettings/offersCellularQuality``.
    case cellularQuality
    case audioLanguage
    case introSkipMode
    case autoSkipCredits
    case autoPlayNext
    case nextUpPrompt
    case bufferingQualityMode

    var keys: [SettingKey] {
        switch self {
        case .resolution: return [.playbackPreferredQuality]
        case .maxBitrate: return [.playbackMaxBitrateKbps]
        case .cellularQuality: return SettingKey.playerCellularQualitySettings
        case .bufferingQualityMode: return SettingKey.playerBufferingQualitySettings
        case .audioLanguage: return [.playbackAudioLanguage]
        case .introSkipMode: return [.playbackIntroSkipMode]
        case .autoSkipCredits: return [.playbackAutoSkipCredits]
        case .autoPlayNext: return [.playbackAutoPlayNext]
        case .nextUpPrompt: return [.playbackNextUpPromptSeconds]
        }
    }
}

private extension SettingKey {
    // Short names for the keys this file uses. The generated cases are named
    // after the full dotted key (playbackAutoSkipIntro); these aliases keep the
    // call sites readable without reintroducing a second list of raw strings —
    // each one still resolves to a generated case, so a key removed from the
    // contract fails to compile here.
    static var preferredQuality: SettingKey { .playbackPreferredQuality }
    static var maxBitrateKbps: SettingKey { .playbackMaxBitrateKbps }
    static var cellularPreferredQuality: SettingKey { .playbackCellularPreferredQuality }
    static var cellularMaxBitrateKbps: SettingKey { .playbackCellularMaxBitrateKbps }
    static var audioLanguage: SettingKey { .playbackAudioLanguage }
    static var introSkipMode: SettingKey { .playbackIntroSkipMode }
    static var bufferingQualityMode: SettingKey { .playbackBufferingQualityMode }
    static var autoSkipCredits: SettingKey { .playbackAutoSkipCredits }
    static var autoSkipRecap: SettingKey { .playbackAutoSkipRecap }
    static var autoPlayNext: SettingKey { .playbackAutoPlayNext }
    static var nextUpPromptSeconds: SettingKey { .playbackNextUpPromptSeconds }
    static var subtitleAppearance: SettingKey { .playbackSubtitleAppearance }
    static var hdrEnabled: SettingKey { .playerHdrEnabled }
    static var dolbyVisionEnabled: SettingKey { .playerDolbyVisionEnabled }
    static var seekCacheEnabled: SettingKey { .playerSeekCacheEnabled }
    static var playbackSpeed: SettingKey { .playerPlaybackSpeed }
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
    private(set) var preferredQualityResolution: String {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(preferredQualityResolution, forKey: Self.cacheKey(Keys.preferredQuality))
        }
    }

    /// The bandwidth half of the quality preference; nil is uncapped.
    private(set) var maxBitrateKbps: Int? {
        didSet {
            guard !isLoadingCache else { return }
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

    /// A user-facing label for the stored pair, in the terms of the two
    /// pickers that set it ("1080p at 10 Mbps") rather than a preset name.
    var preferredQualityLabel: String {
        SiloQualityPresets.describeAxes(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    /// Whether this platform offers the cellular quality pair. iPhone and
    /// iPad only: an Apple TV or a Mac is not on mobile data, and the
    /// contract lists only the phone platforms for the two keys.
    static var offersCellularQuality: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The contract default for the cellular pair: the 720p preset.
    /// `SettingsConformanceTests` pins it to the vendored manifest.
    static let defaultCellularQuality = AppleQualityAxes(resolution: "720p", bitrateKbps: 2_000)

    /// The resolution half of the cellular pair, a member of
    /// `playback.cellular_preferred_quality`.
    ///
    /// Playback uses this pair instead of the main one on mobile data, a
    /// hotspot, or in Low Data Mode. On a server older than manifest revision
    /// 20 the pair is kept on this device only, and still applied.
    private(set) var cellularQualityResolution: String {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(cellularQualityResolution, forKey: Self.cacheKey(Keys.cellularPreferredQuality))
        }
    }

    /// The bandwidth half of the cellular pair; nil is uncapped.
    private(set) var cellularMaxBitrateKbps: Int? {
        didSet {
            guard !isLoadingCache else { return }
            // Unlike the main cap, an absent value is the contract default
            // (2000 kbps), so uncapped is stored as 0.
            defaults.set(cellularMaxBitrateKbps ?? 0, forKey: Self.cacheKey(Keys.cellularMaxBitrateKbps))
        }
    }

    var cellularQualityAxes: AppleQualityAxes {
        AppleQualityAxes(resolution: cellularQualityResolution, bitrateKbps: cellularMaxBitrateKbps)
    }

    /// The shared preset the cellular pair corresponds to, or nil for a pair
    /// no preset covers (set through the API or by another client).
    var currentCellularQualityPreset: SiloQualityPreset? {
        SiloQualityPresets.preset(resolution: cellularQualityResolution, bitrateKbps: cellularMaxBitrateKbps)
    }

    /// A user-facing label for the cellular pair, preset or not.
    var cellularQualityLabel: String {
        SiloQualityPresets.describe(resolution: cellularQualityResolution, bitrateKbps: cellularMaxBitrateKbps)
    }

    /// The pair playback asks for on the current connection: the cellular
    /// pair on a metered one (see ``PlaybackNetworkPath``), the main pair
    /// otherwise.
    func playbackQualityAxes(onMeteredNetwork: Bool) -> AppleQualityAxes {
        guard onMeteredNetwork, Self.offersCellularQuality else {
            return AppleQualityAxes(resolution: preferredQualityResolution, bitrateKbps: maxBitrateKbps)
        }
        return cellularQualityAxes
    }

    private(set) var audioLanguage: String {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(audioLanguage, forKey: Self.cacheKey(Keys.audioLanguage))
        }
    }

    /// Deployment-observed choices returned with the effective audio setting.
    /// The UI unions these with the generated contract floor and current value.
    private(set) var audioLanguageSuggestions: [String] = []

    /// What the player does when an intro starts — `playback.intro_skip_mode`.
    private(set) var introSkipMode: IntroSkipMode {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(introSkipMode.wireValue, forKey: Self.cacheKey(Keys.introSkipMode))
        }
    }

    /// The deprecated `playback.auto_skip_intro`, projected from
    /// ``introSkipMode`` so the two can never disagree locally.
    var autoSkipIntro: Bool { introSkipMode.legacyAutoSkip }

    /// What the player does on Auto when playback keeps buffering —
    /// `playback.buffering_quality_mode`. On a server without the setting it
    /// is the contract default (see ``serverLacksBufferingQualityMode``).
    private(set) var bufferingQualityMode: BufferingQualityMode {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(bufferingQualityMode.wireValue, forKey: Self.cacheKey(Keys.bufferingQualityMode))
        }
    }

    private(set) var autoSkipCredits: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(autoSkipCredits, forKey: Self.cacheKey(Keys.autoSkipCredits))
        }
    }

    /// `playback.auto_skip_recap`, followed from the effective settings read.
    /// Read only: Apple has no player setting for it.
    private(set) var autoSkipRecap: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(autoSkipRecap, forKey: Self.cacheKey(Keys.autoSkipRecap))
        }
    }

    private(set) var hdrEnabled: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(hdrEnabled, forKey: Self.cacheKey(Keys.hdrEnabled))
        }
    }

    /// When off, Dolby Vision sources with a compatible base layer play as
    /// plain HDR10/HLG instead. Profile 5 has no such base layer and always
    /// plays in Dolby Vision.
    private(set) var dolbyVisionEnabled: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(dolbyVisionEnabled, forKey: Self.cacheKey(Keys.dolbyVisionEnabled))
        }
    }

    /// Retained as the cross-client buffering preference. Aether owns the
    /// cache implementation; the adapter maps this preference without
    /// constructing a Silo source cache.
    private(set) var seekCacheEnabled: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(seekCacheEnabled, forKey: Self.cacheKey(Keys.seekCacheEnabled))
        }
    }

    /// Device-local: when true, codecs Aether cannot stream-copy (TrueHD,
    /// DTS-HD MA, and friends) are bridged as FLAC up to 7.1 and decoded to
    /// multichannel LPCM instead of a lossy E-AC-3 rendition capped at 5.1.
    ///
    /// Never synced to the server, and deliberately not a contract key: it
    /// describes what *this* device's audio sink accepts over eARC, which is a
    /// fact about the room rather than a preference that should follow the
    /// profile onto a phone. Default on, which is the bridge the previous
    /// engine always used.
    private(set) var losslessAudioEnabled: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(losslessAudioEnabled, forKey: Self.cacheKey(Keys.losslessAudioEnabled))
        }
    }

    /// Device-local: when true, video playback keeps running as the app leaves
    /// the foreground — Picture in Picture and background audio on iOS, the
    /// PiP keepalive on tvOS. When false the engine tears the session down as
    /// soon as the app is backgrounded, so audio stops with the app.
    ///
    /// Never synced to the server, and deliberately not a contract key: whether
    /// leaving the app should keep a video's audio going is a habit of *this*
    /// device, not a preference that should follow the profile onto a TV.
    /// Default on, which is Aether's own default. Audiobooks are unaffected —
    /// their controller never reads this and always keeps playing.
    private(set) var backgroundPlaybackEnabled: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(
                backgroundPlaybackEnabled,
                forKey: Self.cacheKey(Keys.backgroundPlaybackEnabled)
            )
        }
    }

    /// Device-local: how far ahead of the playhead Aether may buffer.
    ///
    /// Never synced to the server, and deliberately not a contract key — see
    /// ``BufferAheadMode``. Default ``BufferAheadMode/automatic``, which keeps
    /// the historical behaviour of deriving the window from ``seekCacheEnabled``.
    private(set) var bufferAhead: BufferAheadMode {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(bufferAhead.rawValue, forKey: Self.cacheKey(Keys.bufferAhead))
        }
    }

    /// Device-local: which deinterlacer runs on interlaced sources.
    ///
    /// Never synced to the server, and deliberately not a contract key — see
    /// ``DeinterlacePreference``. Default ``DeinterlacePreference/automatic``,
    /// which is Aether's own default, so nothing changes until a user picks.
    private(set) var deinterlaceMode: DeinterlacePreference {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(deinterlaceMode.rawValue, forKey: Self.cacheKey(Keys.deinterlaceMode))
        }
    }

    /// Device-local: whether TrueHD Atmos and DTS:X tracks keep their heights.
    /// Maps to `LoadOptions.objectAudioRendering` through
    /// ``AetherObjectAudioPolicy``: Aether decodes the Atmos objects exactly,
    /// renders them into a 7.1.4 bed (DTS:X: its four heights one to one) and
    /// delivers Apple Positional Audio, which an Atmos receiver or soundbar
    /// gets as Dolby Atmos and AirPods or the built-in speakers render as
    /// Spatial Audio. The trade is a compressed stream in place of
    /// lossless 7.1, so a setup without Atmos is better with it off.
    ///
    /// Never synced to the server: what this device plays into is a fact about
    /// the room or the headphones, not the profile. Default on.
    private(set) var trueHDAtmosEnabled: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(trueHDAtmosEnabled, forKey: Self.cacheKey(Keys.trueHDAtmosEnabled))
        }
    }

    /// Device-local: the hardware deinterlacer's output cadence.
    ///
    /// Never synced to the server, and deliberately not a contract key — see
    /// ``DeinterlaceFieldRatePreference``. Default
    /// ``DeinterlaceFieldRatePreference/fullMotion``, which is Aether's own
    /// default.
    private(set) var deinterlaceFieldRate: DeinterlaceFieldRatePreference {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(
                deinterlaceFieldRate.rawValue,
                forKey: Self.cacheKey(Keys.deinterlaceFieldRate)
            )
        }
    }

    /// This device's own appearance (`profile_device`), used while
    /// ``subtitleUsesDeviceAppearanceOverride`` is on.
    private(set) var deviceSubtitleAppearance: SubtitleAppearance {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(
                deviceSubtitleAppearance.sanitized().jsonString,
                forKey: Self.cacheKey(Keys.subtitleAppearance)
            )
        }
    }

    /// The profile's appearance (or the contract default), which every device
    /// of the profile uses unless it keeps its own.
    private var inheritedSubtitleAppearance: SubtitleAppearance {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(
                inheritedSubtitleAppearance.sanitized().jsonString,
                forKey: Self.cacheKey(Keys.inheritedSubtitleAppearance)
            )
        }
    }

    private(set) var subtitleUsesDeviceAppearanceOverride: Bool {
        didSet {
            guard !isLoadingCache else { return }
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
    private(set) var subtitleMatchesSystemAppearance: Bool {
        didSet {
            guard !isLoadingCache else { return }
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

    /// The Silo appearance in effect on this device: its own while the
    /// device override is on, otherwise the profile's. Every appearance editor
    /// starts from this, so an edit never starts from a stale device copy.
    var subtitleAppearance: SubtitleAppearance {
        subtitleUsesDeviceAppearanceOverride ? deviceSubtitleAppearance : inheritedSubtitleAppearance
    }

    /// The appearance the player should actually render with.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        subtitleMatchesSystemAppearance ? subtitleSystemAppearance : subtitleAppearance
    }

    /// Where a subtitle display edit (appearance or timing) is saved: this
    /// device only while its override is on, otherwise the profile.
    var subtitleDisplayWriteScope: PlayerSettingWriteScope {
        subtitleUsesDeviceAppearanceOverride ? .profileDevice : .profile
    }

    private(set) var subtitleSyncMs: Int {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(subtitleSyncMs, forKey: Self.cacheKey(Keys.subtitleSyncMs))
        }
    }

    private(set) var playbackSpeed: Double {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(playbackSpeed, forKey: Self.cacheKey(Keys.playbackSpeed))
        }
    }

    private(set) var videoGravity: VideoGravity {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(videoGravity.rawValue, forKey: Self.cacheKey(Keys.videoGravity))
        }
    }

    private(set) var playerOrientationMode: PlayerOrientationMode {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(playerOrientationMode.rawValue, forKey: Self.cacheKey(Keys.playerOrientationMode))
        }
    }

    private(set) var autoPlayNextEpisode: Bool {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(autoPlayNextEpisode, forKey: Self.cacheKey(Keys.autoPlayNextEpisode))
        }
    }

    private(set) var nextUpPromptSeconds: Int {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(nextUpPromptSeconds, forKey: Self.cacheKey(Keys.nextUpPromptSeconds))
        }
    }

    /// Synced keys this device holds its own `profile_device` value for.
    ///
    /// Read from each resolved row's scope, and kept current by the setters
    /// and clears below so the settings screens can tell "this device's own
    /// value" from "the value it inherits" without waiting for a round trip.
    /// Cached per scope like the values themselves, so an offline launch
    /// shows the same answer the last refresh did.
    private(set) var deviceOverriddenKeys: Set<SettingKey> {
        didSet {
            defaults.set(
                deviceOverriddenKeys.map(\.rawValue).sorted(),
                forKey: Self.cacheKey(Keys.deviceOverriddenKeys)
            )
        }
    }

    private let defaults: UserDefaults

    /// Set while ``applyCachedSettingsForCurrentScope()`` loads the cache.
    ///
    /// Every property above persists itself when set, and loading a key the
    /// store does not hold assigns its fallback default. Written back, that
    /// default would look like a value this device stored, and the one-time
    /// legacy import would push it to the server as a device override that
    /// hides the profile's own value.
    @ObservationIgnored private var isLoadingCache = false

    /// Debounced writer for the canonical settings API. Owns the queue, the
    /// retry schedule and the held changes; see PlayerSettingsFlusher.swift.
    private let flusher: PlayerSettingsFlusher

    /// The active settings scope, as ``currentScopeIdentifier`` reports it.
    /// Injectable so tests can change scope while a read is in flight.
    @ObservationIgnored private let scopeIdentifier: () -> String?

    /// Device settings whose latest change ran out of automatic retries. The
    /// change stays on this device and is not sent again until the user
    /// retries or discards it (owner decision D4).
    private(set) var heldDeviceSettingKeys: [SettingKey] = []

    /// Set when the server definitively refused a device setting change.
    /// The change was dropped; the settings screen says so once.
    private(set) var rejectedDeviceSettingChange = false

    /// Designated initializer, non-private so tests can build an instance with
    /// an isolated `UserDefaults` and a fake transport rather than reaching for
    /// the singleton (which would leak state between tests and hit the
    /// network).
    init(
        defaults: UserDefaults = .standard,
        flusher: PlayerSettingsFlusher = PlayerSettingsFlusher(),
        scopeIdentifier: @escaping () -> String? = { PlayerSettings.currentScopeIdentifier }
    ) {
        self.defaults = defaults
        self.flusher = flusher
        self.scopeIdentifier = scopeIdentifier
        // No `register(defaults:)`: every read below supplies its own
        // fallback, and a registered value is indistinguishable from a stored
        // one. The legacy import must only see values this device stored.

        preferredQualityResolution = Self.cachedQualityResolution(defaults)
        maxBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
        let cellular = Self.cachedCellularQuality(defaults)
        cellularQualityResolution = cellular.resolution
        cellularMaxBitrateKbps = cellular.bitrateKbps
        audioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage)) ?? ""
        introSkipMode = Self.cachedIntroSkipMode(defaults)
        bufferingQualityMode = Self.cachedBufferingQualityMode(defaults)
        serverLacksBufferingQualityMode = defaults.bool(forKey: Self.cacheKey(Keys.bufferingQualityModeUndefined))
        autoSkipCredits = Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
        autoSkipRecap = Self.cachedBool(defaults, key: Keys.autoSkipRecap, defaultValue: false)
        hdrEnabled = Self.cachedBool(defaults, key: Keys.hdrEnabled, defaultValue: true)
        dolbyVisionEnabled = Self.cachedBool(defaults, key: Keys.dolbyVisionEnabled, defaultValue: true)
        seekCacheEnabled = Self.cachedBool(
            defaults,
            key: Keys.seekCacheEnabled,
            defaultValue: true
        )
        losslessAudioEnabled = Self.cachedBool(
            defaults,
            key: Keys.losslessAudioEnabled,
            defaultValue: true
        )
        backgroundPlaybackEnabled = Self.cachedBool(
            defaults,
            key: Keys.backgroundPlaybackEnabled,
            defaultValue: true
        )
        bufferAhead = Self.cachedBufferAhead(defaults)
        deinterlaceMode = Self.cachedDeinterlaceMode(defaults)
        deinterlaceFieldRate = Self.cachedDeinterlaceFieldRate(defaults)
        trueHDAtmosEnabled = Self.cachedBool(
            defaults,
            key: Keys.trueHDAtmosEnabled,
            defaultValue: true
        )
        deviceSubtitleAppearance = SubtitleAppearance.decode(from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance)))
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
        deviceOverriddenKeys = Self.cachedOverriddenKeys(defaults)

        flusher.observeHeldKeys { [weak self] keys in
            Task { @MainActor in self?.heldDeviceSettingKeys = keys }
        }
        flusher.observeRejections { [weak self] _ in
            Task { @MainActor in self?.rejectedDeviceSettingChange = true }
        }

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

    /// The connected server's manifest revision, as last reported by a batched
    /// effective-values read. `nil` until this scope's refresh succeeds.
    ///
    /// Mirrors ``PlayerSettingsFlusher/knownManifestRevision`` so settings
    /// screens can observe it; the flusher's copy is the one that decides what
    /// a write carries (see ``SettingKey/revisionGatedMembers``).
    private(set) var knownManifestRevision: Int?

    /// The settings scope ``knownManifestRevision`` was read for ("" when no
    /// scope was active), or nil when no revision is known.
    private var manifestRevisionScopeID: String?

    /// The server's settings answered that `playback.buffering_quality_mode`
    /// is not a key they define. Such a server plays `always`, so the player
    /// uses the default and Settings hides the row. Decided by the key, not
    /// the manifest revision, and kept per scope until a read answers the key,
    /// so a switch back to that server or profile, or a launch offline,
    /// remembers it.
    private(set) var serverLacksBufferingQualityMode = false {
        didSet {
            guard !isLoadingCache else { return }
            defaults.set(serverLacksBufferingQualityMode, forKey: Self.cacheKey(Keys.bufferingQualityModeUndefined))
        }
    }

    /// Whether to offer the subtitle text opacity control. Hidden only when the
    /// server is known to predate the member: such a server never receives it,
    /// so the choice would not survive the next refresh.
    var offersSubtitleTextOpacity: Bool {
        guard let knownManifestRevision else { return true }
        return knownManifestRevision >= SettingKey.subtitleTextOpacityRevision
    }

    /// Pull every synced setting from the server and adopt it.
    ///
    /// One batched call: the server resolves every key in
    /// `playerDeviceSettingKeys` in a single store read, and asking per key
    /// would be one round trip per key on every app launch, profile switch and
    /// settings-screen open.
    @discardableResult
    @MainActor
    func refreshFromServer() async -> RefreshResult {
        // This instance survives server and profile switches, so a revision
        // confirmed for the previous scope must not leak into the next one.
        // Until this scope's read records its own, a write whose payload
        // depends on the revision waits in the queue rather than being sent
        // with a guess — including through the pending-writes flush below.
        // The same scope keeps its revision, so a refresh that fails offline
        // does not hold every later subtitle appearance write.
        let refreshScopeID = scopeIdentifier() ?? ""
        if refreshScopeID != manifestRevisionScopeID {
            flusher.forgetManifestRevision()
            knownManifestRevision = nil
            manifestRevisionScopeID = nil
        }

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

        let scopeID = scopeIdentifier()

        do {
            let response = try await flusher.effectiveValues(keys: SettingKey.playerReadSettings)
            knownManifestRevision = flusher.knownManifestRevision
            // The read goes to whichever scope is active when it is sent. If the
            // scope changed while this refresh awaited, the revision belongs to
            // that other scope, so it is not kept for this one.
            let scopeUnchanged = (scopeIdentifier() ?? "") == refreshScopeID
            manifestRevisionScopeID = knownManifestRevision != nil && scopeUnchanged ? refreshScopeID : nil
            var effectiveByKey = response.byKey
            // A failed cellular or buffering read keeps this device's values
            // for those keys.
            let cellular = (try? await cellularQualityValues(atRevision: response.revision)) ?? [:]
            let buffering = await bufferingQualityValues()
            // Applying caches under the scope active now. If it changed while
            // any read awaited, no response belongs to it, so nothing is
            // adopted; that scope's own refresh paints its values.
            guard (scopeIdentifier() ?? "") == refreshScopeID else { return .unavailable }
            effectiveByKey.merge(cellular) { _, cellularValue in cellularValue }
            effectiveByKey.merge(adopt(buffering) ?? [:]) { _, bufferingValue in bufferingValue }
            applyEffectiveSettings(overlayingUnsettledValues(on: effectiveByKey))

            if let scopeID, !isMigrationComplete(for: scopeID) {
                let imported = await importLegacySettingsIfNeeded(
                    scopeID: scopeID,
                    legacySnapshot: legacySnapshot,
                    effectiveByKey: effectiveByKey
                )
                if imported {
                    // Migration just pushed this device's legacy values; skip
                    // a second effective read and only drain the queue.
                    await flushPendingDeviceSettings()
                    markMigrationComplete(for: scopeID)
                }
            }
            // A write that waited because it was made while the revision was
            // unknown can go now. Only after the migration, whose "is anything
            // owed" check must still see it as unsettled.
            if flusher.hasRevisionGatedWrites {
                await flushPendingDeviceSettings()
            }
            if await clearLeftoverDeviceSubtitleOffsetIfNeeded(scopeID: refreshScopeID) {
                // Repaint with the offset this device now inherits. The clear
                // is decided once per scope, so this does not recurse again.
                await refreshFromServer()
            }
            return .refreshed
        } catch SettingsAPIError.serverUpgradeRequired {
            return .serverUpgradeRequired
        } catch {
            // Keep using the last cached values when offline.
            return .unavailable
        }
    }

    /// The cellular pair's rows, or none when this platform does not offer the
    /// pair or the server predates it. A missing row keeps this device's own
    /// value (see ``applyEffectiveSettings(_:)``). Read in its own batch, since
    /// a server rejects a batch that names a key it does not know.
    @MainActor
    private func cellularQualityValues(atRevision revision: Int) async throws -> [SettingKey: EffectiveSettingValue] {
        let keys = SettingKey.playerCellularQualitySettings
        guard Self.offersCellularQuality,
              keys.allSatisfy({ $0.isServed(atRevision: revision) }) else {
            return [:]
        }
        return try await flusher.effectiveValues(keys: keys).byKey.filter { keys.contains($0.key) }
    }

    /// What reading `playback.buffering_quality_mode` found.
    private enum BufferingQualityRead {
        /// The server defines the key; its row, if it sent one.
        case served([SettingKey: EffectiveSettingValue])
        /// The server's settings do not define the key.
        case notDefined
        /// The read failed for another reason, which says nothing either way.
        case unread
    }

    /// `playback.buffering_quality_mode`'s row, read in its own batch for the
    /// same reason as the cellular pair. Asked of every server rather than
    /// gated on the manifest revision: whether the server has the setting is
    /// decided by whether it knows the key. A missing row keeps this device's
    /// own value.
    @MainActor
    private func bufferingQualityValues() async -> BufferingQualityRead {
        let keys = SettingKey.playerBufferingQualitySettings
        do {
            return .served(try await flusher.effectiveValues(keys: keys).byKey.filter { keys.contains($0.key) })
        } catch let error as SettingsAPIError where error.isUnknownKeyAnswer {
            return .notDefined
        } catch {
            return .unread
        }
    }

    /// Records whether the server has the setting, and returns its rows to
    /// apply: none where it has no setting, nil when the read failed.
    @MainActor
    private func adopt(_ read: BufferingQualityRead) -> [SettingKey: EffectiveSettingValue]? {
        switch read {
        case .served(let rows):
            serverLacksBufferingQualityMode = false
            return rows
        case .notDefined:
            serverLacksBufferingQualityMode = true
            return [:]
        case .unread:
            return nil
        }
    }

    /// Set the quality from a shared preset; the settings screens set each
    /// axis on its own. A preset names both axes, so both are written:
    /// leaving a stale cap behind would keep throttling a tier the user just
    /// widened, which is also why uncapped is an explicit JSON null.
    func setQualityPreset(_ preset: SiloQualityPreset) {
        setQualityResolution(preset.resolution)
        setMaxBitrateKbps(preset.bitrateKbps)
    }

    /// The Resolution picker: writes only `playback.preferred_quality`, so the
    /// bitrate cap keeps following wherever it comes from (this device's own
    /// value or the profile's), as on the web.
    func setQualityResolution(_ resolution: String) {
        preferredQualityResolution = SiloQualityPresets.normalizeResolution(resolution)
        enqueueDeviceValue(.preferredQuality, value: .string(preferredQualityResolution))
    }

    /// The Maximum Bitrate picker: writes only `playback.max_bitrate_kbps`.
    /// "No limit" (nil) is an explicit JSON null, so it holds over a cap the
    /// profile sets; "Use Profile Setting" is the way back to that cap.
    func setMaxBitrateKbps(_ bitrateKbps: Int?) {
        maxBitrateKbps = bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
        enqueueDeviceValue(.maxBitrateKbps, value: maxBitrateKbps.map { .int($0) } ?? .null)
    }

    /// Set the cellular pair from a shared preset. Saved at the same scope as
    /// the main pair; against a server older than revision 20 the flusher
    /// keeps it on this device until the server serves the keys.
    func setCellularQualityPreset(_ preset: SiloQualityPreset) {
        cellularQualityResolution = SiloQualityPresets.normalizeResolution(preset.resolution)
        cellularMaxBitrateKbps = preset.bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
        enqueueDeviceValue(.cellularPreferredQuality, value: .string(cellularQualityResolution))
        enqueueDeviceValue(
            .cellularMaxBitrateKbps,
            value: cellularMaxBitrateKbps.map { .int($0) } ?? .null
        )
    }

    /// The empty string is "no preference", which is not a value this device
    /// stores: it clears the device's own language so the profile's applies
    /// again. Storing it — as JSON null, since the contract's language_tag
    /// rejects "" — would pin "no preference" here and hide the profile's
    /// language from this device. The language the profile resolves to is
    /// only known once the clear lands; ``useProfileSetting(_:)`` reads it.
    func setAudioLanguage(_ value: String) {
        audioLanguage = value
        if value.isEmpty {
            enqueueDeviceClear(.audioLanguage)
        } else {
            enqueueDeviceValue(.audioLanguage, value: .string(value))
        }
    }

    /// Writes only the enum, never the deprecated boolean beside it.
    ///
    /// The server mirrors the pair at write time, and its boolean -> enum
    /// direction is lossy (`false` means `ask`): sending both would let the
    /// boolean's mirror land second and rewrite a `never` the viewer just chose.
    func setIntroSkipMode(_ mode: IntroSkipMode) {
        introSkipMode = mode
        enqueueDeviceValue(.introSkipMode, value: .string(mode.wireValue))
    }

    /// Saved for this device like ``setIntroSkipMode(_:)``. Settings offers it
    /// only where the server has the setting.
    func setBufferingQualityMode(_ mode: BufferingQualityMode) {
        // A picker opened before the read that found no setting stores nothing.
        guard !serverLacksBufferingQualityMode else { return }
        bufferingQualityMode = mode
        enqueueDeviceValue(.bufferingQualityMode, value: .string(mode.wireValue))
    }

    func setAutoSkipCredits(_ enabled: Bool) {
        autoSkipCredits = enabled
        enqueueDeviceValue(.autoSkipCredits, value: .bool(enabled))
    }

    func setAutoPlayNextEpisode(_ enabled: Bool) {
        autoPlayNextEpisode = enabled
        enqueueDeviceValue(.autoPlayNext, value: .bool(enabled))
    }

    func setNextUpPromptSeconds(_ seconds: Int) {
        let normalized = Self.clampNextUpPromptSeconds(seconds)
        nextUpPromptSeconds = normalized
        enqueueDeviceValue(.nextUpPromptSeconds, value: .int(normalized))
    }

    func setHDREnabled(_ enabled: Bool) {
        hdrEnabled = enabled
        enqueueDeviceValue(.hdrEnabled, value: .bool(enabled))
    }

    func setDolbyVisionEnabled(_ enabled: Bool) {
        dolbyVisionEnabled = enabled
        enqueueDeviceValue(.dolbyVisionEnabled, value: .bool(enabled))
    }

    func setSeekCacheEnabled(_ enabled: Bool) {
        seekCacheEnabled = enabled
        enqueueDeviceValue(.seekCacheEnabled, value: .bool(enabled))
    }

    /// Choose the bridge Aether uses for non-stream-copyable audio codecs.
    /// Purely local — there is no contract key to enqueue.
    func setLosslessAudioEnabled(_ enabled: Bool) {
        losslessAudioEnabled = enabled
    }

    /// Choose whether video playback survives leaving the app. Purely local —
    /// there is no contract key to enqueue.
    func setBackgroundPlaybackEnabled(_ enabled: Bool) {
        backgroundPlaybackEnabled = enabled
    }

    /// Choose how far ahead Aether buffers. Purely local — there is no contract
    /// key to enqueue.
    func setBufferAhead(_ mode: BufferAheadMode) {
        bufferAhead = mode
    }

    /// Choose the deinterlacer for interlaced sources. Purely local — there is
    /// no contract key to enqueue.
    func setDeinterlaceMode(_ mode: DeinterlacePreference) {
        deinterlaceMode = mode
    }

    /// Choose whether TrueHD Atmos and DTS:X keep their heights. Purely local —
    /// there is no contract key to enqueue.
    func setTrueHDAtmosEnabled(_ enabled: Bool) {
        trueHDAtmosEnabled = enabled
    }

    /// Choose the hardware deinterlacer's output cadence. Purely local — there
    /// is no contract key to enqueue.
    func setDeinterlaceFieldRate(_ rate: DeinterlaceFieldRatePreference) {
        deinterlaceFieldRate = rate
    }

    func setPlaybackSpeed(_ rate: Double) {
        let normalized = Self.clampPlaybackSpeed(rate)
        playbackSpeed = normalized
        enqueueDeviceValue(.playbackSpeed, value: .double(normalized))
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        videoGravity = gravity
        enqueueDeviceValue(.videoGravity, value: .string(gravity.rawValue))
    }

    func setPlayerOrientationMode(_ mode: PlayerOrientationMode) {
        playerOrientationMode = mode
        enqueueDeviceValue(.orientationMode, value: .string(mode.rawValue))
    }

    /// Saved like the appearance: for the profile, unless this device keeps
    /// its own subtitle display settings. A server older than manifest
    /// revision 19 only stores the offset per device, so there it stays a
    /// device value; while the revision is unknown the flusher decides at send
    /// time.
    func setSubtitleSyncMs(_ milliseconds: Int) {
        subtitleSyncMs = max(-10000, min(milliseconds, 10000))
        let value = SettingJSONValue.int(subtitleSyncMs)
        if subtitleDisplayWriteScope == .profileDevice || !serverAcceptsProfileScope(for: .subtitleSyncMs) {
            enqueueDeviceValue(.subtitleSyncMs, value: value)
        } else {
            enqueueProfileValue(.subtitleSyncMs, value: value)
        }
    }

    /// Applies an appearance edit and queues it for the server; the flusher's
    /// debounce sends it. `setSubtitleAppearance(_:)` is this plus an
    /// immediate flush.
    ///
    /// Saved for the profile, so it follows the profile to every device,
    /// unless this device keeps its own appearance (the device override is
    /// on), in which case only this device's value changes.
    func stageSubtitleAppearance(_ appearance: SubtitleAppearance) {
        let sanitized = appearance.sanitized()
        // A manual edit takes over from the system-matching source.
        subtitleMatchesSystemAppearance = false
        if subtitleUsesDeviceAppearanceOverride {
            deviceSubtitleAppearance = sanitized
        } else {
            inheritedSubtitleAppearance = sanitized
        }
        enqueueSubtitleAppearance(sanitized, scope: subtitleDisplayWriteScope)
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        stageSubtitleAppearance(appearance)
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

    /// Turn this device's own subtitle display settings on or off.
    ///
    /// On: the device keeps a copy of the appearance on screen now, and later
    /// appearance and timing edits change only this device. Off: this
    /// device's own values are deleted so the profile's apply again.
    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        guard enabled != subtitleUsesDeviceAppearanceOverride else { return }
        if enabled {
            // Start from what is on screen, not from a device copy cached by
            // an earlier override, so turning this on changes nothing visible.
            let current = inheritedSubtitleAppearance.sanitized()
            deviceSubtitleAppearance = current
            subtitleUsesDeviceAppearanceOverride = true
            enqueueSubtitleAppearance(current, scope: .profileDevice)
            await flushPendingDeviceSettings()
            return
        }

        subtitleUsesDeviceAppearanceOverride = false
        var cleared: [SettingKey] = [.subtitleAppearance]
        // The device's own offset goes too, but only where the profile can
        // hold one: on an older server the device value is the only offset.
        // Before the revision is known (an offline launch) the flusher makes
        // that call once a read reports it. Sent whether or not
        // ``deviceOverriddenKeys`` lists it, for the reason
        // ``enqueueProfileValue(_:value:)`` gives; no device offset is success.
        let clearsOffset = serverAcceptsProfileScope(for: .subtitleSyncMs)
        if clearsOffset {
            cleared.append(.subtitleSyncMs)
        }
        // A first refresh for this scope must not import these keys straight
        // back as device values.
        if let scopeID = scopeIdentifier() {
            retireMigration(of: cleared, for: scopeID)
        }
        enqueueDeviceClear(.subtitleAppearance)
        if clearsOffset {
            deviceOverriddenKeys.remove(.subtitleSyncMs)
            flusher.enqueueDelete(.subtitleSyncMs, onlyWhereProfileScoped: true)
        }
        await flushPendingDeviceSettings()
        await refreshFromServer()
    }

    /// Clear a subtitle offset an older build left on this device, once per
    /// settings scope. Those builds saved every Delay change as this device's
    /// own value without turning the device override on, so on a server that
    /// stores the offset per profile it kept hiding the profile's offset while
    /// the screen said the profile's applied. A device that keeps its own
    /// subtitle settings (the override is on) keeps its offset.
    ///
    /// Decided only from a read of a revision 19 or later server for this
    /// scope. The clear goes through the journal like any other, so a failed
    /// request is retried, and a newer offset edit replaces it. Returns true
    /// when the clear reached the server.
    @MainActor
    private func clearLeftoverDeviceSubtitleOffsetIfNeeded(scopeID: String) async -> Bool {
        let doneKey = Self.leftoverSubtitleOffsetClearKey(for: scopeID)
        guard !defaults.bool(forKey: doneKey),
              (scopeIdentifier() ?? "") == scopeID,
              manifestRevisionScopeID == scopeID,
              let knownManifestRevision,
              SettingKey.subtitleSyncMs.acceptsProfileScope(atRevision: knownManifestRevision) else {
            return false
        }
        // The one-time import may still push this device's legacy values;
        // decide after it has run.
        if let currentScope = scopeIdentifier(), !isMigrationComplete(for: currentScope) {
            return false
        }
        // A timing write still owed can be an older build's device offset
        // that lands later; decide once it has settled.
        guard !flusher.unsettledKeys.contains(.subtitleSyncMs) else {
            return false
        }
        defaults.set(true, forKey: doneKey)
        guard !subtitleUsesDeviceAppearanceOverride,
              deviceOverriddenKeys.contains(.subtitleSyncMs) else {
            return false
        }
        // Gated on the revision when sent, like the override switch's clear:
        // a retry after a relaunch must not delete the only offset a server
        // rolled back below revision 19 keeps.
        deviceOverriddenKeys.remove(.subtitleSyncMs)
        flusher.enqueueDelete(.subtitleSyncMs, onlyWhereProfileScoped: true)
        await flushPendingDeviceSettings()
        return !flusher.unsettledKeys.contains(.subtitleSyncMs)
    }

    private static func leftoverSubtitleOffsetClearKey(for scopeID: String) -> String {
        "player.leftoverDeviceSubtitleOffsetCleared.\(scopeID)"
    }

    /// Whether the server is known to reject `key` at `profile` scope. An
    /// unknown revision counts as accepting: the flusher holds the write until
    /// the revision is known and falls back to the device row then.
    private func serverAcceptsProfileScope(for key: SettingKey) -> Bool {
        guard let knownManifestRevision else { return true }
        return key.acceptsProfileScope(atRevision: knownManifestRevision)
    }

    /// Whether this device holds its own value for `setting`, rather than
    /// inheriting the profile's (or the contract default when the profile has
    /// none).
    func hasDeviceOverride(_ setting: ProfileBackedPlaybackSetting) -> Bool {
        setting.keys.contains { deviceOverriddenKeys.contains($0) }
    }

    /// How many settings "Use Profile Settings" would change: each setting
    /// this device holds its own value for (the cellular pair's two keys
    /// count once), plus each device-only preference away from its default.
    var deviceChangedSettingCount: Int {
        let overridden = Set(deviceOverriddenKeys.map {
            $0 == .cellularMaxBitrateKbps ? .cellularPreferredQuality : $0
        })
        return overridden.count + changedDeviceLocalPreferenceCount
    }

    /// Whether "Use Profile Settings" would reset something the profile has
    /// no value for — a device-only synced key or a local preference — which
    /// goes back to its default rather than to a profile value.
    var deviceChangesIncludeDeviceOnlySettings: Bool {
        let profileBacked = Set(
            ProfileBackedPlaybackSetting.allCases.flatMap(\.keys) + SettingKey.playerFollowedSettings
        )
        return changedDeviceLocalPreferenceCount > 0
            || deviceOverriddenKeys.contains { !profileBacked.contains($0) }
    }

    private var changedDeviceLocalPreferenceCount: Int {
        [
            !losslessAudioEnabled,
            !backgroundPlaybackEnabled,
            bufferAhead != .automatic,
            deinterlaceMode != .automatic,
            deinterlaceFieldRate != .fullMotion,
            !trueHDAtmosEnabled,
        ].filter { $0 }.count
    }

    /// Clear this device's own value for one setting so the profile's applies
    /// again, then read back the value it now inherits.
    ///
    /// The clears go through the same scoped queue as every other edit, so
    /// offline they wait in this (server, profile, device) partition and are
    /// sent by the next flush for it — never onto a profile switched to in
    /// the meantime. Until the read succeeds the row keeps showing the last
    /// known value; it no longer counts as this device's own.
    @MainActor
    func useProfileSetting(_ setting: ProfileBackedPlaybackSetting) async {
        // The refresh below may be this scope's first successful one. Its
        // one-time import would then push the cached value of the very key
        // just cleared straight back as a device override, so these keys are
        // retired from it. The rest of the scope's import stays pending.
        if let scopeID = scopeIdentifier() {
            retireMigration(of: setting.keys, for: scopeID)
        }
        for key in setting.keys {
            enqueueDeviceClear(key)
        }
        if setting == .cellularQuality {
            resetCellularQualityWhereNotServed()
        }
        await flushPendingDeviceSettings()
        await refreshFromServer()
    }

    /// A server older than revision 20 has no profile value for the cellular
    /// pair to read back, so clearing this device's value leaves the contract
    /// default. A newer server's refresh paints the profile's value instead.
    private func resetCellularQualityWhereNotServed() {
        guard let knownManifestRevision,
              knownManifestRevision < SettingKey.cellularQualityRevision else { return }
        cellularQualityResolution = Self.defaultCellularQuality.resolution
        cellularMaxBitrateKbps = Self.defaultCellularQuality.bitrateKbps
    }

    /// Queue this device's own value for `key`.
    private func enqueueDeviceValue(_ key: SettingKey, value: SettingJSONValue) {
        deviceOverriddenKeys.insert(key)
        flusher.enqueue(key, value: value)
    }

    /// Queue the profile's value for `key`. A value this device holds for the
    /// key would keep hiding it here, so that is deleted in the same write.
    ///
    /// Always, not only when ``deviceOverriddenKeys`` lists the key: that set
    /// is only as fresh as the last refresh, and an edit made before one (an
    /// offline launch, a reinstall) cannot see a device value already on the
    /// server. The flusher treats "no device value" as success.
    private func enqueueProfileValue(_ key: SettingKey, value: SettingJSONValue) {
        deviceOverriddenKeys.remove(key)
        // An unfinished one-time import must not later bring back this
        // device's older cached value as a device value over this edit.
        if let scopeID = scopeIdentifier() {
            retireMigration(of: [key], for: scopeID)
        }
        flusher.enqueue(key, value: value, scope: .profile, clearingDeviceValue: true)
    }

    /// Queue clearing this device's own value for `key`, so it inherits again.
    private func enqueueDeviceClear(_ key: SettingKey) {
        deviceOverriddenKeys.remove(key)
        flusher.enqueueDelete(key)
    }

    // Adopting a profile write. The onboarding tour stores these at profile
    // scope, so the server already has them; these methods only update the
    // local value and deliberately queue nothing. Enqueueing would write a
    // `profile_device` override that pins this device to the value and shadows
    // later changes to the profile row. An edit this device owns goes through
    // the matching `setX` instead.

    /// Normalizes the pair the same way ``setQualityPreset(_:)`` does.
    func adoptProfileQuality(resolution: String, bitrateKbps: Int?) {
        preferredQualityResolution = SiloQualityPresets.normalizeResolution(resolution)
        maxBitrateKbps = bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
    }

    func adoptProfileIntroSkipMode(_ mode: IntroSkipMode) {
        introSkipMode = mode
    }

    func adoptProfileAutoSkipCredits(_ enabled: Bool) {
        autoSkipCredits = enabled
    }

    @MainActor
    func resetAllDeviceSettings() async {
        let resetScopeID = scopeIdentifier()
        // The device-local preferences have no canonical row to delete, so the
        // DELETE loop below cannot reach them and the refresh that follows
        // re-adopts whatever this device still has cached. Restore them here
        // instead — before the first suspension, so each `didSet` writes its
        // default into the partition this reset was started in rather than
        // whichever profile is active by the time the network settles.
        resetDeviceLocalPreferences()
        // Reset is an explicit instruction to discard the pre-contract local
        // values. Retire migration before the follow-up refresh or that refresh
        // can snapshot and import the values whose canonical rows were just
        // deleted.
        if let resetScopeID {
            markMigrationComplete(for: resetScopeID)
        }
        for key in SettingKey.playerReadSettings {
            enqueueDeviceClear(key)
        }
        if Self.offersCellularQuality {
            for key in SettingKey.playerCellularQualitySettings {
                enqueueDeviceClear(key)
            }
            resetCellularQualityWhereNotServed()
        }
        for key in SettingKey.playerBufferingQualitySettings {
            enqueueDeviceClear(key)
        }
        await flushPendingDeviceSettings()
        if await refreshFromServer() == .serverUpgradeRequired {
            // A pre-contract server has no inherited canonical rows to read
            // back. Persist defaults into the captured partition even if the
            // user switched profiles while the DELETEs were suspended, but do
            // not repaint a different profile's live state. An ordinary
            // offline failure keeps the cached values instead.
            cacheContractDefaults(for: resetScopeID)
            if scopeIdentifier() == resetScopeID {
                applyCachedSettingsForCurrentScope()
            }
        }
    }

    /// Restore the preferences this device owns outright to their defaults.
    ///
    /// These are the ones deliberately kept off the contract — lossless
    /// multichannel audio, background playback, the buffer-ahead window and the
    /// two deinterlacing choices. "Use Profile Settings" is a promise about
    /// the whole screen, not only the rows that happen to sync, so they are
    /// restored to the same values a fresh install would show.
    private func resetDeviceLocalPreferences() {
        losslessAudioEnabled = true
        backgroundPlaybackEnabled = true
        bufferAhead = .automatic
        deinterlaceMode = .automatic
        deinterlaceFieldRate = .fullMotion
        trueHDAtmosEnabled = true
    }

    /// Keep showing this device's own values for keys whose change has not
    /// reached the server (queued, failed or held): the server's answer does
    /// not have them yet, and painting it would silently undo the edit.
    private func overlayingUnsettledValues(
        on effectiveByKey: [SettingKey: EffectiveSettingValue]
    ) -> [SettingKey: EffectiveSettingValue] {
        var merged = effectiveByKey
        for (key, unsettled) in flusher.unsettledScopedValues() {
            // Painted at the scope it is being written to, so a pending
            // profile edit does not read as this device's own value.
            let scope = unsettled.scope.settingScope
            merged[key] = EffectiveSettingValue(
                key: key.rawValue,
                value: unsettled.value,
                source: .scope(scope),
                suggestedValues: effectiveByKey[key]?.suggestedValues,
                scope: scope
            )
        }
        return merged
    }

    /// "Discard held change": forget the held device setting changes and
    /// repaint what the server holds.
    ///
    /// Reads the server before dropping anything. Offline, the only copy of
    /// a held key on this device is the discarded value itself, so dropping
    /// the hold would leave playback using that value with nothing saying it
    /// is unsaved. The hold stays until the server can be reached. Returns
    /// false when the discard did not happen for that reason. The cellular
    /// pair is read too, where the server has it, so a discarded cellular
    /// edit is repainted like any other; if only that read fails, the holds
    /// stay too.
    ///
    /// Each read answers for the scope (server and profile) active when it is
    /// sent, so a scope change while either awaits also returns false:
    /// nothing is discarded or applied under the new scope.
    @discardableResult
    @MainActor
    func discardHeldDeviceSettingChanges() async -> Bool {
        let discardScopeID = scopeIdentifier()
        let response: EffectiveSettingValuesResponse
        do {
            response = try await flusher.effectiveValues(keys: SettingKey.playerReadSettings)
        } catch SettingsAPIError.serverUpgradeRequired {
            guard scopeIdentifier() == discardScopeID else { return false }
            // The server stores no settings for this device at all, so the
            // local value is the only one there is.
            flusher.discardHeldChanges()
            return true
        } catch {
            return false
        }
        guard scopeIdentifier() == discardScopeID else { return false }
        knownManifestRevision = flusher.knownManifestRevision
        guard let cellular = try? await cellularQualityValues(atRevision: response.revision) else {
            return false
        }
        let bufferingRead = await bufferingQualityValues()
        guard scopeIdentifier() == discardScopeID, let buffering = adopt(bufferingRead) else {
            return false
        }
        flusher.discardHeldChanges()
        applyEffectiveSettings(overlayingUnsettledValues(
            on: response.byKey
                .merging(cellular) { _, cellularValue in cellularValue }
                .merging(buffering) { _, bufferingValue in bufferingValue }
        ))
        return true
    }

    /// Send the held device setting changes again with a fresh retry budget.
    @MainActor
    func retryHeldDeviceSettingChanges() async {
        await flusher.retryHeldChanges()
    }

    @MainActor
    func dismissDeviceSettingRejection() {
        rejectedDeviceSettingChange = false
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
    /// Members an older server does not know are removed by the flusher at
    /// send time, not here (see ``SettingKey/revisionGatedMembers``).
    private func enqueueSubtitleAppearance(_ appearance: SubtitleAppearance, scope: PlayerSettingWriteScope) {
        guard let value = try? SettingJSONValue.encoding(appearance) else {
            // Unreachable for a struct of scalars, and dropping the write is
            // the right failure: the server would reject a value that cannot
            // be encoded, and the local value is already applied.
            return
        }
        switch scope {
        case .profile: enqueueProfileValue(.subtitleAppearance, value: value)
        case .profileDevice: enqueueDeviceValue(.subtitleAppearance, value: value)
        }
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
        // The cellular pair has rows only when its own read ran (see
        // ``cellularQualityValues(atRevision:)``) or a change is still owed.
        // Without one this device keeps its value, which is the only copy on
        // a server older than revision 20.
        if let entry = effectiveByKey[.cellularPreferredQuality] {
            cellularQualityResolution = SiloQualityPresets.normalizeResolution(entry.value.stringValue)
        }
        if let entry = effectiveByKey[.cellularMaxBitrateKbps] {
            cellularMaxBitrateKbps = entry.value.intValue.flatMap { $0 > 0 ? $0 : nil }
        }
        // A nullable language tag: JSON null is "no preference", which this
        // client spells as the empty string.
        audioLanguage = effectiveByKey[.audioLanguage]?.value.stringValue ?? ""
        audioLanguageSuggestions = effectiveByKey[.audioLanguage]?.suggestedValues ?? []
        introSkipMode = IntroSkipMode(
            wireValue: effectiveByKey[.introSkipMode]?.value.stringValue
        ) ?? .default
        // Like the cellular pair: a row only from its own read or an owed
        // change, and without one this device keeps its value. A server
        // without the setting plays the default.
        if serverLacksBufferingQualityMode {
            bufferingQualityMode = .default
        } else if let entry = effectiveByKey[.bufferingQualityMode] {
            bufferingQualityMode = BufferingQualityMode(wireValue: entry.value.stringValue) ?? .default
        }
        autoSkipCredits = effectiveBool(.autoSkipCredits, in: effectiveByKey, default: false)
        autoSkipRecap = effectiveBool(.autoSkipRecap, in: effectiveByKey, default: false)
        autoPlayNextEpisode = effectiveBool(.autoPlayNext, in: effectiveByKey, default: true)
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            effectiveByKey[.nextUpPromptSeconds]?.value.intValue ?? 30
        )
        hdrEnabled = effectiveBool(.hdrEnabled, in: effectiveByKey, default: true)
        dolbyVisionEnabled = effectiveBool(.dolbyVisionEnabled, in: effectiveByKey, default: true)
        seekCacheEnabled = effectiveBool(.seekCacheEnabled, in: effectiveByKey, default: true)
        playbackSpeed = Self.clampPlaybackSpeed(
            effectiveByKey[.playbackSpeed]?.value.doubleValue ?? 1.0
        )
        subtitleSyncMs = effectiveByKey[.subtitleSyncMs]?.value.intValue ?? 0
        videoGravity = VideoGravity(
            rawValue: effectiveByKey[.videoGravity]?.value.stringValue ?? VideoGravity.fit.rawValue
        ) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: effectiveByKey[.orientationMode]?.value.stringValue
                ?? PlayerOrientationMode.landscapeLocked.rawValue
        ) ?? .landscapeLocked

        applyEffectiveSubtitleAppearance(effectiveByKey[.subtitleAppearance])

        // A clear still on its way has not reached the server, whose answer
        // therefore still shows the device value being removed.
        let clearing = flusher.unsettledClears
        // A cellular or buffering key with no row keeps what this device last
        // knew, like its value above, unless the server doesn't define it:
        // then this device has no value of its own there.
        var unreadGated = Set(SettingKey.playerCellularQualitySettings + SettingKey.playerBufferingQualitySettings)
            .subtracting(effectiveByKey.keys)
        if serverLacksBufferingQualityMode {
            unreadGated.subtract(SettingKey.playerBufferingQualitySettings)
        }
        deviceOverriddenKeys = Set(
            effectiveByKey.compactMap { key, entry in
                entry.scope == .profileDevice && !clearing.contains(key) ? key : nil
            }
        ).union(deviceOverriddenKeys.intersection(unreadGated))
    }

    /// Split the resolved appearance between the device override and the
    /// inherited value. The resolved row's scope says whether it is a device
    /// override.
    private func applyEffectiveSubtitleAppearance(_ entry: EffectiveSettingValue?) {
        guard let entry else {
            subtitleUsesDeviceAppearanceOverride = false
            inheritedSubtitleAppearance = .default
            return
        }
        let hasDeviceOverride = entry.scope == .profileDevice
        if hasDeviceOverride && flusher.unsettledClears.contains(.subtitleAppearance) {
            // The answer still shows the device value a clear on its way is
            // removing, and says nothing about the profile's. The override
            // stays off, so the next edit goes to the profile as the user
            // chose rather than back onto this device.
            subtitleUsesDeviceAppearanceOverride = false
            return
        }
        subtitleUsesDeviceAppearanceOverride = hasDeviceOverride
        // A stored appearance is a sparse override the schema merges over the
        // contract default, and SubtitleAppearance's decoder already fills each
        // absent property from `.default` — so a partial object round-trips
        // rather than resetting the properties it omits.
        let appearance = ((try? entry.value.decoded(as: SubtitleAppearance.self)) ?? .default).sanitized()
        if hasDeviceOverride {
            deviceSubtitleAppearance = appearance
        } else {
            inheritedSubtitleAppearance = appearance
        }
    }

    /// A bool from a resolved row; falls back only when the server sent no row
    /// (a typed `false` is a real value).
    private func effectiveBool(
        _ key: SettingKey,
        in effectiveByKey: [SettingKey: EffectiveSettingValue],
        default fallback: Bool
    ) -> Bool {
        effectiveByKey[key]?.value.boolValue ?? fallback
    }

    /// The values this device actually stored, as the contract's typed JSON.
    ///
    /// Read once at the top of a refresh, before the server's answer is
    /// applied, so the one-time migration can tell a value this device has
    /// always held from one the server just handed back.
    ///
    /// Only keys present in the store appear. A key that was never stored has
    /// no legacy value to carry over; filling in this client's default for it
    /// would turn that default into a device override on the first refresh,
    /// hiding whatever the profile chose (a fresh install would pin every
    /// device to Auto quality and no audio language).
    ///
    /// The quality half is decomposed here for the same reason the setter
    /// decomposes it: a compound id like `1080p-high` is not a member of the
    /// contract's enum, so migrating it verbatim would be rejected forever.
    // Internal so the migration's lossless key coverage can be pinned by the
    // focused settings tests without reaching through a live server/profile.
    func legacySnapshot() -> [SettingKey: SettingJSONValue] {
        var snapshot: [SettingKey: SettingJSONValue] = [:]

        // Both spellings appear here: the unscoped key predates per-scope
        // caching, and either may still hold a compound tier id from a build
        // before the axes were stored separately. The shared axes conversion
        // reduces any of them to a contract member without losing its cap.
        let legacyQualityId = storedString(Keys.preferredQuality, unscopedFallback: true)
        if let legacyQualityId {
            snapshot[.preferredQuality] = .string(AppleQualityAxes.split(legacyQualityId).resolution)
        }
        // Builds before the contract stored Apple's compound rung id in the
        // quality key and had no companion bitrate key. Recover that rung's
        // cap only when no explicit axis exists; the separate key is always
        // authoritative once present. The two axes are one preference, so a
        // stored quality carries its bitrate half (uncapped is stored as the
        // key's absence) and neither half is imported without being stored.
        if legacyQualityId != nil || hasStoredValue(Keys.maxBitrateKbps) {
            let legacyBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
                ?? legacyQualityId.flatMap { AppleQualityAxes.split($0).bitrateKbps }
            snapshot[.maxBitrateKbps] = legacyBitrateKbps.map { .int($0) } ?? .null
        }
        if let legacyAudioLanguage = storedString(Keys.audioLanguage, unscopedFallback: true) {
            snapshot[.audioLanguage] = legacyAudioLanguage.isEmpty ? .null : .string(legacyAudioLanguage)
        }
        if hasStoredValue(Keys.introSkipMode) || hasStoredValue(Keys.autoSkipIntro) {
            snapshot[.introSkipMode] = .string(Self.cachedIntroSkipMode(defaults).wireValue)
        }
        if hasStoredValue(Keys.autoSkipCredits) {
            snapshot[.autoSkipCredits] = .bool(
                Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
            )
        }
        if hasStoredValue(Keys.autoPlayNextEpisode)
            || defaults.object(forKey: Keys.legacyAutoPlayNextEpisode) != nil {
            snapshot[.autoPlayNext] = .bool(
                Self.cachedBool(
                    defaults,
                    key: Keys.autoPlayNextEpisode,
                    legacyKey: Keys.legacyAutoPlayNextEpisode,
                    defaultValue: true
                )
            )
        }
        if hasStoredValue(Keys.nextUpPromptSeconds) {
            snapshot[.nextUpPromptSeconds] = .int(
                Self.clampNextUpPromptSeconds(
                    Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
                )
            )
        }
        if hasStoredValue(Keys.hdrEnabled) {
            snapshot[.hdrEnabled] = .bool(
                Self.cachedBool(defaults, key: Keys.hdrEnabled, defaultValue: true)
            )
        }
        if hasStoredValue(Keys.dolbyVisionEnabled) {
            snapshot[.dolbyVisionEnabled] = .bool(
                Self.cachedBool(defaults, key: Keys.dolbyVisionEnabled, defaultValue: true)
            )
        }
        if hasStoredValue(Keys.seekCacheEnabled) {
            snapshot[.seekCacheEnabled] = .bool(
                Self.cachedBool(defaults, key: Keys.seekCacheEnabled, defaultValue: true)
            )
        }
        if hasStoredValue(Keys.playbackSpeed) {
            snapshot[.playbackSpeed] = .double(
                Self.clampPlaybackSpeed(
                    Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
                )
            )
        }
        if hasStoredValue(Keys.subtitleSyncMs) {
            snapshot[.subtitleSyncMs] = .int(defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs)))
        }
        if let videoGravity = storedString(Keys.videoGravity) {
            snapshot[.videoGravity] = .string(videoGravity)
        }
        if let orientationMode = storedString(Keys.playerOrientationMode) {
            snapshot[.orientationMode] = .string(orientationMode)
        }
        if let appearanceJSON = storedString(Keys.subtitleAppearance, unscopedFallback: true),
           let appearance = try? SettingJSONValue.encoding(SubtitleAppearance.decode(from: appearanceJSON)) {
            snapshot[.subtitleAppearance] = appearance
        }
        return snapshot
    }

    /// Whether the store holds a value for `baseKey` in the current scope.
    private func hasStoredValue(_ baseKey: String) -> Bool {
        defaults.object(forKey: Self.cacheKey(baseKey)) != nil
    }

    /// The stored string for `baseKey` in the current scope, or — when
    /// `unscopedFallback` is set — under the unscoped key that predates
    /// per-scope caching. Nil when neither was stored.
    private func storedString(_ baseKey: String, unscopedFallback: Bool = false) -> String? {
        defaults.string(forKey: Self.cacheKey(baseKey))
            ?? (unscopedFallback ? defaults.string(forKey: baseKey) : nil)
    }

    private func applyCachedSettingsForCurrentScope() {
        isLoadingCache = true
        defer { isLoadingCache = false }
        preferredQualityResolution = Self.cachedQualityResolution(defaults)
        maxBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
        let cellular = Self.cachedCellularQuality(defaults)
        cellularQualityResolution = cellular.resolution
        cellularMaxBitrateKbps = cellular.bitrateKbps
        audioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage)) ?? ""
        introSkipMode = Self.cachedIntroSkipMode(defaults)
        bufferingQualityMode = Self.cachedBufferingQualityMode(defaults)
        serverLacksBufferingQualityMode = defaults.bool(forKey: Self.cacheKey(Keys.bufferingQualityModeUndefined))
        autoSkipCredits = Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
        autoSkipRecap = Self.cachedBool(defaults, key: Keys.autoSkipRecap, defaultValue: false)
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
        seekCacheEnabled = Self.cachedBool(
            defaults,
            key: Keys.seekCacheEnabled,
            defaultValue: true
        )
        losslessAudioEnabled = Self.cachedBool(
            defaults,
            key: Keys.losslessAudioEnabled,
            defaultValue: true
        )
        backgroundPlaybackEnabled = Self.cachedBool(
            defaults,
            key: Keys.backgroundPlaybackEnabled,
            defaultValue: true
        )
        bufferAhead = Self.cachedBufferAhead(defaults)
        deinterlaceMode = Self.cachedDeinterlaceMode(defaults)
        deinterlaceFieldRate = Self.cachedDeinterlaceFieldRate(defaults)
        trueHDAtmosEnabled = Self.cachedBool(
            defaults,
            key: Keys.trueHDAtmosEnabled,
            defaultValue: true
        )
        playbackSpeed = Self.clampPlaybackSpeed(
            Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
        )
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
        deviceSubtitleAppearance = SubtitleAppearance.decode(from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance)))
        inheritedSubtitleAppearance = SubtitleAppearance.decode(
            from: defaults.string(forKey: Self.cacheKey(Keys.inheritedSubtitleAppearance))
        )
        deviceOverriddenKeys = Self.cachedOverriddenKeys(defaults)
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
        var locallyEffective = overlayingUnsettledValues(on: effectiveByKey)
        // A key with its own change still owed (a held one included) is the
        // user's newer choice; the legacy value must not replace it.
        let unsettled = flusher.unsettledKeys
        // Keys the user sent back to the profile's value before the import ran.
        let retired = retiredMigrationKeys(for: scopeID)

        for key in SettingKey.playerDeviceSettings where !unsettled.contains(key) && !retired.contains(key) {
            guard let legacyValue = legacySnapshot[key] else { continue }
            // A stored "" audio language is "no preference", which is not a
            // device value: importing it as JSON null would pin "no
            // preference" here and hide the profile's language.
            if key == .audioLanguage, case .null = legacyValue { continue }
            guard let entry = effectiveByKey[key], entry.scope != .profileDevice else { continue }
            // Nothing to migrate when the resolved value already equals what
            // this device holds — typed comparison now, so `1` and `1.0` are
            // not two different values the way their strings were. Compared as
            // the server would store it: an older server's answer cannot carry
            // a member it does not know, so that member is no difference.
            let comparable = flusher.knownManifestRevision.map {
                key.wireValue(legacyValue, forServerRevision: $0)
            } ?? legacyValue
            if comparable.isSemanticallyEquivalent(to: entry.value) {
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

    private static func migrationKey(for scopeID: String) -> String {
        "player.serverDeviceSettingsMigration.\(scopeID)"
    }

    private func isMigrationComplete(for scopeID: String) -> Bool {
        defaults.bool(forKey: Self.migrationKey(for: scopeID))
    }

    private func markMigrationComplete(for scopeID: String) {
        defaults.set(true, forKey: Self.migrationKey(for: scopeID))
        defaults.removeObject(forKey: retiredMigrationKey(for: scopeID))
    }

    private func retiredMigrationKey(for scopeID: String) -> String {
        "player.serverDeviceSettingsMigrationRetired.\(scopeID)"
    }

    private func retiredMigrationKeys(for scopeID: String) -> Set<SettingKey> {
        let stored = defaults.stringArray(forKey: retiredMigrationKey(for: scopeID)) ?? []
        return Set(stored.compactMap(SettingKey.init(rawValue:)))
    }

    /// Leave `keys` out of this scope's pending one-time import, without
    /// cancelling the import for the others. Nothing to do once it has run.
    // Internal so the focused migration tests can retire keys for a scope.
    func retireMigration(of keys: [SettingKey], for scopeID: String) {
        guard !isMigrationComplete(for: scopeID) else { return }
        let retired = retiredMigrationKeys(for: scopeID).union(keys)
        defaults.set(retired.map(\.rawValue).sorted(), forKey: retiredMigrationKey(for: scopeID))
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
        // Absent is the cellular pair's contract default.
        defaults.removeObject(forKey: key(Keys.cellularPreferredQuality))
        defaults.removeObject(forKey: key(Keys.cellularMaxBitrateKbps))
        defaults.set("", forKey: key(Keys.audioLanguage))
        defaults.set(false, forKey: key(Keys.autoSkipIntro))
        defaults.set(IntroSkipMode.default.wireValue, forKey: key(Keys.introSkipMode))
        defaults.set(BufferingQualityMode.default.wireValue, forKey: key(Keys.bufferingQualityMode))
        defaults.set(false, forKey: key(Keys.autoSkipCredits))
        defaults.set(false, forKey: key(Keys.autoSkipRecap))
        defaults.set(true, forKey: key(Keys.autoPlayNextEpisode))
        defaults.set(30, forKey: key(Keys.nextUpPromptSeconds))
        defaults.set(true, forKey: key(Keys.hdrEnabled))
        defaults.set(true, forKey: key(Keys.dolbyVisionEnabled))
        defaults.set(true, forKey: key(Keys.seekCacheEnabled))
        defaults.set(1.0, forKey: key(Keys.playbackSpeed))
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
        defaults.set([String](), forKey: key(Keys.deviceOverriddenKeys))
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

    /// The cached cellular pair, or the contract default for a half never
    /// stored. A stored bitrate of 0 is uncapped (see ``cellularMaxBitrateKbps``).
    private static func cachedCellularQuality(_ defaults: UserDefaults) -> AppleQualityAxes {
        let resolution = defaults.string(forKey: cacheKey(Keys.cellularPreferredQuality))
            .map { SiloQualityPresets.normalizeResolution($0) }
            ?? defaultCellularQuality.resolution
        let bitrateKey = cacheKey(Keys.cellularMaxBitrateKbps)
        let bitrate = defaults.object(forKey: bitrateKey) == nil
            ? defaultCellularQuality.bitrateKbps
            : defaults.integer(forKey: bitrateKey)
        return AppleQualityAxes(resolution: resolution, bitrateKbps: bitrate.flatMap { $0 > 0 ? $0 : nil })
    }

    /// The cached mode, or — on a device that has only ever cached the
    /// deprecated boolean — the mode that boolean meant.
    private static func cachedIntroSkipMode(_ defaults: UserDefaults) -> IntroSkipMode {
        if let mode = IntroSkipMode(wireValue: defaults.string(forKey: cacheKey(Keys.introSkipMode))) {
            return mode
        }
        return IntroSkipMode(
            legacyAutoSkip: cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
        )
    }

    private static func cachedBufferingQualityMode(_ defaults: UserDefaults) -> BufferingQualityMode {
        BufferingQualityMode(wireValue: defaults.string(forKey: cacheKey(Keys.bufferingQualityMode))) ?? .default
    }

    /// A scope a build from before this record already synced (its one-time
    /// import has run) has no record of which values are this device's own.
    /// Until its next refresh says, each synced key counts as the device's
    /// own, so "Use Profile Setting" is offered and can clear it: clearing a
    /// value the device never held changes nothing, while hiding one it does
    /// hold leaves no way back.
    // Internal so the focused tests can check an upgraded scope.
    static func cachedOverriddenKeys(
        _ defaults: UserDefaults,
        scopeID: String? = currentScopeIdentifier
    ) -> Set<SettingKey> {
        if let stored = defaults.stringArray(forKey: cacheKey(Keys.deviceOverriddenKeys, scopeID: scopeID)) {
            return Set(stored.compactMap(SettingKey.init(rawValue:)))
        }
        guard let scopeID, defaults.bool(forKey: migrationKey(for: scopeID)) else { return [] }
        return Set(SettingKey.playerDeviceSettings)
    }

    private static func cachedBufferAhead(_ defaults: UserDefaults) -> BufferAheadMode {
        BufferAheadMode(
            rawValue: defaults.string(forKey: cacheKey(Keys.bufferAhead))
                ?? BufferAheadMode.automatic.rawValue
        ) ?? .automatic
    }

    private static func cachedDeinterlaceMode(_ defaults: UserDefaults) -> DeinterlacePreference {
        DeinterlacePreference(
            rawValue: defaults.string(forKey: cacheKey(Keys.deinterlaceMode))
                ?? DeinterlacePreference.automatic.rawValue
        ) ?? .automatic
    }

    private static func cachedDeinterlaceFieldRate(
        _ defaults: UserDefaults
    ) -> DeinterlaceFieldRatePreference {
        DeinterlaceFieldRatePreference(
            rawValue: defaults.string(forKey: cacheKey(Keys.deinterlaceFieldRate))
                ?? DeinterlaceFieldRatePreference.fullMotion.rawValue
        ) ?? .fullMotion
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
        static let cellularPreferredQuality = "playback.cellularPreferredQuality"
        static let cellularMaxBitrateKbps = "playback.cellularMaxBitrateKbps"
        static let audioLanguage = "preferredAudioLanguage"
        static let autoSkipIntro = "skipIntros"
        static let introSkipMode = "player.introSkipMode"
        static let bufferingQualityMode = "playback.bufferingQualityMode"
        static let bufferingQualityModeUndefined = "playback.bufferingQualityModeUndefined"
        static let autoSkipCredits = "skipCredits"
        static let autoSkipRecap = "player.autoSkipRecap"
        static let hdrEnabled = "player.hdrEnabled"
        static let dolbyVisionEnabled = "player.dolbyVisionEnabled"
        static let seekCacheEnabled = "player.seekCacheEnabled"
        static let losslessAudioEnabled = "player.losslessAudioEnabled"
        static let backgroundPlaybackEnabled = "player.backgroundPlaybackEnabled"
        static let bufferAhead = "player.bufferAhead"
        static let deinterlaceMode = "player.deinterlaceMode"
        static let deinterlaceFieldRate = "player.deinterlaceFieldRate"
        static let trueHDAtmosEnabled = "player.trueHDAtmosEnabled"
        static let subtitleAppearance = "player.subtitleAppearance"
        static let inheritedSubtitleAppearance = "player.inheritedSubtitleAppearance"
        static let subtitleUsesDeviceAppearanceOverride = "player.subtitleUsesDeviceAppearanceOverride"
        static let subtitleMatchesSystemAppearance = "player.subtitleMatchesSystemAppearance"
        static let subtitleSyncMs = "player.subtitleSyncMs"
        static let playbackSpeed = "player.playbackSpeed"
        static let videoGravity = "player.videoGravity"
        static let playerOrientationMode = "player.playerOrientationMode"
        static let autoPlayNextEpisode = "autoPlayNext"
        static let legacyAutoPlayNextEpisode = "player.autoPlayNextEpisode"
        static let nextUpPromptSeconds = "player.nextUpPromptSeconds"
        static let deviceOverriddenKeys = "player.deviceOverriddenKeys"
    }
}
