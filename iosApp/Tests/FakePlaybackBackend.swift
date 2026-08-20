import Foundation
@testable import Silo

/// Recording `PlaybackBackend` double for control-plane tests.
///
/// Deliberately logic-free: every method appends a `name(args)` string to
/// `calls` and nothing else, every getter reads a plain stored value, and the
/// `fire…` helpers invoke whatever closure the system under test installed.
/// Tests assert on `calls` (order and arguments) and drive the control plane by
/// firing callbacks.
final class FakePlaybackBackend: PlaybackBackend {

    /// Ordered log of every call made on this backend: `"name(arg,arg)"`.
    private(set) var calls: [String] = []

    // MARK: - Stored values behind the getters

    var isPausedValue = false
    var currentTimeValue: Double = 0
    var userVolumeValue: Float = 1
    var externalPlaybackActive = false
    var externalPlaybackAllowed = false
    var hasControlledSubtitleSelectionValue = false

    func clearCalls() {
        calls = []
    }

    // MARK: - Load / transport

    func load(sessionSpec: LoopbackSessionSpec, startTime: Double) {
        calls.append("load(loopback,\(startTime))")
    }

    func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double) {
        calls.append("loadRemoteHLS(\(url.absoluteString),\(headers.count),\(startTime))")
    }

    func loadDirectFile(url: URL, headers: [String: String], startTime: Double) {
        calls.append("loadDirectFile(\(url.absoluteString),\(headers.count),\(startTime))")
    }

    func play() {
        calls.append("play()")
    }

    func pause() {
        calls.append("pause()")
    }

    func isPaused() -> Bool {
        calls.append("isPaused()")
        return isPausedValue
    }

    func currentTime() -> Double {
        currentTimeValue
    }

    func seek(to seconds: Double) {
        calls.append("seek(\(seconds))")
    }

    func setSpeed(_ rate: Double) {
        calls.append("setSpeed(\(rate))")
    }

    func setUserVolume(_ v: Float) {
        calls.append("setUserVolume(\(v))")
    }

    func setUserMuted(_ m: Bool) {
        calls.append("setUserMuted(\(m))")
    }

    var currentUserVolume: Float { userVolumeValue }

    func setMediaTimelineOffset(_ offset: Double) {
        calls.append("setMediaTimelineOffset(\(offset))")
    }

    func dispose() {
        calls.append("dispose()")
    }

    // MARK: - Recovery

    /// Live sample handed back to the recovery owner. `nil` by default, which
    /// is what a backend with no item reports.
    var recoveryPlayheadSampleValue: PlayheadSample?
    var recoveryPlayheadSample: PlayheadSample? { recoveryPlayheadSampleValue }

    var onRecoveryObservation: ((RecoveryObservation) -> Void)?

    /// Every action the system under test performed, in order.
    private(set) var performedRecoveryActions: [RecoveryAction] = []

    func perform(_ action: RecoveryAction) {
        performedRecoveryActions.append(action)
        calls.append("perform(\(action))")
    }

    // MARK: - Tracks / subtitles / chapters

    func selectAudioTrack(_ trackId: Int64) {
        calls.append("selectAudioTrack(\(trackId))")
    }

    func selectSubtitleTrack(_ trackId: Int64?) {
        calls.append("selectSubtitleTrack(\(String(describing: trackId)))")
    }

    func setSecondarySubtitleTrack(_ trackId: Int64?) {
        calls.append("setSecondarySubtitleTrack(\(String(describing: trackId)))")
    }

    func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor]) {
        calls.append("registerSidecarSubtitles(\(descriptors.count))")
    }

    func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?) {
        calls.append(
            "openLiveSubtitleTrack(\(slot),\(label ?? "nil"),\(language ?? "nil"))"
        )
    }

    func feedLiveSubtitleCue(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        calls.append("feedLiveSubtitleCue(\(slot),\(eventText),\(startMs),\(durationMs))")
    }

    func closeLiveSubtitleTrack(slot: SubtitleSlot) {
        calls.append("closeLiveSubtitleTrack(\(slot))")
    }

    func setSubtitleDelay(_ seconds: Double) {
        calls.append("setSubtitleDelay(\(seconds))")
    }

    func applySubtitleAppearance(_ appearance: SubtitleAppearance) {
        calls.append("applySubtitleAppearance()")
    }

    func setServerChapters(_ chapters: [PlayerChapterInfo]) {
        calls.append("setServerChapters(\(chapters.count))")
    }

    var hasControlledSubtitleSelection: Bool { hasControlledSubtitleSelectionValue }

    // MARK: - External playback

    var isExternalPlaybackActive: Bool { externalPlaybackActive }
    var isExternalPlaybackAllowed: Bool { externalPlaybackAllowed }

    // MARK: - Callbacks

    var onTimeChange: ((Double) -> Void)?
    var onDurationChange: ((Double) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    var onFileLoaded: ((String) -> Void)?
    var onFirstFrame: ((Int) -> Void)?
    var onError: ((PlaybackFailure) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    var onBufferedAheadChange: ((PlaybackBufferedAhead) -> Void)?
    var onPlaybackStatsChange: ((PlaybackStats) -> Void)?
    var onTracksChange: (([PlayerTrack]) -> Void)?
    var onChaptersChange: (([PlayerChapterInfo]) -> Void)?
    var onTimelineOffsetChange: ((Double) -> Void)?
    var onExternalPlaybackActiveChange: ((Bool) -> Void)?
    var onExternalPlaybackAllowedChange: ((Bool) -> Void)?
    var onExternalPlaybackUnavailable: (() -> Void)?
    var onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)?

    // MARK: - Inbound providers

    var isPictureInPictureActiveProvider: (() -> Bool)?
    var sourceOutageStateProvider: (() -> Bool)?

    // MARK: - Firing helpers

    func fireTime(_ seconds: Double) { onTimeChange?(seconds) }
    func fireDuration(_ seconds: Double) { onDurationChange?(seconds) }
    func firePauseChanged(_ paused: Bool) { onPauseChange?(paused) }
    func fireFileLoaded(reason: String) { onFileLoaded?(reason) }
    func fireFirstFrame(_ milliseconds: Int) { onFirstFrame?(milliseconds) }
    func fireError(_ failure: PlaybackFailure) { onError?(failure) }
    func fireEndOfFile() { onEndOfFile?() }
    func fireBuffering(_ buffering: Bool) { onBufferingChange?(buffering) }
    func fireBufferedAhead(_ ahead: PlaybackBufferedAhead) { onBufferedAheadChange?(ahead) }
    func firePlaybackStats(_ stats: PlaybackStats) { onPlaybackStatsChange?(stats) }
    func fireTracks(_ tracks: [PlayerTrack]) { onTracksChange?(tracks) }
    func fireChapters(_ chapters: [PlayerChapterInfo]) { onChaptersChange?(chapters) }
    func fireTimelineOffset(_ offset: Double) { onTimelineOffsetChange?(offset) }
    func fireExternalPlaybackActive(_ active: Bool) { onExternalPlaybackActiveChange?(active) }
    func fireExternalPlaybackAllowed(_ allowed: Bool) { onExternalPlaybackAllowedChange?(allowed) }
    func fireExternalPlaybackUnavailable() { onExternalPlaybackUnavailable?() }
    func fireSidecarTracksRegistered(_ descriptors: [SidecarSubtitleDescriptor]) {
        onSidecarTracksRegistered?(descriptors)
    }

    func fireRecoveryObservation(_ observation: RecoveryObservation) {
        onRecoveryObservation?(observation)
    }
}
