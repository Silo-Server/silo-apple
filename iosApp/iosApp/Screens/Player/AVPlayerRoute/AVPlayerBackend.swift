import AVFoundation
import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

final class AVPlayerBackend {
    enum SourceStrategy {
        case remoteHLS(url: URL, headers: [String: String])
        case remoteDirect(url: URL, headers: [String: String])
        case siloLoopback(spec: LoopbackSessionSpec)
    }

    private struct MediaSelectionState {
        let kind: PlayerTrack.Kind
        let group: AVMediaSelectionGroup
        let optionsByTrackId: [Int64: AVMediaSelectionOption]
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "AVPlayerBackend"
    )

    /// Forward buffer applied to the loopback `AVPlayerItem` at item
    /// creation. Sized for fast initial readyToPlay — AVPlayer otherwise
    /// waits for whole GOP-sized fragments before declaring ready.
    private static let loopbackStartupForwardBuffer: Double = 4.0
    /// Local loopback startup watchdog (AetherEngine-style, replaces the old
    /// fixed 12 s readiness timeout that killed healthy-but-slow startups —
    /// living-room DV P7 + TrueHD→FLAC at a far resume needed >12 s while
    /// segment GETs were flowing the whole time). Ticks at 1 Hz while the
    /// item is not yet ready. Escalates the recovery ladder (nudge seek →
    /// in-place item reload → route fallback) only when the loopback server
    /// has served no request for `loopbackStartupStallWindowSeconds` — a
    /// dead loader stops fetching within seconds, so genuine failures now
    /// fall back *faster* than the old timeout, while slow heavy muxes get
    /// all the time they need. The absolute backstop bounds the pathological
    /// "fetches forever, never ready" consumer.
    private static let loopbackStartupWatchdogTickSeconds: TimeInterval = 1.0
    private static let loopbackStartupStallWindowSeconds: TimeInterval = 6.0
    private static let loopbackStartupAbsoluteBackstopSeconds: TimeInterval = 60.0
    private static let loopbackSeekWindowTolerance: Double = 0.25

    /// Default forward buffer applied once the initial-video-display gate
    /// releases. Used when the source bitrate is unknown. Keep this modest on
    /// tvOS because AVPlayer's forward buffer is only one part of the resident
    /// playback budget.
    private static let loopbackSteadyStateForwardBufferDefault: Double = 30.0
    /// Local DV loopback playhead watchdog. Driven by an independent wall-clock
    /// timer (AVPlayer's periodic time observer stops firing when the playhead
    /// freezes, so it cannot detect a stationary playhead on its own). When
    /// AVPlayer believes it is playing but the playhead has not advanced for
    /// `playheadWatchdogStallSeconds` while generated media is available ahead,
    /// reanchor the loopback. After `playheadWatchdogMaxReanchors` failed
    /// attempts inside `playheadWatchdogReanchorWindowSeconds`, escalate to a
    /// route fallback instead of reanchoring forever.
    private static let playheadWatchdogTickSeconds: TimeInterval = 1.0
    private static let playheadWatchdogStallSeconds: Double = 10.0
    /// Kept above the reanchor path's own steady-state `generatedAhead`
    /// threshold (10 s) so a watchdog trigger never bails inside recovery.
    private static let playheadWatchdogMinGeneratedAhead: Double = 12.0
    private static let playheadWatchdogMaxReanchors = 3
    private static let playheadWatchdogReanchorWindowSeconds: Double = 90.0
    /// Starvation escalation: the reanchor path requires generated media
    /// ahead of the playhead, so a *producer-dead* stall (e.g. the spill
    /// gate deadlock) never qualified and the session froze forever. If
    /// AVPlayer has been waiting on an empty buffer this long while the
    /// store served nothing, the loopback session is unrecoverable — fall
    /// back to the Compatibility route instead. The serve-quiet guard keeps
    /// ordinary slow-WAN rebuffers (segments still flowing) from tripping it.
    private static let playheadWatchdogStarvationEscalateSeconds: Double = 30.0
    private static let playheadWatchdogStarvationServeQuietSeconds: Double = 15.0
    private static let generatedHLSSpillBudgetBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static var isConstrainedMemoryDevice: Bool {
        #if os(tvOS)
        return ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
        #else
        return false
        #endif
    }
    private static var loopbackSegmentStoreMemoryBudgetBytes: Int {
        isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 128 * 1024 * 1024
    }

    /// Temporary [CMP-MEM] instrumentation: resident footprint as jetsam
    /// accounts it. `phys_footprint` is the number the per-process limit
    /// is enforced against (not `resident_size`), and
    /// `os_proc_available_memory` is the headroom left before the kill —
    /// together they attribute working-set growth directly from a capture
    /// of a memory termination.
    private static func memoryFootprintMiB() -> (footprint: Double, available: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // os_proc_available_memory is iOS/tvOS-only; macOS has no
        // per-process jetsam limit to report headroom against.
        #if os(iOS) || os(tvOS)
        let available = Double(os_proc_available_memory()) / 1_048_576
        #else
        let available = -1.0
        #endif
        return (
            footprint: Double(info.phys_footprint) / 1_048_576,
            available: available
        )
    }

    /// Adaptive forward-buffer target for the local DV loopback. Aims for
    /// a fixed resident-memory target while clamping the duration into a
    /// sensible window so very high-bitrate sources don't blow tvOS RAM and
    /// very low-bitrate sources still keep enough cushion for transient WAN
    /// dips.
    static func loopbackSteadyStateForwardBufferTarget(
        forBitsPerSecond bitrateBps: Double?,
        targetDuration: Double? = nil,
        longestSegmentDuration: Double? = nil,
        constrainedMemoryDevice: Bool? = nil
    ) -> Double {
        let constrainedMemoryDevice = constrainedMemoryDevice ?? Self.isConstrainedMemoryDevice
        let liveEdgeFloor = loopbackLiveEdgeForwardBufferFloor(
            targetDuration: targetDuration,
            longestSegmentDuration: longestSegmentDuration
        )
        let minSeconds = constrainedMemoryDevice ? 8.0 : 12.0
        let maxSeconds = constrainedMemoryDevice ? 36.0 : 60.0
        guard let bps = bitrateBps, bps > 0 else {
            let fallback = constrainedMemoryDevice ? 20.0 : loopbackSteadyStateForwardBufferDefault
            return min(maxSeconds, max(minSeconds, max(fallback, liveEdgeFloor)))
        }
        // target MiB / bitrate seconds = duration that sustains the budget.
        let targetMiB = constrainedMemoryDevice ? 160.0 : 270.0
        let targetBits = targetMiB * 1_048_576 * 8
        let computed = targetBits / bps
        // Clamp: avoid underrun on jitter while capping memory and seek-back
        // churn. Lower-memory Apple TVs get a tighter window.
        return min(maxSeconds, max(minSeconds, max(computed, liveEdgeFloor)))
    }

    private static func loopbackLiveEdgeForwardBufferFloor(
        targetDuration: Double?,
        longestSegmentDuration: Double?
    ) -> Double {
        guard let targetDuration,
              let longestSegmentDuration,
              targetDuration.isFinite,
              longestSegmentDuration.isFinite,
              targetDuration > 0,
              longestSegmentDuration > 0 else {
            return 0
        }
        return 3 * targetDuration + longestSegmentDuration
    }

    private static func generatedHLSSpillPolicy(for spec: LoopbackSessionSpec) -> LoopbackSegmentStore.SpillPolicy {
        if ProcessInfo.processInfo.environment["SILO_ENABLE_HLS_DISK_SPILL"] == "1" {
            return .enabled(reason: "env", maxBytes: generatedHLSSpillBudgetBytes)
        }
        return .enabled(
            reason: spec.sourceBitrateBps == nil ? "source_bitrate_unknown" : "local_hls_event_playlist",
            maxBytes: generatedHLSSpillBudgetBytes
        )
    }

    var onTimeChange: ((Double) -> Void)?
    var onDurationChange: ((Double) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onError: ((String) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    var onBufferedAheadChange: ((Double) -> Void)?
    var onPlaybackStatsChange: ((PlaybackStats) -> Void)?
    var onTracksChange: (([PlayerTrack]) -> Void)?
    var onChaptersChange: (([PlayerChapterInfo]) -> Void)?
    var onTimelineOffsetChange: ((Double) -> Void)?
    var onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)?
    var onSubtitleLoadStatusChange: ((SubtitleSlot, SubtitleLoadStatus) -> Void)?
    /// Raised when the local DV loopback playhead watchdog has exhausted its
    /// reanchor attempts and the route should be degraded (e.g. to the
    /// Compatibility route) rather than left frozen. The argument is a short
    /// reason token for logging/telemetry.
    var onLoopbackStallUnrecoverable: ((String) -> Void)?
    /// Temporary [CMP-MEM]: source-proxy cache stats for the periodic
    /// footprint log line. The proxy is owned by PlayerViewModel, so it is
    /// injected as a closure rather than held here.
    var proxyStatsProvider: (() -> PlaybackSourceProxyStats?)?

    let avPlayer = AVPlayer()
    weak var subtitleOverlay: SubtitleOverlayView?
    var subtitleRendererForOverlay: SubtitleRenderer? {
        subtitleSession?.underlyingRenderer
    }
    var hasControlledSubtitleSelection: Bool {
        selectedControlledSubtitleTrackId != nil || selectedSecondaryControlledSubtitleTrackId != nil
    }

    private var currentSourceStrategy: SourceStrategy?
    private var currentItem: AVPlayerItem?
    private var audioSelectionState: MediaSelectionState?
    private var subtitleSelectionState: MediaSelectionState?
    private var timeObserver: Any?
    #if os(macOS)
    private var subtitleDisplayLink: Timer?
    #else
    private var subtitleDisplayLink: CADisplayLink?
    #endif
    private var didFireFileLoaded = false
    private var pendingStartTime: Double = 0
    private var hasSeekedToStart = false
    private var isDisposed = false
    private var isSeekPending = false
    private var isInitialSeekInFlight = false
    private var initialSeekRetryCount = 0
    private var subtitleSession: SubtitleSession?
    private var embeddedSubtitleExtractor: AVPlayerEmbeddedSubtitleExtractor?
    /// Change-detection key for the overlay's bitmap cue layers: overlay
    /// size plus the identity of each active cue image. The display link
    /// pumps at vsync rate but bitmap cues change on the order of seconds,
    /// so all layer work is skipped while the key is unchanged.
    private struct BitmapCueRenderKey: Equatable {
        let videoRect: CGRect
        let images: [ObjectIdentifier]
    }
    private var lastBitmapCueRenderKey: BitmapCueRenderKey?
    /// Whether a libass-composited frame may still be on the text layer.
    /// Lets the pump clear the layer exactly once on a text → bitmap
    /// transition instead of dispatching a no-op clear to main every vsync
    /// for the whole duration of bitmap-only (PGS/DVD) playback.
    private var textOverlayMayHaveFrame = false
    // Temporary [CMP-SUBDIAG] instrumentation: rolling 1 Hz window of
    // session-queue latency and render cost for the subtitle pump.
    private var subDiagLastEmit: CFTimeInterval = 0
    private var subDiagMaxQueueLatencyMs: Double = 0
    private var subDiagMaxRenderMs: Double = 0
    private var subDiagTicks = 0
    private var subDiagDirtyCount = 0
    private var subDiagSkippedTicks = 0
    /// Text renders currently queued or executing on the renderer's session
    /// queue. The display link enqueues at vsync rate but a render can take
    /// >100 ms (full 4K re-rasterization), so without a cap the queue grows
    /// unboundedly and every downstream mutation (cue feeds, styling,
    /// track drops) lands seconds late. Capped at 2: one executing, one
    /// queued behind it. Main thread only.
    private var subPumpRendersInFlight = 0
    private var selectedControlledSubtitleTrackId: Int64?
    private var selectedSecondaryControlledSubtitleTrackId: Int64?
    private var sidecarDescriptorsByTrackId: [Int64: SidecarSubtitleDescriptor] = [:]
    /// Text-subtitle cues harvested from the loopback writer's own demuxer
    /// (see LoopbackSubtitleTap). Keyed to the source URL: producer
    /// restarts and reanchors reuse the store; a new source resets it.
    private var loopbackSubtitleTap: LoopbackSubtitleTap?
    private var loopbackSubtitleTapSourceURL: URL?
    private var mediaTimelineOffsetSeconds: Double = 0
    private var serverChapters: [PlayerChapterInfo] = []
    private var currentLoopbackAudioTracks: [PlayerTrack] = []
    private var bufferLoadCount = 0
    private var lastStatsEmitWall: CFTimeInterval = 0
    private var loopbackSourceDownloadBitrateBps: Double?
    private var loopbackHDR10PlusDetected = false
    private var loopbackSourceBytesRead: Int64?
    private var latestLoopbackGeneratedStats: LoopbackSegmentWriter.GeneratedMediaStats?
    private struct LoopbackEdgeWatch {
        var lastLoadedEnd: Double
        var lastLoadedEndAdvancedAt: CFTimeInterval
        var lastPlaylistEnd: Double
        var lastPlaylistHash: UInt64
    }
    private var loopbackEdgeWatch: LoopbackEdgeWatch?
    private var isInitialVideoDisplayGatePrepared = false
    private var isWaitingForInitialVideoDisplay = false
    private var didTemporarilyMuteForInitialVideoDisplay = false
    private var initialVideoDisplayGateStartTime: Double?
    private var initialVideoDisplayFallback: DispatchWorkItem?
    private var loopbackStartupWatchdog: Timer?
    private var loopbackStartupWatchdogStartedAt: Date?
    private var loopbackStartupLastProgressAt: Date = .distantPast
    private var loopbackStartupLastRequestCount: UInt64 = 0
    private enum LoopbackStartupRecoveryStage { case initial, nudged, reloaded }
    private var loopbackStartupRecoveryStage: LoopbackStartupRecoveryStage = .initial
    /// In-flight HDMI mode-switch settle wait (gated non-DV HDR only). The
    /// AVPlayerItem attach is deferred behind it; teardown cancels it so a
    /// reanchor or dispose can't race a late attach.
    private var displayModeSettleTask: Task<Void, Never>?

    private var segmentWriter: LoopbackSegmentWriter?
    private var segmentServer: LoopbackSegmentServer?
    private var segmentStore: LoopbackSegmentStore?
    private var sessionDirectory: URL?
    private var activeLoopbackSessionID: String?
    private var loopbackGeneration: UInt64 = 0
    private let loopbackPlaybackClockLock = NSLock()
    private var loopbackPlaybackClockSecondsValue: Double = 0
    private var pendingLocalLoopbackRecoveryMediaTime: Double?
    private var lastLocalLoopbackStallRecoveryAt: CFTimeInterval = 0
    private var loopbackPlayheadWatchdog: Timer?
    private var watchdogLastPlayheadSeconds: Double = -1
    private var watchdogLastAdvanceWall: CFTimeInterval = 0
    private var watchdogLastStateLogWall: CFTimeInterval = 0
    private var watchdogReanchorCount = 0
    private var watchdogReanchorWindowStartWall: CFTimeInterval = 0
    private var didEscalateLoopbackStall = false
    private var isUserPaused = false
    private var preserveSessionDirectory = false
    private var audioSessionActive = false
    private var isPreservingTVDisplayCriteriaForReload = false

    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var timeControlObs: NSKeyValueObservation?
    private var bufferFullObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var itemPlaybackStalledObserver: NSObjectProtocol?
    private var itemFailedToEndObserver: NSObjectProtocol?
    private var itemErrorLogObserver: NSObjectProtocol?
    private var durationObs: NSKeyValueObservation?
    private var loadedRangesObs: NSKeyValueObservation?
    private var seekableRangesObs: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init() {
        let session = SubtitleSession()
        session.onSidecarTracksRegistered = { [weak self] descriptors in
            self?.onSidecarTracksRegistered?(descriptors)
        }
        session.onStatusChange = { [weak self] slot, status in
            self?.onSubtitleLoadStatusChange?(slot, status)
        }
        session.currentPositionSecondsProvider = { [weak self] in
            guard let self else { return 0 }
            return self.mediaTime(for: self.currentTime())
        }
        subtitleSession = session
        let extractor = AVPlayerEmbeddedSubtitleExtractor(subtitleSession: session)
        extractor.currentMediaTimeProvider = { [weak self] in
            guard let self else { return 0 }
            return self.mediaTime(for: self.currentTime())
        }
        extractor.onTracksChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.emitTrackList()
            }
        }
        embeddedSubtitleExtractor = extractor
    }

    deinit {
        dispose()
    }

    func load(
        sessionSpec: LoopbackSessionSpec,
        startTime: Double,
    ) {
        isUserPaused = false
        load(
            strategy: .siloLoopback(spec: sessionSpec),
            startTime: startTime
        )
    }

    func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double) {
        isUserPaused = false
        load(
            strategy: .remoteHLS(url: url, headers: headers),
            startTime: startTime
        )
    }

    func loadDirectFile(url: URL, headers: [String: String], startTime: Double) {
        isUserPaused = false
        load(
            strategy: .remoteDirect(url: url, headers: headers),
            startTime: startTime
        )
    }

    func play() {
        isUserPaused = false
        onPauseChange?(false)
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy,
           let mediaSeconds = pendingLocalLoopbackRecoveryMediaTime {
            pendingLocalLoopbackRecoveryMediaTime = nil
            Self.logger.info(
                "[CMP-AVP] local loopback deferred recovery reanchor media=\(mediaSeconds, privacy: .public)"
            )
            subtitleSession?.flushOnSeek()
            embeddedSubtitleExtractor?.seek(to: mediaSeconds)
            load(strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)), startTime: mediaSeconds)
            return
        }
        avPlayer.play()
    }

    func pause() {
        isUserPaused = true
        onPauseChange?(true)
        avPlayer.pause()
    }

    func prepareToBackground() {
        pause()
    }

    func videoSurfaceBecameReadyForDisplay() {
        guard let item = currentItem, !isDisposed else { return }
        guard isWaitingForInitialVideoDisplay else { return }
        finishInitialVideoDisplayGate(for: item, reason: "ready_for_display")
    }

    func setMediaTimelineOffset(_ offset: Double) {
        mediaTimelineOffsetSeconds = offset.isFinite ? max(0, offset) : 0
        onTimelineOffsetChange?(mediaTimelineOffsetSeconds)
        Self.logger.info(
            "[CMP-SEEK] AVPlayer timeline offset set requested=\(offset, privacy: .public) applied=\(self.mediaTimelineOffsetSeconds, privacy: .public)"
        )
    }

    func seek(to seconds: Double) {
        let mediaSeconds = seconds.isFinite ? max(0, seconds) : 0
        let playerSeconds = playerTime(forMediaTime: mediaSeconds)
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy {
            // VOD serving mode: every seek is in-item. The static playlist
            // covers the whole title; a fetch into never-produced content
            // restarts the producer behind the stable item (1e), so the
            // teardown-reanchor path must never run.
            if spec.servingMode != .vodPlan,
               let reason = localLoopbackReanchorReason(
                mediaSeconds: mediaSeconds,
                playerSeconds: playerSeconds
               ) {
                reloadLocalLoopbackForSeek(
                    spec: spec,
                    mediaSeconds: mediaSeconds,
                    playerSeconds: playerSeconds,
                    reason: reason
                )
                return
            }
            if spec.servingMode == .vodPlan {
                // Recovery anchor (M7): if this seek wedges, the watchdog
                // must aim at the requested target — the frozen clock still
                // reports the pre-seek position.
                vodPendingSeekMediaTarget = mediaSeconds
            }
        }

        let time = CMTime(seconds: playerSeconds, preferredTimescale: 600)
        isSeekPending = true
        let seekItem = currentItem
        Self.logger.info(
            "[CMP-SEEK] AVPlayer seek request media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public) offset=\(self.mediaTimelineOffsetSeconds, privacy: .public)"
        )
        subtitleSession?.flushOnSeek()
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, !self.isDisposed else { return }
            guard seekItem === self.currentItem else { return }
            self.isSeekPending = false
            self.vodPendingSeekMediaTarget = nil
            let landed = self.avPlayer.currentTime().seconds
            let mediaTime = self.mediaTime(for: landed)
            Self.logger.info(
                "[CMP-SEEK] AVPlayer seek complete finished=\(finished, privacy: .public) landedPlayer=\(landed, privacy: .public) landedMedia=\(mediaTime, privacy: .public) requestedMedia=\(mediaSeconds, privacy: .public) offset=\(self.mediaTimelineOffsetSeconds, privacy: .public)"
            )
            guard finished, landed.isFinite, mediaTime.isFinite else { return }
            self.resyncControlledSubtitlesAfterSeek(mediaSeconds: mediaTime)
            self.onTimeChange?(landed)
            self.pumpSubtitleOverlay(referenceTime: mediaTime)
        }
    }

    private func localLoopbackReanchorReason(
        mediaSeconds: Double,
        playerSeconds: Double
    ) -> String? {
        if mediaSeconds + 0.05 < mediaTimelineOffsetSeconds {
            return "before_anchor"
        }
        if let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds {
            if generatedEnd.isFinite,
               generatedEnd > 0,
               playerSeconds > generatedEnd - Self.loopbackSeekWindowTolerance {
                return "outside_generated_window"
            }
        }
        guard let currentItem,
              !itemHasSeekableMedia(currentItem, containing: playerSeconds) else {
            return nil
        }
        return "outside_generated_window"
    }

    private func reloadLocalLoopbackForSeek(
        spec: LoopbackSessionSpec,
        mediaSeconds: Double,
        playerSeconds: Double,
        reason: String
    ) {
        Self.logger.info(
            "[CMP-SEEK] AVPlayer loopback reanchor requestedMedia=\(mediaSeconds, privacy: .public) requestedPlayer=\(playerSeconds, privacy: .public) anchor=\(self.mediaTimelineOffsetSeconds, privacy: .public) reason=\(reason, privacy: .public)"
        )
        subtitleSession?.flushOnSeek()
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        load(strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)), startTime: mediaSeconds)
    }

    func currentTime() -> Double {
        avPlayer.currentTime().seconds
    }

    private func mediaTime(for playerTime: Double) -> Double {
        guard playerTime.isFinite else { return 0 }
        return max(0, playerTime + mediaTimelineOffsetSeconds)
    }

    private func setLoopbackPlaybackClock(_ seconds: Double) {
        guard seconds.isFinite else { return }
        loopbackPlaybackClockLock.lock()
        loopbackPlaybackClockSecondsValue = max(0, seconds)
        loopbackPlaybackClockLock.unlock()
    }

    private func loopbackPlaybackClockSeconds() -> Double {
        loopbackPlaybackClockLock.lock()
        let value = loopbackPlaybackClockSecondsValue
        loopbackPlaybackClockLock.unlock()
        return value
    }

    private func playerTime(forMediaTime mediaTime: Double) -> Double {
        guard mediaTime.isFinite else { return 0 }
        return max(0, mediaTime - mediaTimelineOffsetSeconds)
    }

    func isPaused() -> Bool {
        isUserPaused
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        Self.logger.info("[CMP-AVP] dispose")
        teardownMediaPipeline()
    }

    func setSpeed(_ rate: Double) {
        avPlayer.defaultRate = Float(rate)
        if avPlayer.rate != 0 {
            avPlayer.rate = Float(rate)
        }
    }

    private var userVolume: Float = 1.0
    private var userMuted = false

    func setUserVolume(_ v: Float) {
        userVolume = min(max(v, 0), 1)
        // An explicit volume change requests an audible level, so it clears
        // mute — otherwise the gain stays at 0 and the slider disagrees with
        // the silent output.
        userMuted = false
        applyUserGain()
    }
    func setUserMuted(_ m: Bool) {
        userMuted = m
        applyUserGain()
    }
    var currentUserVolume: Float { userVolume }
    var currentUserMuted: Bool { userMuted }

    // User mute is modeled as volume = 0, NOT avPlayer.isMuted: the latter is
    // owned by the initial-video-display gate (begin/finishInitialVideoDisplayGate)
    // and its unmute would clobber a user mute.
    private func applyUserGain() {
        avPlayer.volume = userMuted ? 0 : userVolume
    }

    func setSubtitleDelay(_ seconds: Double) {
        print("[CMP-SUB] setSubtitleDelay seconds=\(seconds) session=\(subtitleSession == nil ? "nil" : "live")")
        var params = subtitleSession?.currentParams ?? .default
        params.syncOffsetMs = Int((seconds * 1000.0).rounded())
        subtitleSession?.applyStyling(params)
    }

    func applySubtitleAppearance(_ appearance: SubtitleAppearance) {
        print("[CMP-SUB] applySubtitleAppearance size=\(appearance.fontSize.rawValue) session=\(subtitleSession == nil ? "nil" : "live")")
        let syncOffset = subtitleSession?.currentParams.syncOffsetMs ?? 0
        let params = SubtitleStylingOverride.Parameters.from(
            appearance: appearance,
            syncOffsetMs: syncOffset
        )
        subtitleSession?.applyStyling(params)
    }

    func selectAudioTrack(_ trackId: Int64) {
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy {
            guard let selectedTrack = spec.availableAudioTracks.first(where: { $0.trackId == trackId }),
                  let selectedTrackIndex = selectedTrack.srcId else {
                return
            }
            let playerSeconds = currentTime()
            let startTime = playerSeconds.isFinite
                ? mediaTime(for: max(0, playerSeconds))
                : pendingStartTime
            let updatedTracks = spec.availableAudioTracks.map { track in
                PlayerTrack(
                    trackId: track.trackId,
                    kind: track.kind,
                    title: track.title,
                    lang: track.lang,
                    codec: track.codec,
                    audioChannelsLayout: track.audioChannelsLayout,
                    audioChannelCount: track.audioChannelCount,
                    bitrate: track.bitrate,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    isHearingImpaired: track.isHearingImpaired,
                    isVisualImpaired: track.isVisualImpaired,
                    isExternal: track.isExternal,
                    isSelected: track.trackId == trackId,
                    ffIndex: track.ffIndex,
                    srcId: track.srcId
                )
            }
            let updatedSpec = LoopbackSessionSpec(
                sourceURL: spec.sourceURL,
                headers: spec.headers,
                sourceStartTimeSeconds: startTime,
                sourceBitrateBps: spec.sourceBitrateBps,
                videoMode: spec.videoMode,
                sourceVideoFrameRate: spec.sourceVideoFrameRate,
                selectedAudio: LoopbackSessionSpec.SelectedAudio(
                    trackIndex: selectedTrackIndex,
                    ffIndex: selectedTrack.ffIndex,
                    sourceCodec: selectedTrack.codec,
                    sourceChannelCount: selectedTrack.audioChannelCount,
                    sourceChannelLayout: selectedTrack.audioChannelsLayout,
                    outputMode: Self.loopbackAudioOutputMode(for: selectedTrack),
                    preservesAtmos: Self.loopbackPreservesAtmos(for: selectedTrack)
                ),
                availableAudioTracks: updatedTracks,
                manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                    advertisedDolbyVisionProfile: spec.manifestMetadata.advertisedDolbyVisionProfile,
                    compatibilityBrand: spec.manifestMetadata.compatibilityBrand,
                    videoRange: spec.manifestMetadata.videoRange,
                    mayClaimAtmos: Self.loopbackPreservesAtmos(for: selectedTrack)
                )
            )
            Self.logger.info(
                "[CMP-AVP] rebuilding loopback for audio trackId=\(trackId, privacy: .public) trackIndex=\(selectedTrackIndex, privacy: .public) ffIndex=\(selectedTrack.ffIndex ?? -1, privacy: .public)"
            )
            load(
                strategy: .siloLoopback(spec: updatedSpec),
                startTime: startTime
            )
            return
        }

        guard let item = currentItem,
              let state = audioSelectionState,
              let option = state.optionsByTrackId[trackId] else {
            return
        }

        item.select(option, in: state.group)
        emitTrackList()
    }

    func selectSubtitleTrack(_ trackId: Int64?) {
        print("[CMP-SUB] selectSubtitleTrack id=\(trackId.map(String.init) ?? "nil") item=\(currentItem == nil ? "nil" : "live")")
        guard let item = currentItem else {
            return
        }

        // Live AI path: the synthetic live track is already installed in
        // the renderer (and being fed cues). Selecting it just records the
        // selection and drops any AVFoundation/extractor caption in the
        // slot; the live track stays installed and visible. Checked BEFORE
        // the sidecar branch so a live id is never routed to `openSidecar`.
        if let trackId, SubtitleTrackIdSpace.isAILive(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            embeddedSubtitleExtractor?.clear(slot: .primary)
            selectedControlledSubtitleTrackId = trackId
            emitTrackList()
            return
        }

        if let trackId, SubtitleTrackIdSpace.isSidecar(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            embeddedSubtitleExtractor?.clear(slot: .primary)
            selectedControlledSubtitleTrackId = trackId
            subtitleSession?.openSidecar(
                urlIndex: SubtitleTrackIdSpace.sidecarIndex(from: trackId),
                slot: .primary
            )
            emitTrackList()
            return
        }

        // Tap-served embedded text tracks: instant enable from the store,
        // no side demuxer. Checked before the extractor so text tracks
        // never pay the second-connection open/seek.
        if let trackId, tapServesEmbeddedTrack(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            embeddedSubtitleExtractor?.stopFeeding(slot: .primary)
            selectedControlledSubtitleTrackId = trackId
            activateTapSubtitleTrack(trackId: trackId, slot: .primary)
            emitTrackList()
            return
        }

        if let trackId, embeddedSubtitleExtractor?.canSelect(trackId: trackId) == true {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            selectedControlledSubtitleTrackId = trackId
            embeddedSubtitleExtractor?.select(
                trackId: trackId,
                slot: .primary,
                startSeconds: mediaTime(for: currentTime())
            )
            emitTrackList()
            return
        }

        loopbackSubtitleTap?.deactivate()
        embeddedSubtitleExtractor?.clear(slot: .primary)
        selectedControlledSubtitleTrackId = nil
        if let state = subtitleSelectionState {
            item.select(nil, in: state.group)
        }
        if trackId != nil {
            Self.logger.info(
                "[CMP-AVP] primary subtitle ignored because track is not controlled by libass trackId=\(trackId.map(String.init) ?? "nil", privacy: .public)"
            )
        }
        emitTrackList()
    }

    func setSecondarySubtitleTrack(_ trackId: Int64?) {
        guard let trackId else {
            embeddedSubtitleExtractor?.clear(slot: .secondary)
            selectedSecondaryControlledSubtitleTrackId = nil
            subtitleSession?.closeSlot(.secondary)
            return
        }
        if embeddedSubtitleExtractor?.canSelect(trackId: trackId) == true {
            selectedSecondaryControlledSubtitleTrackId = trackId
            embeddedSubtitleExtractor?.select(
                trackId: trackId,
                slot: .secondary,
                startSeconds: mediaTime(for: currentTime())
            )
            return
        }
        guard SubtitleTrackIdSpace.isSidecar(trackId) else {
            embeddedSubtitleExtractor?.clear(slot: .secondary)
            selectedSecondaryControlledSubtitleTrackId = nil
            subtitleSession?.closeSlot(.secondary)
            Self.logger.info(
                "[CMP-AVP] secondary subtitle ignored for non-sidecar trackId=\(trackId, privacy: .public)"
            )
            return
        }
        embeddedSubtitleExtractor?.clear(slot: .secondary)
        selectedSecondaryControlledSubtitleTrackId = trackId
        subtitleSession?.openSidecar(
            urlIndex: SubtitleTrackIdSpace.sidecarIndex(from: trackId),
            slot: .secondary
        )
    }

    func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor]) {
        sidecarDescriptorsByTrackId = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                (SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.index), $0)
            }
        )
        subtitleSession?.registerSidecarTracks(descriptors)
        emitTrackList()
    }

    // MARK: - Live AI subtitle track

    /// Open a synthetic live AI subtitle track in `slot`. The underlying
    /// `SubtitleSession`/`SubtitleRenderer` serialise the work on their own
    /// queue, so this forwards directly (mirroring `openSidecar`).
    func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?) {
        subtitleSession?.openLive(slot: slot, label: label, language: language)
    }

    /// Feed a single converted live AI cue to the live track in `slot`.
    func feedLiveSubtitleCue(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        subtitleSession?.feedLiveCue(
            slot: slot,
            eventText: eventText,
            startMs: startMs,
            durationMs: durationMs
        )
    }

    /// Close the live AI subtitle track in `slot`.
    func closeLiveSubtitleTrack(slot: SubtitleSlot) {
        subtitleSession?.closeLive(slot: slot)
    }

    func setServerChapters(_ chapters: [PlayerChapterInfo]) {
        serverChapters = chapters
        if didFireFileLoaded {
            onChaptersChange?(chapters)
        }
    }

    // MARK: - Startup (TTFF) telemetry — SiloPlayer plan Stage 0

    private var ttffLoadAnchor: CFAbsoluteTime = 0
    private var ttffFirstSegmentMs: Int?
    private var ttffReadyMs: Int?
    private var ttffEmitted = true
    private var ttffLastObservedTime: Double = .nan

    private func ttffElapsedMs() -> Int {
        Int((CFAbsoluteTimeGetCurrent() - ttffLoadAnchor) * 1000)
    }

    private func ttffMarkLoad() {
        ttffLoadAnchor = CFAbsoluteTimeGetCurrent()
        ttffFirstSegmentMs = nil
        ttffReadyMs = nil
        ttffEmitted = false
        ttffLastObservedTime = .nan
    }

    /// Emits one `[CMP-TTFF]` line per load at the first observed playhead
    /// advance while playing — the closest observable proxy for "first frame
    /// rendered" that works on both the loopback and the remote AVPlayer
    /// routes, and is axis-agnostic (the loopback item timeline is
    /// session-relative, not media-relative).
    private func ttffEmitIfNeeded(currentTime: Double) {
        guard !ttffEmitted else { return }
        defer { ttffLastObservedTime = currentTime }
        guard !ttffLastObservedTime.isNaN,
              avPlayer.rate > 0,
              currentTime > ttffLastObservedTime + 0.02 else { return }
        ttffEmitted = true
        let route = currentSourceStrategy.map(Self.describe) ?? "unknown"
        let firstSegment = ttffFirstSegmentMs.map(String.init) ?? "-"
        let ready = ttffReadyMs.map(String.init) ?? "-"
        cmpLog("[CMP-TTFF] route=\(route) first_segment_ms=\(firstSegment) ready_ms=\(ready) first_frame_ms=\(ttffElapsedMs())")
    }

    private func load(strategy: SourceStrategy, startTime: Double) {
        guard !isDisposed else { return }
        cmpLog("[CMP-AVP] load strategy=\(Self.describe(strategy)) startTime=\(startTime)")
        ttffMarkLoad()

        let preserveDisplayCriteria = shouldPreserveTVDisplayCriteriaDuringReload(
            from: currentSourceStrategy,
            to: strategy
        )
        teardownMediaPipeline(clearDisplayCriteria: !preserveDisplayCriteria)
        isPreservingTVDisplayCriteriaForReload = preserveDisplayCriteria
        currentSourceStrategy = strategy
        currentLoopbackAudioTracks = Self.normalizedLoopbackAudioTracks(for: strategy)
        configureEmbeddedSubtitleExtraction(for: strategy)
        setLoopbackPlaybackClock(0)
        bufferLoadCount = 0
        lastStatsEmitWall = 0
        loopbackSourceDownloadBitrateBps = nil
        loopbackHDR10PlusDetected = false
        loopbackSourceBytesRead = nil
        latestLoopbackGeneratedStats = nil
        loopbackEdgeWatch = nil
        pendingLocalLoopbackRecoveryMediaTime = nil
        vodPendingSeekMediaTarget = nil
        lastLocalLoopbackStallRecoveryAt = 0
        // Reset playhead advance-tracking for the new session so a reanchor's
        // pre-reanchor position does not read as instantly stationary. The
        // reanchor retry budget (count/window/escalation) deliberately survives
        // across reanchors and only resets on window expiry.
        watchdogLastPlayheadSeconds = -1
        watchdogLastAdvanceWall = 0
        watchdogLastStateLogWall = 0
        didFireFileLoaded = false
        hasSeekedToStart = false
        pendingStartTime = startTime
        initialSeekRetryCount = 0
        isInitialSeekInFlight = false

        switch strategy {
        case .remoteHLS(let url, let headers):
            prepareAssetPlayback(url: url, headers: headers)
        case .remoteDirect(let url, let headers):
            prepareAssetPlayback(url: url, headers: headers)
        case .siloLoopback(let spec):
            if spec.servingMode == .vodPlan {
                // The VOD item timeline is the plan's playlist axis; its
                // origin is the plan anchor (near 0 for normal titles, the
                // content start for late-start ones). Refined again when the
                // first session resolves the plan.
                setMediaTimelineOffset(
                    vodPlanForCurrentSource(spec: spec)?.anchorSourceSeconds ?? 0
                )
            } else {
                setMediaTimelineOffset(spec.sourceStartTimeSeconds)
            }
            startSiloLoopback(sessionSpec: spec)
        }
    }

    // MARK: - VOD serving-mode plan continuity (loopback-primary plan, 1c)

    /// The segment plan resolved by the first producer session for the
    /// current source. Restarted producers receive it so every session
    /// reproduces the same segment grid the static playlist advertises.
    private var loopbackVODPlan: LoopbackSegmentPlan?
    private var loopbackVODPlanSourceURL: URL?

    private func vodPlanForCurrentSource(spec: LoopbackSessionSpec) -> LoopbackSegmentPlan? {
        guard spec.servingMode == .vodPlan,
              loopbackVODPlanSourceURL == spec.sourceURL else { return nil }
        return loopbackVODPlan
    }

    // MARK: - VOD demand-driven producer restarts (loopback-primary plan, 1e)

    private static let vodSegmentMissWaitSeconds: Double = 8.0
    /// How far past a running producer's base a fetch counts as "covered" —
    /// the producer's forward march will deliver it without a restart.
    private static let vodProducerCoverageWindow = 8

    private var vodRestartCoalescer = LoopbackRestartCoalescer()
    private var activeVODWriterBaseIndex: Int?
    /// Highest segment index the running producer has actually finalized.
    /// Coverage decisions ride the march only when the target is within
    /// `vodProducerMarchAllowance` of THIS, not of the static base — with
    /// 30–70 MB long-GOP segments the march moves at 3–6 s per segment, and
    /// "within 8 of base" left a seek's fetch waiting out the full miss
    /// deadline into a 404 (living-room frozen-video seeks).
    private var activeVODWriterHeadIndex: Int?
    /// How far past the produced head a fetch may ride the running
    /// producer's march. One segment for the natural next-in-line fetch,
    /// plus one for AVPlayer's concurrent lookahead.
    private static let vodProducerMarchAllowance = 2
    /// The unlanded in-item seek target (media seconds). Cleared when the
    /// seek completion fires; while it survives, stall recovery aims here
    /// instead of at the frozen clock (M7).
    private var vodPendingSeekMediaTarget: Double?

    static func vodRetentionBudgetBytes() -> Int64 {
        // `volumeAvailableCapacityForImportantUsage` is unavailable on
        // tvOS, and the plain capacity key can report 0 for the sandboxed
        // temp volume there — a 0 the old code passed straight through as
        // the budget, silently disabling retention (living-room 4GB spill
        // deadlock). Use the filesystem-attributes helper (valid on every
        // platform) and clamp through the pure budget function, which
        // treats any non-positive reading as "query broken", never as 0.
        return Self.vodRetentionBudget(availableBytes: freeDiskSpaceBytes())
    }

    /// Pure clamp for the VOD retention budget: quarter of the available
    /// temp-volume capacity, capped at 2 GiB, floored at 512 MiB. An
    /// unknown or non-positive capacity reading means the query is broken,
    /// not that the disk is full — use the cap, never 0: a zero budget
    /// disables pruning outright and deadlocks the producer once the spill
    /// gate fills.
    static func vodRetentionBudget(availableBytes: Int64?) -> Int64 {
        let cap: Int64 = 2 << 30
        let floor: Int64 = 512 << 20
        guard let availableBytes, availableBytes > 0 else { return cap }
        return min(cap, max(floor, availableBytes / 4))
    }

    /// Swaps the producer (writer only — the store, server, and player item
    /// all survive) to anchor at the requested plan segment. Coalesced: one
    /// in-flight swap, newest pending target wins, self-target guarded.
    @MainActor
    private func requestVODProducerRestart(at index: Int, authoritative: Bool = false) {
        guard !isDisposed,
              case .some(.siloLoopback(let spec)) = currentSourceStrategy,
              spec.servingMode == .vodPlan,
              let plan = vodPlanForCurrentSource(spec: spec),
              plan.segmentCount > 0,
              let store = segmentStore,
              let sessionID = activeLoopbackSessionID,
              let sessionDir = sessionDirectory else { return }
        let target = max(0, min(index, plan.segmentCount - 1))
        if let base = activeVODWriterBaseIndex,
           segmentWriter != nil,
           target >= base,
           target <= base + Self.vodProducerCoverageWindow,
           target <= max(activeVODWriterHeadIndex ?? (base - 1), base - 1)
                        + Self.vodProducerMarchAllowance {
            // The running producer covers it AND is close enough that its
            // forward march delivers before the fetch's miss deadline. The
            // head-proximity bound matters on long-GOP sources: a seek
            // landing 3+ heavy segments past the produced head used to ride
            // "covered by base+8" into an 8 s wait and a 404. This applies
            // to recovery re-bases too: restarting a covering producer
            // discards its march and re-produces the same span — the
            // recovery ladder's player-side nudge/reload is the tool for a
            // consumer wedge, not producer churn. A genuinely wedged
            // producer surfaces separately (source stall → premature EOF /
            // mux failures) and escalates through the watchdog budget.
            return
        }
        var next: Int? = target
        while let current = next {
            guard vodRestartCoalescer.begin(current, authoritative: authoritative) else { return }
            cmpLog("[CMP-AVP] vod producer restart segment=\(current) authoritative=\(authoritative)")
            // Recycle the retiring producer's demuxer: same source URL
            // (reanchored spec only moves the start time), and the open
            // input + warm cue index are the dominant fixed cost of a
            // seek-triggered restart.
            var handoff: LoopbackInputHandoff?
            if let retiring = segmentWriter {
                let h = LoopbackInputHandoff()
                handoff = h
                retiring.stop(recyclingInputInto: h)
            }
            startSiloLoopbackWriter(
                sessionID: sessionID,
                sessionSpec: spec.reanchored(at: plan.sourceStartSeconds(ofSegment: current)),
                sessionDir: sessionDir,
                segmentStore: store,
                debugDirectory: nil,
                vodBaseIndex: current,
                recycledInput: handoff
            )
            next = vodRestartCoalescer.next(justRan: current)
        }
    }

    /// VOD stall-recovery ladder (M7) — never tears the session down. The
    /// anchor is the unlanded seek target when one exists (a wedged
    /// zero-tolerance seek leaves the frozen clock at the PRE-seek
    /// position). Attempt 1 nudges AVPlayer — cancel pending seeks, fresh
    /// zero-tolerance seek, play — which rebuilds its loading pipeline;
    /// later attempts swap the item in place (same URL, no pre-pause, the
    /// old item keeps rendering until the swap lands). Both ride alongside
    /// an authoritative producer restart at the anchor segment. The
    /// existing watchdog budget still escalates to a route fallback when
    /// the ladder doesn't take.
    @MainActor
    private func performVODStallRecovery(attempt: Int, frozenPosition: Double) {
        let anchorPlayer = vodPendingSeekMediaTarget.map(playerTime(forMediaTime:))
            ?? frozenPosition
        if let plan = loopbackVODPlan {
            requestVODProducerRestart(
                at: plan.segmentIndex(forPlaylistSeconds: anchorPlayer),
                authoritative: true
            )
        }
        let time = CMTime(seconds: max(0, anchorPlayer), preferredTimescale: 600)
        if attempt <= 1 {
            cmpLog("[CMP-AVP] vod stall recovery nudge anchorPlayer=\(anchorPlayer)")
            currentItem?.cancelPendingSeeks()
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            avPlayer.play()
        } else {
            guard let urlAsset = currentItem?.asset as? AVURLAsset else { return }
            cmpLog("[CMP-AVP] vod stall recovery in-place item reload anchorPlayer=\(anchorPlayer)")
            prepareAssetPlayback(url: urlAsset.url, headers: [:])
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            avPlayer.play()
        }
    }

    private func startSiloLoopback(
        sessionSpec: LoopbackSessionSpec
    ) {
        let sessionID = UUID().uuidString
        activeLoopbackSessionID = sessionID
        installLoopbackPlayheadWatchdog()
        loopbackGeneration &+= 1
        let generation = loopbackGeneration
        let debugBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-dv-hls-debug", isDirectory: true)
        let sessionDir = debugBaseDir.appendingPathComponent(sessionID, isDirectory: true)
        sessionDirectory = sessionDir
        preserveSessionDirectory = Self.keepLoopbackArtifacts

        let debugDirectory = preserveSessionDirectory ? sessionDir : nil
        let store = LoopbackSegmentStore(
            generation: generation,
            memoryBudgetBytes: Self.loopbackSegmentStoreMemoryBudgetBytes,
            spillPolicy: Self.generatedHLSSpillPolicy(for: sessionSpec),
            debugDirectory: debugDirectory
        )
        if sessionSpec.servingMode == .vodPlan {
            let retentionBudget = Self.vodRetentionBudgetBytes()
            cmpLog("[CMP-HLS-STORE] vod retention budgetBytes=\(retentionBudget)")
            // Forward byte budget: bounds the producer's produce-ahead race
            // on high-bitrate sources (the segment-count window alone
            // authorizes hundreds of MB at Blu-ray-remux segment sizes).
            store.configureVODRetention(
                budgetBytes: retentionBudget,
                forwardByteBudget: Self.isConstrainedMemoryDevice ? 96 << 20 : 192 << 20
            )
        }
        segmentStore = store
        if preserveSessionDirectory {
            print("[CMP-AVP] preserving local DV artifacts due to SILO_KEEP_DV_HLS=1 dir=\(sessionDir.path)")
        }

        let server = LoopbackSegmentServer(segmentStore: store)
        if sessionSpec.servingMode == .vodPlan {
            // A miss under the static VOD playlist means "not produced (yet)
            // or pruned": request a coalesced producer restart on main, then
            // wait — bounded — for the bytes. Runs on the server's resolver
            // queue; the store is thread-safe.
            server.vodSegmentMissResolver = { [weak self, weak store] index in
                guard let store else { return .missing }
                Task { @MainActor [weak self] in
                    self?.requestVODProducerRestart(at: index)
                }
                return store.waitForSegment(
                    named: String(format: "seg_%06d.m4s", index),
                    deadline: Date().addingTimeInterval(Self.vodSegmentMissWaitSeconds)
                )
            }
        }
        // Stash the server immediately so a synchronous teardown (e.g. fast
        // user dismiss) can find and cancel the still-binding listener.
        segmentServer = server

        // Server bind goes through `withCheckedThrowingContinuation` rather
        // than blocking the main actor on a 2 s semaphore. Defer writer setup
        // until bind completes; if the user disposes the backend or switches
        // sessions in the meantime, bail before touching state.
        Task { @MainActor [weak self] in
            do {
                try await server.start()
            } catch {
                guard let self else { return }
                // The server's catch arm already cancelled the listener; null
                // out our reference so callers don't trip on a cancelled
                // server still hanging off `segmentServer`.
                if self.segmentServer === server {
                    self.segmentServer = nil
                }
                guard !self.isDisposed,
                      self.activeLoopbackSessionID == sessionID else {
                    return
                }
                self.reportError("Local HLS server failed to start: \(error)")
                return
            }
            guard let self, !self.isDisposed else {
                server.stop()
                return
            }
            guard self.activeLoopbackSessionID == sessionID else {
                server.stop()
                return
            }
            self.startSiloLoopbackWriter(sessionID: sessionID,
                                             sessionSpec: sessionSpec,
                                             sessionDir: sessionDir,
                                             segmentStore: store,
                                             debugDirectory: nil)
        }
    }

    @MainActor
    private func startSiloLoopbackWriter(
        sessionID: String,
        sessionSpec: LoopbackSessionSpec,
        sessionDir: URL,
        segmentStore: LoopbackSegmentStore,
        debugDirectory: URL?,
        vodBaseIndex: Int = 0,
        recycledInput: LoopbackInputHandoff? = nil
    ) {
        let writer = LoopbackSegmentWriter(
            sessionSpec: sessionSpec,
            outputDirectory: sessionDir,
            segmentStore: segmentStore,
            debugOutputDirectory: debugDirectory,
            vodPlan: vodPlanForCurrentSource(spec: sessionSpec),
            vodBaseIndex: vodBaseIndex,
            recycledInputHandoff: recycledInput
        )
        let tap = ensureLoopbackSubtitleTap(for: sessionSpec.sourceURL)
        writer.onSubtitleTapTracks = { [weak tap] infos in
            tap?.registerTracks(infos)
        }
        writer.onSubtitleTapCue = { [weak tap] cue in
            tap?.ingest(cue)
        }
        if sessionSpec.servingMode == .vodPlan {
            activeVODWriterBaseIndex = vodBaseIndex
            activeVODWriterHeadIndex = vodBaseIndex - 1
            // Seed the consumer window at the producer's base so a resumed
            // or restarted session isn't parked by backpressure before the
            // player's first fetch declares a real target.
            segmentStore.declareVODTarget(vodBaseIndex)
            // A resume-first session anchors itself once the plan resolves;
            // re-seed from the writer's TRUE base or the producer parks
            // against a window still sitting at 0 while AVPlayer's resume
            // fetches strand (the living-room resume startup timeout).
            writer.onVODProducerAnchored = { [weak self, weak segmentStore] base in
                segmentStore?.declareVODTarget(base)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isDisposed,
                          self.activeLoopbackSessionID == sessionID else { return }
                    self.activeVODWriterBaseIndex = base
                    self.activeVODWriterHeadIndex = base - 1
                }
            }
            // Produced-head tracking for the restart coverage decision:
            // a fetch may only ride the running march when it's within
            // vodProducerMarchAllowance of what has actually been written.
            writer.onSegmentAppended = { [weak self] segmentIndex, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isDisposed,
                          self.activeLoopbackSessionID == sessionID else { return }
                    self.activeVODWriterHeadIndex = max(
                        self.activeVODWriterHeadIndex ?? segmentIndex,
                        segmentIndex
                    )
                }
            }
        }
        writer.onSegmentPlanResolved = { [weak self] plan in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                self.loopbackVODPlan = plan
                self.loopbackVODPlanSourceURL = sessionSpec.sourceURL
                // The item timeline's origin is the plan anchor; the initial
                // media-time seek (pendingStartTime) converts through this
                // offset, and plan resolution always precedes item creation.
                self.setMediaTimelineOffset(plan.anchorSourceSeconds)
            }
        }
        writer.onFirstSegmentReady = { [weak self] playlistName in
            DispatchQueue.main.async {
                self?.handleFirstSegmentReady(playlistName: playlistName, sessionID: sessionID)
            }
        }
        writer.onFinished = { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                if let error {
                    self.reportError("Remuxer failed: \(error)")
                }
            }
        }
        writer.onTimelineAnchorResolved = { [weak self] sourceStartSeconds in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                guard case .siloLoopback = self.currentSourceStrategy else { return }
                self.setMediaTimelineOffset(sourceStartSeconds)
            }
        }
        writer.playbackPositionProvider = { [weak self] in
            self?.loopbackPlaybackClockSeconds()
        }
        writer.onSourceDownloadStats = { [weak self] bitsPerSecond, totalBytesRead in
            DispatchQueue.main.async {
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                let previousBitrate = self.loopbackSourceDownloadBitrateBps
                self.loopbackSourceDownloadBitrateBps = bitsPerSecond
                self.loopbackSourceBytesRead = totalBytesRead
                self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                if let bitsPerSecond {
                    let mbps = bitsPerSecond / 1_000_000
                    let mib = totalBytesRead.map { Double($0) / 1_048_576 } ?? 0
                    Self.logger.info(
                        "[CMP-AVP] loopback source rate=\(String(format: "%.1f", mbps), privacy: .public)Mbps totalRead=\(String(format: "%.1f", mib), privacy: .public)MiB"
                    )
                }
                // First measurable bitrate (or a meaningful change) — re-
                // evaluate the steady-state forward buffer so a high-
                // bitrate source doesn't sit on the conservative 30 s
                // default after the gate has already been released.
                if previousBitrate == nil, bitsPerSecond != nil,
                   let item = self.currentItem,
                   self.canRampLoopbackBufferToSteadyState {
                    self.rampLoopbackBufferToSteadyStateIfNeeded(for: item)
                }
            }
        }
        writer.onGeneratedMediaStats = { [weak self] generatedStats in
            DispatchQueue.main.async {
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                self.latestLoopbackGeneratedStats = generatedStats
                self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                if let item = self.currentItem,
                   self.canRampLoopbackBufferToSteadyState {
                    self.rampLoopbackBufferToSteadyStateIfNeeded(for: item)
                    self.sampleLocalLoopbackEdge(item: item, referenceTime: self.currentTime(), trigger: "generated_stats")
                }
            }
        }
        // HDR10+ badge: install the one-shot SEI scan only for plain HEVC PQ
        // sessions whose label currently reads "HDR10" and has not flipped.
        // DV Profile 8 sources keep their validated labels (scan not installed).
        if sessionSpec.videoMode == .passthroughHEVC,
           sessionSpec.manifestMetadata.videoRange != "HLG",
           sessionSpec.manifestMetadata.videoRange != "SDR",
           !loopbackHDR10PlusDetected {
            writer.onHDR10PlusMetadataDetected = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isDisposed else { return }
                    guard self.activeLoopbackSessionID == sessionID else { return }
                    self.loopbackHDR10PlusDetected = true
                    cmpLog("[CMP-AVP] hdr10+ dynamic metadata detected — badge flips HDR10 → HDR10+")
                    self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                }
            }
        }
        segmentWriter = writer
        writer.start()
    }

    private func handleFirstSegmentReady(playlistName: String, sessionID: String) {
        guard activeLoopbackSessionID == sessionID else { return }
        guard !isDisposed, currentItem == nil, let server = segmentServer else { return }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(playlistName)")!
        cmpLog("[CMP-AVP] local playlist ready \(url.absoluteString)")
        if ttffFirstSegmentMs == nil { ttffFirstSegmentMs = ttffElapsedMs() }
        logTVDisplayManagerState(context: "before_prepare_\(playlistName)")
        // The criteria write always happens synchronously before the item is
        // created; only the gated non-DV HDR path additionally holds the item
        // back until the HDMI negotiation settles, so the item's startup
        // probes don't race the mode switch.
        let needsModeSettleWait = applyTVDisplayCriteriaForLoopbackIfNeeded(
            context: "before_prepare_\(playlistName)"
        )
        guard needsModeSettleWait else {
            attachLoopbackItem(url: url)
            return
        }
        #if os(tvOS)
        displayModeSettleTask?.cancel()
        displayModeSettleTask = Task { @MainActor [weak self] in
            let hosted = await TVDisplayCriteria.waitForModeSwitchSettle()
            guard let self, !self.isDisposed, !Task.isCancelled,
                  self.activeLoopbackSessionID == sessionID,
                  self.currentItem == nil else { return }
            // Panel-readiness snapshot. No manifest gating is needed today:
            // the loopback route always serves AVPlayer the media playlist
            // (never the VIDEO-RANGE-claiming master artifact), which is the
            // safe hosting for an SDR panel — AVPlayer tonemaps. Logged as
            // the gate signal for any future master-playlist serving.
            cmpLog("[CMP-AVP] tv display settle hdrHosted=\(hosted ? 1 : 0)")
            self.attachLoopbackItem(url: url)
        }
        #else
        attachLoopbackItem(url: url)
        #endif
    }

    /// Hands AVPlayer its loopback item plus the VOD resume pre-seek. Split
    /// from `handleFirstSegmentReady` so the gated HDR path can defer it
    /// behind the display-mode settle wait.
    private func attachLoopbackItem(url: URL) {
        // The local loopback server is an in-app HTTP surface. Remote auth
        // headers are only for libavformat's source fetch and should not be
        // propagated into AVPlayer's localhost HLS requests.
        prepareAssetPlayback(url: url, headers: [:])
        issueVODResumePreSeekIfNeeded(context: "first_segment")
    }

    /// Resume: aim AVPlayer's very first media fetches at the resume
    /// segment. The producer is anchored there; without this, the
    /// item buffers from position 0 whose segments may never exist.
    /// Re-issued after a startup-watchdog item reload for the same reason.
    private func issueVODResumePreSeekIfNeeded(context: String) {
        guard case .some(.siloLoopback(let spec)) = currentSourceStrategy,
              spec.servingMode == .vodPlan,
              pendingStartTime > 0 else { return }
        let target = max(0, playerTime(forMediaTime: pendingStartTime))
        avPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        cmpLog("[CMP-AVP] vod resume pre-seek player=\(target) media=\(pendingStartTime) context=\(context)")
    }

    private func prepareAssetPlayback(url: URL, headers: [String: String]) {
        activateAudioSession()
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // For the local DV loopback the writer produces segments much faster
        // than realtime against a localhost server, so AVPlayer's default
        // automatic buffer-up was waiting for many of the source's long
        // (~30s, one per GOP) fragments before declaring readyToPlay. Tell
        // it to start as soon as the first fragment is decodable and cap
        // forward buffer at one fragment-equivalent for *startup only*.
        //
        // After the initial-video-display gate releases (see
        // `finishInitialVideoDisplayGate`) we ramp the forward buffer up
        // to `loopbackSteadyStateForwardBuffer` and re-enable
        // `automaticallyWaitsToMinimizeStalling` so AVPlayer can ride out
        // network jitter on high-bitrate sources where the WAN headroom
        // over the source's bitrate is small (e.g. 4K DV at 72 Mbps over
        // 80 Mbps).
        //
        // Remote routes keep AVPlayer's defaults since automatic buffering
        // is genuinely useful over the WAN.
        if case .siloLoopback = currentSourceStrategy {
            avPlayer.automaticallyWaitsToMinimizeStalling = false
            item.preferredForwardBufferDuration = Self.loopbackStartupForwardBuffer
            // Do not let AVPlayer poll the local EVENT playlist while paused.
            // Under disk pressure the writer may pause appends until playback
            // frees spill capacity; paused polling can therefore see an
            // unchanged playlist long enough for CoreMedia to fail the item.
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        }
        currentItem = item
        beginInitialVideoDisplayGate()
        attachItemObservers(item)
        avPlayer.replaceCurrentItem(with: item)
        armLoopbackStartupWatchdogIfNeeded()
        installPeriodicTimeObserver()
        installSubtitleDisplayLink()
    }

    private func activateAudioSession() {
        #if os(macOS)
        return
        #else
        guard !audioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
            audioSessionActive = true
        } catch {
            let message = "AVPlayer audio session setup failed: \(error.localizedDescription)"
            cmpLog("[CMP-AVP] ERROR: \(message)")
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(macOS)
        return
        #else
        guard audioSessionActive else { return }
        audioSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation]
        )
        #endif
    }

    private func configureEmbeddedSubtitleExtraction(for strategy: SourceStrategy) {
        let source: AVPlayerSubtitleExtractionSource?
        switch strategy {
        case .remoteDirect(let url, let headers):
            source = AVPlayerSubtitleExtractionSource(
                mediaURL: url,
                requestHeaders: headers,
                routeLabel: "remoteDirect",
                seekable: true
            )
        case .siloLoopback(let spec):
            source = AVPlayerSubtitleExtractionSource(
                mediaURL: spec.sourceURL,
                requestHeaders: spec.headers,
                routeLabel: "siloLoopback",
                seekable: true
            )
        case .remoteHLS:
            source = nil
        }
        embeddedSubtitleExtractor?.configure(source: source)
    }

    /// The tap store survives producer restarts and reanchors (same source,
    /// same timeline); switching to a different source resets it.
    private func ensureLoopbackSubtitleTap(for sourceURL: URL) -> LoopbackSubtitleTap {
        if let tap = loopbackSubtitleTap, loopbackSubtitleTapSourceURL == sourceURL {
            return tap
        }
        let tap = LoopbackSubtitleTap()
        loopbackSubtitleTap = tap
        loopbackSubtitleTapSourceURL = sourceURL
        return tap
    }

    /// True when `trackId` is an embedded text track the tap can serve.
    /// Loopback-route only: other routes have no writer harvesting cues,
    /// so a leftover store must not shadow the extractor.
    private func tapServesEmbeddedTrack(_ trackId: Int64) -> Bool {
        guard case .some(.siloLoopback) = currentSourceStrategy,
              SubtitleTrackIdSpace.isAVPlayerEmbedded(trackId),
              let tap = loopbackSubtitleTap else { return false }
        let streamIndex = Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
        return tap.hasTrack(forStream: streamIndex)
    }

    /// (Re)install the libass track for a tap-served stream and feed it:
    /// a fresh track, the full backfill snapshot, then live forwarding —
    /// exactly once per cue (libass ReadOrder dedup is disabled). Also the
    /// post-seek resync: re-running replaces the track wholesale, so
    /// flushed state can't double-feed.
    private func activateTapSubtitleTrack(trackId: Int64, slot: SubtitleSlot) {
        guard let tap = loopbackSubtitleTap,
              let session = subtitleSession else { return }
        let streamIndex = Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
        guard let info = tap.trackInfo(forStream: streamIndex) else { return }

        if info.header.isEmpty {
            session.openEmbedded(
                slot: slot, isNativeASS: info.isNativeASS,
                extradata: nil, extradataSize: 0
            )
        } else {
            info.header.withUnsafeBytes { raw in
                session.openEmbedded(
                    slot: slot,
                    isNativeASS: info.isNativeASS,
                    extradata: raw.bindMemory(to: UInt8.self).baseAddress,
                    extradataSize: info.header.count
                )
            }
        }
        let backfill = tap.activate(streamIndex: streamIndex) { [weak session] cue in
            session?.feedEmbedded(
                slot: slot,
                eventText: cue.eventText,
                startMs: cue.startMs,
                durationMs: cue.durationMs
            )
        }
        for cue in backfill {
            session.feedEmbedded(
                slot: slot,
                eventText: cue.eventText,
                startMs: cue.startMs,
                durationMs: cue.durationMs
            )
        }
        print("[CMP-TAP] activated stream=\(streamIndex) backfill=\(backfill.count)")
    }

    /// After a completed in-item seek: extractor-owned slots re-seek their
    /// side demuxer (the extractor only iterates its own selections, so
    /// this is a no-op for tap-served slots), and a tap-served primary
    /// re-installs + re-feeds (the session's flushOnSeek dropped its
    /// libass events).
    private func resyncControlledSubtitlesAfterSeek(mediaSeconds: Double) {
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        if let trackId = selectedControlledSubtitleTrackId,
           tapServesEmbeddedTrack(trackId) {
            activateTapSubtitleTrack(trackId: trackId, slot: .primary)
        }
    }

    private func installPeriodicTimeObserver() {
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }

        let interval = CMTime(value: 1, timescale: 10)
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isDisposed else { return }
            if self.isSeekPending { return }
            if case .siloLoopback = self.currentSourceStrategy {
                self.setLoopbackPlaybackClock(time.seconds)
            }
            self.releaseInitialVideoDisplayGateIfPlaybackAdvanced(currentTime: time.seconds)
            self.ttffEmitIfNeeded(currentTime: time.seconds)
            self.onTimeChange?(time.seconds)
            self.emitBufferedAhead(referenceTime: time.seconds)
            self.emitPlaybackStats(referenceTime: time.seconds)
            if let item = self.currentItem {
                self.sampleLocalLoopbackEdge(item: item, referenceTime: time.seconds, trigger: "time")
            }
        }
    }

    private func installSubtitleDisplayLink() {
        subtitleDisplayLink?.invalidate()
        #if os(macOS)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.isDisposed, !self.isSeekPending else { return }
            self.pumpSubtitleOverlay(referenceTime: self.mediaTime(for: self.avPlayer.currentTime().seconds))
        }
        RunLoop.main.add(timer, forMode: .common)
        subtitleDisplayLink = timer
        #else
        let link = CADisplayLink(target: self, selector: #selector(subtitleDisplayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        subtitleDisplayLink = link
        #endif
    }

    #if !os(macOS)
    @objc private func subtitleDisplayLinkTick(_ link: CADisplayLink) {
        guard !isDisposed, !isSeekPending else { return }
        pumpSubtitleOverlay(referenceTime: mediaTime(for: avPlayer.currentTime().seconds))
    }
    #endif

    private func emitBufferedAhead(referenceTime: Double) {
        guard let item = currentItem, referenceTime.isFinite else { return }
        let ranges = item.loadedTimeRanges.map { $0.timeRangeValue }
        guard !ranges.isEmpty else {
            onBufferedAheadChange?(0)
            return
        }

        let aheadEnd = ranges
            .compactMap { range -> Double? in
                let start = range.start.seconds
                let end = (range.start + range.duration).seconds
                guard start.isFinite, end.isFinite, end > referenceTime else {
                    return nil
                }
                return start <= referenceTime ? end : nil
            }
            .max() ?? referenceTime

        onBufferedAheadChange?(max(0, aheadEnd - referenceTime))
    }

    private func emitPlaybackStats(referenceTime: Double, force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastStatsEmitWall >= 1.0 else { return }
        lastStatsEmitWall = now
        guard let item = currentItem else { return }

        Task { [weak self, item] in
            await self?.emitPlaybackStatsSnapshot(for: item, referenceTime: referenceTime)
        }
    }

    @MainActor
    private func emitPlaybackStatsSnapshot(for item: AVPlayerItem, referenceTime: Double) async {
        guard currentItem === item else { return }
        let accessEvent = item.accessLog()?.events.last
        let indicatedBitrate = positive(accessEvent?.indicatedBitrate)
        let shouldPublishNetworkStats = publishesRemoteAccessLogNetworkStats
        let observedBitrate = shouldPublishNetworkStats
            ? positive(accessEvent?.observedBitrate)
            : nil
        let videoFormat = await AVFoundationPlaybackIntrospection.videoFormat(for: item)
        let audio = await audioStats(for: item)
        guard currentItem === item else { return }

        var stats = PlaybackStats()
        stats.route = currentSourceStrategy.map(Self.displayRouteLabel)
        stats.source = sourceLabel(for: currentSourceStrategy)
        stats.video = PlaybackStats.MediaStream(
            codec: videoFormat.stream.codec ?? videoCodecLabel(for: currentSourceStrategy),
            detail: videoFormat.stream.detail ?? videoDetail(for: item),
            bitrateBps: indicatedBitrate ?? observedBitrate ?? videoFormat.stream.bitrateBps
        )
        // Prefer the format description of what AVPlayer is actually
        // playing (e.g. "Dolby Vision Profile 8 Level 6 (HDR10
        // compatible)") over the spec-derived expectation.
        stats.dynamicRange = videoFormat.dynamicRange ?? dynamicRangeLabel(for: currentSourceStrategy)
        stats.audio = audio
        stats.subtitles = selectedSubtitleLabel()
        stats.screenFrameRate = PlatformScreen.maximumFramesPerSecond
        stats.playbackRate = Double(avPlayer.rate == 0 ? avPlayer.defaultRate : avPlayer.rate)
        stats.bufferStatus = bufferStatus(for: item)
        stats.bufferedAheadSeconds = bufferedAheadSeconds(for: item, referenceTime: referenceTime)
        stats.bufferLoadCount = bufferLoadCount
        stats.observedBitrateBps = observedBitrate
        stats.indicatedBitrateBps = indicatedBitrate
        stats.currentDownloadBitrateBps = observedBitrate ?? loopbackSourceDownloadBitrateBps
        if let segmentStats = segmentStore?.stats() {
            stats.generatedAheadSeconds = max(0, segmentStats.generatedMediaSeconds - referenceTime)
            stats.generatedSegmentCount = segmentStats.segmentCount
            stats.generatedSpilledSegmentCount = segmentStats.spilledSegmentCount
            stats.segmentStoreBytes = segmentStats.memoryBytes
            stats.segmentStoreBudgetBytes = segmentStats.memoryBudgetBytes
            stats.segmentStoreTempSpillBytes = segmentStats.tempSpillBytes
            stats.segmentStoreTempSpillBudgetBytes = segmentStats.tempSpillBudgetBytes
            if segmentStats.tempSpillBudgetBytes > 0 {
                stats.segmentStoreTempSpillPercent = Double(segmentStats.tempSpillBytes)
                    / Double(segmentStats.tempSpillBudgetBytes) * 100
            }
            stats.segmentStoreDebugMirrorBytes = segmentStats.debugMirrorBytes
            stats.segmentServerRequestCount = segmentStats.requestCount
            stats.segmentServerBytesServed = segmentStats.bytesServed
            stats.segmentServerLastLatencyMs = segmentStats.lastRequestLatencyMs
            stats.segmentServerWaitCount = segmentStats.waitCount
        }
        if let generatedStats = latestLoopbackGeneratedStats {
            stats.generatedVisibleAheadSeconds = max(0, generatedStats.playlistVisibleEndSeconds - referenceTime)
            stats.generatedMediaBitrateBps = generatedStats.rollingBitrateBps
            stats.generatedLoopbackGeneration = generatedStats.generation
            stats.generatedPlaylistMediaSequence = "\(generatedStats.firstMediaSequence)-\(generatedStats.lastMediaSequence)"
            stats.generatedPlaylistVisibleRange = String(
                format: "%.1f-%.1f s",
                generatedStats.playlistVisibleStartSeconds,
                generatedStats.playlistVisibleEndSeconds
            )
            stats.generatedPlaylistBytes = generatedStats.playlistBodyBytes
            stats.generatedPlaylistHash = generatedStats.playlistBodyHash
            stats.generatedDurationSource = generatedStats.durationSource
        }
        if let observedBitrate, let indicatedBitrate, indicatedBitrate > 0 {
            stats.streamSpeed = observedBitrate / indicatedBitrate
        } else if let loopbackSourceDownloadBitrateBps,
                  let averageFileBitrateBps = stats.averageFileBitrateBps,
                  averageFileBitrateBps > 0 {
            stats.streamSpeed = loopbackSourceDownloadBitrateBps / averageFileBitrateBps
        }
        if shouldPublishNetworkStats,
           let bytes = accessEvent?.numberOfBytesTransferred,
           bytes > 0 {
            stats.bytesTransferred = bytes
        } else if !shouldPublishNetworkStats {
            stats.bytesTransferred = loopbackSourceBytesRead
        }
        stats.deviceInfo = Self.deviceInfo()
        stats.freeDiskSpaceBytes = Self.freeDiskSpaceBytes()
        stats.volumeAvailableCapacityBytes = Self.volumeAvailableCapacityBytes()
        onPlaybackStatsChange?(stats)
    }

    private var publishesRemoteAccessLogNetworkStats: Bool {
        switch currentSourceStrategy {
        case .siloLoopback:
            return false
        case .remoteHLS, .remoteDirect:
            return true
        case .none:
            return false
        }
    }

    private func sourceLabel(for strategy: SourceStrategy?) -> String? {
        switch strategy {
        case .remoteHLS(let url, _), .remoteDirect(let url, _):
            return url.host ?? url.scheme
        case .siloLoopback(let spec):
            // The loopback is an implementation detail; the user-meaningful
            // source is the origin the media is actually fetched from.
            return spec.sourceURL.host ?? "local"
        case .none:
            return nil
        }
    }

    private func videoCodecLabel(for strategy: SourceStrategy?) -> String? {
        switch strategy {
        case .siloLoopback(let spec):
            return spec.videoMode.sampleEntryCodec
        case .remoteHLS:
            return "hls"
        case .remoteDirect, .none:
            return nil
        }
    }

    private func videoDetail(for item: AVPlayerItem) -> String? {
        let size = item.presentationSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return nil
        }
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    @MainActor
    private func audioStats(for item: AVPlayerItem) async -> PlaybackStats.MediaStream {
        if case .siloLoopback(let spec) = currentSourceStrategy {
            let outputMode = Self.audioOutputModeLabel(spec.selectedAudio.outputMode)
            let liveStream = await AVFoundationPlaybackIntrospection.audioStream(for: item)
            return PlaybackStats.MediaStream(
                codec: liveStream.codec ?? outputMode,
                detail: audioDetail(
                    channels: spec.selectedAudio.sourceChannelCount,
                    layout: spec.selectedAudio.sourceChannelLayout,
                    suffix: loopbackAudioSuffix(sourceCodec: spec.selectedAudio.sourceCodec, outputMode: outputMode, preservesAtmos: spec.selectedAudio.preservesAtmos)
                ),
                bitrateBps: liveStream.bitrateBps
            )
        }

        guard let state = audioSelectionState,
              let option = item.currentMediaSelection.selectedMediaOption(in: state.group) else {
            return await AVFoundationPlaybackIntrospection.audioStream(for: item)
        }
        let selectionLabel = normalizedTitle(for: option) ?? languageCode(for: option)
        let liveStream = await AVFoundationPlaybackIntrospection.audioStream(for: item, selectionHint: selectionLabel)
        return PlaybackStats.MediaStream(
            codec: liveStream.codec ?? codecLabel(for: option),
            detail: joined([liveStream.detail, selectionLabel]),
            bitrateBps: liveStream.bitrateBps
        )
    }

    private func selectedSubtitleLabel() -> String? {
        if let selectedControlledSubtitleTrackId,
           let track = embeddedSubtitleExtractor?
            .playerTracks(selectedPrimaryTrackId: selectedControlledSubtitleTrackId)
            .first(where: { $0.trackId == selectedControlledSubtitleTrackId }) {
            return track.title ?? track.lang ?? track.codec ?? "On"
        }
        if let selectedControlledSubtitleTrackId,
           let descriptor = sidecarDescriptorsByTrackId[selectedControlledSubtitleTrackId] {
            return descriptor.label ?? descriptor.language ?? descriptor.codec ?? "On"
        }
        guard let state = subtitleSelectionState,
              let option = currentItem?.currentMediaSelection.selectedMediaOption(in: state.group) else {
            return "Off"
        }
        return normalizedTitle(for: option) ?? languageCode(for: option) ?? codecLabel(for: option) ?? "On"
    }

    private func audioDetail(channels: Int?, layout: String?, suffix: String?) -> String? {
        var parts: [String] = []
        if let layout, !layout.isEmpty {
            parts.append(layout)
        } else if let channels, channels > 0 {
            parts.append("\(channels) ch")
        }
        if let suffix, !suffix.isEmpty {
            parts.append(suffix)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func dynamicRangeLabel(for strategy: SourceStrategy?) -> String? {
        guard case .siloLoopback(let spec) = strategy else { return nil }
        switch spec.videoMode {
        case .passthroughProfile5:
            return "Dolby Vision (Profile \(spec.manifestMetadata.advertisedDolbyVisionProfile ?? 5))"
        case .convertProfile7To81:
            return "Dolby Vision (Profile 7 → 8.1)"
        case .passthroughProfile8(.hdr10):
            return "Dolby Vision (Profile 8.1)"
        case .passthroughProfile8(.hlg):
            return "Dolby Vision (Profile 8.4)"
        case .passthroughHEVC:
            switch spec.manifestMetadata.videoRange {
            case "HLG": return "HLG"
            case "SDR": return "SDR"
            default: return loopbackHDR10PlusDetected ? "HDR10+" : "HDR10"
            }
        case .passthroughH264:
            return "SDR"
        }
    }

    private func shouldPreserveTVDisplayCriteriaDuringReload(
        from current: SourceStrategy?,
        to next: SourceStrategy
    ) -> Bool {
        #if os(tvOS)
        guard case .siloLoopback(let currentSpec) = current,
              case .siloLoopback(let nextSpec) = next else {
            return false
        }
        // With the HDR gate off this reduces to the shipped DV→DV rule
        // (non-DV modes select `.none`); with it on, same-range HDR10/HLG
        // reloads also keep their criteria so an audio-track change doesn't
        // renegotiate the HDMI mode.
        let hdrGateEnabled = HDRDisplayCriteriaPolicy.isEnabled()
        return HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
            current: HDRDisplayCriteriaPolicy.selection(
                videoMode: currentSpec.videoMode,
                manifestVideoRange: currentSpec.manifestMetadata.videoRange,
                hdrGateEnabled: hdrGateEnabled
            ),
            next: HDRDisplayCriteriaPolicy.selection(
                videoMode: nextSpec.videoMode,
                manifestVideoRange: nextSpec.manifestMetadata.videoRange,
                hdrGateEnabled: hdrGateEnabled
            ),
            currentRate: currentSpec.sourceVideoFrameRate ?? 24.0,
            nextRate: nextSpec.sourceVideoFrameRate ?? 24.0
        )
        #else
        return false
        #endif
    }

    private func loopbackAudioSuffix(sourceCodec: String?, outputMode: String, preservesAtmos: Bool) -> String {
        var parts: [String] = []
        if let sourceCodec,
           !sourceCodec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sourceCodec.caseInsensitiveCompare(outputMode) != .orderedSame {
            parts.append("from \(sourceCodec)")
        }
        if preservesAtmos {
            parts.append("receiver Atmos validation required")
        }
        if parts.isEmpty {
            parts.append(outputMode)
        }
        return parts.joined(separator: ", ")
    }

    private func joined(_ parts: [String?]) -> String? {
        let values = parts.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private func bufferStatus(for item: AVPlayerItem) -> String {
        if item.isPlaybackBufferEmpty { return "Buffering" }
        if item.isPlaybackLikelyToKeepUp { return "Healthy" }
        return "Filling"
    }

    private func bufferedAheadSeconds(for item: AVPlayerItem, referenceTime: Double) -> Double? {
        loadedRangeEnd(for: item, referenceTime: referenceTime).map { max(0, $0 - referenceTime) }
    }

    private func loadedRangeEnd(for item: AVPlayerItem, referenceTime: Double) -> Double? {
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        let end = ranges.compactMap { range -> Double? in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite, end > referenceTime, start <= referenceTime else {
                return nil
            }
            return end
        }.max()
        return end
    }

    private func describeLoadedRanges(_ item: AVPlayerItem) -> String {
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        guard !ranges.isEmpty else { return "[]" }
        return ranges.map { range in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            return String(format: "%.2f-%.2f", start, end)
        }.joined(separator: ",")
    }

    private func describeSeekableRanges(_ item: AVPlayerItem) -> String {
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard !ranges.isEmpty else { return "[]" }
        return ranges.map { range in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            return String(format: "%.2f-%.2f", start, end)
        }.joined(separator: ",")
    }

    private func installLoopbackPlayheadWatchdog() {
        loopbackPlayheadWatchdog?.invalidate()
        let timer = Timer(
            timeInterval: Self.playheadWatchdogTickSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.loopbackPlayheadWatchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        loopbackPlayheadWatchdog = timer
    }

    /// Independent wall-clock check for a local DV loopback playhead that has
    /// stopped advancing while AVPlayer believes it is playing and generated
    /// media is available ahead of it. This is the failure mode the existing
    /// recovery hooks miss: `.AVPlayerItemPlaybackStalled` only fires on buffer
    /// starvation, the edge watchdog requires the buffered edge to sit at the
    /// playhead, and the periodic time observer stops firing the moment the
    /// playhead freezes. `timeControlStatus` distinguishes a genuine wedge from
    /// a user pause, so a paused player is never reanchored.
    private func loopbackPlayheadWatchdogTick() {
        guard !isDisposed,
              case .siloLoopback = currentSourceStrategy,
              let item = currentItem,
              didFireFileLoaded,
              !isSeekPending else { return }

        let now = CACurrentMediaTime()
        let position = currentTime()
        guard position.isFinite else { return }

        // Movement in EITHER direction counts as alive. Comparing with `>`
        // alone left the high-water mark stale across backward in-item
        // seeks: after a back-scrub the playhead sits below the pre-scrub
        // mark for tens of seconds of healthy playback, `stationaryFor`
        // climbs the whole time, and the watchdog "recovers" a route that
        // was never wedged (nudge → item reloads that reset a full buffer →
        // reanchor budget exhausted → spurious PlayerCore fallback).
        if watchdogLastPlayheadSeconds < 0 || abs(position - watchdogLastPlayheadSeconds) > 0.05 {
            watchdogLastPlayheadSeconds = position
            watchdogLastAdvanceWall = now
        }
        let stationaryFor = watchdogLastAdvanceWall > 0 ? now - watchdogLastAdvanceWall : 0

        let timeControlStatus = avPlayer.timeControlStatus
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: position) ?? 0
        let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds
            ?? 0
        let generatedAhead = max(0, generatedEnd - position)

        let statusLabel: String
        switch timeControlStatus {
        case .paused: statusLabel = "paused"
        case .waitingToPlayAtSpecifiedRate: statusLabel = "waiting"
        case .playing: statusLabel = "playing"
        @unknown default: statusLabel = "unknown"
        }

        // Periodic transport-state telemetry so a captured stall can be
        // classified (pause vs. wedge) directly from the log.
        if now - watchdogLastStateLogWall >= 3 {
            watchdogLastStateLogWall = now
            // Temporary [CMP-MEM]: attribute footprint growth per tick —
            // jetsam-accounted footprint + remaining headroom, alongside the
            // app-managed pools (segment store RAM, source proxy cache) so a
            // memory termination capture shows which pool was growing.
            let mem = Self.memoryFootprintMiB()
            let storeMiB = Double(segmentStore?.stats().memoryBytes ?? 0) / 1_048_576
            let proxyMiB = Double(proxyStatsProvider?()?.cachedBytes ?? 0) / 1_048_576
            let memSuffix: String
            if let mem {
                memSuffix = String(
                    format: " footprint=%.1fMiB avail=%.1fMiB store=%.1fMiB proxy=%.1fMiB",
                    mem.footprint, mem.available, storeMiB, proxyMiB
                )
            } else {
                memSuffix = String(
                    format: " footprint=? avail=? store=%.1fMiB proxy=%.1fMiB",
                    storeMiB, proxyMiB
                )
            }
            Self.logger.info(
                "[CMP-AVP] loopback playhead state pos=\(position, privacy: .public) tc=\(statusLabel, privacy: .public) rate=\(self.avPlayer.rate, privacy: .public) paused=\(self.isUserPaused ? 1 : 0, privacy: .public) bufAhead=\(bufferedAhead, privacy: .public) generatedAhead=\(generatedAhead, privacy: .public) stationaryFor=\(stationaryFor, privacy: .public)\(memSuffix, privacy: .public)"
            )
            if case .some(.siloLoopback(let stateSpec)) = currentSourceStrategy,
               stateSpec.servingMode == .vodPlan {
                // OSLog is invisible to the devicectl console; mirror the
                // transport state so on-device render stalls (frozen picture,
                // advancing audio clock) are diagnosable from the capture.
                print("[CMP-AVP] vod state pos=\(String(format: "%.2f", position)) tc=\(statusLabel) rate=\(avPlayer.rate) bufAhead=\(String(format: "%.1f", bufferedAhead)) stationaryFor=\(String(format: "%.1f", stationaryFor))\(memSuffix)")
            }
        }

        // Producer-dead starvation: waiting on an empty buffer with no
        // successful segment serves for a sustained stretch. The reanchor
        // path below can't help (it needs generated media ahead), so
        // escalate straight to the route fallback rather than freezing.
        if !isUserPaused,
           timeControlStatus == .waitingToPlayAtSpecifiedRate,
           bufferedAhead < 2.0,
           stationaryFor >= Self.playheadWatchdogStarvationEscalateSeconds,
           (segmentStore?.secondsSinceLastSegmentServe() ?? .infinity)
               >= Self.playheadWatchdogStarvationServeQuietSeconds,
           !didEscalateLoopbackStall {
            didEscalateLoopbackStall = true
            cmpLog(
                "[CMP-AVP] loopback starvation: playhead frozen \(Int(stationaryFor))s with empty buffer and no segment serves; escalating to route fallback"
            )
            onLoopbackStallUnrecoverable?("loopback_starvation")
            return
        }

        // Only a wedge qualifies: AVPlayer should be playing (not user-paused,
        // not legitimately waiting on an empty buffer) yet the playhead is
        // stationary while media is generated ahead of it.
        let believesPlayable = timeControlStatus == .playing
            || (timeControlStatus == .waitingToPlayAtSpecifiedRate && bufferedAhead >= 2.0)
        guard !isUserPaused,
              believesPlayable,
              stationaryFor >= Self.playheadWatchdogStallSeconds,
              generatedAhead >= Self.playheadWatchdogMinGeneratedAhead else {
            return
        }

        // Bound reanchors within a rolling window; escalate to a route fallback
        // rather than reanchoring a route that will not recover.
        if watchdogReanchorWindowStartWall == 0
            || now - watchdogReanchorWindowStartWall > Self.playheadWatchdogReanchorWindowSeconds {
            watchdogReanchorWindowStartWall = now
            watchdogReanchorCount = 0
            didEscalateLoopbackStall = false
        }

        if watchdogReanchorCount >= Self.playheadWatchdogMaxReanchors {
            guard !didEscalateLoopbackStall else { return }
            didEscalateLoopbackStall = true
            Self.logger.error(
                "[CMP-AVP] local loopback playhead_watchdog exhausted reanchors=\(self.watchdogReanchorCount, privacy: .public) pos=\(position, privacy: .public) stationaryFor=\(stationaryFor, privacy: .public); escalating to route fallback"
            )
            onLoopbackStallUnrecoverable?("playhead_watchdog")
            return
        }

        if case .some(.siloLoopback(let servingSpec)) = currentSourceStrategy,
           servingSpec.servingMode == .vodPlan,
           let sinceServe = segmentStore?.secondsSinceLastSegmentServe(),
           sinceServe < 4.0 {
            // The consumer is actively pulling segments — a post-seek buffer
            // fill, not a wedge (the fetch-high-water signal). Recovery here
            // would kill the producer mid-march and reset AVPlayer's buffer,
            // looping the fill forever (living-room bug 3).
            return
        }

        watchdogReanchorCount += 1
        Self.logger.error(
            "[CMP-AVP] local loopback playhead_watchdog trigger attempt=\(self.watchdogReanchorCount, privacy: .public) pos=\(position, privacy: .public) tc=\(statusLabel, privacy: .public) bufAhead=\(bufferedAhead, privacy: .public) generatedAhead=\(generatedAhead, privacy: .public) stationaryFor=\(stationaryFor, privacy: .public)"
        )
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy,
           spec.servingMode == .vodPlan {
            let attempt = watchdogReanchorCount
            Task { @MainActor [weak self] in
                self?.performVODStallRecovery(attempt: attempt, frozenPosition: position)
            }
            return
        }
        recoverLocalLoopbackStallIfNeeded(item: item, requireBufferedEdge: false, reason: "playhead_watchdog")
    }

    private func sampleLocalLoopbackEdge(item: AVPlayerItem, referenceTime: Double, trigger: String) {
        guard case .siloLoopback = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isUserPaused,
              !isSeekPending,
              referenceTime.isFinite,
              let generatedStats = latestLoopbackGeneratedStats else {
            return
        }
        let now = CACurrentMediaTime()
        let loadedEnd = loadedRangeEnd(for: item, referenceTime: referenceTime) ?? referenceTime
        if loopbackEdgeWatch == nil {
            loopbackEdgeWatch = LoopbackEdgeWatch(
                lastLoadedEnd: loadedEnd,
                lastLoadedEndAdvancedAt: now,
                lastPlaylistEnd: generatedStats.playlistVisibleEndSeconds,
                lastPlaylistHash: generatedStats.playlistBodyHash
            )
            return
        }

        guard var watch = loopbackEdgeWatch else { return }
        let loadedAdvanced = loadedEnd > watch.lastLoadedEnd + 0.25
        if loadedAdvanced {
            watch.lastLoadedEnd = loadedEnd
            watch.lastLoadedEndAdvancedAt = now
        }
        let playlistAdvanced = generatedStats.playlistVisibleEndSeconds > watch.lastPlaylistEnd + 0.25
            || generatedStats.playlistBodyHash != watch.lastPlaylistHash
        watch.lastPlaylistEnd = max(watch.lastPlaylistEnd, generatedStats.playlistVisibleEndSeconds)
        watch.lastPlaylistHash = generatedStats.playlistBodyHash
        loopbackEdgeWatch = watch

        let targetDuration = max(1.0, Double(generatedStats.targetDuration))
        let watchdogDelay = max(3.0, targetDuration * 2.0 + 1.0)
        let loadedAhead = max(0, loadedEnd - referenceTime)
        let visibleAhead = max(0, generatedStats.playlistVisibleEndSeconds - referenceTime)
        guard playlistAdvanced,
              !loadedAdvanced,
              loadedAhead <= 1.0,
              visibleAhead >= max(6.0, targetDuration + generatedStats.longestSegmentDuration),
              now - watch.lastLoadedEndAdvancedAt >= watchdogDelay else {
            return
        }

        Self.logger.info(
            "[CMP-AVP] edge_watchdog trigger=\(trigger, privacy: .public) player=\(referenceTime, privacy: .public) loadedEnd=\(loadedEnd, privacy: .public) loadedAhead=\(loadedAhead, privacy: .public) playlistStart=\(generatedStats.playlistVisibleStartSeconds, privacy: .public) playlistEnd=\(generatedStats.playlistVisibleEndSeconds, privacy: .public) visibleAhead=\(visibleAhead, privacy: .public) mediaSeq=\(generatedStats.firstMediaSequence, privacy: .public)-\(generatedStats.lastMediaSequence, privacy: .public) targetDuration=\(generatedStats.targetDuration, privacy: .public) longestSegment=\(generatedStats.longestSegmentDuration, privacy: .public) playlistBytes=\(generatedStats.playlistBodyBytes, privacy: .public) playlistHash=\(generatedStats.playlistBodyHash, privacy: .public) forwardBuffer=\(item.preferredForwardBufferDuration, privacy: .public) loadedRanges=\(self.describeLoadedRanges(item), privacy: .public) seekableRanges=\(self.describeSeekableRanges(item), privacy: .public)"
        )
        recoverLocalLoopbackStallIfNeeded(item: item, requireBufferedEdge: true, reason: "edge_watchdog")
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func deviceInfo() -> String {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        #if os(macOS)
        let model = Host.current().localizedName ?? "Mac"
        #else
        let model = UIDevice.current.model
        #endif
        return "\(model) / \(String(format: "%.0f", memoryGB)) GB"
    }

    private static func freeDiskSpaceBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func volumeAvailableCapacityBytes() -> Int64? {
        #if os(tvOS)
        return freeDiskSpaceBytes()
        #else
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    private static func audioOutputModeLabel(_ mode: LoopbackSessionSpec.AudioOutputMode) -> String {
        switch mode {
        case .copy: return "copy"
        case .transcodeFLAC: return "flac"
        case .requireFLAC: return "flac(required)"
        case .transcodeEC3: return "ec-3"
        case .transcodeAC3: return "ac-3"
        case .transcodeAAC: return "aac"
        }
    }

    private func attachItemObservers(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                switch item.status {
                case .readyToPlay:
                    if self.ttffReadyMs == nil { self.ttffReadyMs = self.ttffElapsedMs() }
                    self.cancelLoopbackStartupWatchdog()
                    self.attemptInitialPlaybackStart(for: item, trigger: "status.readyToPlay")
                case .failed:
                    self.cancelLoopbackStartupWatchdog()
                    self.reportItemFailure(item)
                default:
                    break
                }
            }
        }

        rateObs = avPlayer.observe(\.rate, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.onPauseChange?(self.isUserPaused)
            }
        }

        timeControlObs = avPlayer.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                guard case .siloLoopback = self.currentSourceStrategy else { return }
                let status: String
                switch player.timeControlStatus {
                case .paused:
                    status = "paused"
                case .waitingToPlayAtSpecifiedRate:
                    status = "waiting"
                case .playing:
                    status = "playing"
                @unknown default:
                    status = "unknown"
                }
                let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
                Self.logger.info(
                    "[CMP-AVP] timeControlStatus=\(status, privacy: .public) reason=\(reason, privacy: .public) rate=\(player.rate, privacy: .public) current=\(player.currentTime().seconds, privacy: .public)"
                )
            }
        }

        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                if item.isPlaybackBufferEmpty {
                    self.bufferLoadCount += 1
                    if case .siloLoopback = self.currentSourceStrategy {
                        Self.logger.info(
                            "[CMP-AVP] item buffer empty current=\(self.currentTime(), privacy: .public) loadedRanges=\(self.describeLoadedRanges(item), privacy: .public)"
                        )
                    }
                    self.onBufferingChange?(true)
                    self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                }
            }
        }

        bufferFullObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                if item.isPlaybackLikelyToKeepUp {
                    self.onBufferingChange?(false)
                    self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                    self.resumeLocalLoopbackPlaybackIfNeeded(for: item, trigger: "likely_to_keep_up")
                }
            }
        }

        durationObs = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.onDurationChange?(duration)
            }
        }

        loadedRangesObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.emitBufferedAhead(referenceTime: self.currentTime())
                self.attemptInitialPlaybackStart(for: item, trigger: "loadedTimeRanges")
                self.resumeLocalLoopbackPlaybackIfNeeded(for: item, trigger: "loaded_ranges")
            }
        }

        seekableRangesObs = item.observe(\.seekableTimeRanges, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.attemptInitialPlaybackStart(for: item, trigger: "seekableTimeRanges")
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDisposed else { return }
            self.onEndOfFile?()
        }

        itemPlaybackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDisposed else { return }
            Self.logger.info(
                "[CMP-AVP] item playback stalled current=\(self.currentTime(), privacy: .public) loadedRanges=\(self.describeLoadedRanges(item), privacy: .public)"
            )
            self.recoverLocalLoopbackStallIfNeeded(item: item)
        }

        itemFailedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self, !self.isDisposed else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Self.logger.info(
                "[CMP-AVP] item failed to play to end current=\(self.currentTime(), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            self.recoverLocalLoopbackFailureIfNeeded(item: item, error: error)
        }

        // AVPlayer surfaces HLS-level trouble (404s, playlist parse errors,
        // format rejections) as errorLog entries without ever flipping the
        // item to .failed — the "spinner forever" class. Log every entry;
        // -15628 is CoreMedia's loader-poison signature, after which the
        // item will never post a stall or become ready, so escalate the
        // startup recovery ladder immediately instead of waiting for the
        // fetch-freeze window to notice.
        itemErrorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self, !self.isDisposed,
                  let item, item === self.currentItem,
                  let event = item.errorLog()?.events.last else { return }
            cmpLog(
                "[CMP-AVP] item errorLog status=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(event.uri ?? "-") comment=\(event.errorComment ?? "-")"
            )
            if event.errorStatusCode == -15628,
               !self.didFireFileLoaded,
               case .siloLoopback = self.currentSourceStrategy {
                self.escalateLoopbackStartupRecovery(trigger: "errorLog_-15628")
            }
        }
    }

    /// Tears down every observer scoped to the current AVPlayerItem (plus
    /// the player-level KVO that `attachItemObservers` re-creates). Shared
    /// by full disposal and the startup watchdog's in-place item reload.
    private func detachPerItemObservers() {
        statusObs?.invalidate(); statusObs = nil
        rateObs?.invalidate(); rateObs = nil
        timeControlObs?.invalidate(); timeControlObs = nil
        bufferFullObs?.invalidate(); bufferFullObs = nil
        bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
        durationObs?.invalidate(); durationObs = nil
        loadedRangesObs?.invalidate(); loadedRangesObs = nil
        seekableRangesObs?.invalidate(); seekableRangesObs = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = itemPlaybackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            itemPlaybackStalledObserver = nil
        }
        if let observer = itemFailedToEndObserver {
            NotificationCenter.default.removeObserver(observer)
            itemFailedToEndObserver = nil
        }
        if let observer = itemErrorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            itemErrorLogObserver = nil
        }
    }

    private func recoverLocalLoopbackFailureIfNeeded(item: AVPlayerItem, error: Error?) {
        let description = String(describing: error)
        guard description.contains("Playlist File unchanged") || description.contains("-12888") else {
            return
        }
        if isUserPaused {
            let playerSeconds = currentTime()
            guard playerSeconds.isFinite else { return }
            let mediaSeconds = mediaTime(for: playerSeconds)
            pendingLocalLoopbackRecoveryMediaTime = mediaSeconds
            Self.logger.info(
                "[CMP-AVP] local loopback playlist_unchanged recovery deferred until play media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public)"
            )
            return
        }
        recoverLocalLoopbackStallIfNeeded(item: item, requireBufferedEdge: false, reason: "playlist_unchanged")
    }

    private func recoverLocalLoopbackStallIfNeeded(
        item: AVPlayerItem,
        requireBufferedEdge: Bool = true,
        reason: String = "stall"
    ) {
        guard case .some(.siloLoopback(let spec)) = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isUserPaused else { return }
        let now = CACurrentMediaTime()
        guard now - lastLocalLoopbackStallRecoveryAt >= 10 else { return }
        let playerSeconds = currentTime()
        guard playerSeconds.isFinite else { return }
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: playerSeconds) ?? 0
        guard !requireBufferedEdge || bufferedAhead <= 0.5 else { return }
        let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds
            ?? 0
        let generatedAhead = generatedEnd - playerSeconds
        let minimumGeneratedAhead = playerSeconds < 10 ? Self.loopbackStartupForwardBuffer : 10
        guard generatedAhead > minimumGeneratedAhead else { return }
        lastLocalLoopbackStallRecoveryAt = now
        let mediaSeconds = mediaTime(for: playerSeconds)
        Self.logger.info(
            "[CMP-AVP] local loopback \(reason, privacy: .public) reanchor media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public) generatedAhead=\(generatedAhead, privacy: .public) bufferedAhead=\(bufferedAhead, privacy: .public)"
        )
        subtitleSession?.flushOnSeek()
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        load(strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)), startTime: mediaSeconds)
    }

    private func resumeLocalLoopbackPlaybackIfNeeded(for item: AVPlayerItem, trigger: String) {
        guard case .siloLoopback = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isUserPaused,
              avPlayer.rate == 0 else { return }
        let playerSeconds = currentTime()
        guard playerSeconds.isFinite else { return }
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: playerSeconds) ?? 0
        guard item.isPlaybackLikelyToKeepUp || bufferedAhead > 0.5 else { return }
        Self.logger.info(
            "[CMP-AVP] local loopback auto resume trigger=\(trigger, privacy: .public) player=\(playerSeconds, privacy: .public) bufferedAhead=\(bufferedAhead, privacy: .public)"
        )
        avPlayer.play()
    }

    private func attemptInitialPlaybackStart(for item: AVPlayerItem, trigger: String) {
        guard item === currentItem, !isDisposed, item.status == .readyToPlay else { return }

        let mediaTarget = max(0, pendingStartTime)
        let playerTarget = playerTime(forMediaTime: mediaTarget)
        guard !hasSeekedToStart, !isInitialSeekInFlight else { return }
        guard mediaTarget > 0, playerTarget > 0.05 else {
            startPlaybackIfNeeded(for: item)
            hasSeekedToStart = true
            resyncControlledSubtitlesAfterSeek(mediaSeconds: mediaTarget)
            onTimeChange?(avPlayer.currentTime().seconds)
            return
        }
        guard itemHasSeekableMedia(item, containing: playerTarget) else {
            Self.logger.info(
                "Deferring initial resume seek mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) trigger=\(trigger, privacy: .public) because the target is not seekable yet"
            )
            return
        }

        isInitialSeekInFlight = true
        isSeekPending = true
        subtitleSession?.flushOnSeek()
        let time = CMTime(seconds: playerTarget, preferredTimescale: 600)
        Self.logger.info(
            "Attempting initial resume seek mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) trigger=\(trigger, privacy: .public)"
        )
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, !self.isDisposed, item === self.currentItem else { return }
            self.isSeekPending = false
            self.isInitialSeekInFlight = false

            let landed = self.avPlayer.currentTime().seconds
            let landedMedia = self.mediaTime(for: landed)
            let landedCorrectly = finished && self.isInitialSeekSatisfied(target: mediaTarget, landed: landedMedia)
            Self.logger.info(
                "Initial resume seek completed finished=\(finished, privacy: .public) mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) landedPlayer=\(landed, privacy: .public) landedMedia=\(landedMedia, privacy: .public)"
            )

            if landedCorrectly {
                self.hasSeekedToStart = true
                self.initialSeekRetryCount = 0
                self.resyncControlledSubtitlesAfterSeek(mediaSeconds: landedMedia)
                self.startPlaybackIfNeeded(for: item)
                self.onTimeChange?(landed)
                return
            }

            self.initialSeekRetryCount += 1
            if self.initialSeekRetryCount <= 8 {
                let retry = self.initialSeekRetryCount
                Self.logger.warning(
                    "Initial resume seek did not land mediaTarget=\(mediaTarget, privacy: .public) landedMedia=\(landedMedia, privacy: .public) landedPlayer=\(landed, privacy: .public) finished=\(finished, privacy: .public) retry=\(retry, privacy: .public)"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.isDisposed else { return }
                    self.attemptInitialPlaybackStart(for: item, trigger: "retry-\(retry)")
                }
            } else {
                Self.logger.error(
                    "Initial resume seek failed after retries mediaTarget=\(mediaTarget, privacy: .public) landedMedia=\(landedMedia, privacy: .public) landedPlayer=\(landed, privacy: .public)"
                )
                if self.itemHasSeekableMedia(item, containing: playerTarget) {
                    self.startPlaybackIfNeeded(for: item)
                    self.onTimeChange?(landed)
                }
            }
        }
    }

    private func startPlaybackIfNeeded(for item: AVPlayerItem) {
        armInitialVideoDisplayGateIfNeeded()
        avPlayer.play()
        if isWaitingForInitialVideoDisplay {
            scheduleInitialVideoDisplayFallback(for: item)
        } else {
            finishInitialLoadIfNeeded(for: item)
        }
    }

    private func armLoopbackStartupWatchdogIfNeeded() {
        guard case .siloLoopback = currentSourceStrategy else { return }
        cancelLoopbackStartupWatchdog()
        let now = Date()
        loopbackStartupWatchdogStartedAt = now
        loopbackStartupLastProgressAt = now
        loopbackStartupLastRequestCount = segmentServer?.servedRequestCount ?? 0
        loopbackStartupRecoveryStage = .initial
        let timer = Timer(
            timeInterval: Self.loopbackStartupWatchdogTickSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.loopbackStartupWatchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        loopbackStartupWatchdog = timer
    }

    private func loopbackStartupWatchdogTick() {
        guard !isDisposed,
              !didFireFileLoaded,
              case .siloLoopback = currentSourceStrategy,
              let item = currentItem,
              let startedAt = loopbackStartupWatchdogStartedAt else {
            cancelLoopbackStartupWatchdog()
            return
        }
        guard item.status != .readyToPlay else {
            cancelLoopbackStartupWatchdog()
            return
        }
        let now = Date()
        let served = segmentServer?.servedRequestCount ?? 0
        if served != loopbackStartupLastRequestCount {
            loopbackStartupLastRequestCount = served
            loopbackStartupLastProgressAt = now
        }
        let displaySwitching = isTVDisplayModeSwitchInProgress()
        if displaySwitching {
            // Don't let the stall window expire the instant an HDMI mode
            // switch completes — restart it from the switch's end.
            loopbackStartupLastProgressAt = now
        }
        let verdict = LoopbackStartupRecoveryPolicy.verdict(
            secondsSinceProgress: now.timeIntervalSince(loopbackStartupLastProgressAt),
            secondsSinceStart: now.timeIntervalSince(startedAt),
            displayModeSwitchInProgress: displaySwitching,
            stallWindow: Self.loopbackStartupStallWindowSeconds,
            absoluteBackstop: Self.loopbackStartupAbsoluteBackstopSeconds
        )
        switch verdict {
        case .wait:
            return
        case .escalate:
            escalateLoopbackStartupRecovery(trigger: "fetches_frozen")
        case .failBackstop:
            cancelLoopbackStartupWatchdog()
            reportError(
                "Local loopback startup never became ready within "
                + "\(Int(Self.loopbackStartupAbsoluteBackstopSeconds))s "
                + "(requestsServed=\(served) stage=\(loopbackStartupRecoveryStage))"
            )
        }
    }

    /// Startup recovery ladder (AetherEngine consumer re-engage pattern):
    /// stage 1 nudges AVFoundation's loader with a zero-tolerance seek,
    /// stage 2 swaps in a fresh AVPlayerItem against the same loopback
    /// session, stage 3 surfaces the error so the route planner can fall
    /// back to the Compatibility player. Also driven directly by the item
    /// errorLog observer on loader-poison signatures.
    private func escalateLoopbackStartupRecovery(trigger: String) {
        guard !isDisposed, !didFireFileLoaded, currentItem != nil else { return }
        switch loopbackStartupRecoveryStage {
        case .initial:
            loopbackStartupRecoveryStage = .nudged
            loopbackStartupLastProgressAt = Date()
            cmpLog("[CMP-AVP] startup watchdog stage=nudge trigger=\(trigger)")
            nudgeLoopbackStartupConsumer()
        case .nudged:
            loopbackStartupRecoveryStage = .reloaded
            loopbackStartupLastProgressAt = Date()
            cmpLog("[CMP-AVP] startup watchdog stage=reload trigger=\(trigger)")
            reloadLoopbackStartupItem()
        case .reloaded:
            cancelLoopbackStartupWatchdog()
            reportError(
                "Local loopback startup stalled after nudge and item reload (trigger=\(trigger))"
            )
        }
    }

    /// Forces AVFoundation to tear down and rebuild its item loader via a
    /// zero-tolerance seek to the startup target — the same recovery a user
    /// gets by exiting the player and re-entering — without touching
    /// transport intent.
    private func nudgeLoopbackStartupConsumer() {
        let target: CMTime
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy,
           spec.servingMode == .vodPlan,
           pendingStartTime > 0 {
            target = CMTime(
                seconds: max(0, playerTime(forMediaTime: pendingStartTime)),
                preferredTimescale: 600
            )
        } else {
            target = avPlayer.currentTime()
        }
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Swap in a fresh AVPlayerItem for the same loopback URL. The producer,
    /// segment store, and server all stay up — only AVFoundation's item-side
    /// loader state is rebuilt. The initial-video-display gate stays armed
    /// from the original prepare, so the fresh item flows through the same
    /// ready → initial-seek → gated-start path as the first one.
    private func reloadLoopbackStartupItem() {
        guard let oldItem = currentItem,
              let asset = oldItem.asset as? AVURLAsset else {
            cancelLoopbackStartupWatchdog()
            reportError("Local loopback startup stalled with no reloadable item URL")
            return
        }
        let url = asset.url
        cmpLog("[CMP-AVP] startup watchdog reloading item in place url=\(url.absoluteString)")
        detachPerItemObservers()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if case .siloLoopback = currentSourceStrategy {
            item.preferredForwardBufferDuration = Self.loopbackStartupForwardBuffer
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        }
        currentItem = item
        attachItemObservers(item)
        avPlayer.replaceCurrentItem(with: item)
        issueVODResumePreSeekIfNeeded(context: "startup_reload")
    }

    private func isTVDisplayModeSwitchInProgress() -> Bool {
        #if os(tvOS)
        return TVDisplayCriteria.activeTVWindow()?.avDisplayManager
            .isDisplayModeSwitchInProgress ?? false
        #else
        return false
        #endif
    }

    private func cancelLoopbackStartupWatchdog() {
        loopbackStartupWatchdog?.invalidate()
        loopbackStartupWatchdog = nil
        loopbackStartupWatchdogStartedAt = nil
    }

    private func beginInitialVideoDisplayGate() {
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        isInitialVideoDisplayGatePrepared = true
        isWaitingForInitialVideoDisplay = false
        didTemporarilyMuteForInitialVideoDisplay = !avPlayer.isMuted
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = true
        }
        Self.logger.info("[CMP-AVP] prepared initial video frame gate before startup audio")
    }

    private func armInitialVideoDisplayGateIfNeeded() {
        guard isInitialVideoDisplayGatePrepared else { return }
        isInitialVideoDisplayGatePrepared = false
        isWaitingForInitialVideoDisplay = true
        initialVideoDisplayGateStartTime = avPlayer.currentTime().seconds
        Self.logger.info("[CMP-AVP] waiting for initial video frame before unmuting startup audio")
    }

    private func releaseInitialVideoDisplayGateIfPlaybackAdvanced(currentTime: Double) {
        guard isWaitingForInitialVideoDisplay, let item = currentItem else { return }
        let startTime = initialVideoDisplayGateStartTime ?? currentTime
        guard currentTime.isFinite, startTime.isFinite, currentTime - startTime >= 0.05 else { return }
        finishInitialVideoDisplayGate(for: item, reason: "playback_clock_advanced")
    }

    private func scheduleInitialVideoDisplayFallback(for item: AVPlayerItem) {
        guard initialVideoDisplayFallback == nil else { return }
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
            self.finishInitialVideoDisplayGate(for: item, reason: "ready_for_display_timeout")
        }
        initialVideoDisplayFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func finishInitialVideoDisplayGate(for item: AVPlayerItem, reason: String) {
        guard item === currentItem, !isDisposed else { return }
        guard isWaitingForInitialVideoDisplay else {
            finishInitialLoadIfNeeded(for: item)
            return
        }
        isWaitingForInitialVideoDisplay = false
        initialVideoDisplayGateStartTime = nil
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        finishInitialLoadIfNeeded(for: item)
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = false
            didTemporarilyMuteForInitialVideoDisplay = false
        }
        rampLoopbackBufferToSteadyStateIfNeeded(for: item)
        Self.logger.info("[CMP-AVP] initial video display gate released reason=\(reason, privacy: .public)")
    }

    /// Once the first frame is on screen, expand AVPlayer's forward
    /// buffer target so the loopback path can ride out brief network
    /// dips. Until now the buffer was capped at
    /// `loopbackStartupForwardBuffer` to keep readyToPlay snappy; that
    /// cushion is too thin for sustained playback when the source
    /// bitrate is close to the user's WAN throughput. Re-enable
    /// `automaticallyWaitsToMinimizeStalling` so AVPlayer pauses cleanly
    /// to rebuffer on actual underrun instead of presenting a stutter.
    private func rampLoopbackBufferToSteadyStateIfNeeded(for item: AVPlayerItem) {
        guard case .siloLoopback(let spec) = currentSourceStrategy else { return }
        guard canRampLoopbackBufferToSteadyState else { return }
        let generatedStats = latestLoopbackGeneratedStats
        let mediaBitrate = generatedStats?.rollingBitrateBps ?? spec.sourceBitrateBps
        let target = Self.loopbackSteadyStateForwardBufferTarget(
            forBitsPerSecond: mediaBitrate,
            targetDuration: generatedStats.map { Double($0.targetDuration) },
            longestSegmentDuration: generatedStats?.longestSegmentDuration
        )
        guard item.preferredForwardBufferDuration < target else { return }
        item.preferredForwardBufferDuration = target
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        Self.logger.info(
            "[CMP-AVP] loopback buffer ramp forwardBuffer=\(target, privacy: .public)s automaticallyWaits=1 mediaBitrate=\(mediaBitrate ?? 0, privacy: .public)bps generatedBitrate=\(generatedStats?.rollingBitrateBps ?? 0, privacy: .public)bps declaredBitrate=\(spec.sourceBitrateBps ?? 0, privacy: .public)bps sourceReadBitrate=\(self.loopbackSourceDownloadBitrateBps ?? 0, privacy: .public)bps targetDuration=\(generatedStats?.targetDuration ?? 0, privacy: .public) longestSegment=\(generatedStats?.longestSegmentDuration ?? 0, privacy: .public)"
        )
    }

    private var canRampLoopbackBufferToSteadyState: Bool {
        didFireFileLoaded && !isInitialVideoDisplayGatePrepared && !isWaitingForInitialVideoDisplay
    }

    private func itemHasSeekableMedia(_ item: AVPlayerItem, containing target: Double) -> Bool {
        let target = target.isFinite ? max(0, target) : 0
        if item.seekableTimeRanges.contains(where: { range in
            Self.timeRange(range.timeRangeValue, contains: target)
        }) {
            return true
        }

        return item.loadedTimeRanges.contains { range in
            Self.timeRange(range.timeRangeValue, contains: target)
        }
    }

    private static func timeRange(_ range: CMTimeRange, contains target: Double) -> Bool {
        let start = range.start.seconds
        let duration = range.duration.seconds
        let end = (range.start + range.duration).seconds
        guard start.isFinite, duration.isFinite, end.isFinite, duration > 0 else {
            return false
        }
        let tolerance = 0.05
        return target + tolerance >= start && target <= end + tolerance
    }

    private func isInitialSeekSatisfied(target: Double, landed: Double) -> Bool {
        guard target.isFinite, landed.isFinite else { return false }
        return abs(landed - target) <= 1.0
    }

    private func finishInitialLoadIfNeeded(for item: AVPlayerItem) {
        guard !didFireFileLoaded else { return }
        cancelLoopbackStartupWatchdog()
        didFireFileLoaded = true
        onFileLoaded?()
        loadMediaSelections(for: item)
        onChaptersChange?(serverChapters)
        emitPlaybackStats(referenceTime: currentTime(), force: true)
        logReadyItemFormat(item)
        logTVDisplayManagerState(context: "item_ready")
    }

    private func loadMediaSelections(for item: AVPlayerItem) {
        audioSelectionState = nil
        subtitleSelectionState = nil
        emitTrackList()

        let asset = item.asset
        if currentLoopbackAudioTracks.isEmpty {
            asset.loadMediaSelectionGroup(for: .audible) { [weak self, weak item] group, error in
                DispatchQueue.main.async { [weak self, weak item] in
                    guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
                    self.updateMediaSelectionState(group: group, kind: .audio, error: error)
                }
            }
        }
        asset.loadMediaSelectionGroup(for: .legible) { [weak self, weak item] group, error in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
                self.updateMediaSelectionState(group: group, kind: .sub, error: error)
            }
        }
    }

    private func updateMediaSelectionState(
        group: AVMediaSelectionGroup?,
        kind: PlayerTrack.Kind,
        error: Error?
    ) {
        if let error {
            Self.logger.warning(
                "Failed loading \(kind.rawValue, privacy: .public) tracks: \(error.localizedDescription, privacy: .public)"
            )
        }

        let state = group.flatMap { makeMediaSelectionState(group: $0, kind: kind) }
        switch kind {
        case .audio:
            audioSelectionState = state
        case .sub:
            subtitleSelectionState = state
        case .video, .unknown:
            break
        }
        emitTrackList()
    }

    private func makeMediaSelectionState(
        group: AVMediaSelectionGroup,
        kind: PlayerTrack.Kind
    ) -> MediaSelectionState? {
        let options = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
        guard !options.isEmpty else { return nil }

        var optionsByTrackId: [Int64: AVMediaSelectionOption] = [:]
        for (index, option) in options.enumerated() {
            optionsByTrackId[makeTrackId(for: kind, index: index)] = option
        }

        return MediaSelectionState(
            kind: kind,
            group: group,
            optionsByTrackId: optionsByTrackId
        )
    }

    private func emitTrackList() {
        guard let item = currentItem else {
            onTracksChange?([])
            return
        }

        var tracks: [PlayerTrack] = []
        if !currentLoopbackAudioTracks.isEmpty {
            tracks.append(contentsOf: currentLoopbackAudioTracks)
        } else if let audioSelectionState {
            let mediaSelection = item.currentMediaSelection
            tracks.append(
                contentsOf: buildTracks(
                    from: audioSelectionState,
                    selectedOption: mediaSelection.selectedMediaOption(in: audioSelectionState.group)
                )
            )
        }
        let extractedSubtitles = embeddedSubtitleExtractor?
            .playerTracks(selectedPrimaryTrackId: selectedControlledSubtitleTrackId) ?? []
        tracks.append(contentsOf: extractedSubtitles)
        onTracksChange?(tracks)
    }

    private func buildTracks(
        from state: MediaSelectionState,
        selectedOption: AVMediaSelectionOption?
    ) -> [PlayerTrack] {
        state.optionsByTrackId.keys.sorted().compactMap { trackId in
            guard let option = state.optionsByTrackId[trackId] else { return nil }
            let isSelected = selectedOption.map { ObjectIdentifier($0) == ObjectIdentifier(option) } ?? false
            let isHearingImpaired = option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
            return PlayerTrack(
                trackId: trackId,
                kind: state.kind,
                title: normalizedTitle(for: option),
                lang: languageCode(for: option),
                codec: codecLabel(for: option),
                audioChannelsLayout: nil,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: state.group.defaultOption.map { ObjectIdentifier($0) == ObjectIdentifier(option) } ?? false,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                isHearingImpaired: isHearingImpaired,
                isVisualImpaired: option.hasMediaCharacteristic(.describesVideoForAccessibility),
                isExternal: false,
                isSelected: isSelected,
                ffIndex: nil,
                srcId: nil
            )
        }
    }

    private func makeTrackId(for kind: PlayerTrack.Kind, index: Int) -> Int64 {
        let base: Int64
        switch kind {
        case .audio:
            base = 10_000
        case .sub:
            base = 20_000
        case .video:
            base = 30_000
        case .unknown:
            base = 40_000
        }
        return base + Int64(index)
    }

    private func normalizedTitle(for option: AVMediaSelectionOption) -> String? {
        let value = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func languageCode(for option: AVMediaSelectionOption) -> String? {
        if let localeCode = option.locale?.language.languageCode?.identifier, !localeCode.isEmpty {
            return localeCode
        }
        if let tag = option.extendedLanguageTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return tag.split(separator: "-").first.map(String.init)
        }
        return nil
    }

    private func codecLabel(for option: AVMediaSelectionOption) -> String? {
        guard let subtype = option.mediaSubTypes.first?.uint32Value else { return nil }
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF)
        ]
        guard let code = String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty else {
            return nil
        }
        return code
    }

    private func pumpSubtitleOverlay(referenceTime: Double) {
        guard let session = subtitleSession else { return }
        guard let overlay = subtitleOverlay else { return }
        let renderer = session.underlyingRenderer
        let hasTextTrack = renderer.hasAnyActiveTrack
        let hasBitmapTrack = session.hasActiveBitmapTrack
        guard hasTextTrack || hasBitmapTrack else {
            lastBitmapCueRenderKey = nil
            textOverlayMayHaveFrame = false
            DispatchQueue.main.async {
                overlay.clear()
            }
            return
        }

        // One sync-adjusted clock for both render paths.
        let nowMs = Int64(referenceTime * 1000.0)
        let syncOffsetMs = Int64(session.currentParams.syncOffsetMs)
        let adjustedNowMs = nowMs - syncOffsetMs
        let bounds = overlay.bounds
        let videoInsets = overlay.videoInsets

        if hasTextTrack {
            textOverlayMayHaveFrame = true
            #if os(macOS)
            let scale = overlay.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            #else
            let scale = overlay.window?.screen.scale ?? overlay.traitCollection.displayScale
            #endif
            guard subPumpRendersInFlight < 2 else {
                subDiagSkippedTicks += 1
                return
            }
            subPumpRendersInFlight += 1
            let enqueuedAt = CACurrentMediaTime()
            renderer.sessionQueue.async { [weak overlay, weak self] in
                let startedAt = CACurrentMediaTime()
                let out = renderer.renderOnSessionQueue(
                    atMilliseconds: adjustedNowMs,
                    frameSize: bounds.size,
                    scale: scale,
                    videoInsets: videoInsets
                )
                let endedAt = CACurrentMediaTime()
                DispatchQueue.main.async {
                    if let self {
                        self.subPumpRendersInFlight = max(0, self.subPumpRendersInFlight - 1)
                        self.recordSubtitlePumpDiag(
                            queueLatencyMs: (startedAt - enqueuedAt) * 1000,
                            renderMs: (endedAt - startedAt) * 1000,
                            out: out,
                            referenceTime: referenceTime,
                            syncOffsetMs: syncOffsetMs,
                            bounds: bounds,
                            insets: videoInsets
                        )
                    }
                    guard out.isDirty else { return }
                    overlay?.updateContents(out.image)
                }
            }
        } else if textOverlayMayHaveFrame {
            // A slot just switched away from libass (e.g. text → bitmap
            // track): don't let the last composited text frame linger.
            // One-shot, and funneled through the render queue so it lands
            // after any render still in flight from the previous tick.
            textOverlayMayHaveFrame = false
            renderer.sessionQueue.async { [weak overlay] in
                DispatchQueue.main.async {
                    overlay?.updateContents(nil)
                }
            }
        }

        if hasBitmapTrack {
            pumpBitmapCues(
                session: session,
                overlay: overlay,
                atSeconds: Double(adjustedNowMs) / 1000.0,
                bounds: bounds,
                videoInsets: videoInsets
            )
        } else if lastBitmapCueRenderKey != nil {
            lastBitmapCueRenderKey = nil
            DispatchQueue.main.async {
                overlay.clearBitmapCues()
            }
        }
    }

    /// Temporary [CMP-SUBDIAG] emit — 1 Hz summary of the pump's
    /// session-queue latency, render cost, and the clocks feeding it.
    /// Main thread only.
    private func recordSubtitlePumpDiag(
        queueLatencyMs: Double,
        renderMs: Double,
        out: SubtitleRenderOutput,
        referenceTime: Double,
        syncOffsetMs: Int64,
        bounds: CGRect,
        insets: SubtitleVideoInsets
    ) {
        subDiagTicks += 1
        if out.isDirty { subDiagDirtyCount += 1 }
        subDiagMaxQueueLatencyMs = max(subDiagMaxQueueLatencyMs, queueLatencyMs)
        subDiagMaxRenderMs = max(subDiagMaxRenderMs, renderMs)
        let now = CACurrentMediaTime()
        guard now - subDiagLastEmit >= 1.0 else { return }
        let playerSeconds = avPlayer.currentTime().seconds
        print(String(
            format: "[CMP-SUBDIAG] qLatMaxMs=%.1f renderMaxMs=%.1f ticks=%d dirty=%d skip=%d chg=%d/%d fsd=%d geom=%d evts=%d imgs=%d imgKB=%d ref=%.2f player=%.2f syncMs=%d bounds=%.0fx%.0f insets=%.0f/%.0f/%.0f/%.0f",
            subDiagMaxQueueLatencyMs, subDiagMaxRenderMs, subDiagTicks, subDiagDirtyCount, subDiagSkippedTicks,
            out.diagChangePrimary, out.diagChangeSecondary,
            out.diagWasFrameSizeDirty ? 1 : 0, out.diagGeometryApplies,
            out.diagTrackEvents, out.diagImageCount, out.diagImageBytes / 1024,
            referenceTime, playerSeconds, syncOffsetMs,
            bounds.width, bounds.height,
            insets.top, insets.bottom, insets.left, insets.right
        ))
        subDiagLastEmit = now
        subDiagMaxQueueLatencyMs = 0
        subDiagMaxRenderMs = 0
        subDiagTicks = 0
        subDiagDirtyCount = 0
        subDiagSkippedTicks = 0
    }

    private func pumpBitmapCues(
        session: SubtitleSession,
        overlay: SubtitleOverlayView,
        atSeconds seconds: Double,
        bounds: CGRect,
        videoInsets: SubtitleVideoInsets
    ) {
        let cues = session.activeBitmapCues(at: seconds)
        // Normalized cue rects are relative to the displayed video, not the
        // overlay: on tvOS the overlay covers the full frame (so libass can
        // place text in the letterbox bars) and `videoInsets` marks the
        // video rect inside it; on iOS/macOS the overlay is framed to the
        // video and the insets are zero, so this reduces to `bounds`.
        let videoRect = CGRect(
            x: bounds.minX + videoInsets.left,
            y: bounds.minY + videoInsets.top,
            width: max(0, bounds.width - videoInsets.left - videoInsets.right),
            height: max(0, bounds.height - videoInsets.top - videoInsets.bottom)
        )
        let key = BitmapCueRenderKey(
            videoRect: videoRect,
            images: cues.map { ObjectIdentifier($0.image) }
        )
        guard key != lastBitmapCueRenderKey else { return }
        lastBitmapCueRenderKey = key
        let placements = cues.map { cue in
            (
                image: cue.image,
                frame: CGRect(
                    x: videoRect.minX + cue.normalizedFrame.origin.x * videoRect.width,
                    y: videoRect.minY + cue.normalizedFrame.origin.y * videoRect.height,
                    width: cue.normalizedFrame.width * videoRect.width,
                    height: cue.normalizedFrame.height * videoRect.height
                )
            )
        }
        DispatchQueue.main.async {
            overlay.updateBitmapCues(placements)
        }
    }

    private func teardownMediaPipeline(clearDisplayCriteria: Bool = true) {
        if clearDisplayCriteria {
            clearTVDisplayCriteria(context: "teardown")
        } else {
            logTVDisplayManagerState(context: "preserve_for_loopback_reload")
        }
        avPlayer.pause()
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        subtitleDisplayLink?.invalidate()
        subtitleDisplayLink = nil
        subPumpRendersInFlight = 0
        loopbackPlayheadWatchdog?.invalidate()
        loopbackPlayheadWatchdog = nil
        detachPerItemObservers()
        audioSelectionState = nil
        subtitleSelectionState = nil
        currentLoopbackAudioTracks = []
        selectedControlledSubtitleTrackId = nil
        selectedSecondaryControlledSubtitleTrackId = nil
        sidecarDescriptorsByTrackId.removeAll()
        // Stop live forwarding; the cue STORE survives so a reanchor of the
        // same source re-enables instantly (ensureLoopbackSubtitleTap
        // resets it when the source changes).
        loopbackSubtitleTap?.deactivate()
        embeddedSubtitleExtractor?.teardown()
        activeLoopbackSessionID = nil
        isInitialSeekInFlight = false
        initialSeekRetryCount = 0
        isInitialVideoDisplayGatePrepared = false
        isWaitingForInitialVideoDisplay = false
        initialVideoDisplayGateStartTime = nil
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        cancelLoopbackStartupWatchdog()
        displayModeSettleTask?.cancel()
        displayModeSettleTask = nil
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = false
            didTemporarilyMuteForInitialVideoDisplay = false
        }
        avPlayer.replaceCurrentItem(with: nil)
        deactivateAudioSession()
        currentItem = nil
        subtitleSession?.teardown()
        lastBitmapCueRenderKey = nil
        textOverlayMayHaveFrame = false
        DispatchQueue.main.async { [weak self] in
            self?.subtitleOverlay?.clear()
        }

        let writer = segmentWriter
        segmentWriter = nil
        writer?.onFirstSegmentReady = nil
        writer?.onSegmentAppended = nil
        writer?.onTimelineAnchorResolved = nil
        writer?.onSourceDownloadStats = nil
        writer?.onGeneratedMediaStats = nil
        writer?.onHDR10PlusMetadataDetected = nil
        writer?.onFinished = nil
        segmentServer?.stop()
        segmentServer = nil
        segmentStore = nil
        latestLoopbackGeneratedStats = nil
        loopbackEdgeWatch = nil

        let dir = sessionDirectory
        let preserveDir = preserveSessionDirectory
        sessionDirectory = nil
        preserveSessionDirectory = false
        writer?.stop {
            if let dir, preserveDir {
                print("[CMP-AVP] retained local DV artifacts dir=\(dir.path)")
            } else if let dir {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        if writer == nil, let dir {
            if preserveDir {
                print("[CMP-AVP] retained local DV artifacts dir=\(dir.path)")
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    private func reportError(_ message: String) {
        cmpLog("[CMP-AVP] ERROR: \(message)")
        onError?(message)
    }

    private func logReadyItemFormat(_ item: AVPlayerItem) {
        Task { [item] in
            let videoFormat = await AVFoundationPlaybackIntrospection.videoFormat(for: item)
            let audioFormat = await AVFoundationPlaybackIntrospection.audioStream(for: item)
            print(
                "[CMP-AVP] item ready format videoCodec=\(videoFormat.stream.codec ?? "nil") videoDetail=\(videoFormat.stream.detail ?? "nil") dynamicRange=\(videoFormat.dynamicRange ?? "nil") audioCodec=\(audioFormat.codec ?? "nil") audioDetail=\(audioFormat.detail ?? "nil")"
            )
        }
    }

    private func logTVDisplayManagerState(context: String) {
        #if os(tvOS)
        guard let displayManager = TVDisplayCriteria.activeTVWindow()?.avDisplayManager else {
            print("[CMP-AVP] tv display context=\(context) manager=nil")
            return
        }
        print(
            "[CMP-AVP] tv display context=\(context) matching=\(displayManager.isDisplayCriteriaMatchingEnabled ? 1 : 0) switchInProgress=\(displayManager.isDisplayModeSwitchInProgress ? 1 : 0)"
        )
        #endif
    }

    /// Writes the HDMI display criteria for the upcoming loopback item.
    /// Returns true when a dynamic-range switch was requested and the caller
    /// should wait for it to settle before creating the AVPlayerItem (gated
    /// non-DV HDR only; the shipped DV path never waits).
    @discardableResult
    private func applyTVDisplayCriteriaForLoopbackIfNeeded(context: String) -> Bool {
        #if os(tvOS)
        guard case .siloLoopback(let spec) = currentSourceStrategy else { return false }
        let selection = HDRDisplayCriteriaPolicy.selection(
            videoMode: spec.videoMode,
            manifestVideoRange: spec.manifestMetadata.videoRange,
            hdrGateEnabled: HDRDisplayCriteriaPolicy.isEnabled()
        )
        let preservedForReload = isPreservingTVDisplayCriteriaForReload
        isPreservingTVDisplayCriteriaForReload = false
        let refreshRate = spec.sourceVideoFrameRate ?? 24.0
        switch selection {
        case .dolbyVision:
            // `handleFirstSegmentReady` (the only caller) is dispatched onto
            // the main queue by the writer callback.
            let outcome = MainActor.assumeIsolated {
                TVDisplayCriteria.setRangeCriteria(.dolbyVision, refreshRate: refreshRate)
            }
            switch outcome {
            case .noDisplayManager:
                print("[CMP-AVP] tv display apply context=\(context) manager=nil")
            case .matchingDisabled:
                print("[CMP-AVP] tv display apply context=\(context) matching=0 skipped=matching_disabled")
            case .applied:
                print(String(format: "[CMP-AVP] tv display apply context=%@ fps=%.3f dr=%d matching=1 preservedReload=%d", context, Double(refreshRate), Int(SpikeDynamicRange.dolbyVision.rawValue), preservedForReload ? 1 : 0))
            case .formatUnavailable:
                break
            }
            return false
        case .hdr10, .hlg:
            let range = selection == .hlg ? "HLG" : "PQ"
            let outcome = MainActor.assumeIsolated {
                TVDisplayCriteria.setHDRFormatCriteria(
                    hlg: selection == .hlg,
                    refreshRate: refreshRate
                )
            }
            print(String(format: "[CMP-AVP] tv display apply hdr context=%@ range=%@ fps=%.3f outcome=%@ preservedReload=%d", context, range, Double(refreshRate), String(describing: outcome), preservedForReload ? 1 : 0))
            // A reload that preserved criteria left the panel in the right
            // mode already; rewriting identical criteria triggers no new
            // negotiation, so only a fresh apply needs the settle wait.
            return outcome == .applied && !preservedForReload
        case .none:
            return false
        }
        #else
        return false
        #endif
    }

    private func clearTVDisplayCriteria(context: String) {
        #if os(tvOS)
        DispatchQueue.main.async {
            guard let displayManager = TVDisplayCriteria.activeTVWindow()?.avDisplayManager else {
                print("[CMP-AVP] tv display clear context=\(context) manager=nil")
                return
            }
            displayManager.preferredDisplayCriteria = nil
            print("[CMP-AVP] tv display clear context=\(context) switchInProgress=\(displayManager.isDisplayModeSwitchInProgress ? 1 : 0)")
        }
        #endif
    }

    private func reportItemFailure(_ item: AVPlayerItem) {
        preserveLoopbackArtifactsIfDebugEnabled(reason: "avplayer_item_failed")
        let nsError = item.error as NSError?
        let domain = nsError?.domain ?? "unknown"
        let code = nsError?.code ?? 0
        let description = nsError?.localizedDescription ?? "AVPlayer item failed"
        let failingURL = (nsError?.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        let underlying = (nsError?.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            "\($0.domain)(\($0.code)): \($0.localizedDescription)"
        }
        let latestErrorLog = item.errorLog()?.events.last.map { event in
            let uri = event.uri ?? "nil"
            let comment = event.errorComment ?? "nil"
            return "uri=\(uri) status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(comment)"
        }

        var details = "AVPlayer item failed: \(description) domain=\(domain) code=\(code)"
        if let failingURL, !failingURL.isEmpty {
            details += " failingURL=\(failingURL)"
        }
        if let underlying, !underlying.isEmpty {
            details += " underlying=\(underlying)"
        }
        if let latestErrorLog, !latestErrorLog.isEmpty {
            details += " errorLog=\(latestErrorLog)"
        }
        reportError(details)
    }

    private func preserveLoopbackArtifactsIfDebugEnabled(reason: String) {
        guard Self.keepLoopbackArtifacts else { return }
        guard let dir = sessionDirectory else { return }
        if !preserveSessionDirectory {
            print("[CMP-AVP] preserving local DV artifacts after \(reason) dir=\(dir.path)")
        }
        preserveSessionDirectory = true
    }

    private static var keepLoopbackArtifacts: Bool {
        let raw = ProcessInfo.processInfo.environment["SILO_KEEP_DV_HLS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static func describe(_ strategy: SourceStrategy) -> String {
        switch strategy {
        case .remoteHLS(let url, _):
            return "remoteHLS(\(url.absoluteString))"
        case .remoteDirect(let url, _):
            return "remoteDirect(\(url.absoluteString))"
        case .siloLoopback(let spec):
            return "siloLoopback(\(spec.sourceURL.absoluteString), videoMode=\(spec.videoMode.logToken), start=\(spec.sourceStartTimeSeconds), audioTrackIndex=\(spec.selectedAudio.trackIndex), audioFfIndex=\(spec.selectedAudio.ffIndex ?? -1))"
        }
    }

    private static func displayRouteLabel(_ strategy: SourceStrategy) -> String {
        switch strategy {
        case .remoteHLS:
            return "Native Player HLS"
        case .remoteDirect:
            return "Native Player Direct"
        case .siloLoopback(let spec):
            switch spec.videoMode {
            case .passthroughH264:
                return "SiloPlayer (H.264)"
            case .passthroughHEVC:
                return "SiloPlayer (HEVC)"
            case .passthroughProfile5, .convertProfile7To81, .passthroughProfile8:
                return "SiloPlayer (Dolby Vision)"
            }
        }
    }

    private static func normalizedLoopbackAudioTracks(for strategy: SourceStrategy) -> [PlayerTrack] {
        switch strategy {
        case .siloLoopback(let spec):
            let audioTracks = spec.availableAudioTracks
            guard !audioTracks.isEmpty else { return [] }
            if audioTracks.contains(where: { $0.isSelected }) {
                return audioTracks
            }
            return audioTracks.enumerated().map { index, track in
                PlayerTrack(
                    trackId: track.trackId,
                    kind: track.kind,
                    title: track.title,
                    lang: track.lang,
                    codec: track.codec,
                    audioChannelsLayout: track.audioChannelsLayout,
                    audioChannelCount: track.audioChannelCount,
                    bitrate: track.bitrate,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    isHearingImpaired: track.isHearingImpaired,
                    isVisualImpaired: track.isVisualImpaired,
                    isExternal: track.isExternal,
                    isSelected: index == 0,
                    ffIndex: track.ffIndex,
                    srcId: track.srcId
                )
            }
        case .remoteHLS, .remoteDirect:
            return []
        }
    }

    private static func loopbackAudioOutputMode(for track: PlayerTrack) -> LoopbackSessionSpec.AudioOutputMode {
        switch normalizedCodecToken(track.codec) {
        case "aac", "ac3", "eac3":
            return .copy
        case "truehd":
            return .requireFLAC
        default:
            if let channelCount = track.audioChannelCount, channelCount > 2 {
                return .transcodeFLAC
            }
            return .transcodeAAC
        }
    }

    private static func loopbackPreservesAtmos(for track: PlayerTrack) -> Bool {
        guard normalizedCodecToken(track.codec) == "eac3" else { return false }
        let title = track.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return title?.contains("atmos") == true || title?.contains("joc") == true
    }

    private static func normalizedCodecToken(_ raw: String?) -> String? {
        let token = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        switch token {
        case "dolbytruehd", "mlp", "mlpa":
            return "truehd"
        default:
            return token
        }
    }
}
