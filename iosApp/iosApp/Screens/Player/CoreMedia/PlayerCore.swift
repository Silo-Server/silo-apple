//
//  PlayerCore.swift
//  Continuum (iOS + tvOS)
//
//  The single player core. Pipeline:
//
//    libavformat demux  →  video packet queue  →  VTDecompressionSession (async)
//                       \→ audio packet queue  →  FFmpeg SW decode + SwrContext
//                                                 → AVAudioEngine (AVAudioSourceNode)
//
//    Video is push-driven through `AVSampleBufferDisplayLayer` while audio is
//    rendered as decoded PCM through an `AVAudioEngine` graph, modeled after
//    KSPlayer's Apple backend. Color attachments come from ffmpeg.
//
//  HDR policy differs per platform:
//    - tvOS: HDMI mode is driven by AVDisplayManager. `onSigPeakChange` is a
//      no-op; the display layer's EDR flag is irrelevant because the compositor
//      negotiates HDR directly with the TV.
    //    - iOS / macOS: no HDMI to negotiate. HDR is driven by setting
    //      `preferredDynamicRange` on the AVSampleBufferDisplayLayer
//      when the stream's transfer function is HDR and the user has HDR
//      enabled. `onSigPeakChange` fires so the hosting view can toggle EDR.

import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import OSLog
import VideoToolbox

/// Only an explicit user pause suspends the I/O timeout. The playback clock
/// also reads rate 0 during startup and seek restarts, and those windows
/// rely on this abort as their only escape from a wedged `av_read_frame`.
enum CoreMediaDemuxInterruptPolicy {
    static func shouldAbort(
        cancelled: Bool,
        userPaused: Bool,
        secondsSinceProgress: CFTimeInterval,
        timeoutSeconds: CFTimeInterval
    ) -> Bool {
        cancelled || (!userPaused && secondsSinceProgress > timeoutSeconds)
    }
}

final class PlayerCore: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app.tvos",
        category: "CoreMediaPlayer"
    )
    private static let ffmpegEAGAIN = -EAGAIN

    /// OSLog handle for signposts. Category scoped so Instruments can pivot on it.
    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app.tvos",
        category: "CoreMediaPlayer"
    )

    // MARK: - Public callbacks

    var onDurationChange: ((Double) -> Void)?
    var onTimeChange: ((Double) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onFirstFrame: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    /// Fires on main while buffering with fill progress toward the resume
    /// threshold (0–100). Only whole-percent changes are reported.
    var onBufferingProgress: ((Double) -> Void)?
    var onPlaybackStatsChange: ((PlaybackStats) -> Void)?
    var onTracksChange: (([PlayerTrack]) -> Void)?
    var onChaptersChange: (([ChapterInfo]) -> Void)?
    /// Fires on iOS with a sig-peak > 1.0 for HDR streams (HDR10 / HLG) when
    /// the user has HDR enabled, so the hosting view can toggle
    /// `preferredDynamicRange` on the display layer. On tvOS this
    /// is a no-op — HDR is negotiated via AVDisplayManager HDMI signaling.
    var onSigPeakChange: ((Double) -> Void)?
    /// Fires on main when sidecar subtitle descriptors have been
    /// registered with the subtitle session. The VM appends synthesised
    /// `PlayerTrack` entries to `subtitleTracks` so the picker shows
    /// every available caption track (embedded + server-provided).
    var onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)?
    /// Fires on main when a subtitle slot's loading status changes.
    /// UI can surface a loading spinner or silent-failure indicator.
    var onSubtitleLoadStatusChange: ((SubtitleSlot, SubtitleLoadStatus) -> Void)?
    /// Fires on main whenever PiP activates/deactivates. UI can dim or hide
    /// the in-app controls while the layer is pip'd out.
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    private enum VideoDecodeMode {
        case videoToolbox
        case software
    }

    /// Fires on main when PlayerCore determines it can't decode the loaded
    /// stream. Carries the original `(url, headers, startTime)` so the VM
    /// can hand off to another backend without keeping its own copy.
    var onUnsupportedStream: ((StreamRejection, URL, [String: String], Double) -> Void)?

    /// User HDR-enable preference. On tvOS applied to AVDisplayManager at
    /// `load()` time; `setHDREnabled` re-applies immediately. On iOS drives
    /// whether `onSigPeakChange` emits a >1.0 peak for the display-layer EDR
    /// flag.
    private(set) var hdrEnabled: Bool = true
    /// Snapshot of the user's Dolby Vision settings, pushed by the owner at
    /// construction (alongside the initial `setHDREnabled`) so it is in place
    /// before `load()` runs Dolby Vision routing. Plan-time snapshot like the
    /// route planner's — mid-playback changes apply on the next load.
    var dolbyVisionPolicy: DolbyVisionPolicy.Snapshot = .default
    /// Most recent sig-peak emitted via `onSigPeakChange`. Used by the hosting
    /// view when re-attaching (e.g. on window/screen change) so EDR can be
    /// re-evaluated without replaying the whole stream. Always 0 on tvOS.
    private(set) var lastSigPeak: Double = 0
    /// Pixel-aspect-corrected presentation size of the active video stream,
    /// derived from `videoFormatDescription`. `.zero` until the format is
    /// known. The hosting view sizes the subtitle overlay to the displayed
    /// video rect with it, so libass font scale tracks the video frame
    /// rather than the full view.
    private(set) var videoPresentationSize: CGSize = .zero
    /// Fires on main whenever `videoPresentationSize` changes.
    var onVideoPresentationSizeChange: ((CGSize) -> Void)?

    // MARK: - Master clock

    /// Audio is rendered by the `AVAudioEngine` backend; video has its own
    /// independent `controlTimebase` parented to the host clock because the
    /// `AVSampleBufferVideoRenderer` pull model on tvOS 18 never actually
    /// pulls video frames. See comment at `attach(to:)` for the pivot rationale.
    private let audioOutput = AudioEngineAudioOutput()
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var hasAddedDisplayLayer = false

    /// Video-only clock, parented to the host clock. Rate stays at 1.0 for the
    /// lifetime of the layer; pause/resume is driven by toggling `displayLink`.
    /// Set up in `attach(to:)`.
    private var controlTimebase: CMTimebase?
    /// vsync tick driver for the push-mode video pipeline. Fires on main via
    /// `.common` runloop mode so focus/scroll animations on tvOS don't starve
    /// us. Nil until `attach(to:)` is called.
    #if os(macOS)
    private var displayLink: Timer?
    #else
    private var displayLink: CADisplayLink?
    #endif
    private var videoDisplayTickPaused = true
    /// Thread-safe PTS-ordered queue of decoded frames waiting to be
    private static let decodedVideoQueueCap = 24
    private static let decodedVideoFeedBackpressure = 16
    /// Byte companion to the count threshold above. 16 × 1080p frames is
    /// ~50 MiB (count governs); 16 × 4K 10-bit is ~400 MiB of IOSurface,
    /// which this caps at ~192 MiB (≈8 frames / 300 ms at 24 fps — still
    /// comfortably ahead of the display tick).
    private static let decodedVideoFeedBackpressureBytes = 192 * 1024 * 1024
    private let videoFrameScheduler = VideoFrameScheduler(
        queueCap: decodedVideoQueueCap,
        feedBackpressure: decodedVideoFeedBackpressure,
        feedBackpressureBytes: decodedVideoFeedBackpressureBytes
    )
    private let decodedVideoFrameRenderer = DecodedVideoFrameRenderer()
    /// Bound VT async decode submissions separately from decoded-frame queue
    /// depth. Hardware decoders have their own finite input/reorder queues;
    /// feeding hundreds of compressed H.264 samples before callbacks drain can
    /// surface as kVTVideoDecoderBadDataErr on otherwise-valid streams.
    private static let maxVideoToolboxInFlightSubmissions = 24
    private let videoToolboxDecoder = VideoToolboxVideoDecoder(
        maxInFlightSubmissions: maxVideoToolboxInFlightSubmissions
    )
    private let compressedVideoPipeline = CompressedVideoPipeline()
    /// Frames-per-second used for the video sync predicate. Pulled from the
    /// stream info at decoder setup. 24.0 fallback if unknown.
    private var videoFPS: Double = 24.0
    /// Diagnostic counter — how many frames we've successfully enqueued via
    /// the display link since the last reset. Logged at milestones.
    /// Interpolated audio position. Updated from the audio-engine render
    /// callback and read by the display link to decide whether the
    /// head-of-queue frame is early / on-time / late.
    private let playbackClock = PlaybackClock()
    /// Wall-clock stamp of the last `onTimeChange` emission (for throttling).
    private var lastOnTimeChange: CFTimeInterval = 0
    private var lastReportedSeconds: Double = -1

    // MARK: - FFmpeg + VideoToolbox state

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1
    private var videoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private var audioTimeBase: AVRational = AVRational(num: 1, den: 1)

    private var videoFormatDescription: CMVideoFormatDescription?
    private var videoDecodeMode: VideoDecodeMode = .videoToolbox
    private var videoCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoSwsCtx: OpaquePointer?
    private var videoDecodeOutputDimensions: CMVideoDimensions?
    private var useUntimedCompressedVideoSamples = false
    /// Set when PlayerCore detects it can't decode the stream. Signals
    /// `openAndDemux` to bail out and fire `onUnsupportedStream` so the
    /// ViewModel can swap backends. Cleared on each `load()` entry.
    private var pendingRejection: (reason: StreamRejection, url: URL, headers: [String: String], startTime: Double)?
    private var lastLoadURL: URL?
    private var lastLoadHeaders: [String: String] = [:]
    private var lastLoadStartTime: Double = 0
    /// CVPixelBuffer format chosen in `buildVideoFormatDescription` to match
    /// the source's bit depth + fullRange. Declared in the format-description
    /// extensions so VT picks a matching decoder, and passed again via
    /// `imageBufferAttributes` so the output buffers come out consistently.
    private var videoPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private var isConvertNALSize = false

    // Audio SW decode state.
    private var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioSwrCtx: OpaquePointer?
    private var audioOutputConfig: NegotiatedAudioOutput?
    private let audioDecodePipeline = AudioDecodePipeline()
    /// Set on first successful VT decode so we can fire `onFileLoaded` once.
    private var hasFiredFileLoaded = false
    private var hasFiredFirstFrameSignpost = false
    /// Wall-clock anchor for the one-shot `[CMP-TTFF]` first-frame log
    /// (SiloPlayer plan Stage 0). Set on every `load(url:...)`.
    private var ttffLoadAnchor: CFAbsoluteTime = 0
    private var hasLoggedFirstDecodedVideoBuffer = false
    /// PTS floor for frames/samples that should reach the renderers. Set after
    /// any backward-seek (resume mid-stream, user scrub): FFmpeg lands on the
    /// nearest prior keyframe — up to a few seconds before the target — and
    /// without a floor we'd feed that keyframe-gap content through the
    /// pipeline. The video display link paces against the engine-driven audio
    /// clock, so these pre-target frames would otherwise sit `keyframeGap`
    /// seconds behind the requested position while audio starts at the target
    /// PTS. Net result: audio plays `keyframeGap` seconds ahead of video for
    /// the entire session. Skipping pre-target frames here pushes the first
    /// rendered frame (both A and V) to the target PTS so the audio engine,
    /// playback clock, and display link all agree on t=0.
    private var pendingSkipBelowPTS: Double = 0
    private var skippedPreTargetVideoFrames: UInt64 = 0
    private var skippedPreTargetAudioFrames: UInt64 = 0

    /// When set, the first rendered audio callback re-anchors the playback
    /// clock to the sample's actual PTS. Motivation: the user-visible clock
    /// starts ticking immediately, but the decoder needs ~50–350 ms to spin
    /// up and produce its first frame. Re-anchoring on the first rendered
    /// sample keeps video/audio aligned on the real content timeline.
    private var shouldResyncClockOnFirstAudio: Bool = false

    // MARK: - Queues

    private let demuxQueue = DispatchQueue(
        label: "com.continuum.coremedia.demux",
        qos: .userInitiated
    )
    private let videoDecodeQueue = DispatchQueue(
        label: "com.continuum.coremedia.videodecode",
        qos: .userInitiated
    )
    private let audioDecodeQueue = DispatchQueue(
        label: "com.continuum.coremedia.audiodecode",
        qos: .userInitiated
    )
    private let audioFeedQueue = DispatchQueue(
        label: "com.continuum.coremedia.audiofeed",
        qos: .userInitiated
    )
    private let videoFeedQueue = DispatchQueue(
        label: "com.continuum.coremedia.videofeed",
        qos: .userInitiated
    )
    /// Control-plane queue for seek/pause coordination. Stays outside the
    /// demux/feed queues so it can use `.sync {}` barriers to drain them
    /// without deadlocking.
    private let controlQueue = DispatchQueue(
        label: "com.continuum.coremedia.control",
        qos: .userInitiated
    )

    // MARK: - Packet queues (bounded)

    /// Base capacities. `demuxerBufferMultiplier` scales these at load time
    /// to produce the active PacketQueue — runtime mutation of a live queue's
    /// capacity would race with the demux enqueue loop.
    ///
    /// Video is byte-budgeted with a high count ceiling. Keep the cap modest:
    /// ProRes can be ~500 Mbps, so a 1 GB packet queue is only seconds of
    /// media but enough to trigger tvOS jetsam when combined with source cache
    /// and decoded frames. Audio packets are tiny, so 480 by count is fine.
    private static let baseVideoPacketCapacity = 8000
    private static let baseVideoPacketMaxBytes = 96 * 1024 * 1024
    private static let baseAudioPacketCapacity = 480

    private var videoPacketQueue = PacketQueue(
        capacity: baseVideoPacketCapacity,
        maxBytes: baseVideoPacketMaxBytes
    )
    private var audioPacketQueue = PacketQueue(capacity: baseAudioPacketCapacity)

    // MARK: - Cancellation

    private let cancelLock = NSLock()
    private var _isCancelled = false
    private var _isDisposed = false
    private let endOfFileCoordinator = EndOfFileCoordinator()
    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _isCancelled
    }
    private var isDisposed: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _isDisposed
    }
    private func markCancelled() {
        cancelLock.lock()
        _isCancelled = true
        cancelLock.unlock()
        // Wake the video feed loop if it is parked on the decoded-frame
        // backpressure condition — otherwise it would only re-check
        // isCancelled after the next `broadcast()` from a tick or drain.
        videoFrameScheduler.wakeWaiters()
    }
    /// Atomic test-and-set: returns `true` the first time it's called, `false`
    /// thereafter. Used so `dispose()` is idempotent across threads.
    @discardableResult
    private func claimDisposed() -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        if _isDisposed { return false }
        _isDisposed = true
        return true
    }
    private func currentEndOfFileGeneration() -> UInt64 {
        endOfFileCoordinator.currentGeneration()
    }
    private func clearEndOfFileFlag() {
        endOfFileCoordinator.clear()
    }

    // MARK: - Deferred track selection during load

    /// `setAudioTrack` calls `markCancelled()`, which the FFmpeg interrupt
    /// callback treats as "abort blocking I/O". If that fires while
    /// `openAndDemux` is inside its startTime seek (e.g. a persisted or
    /// detail-page audio selection applied as soon as tracks enumerate),
    /// the aborted read poisons the matroska demuxer — the file is marked
    /// broken and every subsequent seek lands near the start. A switch
    /// requested while a load is in flight is parked here and applied via
    /// the normal switch path once the open completes.
    private let deferredTrackLock = NSLock()
    private var _loadInProgress = false
    /// `.some(id)` is a parked request; the inner `id` nil means "disable audio".
    private var _deferredAudioTrackId: Int64??

    private func beginLoadGate() {
        deferredTrackLock.lock()
        _loadInProgress = true
        _deferredAudioTrackId = nil
        deferredTrackLock.unlock()
    }

    /// Returns true if the switch was parked because a load is in flight.
    private func deferAudioTrackSwitchIfLoading(_ id: Int64?) -> Bool {
        deferredTrackLock.lock()
        defer { deferredTrackLock.unlock() }
        guard _loadInProgress else { return false }
        _deferredAudioTrackId = .some(id)
        return true
    }

    /// Ends the load gate. On a successful open, applies any parked audio
    /// track switch through the normal cancel-and-switch path; on failure
    /// the request is dropped (the VM re-applies selections on reload).
    /// No-op outside a load, so failure funnels can call it unconditionally.
    private func endLoadGate(applyDeferredSwitch: Bool) {
        deferredTrackLock.lock()
        _loadInProgress = false
        let parked = _deferredAudioTrackId
        _deferredAudioTrackId = nil
        deferredTrackLock.unlock()
        guard applyDeferredSwitch, let newId = parked, !isDisposed else { return }
        Self.logger.info("applying deferred setAudioTrack(\(newId ?? -1)) after load")
        markCancelled()
        controlQueue.async { [weak self] in
            self?.performAudioTrackSwitch(newId: newId)
        }
    }

    // MARK: - Seek coalescing

    /// Latest-wins latch for seek targets; see `runSeekWorker()`.
    private let seekLatch = SeekLatch()

    // MARK: - Playback health telemetry
    //
    // Counters feeding the 1 Hz diagnostics line, the stats panel, and the
    // planned playback-diagnostics reporting. Written from main (buffering
    // monitor, display tick), controlQueue (seek worker), and arbitrary
    // seek-caller threads, so all access goes through `telemetryLock`.

    private let telemetryLock = NSLock()
    private var _seekCount: UInt64 = 0
    private var _coalescedSeekCount: UInt64 = 0
    /// Wall time of the most recent seek worker iteration. Never reset —
    /// also drives the buffering policy's post-seek fast-resume window.
    private var _lastSeekWall: CFTimeInterval = -.infinity
    /// Wall time armed by a seek and consumed by the first post-seek frame
    /// enqueue to compute seek→first-frame latency.
    private var _seekLatencyArmedWall: CFTimeInterval?
    private var _lastSeekToFirstFrameSeconds: Double?
    private var _rebufferCount = 0
    /// Rebuffers whose binding constraint was the audio track. Reported as the
    /// `playback.audio_underruns` diagnostics attribute: from the user's side
    /// an audio-starved stall *is* an underrun, and the renderer exposes no
    /// underrun counter of its own.
    private var _audioUnderrunCount = 0
    private var _bufferingWallSeconds: Double = 0
    private var _bufferingSinceWall: CFTimeInterval?
    private var _lastRebufferRecoverySeconds: Double?
    private var _avsyncFlushCount: UInt64 = 0
    private var _avsyncGopDropCount: UInt64 = 0
    private var _avsyncReseekCount: UInt64 = 0
    private var _avsyncDroppedPacketSeconds: Double = 0

    /// Wall time the in-flight seek worker iteration started; nil when no
    /// iteration is running. Basis for the seek-stall watchdog.
    private var _seekIterationStartWall: CFTimeInterval?
    private var _seekStallReported = false
    /// A seek iteration older than this is declared wedged. FFmpeg's
    /// interrupt callback + rw_timeout are supposed to bound
    /// `avformat_seek_file`, but the vendored build's TLS reads have been
    /// observed blocking without polling either (tvOS, TLS decode error →
    /// reconnect → dead read). Comfortably above `demuxIOTimeoutSeconds` so
    /// the watchdog only fires after FFmpeg's own timeouts have failed.
    private static let seekStallTimeoutSeconds: CFTimeInterval = 15.0

    private func noteSeekStarted() {
        let now = CACurrentMediaTime()
        telemetryLock.lock()
        _seekCount &+= 1
        _lastSeekWall = now
        _seekLatencyArmedWall = now
        _seekIterationStartWall = now
        _seekStallReported = false
        telemetryLock.unlock()
    }

    private func noteSeekIterationEnded() {
        telemetryLock.lock()
        _seekIterationStartWall = nil
        telemetryLock.unlock()
    }

    /// Returns the stalled iteration's age when the watchdog should fire,
    /// else nil. Sets the reported flag so it fires once per iteration.
    private func claimSeekStall() -> Double? {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        guard let started = _seekIterationStartWall, !_seekStallReported else { return nil }
        let age = CACurrentMediaTime() - started
        guard age > Self.seekStallTimeoutSeconds else { return nil }
        _seekStallReported = true
        return age
    }

    private func noteCoalescedSeek() {
        telemetryLock.lock()
        _coalescedSeekCount &+= 1
        telemetryLock.unlock()
    }

    private func noteSeekFirstFrame() {
        telemetryLock.lock()
        if let armed = _seekLatencyArmedWall {
            _lastSeekToFirstFrameSeconds = CACurrentMediaTime() - armed
            _seekLatencyArmedWall = nil
        }
        telemetryLock.unlock()
    }

    /// Seconds since the last seek worker iteration began; used by the
    /// buffering policy's post-seek fast-resume path.
    private func secondsSinceLastSeek() -> Double {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        guard _lastSeekWall.isFinite else { return .infinity }
        return CACurrentMediaTime() - _lastSeekWall
    }

    /// Records a buffering edge. `audioStarved` marks an entry whose binding
    /// constraint was the audio track so the audio-underrun tally stays
    /// separable from generic rebuffers.
    private func noteBufferingTransition(
        _ buffering: Bool,
        audioStarved: Bool = false
    ) {
        let now = CACurrentMediaTime()
        telemetryLock.lock()
        if buffering {
            _rebufferCount += 1
            if audioStarved { _audioUnderrunCount += 1 }
            _bufferingSinceWall = now
        } else if let since = _bufferingSinceWall {
            let elapsed = now - since
            _bufferingWallSeconds += elapsed
            _lastRebufferRecoverySeconds = elapsed
            _bufferingSinceWall = nil
        }
        telemetryLock.unlock()
    }

    /// Running audio-underrun tally for the `playback.audio_underruns`
    /// attribute. Only `noteBufferingTransition` writes it, and only from the
    /// buffering timer on main, so a read taken right after that call on the
    /// same thread reports exactly the edge just recorded.
    private func audioUnderrunCount() -> Int {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        return _audioUnderrunCount
    }

    /// Classifies which track ran dry at a buffering edge, for the
    /// `playback.reason` attribute. Stable tokens, not prose: they are the
    /// grouping key when reading rebuffers across reports.
    static func stallCause(
        videoBufferedSeconds: Double?,
        audioBufferedSeconds: Double?
    ) -> String {
        switch (videoBufferedSeconds, audioBufferedSeconds) {
        case let (video?, audio?):
            // Both tracks present: name whichever is shallower. A tie (both
            // dry) reads as the network having stopped feeding either.
            if video < audio { return "video_starved" }
            if audio < video { return "audio_starved" }
            return "source_starved"
        case (_?, nil):
            return "video_starved"
        case (nil, _?):
            return "audio_starved"
        case (nil, nil):
            return "source_starved"
        }
    }

    /// Clamps a playback position in seconds to a non-negative whole-
    /// millisecond count for the `playback.position_ms` attribute; the
    /// registry has no float type. Non-finite and negative inputs collapse to
    /// zero, matching how an unusable clock is treated everywhere else here.
    static func positionMilliseconds(_ seconds: Double) -> Int {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let milliseconds = (clamped * 1000).rounded()
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds)
    }

    private func noteAvsyncAction(_ action: AVSyncLadder.Action, droppedPacketSeconds: Double = 0) {
        telemetryLock.lock()
        switch action {
        case .flushDecodedFrames: _avsyncFlushCount &+= 1
        case .dropPacketsToNextKeyframe:
            _avsyncGopDropCount &+= 1
            _avsyncDroppedPacketSeconds += droppedPacketSeconds
        case .reseekToClock: _avsyncReseekCount &+= 1
        case .none: break
        }
        telemetryLock.unlock()
    }

    func playbackHealthStats() -> PlaybackHealthStats {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        return PlaybackHealthStats(
            rebufferCount: _rebufferCount,
            bufferingWallSeconds: _bufferingWallSeconds
                + (_bufferingSinceWall.map { CACurrentMediaTime() - $0 } ?? 0),
            lastRebufferRecoverySeconds: _lastRebufferRecoverySeconds,
            seekCount: _seekCount,
            coalescedSeekCount: _coalescedSeekCount,
            lastSeekToFirstFrameSeconds: _lastSeekToFirstFrameSeconds,
            avsyncFlushCount: _avsyncFlushCount,
            avsyncGopDropCount: _avsyncGopDropCount,
            avsyncReseekCount: _avsyncReseekCount,
            avsyncDroppedPacketSeconds: _avsyncDroppedPacketSeconds
        )
    }

    // MARK: - Stream info learned at load time

    private var refreshRate: Float = 24.0
    private var dynamicRange: SpikeDynamicRange = .sdr
    private var sourceColorRangeHint: String?
    private var resolvedVideoColorRange: String?
    /// Parsed Dolby Vision config record from the stream's `AV_PKT_DATA_DOVI_CONF`
    /// side data. `nil` when the source is not DV. Set during
    /// `buildVideoFormatDescription`.
    private var doviConfig: DolbyVisionFormat.Config?
    /// True for Profile 5 (DV-only, no HDR10 back-compat). The base layer is PQ
    /// bytes that are not valid HDR10, so playback must be refused unless the
    /// TV can actually switch into DV mode.
    private var requiresDolbyVisionDisplay: Bool = false
    /// True for Profile 4/7 (dual-layer HEVC). The elementary stream contains
    /// BL NAL units interleaved with EL NAL units (nuh_layer_id > 0) and DV
    /// RPU/metadata NAL units (nal_unit_type 62/63). VT's HEVC decoder chokes
    /// on these intermittently and produces decode stalls. Filter them at
    /// packet-feed time so VT sees a clean BL bitstream.
    private var shouldStripHevcEnhancement: Bool = false
    /// Diagnostic: cumulative NAL units dropped by `stripHevcEnhancementLayer`.
    private var strippedNalCount: UInt64 = 0
    #if os(tvOS)
    /// Observation + watchdog for Profile-5 DV-mode negotiation. See
    /// `applyDvGatedDisplayCriteria`. Cleared on success, timeout, or dispose.
    private var dvGateObservation: NSKeyValueObservation?
    private var dvGateTimeoutItem: DispatchWorkItem?
    #endif
    private var durationSeconds: Double = 0

    // UI time observer on main.
    private var playbackTimeObserver: Timer?

    // Buffering state (reflects whether playback is starving for media).
    private var bufferingState = false
    /// Hysteresis policy behind `bufferingState`. Main-only (timer thread).
    private var bufferingPolicy = BufferingPolicy()
    /// Last whole-percent buffering progress reported; dedupes the 10 Hz
    /// sampling down to actual changes. Main-only.
    private var lastReportedBufferingProgress = -1
    /// Post-seek window in which the buffering policy uses its faster
    /// resume threshold.
    private static let postSeekFastResumeWindowSeconds: CFTimeInterval = 10.0
    /// Timer that samples buffered seconds + renderer readiness every 100ms.
    /// Used for the `onBufferingChange` heuristic. Runs on main.
    private var bufferingTimer: Timer?

    /// Counts consecutive VT decode failures after a successful session
    /// creation. If we cross the threshold without ever producing a decoded
    /// frame, we surface an error instead of hanging on a loading spinner.
    /// Touched only on VT's callback thread + decode thread; both are
    /// serialized through the VT session's internal synchronization.
    private var consecutiveDecodeFailures: Int = 0
    private var hasReportedDecodeFailure = false
    /// Guards against re-entering the VT session rebuild path while one is
    /// already in flight. Without this, every decode callback firing -12903
    /// between teardown and recreate would try to rebuild and we'd thrash.
    private var isRebuildingDecoder = false
    /// Set when VT's async output callback sees `kVTInvalidSessionErr`
    /// before the submit path gets a chance to rebuild inline on
    /// `videoFeedQueue`. The next packet on the feed loop performs the
    /// actual teardown/recreate before submitting more work to VT.
    private var decoderRebuildPending = false
    /// Armed to tag the next sample buffer sent to VT with
    /// `kCMSampleAttachmentKey_ResetDecoderBeforeDecoding`. Without this,
    /// VT retains reference frames from the pre-seek GOP and emits
    /// `-8969` / similar for every new post-seek packet until it happens
    /// to land a clean I-frame — which often crosses the 30-failure
    /// threshold first.
    ///
    /// Writers: control queue (seek / audio-track switch), `videoFeedQueue`
    /// (decode-burst resync), and main (A/V-sync ladder packet drops, which
    /// race the live feed loop — the reason this is locked rather than
    /// relying on dispatch happens-before like its neighbors). The
    /// generation guard keeps the decode thread's post-apply clear from
    /// erasing an arm that landed while the sample was in flight.
    private let decoderResetLock = NSLock()
    private var _decoderResetArmed = false
    private var _decoderResetGeneration: UInt64 = 0

    private func armDecoderReset() {
        decoderResetLock.lock()
        _decoderResetArmed = true
        _decoderResetGeneration &+= 1
        decoderResetLock.unlock()
    }

    private func decoderResetSnapshot() -> (armed: Bool, generation: UInt64) {
        decoderResetLock.lock()
        defer { decoderResetLock.unlock() }
        return (_decoderResetArmed, _decoderResetGeneration)
    }

    private func clearDecoderReset(ifGeneration generation: UInt64) {
        decoderResetLock.lock()
        if _decoderResetGeneration == generation {
            _decoderResetArmed = false
        }
        decoderResetLock.unlock()
    }
    /// Cumulative VT decode failures since the current `openAndDemux` session
    /// started. Used to print milestone log lines for on-device diagnosis —
    /// OSLog warnings from VT don't reach `devicectl --console` on tvOS.
    private var totalDecodeErrors: UInt64 = 0
    /// Cumulative VT frame drops (`infoFlags.contains(.frameDropped)`) since
    /// the current session started. Same log-milestone treatment.
    private var totalVtFrameDrops: UInt64 = 0

    // MARK: - VideoToolbox `-12909` burst recovery
    //
    // Some valid H.264 / HEVC files have local GOP regions that make
    // VideoToolbox reject a run of frames as bad data while surrounding GOPs
    // decode cleanly. Rather than abandoning the CoreMedia decoder immediately,
    // flush and resync at the next IDR -- exactly like a seek. Bounded so a
    // genuinely undecodable region still falls through to the existing
    // terminal/fallback behavior instead of looping forever.
    private static let maxDecodeBurstRecoveryAttempts = 2
    /// Clean decodes after a resync before the burst is considered ridden out
    /// and the attempt budget is refreshed (~2 s at 24 fps).
    private static let decodeBurstRecoveryStableFrames = 48
    /// Resync attempts since the last sustained-clean run. Touched on VT's
    /// callback thread + the decode thread (serialized through the VT session),
    /// same as `consecutiveDecodeFailures`.
    private var decodeBurstRecoveryAttempts = 0
    /// Successful decodes since the last resync attempt; resets the attempt
    /// budget once it clears `decodeBurstRecoveryStableFrames`.
    private var framesDecodedSinceRecovery = 0
    /// Set on VT's callback thread when a `-12909` burst is detected there;
    /// consumed on `videoFeedQueue` before the next packet so the flush/resync
    /// runs off the callback thread (mirrors `decoderRebuildPending`).
    private var pendingDecodeBurstResync = false
    /// Guards the resync path so the in-flight failed decodes that drain during
    /// `flushVideoDecoderAfterDiscontinuity()` don't each re-trigger recovery
    /// and burn the attempt budget (mirrors `isRebuildingDecoder` for -12903).
    private var isRecoveringDecodeBurst = false
    /// Serializes the decode-recovery state group above
    /// (`consecutiveDecodeFailures`, `hasReportedDecodeFailure`,
    /// `isRebuildingDecoder`, `decoderRebuildPending`,
    /// `decodeBurstRecoveryAttempts`, `framesDecodedSinceRecovery`,
    /// `pendingDecodeBurstResync`, `isRecoveringDecodeBurst`). VT delivers
    /// async output callbacks on its own thread while the submit/recovery work
    /// runs on `videoFeedQueue`, and VT does not guarantee the two are
    /// serialized — so these fields are genuinely shared. `RealtimeAudioLock`
    /// is a generic `os_unfair_lock` wrapper (named for its first use). The
    /// lock is *never* held across the blocking decoder flush/recreate, which
    /// drains async frames that re-enter on the callback thread: decisions are
    /// made under the lock and the heavy work runs after release.
    private let decodeRecoveryLock = RealtimeAudioLock()

    /// Outcome of `recordDecodeFailure`'s decision, computed under
    /// `decodeRecoveryLock` and executed after the lock is released so no
    /// blocking decoder work happens while holding the lock.
    private enum DecodeFailureAction {
        case none
        case burstResyncInline
        case rebuildInline
        case reportUnsupported(StreamRejection, URL)
        case terminal(String)
    }

    // MARK: - Temporary slow-motion-debug instrumentation
    //
    // `print()` rather than Logger.info so `devicectl ... --console` captures
    // the lines (OSLog doesn't reach the console stream on tvOS). Revert once
    // the root cause is identified.
    private var diagnosticsTimer: Timer?
    private var diagStartWall: CFTimeInterval = 0
    private var diagStartSyncTime: Double = 0
    /// Last playhead second at which the live-subtitle render diagnostic logged,
    /// so `pumpSubtitleOverlay` samples it ~1×/s instead of every vsync.
    private var lastLiveOverlayDiagSeconds: Double = -1
    private var lastDiagEnqueueCount: UInt64 = 0
    private var lastDiagAudioEnqueueCount: UInt64 = 0
    private var vSyncHolds: UInt64 = 0
    private var vSyncDrops: UInt64 = 0
    /// Wall-clock deadline (CACurrentMediaTime basis) until which the
    /// `videoDisplayLinkTick` sync predicate widens its drop tolerance to
    /// accommodate post-discontinuity catch-up (HLS keyframe gaps after a
    /// seek / audio-track switch / openAndDemux). Outside this window the
    /// predicate uses a tight `-2 × frameDuration` bound so transient
    /// main-thread stalls (SwiftUI focus + material blur in the player HUD,
    /// system animations, etc.) drop late frames instead of accumulating
    /// permanent A/V drift.
    private var postDiscontinuityWallDeadline: CFTimeInterval = 0
    private static let postDiscontinuityWindowSeconds: CFTimeInterval = 5.0
    private static let postDiscontinuityPrerollTimeoutSeconds: CFTimeInterval = 3.0
    private static let postDiscontinuityMinimumAudioBufferSeconds: Double = 0.25
    private static let postDiscontinuityMinimumDecodedVideoFrames = 1
    /// Main-thread token used to cancel stale post-seek/post-track-switch
    /// preroll waiters when another discontinuity supersedes them.
    private var playbackRestartGeneration: UInt64 = 0
    private var audioEnqueueCount: UInt64 = 0
    // Count of audio-feed wakeups and the last observed audio-output status.
    // If `audRdy=1` but `aEnq=+0` persists across DIAG ticks, we want to know
    // (a) whether the backend flipped to a failed state and we never noticed,
    // and (b) whether the system is still invoking our feed block.
    private var audioFeedInvocations: UInt64 = 0
    private var lastAudioRendererStatus: Int = -1

    // --- Demux-progress instrumentation (Bug B: `av_read_frame` hang) -------
    //
    // `demuxReadCount` increments every time we *enter* `av_read_frame`;
    // `demuxReturnCount` every time it *returns*. If enter > return, we're
    // currently blocked inside FFmpeg's I/O. `demuxLastProgressWall` is the
    // host-clock stamp of the last successful (rc >= 0) return. The interrupt
    // callback reads `demuxLastProgressWall` and returns 1 (abort) if we've
    // been stuck for longer than `demuxIOTimeoutSeconds`, which makes a
    // blocking socket read bail out of `av_read_frame` with a negative rc so
    // the demux loop can surface an error instead of hanging forever.
    //
    // All of these are written/read across threads (demuxQueue ↔ FFmpeg's
    // I/O callback thread ↔ main for DIAG). They're `Atomic`-by-convention:
    // single writer per field, readers get a possibly-stale value which is
    // fine for diagnostics + a soft timeout.
    private var demuxReadCount: UInt64 = 0
    private var demuxReturnCount: UInt64 = 0
    private var demuxLastProgressWall: CFTimeInterval = 0
    private let demuxIOTimeoutSeconds: CFTimeInterval = 10.0

    // MARK: - Phase 2: runtime configurable knobs

    /// True iff the user explicitly paused via `pause()`. Used by the stall
    /// watchdog in `logDiagnosticSnapshot` to distinguish intentional pauses
    /// (don't recover) from externally-induced playback stalls (do recover).
    private var userPaused: Bool = false
    /// Wall-clock timestamp of the most recent stall recovery, so the
    /// watchdog doesn't re-fire more than once per second.
    private var lastStallRecoveryWall: CFTimeInterval = 0
    /// User-requested playback rate. Re-applied on `play()` so toggling
    /// pause/play doesn't reset to 1.0. Clamped to the 0.5...3.0 range that
    /// `AVAudioEngine` + `AVAudioUnitTimePitch` realistically handle cleanly.
    private var currentRate: Float = 1.0
    /// Multiplier on the base PacketQueue capacities. Reserved for a future
    /// buffer-size setting; fixed at 1.0 until then.
    private let demuxerBufferMultiplier: Double = 1.0
    /// The subtitle track the caller last selected. Phase 3 will act on this
    /// once subtitle decode/rendering exists; for Phase 2 we just remember
    /// the id so a selection made pre-load persists through playback.
    private var pendingSubtitleTrackId: Int64?
    private var pendingSecondarySubtitleTrackId: Int64?
    /// Cached track list for the currently-loaded file. Lets `setAudioTrack`
    /// look up the ffmpeg stream index from the caller-visible `trackId`
    /// without re-walking the AVFormatContext.
    private var currentTracks: [PlayerTrack] = []
    /// Cached chapter list for the currently-loaded file.
    private var currentChapters: [ChapterInfo] = []

    // MARK: - Phase 3 state

    /// PiP controller, lazily created once a display layer is attached.
    /// tvOS 14.0+ only; guarded with `@available` at use sites.
    private var pipController: Any?
    /// True while PiP is on-screen. Exposed via onPictureInPictureActiveChange.
    private(set) var isPictureInPictureActive: Bool = false
    /// True once we've successfully activated AVAudioSession. Guarded so we
    /// don't re-activate on every `load()` (route-change hot path). Reset by
    /// `deactivateAudioSession()` called from `dispose()`.
    #if !os(macOS)
    private var audioSessionActive: Bool = false
    #endif

    private let embeddedSubtitlePipeline = EmbeddedSubtitlePipeline()

    /// Dedicated subtitle-only FFmpeg context for runtime embedded-track
    /// switches (shared implementation with the AVPlayer route). The main
    /// demuxer runs tens of seconds ahead of the playhead and discards
    /// packets of unselected subtitle streams, so enabling a track through
    /// the in-band pipeline mid-playback would show no cues until the
    /// playhead crosses the toggle-time demux head. This context re-opens
    /// the source, seeks to the playhead, and feeds libass immediately.
    /// Created lazily on the first runtime switch; reset per load.
    private var runtimeSubtitleExtractor: AVPlayerEmbeddedSubtitleExtractor?

    /// libass-backed subtitle session. Created eagerly in `init()` so the
    /// overlay view can receive a non-nil renderer reference before the
    /// first `load()` is issued — otherwise `layoutSubviews` never pushes
    /// a frame size to libass and the first render silently bails. State
    /// is reset (tracks/cache) per load via `teardown()`.
    private var subtitleSession: SubtitleSession?

    /// Live overlay views mounted by `PlayerSurface`. Next Up transitions can
    /// overlap a mini-player and full-screen surface, so ownership is tracked
    /// rather than stored in one racy weak property.
    private let subtitleOverlayAttachments = SubtitleOverlayAttachmentRegistry()
    var subtitleOverlay: SubtitleOverlayView? {
        subtitleOverlayAttachments.currentOverlay
    }

    func attachSubtitleOverlay(_ overlay: SubtitleOverlayView, owner: AnyObject) {
        subtitleOverlayAttachments.attach(owner: owner, overlay: overlay)
    }

    func detachSubtitleOverlay(owner: AnyObject) {
        subtitleOverlayAttachments.detach(owner: owner)
    }

    /// Renderer handle exposed so the overlay view can receive frame-size
    /// notifications directly on layout.
    var subtitleRendererForOverlay: SubtitleRenderer? {
        subtitleSession?.underlyingRenderer
    }

    // Signpost IDs.
    private var loadSignpostID: OSSignpostID = .null
    private var seekSignpostID: OSSignpostID = .null

    override init() {
        super.init()
        audioOutput.onRenderedTime = { [weak self] renderedTime in
            self?.handleRenderedAudioTime(renderedTime)
        }
        audioOutput.onFailure = { [weak self] message in
            self?.reportError("Audio output failed: \(message)")
        }
        let session = SubtitleSession()
        session.onSidecarTracksRegistered = { [weak self] descriptors in
            self?.onSidecarTracksRegistered?(descriptors)
        }
        session.onStatusChange = { [weak self] slot, status in
            self?.onSubtitleLoadStatusChange?(slot, status)
        }
        session.currentPositionSecondsProvider = { [weak self] in
            self?.currentPlaybackTimeSeconds() ?? 0
        }
        subtitleSession = session
        installAudioSessionObservers()
        Self.logger.info("PlayerCore.init()")
    }

    deinit {
        Self.logger.info("PlayerCore.deinit")
        removeAudioSessionObservers()
        // Inline frees only: the deferred-free path captures `self` strongly
        // on the control queue, which is illegal from deinit (resurrection).
        // Inline is safe here — any in-flight control-queue work (seek) holds
        // a strong `self`, so reaching deinit proves the queue has none.
        dispose(deferringFrees: false)
    }

    // MARK: - AVAudioSession lifecycle observers

    /// Tokens for the AVAudioSession notifications we own. Held so deinit
    /// can remove them; on macOS these stay nil because AVAudioSession is
    /// iOS/tvOS only.
    private var audioRouteChangeObserver: NSObjectProtocol?
    private var audioMediaServicesResetObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    /// True when an AVAudioSession interruption (call, Siri, alarm) paused
    /// playback the user had running. Drives the optional auto-resume on
    /// `.ended` + `.shouldResume`. Cleared whenever `play()` runs so a manual
    /// resume during the interruption supersedes the auto-resume.
    private var wasPlayingWhenInterrupted = false

    private func installAudioSessionObservers() {
        #if !os(macOS)
        let center = NotificationCenter.default
        audioRouteChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleAudioRouteChange(note)
        }
        audioMediaServicesResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.handleAudioMediaServicesReset()
        }
        audioInterruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleAudioSessionInterruption(note)
        }
        #endif
    }

    private func removeAudioSessionObservers() {
        let center = NotificationCenter.default
        if let token = audioRouteChangeObserver {
            center.removeObserver(token)
            audioRouteChangeObserver = nil
        }
        if let token = audioMediaServicesResetObserver {
            center.removeObserver(token)
            audioMediaServicesResetObserver = nil
        }
        if let token = audioInterruptionObserver {
            center.removeObserver(token)
            audioInterruptionObserver = nil
        }
    }

    #if !os(macOS)
    private func handleAudioRouteChange(_ note: Notification) {
        guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map(\.portType.rawValue)
            .joined(separator: ",")
        Self.logger.info(
            "AVAudioSession route changed: reason=\(reason.rawValue) outputs=\(outputs, privacy: .public)"
        )
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .playback,
            tag: "AudioRoute",
            message: "audio route changed",
            attrs: [
                "reason": .string(String(reason.rawValue)),
                "sink": .string(outputs.isEmpty ? "none" : outputs),
            ]
        )
        #endif
        // For reasons that change downstream channel layout (new device,
        // category change, override), drop any pending audio chunks so the
        // engine reprepares against the new route's preferred format on the
        // next enqueue rather than continuing to render against a stale
        // format. Don't react to reasons like `unknown` or `wakeFromSleep`
        // where the route did not actually change.
        switch reason {
        case .oldDeviceUnavailable:
            // The active output went away (headphones/AirPods unplugged or
            // out of range). Drop buffered audio AND pause: letting playback
            // continue through the fallback route is the classic "audio
            // suddenly blasting from the speaker" failure.
            audioOutput.flush()
            if !userPaused {
                pause()
            }
        case .newDeviceAvailable, .categoryChange,
             .override, .routeConfigurationChange:
            audioOutput.flush()
        default:
            break
        }
    }

    /// Phone call / Siri / alarm interruptions. On `.began` the system has
    /// already silenced the session and stopped the engine — route through
    /// `pause()` so the timeline anchors at the interruption point and the
    /// VM sees the state flip via `onPauseChange`. On `.ended`, resume only
    /// when the system says `.shouldResume` and the user hasn't intervened.
    private func handleAudioSessionInterruption(_ note: Notification) {
        guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            guard !isDisposed, !userPaused else { return }
            Self.logger.info("AVAudioSession interruption began — pausing")
            print("[CMP] audio interruption began; pausing")
            wasPlayingWhenInterrupted = true
            pause()
        case .ended:
            let shouldRestore = wasPlayingWhenInterrupted
            wasPlayingWhenInterrupted = false
            guard shouldRestore, !isDisposed else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume) else { return }
            Self.logger.info("AVAudioSession interruption ended — resuming")
            print("[CMP] audio interruption ended; resuming")
            // The interruption deactivated our session; reactivate before
            // restarting the engine.
            audioSessionActive = false
            activateAudioSession()
            play()
        @unknown default:
            break
        }
    }

    private func handleAudioMediaServicesReset() {
        Self.logger.error(
            "AVAudioSession mediaServicesWereReset — tearing down audio engine and surfacing as recoverable error"
        )
        // Fully reset the engine; the next packet enqueue will reprepare it.
        audioOutput.stop()
        audioSessionActive = false
        // Surface so the VM can decide whether to fall back or retry.
        reportError("Audio media services were reset; restart playback to resume audio")
    }
    #endif

    // MARK: - FFmpeg error helpers

    /// Wraps `av_strerror` so errno-style ffmpeg return codes turn into a
    /// readable message on the onError channel. Keeps callsites terse.
    private static func ffmpegError(_ code: Int32) -> String {
        var buf = [Int8](repeating: 0, count: 256)
        _ = av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }

    // MARK: - Audio session

    /// Activate `.playback / .moviePlayback` and request multichannel output
    /// sized to the current audio stream. Idempotent — called lazily from
    /// `load()` and guarded by `audioSessionActive`. Errors are surfaced via
    /// onError (non-fatal; playback still works with the pre-existing
    /// session the app set up earlier).
    private func activateAudioSession(preferredChannels: Int32? = nil) {
        #if os(macOS)
        _ = preferredChannels
        #else
        let session = AVAudioSession.sharedInstance()
        do {
            if !audioSessionActive {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true, options: [])
                audioSessionActive = true
            }
            if let preferredChannels, preferredChannels > 0 {
                let maxCh = Int32(session.maximumOutputNumberOfChannels)
                let want = Int(min(preferredChannels, max(1, maxCh)))
                try session.setPreferredOutputNumberOfChannels(want)
                Self.logger.info("preferredOutputChannels=\(want)")
            }
        } catch {
            let msg = "Audio session setup failed: \(error.localizedDescription)"
            Self.logger.error("\(msg, privacy: .public)")
            print("[CMP] ERROR: \(msg)")
            DispatchQueue.main.async { [weak self] in
                self?.onError?(msg)
            }
        }
        #endif
    }

    #if !os(macOS)
    private func spatialAudioEnabled(for session: AVAudioSession) -> Bool {
        if #available(iOS 15.0, tvOS 15.0, *) {
            let enabled = session.currentRoute.outputs.contains { $0.isSpatialAudioEnabled }
            try? session.setSupportsMultichannelContent(enabled)
            return enabled
        }
        return false
    }

    private func preferredOutputChannelCount(
        forSourceChannels sourceChannels: Int32,
        session: AVAudioSession = .sharedInstance()
    ) -> Int32 {
        let sourceChannels = max(1, sourceChannels)
        guard sourceChannels > 2 else { return sourceChannels }
        if spatialAudioEnabled(for: session) {
            return sourceChannels
        }
        let maxRouteChannels = max(2, Int32(session.maximumOutputNumberOfChannels))
        return min(sourceChannels, maxRouteChannels)
    }
    #else
    private func preferredOutputChannelCount(forSourceChannels sourceChannels: Int32) -> Int32 {
        max(1, sourceChannels)
    }
    #endif

    /// Recover a wedged `AVSampleBufferDisplayLayer` that has transitioned
    /// to `.failed` status. The previously-used `flush()` clears queued
    /// samples but doesn't always reset the layer's status — observed on
    /// tvOS 18 after `kVTInvalidSessionErr (-12903)` decoder failures, the
    /// layer stays `.failed` even after flush, which then leaves the next
    /// session's video pipeline broken (no frames presented, predicate
    /// drops everything trying to catch up to a stale audio clock).
    ///
    /// `flushAndRemoveImage()` is the aggressive variant — drops queued
    /// samples *and* the currently-displayed image, and also resets the
    /// layer's status on tvOS in cases where plain flush leaves it wedged.
    /// We re-attach `controlTimebase` afterward because some tvOS versions
    /// silently drop it during the more aggressive flush.
    ///
    /// `reason` is logged to make recovery sites distinguishable in the
    /// `[CMP]` console stream.
    private func recoverDisplayLayerIfFailed(reason: String) {
        guard let layer = displayLayer, layer.sampleBufferRenderer.status == .failed else { return }
        let renderer = layer.sampleBufferRenderer
        print("[CMP] recover: displayLayer.status=failed (\(reason)) error=\(String(describing: renderer.error)); flushAndRemoveImage")
        renderer.flush(removingDisplayedImage: true) { }
        if let tb = controlTimebase, layer.controlTimebase !== tb {
            layer.controlTimebase = tb
        }
    }

    /// Tear down the audio session we activated in `activateAudioSession`.
    /// Non-fatal if it fails (AVFoundation may refuse if another session is
    /// already pulling audio).
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

    private func updateAudioClock(to time: CMTime) {
        playbackClock.updateAudio(to: time)
    }

    private func audioClockSnapshot() -> PlaybackClock.AudioSnapshot {
        playbackClock.audioSnapshot()
    }

    private func wakeVideoToolboxDecodeWaiters() {
        videoToolboxDecoder.wakeWaiters()
    }

    private func resetVideoToolboxDecodeBackpressure() {
        videoToolboxDecoder.resetBackpressure()
    }

    private func videoToolboxInFlightCount() -> Int {
        videoToolboxDecoder.inFlightCount()
    }

    private func setPlaybackTimeline(time: CMTime, rate: Float) {
        playbackClock.setTimeline(time: time, rate: rate)
    }

    private func currentPlaybackTimeSeconds() -> Double {
        playbackClock.currentSeconds(prefersAudioClock: audioStreamIndex >= 0)
    }

    private func currentPlaybackTime() -> CMTime {
        CMTime(seconds: currentPlaybackTimeSeconds(), preferredTimescale: 600)
    }

    private func invalidatePlaybackRestartWaiters() {
        if Thread.isMainThread {
            playbackRestartGeneration &+= 1
        } else {
            DispatchQueue.main.sync {
                playbackRestartGeneration &+= 1
            }
        }
    }

    @discardableResult
    private func seekFormatContext(
        _ context: UnsafeMutablePointer<AVFormatContext>,
        to seconds: Double,
        logContext: String
    ) -> Int32 {
        let target = max(0, seconds)
        if videoStreamIndex >= 0,
           let videoTimestamp = streamTimestamp(seconds: target, timeBase: videoTimeBase) {
            let result = avformat_seek_file(
                context,
                videoStreamIndex,
                Int64.min,
                videoTimestamp,
                Int64.max,
                AVSEEK_FLAG_BACKWARD
            )
            if result >= 0 { return result }
            Self.logger.warning(
                "[CMP-SEEK] \(logContext, privacy: .public) video-stream seek failed result=\(result, privacy: .public); falling back to global seek"
            )
        }

        let timestamp = Int64(target * Double(AV_TIME_BASE))
        let result = avformat_seek_file(
            context, -1, Int64.min, timestamp, Int64.max, AVSEEK_FLAG_BACKWARD
        )
        if result >= 0 { return result }
        return avformat_seek_file(context, -1, Int64.min, timestamp, Int64.max, 0)
    }

    private func streamTimestamp(seconds: Double, timeBase: AVRational) -> Int64? {
        guard seconds.isFinite, timeBase.num > 0, timeBase.den > 0 else { return nil }
        let timestamp = seconds * Double(timeBase.den) / Double(timeBase.num)
        guard timestamp.isFinite,
              timestamp >= Double(Int64.min),
              timestamp <= Double(Int64.max) else {
            return nil
        }
        return Int64(timestamp)
    }

    private func handleRenderedAudioTime(_ renderedTime: CMTime) {
        updateAudioClock(to: renderedTime)
        setPlaybackTimeline(time: renderedTime, rate: playbackClock.rate)
        if shouldResyncClockOnFirstAudio {
            shouldResyncClockOnFirstAudio = false
            postDiscontinuityWallDeadline =
                CACurrentMediaTime() + Self.postDiscontinuityWindowSeconds
        }
    }

    private func startPlaybackTimeObserver() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playbackTimeObserver?.invalidate()
            self.playbackTimeObserver = Timer.scheduledTimer(
                withTimeInterval: 0.01,
                repeats: true
            ) { [weak self] _ in
                guard let self else { return }
                let seconds = self.currentPlaybackTimeSeconds()
                guard seconds.isFinite else { return }
                let now = CACurrentMediaTime()
                guard now - self.lastOnTimeChange >= 0.5 else { return }
                let reported = max(0, seconds)
                guard reported != self.lastReportedSeconds else { return }
                self.lastOnTimeChange = now
                self.lastReportedSeconds = reported
                self.onTimeChange?(reported)
                self.completePlaybackIfInputEOFAndClockReachedEnd(observedSeconds: reported)
            }
        }
    }

    private func noteInputEndOfFile(generation: UInt64) {
        guard !isDisposed else { return }
        guard endOfFileCoordinator.markInputEndOfFile(generation: generation) else { return }
        completePlaybackIfInputEOFAndClockReachedEnd(
            observedSeconds: currentPlaybackTimeSeconds()
        )
    }

    private func completePlaybackIfInputEOFAndClockReachedEnd(observedSeconds: Double) {
        guard !isDisposed else { return }
        guard endOfFileCoordinator.hasReachedInputEndOfFile() else { return }
        guard observedSeconds.isFinite else { return }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            if endOfFileCoordinator.claimEndOfFile() {
                onEndOfFile?()
            }
            return
        }

        let remaining = durationSeconds - observedSeconds
        guard remaining <= 0.5 else { return }
        if endOfFileCoordinator.claimEndOfFile() {
            onEndOfFile?()
        }
    }

    // MARK: - Public API

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard !isDisposed else { return }
        displayLayer = layer

        // Attach a `controlTimebase` parented to the host clock directly on
        // the display layer. Timebase rate is 1.0 for the layer's lifetime;
        // pause is driven by pausing the display link, not by zeroing the
        // timebase rate (which would blank the layer).
        //
        // `AVSampleBufferVideoRenderer` pull mode is the "standard" Apple
        // path but, per tvOS 18 runtime behavior, it never delivers video
        // frames to the display layer here. We use the push-mode alternative:
        // enqueue `CMSampleBuffer`s directly from the display-link tick.
        if controlTimebase == nil {
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &tb
            )
            if let tb {
                layer.controlTimebase = tb
                CMTimebaseSetTime(tb, time: .zero)
                CMTimebaseSetRate(tb, rate: 1.0)
                controlTimebase = tb
                Self.logger.info("controlTimebase created and attached to displayLayer")
            } else {
                Self.logger.error("CMTimebaseCreateWithSourceClock failed; video will not render")
            }
        } else if let tb = controlTimebase, layer.controlTimebase !== tb {
            // Layer swap (view recycling): re-attach the existing timebase so
            // we don't lose the current playback position.
            layer.controlTimebase = tb
            Self.logger.info("controlTimebase re-attached to new displayLayer")
        }

        if displayLink == nil {
            #if os(macOS)
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.videoDisplayLinkTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            displayLink = timer
            Self.logger.info("Video display timer installed on .main/.common")
            #else
            let link = CADisplayLink(target: self, selector: #selector(videoDisplayLinkTick))
            // `.common` (NOT `.default`) — focus-engine nav on tvOS runs its
            // animations on `.default` mode; using `.default` pauses the tick
            // while the user moves focus, stuttering playback.
            link.add(to: .main, forMode: .common)
            link.isPaused = videoDisplayTickPaused
            displayLink = link
            Self.logger.info("CADisplayLink installed on .main/.common")
            #endif
        }

        hasAddedDisplayLayer = true
        setupPictureInPictureIfNeeded(layer: layer)
    }

    /// Lazily construct an AVPictureInPictureController backed by the display
    /// layer. Disabled for both iOS and tvOS for now. Older OSes get no PiP
    /// (no-op).
    private func setupPictureInPictureIfNeeded(layer: AVSampleBufferDisplayLayer) {
        #if os(iOS) || os(tvOS) || os(macOS)
        _ = layer
        return
        #else
        guard #available(iOS 15.0, tvOS 15.0, *) else { return }
        guard pipController == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            Self.logger.info("PiP unsupported on this device")
            return
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        pipController = controller
        Self.logger.info("AVPictureInPictureController created")
        #endif
    }

    private func setVideoDisplayTickPaused(_ paused: Bool) {
        videoDisplayTickPaused = paused
        #if !os(macOS)
        displayLink?.isPaused = paused
        #endif
    }

    private func invalidateVideoDisplayTicker() {
        displayLink?.invalidate()
        displayLink = nil
        videoDisplayTickPaused = true
    }

    /// If a rejection was stashed during stream setup, dispatch it to the VM
    /// on main and return true (caller should bail out of its current
    /// setup flow). Returns false if no rejection is pending.
    @discardableResult
    private func fireRejectionIfPending() -> Bool {
        guard let r = pendingRejection else { return false }
        pendingRejection = nil
        // The load is being abandoned for a route replay; drop any parked
        // track switch — the replacement backend re-applies selections.
        endLoadGate(applyDeferredSwitch: false)
        DispatchQueue.main.async { [weak self] in
            self?.onUnsupportedStream?(r.reason, r.url, r.headers, r.startTime)
        }
        return true
    }

    func load(
        url: URL,
        headers: [String: String],
        startTime: Double,
        colorRangeHint: String? = nil
    ) {
        guard !isDisposed else { return }

        // Stash the load args so the rejection signal (fired from deep inside
        // `buildVideoFormatDescription` on the demux queue) can replay them
        // without a second copy path.
        lastLoadURL = url
        lastLoadHeaders = headers
        lastLoadStartTime = startTime
        sourceColorRangeHint = VideoColorMetadata.normalizedColorRangeName(colorRangeHint)
        resolvedVideoColorRange = nil
        pendingRejection = nil
        ttffLoadAnchor = CFAbsoluteTimeGetCurrent()

        // Park any audio-track switch that arrives before the open
        // completes — see `deferredTrackLock`.
        beginLoadGate()

        // Signpost the full load span. Ends in `openAndDemux` after all
        // init steps complete (or `reportError` on failure).
        loadSignpostID = OSSignpostID(log: Self.signpostLog)
        if #available(iOS 15.0, tvOS 15.0, *) {
            os_signpost(.begin, log: Self.signpostLog, name: "Load",
                        signpostID: loadSignpostID)
        }

        // Bring the audio session up before touching media. Non-fatal if it
        // fails; we'll still try to play.
        activateAudioSession()

        // Reset per-load state. Drain the feed queues — that's where the
        // `requestMediaDataWhenReady` closures execute, so we must wait for
        // them to exit before tearing down decode state. `videoDecodeQueue`
        // and `audioDecodeQueue` are not where the closures actually run.
        invalidatePlaybackRestartWaiters()
        markCancelled()
        // Drain the packet queues FIRST to broadcast on the condition
        // variables, waking any demux enqueue that's blocked on a full
        // queue. Without this, the `demuxQueue.sync {}` below will hang:
        // `markCancelled` doesn't signal the cond, so a blocked enqueue
        // has no way to wake up and notice the cancel flag.
        wakeVideoToolboxDecodeWaiters()
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()

        demuxQueue.sync {}
        videoFeedQueue.sync {}
        audioFeedQueue.sync {}
        embeddedSubtitlePipeline.waitForDecodeQueues()

        // Drain again to catch anything the demux loop pushed between the
        // first drain and the barrier returning.
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()

        // Reallocate packet queues between loads. Happens while the queues
        // are drained so there's no race with the demux enqueue loop.
        videoPacketQueue = PacketQueue(
            capacity: Self.baseVideoPacketCapacity,
            maxBytes: Self.baseVideoPacketMaxBytes
        )
        audioPacketQueue = PacketQueue(capacity: Self.baseAudioPacketCapacity)
        embeddedSubtitlePipeline.resetQueues()

        // Reset session state between files (drops tracks + sidecar cache)
        // but keep the renderer/library alive — the overlay view already
        // holds a weak reference to it and we don't want to break that.
        subtitleSession?.teardown()
        // The runtime extractor is bound to the previous load's URL;
        // rebuild lazily against the new source on the next switch.
        runtimeSubtitleExtractor?.teardown()
        runtimeSubtitleExtractor = nil
        applyCurrentSubtitleStyling()

        // Re-open. This zeroes the cancel flag inside `resetCancellation`.
        resetCancellation()

        hasFiredFileLoaded = false
        hasFiredFirstFrameSignpost = false
        hasLoggedFirstDecodedVideoBuffer = false
        compressedVideoPipeline.resetDiagnostics()
        durationSeconds = 0
        lastOnTimeChange = 0
        lastReportedSeconds = -1
        currentTracks = []
        currentChapters = []
        bufferingState = false
        consecutiveDecodeFailures = 0
        hasReportedDecodeFailure = false
        isRebuildingDecoder = false
        decoderRebuildPending = false
        totalDecodeErrors = 0
        totalVtFrameDrops = 0
        decodeBurstRecoveryAttempts = 0
        framesDecodedSinceRecovery = 0
        pendingDecodeBurstResync = false
        isRecoveringDecodeBurst = false
        userPaused = false
        lastStallRecoveryWall = 0
        setPlaybackTimeline(time: .zero, rate: 0)
        updateAudioClock(to: .zero)
        audioOutput.flush()
        clearEndOfFileFlag()

        // Start the buffering watchdog. Poll is cheap (100ms timer, single
        // atomic read + one property read); stays alive until dispose.
        startBufferingMonitor()

        demuxQueue.async { [weak self] in
            guard let self else { return }
            self.openAndDemux(url: url, headers: headers, startTime: startTime)
        }
    }

    func play() {
        guard !isDisposed else { return }
        userPaused = false
        wasPlayingWhenInterrupted = false
        // A deliberate pause lets the demux queues fill and then throttles
        // reads. Without rearming this clock, the first read after a pause
        // longer than `demuxIOTimeoutSeconds` is immediately killed by the
        // interrupt callback as a false I/O wedge (AVERROR_EXIT).
        demuxLastProgressWall = CACurrentMediaTime()
        let time = currentPlaybackTime()
        setPlaybackTimeline(time: time, rate: currentRate)
        audioOutput.setRate(currentRate)
        audioOutput.play()
        // Resume the video push pipeline. The video `controlTimebase` rate
        // stays at 1.0 — pause is only a display-link toggle (zeroing the
        // timebase rate would blank the layer).
        DispatchQueue.main.async { [weak self] in
            // Backgrounding while paused can leave the sample-buffer layer
            // `.failed`; recover before the tick resumes enqueueing so the
            // first resume after a foreground return isn't a frozen frame.
            self?.recoverDisplayLayerIfFailed(reason: "play")
            self?.setVideoDisplayTickPaused(false)
            self?.onPauseChange?(false)
        }
    }

    private func beginPlaybackWhenPrimed(initial: CMTime, rate: Float, deadline: CFTimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDisposed, !self.isCancelled else { return }
            let audioReady = self.audioStreamIndex < 0 || self.audioOutput.bufferedDurationSeconds >= 1.0
            let videoReady = self.videoStreamIndex < 0 || self.decodedVideoFrameCount() >= 6
            let timedOut = CACurrentMediaTime() >= deadline
            guard audioReady && videoReady || timedOut else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.beginPlaybackWhenPrimed(initial: initial, rate: rate, deadline: deadline)
                }
                return
            }

            self.recoverDisplayLayerIfFailed(reason: "openAndDemux pre-setRate")
            self.setPlaybackTimeline(time: initial, rate: rate)
            self.audioOutput.setRate(rate)
            self.audioOutput.play()
            print(String(format:
                "[CMP] playback start time=%.3f rate=%.2f audSt=%d audioAhead=%.2f videoReady=%d timedOut=%d",
                initial.seconds, Double(rate), self.audioOutput.statusCode,
                self.audioOutput.bufferedDurationSeconds, videoReady ? 1 : 0, timedOut ? 1 : 0))

            // Seed the video-side control timebase so the layer schedules
            // frames relative to `startTime`, not zero. Rate stays 1.0 —
            // pause is driven by toggling the display link, not by zeroing
            // this rate (which would blank the layer).
            if let tb = self.controlTimebase {
                CMTimebaseSetTime(tb, time: initial)
                CMTimebaseSetRate(tb, rate: 1.0)
            }
            self.setVideoDisplayTickPaused(false)

            // Reset the audio clock to startTime so the very first display
            // tick doesn't reject the head frame as "far in the future"
            // before the engine reports the first rendered timestamp.
            self.updateAudioClock(to: initial)
            self.postDiscontinuityWallDeadline =
                CACurrentMediaTime() + Self.postDiscontinuityWindowSeconds
            self.startPlaybackTimeObserver()
            self.onPauseChange?(false)
        }
    }

    private func beginPlaybackAfterDiscontinuityWhenPrimed(
        initial: CMTime,
        rate: Float,
        deadline: CFTimeInterval,
        generation: UInt64,
        reason: String
    ) {
        guard rate != 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isDisposed,
                  !self.isCancelled,
                  self.playbackRestartGeneration == generation else {
                return
            }

            let audioReady = self.audioStreamIndex < 0
                || self.audioOutput.bufferedDurationSeconds >= Self.postDiscontinuityMinimumAudioBufferSeconds
            let videoReady = self.videoStreamIndex < 0
                || self.decodedVideoFrameCount() >= Self.postDiscontinuityMinimumDecodedVideoFrames
            let timedOut = CACurrentMediaTime() >= deadline
            guard audioReady && videoReady || timedOut else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.beginPlaybackAfterDiscontinuityWhenPrimed(
                        initial: initial,
                        rate: rate,
                        deadline: deadline,
                        generation: generation,
                        reason: reason
                    )
                }
                return
            }

            self.recoverDisplayLayerIfFailed(reason: "\(reason) preroll")
            self.setPlaybackTimeline(time: initial, rate: rate)
            self.audioOutput.setRate(rate)
            if self.audioStreamIndex >= 0 {
                self.audioOutput.play()
            }
            if let tb = self.controlTimebase {
                CMTimebaseSetTime(tb, time: initial)
                CMTimebaseSetRate(tb, rate: 1.0)
            }
            self.updateAudioClock(to: initial)
            self.postDiscontinuityWallDeadline =
                CACurrentMediaTime() + Self.postDiscontinuityWindowSeconds
            self.setVideoDisplayTickPaused(false)
            print(String(format:
                "[CMP] discontinuity playback resume reason=%@ time=%.3f rate=%.2f audioAhead=%.2f videoReady=%d timedOut=%d",
                reason, initial.seconds, Double(rate),
                self.audioOutput.bufferedDurationSeconds,
                videoReady ? 1 : 0, timedOut ? 1 : 0))
        }
    }

    private func decodedVideoFrameCount() -> Int {
        videoFrameScheduler.count
    }

    func pause() {
        guard !isDisposed else { return }
        userPaused = true
        let pausedAt = currentPlaybackTime()
        setPlaybackTimeline(time: pausedAt, rate: 0)
        audioOutput.pause()
        DispatchQueue.main.async { [weak self] in
            self?.setVideoDisplayTickPaused(true)
            self?.onPauseChange?(true)
        }
    }

    func seek(to seconds: Double) {
        guard !isDisposed else { return }
        let target = max(0, seconds)

        // Seek tears down the demux + feed workers, rewinds the format ctx,
        // flushes decoders + renderers, then restarts the workers. Running
        // on the control queue keeps us off main (which would deadlock on
        // the main.sync flush) and off demuxQueue (which we need to .sync
        // to drain). Signal cancel immediately so in-flight workers exit.
        //
        // Bursts coalesce through `seekLatch`: the newest target overwrites
        // any pending one, and at most one seek worker runs at a time. A
        // superseded in-flight `performSeek` short-circuits before the
        // renderer flush / worker restart, so a scrub storm pays the
        // expensive tail once, for the final target.
        clearEndOfFileFlag()
        markCancelled()
        guard seekLatch.submit(target) else {
            // An active worker will pick this target up.
            noteCoalescedSeek()
            if #available(iOS 15.0, tvOS 15.0, *) {
                os_signpost(.event, log: Self.signpostLog, name: "SeekCoalesced",
                            "target=%.3f", target)
            }
            return
        }
        seekSignpostID = OSSignpostID(log: Self.signpostLog)
        if #available(iOS 15.0, tvOS 15.0, *) {
            os_signpost(.begin, log: Self.signpostLog, name: "Seek",
                        signpostID: seekSignpostID,
                        "target=%.3f", target)
        }
        // Silence the renderers for the whole burst. Superseded worker
        // iterations skip the renderer-flush tail, so without this the
        // audio renderer keeps playing pre-seek content (and the display
        // tick keeps consuming stale frames) until the final target's
        // flush lands — seconds of old audio over a frozen frame on a slow
        // network. Ordering is safe: this main.async is enqueued before
        // any restart's preroll (also dispatched to main), and every
        // coalesced submit guarantees a later iteration whose preroll
        // re-plays. Rate preservation is untouched — `playbackClock.rate`
        // isn't modified here, so the restart tail still restores the
        // user's rate (or stays paused if they were paused).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.audioOutput.pause()
            self.setVideoDisplayTickPaused(true)
        }
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.runSeekWorker()
        }
    }

    /// Seek worker (controlQueue). Drains the latch: each iteration takes
    /// the newest target and runs a full `performSeek`. `finish()` closes
    /// the submit-vs-exit race — a target submitted after the final nil
    /// `take()` is returned by `finish()` and keeps this worker looping,
    /// because no new worker was started for it (`submit` saw us active).
    private func runSeekWorker() {
        while true {
            guard let target = seekLatch.take() ?? seekLatch.finish() else { break }
            guard !isDisposed else {
                seekLatch.abandon()
                break
            }
            // Iterations after the first run with cancellation cleared by the
            // previous performSeek's restart tail. Re-arm so the drains and
            // barriers below actually stop the freshly restarted workers.
            markCancelled()
            noteSeekStarted()
            performSeek(to: target)
            noteSeekIterationEnded()
        }
        if #available(iOS 15.0, tvOS 15.0, *) {
            os_signpost(.end, log: Self.signpostLog, name: "Seek",
                        signpostID: seekSignpostID)
        }
    }

    private func flushVideoDecoderAfterDiscontinuity() {
        videoToolboxDecoder.waitForAsynchronousFrames()
        videoToolboxDecoder.resetBackpressure()
        if let video = videoCodecCtx {
            avcodec_flush_buffers(video)
        }
    }

    private func performSeek(to target: Double) {
        // Drain packet queues BEFORE the demux barrier — otherwise a demux
        // loop blocked inside `PacketQueue.enqueue` on a full queue never
        // wakes up (markCancelled doesn't broadcast; only drain does).
        // Both subtitle slots drain because either can be full when the
        // demux loop is blocked inside their enqueue.
        wakeVideoToolboxDecodeWaiters()
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()

        // Wait for demux + feed workers to observe the cancel and exit.
        demuxQueue.sync {}
        videoFeedQueue.sync {}
        audioFeedQueue.sync {}

        guard !isDisposed, let formatCtx else { return }

        // Drain again to catch anything that squeaked through between the
        // first drain and the barriers returning.
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()
        flushVideoDecoderAfterDiscontinuity()
        // Tag the next sample buffer so VT drops its DPB state before
        // decoding. `WaitForAsynchronousFrames` above just drains pending
        // decodes — it doesn't invalidate reference frames. Without this
        // tag, the first packets of the new GOP try to resolve DPB
        // references against stale pre-seek frames → -8969 cascade.
        armDecoderReset()
        if let audio = audioCodecCtx {
            avcodec_flush_buffers(audio)
        }
        embeddedSubtitlePipeline.flushDecoders()
        // libass track keeps its parsed script + styles across seeks;
        // only the cached events need to clear so pre-seek cues don't
        // flicker after the seek lands.
        subtitleSession?.flushOnSeek()

        // Clear cancel before `avformat_seek_file` so the seek's internal
        // HTTP reads aren't aborted by the interrupt callback. The worker
        // barriers above already guaranteed the old loops exited, so no
        // stale reader will observe the clear.
        resetCancellation()
        // Re-stamp demux progress so the seek's I/O (and the first
        // post-seek `av_read_frame`) get a fresh `demuxIOTimeoutSeconds`
        // window. The stored wall reflects the last successful read, which
        // can be stale when queues were full at the time of the seek.
        demuxLastProgressWall = CACurrentMediaTime()

        // Gate the renderers so the keyframe-gap frames the backward-seek
        // drags in don't produce an audio-ahead-of-video offset (see
        // `pendingSkipBelowPTS` doc comment).
        pendingSkipBelowPTS = target
        skippedPreTargetVideoFrames = 0
        skippedPreTargetAudioFrames = 0
        shouldResyncClockOnFirstAudio = audioStreamIndex >= 0
        compressedVideoPipeline.resetDiagnostics()

        let result = seekFormatContext(formatCtx, to: target, logContext: "seek")
        if result < 0 {
            // Log but fall through to the workers-restart tail below:
            // even on seek failure we want demux running, otherwise a
            // subsequent `seek(to:)` would find no loop to replace.
            Self.logger.error("avformat_seek_file failed: \(result)")
        }
        demuxLastProgressWall = CACurrentMediaTime()

        // Superseded mid-seek: a newer target landed while we were inside
        // `avformat_seek_file`. Skip the renderer flush, worker restart, and
        // preroll — the worker loop immediately re-runs from this drained
        // state (queues empty, decoders flushed, workers not running), so
        // the burst pays the expensive tail once, for the final target.
        if seekLatch.hasPending {
            Self.logger.info("[CMP-SEEK] superseded after format seek target=\(target, privacy: .public); skipping restart tail")
            return
        }

        // Drain any decoded frames from before the seek so stale images don't
        // get enqueued once the display link resumes.
        videoFrameScheduler.removeAll(keepingCapacity: true)

        // Display layer + audio backend flush and playback clock reset must
        // run on main (those are main-thread objects). Synchronous so
        // the new timeline is in place before we restart the feeds.
        var restartRate: Float = 0
        var restartGeneration: UInt64 = 0
        let seekTime = CMTime(seconds: target, preferredTimescale: 600)
        DispatchQueue.main.sync {
            self.audioOutput.pause()
            self.setVideoDisplayTickPaused(true)
            self.displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
            self.audioOutput.flush()
            // Preserve the user's rate setting. If we were paused (rate==0),
            // the seek's new anchor should remain paused; if we were playing,
            // keep the user-requested `currentRate` (which may not be 1.0).
            let previousRate = self.playbackClock.rate
            let newRate: Float = previousRate == 0 ? 0 : self.currentRate
            restartRate = newRate
            self.playbackRestartGeneration &+= 1
            restartGeneration = self.playbackRestartGeneration
            self.setPlaybackTimeline(time: seekTime, rate: 0)
            self.audioOutput.setRate(self.currentRate)

            // Anchor the control timebase at the seek target. `timescale: 600`
            // must match the playback timeline above — any lower timescale truncates
            // fractional seconds and leaves the clocks misaligned post-seek.
            if let tb = self.controlTimebase {
                CMTimebaseSetTime(
                    tb,
                    time: seekTime
                )
                CMTimebaseSetRate(tb, rate: 1.0)
            }
            // Re-seed the audio clock so the first post-seek display tick
            // doesn't drop frames before the engine reports its first
            // rendered timestamp.
            self.updateAudioClock(to: seekTime)
            self.postDiscontinuityWallDeadline =
                CACurrentMediaTime() + Self.postDiscontinuityWindowSeconds
            self.decodedVideoFrameRenderer.reset()
            // Fresh ladder per discontinuity — the post-seek keyframe gap
            // must not inherit a half-escalated episode.
            self.avSyncLadder = AVSyncLadder()

            // Bypass the dedup guard — the scrubber must reflect the new
            // position even if `target` happens to match the last report.
            self.lastReportedSeconds = -1
            self.onTimeChange?(target)
        }

        // Extractor-fed subtitle slots re-seek their own context to the
        // new target (re-select is a fresh open + seek). Runs only on the
        // final seek of a scrub burst — superseded seeks returned above.
        runtimeSubtitleExtractor?.seek(to: target)

        // Restart demux + feeds from the seek point. Re-check disposal —
        // dispose() may have landed while we were blocked in
        // `avformat_seek_file` or the main.sync above, and restarting the
        // workers would resurrect a torn-down session. Re-check the latch
        // too: a target that arrived during the main.sync above makes this
        // restart pointless (the next worker iteration cancels + drains it
        // immediately), so skip straight to that iteration.
        guard !isDisposed else { return }
        if seekLatch.hasPending {
            Self.logger.info("[CMP-SEEK] superseded before restart target=\(target, privacy: .public); skipping worker restart")
            return
        }
        clearEndOfFileFlag()
        resetCancellation()
        startVideoFeed()
        startAudioFeed()
        startEmbeddedSubtitleFeeds()
        demuxQueue.async { [weak self] in
            self?.runDemuxLoop()
        }
        beginPlaybackAfterDiscontinuityWhenPrimed(
            initial: seekTime,
            rate: restartRate,
            deadline: CACurrentMediaTime() + Self.postDiscontinuityPrerollTimeoutSeconds,
            generation: restartGeneration,
            reason: "seek"
        )
    }

    func setHDREnabled(_ enabled: Bool) {
        let wasEnabled = hdrEnabled
        hdrEnabled = enabled
        Self.logger.info("setHDREnabled \(enabled)")
        // If a file is already loaded, push the new mode immediately. If not,
        // the next `load()` will pick up the stashed preference.
        guard formatCtx != nil else { return }
        #if os(iOS) || os(tvOS)
        // Re-signaling HDMI mode (tvOS) or EDR (iOS) mid-playback renegotiates
        // the display and is a common source of "the picture went black for a
        // second" reports, so the transition is worth an essential line. Only
        // an actual change though: `applySettingsToPlayer` re-pushes every
        // preference on each load, and the load-time breadcrumb already
        // reported the mode we started in.
        if enabled != wasEnabled {
            DiagTrace.breadcrumb(
                .essential,
                category: .playback,
                tag: "Player",
                message: "hdr output mode changed",
                attrs: [
                    "hdr_mode": .string(diagnosticsHDRMode()),
                    "sink": .string(diagnosticsVideoSink()),
                    "reason": .string(enabled ? "hdr_preference_enabled" : "hdr_preference_disabled"),
                ]
            )
        }
        #endif
        #if os(tvOS)
        let rate = refreshRate
        let contentFormat: TVDisplayCriteria.ContentFormat = enabled
            ? tvDisplayContentFormat
            : .sdr
        DispatchQueue.main.async {
            TVDisplayCriteria.apply(refreshRate: rate, contentFormat: contentFormat)
        }
        #else
        // iOS: re-publish sig peak so the hosting view can toggle EDR on the
        // display layer. Switching off drops peak to 0 (disables EDR).
        publishSigPeakIfNeeded()
        #endif
    }

    /// Recomputes `videoPresentationSize` from the current
    /// `videoFormatDescription` and notifies the hosting view on main when
    /// it changes. Called wherever `videoFormatDescription` is assigned or
    /// cleared.
    private func publishVideoPresentationSize() {
        let size: CGSize
        if let fd = videoFormatDescription {
            size = CMVideoFormatDescriptionGetPresentationDimensions(
                fd,
                usePixelAspectRatio: true,
                useCleanAperture: true
            )
        } else {
            size = .zero
        }
        // Compare-and-assign on main: `PlayerSurfaceHostView.attach` reads
        // the property from the UI thread, so keep it main-confined rather
        // than writing from the demux/control path.
        DispatchQueue.main.async { [weak self] in
            guard let self, size != self.videoPresentationSize else { return }
            self.videoPresentationSize = size
            self.onVideoPresentationSizeChange?(size)
        }
    }

    /// iOS/macOS HDR path: derives a sig peak from the current stream's
    /// dynamic range and the user's `hdrEnabled` preference, then fires
    /// `onSigPeakChange` so the hosting view can toggle
    /// `preferredDynamicRange` on the display layer. Called once
    /// per load (after dynamicRange is known) and whenever `setHDREnabled`
    /// changes the preference. No-op on tvOS — HDR is handled via
    /// AVDisplayManager there, not EDR.
    private func publishSigPeakIfNeeded() {
        #if os(iOS) || os(macOS)
        // 1.1 is a sentinel "HDR content present" value; the actual peak
        // nit target is handled by the OS when EDR is enabled. Real per-frame
        // MaxCLL propagation happens via the VT session's
        // `PropagatePerFrameHDRDisplayMetadata` flag.
        let peak: Double = (hdrEnabled && dynamicRange != .sdr) ? 1.1 : 0.0
        lastSigPeak = peak
        DispatchQueue.main.async { [weak self] in
            self?.onSigPeakChange?(peak)
        }
        #endif
    }

    #if os(tvOS)
    /// Preserves the Dolby Vision base-layer transfer for HDMI negotiation.
    /// Shares the compatibility-ID mapping with the route planner so the
    /// pre-decode and post-decode paths cannot disagree. Profile 8.2
    /// (compatibility ID 2) has an SDR base and falls in with the PQ default,
    /// as it did under the private API this replaced — that API requested DV
    /// mode with no transfer information at all.
    private var tvDisplayContentFormat: TVDisplayCriteria.ContentFormat {
        switch dynamicRange {
        case .sdr: return .sdr
        case .hdr10: return .hdr10
        case .hlg: return .hlg
        case .dolbyVision:
            return .dolbyVision(
                baseLayer: LoopbackSessionSpec.DVProfile8BaseLayer(
                    dolbyVisionCompatibilityID: doviConfig.map { Int($0.compatId) }
                )
            )
        }
    }
    #endif

    func dispose() {
        dispose(deferringFrees: true)
    }

    private func dispose(deferringFrees: Bool) {
        guard claimDisposed() else { return }
        Self.logger.info("PlayerCore.dispose()")

        markCancelled()
        // No further submits can race this: `seek(to:)` guards on
        // `isDisposed`, which `claimDisposed()` just set.
        seekLatch.abandon()
        wakeVideoToolboxDecodeWaiters()

        let disposedAt = currentPlaybackTime()
        setPlaybackTimeline(time: disposedAt, rate: 0)
        audioOutput.pause()

        // Stop PiP first so its playback-delegate callbacks don't land on a
        // half-torn-down core.
        if #available(iOS 15.0, tvOS 15.0, *),
           let pip = pipController as? AVPictureInPictureController,
           pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        pipController = nil

        // Unhook requestMediaDataWhenReady blocks (audio side only). Video
        // is push-mode via the CADisplayLink now — invalidate that on main
        // so the selector stops firing.
        audioOutput.stop()
        DispatchQueue.main.async { [weak self] in
            self?.invalidateVideoDisplayTicker()
        }

        DispatchQueue.main.async { [weak self] in
            self?.playbackTimeObserver?.invalidate()
            self?.playbackTimeObserver = nil
        }

        #if os(tvOS)
        TVDisplayCriteria.clear(context: "dispose")

        // Tear down the Profile-5 DV gate if it's still live. Observation and
        // timer hold strong refs to self via their closures; invalidating here
        // releases them before dispose returns.
        DispatchQueue.main.async { [weak self] in
            self?.dvGateTimeoutItem?.cancel()
            self?.dvGateTimeoutItem = nil
            self?.dvGateObservation?.invalidate()
            self?.dvGateObservation = nil
        }
        #endif

        // Drain any decoded frames held by the display-link queue; nobody
        // will consume them after dispose. Holding onto CVImageBuffers here
        // would keep VT output buffers pinned past teardown.
        videoFrameScheduler.removeAll()

        // Release the control timebase. The display layer (if still alive)
        // holds a strong reference via `controlTimebase`; nil-ing ours just
        // drops our ownership. The layer is torn down by the host view.
        controlTimebase = nil
        decodedVideoFrameRenderer.reset()

        // Kill the buffering watchdog.
        stopBufferingMonitor()
        stopDiagnostics()

        // CRITICAL: drain the packet queues BEFORE the demux barrier.
        //
        // Why: the demux loop can block inside `PacketQueue.enqueue(pkt)`
        // when a queue is at capacity, sitting on `cond.wait()` until a
        // consumer dequeues. `markCancelled()` alone doesn't wake it — the
        // wait only unblocks on a cond.broadcast, which happens on
        // dequeue/drain. If the feed closures have already exited (idle
        // renderer, or stopRequestingMediaData was just called), nobody
        // will dequeue. The demuxQueue.sync {} barrier then hangs forever
        // waiting for a demux loop that's waiting on a cond that nobody
        // will signal → freeze.
        //
        // drain() does that broadcast. The demux loop's enqueue returns,
        // the loop sees `!isCancelled` false, exits cleanly.
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()

        // Drain workers. The feed queues are where requestMediaDataWhenReady
        // closures execute; barriers on them guarantee no pending enqueue
        // survives into teardown. Subtitle decode runs on its own queue,
        // barrier it too so no pending packet survives.
        demuxQueue.sync {}
        videoFeedQueue.sync {}
        audioFeedQueue.sync {}
        embeddedSubtitlePipeline.waitForDecodeQueues()

        // Tear down FFmpeg + VT state.
        teardownMedia(deferFrees: deferringFrees)

        // Give up the audio session. Done last because `teardownMedia` can
        // still produce a final CoreAudio drain event; releasing the session
        // before that can (on older tvOS) generate an `AVAudioSessionErrorCode
        // CannotInterruptOthers` on the next client.
        deactivateAudioSession()

        // Drop all libass state + cancel any outstanding sidecar
        // fetches. The overlay view is cleared by the session teardown
        // because `SubtitleRenderer.dropAllTracks` causes the next
        // render to emit an empty image (or no image if nothing else
        // remains dirty) — but we still force a clear here so the
        // overlay doesn't briefly keep the last-rendered frame while
        // the next file loads.
        subtitleSession?.teardown()
        subtitleSession = nil
        DispatchQueue.main.async { [weak self] in
            self?.subtitleOverlay?.clear()
        }
    }

    /// Phase-3 hook for scene-phase → background transitions. `pause()` alone
    /// currently handles everything we need (halts audio output, video
    /// presentation, and decode work). Kept as a named entry point
    /// so future backgrounding cleanup (e.g. releasing VT session memory) has
    /// an obvious place to land.
    func prepareToBackground() {
        guard !isDisposed else { return }
        pause()
    }

    func currentTime() -> Double {
        currentPlaybackTimeSeconds()
    }

    func isPaused() -> Bool {
        playbackClock.rate == 0
    }

    // MARK: - Phase 2 API

    /// Playback rate multiplier. 1.0 is normal. Clamped to 0.5...3.0 — outside
    /// that range `AVAudioEngine` + `AVAudioUnitTimePitch` stops producing
    /// especially clean output on tvOS, so we keep the same clamp.
    func setSpeed(_ rate: Double) {
        guard !isDisposed else { return }
        let clamped = Float(min(max(rate, 0.5), 3.0))
        currentRate = clamped
        audioOutput.setRate(clamped)
        if playbackClock.rate != 0 {
            let now = currentPlaybackTime()
            setPlaybackTimeline(time: now, rate: clamped)
        }
        Self.logger.info("setSpeed(\(clamped))")
    }

    func setUserVolume(_ v: Float) {
        audioOutput.setUserVolume(v)
    }
    func setUserMuted(_ m: Bool) {
        audioOutput.setUserMuted(m)
    }
    var currentUserVolume: Float { audioOutput.currentUserVolume }
    var currentUserMuted: Bool { audioOutput.currentUserMuted }

    func setAudioDelay(_ seconds: Double) {
        // Nice-to-have; deferred from this Phase 2 pass. Needs per-frame PTS
        // offsets applied at audio enqueue time, with the cached delay
        // compared on every sample buffer.
        Self.logger.info("TODO Phase 2+: setAudioDelay(\(seconds))")
    }

    /// Apply a subtitle render-time offset. Positive seconds push cues
    /// *later*; negative pushes earlier. The offset applies to both
    /// primary and secondary slots; libass receives an adjusted `now`
    /// value on each render.
    func setSubtitleDelay(_ seconds: Double) {
        guard !isDisposed else { return }
        var params = subtitleSession?.currentParams ?? .default
        params.syncOffsetMs = Int((seconds * 1000.0).rounded())
        subtitleSession?.applyStyling(params)
        Self.logger.info("setSubtitleDelay \(seconds)s")
    }

    /// Apply an `AVLayerVideoGravity` to the display layer. Takes effect
    /// immediately; safe to call before or after `load(url:)`.
    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard !isDisposed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.displayLayer else { return }
            layer.videoGravity = gravity
        }
        Self.logger.info("setVideoGravity → \(gravity.rawValue)")
    }

    /// Apply user subtitle styling preferences. Forwarded to
    /// `SubtitleSession` which translates them into libass renderer
    /// overrides. Native ASS tracks (author-styled anime typesets)
    /// ignore most of these so creative intent survives — only vertical
    /// position and sync offset apply there.
    ///
    /// `backgroundColorAARRGGBB` is a hex string in
    /// `#AARRGGBB` form (alpha + RGB). Only the RGB portion and the
    /// alpha byte are used; the underlying background color + opacity
    /// percent are derived from them.
    func applySubtitleAppearance(_ appearance: SubtitleAppearance) {
        guard !isDisposed else { return }
        let syncOffset = subtitleSession?.currentParams.syncOffsetMs ?? 0
        let params = SubtitleStylingOverride.Parameters.from(
            appearance: appearance,
            syncOffsetMs: syncOffset
        )
        subtitleSession?.applyStyling(params)
    }

    /// Re-push the current styling params to the session. Used after a
    /// session is rebuilt on `load()`.
    private func applyCurrentSubtitleStyling() {
        subtitleSession?.applyStyling(subtitleSession?.currentParams ?? .default)
    }

    /// Select an audio track by `trackId` (which maps to the ffmpeg stream
    /// index in our Phase 2 track enumeration — see `buildTrackList`). Pass
    /// `nil` to disable audio entirely (rare; usually "no audio" means the
    /// file itself has none). Structurally mirrors `seek`: drain feeds,
    /// tear down the audio decoder, point at the new stream, rebuild
    /// decode state, flush, restart.
    func setAudioTrack(_ id: Int64?) {
        guard !isDisposed else { return }
        Self.logger.info("setAudioTrack(\(id ?? -1))")

        // A switch arriving while `openAndDemux` is mid-flight must not
        // `markCancelled()` — the interrupt callback would abort the open's
        // startTime seek mid-read and corrupt demuxer state. Park it;
        // `openAndDemux` applies it once the open completes.
        if deferAudioTrackSwitchIfLoading(id) {
            Self.logger.info("setAudioTrack(\(id ?? -1)) deferred until load completes")
            return
        }

        // Stop streaming before we start yanking state out from under the
        // feed closures.
        markCancelled()
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.performAudioTrackSwitch(newId: id)
        }
    }

    /// Select a subtitle track by id. An embedded-stream id is the raw
    /// FFmpeg stream index; a sidecar id is a synthesised value in the
    /// range managed by `SubtitleTrackIdSpace`. `nil` disables primary
    /// subtitles entirely. Dispatches the work onto `controlQueue` so
    /// track switching can barrier the subtitle decode loop without
    /// deadlocking main.
    func setSubtitleTrack(_ id: Int64?) {
        guard !isDisposed else { return }
        pendingSubtitleTrackId = id
        Self.logger.info("setSubtitleTrack(\(id ?? -1))")
        controlQueue.async { [weak self] in
            self?.performSubtitleTrackSwitch(newId: id, slot: .primary)
        }
    }

    /// Select a secondary subtitle track (shown alongside the primary).
    /// Same id semantics as `setSubtitleTrack`. Passing `nil` removes
    /// the secondary track without affecting the primary.
    func setSecondarySubtitleTrack(_ id: Int64?) {
        guard !isDisposed else { return }
        pendingSecondarySubtitleTrackId = id
        Self.logger.info("setSecondarySubtitleTrack(\(id ?? -1))")
        controlQueue.async { [weak self] in
            self?.performSubtitleTrackSwitch(newId: id, slot: .secondary)
        }
    }

    /// Register server-provided sidecar subtitle tracks. Called by the
    /// VM after the playback-start session resolves with a list of
    /// `subtitle_urls`. Synthesises `PlayerTrack` entries keyed by a
    /// collision-free id space and publishes them via
    /// `onSidecarTracksRegistered`; the VM appends them to the track
    /// picker.
    ///
    /// The actual fetch + parse is deferred until the user selects one
    /// of these tracks (lazy loading — only fetch what the user asks
    /// for). Forced sidecar tracks are an exception: if any are
    /// present, the VM may auto-select the first one.
    func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor]) {
        guard !isDisposed else { return }
        subtitleSession?.registerSidecarTracks(descriptors)
    }

    // MARK: - Live AI subtitle track

    /// Open a synthetic live AI subtitle track in the given slot. Cues are
    /// then streamed in via `feedLiveSubtitleCue`. Dispatches onto
    /// `controlQueue` so it serialises with subtitle track switching and
    /// the decode loop, matching every other subtitle-session mutation.
    func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?) {
        guard !isDisposed else { return }
        controlQueue.async { [weak self] in
            self?.subtitleSession?.openLive(slot: slot, label: label, language: language)
        }
    }

    /// Feed a single converted live AI cue to the live track in `slot`.
    /// `eventText`/`startMs`/`durationMs` come straight from
    /// `LiveSubtitleTrack`. Dispatched onto `controlQueue` for ordering.
    func feedLiveSubtitleCue(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        guard !isDisposed else { return }
        controlQueue.async { [weak self] in
            self?.subtitleSession?.feedLiveCue(
                slot: slot,
                eventText: eventText,
                startMs: startMs,
                durationMs: durationMs
            )
        }
    }

    /// Close the live AI subtitle track in `slot`. Dispatched onto
    /// `controlQueue` for ordering.
    func closeLiveSubtitleTrack(slot: SubtitleSlot) {
        guard !isDisposed else { return }
        controlQueue.async { [weak self] in
            self?.subtitleSession?.closeLive(slot: slot)
        }
    }

    /// Re-apply the current negotiated format to the audio engine after an
    /// output-route change.
    func reloadAudioOutput() {
        guard let audioFormat = audioOutputConfig?.audioFormat else { return }
        audioOutput.prepare(audioFormat: audioFormat)
        Self.logger.info("reloadAudioOutput(): re-prepared AVAudioEngine format")
        // Re-preparing the engine resets mixer volume to 1.0; restore the
        // user's volume/mute so a route/format change can't blow it away.
        audioOutput.applyUserGain()
    }

    // MARK: - Internal

    private func resetCancellation() {
        cancelLock.lock(); defer { cancelLock.unlock() }
        // dispose() relies on `_isCancelled` staying set so late-waking
        // workers exit. A seek racing dispose must not clear it.
        guard !_isDisposed else { return }
        _isCancelled = false
    }

    // MARK: - Track enumeration

    /// Walk `formatCtx.pointee.streams` and build the UI-facing track list.
    /// Fields populated: `trackId` (ffmpeg stream index, since CoreMedia has
    /// no per-kind id concept), `kind`, `codec`, `lang`, `title`, channel
    /// count (for audio), and the `isSelected` bit (which stream is live).
    ///
    /// Track switching uses `trackId` to find the new stream in the
    /// format context.
    private func buildTrackList() -> [PlayerTrack] {
        guard let formatCtx else { return [] }
        let nb = Int(formatCtx.pointee.nb_streams)
        let streams = formatCtx.pointee.streams
        var result: [PlayerTrack] = []
        result.reserveCapacity(nb)

        // Audio-relative ordinal (0 = first audio stream, 1 = second, …),
        // independent of the container stream index. This is the selection
        // identity the detail screen and the server's `0:a:%d` mapping speak,
        // so it goes into `srcId` — the same convention the loopback route
        // uses — while `ffIndex`/`trackId` keep the raw container index used to
        // drive the ffmpeg decoder. Without this, a selected audio ordinal was
        // matched against the container stream index and picked the wrong (or
        // no) track on the direct PlayerCore route.
        var audioTrackOrdinal = 0

        for i in 0..<nb {
            guard let stream = streams?[i] else { continue }
            guard let codecparPtr = stream.pointee.codecpar else { continue }
            let codecpar = codecparPtr.pointee
            let streamIndex = Int32(i)

            // Pull language + title out of the stream's metadata dict. Both
            // optional; `und` (undefined) is treated as absent.
            var title: String?
            var lang: String?
            if let meta = stream.pointee.metadata {
                if let entry = av_dict_get(meta, "language", nil, 0),
                   let cstr = entry.pointee.value {
                    let value = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, value.caseInsensitiveCompare("und") != .orderedSame {
                        lang = value
                    }
                }
                if let entry = av_dict_get(meta, "title", nil, 0),
                   let cstr = entry.pointee.value {
                    let value = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        title = value
                    }
                }
            }

            // Codec short-name via ffmpeg's descriptor table. Nil is fine —
            // the UI label logic in PlayerTrack.displayLabel handles absence.
            var codecName: String?
            if let descriptor = avcodec_descriptor_get(codecpar.codec_id),
               let namePtr = descriptor.pointee.name {
                codecName = String(cString: namePtr)
            }

            let disposition = Int32(stream.pointee.disposition)
            let isDefault = (disposition & AV_DISPOSITION_DEFAULT) != 0
            let isForced  = (disposition & AV_DISPOSITION_FORCED) != 0
            let isHearingImpaired = (disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0
            let isVisualImpaired = (disposition & AV_DISPOSITION_VISUAL_IMPAIRED) != 0

            let bitrate: Int64? = codecpar.bit_rate > 0 ? codecpar.bit_rate : nil

            switch codecpar.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                let channels = Int(codecpar.ch_layout.nb_channels)
                let layoutLabel = Self.channelLayoutLabel(channels)
                result.append(PlayerTrack(
                    trackId: Int64(streamIndex),
                    kind: .audio,
                    title: title,
                    lang: lang,
                    codec: codecName,
                    audioChannelsLayout: layoutLabel,
                    audioChannelCount: channels > 0 ? channels : nil,
                    bitrate: bitrate,
                    isDefault: isDefault,
                    isForced: isForced,
                    isHearingImpaired: isHearingImpaired,
                    isVisualImpaired: isVisualImpaired,
                    isExternal: false,
                    isSelected: streamIndex == audioStreamIndex,
                    ffIndex: Int(streamIndex),
                    srcId: audioTrackOrdinal
                ))
                audioTrackOrdinal += 1

            case AVMEDIA_TYPE_SUBTITLE:
                result.append(PlayerTrack(
                    trackId: Int64(streamIndex),
                    kind: .sub,
                    title: title,
                    lang: lang,
                    codec: codecName,
                    audioChannelsLayout: nil,
                    audioChannelCount: nil,
                    bitrate: bitrate,
                    isDefault: isDefault,
                    isForced: isForced,
                    isHearingImpaired: isHearingImpaired,
                    isVisualImpaired: isVisualImpaired,
                    isExternal: false,
                    // Phase 3: subtitle rendering is live. The selected stream
                    // is whichever decoder we've opened.
                    isSelected: streamIndex == selectedEmbeddedSubtitleStreamIndex(slot: .primary),
                    ffIndex: Int(streamIndex),
                    srcId: nil
                ))

            case AVMEDIA_TYPE_VIDEO:
                result.append(PlayerTrack(
                    trackId: Int64(streamIndex),
                    kind: .video,
                    title: title,
                    lang: lang,
                    codec: codecName,
                    audioChannelsLayout: nil,
                    audioChannelCount: nil,
                    bitrate: bitrate,
                    isDefault: isDefault,
                    isForced: isForced,
                    isHearingImpaired: false,
                    isVisualImpaired: false,
                    isExternal: false,
                    isSelected: streamIndex == videoStreamIndex,
                    ffIndex: Int(streamIndex),
                    srcId: nil
                ))

            default:
                break
            }
        }
        return result
    }

    /// Human-readable channel layout for common counts. Falls back to a
    /// numeric label for exotic configs.
    private static func channelLayoutLabel(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count)ch"
        }
    }

    // MARK: - Audio track switching

    /// Runs on `controlQueue`. Structural twin of `performSeek`: drain the
    /// demux + feed workers, free the currently-open audio codec, point at
    /// the new stream index, rebuild the decoder, flush the renderer, and
    /// restart the workers from the current time.
    private func performAudioTrackSwitch(newId: Int64?) {
        // Drain packet queues BEFORE the demux barrier to wake any demux
        // thread blocked inside a full-queue enqueue (markCancelled alone
        // doesn't broadcast on the condition variable). Both subtitle
        // slots drain because either can be the one the demux is
        // blocked on when the secondary track is active.
        wakeVideoToolboxDecodeWaiters()
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()

        // Wait for demux + feed workers to observe the cancel and exit.
        demuxQueue.sync {}
        videoFeedQueue.sync {}
        audioFeedQueue.sync {}

        // Stop the audio renderer from re-invoking `requestMediaDataWhenReady`
        // against our workers while we're tearing down codec state. The
        // feed-queue barrier above waits for the currently-queued closure
        // but does NOT prevent the renderer from queueing a new one — only
        // `stopRequestingMediaData()` does that. `startAudioFeed` below
        // re-registers it.
        //
        // For video: pause the display link so the push path stops emitting
        // frames while we rebuild the audio decoder. The preroll gate below
        // flips it back on once post-switch audio and video are both ready.
        // The video feed queue is now a decode-only loop that exits when it
        // sees `isCancelled`.
        audioOutput.stopRequestingMediaData()
        DispatchQueue.main.async { [weak self] in
            self?.setVideoDisplayTickPaused(true)
        }

        guard !isDisposed, let formatCtx else { return }

        // Resolve the new audio stream index. `nil` means "disable audio".
        var newStreamIndex: Int32 = -1
        if let newId {
            let candidate = Int32(newId)
            if candidate >= 0, candidate < Int32(formatCtx.pointee.nb_streams) {
                if let stream = formatCtx.pointee.streams?[Int(candidate)],
                   let codecparPtr = stream.pointee.codecpar,
                   codecparPtr.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                    newStreamIndex = candidate
                } else {
                    Self.logger.warning("setAudioTrack: id=\(candidate) isn't an audio stream")
                }
            }
        }

        // Toss queued packets, drain in-flight frames, flush codecs.
        videoPacketQueue.drain()
        audioPacketQueue.drain()
        flushVideoDecoderAfterDiscontinuity()
        // Same reset tag as performSeek: track switch restarts video
        // feed from the current position, so VT's DPB state is stale
        // relative to the re-fed packets.
        armDecoderReset()
        compressedVideoPipeline.resetDiagnostics()
        if let audio = audioCodecCtx {
            avcodec_flush_buffers(audio)
        }

        // Tear down the current audio codec / resampler unconditionally —
        // even if the caller is just disabling audio, we want clean state.
        if audioCodecCtx != nil {
            avcodec_free_context(&audioCodecCtx)
        }
        if audioSwrCtx != nil {
            swr_free(&audioSwrCtx)
        }
        audioOutputConfig = nil
        audioStreamIndex = newStreamIndex

        // Rebuild audio decode state for the new stream (if any). If this
        // fails (unsupported codec, etc.), we degrade to video-only.
        if newStreamIndex >= 0 {
            if let stream = formatCtx.pointee.streams?[Int(newStreamIndex)] {
                audioTimeBase = stream.pointee.time_base
            }
            if !setupAudioDecoder() {
                Self.logger.warning("setAudioTrack: decoder setup failed; disabling audio")
                audioStreamIndex = -1
            }
        }
        #if os(iOS) || os(tvOS)
        // Only the degraded outcomes are recorded. A switch that lands on the
        // requested stream is already covered by the "audio output negotiated"
        // breadcrumb the rebuilt decoder emits on its first frame; recording
        // the happy path here as well would double every track change.
        if newId != nil, audioStreamIndex < 0 {
            DiagTrace.breadcrumb(
                .essential,
                level: .warning,
                category: .playback,
                tag: "Player",
                message: "audio track switch degraded to silent",
                attrs: [
                    "reason": .string(
                        newStreamIndex < 0 ? "track_not_an_audio_stream" : "audio_decoder_setup_failed"
                    ),
                    "position_ms": .int(Self.positionMilliseconds(currentPlaybackTimeSeconds())),
                ]
            )
        }
        #endif
        // The audio timebase (and frame duration) may have changed.
        configurePacketQueueTiming()

        // The playback clock may not have been primed yet when a track switch
        // races `openAndDemux` (e.g. a persisted or detail-page audio
        // selection applied during load), in which case it reads ~0.
        // `pendingSkipBelowPTS` holds the last requested anchor (load
        // startTime or seek target); never resume behind it, or an early
        // switch silently rewinds playback to the start of the file.
        let resumeSeconds = max(0, currentPlaybackTimeSeconds(), pendingSkipBelowPTS)
        pendingSkipBelowPTS = resumeSeconds
        skippedPreTargetVideoFrames = 0
        skippedPreTargetAudioFrames = 0
        shouldResyncClockOnFirstAudio = audioStreamIndex >= 0
        let seekR = seekFormatContext(formatCtx, to: resumeSeconds, logContext: "audio-track-switch")
        if seekR < 0 {
            Self.logger.error("setAudioTrack: seek failed after stream switch result=\(seekR)")
        }

        // Drop stale decoded frames so the post-switch display link doesn't
        // flash pre-seek content between the flush and the new packets
        // arriving.
        videoFrameScheduler.removeAll(keepingCapacity: true)

        var restartRate: Float = 0
        var restartGeneration: UInt64 = 0
        let resumeTime = CMTime(seconds: resumeSeconds, preferredTimescale: 600)
        DispatchQueue.main.sync {
            self.audioOutput.pause()
            self.setVideoDisplayTickPaused(true)
            self.displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
            self.audioOutput.flush()
            let previousRate = self.playbackClock.rate
            let newRate: Float = previousRate == 0 ? 0 : self.currentRate
            restartRate = newRate
            self.playbackRestartGeneration &+= 1
            restartGeneration = self.playbackRestartGeneration
            self.setPlaybackTimeline(time: resumeTime, rate: 0)
            self.audioOutput.setRate(self.currentRate)

            // Video control timebase follows the new position. Rate stays 1.0.
            if let tb = self.controlTimebase {
                CMTimebaseSetTime(
                    tb,
                    time: resumeTime
                )
                CMTimebaseSetRate(tb, rate: 1.0)
            }
            self.updateAudioClock(to: resumeTime)
            self.postDiscontinuityWallDeadline =
                CACurrentMediaTime() + Self.postDiscontinuityWindowSeconds
            self.decodedVideoFrameRenderer.reset()
            // Fresh ladder per discontinuity — the post-seek keyframe gap
            // must not inherit a half-escalated episode.
            self.avSyncLadder = AVSyncLadder()
        }

        // Refresh the track list so the UI's "selected" indicator matches.
        let updated = buildTrackList()
        currentTracks = updated
        DispatchQueue.main.async { [weak self] in
            self?.onTracksChange?(updated)
        }

        // Restart demux + feeds.
        clearEndOfFileFlag()
        resetCancellation()
        startVideoFeed(resumeDisplayLink: false)
        startAudioFeed()
        startEmbeddedSubtitleFeeds()
        demuxQueue.async { [weak self] in
            self?.runDemuxLoop()
        }
        beginPlaybackAfterDiscontinuityWhenPrimed(
            initial: resumeTime,
            rate: restartRate,
            deadline: CACurrentMediaTime() + Self.postDiscontinuityPrerollTimeoutSeconds,
            generation: restartGeneration,
            reason: "audioTrack"
        )
    }

    // MARK: - Buffering monitor

    /// Heuristic: we're buffering when the video packet queue has fallen
    /// below 10% of capacity AND the audio renderer is starved. That
    /// combination reliably separates "we're paused / user-initiated" from
    /// "network is the bottleneck". 100ms poll is cheap. Main-thread Timer
    /// is fine; `Timer.scheduledTimer` attaches to the current runloop.
    private func startBufferingMonitor() {
        // Belt + suspenders: tear down any prior timer, then install fresh
        // on main. If we're off-main (we are — this is called from `load`
        // which runs on the demux queue's async context via `self`), hop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bufferingTimer?.invalidate()
            // Fresh policy per monitored session: a reloaded core must not
            // inherit the previous file's buffering state. Main-only, like
            // every other touch of these two.
            self.bufferingPolicy = BufferingPolicy()
            self.lastReportedBufferingProgress = -1
            self.bufferingTimer = Timer.scheduledTimer(
                withTimeInterval: 0.1, repeats: true
            ) { [weak self] _ in
                self?.sampleBufferingState()
            }
        }
    }

    private func stopBufferingMonitor() {
        // bufferingTimer is only ever touched on main (startBufferingMonitor
        // writes it from a main-async block). Reading/writing from any other
        // thread is a data race AND loses any pending assignment queued by
        // startBufferingMonitor that hasn't been served yet. Always hop to
        // main so we see the authoritative value.
        DispatchQueue.main.async { [weak self] in
            self?.bufferingTimer?.invalidate()
            self?.bufferingTimer = nil
        }
    }

    // MARK: - Slow-motion-debug diagnostics (temporary)

    /// Start a 1Hz diagnostics timer that emits a single-line snapshot
    /// covering sync time vs wall time, audio clock, queue depths, and
    /// display-link / audio-renderer readiness. Uses `cmpLog` so the line
    /// reaches `devicectl ... --console` and the diagnostics ring.
    private func startDiagnostics() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.diagnosticsTimer?.invalidate()
            self.diagStartWall = CACurrentMediaTime()
            self.diagStartSyncTime = self.currentPlaybackTimeSeconds()
            self.lastDiagEnqueueCount = 0
            self.lastDiagAudioEnqueueCount = 0
            self.vSyncHolds = 0
            self.vSyncDrops = 0
            cmpLog(String(format:
                "[CMP] startDiagnostics wallStart=%.3f syncStart=%.3f rate=%.2f videoFPS=%.2f refreshRate=%.2f",
                self.diagStartWall, self.diagStartSyncTime,
                Double(self.playbackClock.rate), self.videoFPS, Double(self.refreshRate)))
            self.diagnosticsTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0, repeats: true
            ) { [weak self] _ in
                self?.logDiagnosticSnapshot()
            }
        }
    }

    private func stopDiagnostics() {
        DispatchQueue.main.async { [weak self] in
            self?.diagnosticsTimer?.invalidate()
            self?.diagnosticsTimer = nil
        }
    }

    /// One line of diagnostic state, snapshotted on main at 1Hz. Fields:
    ///   wall     wall-clock seconds since diagnostics started
    ///   sync     currentPlaybackTimeSeconds() (absolute)
    ///   adv      playback advance since diagnostics started (should ≈ wall at 1x)
    ///   ratio    adv/wall — <1 means playback is running slow
    ///   rate     playbackRate (should be 1.0 during normal playback)
    ///   ac.pts   audioClock.pts (last sync-observer sample)
    ///   ac.cur   audioClock.current() — extrapolated master clock
    ///   vidEnq   video frames enqueued in the last second
    ///   aEnq     audio sample buffers enqueued in the last second
    ///   holds    cumulative "held (too early)" tick count since diag start
    ///   drops    cumulative "dropped (too late)" frame count
    ///   vDec     decoded-video frame queue depth (0..8)
    ///   vtIn     VideoToolbox decode submissions in flight
    ///   vPkts    video packet queue depth (0..240)
    ///   aPkts    audio packet queue depth (0..480)
    ///   layerRdy displayLayer.isReadyForMoreMediaData
    ///   layerSt  displayLayer.status raw value (0=unknown, 1=rendering, 2=failed)
    ///   audRdy   audio output has room for more PCM
    ///   rd       demuxReadCount: av_read_frame entries since open
    ///   rt       demuxReturnCount: av_read_frame returns since open
    ///             (rd > rt → currently blocked inside FFmpeg I/O)
    ///   idle     seconds since last successful av_read_frame return
    private func logDiagnosticSnapshot() {
        let now = CACurrentMediaTime()
        let wall = now - diagStartWall
        let syncTime = currentPlaybackTimeSeconds()
        let syncAdvance = syncTime - diagStartSyncTime
        let syncRate = playbackClock.rate
        let ratio = wall > 0.1 ? syncAdvance / wall : 0
        let audioSnapshot = audioClockSnapshot()
        let audioPts = audioSnapshot.pts
        let audioCurrent = audioSnapshot.current
        let displayLinkEnqueueCount = decodedVideoFrameRenderer.enqueueCount
        let enqDelta = displayLinkEnqueueCount &- lastDiagEnqueueCount
        lastDiagEnqueueCount = displayLinkEnqueueCount
        let audioEnqDelta = audioEnqueueCount &- lastDiagAudioEnqueueCount
        lastDiagAudioEnqueueCount = audioEnqueueCount
        let vDec = videoFrameScheduler.count
        let vPkts = videoPacketQueue.count
        let aPkts = audioPacketQueue.count
        let vtInFlight = videoToolboxInFlightCount()
        let layerReady = displayLayer?.sampleBufferRenderer.isReadyForMoreMediaData ?? false
        let layerStatus = displayLayer?.sampleBufferRenderer.status.rawValue ?? -1
        let audioReady = audioOutput.isReadyForMoreMediaData
        let audioStatus = audioOutput.statusCode
        if audioStatus != lastAudioRendererStatus {
            let err = audioOutput.lastErrorDescription ?? "nil"
            cmpLog("[CMP] audioOutput.status \(lastAudioRendererStatus) -> \(audioStatus) error=\(err)")
            lastAudioRendererStatus = audioStatus
        }
        let demuxIdle = now - demuxLastProgressWall
        let health = playbackHealthStats()
        let bufferedAhead = bufferedSecondsEstimate() ?? -1
        cmpLog(String(format:
            "[CMP-DIAG] wall=%.2f sync=%.3f adv=%.3f ratio=%.3f rate=%.2f ac.pts=%.3f ac.cur=%.3f vidEnq=+%llu aEnq=+%llu holds=%llu drops=%llu vDec=%d vtIn=%d vPkts=%d aPkts=%d layerRdy=%d layerSt=%d audRdy=%d audSt=%d audFeed=%llu rd=%llu rt=%llu idle=%.2f bufS=%.2f rebuf=%d seeks=%llu coal=%llu ladder=%llu/%llu/%llu",
            wall, syncTime, syncAdvance, ratio, Double(syncRate),
            audioPts, audioCurrent,
            enqDelta, audioEnqDelta, vSyncHolds, vSyncDrops,
            vDec, vtInFlight, vPkts, aPkts,
            layerReady ? 1 : 0, layerStatus, audioReady ? 1 : 0,
            audioStatus, audioFeedInvocations,
            demuxReadCount, demuxReturnCount, demuxIdle,
            bufferedAhead, health.rebufferCount, health.seekCount,
            health.coalescedSeekCount, health.avsyncFlushCount,
            health.avsyncGopDropCount, health.avsyncReseekCount),
            verbose: true)
        emitPlaybackStatsSnapshot(
            syncRate: Double(syncRate),
            videoFramesEnqueued: displayLinkEnqueueCount,
            droppedFrames: vSyncDrops + totalVtFrameDrops,
            decodedVideoDepth: vDec,
            videoPacketDepth: vPkts,
            audioPacketDepth: aPkts
        )

        // Stall-recovery watchdog. Two independent failure modes recovered
        // here because neither recovers from the normal code paths:
        //   1. playbackRate drops to 0 from outside our `pause()` —
        //      typically an audio-route swap or backend interruption. The
        //      renderer stops requesting data, the display link
        //      stops getting new PTS targets, and playback freezes.
        //   2. `displayLayer.status == .failed` after extended idleness —
        //      tvOS times the layer out if no sample buffer arrives within
        //      a few seconds. The existing in-enqueue recovery (search
        //      `layer.status == .failed; flushing`) only fires when we're
        //      actively enqueuing, so it never reaches us if rate=0.
        //
        // Rate-limited to one recovery per second so a genuinely stuck
        // renderer doesn't spin this loop.
        let canRecover = !isDisposed && !isCancelled && !userPaused
            && now - lastStallRecoveryWall >= 1.0
        if canRecover {
            var didRecover = false
            if let layer = displayLayer, layer.sampleBufferRenderer.status == .failed {
                recoverDisplayLayerIfFailed(reason: "stall-recover")
                didRecover = true
            }
            if syncRate == 0 {
                cmpLog(String(format:
                    "[CMP] stall-recover: playbackRate=0 (userPaused=false); restoring rate=%.2f",
                    Double(currentRate)))
                let resumeTime = currentPlaybackTime()
                setPlaybackTimeline(time: resumeTime, rate: currentRate)
                audioOutput.setRate(currentRate)
                audioOutput.play()
                didRecover = true
            }
            if syncRate != 0,
               audioStreamIndex >= 0,
               audioReady,
               aPkts > 0,
               audioEnqDelta == 0,
               demuxIdle > 2.0 {
                cmpLog(String(format:
                    "[CMP] stall-recover: audio feed idle while ready (aPkts=%d idle=%.2f); nudging feed",
                    aPkts, demuxIdle))
                audioOutput.nudgeRequestMediaDataWhenReady()
                didRecover = true
            }
            if didRecover {
                lastStallRecoveryWall = now
            }
        }
    }

    private func emitPlaybackStatsSnapshot(
        syncRate: Double,
        videoFramesEnqueued: UInt64,
        droppedFrames: UInt64,
        decodedVideoDepth: Int,
        videoPacketDepth: Int,
        audioPacketDepth: Int
    ) {
        var stats = PlaybackStats()
        stats.route = "Compatibility Playback"
        stats.source = lastLoadURL?.host ?? lastLoadURL?.scheme
        stats.container = formatContainerName()
        stats.createdBy = formatMetadataValue(keys: ["encoder", "writing_application", "creation_time"])
        stats.video = currentVideoStats()
        stats.audio = currentAudioStats()
        stats.dynamicRange = currentDynamicRangeStatsLabel()
        stats.confirmedDynamicRange = confirmedDynamicRangeForStats()
        stats.subtitles = currentSubtitleStats()
        stats.screenFrameRate = PlatformScreen.maximumFramesPerSecond
        stats.playbackRate = syncRate
        stats.bufferStatus = bufferingState ? "Buffering" : "Healthy"
        stats.bufferedAheadSeconds = bufferedSecondsEstimate()
        let health = playbackHealthStats()
        stats.bufferLoadCount = health.rebufferCount
        stats.seekCount = health.seekCount
        stats.coalescedSeekCount = health.coalescedSeekCount
        stats.lastSeekLatencySeconds = health.lastSeekToFirstFrameSeconds
        stats.avsyncRecoveryCount = health.avsyncFlushCount
            &+ health.avsyncGopDropCount
            &+ health.avsyncReseekCount
        stats.displayedVideoFrames = videoFramesEnqueued
        stats.droppedVideoFrames = droppedFrames
        stats.videoQueueDepth = videoPacketDepth
        stats.decodedVideoQueueDepth = decodedVideoDepth
        stats.audioQueueDepth = audioPacketDepth
        stats.deviceInfo = Self.deviceInfo()
        stats.freeDiskSpaceBytes = Self.freeDiskSpaceBytes()
        onPlaybackStatsChange?(stats)
    }

    private func formatContainerName() -> String? {
        guard let name = formatCtx?.pointee.iformat?.pointee.name else { return nil }
        let value = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func formatMetadataValue(keys: [String]) -> String? {
        guard let metadata = formatCtx?.pointee.metadata else { return nil }
        for key in keys {
            if let entry = av_dict_get(metadata, key, nil, 0),
               let value = entry.pointee.value {
                let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private func currentVideoStats() -> PlaybackStats.MediaStream {
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecparPtr = stream.pointee.codecpar else {
            return .init()
        }
        let codecpar = codecparPtr.pointee
        return PlaybackStats.MediaStream(
            codec: Self.codecName(for: codecpar.codec_id),
            detail: "\(codecpar.width)x\(codecpar.height), \(String(format: "%.2f", Double(refreshRate))) fps",
            bitrateBps: codecpar.bit_rate > 0 ? Double(codecpar.bit_rate) : nil
        )
    }

    private func currentAudioStats() -> PlaybackStats.MediaStream {
        guard let formatCtx,
              audioStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(audioStreamIndex)],
              let codecparPtr = stream.pointee.codecpar else {
            return .init()
        }
        let codecpar = codecparPtr.pointee
        let channels = Int(codecpar.ch_layout.nb_channels)
        let sampleRate = codecpar.sample_rate > 0 ? "\(codecpar.sample_rate) Hz" : nil
        var detailParts: [String] = []
        if let layout = Self.channelLayoutLabel(channels) {
            detailParts.append(layout)
        }
        if let sampleRate {
            detailParts.append(sampleRate)
        }
        if selectedAudioTrackHasAtmosHint() {
            detailParts.append("Atmos")
        }
        return PlaybackStats.MediaStream(
            codec: Self.codecName(for: codecpar.codec_id),
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: ", "),
            bitrateBps: codecpar.bit_rate > 0 ? Double(codecpar.bit_rate) : nil
        )
    }

    /// What this decoder is rendering, for the HUD badge. `dynamicRange` is
    /// set from the resolved routing, so a Dolby Vision source the user's
    /// settings stripped to its base layer reports `.hdr10` here even though
    /// the prose label below still names the source's DV profile.
    private func confirmedDynamicRangeForStats() -> PlaybackStats.ConfirmedDynamicRange {
        switch dynamicRange {
        case .sdr: return .sdr
        case .hdr10: return .hdr10
        case .hlg: return .hlg
        case .dolbyVision: return .dolbyVision
        }
    }

    private func currentDynamicRangeStatsLabel() -> String? {
        if let doviConfig {
            var label = "Dolby Vision Profile \(Int(doviConfig.profile))"
            if doviConfig.level > 0 {
                label += " Level \(Int(doviConfig.level))"
            }
            if let compatibility = Self.dolbyVisionCompatibilityLabel(doviConfig.compatId) {
                label += " (\(compatibility))"
            }
            switch dynamicRange {
            case .hdr10:
                label += " as HDR10"
            case .hlg:
                label += " as HLG"
            case .sdr:
                label += " as SDR"
            case .dolbyVision:
                break
            }
            return label
        }

        switch dynamicRange {
        case .sdr:
            return nil
        case .hdr10:
            return "HDR10"
        case .hlg:
            return "HLG"
        case .dolbyVision:
            return "Dolby Vision"
        }
    }

    #if os(iOS) || os(tvOS)
    // MARK: - Diagnostics attributes

    /// The resolved video pipeline as registered `playback` attributes.
    /// Shared by the load-time breadcrumb and the decoder-fallback one so a
    /// report can compare "what we chose" against "what we fell back to"
    /// field by field instead of diffing two differently-shaped log lines.
    /// Reads FFmpeg stream state, so callers must already be on a queue where
    /// touching `formatCtx` is safe (demux/control).
    private func videoPipelineAttributes() -> [String: DiagLogAttributeValue] {
        var attrs: [String: DiagLogAttributeValue] = [
            "decoder": .string(videoDecodeMode == .software ? "software" : "videotoolbox"),
            "hdr_mode": .string(diagnosticsHDRMode()),
            "sink": .string(diagnosticsVideoSink()),
        ]
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecparPtr = stream.pointee.codecpar else {
            return attrs
        }
        let codecpar = codecparPtr.pointee
        attrs["fmt"] = .string(Self.codecName(for: codecpar.codec_id) ?? "unknown")
        if codecpar.width > 0, codecpar.height > 0 {
            attrs["width"] = .int(Int(codecpar.width))
            attrs["height"] = .int(Int(codecpar.height))
        }
        if codecpar.bit_rate > 0 {
            attrs["bitrate_kbps"] = .int(Int(codecpar.bit_rate / 1000))
        }
        return attrs
    }

    /// What the pipeline resolved to render, not what the source is tagged
    /// as: a Dolby Vision stream the user's policy stripped to its base layer
    /// reports the base layer, and the HDR preference being off reports
    /// `sdr_forced` rather than hiding the fact that HDR was available.
    private func diagnosticsHDRMode() -> String {
        guard hdrEnabled else { return dynamicRange == .sdr ? "sdr" : "sdr_forced" }
        switch dynamicRange {
        case .sdr: return "sdr"
        case .hdr10: return "hdr10"
        case .hlg: return "hlg"
        case .dolbyVision: return "dolby_vision"
        }
    }

    /// Where decoded video is being presented. Fixed per platform today, but
    /// named as an attribute so a report distinguishes a tvOS HDMI session
    /// from an iOS EDR one without inferring it from the device snapshot.
    private func diagnosticsVideoSink() -> String {
        #if os(tvOS)
        return "avsamplebufferdisplaylayer_hdmi"
        #else
        return "avsamplebufferdisplaylayer_edr"
        #endif
    }
    #endif

    private func selectedAudioTrackHasAtmosHint() -> Bool {
        guard audioStreamIndex >= 0,
              let track = currentTracks.first(where: { $0.kind == .audio && $0.ffIndex == Int(audioStreamIndex) }) else {
            return false
        }
        return Self.containsAtmosHint(track.title) || Self.containsAtmosHint(track.codec)
    }

    /// Embedded subtitle stream selected in `slot`, regardless of which
    /// mechanism feeds it: the in-band pipeline (selections made during
    /// open) or the runtime extractor (mid-playback switches). -1 = none.
    private func selectedEmbeddedSubtitleStreamIndex(slot: SubtitleSlot) -> Int32 {
        let pipelineIndex = embeddedSubtitlePipeline.streamIndex(for: slot)
        if pipelineIndex >= 0 { return pipelineIndex }
        return runtimeSubtitleExtractor?.selectedStreamIndex(for: slot) ?? -1
    }

    private func currentSubtitleStats() -> String? {
        let subtitleStreamIndex = selectedEmbeddedSubtitleStreamIndex(slot: .primary)
        guard subtitleStreamIndex >= 0 else { return "Off" }
        if let track = currentTracks.first(where: { $0.kind == .sub && $0.trackId == Int64(subtitleStreamIndex) }) {
            return track.title ?? track.lang ?? track.codec ?? "On"
        }
        return "On"
    }

    private func bufferedSecondsEstimate() -> Double? {
        // Min across active tracks — matches what the buffering policy
        // considers the binding constraint.
        var tracked: [Double] = []
        if videoStreamIndex >= 0 {
            tracked.append(videoPacketQueue.bufferedSeconds + decodedVideoSecondsEstimate())
        }
        if audioStreamIndex >= 0 {
            tracked.append(audioPacketQueue.bufferedSeconds + max(0, audioOutput.bufferedDurationSeconds))
        }
        return tracked.min()
    }

    private static func codecName(for codecID: AVCodecID) -> String? {
        if let descriptor = avcodec_descriptor_get(codecID),
           let name = descriptor.pointee.name {
            return String(cString: name)
        }
        let rawName = String(cString: avcodec_get_name(codecID)).trimmingCharacters(in: .whitespacesAndNewlines)
        return rawName.isEmpty ? nil : rawName
    }

    private static func dolbyVisionCompatibilityLabel(_ compatibilityID: UInt8) -> String? {
        switch compatibilityID {
        case 1: return "HDR10 compatible"
        case 2: return "SDR compatible"
        case 4: return "HLG compatible"
        default: return nil
        }
    }

    private static func containsAtmosHint(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value.contains("atmos") || value.contains("joc")
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

    /// Called from the buffering watchdog timer (main, 100 ms). Samples
    /// buffered *seconds* per track, runs the hysteresis policy, flips the
    /// `bufferingState` bit on transitions, and fires `onBufferingChange`
    /// only on state change. While buffering, also reports fill progress
    /// toward the leave threshold via `onBufferingProgress`.
    private func sampleBufferingState() {
        guard !isDisposed else { return }

        // Seek-stall watchdog. A worker iteration wedged inside FFmpeg I/O
        // (observed: TLS read that ignores both the interrupt callback and
        // rw_timeout during `avformat_seek_file`) freezes the pipeline and
        // holds the seek latch, silently swallowing every further seek.
        // There is no way to unblock the thread from here, so escalate: set
        // cancel (in case FFmpeg ever polls again) and surface the error —
        // the VM's recovery chain rebuilds the session on a fresh engine,
        // and this core's `isDisposed` guards neutralize the stuck worker
        // if it ever returns. Checked before the rate guard so a stalled
        // seek-while-paused is caught too.
        if let age = claimSeekStall() {
            print(String(format:
                "[CMP] seek watchdog: worker iteration stalled for %.1fs (ffmpeg I/O wedged); surfacing error",
                age))
            markCancelled()
            reportError("Seek stalled: stream I/O did not complete")
            return
        }

        // While paused, buffering is nonsense — the user is the reason we're
        // not moving, not the network.
        if playbackClock.rate == 0 { return }

        // Video seconds = compressed backlog + decoded frames. Decoded
        // frames count on purpose: they're media the user will see, and the
        // policy's enter threshold should reflect true starvation. A starved
        // *decoded* queue with a full packet queue is a decoder problem, not
        // a network one — that case belongs to the VT failure counters and
        // the A/V-sync ladder, not the spinner.
        let videoSeconds: Double? = videoStreamIndex >= 0
            ? videoPacketQueue.bufferedSeconds + decodedVideoSecondsEstimate()
            : nil
        let audioSeconds: Double? = audioStreamIndex >= 0
            ? audioPacketQueue.bufferedSeconds + max(0, audioOutput.bufferedDurationSeconds)
            : nil
        let sample = BufferingPolicy.Sample(
            videoBufferedSeconds: videoSeconds,
            audioBufferedSeconds: audioSeconds,
            audioRendererHungry: audioStreamIndex >= 0
                ? audioOutput.isReadyForMoreMediaData
                : nil,
            isPlaying: true,
            reachedInputEOF: endOfFileCoordinator.hasReachedInputEndOfFile(),
            withinPostSeekWindow: secondsSinceLastSeek() < Self.postSeekFastResumeWindowSeconds
        )
        let newState = bufferingPolicy.evaluate(sample)

        if newState != bufferingState {
            bufferingState = newState
            if #available(iOS 15.0, tvOS 15.0, *) {
                os_signpost(.event, log: Self.signpostLog, name: "Buffering",
                            "state=%{public}@", newState ? "underrun" : "ok")
            }
            // Which track ran dry decides whether this reads as a network
            // stall or an audio underrun. Computed before the tally update so
            // the two agree about what this edge was.
            let cause = Self.stallCause(
                videoBufferedSeconds: videoSeconds,
                audioBufferedSeconds: audioSeconds
            )
            noteBufferingTransition(
                newState,
                audioStarved: newState && cause == "audio_starved"
            )
            #if os(iOS) || os(tvOS)
            // Rebuffer edges are the single highest-value playback signal a
            // crash bundle can carry and they are rare (a healthy playback
            // emits none), so they are essential-tier. The 1 Hz [CMP-DIAG]
            // line already carries the running counters for anyone with Debug
            // Logging on; this records only the transition and its cause.
            DiagTrace.breadcrumb(
                .essential,
                level: newState ? .warning : .info,
                category: .playback,
                tag: "Player",
                message: newState ? "rebuffer started" : "rebuffer recovered",
                attrs: [
                    "reason": .string(newState ? cause : "buffer_refilled"),
                    "dropped_frames": .int(Int(clamping: vSyncDrops &+ totalVtFrameDrops)),
                    "audio_underruns": .int(audioUnderrunCount()),
                    "position_ms": .int(Self.positionMilliseconds(currentPlaybackTimeSeconds())),
                ]
            )
            #endif
            onBufferingChange?(newState)
            if !newState {
                lastReportedBufferingProgress = -1
            }
        }
        if newState, let buffered = bufferingPolicy.lastMinBufferedSeconds {
            let leave = bufferingPolicy.activeLeaveThresholdSeconds
            let progress = leave > 0 ? min(100, max(0, buffered / leave * 100)) : 100
            // Fire on whole-percent changes only; this runs 10×/second.
            let rounded = Int(progress)
            if rounded != lastReportedBufferingProgress {
                lastReportedBufferingProgress = rounded
                onBufferingProgress?(progress)
            }
        }
    }

    /// Seconds of decoded-but-unrendered video sitting in the frame
    /// scheduler.
    private func decodedVideoSecondsEstimate() -> Double {
        let fps = videoFPS > 0 ? videoFPS : 24.0
        return Double(videoFrameScheduler.count) / fps
    }

    /// Configure the packet queues' duration→seconds conversion from the
    /// discovered streams. Called after stream selection at load and again
    /// after an audio track switch (the audio timebase can change).
    private func configurePacketQueueTiming() {
        let videoTickSeconds = videoTimeBase.den > 0
            ? Double(videoTimeBase.num) / Double(videoTimeBase.den)
            : 0
        let fps = Double(refreshRate > 0 ? refreshRate : 24)
        videoPacketQueue.configureTiming(
            secondsPerTick: videoTickSeconds,
            fallbackSecondsPerPacket: fps > 0 ? 1.0 / fps : 0
        )

        let audioTickSeconds = audioTimeBase.den > 0
            ? Double(audioTimeBase.num) / Double(audioTimeBase.den)
            : 0
        // Fallback for zero-duration audio packets: codec frame duration
        // when the codec reports one, else an AAC-ish ~23 ms guess.
        var audioPacketSeconds = 1.0 / 43.0
        if let formatCtx, audioStreamIndex >= 0,
           let stream = formatCtx.pointee.streams?[Int(audioStreamIndex)],
           let codecparPtr = stream.pointee.codecpar {
            let codecpar = codecparPtr.pointee
            if codecpar.frame_size > 0, codecpar.sample_rate > 0 {
                audioPacketSeconds = Double(codecpar.frame_size) / Double(codecpar.sample_rate)
            }
        }
        audioPacketQueue.configureTiming(
            secondsPerTick: audioTickSeconds,
            fallbackSecondsPerPacket: audioPacketSeconds
        )
    }

    // MARK: - FFmpeg open + demux loop (demuxQueue)

    private func openAndDemux(url: URL, headers: [String: String], startTime: Double) {
        avformat_network_init()

        // Pre-allocate the format context so we can install the interrupt
        // callback BEFORE avformat_open_input. That call itself can block on
        // the initial socket connect / HTTP handshake, and we want the same
        // 10-second timeout policy to apply there too. Passing a non-nil ctx
        // into avformat_open_input preserves any fields we set on it.
        guard let ctx = avformat_alloc_context() else {
            reportError("avformat_alloc_context failed")
            return
        }

        // Interrupt callback: FFmpeg calls this periodically from inside
        // blocking I/O. Return non-zero to abort. We return 1 if we're either
        // cancelled OR if the demuxer has been stuck (no progress) for more
        // than `demuxIOTimeoutSeconds`. Reads are lock-free: we pass a raw
        // unretained pointer to self; the context is freed (and callback
        // unregistered) before PlayerCore deallocates, so the pointer is
        // always valid while FFmpeg can call us.
        demuxLastProgressWall = CACurrentMediaTime()
        let selfOpaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.interrupt_callback.opaque = selfOpaque
        ctx.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            let player = Unmanaged<PlayerCore>.fromOpaque(opaque).takeUnretainedValue()
            let elapsed = CACurrentMediaTime() - player.demuxLastProgressWall
            if CoreMediaDemuxInterruptPolicy.shouldAbort(
                cancelled: player.isCancelled,
                userPaused: player.userPaused,
                secondsSinceProgress: elapsed,
                timeoutSeconds: player.demuxIOTimeoutSeconds
            ) {
                return 1 // Abort blocking read — demux loop surfaces as error.
            }
            return 0
        }

        var optCtx: UnsafeMutablePointer<AVFormatContext>? = ctx

        // Every option below is HTTP(S)-specific. For local `file://`
        // playback (offline downloads) they must NOT be set: FFmpeg's `file`
        // protocol rejects `seekable=1` (valid range is [-1, 0]) and the
        // resulting ERANGE — surfaced as "Result too large" — aborts
        // `avformat_open_input`. Local files are natively seekable and need
        // no header/reconnect/range/timeout tuning.
        var options: OpaquePointer?
        let isRemote = url.scheme == "http" || url.scheme == "https"
        if isRemote {
            // Build AVDictionary for HTTP headers (Authorization etc.). ffmpeg
            // accepts `headers` as a \r\n-separated string in the options dict.
            if !headers.isEmpty {
                let joined = headers
                    .sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\r\n") + "\r\n"
                av_dict_set(&options, "headers", joined, 0)
            }
            // Enable reconnection for flaky HTTP.
            av_dict_set(&options, "reconnect", "1", 0)
            av_dict_set(&options, "reconnect_streamed", "1", 0)
            av_dict_set(&options, "reconnect_on_network_error", "1", 0)
            // reconnect_at_eof is deliberately NOT set: FFmpeg documents it for
            // live/endless streams — it treats a finite file's natural EOF as an
            // error and reconnects, which delays or breaks end-of-playback.
            av_dict_set(&options, "reconnect_on_http_error", "5xx", 0)
            av_dict_set(&options, "reconnect_delay_max", "5", 0)
            // Matroska over HTTP needs frequent small seeks during probing and
            // startup. Keep requests bounded so CDN/proxy TLS connections are not
            // held as one large open-ended range while the demuxer seeks around.
            av_dict_set(&options, "seekable", "1", 0)
            av_dict_set(&options, "multiple_requests", "1", 0)
            av_dict_set(&options, "initial_request_size", "2097152", 0)
            av_dict_set(&options, "request_size", "2097152", 0)
            av_dict_set(&options, "short_seek_size", "2097152", 0)
            // Per-operation socket timeout (microseconds). 10s matches the
            // interrupt callback so either mechanism can unstick us first.
            av_dict_set(&options, "rw_timeout", "10000000", 0)
            // TCP-specific hint: stop retrying the connect() if the remote is
            // quiet for 10s. Belt-and-braces with rw_timeout.
            av_dict_set(&options, "stimeout", "10000000", 0)
        }

        // FFmpeg's `file` protocol takes a raw filesystem path and does NOT
        // percent-decode it: handing it `url.absoluteString`
        // (`file:///…/Application%20Support/…`) makes it look for a literal
        // "Application%20Support" directory and fail with ENOENT. For local
        // files pass the decoded `url.path`; remote URLs keep their encoded
        // absolute string.
        let ffmpegInput = url.isFileURL ? url.path : url.absoluteString
        let urlC = ffmpegInput.cString(using: .utf8)
        let openResult = avformat_open_input(&optCtx, urlC, nil, &options)
        av_dict_free(&options)
        // avformat_open_input keeps our pre-allocated context on success and
        // frees it on failure — so `optCtx` is nil iff we failed. On the
        // happy path `ctx == optCtx`, and subsequent code keeps using `ctx`.
        guard openResult == 0, optCtx != nil else {
            reportError("Failed to open file: \(Self.ffmpegError(openResult))")
            return
        }
        formatCtx = ctx

        let findResult = avformat_find_stream_info(ctx, nil)
        guard findResult >= 0 else {
            reportError("Failed to read stream info: \(Self.ffmpegError(findResult))")
            return
        }

        // Duration in seconds. AV_NOPTS_VALUE → 0.
        let durationRaw = ctx.pointee.duration
        if durationRaw > 0 {
            durationSeconds = Double(durationRaw) / Double(AV_TIME_BASE)
        }

        // Find streams + build format descriptions.
        guard findStreams() else {
            reportError("No supported video stream")
            return
        }
        // Stream timebases are known — teach the packet queues to convert
        // packet durations into buffered seconds for the buffering policy.
        configurePacketQueueTiming()
        let buildOK = buildVideoFormatDescription()
        // If the format-description step rejected the stream (e.g. DV P5 up
        // front), fire the neutral rejection signal and exit cleanly. The
        // VM decides what to do with it.
        if fireRejectionIfPending() { return }
        guard buildOK else {
            reportError("Unsupported video codec / failed to build format description")
            return
        }
        guard createDecompressionSession() else {
            // VT can flag a rejection from inside createDecompressionSession
            // (unimpErr on HEVC+PQ = unsignalled DV). Route it through the
            // same neutral signal used for the up-front P5 detection.
            if fireRejectionIfPending() { return }
            reportError("Video decoder unavailable")
            return
        }
        if audioStreamIndex >= 0 {
            if !setupAudioDecoder() {
                Self.logger.warning("audio decoder setup failed; continuing video-only")
                audioStreamIndex = -1
            }
        }
        // Register any embedded font attachments with libass BEFORE we
        // open a subtitle decoder — tracks that reference these fonts
        // need the library to already know about them at parse time.
        registerEmbeddedFonts()

        // Subtitle: honor any caller-stashed selection. Sidecar tracks
        // flow through `addSubtitle` later, once the VM has walked the
        // server-provided `subtitle_urls` list.
        if let wantedId = pendingSubtitleTrackId, !SubtitleTrackIdSpace.isSidecar(wantedId) {
            let candidate = Int32(wantedId)
            if candidate >= 0, candidate < Int32(ctx.pointee.nb_streams) {
                if !setupSubtitleDecoder(streamIndex: candidate, slot: .primary) {
                    Self.logger.warning("subtitle decoder setup failed; continuing without subs")
                }
            }
        }
        if let wantedId = pendingSecondarySubtitleTrackId,
           !SubtitleTrackIdSpace.isSidecar(wantedId) {
            let candidate = Int32(wantedId)
            if candidate >= 0, candidate < Int32(ctx.pointee.nb_streams) {
                if !setupSubtitleDecoder(streamIndex: candidate, slot: .secondary) {
                    Self.logger.warning("secondary subtitle decoder setup failed")
                }
            }
        }

        // Tracks + chapters. Both are walked off the AVFormatContext while
        // we still hold demuxQueue; capturing snapshots here keeps main
        // thread callbacks from touching formatCtx directly.
        let tracks = buildTrackList()
        let chapters = ChapterParser.parse(formatContext: formatCtx)
        currentTracks = tracks
        currentChapters = chapters
        DispatchQueue.main.async { [weak self] in
            self?.onTracksChange?(tracks)
            self?.onChaptersChange?(chapters)
            if self?.durationSeconds ?? 0 > 0 {
                self?.onDurationChange?(self?.durationSeconds ?? 0)
            }
        }

        // HDR: platform-specific signaling before the first frame arrives.
        // tvOS negotiates HDMI mode via AVDisplayManager; iOS toggles EDR on
        // the display layer via a sig-peak event.
        #if os(tvOS)
        let fps = refreshRate
        let contentFormat: TVDisplayCriteria.ContentFormat = hdrEnabled
            ? tvDisplayContentFormat
            : .sdr
        let needsDvGate = requiresDolbyVisionDisplay && hdrEnabled
        DispatchQueue.main.async { [weak self] in
            if needsDvGate {
                self?.applyDvGatedDisplayCriteria(refreshRate: fps)
            } else {
                TVDisplayCriteria.apply(refreshRate: fps, contentFormat: contentFormat)
            }
        }
        #else
        publishSigPeakIfNeeded()
        #endif

        #if os(iOS) || os(tvOS)
        // Single funnel for "what did the pipeline actually decide to be".
        // Everything upstream of here — codec classification, DV routing,
        // software fallback, pixel format, HDMI/EDR signaling — has resolved,
        // and each of those branches already prints its own `[CMP-…]` line to
        // stdout. This does not repeat them: it records the *outcome* as
        // registered attributes so a report can be filtered on decoder,
        // resolution, or HDR mode without parsing the free-text trace.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: "video pipeline resolved",
            attrs: videoPipelineAttributes()
        )
        #endif

        // Seek to startTime if requested. `pendingSkipBelowPTS` gates the
        // renderers so the keyframe-gap frames the backward-seek drags in
        // don't produce an audio-ahead-of-video offset.
        pendingSkipBelowPTS = startTime
        skippedPreTargetVideoFrames = 0
        skippedPreTargetAudioFrames = 0
        // Audio-less content has nothing to re-anchor on; skip the dance.
        shouldResyncClockOnFirstAudio = audioStreamIndex >= 0
        if startTime > 0 {
            _ = seekFormatContext(ctx, to: startTime, logContext: "open")
        }

        // Start decode feed loops before starting the clocks. Very high bitrate
        // direct files can otherwise underrun audio immediately, which stops the
        // audio engine and drops the shared playback timeline back to rate 0.
        startVideoFeed(resumeDisplayLink: false)
        startAudioFeed()
        startEmbeddedSubtitleFeeds()

        // Prime the playback clock at startTime, then auto-start playback at
        // the user's preferred rate once the decode queues have a small cushion.
        // The shared player UI assumes loads begin playing immediately, so this
        // is a bounded startup wait rather than requiring a follow-up `play()`.
        let initial = CMTime(seconds: startTime, preferredTimescale: 600)
        let startRate = self.currentRate
        // Record where the video clock should start. videoFPS drives the
        // sync predicate in the display link tick; refreshRate came from
        // `avg_frame_rate` at stream setup.
        self.videoFPS = Double(self.refreshRate > 0 ? self.refreshRate : 24.0)
        print(String(format:
            "[CMP] openAndDemux startTime=%.3f startRate=%.2f videoFPS=%.3f durationSeconds=%.3f",
            startTime, Double(startRate), self.videoFPS, self.durationSeconds))
        beginPlaybackWhenPrimed(initial: initial, rate: startRate, deadline: CACurrentMediaTime() + 3.0)

        // Kick off the 1Hz diagnostic snapshot timer. Temporary — for the
        // slow-motion debug investigation.
        startDiagnostics()

        // Fire onFileLoaded now — the streams are open, codecs are ready,
        // feeds are registered, and playback is starting. The UI can
        // dismiss its loading spinner and apply user settings. Previously
        // we waited for the first decoded frame, which created a deadlock:
        // the renderer only pulls packets after rate > 0, but rate came
        // from the UI which was blocked on onFileLoaded → no frames → hang.
        if !hasFiredFileLoaded {
            hasFiredFileLoaded = true
            DispatchQueue.main.async { [weak self] in self?.onFileLoaded?() }
        }

        if #available(iOS 15.0, tvOS 15.0, *) {
            os_signpost(.end, log: Self.signpostLog, name: "Load",
                        signpostID: loadSignpostID)
        }

        // The open (and its startTime seek) is complete; it's now safe to
        // apply a parked audio-track switch through the normal cancel-and-
        // switch path. It restarts the demux loop itself, so if it cancels
        // the one below immediately that's the standard switch sequence.
        endLoadGate(applyDeferredSwitch: true)

        // Demux loop: push packets onto the bounded queues; block when full.
        runDemuxLoop()
    }

    private func findStreams() -> Bool {
        guard let formatCtx else { return false }
        let nb = Int(formatCtx.pointee.nb_streams)
        let streams = formatCtx.pointee.streams

        // Video: first stream wins.
        // Audio: prefer the container-default stream when present, otherwise
        // fall back to the first audio stream. Output channel adaptation now
        // happens in `setupAudioDecoder`, so we no longer bias initial
        // selection toward compatibility tracks just because they have fewer
        // channels than the primary stream.
        var fallbackAudioIdx: Int32 = -1
        var fallbackAudioTB = AVRational(num: 1, den: 1)
        var defaultAudioIdx: Int32 = -1
        var defaultAudioTB = AVRational(num: 1, den: 1)
        for i in 0..<nb {
            guard let stream = streams?[i] else { continue }
            guard let codecparPtr = stream.pointee.codecpar else { continue }
            let codecpar = codecparPtr.pointee

            if codecpar.codec_type == AVMEDIA_TYPE_VIDEO, videoStreamIndex < 0 {
                videoStreamIndex = Int32(i)
                videoTimeBase = stream.pointee.time_base
                let avg = stream.pointee.avg_frame_rate
                let r = stream.pointee.r_frame_rate
                if avg.den > 0, avg.num > 0 {
                    refreshRate = Float(avg.num) / Float(avg.den)
                } else if r.den > 0, r.num > 0 {
                    refreshRate = Float(r.num) / Float(r.den)
                }
            } else if codecpar.codec_type == AVMEDIA_TYPE_AUDIO {
                let disposition = Int32(stream.pointee.disposition)
                let isDefault = (disposition & AV_DISPOSITION_DEFAULT) != 0
                if fallbackAudioIdx < 0 {
                    fallbackAudioIdx = Int32(i)
                    fallbackAudioTB = stream.pointee.time_base
                }
                if defaultAudioIdx < 0, isDefault {
                    defaultAudioIdx = Int32(i)
                    defaultAudioTB = stream.pointee.time_base
                }
            }
        }
        if defaultAudioIdx >= 0 {
            audioStreamIndex = defaultAudioIdx
            audioTimeBase = defaultAudioTB
            print("[CMP] findStreams selected default audio stream \(defaultAudioIdx)")
        } else if fallbackAudioIdx >= 0 {
            audioStreamIndex = fallbackAudioIdx
            audioTimeBase = fallbackAudioTB
            print("[CMP] findStreams selected first audio stream \(fallbackAudioIdx)")
        }
        print(String(format:
            "[CMP] findStreams vStream=%d aStream=%d refreshRate=%.3f vTB=%d/%d aTB=%d/%d",
            videoStreamIndex, audioStreamIndex, Double(refreshRate),
            Int(videoTimeBase.num), Int(videoTimeBase.den),
            Int(audioTimeBase.num), Int(audioTimeBase.den)))
        return videoStreamIndex >= 0
    }

    private func buildVideoFormatDescription() -> Bool {
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecparPtr = stream.pointee.codecpar
        else { return false }
        let codecpar = codecparPtr.pointee
        resolvedVideoColorRange = VideoColorMetadata.colorRangeName(codecpar.color_range)
            ?? sourceColorRangeHint
        videoDecodeOutputDimensions = nil
        useUntimedCompressedVideoSamples = false

        let codecType: CMVideoCodecType
        let atomKey: String?
        switch codecpar.codec_id {
        case AV_CODEC_ID_HEVC:
            codecType = kCMVideoCodecType_HEVC
            atomKey = "hvcC"
        case AV_CODEC_ID_H264:
            if let codedDimensions = Self.codedH264OutputDimensionsIfNeeded(codecpar) {
                videoDecodeOutputDimensions = codedDimensions
                print(String(format:
                    "[CMP] h264 display size %dx%d is cropped; trying VideoToolbox hardware with coded buffers %dx%d",
                    Int(codecpar.width), Int(codecpar.height),
                    Int(codedDimensions.width), Int(codedDimensions.height)))
            }
            codecType = kCMVideoCodecType_H264
            atomKey = "avcC"
            useUntimedCompressedVideoSamples = true
        case AV_CODEC_ID_PRORES:
            codecType = VideoColorMetadata.proResCodecType(codecTag: codecpar.codec_tag)
            atomKey = nil
            videoPixelFormat = kCVPixelFormatType_32BGRA
        case AV_CODEC_ID_MPEG2VIDEO:
            videoDecodeMode = .software
            dynamicRange = VideoColorMetadata.dynamicRange(forTransfer: codecpar.color_trc)
            videoPixelFormat = kCVPixelFormatType_32BGRA
            let codecName = Self.codecName(for: codecpar.codec_id) ?? "unknown"
            Self.logger.info(
                "video: codec=\(codecpar.codec_id.rawValue) \(codecpar.width)x\(codecpar.height) fps=\(self.refreshRate) dr=\(self.dynamicRange.rawValue) mode=software"
            )
            print(String(format:
                "[CMP] video codecId=%d codec=%@ %dx%d fps=%.3f dr=%d color_trc=%d color_range=%d software=1",
                Int(codecpar.codec_id.rawValue), codecName, Int(codecpar.width), Int(codecpar.height),
                Double(self.refreshRate), Int(dynamicRange.rawValue),
                Int(codecpar.color_trc.rawValue), Int(codecpar.color_range.rawValue)))
            return setupSoftwareVideoDecoder(codecpar: codecpar, codecparPtr: codecparPtr)
        default:
            // Codec-tail fallback (SiloPlayer plan, Stage 4): anything FFmpeg
            // ships a decoder for routes through the generic software path
            // instead of being rejected — VP9/VP8, AV1 (dav1d), MPEG-4
            // Part 2, VC-1, and friends. The decoders were always compiled
            // in; this switch was the only thing between them and playback.
            // The SW path decodes with bounded frame+slice threading and
            // outputs bit-depth-aware buffers (>8-bit sources convert to
            // P010 so HDR survives end-to-end; 8-bit stays on the planar
            // fast path). Known limit: 4K AV1/VP9 conversion is CPU-bound
            // even threaded and may stutter on Apple TV — the loopback
            // route remains primary for H.264/HEVC.
            guard avcodec_find_decoder(codecpar.codec_id) != nil else {
                Self.logger.error("Unsupported video codec_id=\(codecpar.codec_id.rawValue) (no FFmpeg decoder)")
                return false
            }
            videoDecodeMode = .software
            dynamicRange = VideoColorMetadata.dynamicRange(forTransfer: codecpar.color_trc)
            videoPixelFormat = kCVPixelFormatType_32BGRA
            let codecName = Self.codecName(for: codecpar.codec_id) ?? "unknown"
            Self.logger.info(
                "video: codec=\(codecpar.codec_id.rawValue) \(codecpar.width)x\(codecpar.height) fps=\(self.refreshRate) dr=\(self.dynamicRange.rawValue) mode=software (codec-tail)"
            )
            print(String(format:
                "[CMP] video codecId=%d codec=%@ %dx%d fps=%.3f dr=%d color_trc=%d color_range=%d software=1 tail=1",
                Int(codecpar.codec_id.rawValue), codecName, Int(codecpar.width), Int(codecpar.height),
                Double(self.refreshRate), Int(dynamicRange.rawValue),
                Int(codecpar.color_trc.rawValue), Int(codecpar.color_range.rawValue)))
            return setupSoftwareVideoDecoder(codecpar: codecpar, codecparPtr: codecparPtr)
        }
        videoDecodeMode = .videoToolbox

        // Baseline dynamic-range classification from the transfer function.
        // Overridden below if we find Dolby Vision side data.
        dynamicRange = VideoColorMetadata.dynamicRange(forTransfer: codecpar.color_trc)

        // Dolby Vision detection + routing. See MARK: Dolby Vision.
        doviConfig = nil
        requiresDolbyVisionDisplay = false
        shouldStripHevcEnhancement = false
        strippedNalCount = 0
        var doviAtom: (key: String, data: Data)?
        if let dovi = DolbyVisionFormat.readConfig(stream: stream, codecpar: codecpar) {
            doviConfig = dovi
            let routing = DolbyVisionFormat.decideRouting(dovi, policy: dolbyVisionPolicy)
            switch routing {
            case .native(let boxKey, let dr, let requiresDv):
                doviAtom = (boxKey, DolbyVisionFormat.serializeBox(dovi))
                dynamicRange = dr
                requiresDolbyVisionDisplay = requiresDv
                print(String(format:
                    "[CMP] dv profile=%d level=%d compat=%d rpu=%d bl=%d el=%d emittedAs=%@ dr=%d",
                    Int(dovi.profile), Int(dovi.level), Int(dovi.compatId),
                    dovi.rpuPresent ? 1 : 0, dovi.blPresent ? 1 : 0, dovi.elPresent ? 1 : 0,
                    boxKey, Int(dr.rawValue)))
            case .strippedHdr10:
                // Keep dynamicRange as whatever color_trc said (should be hdr10
                // for PQ-encoded base layers). Do not emit the DV atom.
                //
                // NAL-level stripping of EL / DV RPU units turned out to cause
                // regressions: even stripping just UNSPEC62/63 left VT unable
                // to produce output frames on Profile 7 seek-resumes. Leave
                // the filter off while we investigate — VT on Apple TV 4K
                // appears to handle BL+EL+RPU mixed packets correctly on its
                // own, modulo the periodic stutter.
                shouldStripHevcEnhancement = false
                print(String(format:
                    "[CMP] dv profile=%d level=%d compat=%d rpu=%d bl=%d el=%d emittedAs=stripped dr=%d stripEL=%d",
                    Int(dovi.profile), Int(dovi.level), Int(dovi.compatId),
                    dovi.rpuPresent ? 1 : 0, dovi.blPresent ? 1 : 0, dovi.elPresent ? 1 : 0,
                    Int(dynamicRange.rawValue), shouldStripHevcEnhancement ? 1 : 0))
            case .p5Passthrough:
                // DV P5: VT won't instantiate a decoder for the BL (unimpErr
                // from VTDecompressionSessionCreate for any hvcC + dvcC + P5
                // combo we've tried). Hand off to the AVPlayer backend, which
                // remuxes to HLS via FFmpeg's mp4 muxer + dvh1 FourCC and lets
                // AVPlayer's internal DV pipeline decode + negotiate HDMI.
                if let url = lastLoadURL {
                    pendingRejection = (.dolbyVisionProfile5, url, lastLoadHeaders, lastLoadStartTime)
                    print(String(format:
                        "[CMP] dv profile=%d level=%d compat=%d → reject as P5 (VM picks fallback)",
                        Int(dovi.profile), Int(dovi.level), Int(dovi.compatId)))
                    return false
                } else {
                    print("[CMP] dv p5 detected but lastLoadURL missing — refusing")
                    DispatchQueue.main.async { [weak self] in
                        self?.onError?("Dolby Vision Profile 5 handoff failed")
                    }
                    return false
                }
            case .refused(let reason):
                print(String(format:
                    "[CMP] dv profile=%d level=%d compat=%d REFUSED: %@",
                    Int(dovi.profile), Int(dovi.level), Int(dovi.compatId), reason))
                Self.logger.error("Dolby Vision refused: \(reason)")
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(reason)
                }
                return false
            }
        } else {
            print(String(format:
                "[CMP] dv none color_trc=%d → dr=%d",
                Int(codecpar.color_trc.rawValue), Int(dynamicRange.rawValue)))
        }

        Self.logger.info(
            "video: codec=\(codecpar.codec_id.rawValue) \(codecpar.width)x\(codecpar.height) fps=\(self.refreshRate) dr=\(self.dynamicRange.rawValue)"
        )
        print(String(format:
            "[CMP] video codecId=%d %dx%d fps=%.3f dr=%d color_trc=%d color_range=%d",
            Int(codecpar.codec_id.rawValue), Int(codecpar.width), Int(codecpar.height),
            Double(self.refreshRate), Int(self.dynamicRange.rawValue),
            Int(codecpar.color_trc.rawValue), Int(codecpar.color_range.rawValue)))

        // hvcC / avcC extradata, with the NAL-size patch below. Copy into a
        // Swift-owned Data buffer BEFORE mutating — ed points at ffmpeg-owned
        // memory that may be read again by the demuxer (seek, track switch,
        // codec re-configure). Mutating it in place can corrupt downstream
        // reads.
        var atomsData: Data?
        if let ed = codecpar.extradata, codecpar.extradata_size > 0 {
            let size = Int(codecpar.extradata_size)
            var copy = Data(bytes: ed, count: size)
            if codecpar.codec_id == AV_CODEC_ID_HEVC, size >= 5, copy[4] == 0xFE {
                copy[4] = 0xFF
                isConvertNALSize = true
            } else if codecpar.codec_id == AV_CODEC_ID_H264, size >= 5, (copy[4] & 0xFC) == 0xFC {
                // H.264 avcC: bottom 2 bits == NAL length size - 1. Standard
                // streams already encode 4-byte length prefixes; no patch.
                isConvertNALSize = false
            }
            atomsData = copy
        }

        let isNativeDv: Bool = {
            if let doviAtom { return doviAtom.key == "dvcC" || doviAtom.key == "dvvC" }
            return false
        }()
        // Stay on `kCMVideoCodecType_HEVC` ('hvc1') for native DV too. The
        // dedicated `kCMVideoCodecType_DolbyVisionHEVC` ('dvh1') is documented
        // for HLS / authoring file formats, not for VTDecompressionSessionCreate
        // — asking VT for a 'dvh1' session returns unimpErr (-4). Profile 7/8.x
        // work because their BL is HDR10/SDR/HLG-compatible and VT decodes the
        // BL with 'hvc1' while the dvcC atom + RPU-carrying NALs pass through
        // for the display to apply DV dynamic metadata.
        let fullRange = VideoColorMetadata.isFullRange(
            codecpar.color_range,
            fallbackName: resolvedVideoColorRange
        )
        // Pick a CVPixelBuffer format that matches the advertised fullRange.
        // Mismatches (e.g. `FullRangeVideo=true` + video-range pixel format)
        // leave VT with no registered decoder → unimpErr (-4). This is what
        // breaks P5 on our stack specifically: P5 signals color_range=JPEG in
        // the SPS VUI per the DV hidden-signal convention, so we MUST ask VT
        // for a matching full-range 10-bit pixel format.
        videoPixelFormat = VideoColorMetadata.pickPixelFormat(
            dynamicRange: dynamicRange, fullRange: fullRange)
        let extensions: NSMutableDictionary = [
            kCMFormatDescriptionExtension_FullRangeVideo: fullRange,
            "EnableHardwareAcceleratedVideoDecoder": true,
            // Declare the pixel format in the format-description extensions
            // so VT's decoder lookup sees a consistent spec that matches what
            // we ask for in `createDecompressionSession`'s imageBufferAttributes.
            // Without this, VT can fail session creation with unimpErr (-4)
            // when fullRange / pixel-format combos don't match a registered
            // decoder (notably for DV P5).
            kCVPixelBufferPixelFormatTypeKey: videoPixelFormat,
        ]
        if let atomsData, let atomKey {
            var atoms: [String: Data] = [atomKey: atomsData]
            if let doviAtom {
                atoms[doviAtom.key] = doviAtom.data
            }
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
        }
        // Color attachments. Native DV (P8.x / P9 / P10, whose base layer is
        // HDR10/SDR/HLG-compatible) declares its base layer rather than the
        // source VUI, which Profile 8 streams routinely tag for the DV layer
        // instead. Which base layer that is comes from the compatibility ID,
        // through the same mapping the tvOS HDMI criteria use, so the mode
        // the panel is asked for and the frames it is handed agree: 8.1 is
        // PQ, 8.2 is Rec.709 SDR, 8.4 is HLG.
        //
        // For plain HEVC and for P5 passthrough we take the VUI values — the
        // helpers return nil on UNSPECIFIED, leaving the keys absent (standard
        // approach for P5).
        if isNativeDv {
            let colorimetry = VideoColorMetadata.dolbyVisionBaseLayerColorimetry(
                LoopbackSessionSpec.DVProfile8BaseLayer(
                    dolbyVisionCompatibilityID: doviConfig.map { Int($0.compatId) }
                )
            )
            extensions[kCVImageBufferColorPrimariesKey] = colorimetry.primaries as String
            extensions[kCVImageBufferTransferFunctionKey] = colorimetry.transfer as String
            extensions[kCVImageBufferYCbCrMatrixKey] = colorimetry.matrix as String
        } else {
            if let cp = VideoColorMetadata.colorPrimariesString(codecpar.color_primaries) {
                extensions[kCVImageBufferColorPrimariesKey] = cp as String
            }
            if let tf = VideoColorMetadata.transferFunctionString(codecpar.color_trc) {
                extensions[kCVImageBufferTransferFunctionKey] = tf as String
            }
            if let mx = VideoColorMetadata.ycbcrMatrixString(codecpar.color_space) {
                extensions[kCVImageBufferYCbCrMatrixKey] = mx as String
            }
        }

        let fourCC = VideoFormatDescriptionBuilder.fourCCString(codecType)
        let pxFourCC = VideoFormatDescriptionBuilder.fourCCString(videoPixelFormat)
        print("[CMP] videoFormat codecType='\(fourCC)' fullRange=\(fullRange) nativeDv=\(isNativeDv) pxFmt='\(pxFourCC)'")

        let buildResult = VideoFormatDescriptionBuilder.makeCompressedFormatDescription(
            codecpar: codecpar,
            codecType: codecType,
            extensions: extensions,
            atomsData: atomsData
        )
        if buildResult.usedH264ParameterSets,
           let formatDescription = buildResult.formatDescription {
            let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
            print(String(format:
                "[CMP] videoFormat h264 from avcC parameter sets dims=%dx%d probed=%dx%d",
                Int(dims.width), Int(dims.height),
                Int(codecpar.width), Int(codecpar.height)))
        }
        guard buildResult.status == noErr, let fd = buildResult.formatDescription else {
            Self.logger.error("CMVideoFormatDescriptionCreate failed: \(buildResult.status)")
            return false
        }
        videoFormatDescription = fd
        publishVideoPresentationSize()
        return true
    }

    private static func codedH264OutputDimensionsIfNeeded(_ codecpar: AVCodecParameters) -> CMVideoDimensions? {
        // H.264 is macroblock-coded. Some valid rips signal a cropped display
        // width (for example 1918px from a 1920px coded frame). The compressed
        // format description should keep the crop from SPS, but VT's output
        // pool must not be constrained to the cropped width or the hardware
        // decoder can reject later slices as bad data.
        guard codecpar.width > 0, codecpar.height > 0, codecpar.width % 16 != 0 else {
            return nil
        }
        let codedWidth = alignToH264Macroblock(codecpar.width)
        let codedHeight = alignToH264Macroblock(codecpar.height)
        guard codedWidth != codecpar.width || codedHeight != codecpar.height else { return nil }
        return CMVideoDimensions(width: codedWidth, height: codedHeight)
    }

    private static func alignToH264Macroblock(_ value: Int32) -> Int32 {
        ((value + 15) / 16) * 16
    }

    private func setupSoftwareVideoDecoder(
        codecpar: AVCodecParameters,
        codecparPtr: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        guard let codec = avcodec_find_decoder(codecpar.codec_id) else {
            Self.logger.error("video: avcodec_find_decoder failed id=\(codecpar.codec_id.rawValue)")
            return false
        }

        var ctx = avcodec_alloc_context3(codec)
        guard ctx != nil else { return false }
        let copyR = avcodec_parameters_to_context(ctx, codecparPtr)
        if copyR < 0 {
            Self.logger.error("video: avcodec_parameters_to_context failed: \(Self.ffmpegError(copyR))")
            avcodec_free_context(&ctx)
            return false
        }
        // Bounded frame+slice threading. FFmpeg intersects the request with
        // the codec's actual capabilities, so this is a safe no-op for
        // decoders that can't split work. Capped at 8 so a software decode
        // never claims every core: real-time audio decode, demux, and the
        // display tick still need headroom. Configured here (not at the
        // call sites) so the mid-stream VT->software fallback inherits it.
        let threadBudget = Int32(min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8))
        ctx?.pointee.thread_count = threadBudget
        ctx?.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        let openR = avcodec_open2(ctx, codec, nil)
        if openR < 0 {
            Self.logger.error("video: avcodec_open2 failed: \(Self.ffmpegError(openR))")
            avcodec_free_context(&ctx)
            return false
        }
        print(String(format:
            "[CMP] software video decoder open codec=%@ threads=%d %dx%d",
            Self.codecName(for: codecpar.codec_id) ?? "unknown",
            Int(ctx?.pointee.thread_count ?? 0),
            Int(codecpar.width), Int(codecpar.height)))
        videoCodecCtx = ctx
        return true
    }

    private func createDecompressionSession() -> Bool {
        if videoDecodeMode == .software {
            return videoCodecCtx != nil
        }
        guard let fd = videoFormatDescription else { return false }

        let formatDims = CMVideoFormatDescriptionGetDimensions(fd)
        let outputDims = videoDecodeOutputDimensions ?? formatDims
        let attrs: NSMutableDictionary = [
            kCVPixelBufferPixelFormatTypeKey:     videoPixelFormat,
            kCVPixelBufferMetalCompatibilityKey:  true,
            kCVPixelBufferWidthKey:               outputDims.width,
            kCVPixelBufferHeightKey:              outputDims.height,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        if videoDecodeOutputDimensions != nil {
            print(String(format:
                "[CMP] VT output dimensions override format=%dx%d output=%dx%d",
                Int(formatDims.width), Int(formatDims.height),
                Int(outputDims.width), Int(outputDims.height)))
        }

        // Pass the full format-description extensions dict as the decoder
        // specification — this lets VT read the hvcC / dvcC atoms + color
        // attachments when picking which decoder to instantiate. Some iPhone
        // HEVC HDR streams reject this stricter path with `unimpErr (-4)`,
        // so we retry a more relaxed create before surfacing a hard failure.
        var createResult = videoToolboxDecoder.createSession(
            formatDescription: fd,
            decoderSpecification: VideoToolboxVideoDecoder.decoderSpecification(for: fd),
            imageBufferAttributes: attrs,
            label: "primary"
        )
        if createResult.session == nil,
           let retryResult = retryVideoToolboxSessionCreateIfNeeded(
                failedStatus: createResult.status,
                formatDescription: fd,
                imageBufferAttributes: attrs
           ) {
            createResult = retryResult
        }

        guard createResult.status == noErr, let session = createResult.session else {
            Self.logger.error("VTDecompressionSessionCreate failed: \(createResult.status)")
            print("[CMP] ERROR: VTDecompressionSessionCreate failed status=\(createResult.status)")
            if currentVideoCodecIsProRes(),
               switchCurrentVideoToSoftwareDecoder(reason: "prores_vt_create_failed_\(createResult.status)") {
                return true
            }
            // If VT rejects iPhone HEVC HDR session create with unimpErr (-4),
            // route the same original source URL through the AVPlayer
            // remux backend instead of surfacing a terminal decoder error.
            // PQ still strongly suggests unsignalled DV; HLG/HDR10 now share
            // the same AVPlayer escape hatch.
            if createResult.status == -4,
               let formatCtx,
               videoStreamIndex >= 0,
               let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
               let cpp = stream.pointee.codecpar,
               cpp.pointee.codec_id == AV_CODEC_ID_HEVC,
               dynamicRange != .sdr,
               let url = lastLoadURL {
                let rejection: StreamRejection =
                    cpp.pointee.color_trc == AVCOL_TRC_SMPTE2084 ?
                    .videoToolboxUnsupportedHEVCPQ :
                    .videoToolboxUnsupportedHEVCHDR
                print("[CMP] VT unimpErr on HEVC HDR dr=\(dynamicRange.rawValue) → reject to AVPlayer route")
                pendingRejection = (rejection, url,
                                    lastLoadHeaders, lastLoadStartTime)
                return false
            }
            // Caller's `reportError("Video decoder unavailable")` is the
            // single owner of the terminal-error dispatch. Don't fire
            // another one here.
            return false
        }
        if #available(iOS 14.0, tvOS 14.0, *) {
            VTSessionSetProperty(
                session,
                key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                value: kCFBooleanTrue)
        }
        videoToolboxDecoder.install(session: session)
        return true
    }

    private func retryVideoToolboxSessionCreateIfNeeded(
        failedStatus: OSStatus,
        formatDescription: CMVideoFormatDescription,
        imageBufferAttributes: NSDictionary
    ) -> VideoToolboxVideoDecoder.CreateResult? {
        #if os(iOS)
        guard failedStatus == -4 else { return nil }
        guard doviConfig == nil else { return nil }
        guard dynamicRange != .sdr else { return nil }
        guard CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC else {
            return nil
        }

        let relaxed = videoToolboxDecoder.createSession(
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes,
            label: "retry-no-decoder-spec"
        )
        if relaxed.session != nil {
            return relaxed
        }

        guard let simplifiedFormatDescription = VideoFormatDescriptionBuilder.makeRelaxedFormatDescription(from: formatDescription) else {
            return relaxed
        }
        let simplified = videoToolboxDecoder.createSession(
            formatDescription: simplifiedFormatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes,
            label: "retry-simplified-format"
        )
        if simplified.session != nil {
            videoFormatDescription = simplifiedFormatDescription
            publishVideoPresentationSize()
        }
        return simplified
        #else
        return nil
        #endif
    }

    private func setupAudioDecoder() -> Bool {
        guard let formatCtx,
              audioStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(audioStreamIndex)],
              let codecparPtr = stream.pointee.codecpar
        else { return false }
        let codecpar = codecparPtr.pointee

        guard let codec = avcodec_find_decoder(codecpar.codec_id) else {
            Self.logger.error("audio: avcodec_find_decoder failed id=\(codecpar.codec_id.rawValue)")
            return false
        }
        var ctx = avcodec_alloc_context3(codec)
        guard ctx != nil else { return false }
        // Pass the real codecpar pointer. Shallow-copying the struct would
        // alias pointer fields (extradata, coded_side_data) and break free
        // semantics.
        let copyR = avcodec_parameters_to_context(ctx, codecparPtr)
        if copyR < 0 {
            Self.logger.error("audio: avcodec_parameters_to_context failed: \(Self.ffmpegError(copyR))")
            avcodec_free_context(&ctx)
            return false
        }
        let openR = avcodec_open2(ctx, codec, nil)
        if openR < 0 {
            Self.logger.error("audio: avcodec_open2 failed: \(Self.ffmpegError(openR))")
            avcodec_free_context(&ctx)
            return false
        }
        audioCodecCtx = ctx

        // TrueHD/MLP can leave codecpar and the opened decoder at
        // AV_SAMPLE_FMT_NONE until the first major-sync unit has decoded.
        // The output path is therefore configured lazily from that first
        // authoritative AVFrame in ensureAudioOutputConfigured(from:).
        return true
    }

    private func ensureAudioOutputConfigured(
        from decodedFrame: UnsafeMutablePointer<AVFrame>
    ) -> AudioDecodePipeline.ResamplingOutput? {
        if let swrContext = audioSwrCtx, let config = audioOutputConfig {
            return AudioDecodePipeline.ResamplingOutput(
                swrContext: swrContext,
                config: config
            )
        }
        guard let codecContext = audioCodecCtx else { return nil }

        let inputFormatRaw = decodedFrame.pointee.format
        guard inputFormatRaw >= 0 else {
            Self.logger.error("audio: decoded frame has unknown sample format")
            return nil
        }
        let inputSampleRate = decodedFrame.pointee.sample_rate > 0
            ? decodedFrame.pointee.sample_rate
            : codecContext.pointee.sample_rate
        guard inputSampleRate > 0 else {
            Self.logger.error("audio: decoded frame has unknown sample rate")
            return nil
        }

        var inputLayout = decodedFrame.pointee.ch_layout
        if inputLayout.nb_channels <= 0 {
            inputLayout = codecContext.pointee.ch_layout
        }
        if inputLayout.nb_channels <= 0 {
            av_channel_layout_default(&inputLayout, 2)
        }

        // Output format: LPCM Float32 planar at the decoded sample rate. Size
        // the output layout to the active audio route instead of blindly
        // exposing the source channel count. This mirrors KSPlayer's pattern:
        // keep the selected stream, but let the resampler fold it down when
        // the Apple output path cannot safely render the full layout.
        let inChannels = max(1, Int32(inputLayout.nb_channels))
        let outSampleRate = inputSampleRate
        #if os(macOS)
        let spatialAudioEnabled = false
        let routeMaxChannels = inChannels
        let outChannels = preferredOutputChannelCount(forSourceChannels: inChannels)
        #else
        let session = AVAudioSession.sharedInstance()
        let spatialAudioEnabled = spatialAudioEnabled(for: session)
        let routeMaxChannels = max(2, Int32(session.maximumOutputNumberOfChannels))
        let outChannels = preferredOutputChannelCount(
            forSourceChannels: inChannels,
            session: session
        )
        #endif
        if outChannels != inChannels {
            print(
                "[CMP] audio downmix sourceChannels=\(inChannels) outputChannels=\(outChannels) routeMaxChannels=\(routeMaxChannels) spatial=\(spatialAudioEnabled ? 1 : 0) codecId=\(Int(codecContext.pointee.codec_id.rawValue))"
            )
        }

        // Default layout for the destination (stereo if unknown / weird).
        var outChannelLayout = AVChannelLayout()
        av_channel_layout_default(&outChannelLayout, outChannels)

        var swr: OpaquePointer?
        let allocateResult = swr_alloc_set_opts2(
            &swr,
            &outChannelLayout,
            AV_SAMPLE_FMT_FLTP,
            outSampleRate,
            &inputLayout,
            AVSampleFormat(rawValue: inputFormatRaw),
            inputSampleRate,
            0,
            nil)
        guard allocateResult >= 0, swr != nil else {
            Self.logger.error(
                "swr_alloc_set_opts2 failed: \(Self.ffmpegError(allocateResult), privacy: .public)"
            )
            return nil
        }
        let initializeResult = swr_init(swr)
        guard initializeResult >= 0 else {
            Self.logger.error(
                "swr_init failed: \(Self.ffmpegError(initializeResult), privacy: .public)"
            )
            swr_free(&swr)
            return nil
        }

        // Build CMAudioFormatDescription matching our interleaved Float32 output.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(outSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(outChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Declare the output channel layout so CoreAudio knows which
        // interleaved slot is L / R / C / LFE / Ls / Rs. Without
        // this, multichannel sources (e.g. E-AC-3 / Atmos 5.1) sound muffled
        // because CoreAudio guesses a mapping and the center/dialog channel
        // gets routed wrong on downmix to the actual speaker output.
        // FFmpeg's `av_channel_layout_default` for 6ch produces
        // FL,FR,FC,LFE,BL,BR — identical ordering to MPEG_5_1_A — so swr's
        // interleaved output matches the layout we advertise here.
        var audioChannelLayout = AudioChannelLayout()
        let layoutTag: AudioChannelLayoutTag = {
            switch outChannels {
            case 1: return kAudioChannelLayoutTag_Mono
            case 2: return kAudioChannelLayoutTag_Stereo
            case 3: return kAudioChannelLayoutTag_MPEG_3_0_A
            case 4: return kAudioChannelLayoutTag_MPEG_4_0_A
            case 5: return kAudioChannelLayoutTag_MPEG_5_0_A
            case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
            case 7: return kAudioChannelLayoutTag_MPEG_6_1_A
            case 8: return kAudioChannelLayoutTag_MPEG_7_1_A
            default:
                // DiscreteInOrder tag encodes channel count in its low bits;
                // CoreAudio treats the channels as unmapped-but-ordered.
                return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(outChannels)
            }
        }()
        audioChannelLayout.mChannelLayoutTag = layoutTag
        var afd: CMAudioFormatDescription?
        let status = withUnsafePointer(to: &audioChannelLayout) { layoutPtr in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size,
                layout: layoutPtr,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &afd)
        }
        guard status == noErr, let afd else {
            Self.logger.error("CMAudioFormatDescriptionCreate failed: \(status)")
            swr_free(&swr)
            return nil
        }
        let engineChannelLayout = AVAudioChannelLayout(layoutTag: layoutTag)
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(outSampleRate),
            interleaved: false,
            channelLayout: engineChannelLayout
        )
        let config = NegotiatedAudioOutput(
            sampleRate: outSampleRate,
            channelCount: outChannels,
            channelLayout: outChannelLayout,
            formatDescription: afd,
            audioFormat: audioFormat,
            bytesPerSample: 4,
            layoutTag: layoutTag
        )
        guard let swr else { return nil }
        audioSwrCtx = swr
        audioOutputConfig = config
        audioOutput.prepare(audioFormat: audioFormat)
        activateAudioSession(preferredChannels: outChannels)
        print(String(format:
            "[CMP] audio codecId=%d sampleRate=%d channels=%d srcFormat=%d srcChannels=%d layoutTag=0x%x",
            Int(codecContext.pointee.codec_id.rawValue), Int(outSampleRate), Int(outChannels),
            Int(inputFormatRaw), Int(inChannels), Int(layoutTag)))
        #if os(iOS) || os(tvOS)
        // Audio negotiation is once per load (and once per track switch), and
        // the source→output channel fold is the usual explanation for "the
        // centre channel sounds wrong" reports, so it is essential-tier. The
        // existing "audio route changed" breadcrumb covers the route moving
        // afterwards; this covers what we negotiated against it.
        //
        // `sink` carries the fold because the registry has no channel-count
        // key, and the fold only means anything paired with the route it was
        // chosen for. Codec goes in `fmt`.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: "audio output negotiated",
            attrs: [
                "fmt": .string(Self.codecName(for: codecContext.pointee.codec_id) ?? "unknown"),
                "sink": .string(
                    "ch_\(inChannels)->\(outChannels) route_max_\(routeMaxChannels)"
                    + " spatial_\(spatialAudioEnabled ? 1 : 0)"
                ),
                "reason": .string(outChannels == inChannels ? "native_layout" : "downmix"),
            ]
        )
        #endif
        return AudioDecodePipeline.ResamplingOutput(
            swrContext: swr,
            config: config
        )
    }

    private func runDemuxLoop() {
        guard let formatCtx else { return }
        let endOfFileGeneration = currentEndOfFileGeneration()
        FFmpegDemuxLoop.run(
            formatContext: formatCtx,
            streams: FFmpegDemuxLoop.Streams(
                video: { [weak self] in self?.videoStreamIndex ?? -1 },
                audio: { [weak self] in self?.audioStreamIndex ?? -1 },
                subtitlePrimary: { [weak self] in
                    self?.embeddedSubtitlePipeline.streams.primary ?? -1
                },
                subtitleSecondary: { [weak self] in
                    self?.embeddedSubtitlePipeline.streams.secondary ?? -1
                }
            ),
            queues: FFmpegDemuxLoop.Queues(
                video: videoPacketQueue,
                audio: audioPacketQueue,
                subtitlePrimary: embeddedSubtitlePipeline.queues.primary,
                subtitleSecondary: embeddedSubtitlePipeline.queues.secondary
            ),
            isCancelled: { [weak self] in self?.isCancelled ?? true },
            shouldThrottle: { [weak self] in self?.shouldThrottleDemuxForStoppedPlayback() ?? false },
            ioTimeoutSeconds: { [weak self] in self?.demuxIOTimeoutSeconds ?? 0 },
            lastProgressWall: { [weak self] in self?.demuxLastProgressWall ?? 0 },
            onReadEntered: { [weak self] in self?.demuxReadCount &+= 1 },
            onReadReturned: { [weak self] in self?.demuxReturnCount &+= 1 },
            onProgress: { [weak self] in self?.demuxLastProgressWall = CACurrentMediaTime() },
            onReadError: { [weak self] result in
                guard let self else { return }
                let message = "Stream read error: \(Self.ffmpegError(result))"
                Self.logger.error("\(message, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(message)
                }
            },
            onEOF: { [weak self] in
                Self.logger.info("av_read_frame returned EOF")
                DispatchQueue.main.async { [weak self] in
                    self?.noteInputEndOfFile(generation: endOfFileGeneration)
                }
            }
        )
    }

    private func shouldThrottleDemuxForStoppedPlayback() -> Bool {
        guard playbackClock.rate == 0, !isCancelled else { return false }
        if videoStreamIndex >= 0 {
            let videoBacklog = videoPacketQueue.bytes + decodedVideoFrameCount() * 4 * 1024 * 1024
            if videoBacklog < 48 * 1024 * 1024 { return false }
        }
        if audioStreamIndex >= 0, audioOutput.bufferedDurationSeconds < 1.0 {
            return false
        }
        return true
    }

    // MARK: - Video decode feed
    //
    // Split design: a decode loop pulls packets, hands them to VT, and the
    // VT async handler appends decoded frames to `videoFrameScheduler`. The
    // display link tick then peeks/pops that queue to drive `enqueue` onto
    // the display layer at vsync cadence. The layer is driven by its own
    // `controlTimebase`, not by the synchronizer.
    //
    // We keep the display link start on main. The decode loop runs on
    // `videoFeedQueue` (same serial queue we used pre-rewrite for enqueue
    // safety); with the new push model, enqueue happens on main inside the
    // display link tick, so this queue is now "decode-only". It stays serial
    // so the `avformat_seek_file` / `avcodec_flush_buffers` barriers keep
    // working — draining `videoFeedQueue.sync {}` still blocks until the
    // decode loop exits.

    private func startVideoFeed(resumeDisplayLink: Bool = true) {
        if resumeDisplayLink {
            DispatchQueue.main.async { [weak self] in
                self?.setVideoDisplayTickPaused(false)
            }
        }
        // Spin up the packet-consuming decode loop. Self-reschedules nothing;
        // runs until cancel or EOF sentinel.
        videoFeedQueue.async { [weak self] in
            guard let self else { return }
            while !self.isCancelled {
                // Backpressure: park on the condition while the decoded
                // queue is at or above the feed threshold. The display-link
                // tick (and drain/cancel paths) broadcast when frames leave
                // the queue or playback is torn down. Threshold is strictly
                // less than the queue cap so already-submitted VT decodes
                // can land their async output without triggering overflow.
                guard self.videoFrameScheduler.waitUntilBelowFeedBackpressure(
                    isCancelled: { self.isCancelled }
                ) else { return }
                let maybePkt = self.videoPacketQueue.dequeue()
                guard let pkt = maybePkt else {
                    // EOF sentinel — flush any frames still parked inside
                    // FFmpeg's frame-threading pipeline (up to ~thread_count
                    // of them; without this the file's tail never displays),
                    // then exit. The display link keeps ticking so decoded
                    // frames still drain.
                    if self.videoDecodeMode == .software {
                        self.drainSoftwareVideoDecoder()
                    }
                    return
                }
                self.decodeVideoPacket(pkt)
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                av_packet_free(&p)
            }
        }
    }

    private func decodeVideoPacket(_ pkt: UnsafeMutablePointer<AVPacket>) {
        if videoDecodeMode == .software {
            decodeSoftwareVideoPacket(pkt)
            return
        }
        decodeRecoveryLock.lock()
        let doRebuild = decoderRebuildPending
        // A rebuild recreates the VT session outright, which supersedes a
        // pending burst resync — running both in one pass would reset the
        // freshly-rebuilt decoder a second time. Drop the stale resync.
        if doRebuild { pendingDecodeBurstResync = false }
        let doResync = !doRebuild && pendingDecodeBurstResync
        decodeRecoveryLock.unlock()
        if doRebuild {
            rebuildDecoderAfterInvalidSession()
        } else if doResync {
            performDecodeBurstResync()
        }
        guard let fd = videoFormatDescription,
              videoToolboxDecoder.isInstalled
        else { return }

        let rawSize = Int(pkt.pointee.size)
        guard rawSize > 0, let rawData = pkt.pointee.data else { return }

        // Profile 4/7 filter: strip EL + DV-RPU NAL units before VT sees them.
        // Returns (data, size, needsFree=true) for filtered buffers; caller
        // must free. For non-filtering paths, returns the input unchanged with
        // needsFree=false.
        let lengthSize = isConvertNALSize ? 3 : 4
        let filtered: (ptr: UnsafeMutablePointer<UInt8>, size: Int, free: Bool)
        if shouldStripHevcEnhancement {
            filtered = CompressedVideoSampleBuilder.stripHevcEnhancementLayer(
                data: rawData, size: rawSize,
                lengthSize: lengthSize,
                counter: &strippedNalCount)
        } else {
            filtered = (rawData, rawSize, false)
        }
        defer {
            if filtered.free {
                filtered.ptr.deallocate()
            }
        }
        let data = filtered.ptr
        let size = filtered.size
        guard size > 0 else { return }

        let decoderReset = decoderResetSnapshot()
        let resetDecoderBeforeDecoding = decoderReset.armed
        let outcome = compressedVideoPipeline.submitPacket(
            packet: pkt,
            data: data,
            size: size,
            formatDescription: fd,
            timeBase: videoTimeBase,
            useUntimedSamples: useUntimedCompressedVideoSamples,
            preferredLengthSize: lengthSize,
            isH264: currentVideoCodecIsH264(),
            resetDecoderBeforeDecoding: resetDecoderBeforeDecoding,
            requiresRandomAccessForDecoderReset: currentVideoCodecRequiresRandomAccessForDecoderReset(),
            decoder: videoToolboxDecoder,
            isCancelled: { [weak self] in self?.isCancelled ?? true },
            outputHandler: { [weak self] status, infoFlags, imageBuffer, pts, rawPacketSize in
                guard let self else { return }
                guard !self.isCancelled else { return }
                if status != noErr {
                    Self.logger.error("VT decode status=\(status)")
                    self.totalDecodeErrors &+= 1
                    Self.logMilestoneIfNeeded(
                        kind: "VT decode error", status: status,
                        count: self.totalDecodeErrors)
                    self.recordDecodeFailure(
                        status: status,
                        canRebuildInline: false,
                        ptsSeconds: pts.seconds,
                        packetSize: rawPacketSize)
                    return
                }
                if infoFlags.contains(.frameDropped) {
                    self.totalVtFrameDrops &+= 1
                    Self.logMilestoneIfNeeded(
                        kind: "VT frameDropped", status: 0,
                        count: self.totalVtFrameDrops)
                }
                guard !infoFlags.contains(.frameDropped),
                      let imageBuffer else { return }
                self.decodeRecoveryLock.lock()
                self.consecutiveDecodeFailures = 0
                self.noteDecodeSuccessForBurstRecoveryLocked()
                self.decodeRecoveryLock.unlock()
                self.handleDecodedVideoFrame(imageBuffer, pts: pts)
            })
        guard let outcome else { return }
        if outcome.decoderResetApplied {
            clearDecoderReset(ifGeneration: decoderReset.generation)
        }
        if case .submitFailed(let status) = outcome.submission {
            Self.logger.error("VTDecompressionSessionDecodeFrame failed: \(status)")
            totalDecodeErrors &+= 1
            Self.logMilestoneIfNeeded(
                kind: "VT submit error", status: status,
                count: totalDecodeErrors)
            recordDecodeFailure(
                status: status,
                canRebuildInline: true,
                ptsSeconds: outcome.pts.seconds,
                packetSize: outcome.rawPacketSize)
        }
    }

    private func decodeSoftwareVideoPacket(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard let ctx = videoCodecCtx else { return }

        let sendR = avcodec_send_packet(ctx, pkt)
        if sendR < 0 && sendR != Self.ffmpegEAGAIN {
            Self.logger.warning("software video send failed: \(Self.ffmpegError(sendR), privacy: .public)")
            return
        }

        receiveSoftwareVideoFrames(from: ctx)
    }

    /// Pop every frame FFmpeg has ready and hand each to the enqueue path.
    /// Shared by the per-packet decode and the end-of-file drain; loops until
    /// `avcodec_receive_frame` reports empty (EAGAIN or EOF).
    private func receiveSoftwareVideoFrames(from ctx: UnsafeMutablePointer<AVCodecContext>) {
        while true {
            guard let frame = av_frame_alloc() else { return }
            let recvR = avcodec_receive_frame(ctx, frame)
            if recvR < 0 {
                var f: UnsafeMutablePointer<AVFrame>? = frame
                av_frame_free(&f)
                return
            }
            autoreleasepool {
                enqueueSoftwareVideoFrame(frame)
            }
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }
    }

    /// End-of-file flush for the software decoder. With frame threading on,
    /// the decoder keeps up to ~thread_count decoded-but-unreturned frames
    /// in flight; sending the flush packet (nil) releases them. Runs on
    /// `videoFeedQueue` like all software decode. A seek afterwards still
    /// works: `performSeek` calls `avcodec_flush_buffers`, which resets
    /// FFmpeg's draining state.
    private func drainSoftwareVideoDecoder() {
        guard let ctx = videoCodecCtx else { return }
        // A repeated drain (e.g. feed restarted and hit the sentinel again)
        // returns AVERROR_EOF from send; the receive loop below then just
        // reports empty. No need to special-case it.
        _ = avcodec_send_packet(ctx, nil)
        receiveSoftwareVideoFrames(from: ctx)
    }

    private func enqueueSoftwareVideoFrame(_ frame: UnsafeMutablePointer<AVFrame>) {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return }

        let noPts = Int64.min
        let ptsRaw: Int64 = {
            let best = frame.pointee.best_effort_timestamp
            if best != noPts { return best }
            let p = frame.pointee.pts
            if p != noPts { return p }
            return 0
        }()
        let ptsSeconds = Double(ptsRaw) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
        if pendingSkipBelowPTS > 0,
           ptsSeconds.isFinite,
           ptsSeconds < pendingSkipBelowPTS - 0.005 {
            skippedPreTargetVideoFrames &+= 1
            return
        }
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)

        // >8-bit sources (10-bit VP9/AV1, 12-bit profiles) convert to P010
        // so the extra depth — and any PQ/HLG transfer attachment — survives
        // to the display layer instead of being truncated to 8-bit BGRA. On
        // any failure this returns nil and we fall through to the 8-bit
        // paths below: a degraded picture beats a black screen.
        if VideoColorMetadata.sourceBitDepth(AVPixelFormat(rawValue: frame.pointee.format)) > 8,
           let pixelBuffer = makeHighBitDepthBiPlanarPixelBuffer(from: frame, width: width, height: height) {
            attachSoftwareVideoColorMetadata(to: pixelBuffer, frame: frame)
            handleDecodedVideoFrame(pixelBuffer, pts: pts)
            return
        }

        if let pixelBuffer = makePlanarYUVPixelBuffer(from: frame, width: width, height: height) {
            attachSoftwareVideoColorMetadata(to: pixelBuffer, frame: frame)
            handleDecodedVideoFrame(pixelBuffer, pts: pts)
            return
        }

        let attrs: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            Self.logger.error("software video pixel buffer create failed: \(createStatus)")
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)
        videoSwsCtx = sws_getCachedContext(
            videoSwsCtx,
            Int32(width),
            Int32(height),
            srcFormat,
            Int32(width),
            Int32(height),
            AV_PIX_FMT_BGRA,
            SWS_BILINEAR,
            nil,
            nil,
            nil
        )
        guard let sws = videoSwsCtx else { return }

        var srcData = withUnsafeBytes(of: frame.pointee.data) { raw -> [UnsafePointer<UInt8>?] in
            raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).map { ptr in
                ptr.map { UnsafePointer($0) }
            }
        }
        var srcLinesize = withUnsafeBytes(of: frame.pointee.linesize) { raw -> [Int32] in
            raw.bindMemory(to: Int32.self).map { $0 }
        }
        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            baseAddress.assumingMemoryBound(to: UInt8.self),
            nil, nil, nil,
            nil, nil, nil, nil,
        ]
        var dstLinesize: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRow(pixelBuffer)),
            0, 0, 0,
            0, 0, 0, 0,
        ]
        let scaled = srcData.withUnsafeMutableBufferPointer { srcDataBP in
            srcLinesize.withUnsafeMutableBufferPointer { srcLineBP in
                dstData.withUnsafeMutableBufferPointer { dstDataBP in
                    dstLinesize.withUnsafeMutableBufferPointer { dstLineBP in
                        sws_scale(
                            sws,
                            srcDataBP.baseAddress,
                            srcLineBP.baseAddress,
                            0,
                            Int32(height),
                            dstDataBP.baseAddress,
                            dstLineBP.baseAddress
                        )
                    }
                }
            }
        }
        guard scaled == Int32(height) else {
            Self.logger.warning("software video scale produced \(scaled) rows, expected \(height)")
            return
        }

        attachSoftwareVideoColorMetadata(to: pixelBuffer, frame: frame)
        handleDecodedVideoFrame(pixelBuffer, pts: pts)
    }

    /// Convert a >8-bit decoded frame (e.g. dav1d/libvpx emit 10-bit as
    /// YUV420P10LE) into a P010-layout biplanar CVPixelBuffer: plane 0 is
    /// 16-bit luma (10 significant MSBs), plane 1 is interleaved CbCr.
    /// FFmpeg's `AV_PIX_FMT_P010LE` memory layout matches
    /// `kCVPixelFormatType_420YpCbCr10BiPlanar(Video|Full)Range` exactly, so
    /// sws_scale writes straight into the locked planes. Returns nil on any
    /// failure so the caller falls through to the 8-bit paths.
    private func makeHighBitDepthBiPlanarPixelBuffer(
        from frame: UnsafeMutablePointer<AVFrame>,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        let outputFormat = VideoColorMetadata.highBitDepthOutputPixelFormat(
            fullRange: VideoColorMetadata.isFullRange(
                frame.pointee.color_range,
                fallbackName: resolvedVideoColorRange
            ))
        let attrs: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            outputFormat,
            attrs,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            Self.logger.error("software 10-bit pixel buffer create failed: \(createStatus)")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)
        videoSwsCtx = sws_getCachedContext(
            videoSwsCtx,
            Int32(width),
            Int32(height),
            srcFormat,
            Int32(width),
            Int32(height),
            AV_PIX_FMT_P010LE,
            SWS_BILINEAR,
            nil,
            nil,
            nil
        )
        guard let sws = videoSwsCtx else { return nil }

        var srcData = withUnsafeBytes(of: frame.pointee.data) { raw -> [UnsafePointer<UInt8>?] in
            raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).map { ptr in
                ptr.map { UnsafePointer($0) }
            }
        }
        var srcLinesize = withUnsafeBytes(of: frame.pointee.linesize) { raw -> [Int32] in
            raw.bindMemory(to: Int32.self).map { $0 }
        }
        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            lumaBase.assumingMemoryBound(to: UInt8.self),
            chromaBase.assumingMemoryBound(to: UInt8.self),
            nil, nil,
            nil, nil, nil, nil,
        ]
        var dstLinesize: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)),
            0, 0,
            0, 0, 0, 0,
        ]
        let scaled = srcData.withUnsafeMutableBufferPointer { srcDataBP in
            srcLinesize.withUnsafeMutableBufferPointer { srcLineBP in
                dstData.withUnsafeMutableBufferPointer { dstDataBP in
                    dstLinesize.withUnsafeMutableBufferPointer { dstLineBP in
                        sws_scale(
                            sws,
                            srcDataBP.baseAddress,
                            srcLineBP.baseAddress,
                            0,
                            Int32(height),
                            dstDataBP.baseAddress,
                            dstLineBP.baseAddress
                        )
                    }
                }
            }
        }
        guard scaled == Int32(height) else {
            Self.logger.warning("software 10-bit scale produced \(scaled) rows, expected \(height)")
            return nil
        }
        return pixelBuffer
    }

    private func makePlanarYUVPixelBuffer(
        from frame: UnsafeMutablePointer<AVFrame>,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)
        guard srcFormat == AV_PIX_FMT_YUV420P || srcFormat == AV_PIX_FMT_YUVJ420P else {
            return nil
        }
        guard let yPlane = frame.pointee.data.0,
              let uPlane = frame.pointee.data.1,
              let vPlane = frame.pointee.data.2 else {
            return nil
        }

        let pixelFormat = VideoColorMetadata.isFullRange(
            frame.pointee.color_range,
            fallbackName: resolvedVideoColorRange
        )
            ? kCVPixelFormatType_420YpCbCr8PlanarFullRange
            : kCVPixelFormatType_420YpCbCr8Planar
        let attrs: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        func copyPlane(
            index: Int,
            source: UnsafeMutablePointer<UInt8>,
            sourceStride: Int32,
            copyWidth: Int,
            copyHeight: Int
        ) {
            guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index) else { return }
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
            let dst = destination.assumingMemoryBound(to: UInt8.self)
            let rowBytes = min(copyWidth, destinationStride, Int(sourceStride))
            for row in 0..<copyHeight {
                dst.advanced(by: row * destinationStride)
                    .initialize(from: source.advanced(by: row * Int(sourceStride)), count: rowBytes)
            }
        }

        copyPlane(index: 0, source: yPlane, sourceStride: frame.pointee.linesize.0,
                  copyWidth: width, copyHeight: height)
        copyPlane(index: 1, source: uPlane, sourceStride: frame.pointee.linesize.1,
                  copyWidth: (width + 1) / 2, copyHeight: (height + 1) / 2)
        copyPlane(index: 2, source: vPlane, sourceStride: frame.pointee.linesize.2,
                  copyWidth: (width + 1) / 2, copyHeight: (height + 1) / 2)
        return pixelBuffer
    }

    private func attachSoftwareVideoColorMetadata(
        to pixelBuffer: CVPixelBuffer,
        frame: UnsafeMutablePointer<AVFrame>
    ) {
        if let cp = VideoColorMetadata.colorPrimariesString(frame.pointee.color_primaries) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                cp,
                .shouldPropagate
            )
        }
        if let tf = VideoColorMetadata.transferFunctionString(frame.pointee.color_trc) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                tf,
                .shouldPropagate
            )
        }
        if let mx = VideoColorMetadata.ycbcrMatrixString(frame.pointee.colorspace) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                mx,
                .shouldPropagate
            )
        }
    }

    /// Print a one-liner at exponentially-spaced milestones (1, 30, 100,
    /// 1000, 10000). OSLog warnings from VT don't reach `devicectl --console`
    /// on tvOS, so we have to surface these manually to stdout if we ever want
    /// to correlate a user-visible stall with decode behavior.
    private static func logMilestoneIfNeeded(
        kind: String, status: OSStatus, count: UInt64
    ) {
        switch count {
        case 1, 30, 100, 1000, 10_000:
            print("[CMP] \(kind) status=\(status) count=\(count)")
        default:
            break
        }
    }

    private func currentVideoCodecIsH264() -> Bool {
        if let fd = videoFormatDescription,
           CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_H264 {
            return true
        }
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecpar = stream.pointee.codecpar else {
            return false
        }
        return codecpar.pointee.codec_id == AV_CODEC_ID_H264
    }

    private func currentVideoCodecIsHEVC() -> Bool {
        if let fd = videoFormatDescription,
           CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC {
            return true
        }
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecpar = stream.pointee.codecpar else {
            return false
        }
        return codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
    }

    private func currentVideoCodecRequiresRandomAccessForDecoderReset() -> Bool {
        if let fd = videoFormatDescription {
            let subtype = CMFormatDescriptionGetMediaSubType(fd)
            if subtype == kCMVideoCodecType_H264 || subtype == kCMVideoCodecType_HEVC {
                return true
            }
        }
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecpar = stream.pointee.codecpar else {
            return false
        }
        let codecId = codecpar.pointee.codec_id
        return codecId == AV_CODEC_ID_H264 || codecId == AV_CODEC_ID_HEVC
    }

    private func currentVideoCodecIsProRes() -> Bool {
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecpar = stream.pointee.codecpar else {
            return false
        }
        return codecpar.pointee.codec_id == AV_CODEC_ID_PRORES
    }

    private func switchCurrentVideoToSoftwareDecoder(reason: String) -> Bool {
        guard let formatCtx,
              videoStreamIndex >= 0,
              let stream = formatCtx.pointee.streams?[Int(videoStreamIndex)],
              let codecparPtr = stream.pointee.codecpar else {
            return false
        }
        let codecpar = codecparPtr.pointee
        print("[CMP] VideoToolbox fallback -> software codec=\(Self.codecName(for: codecpar.codec_id) ?? "unknown") reason=\(reason)")
        videoToolboxDecoder.invalidate()
        if videoCodecCtx != nil {
            avcodec_free_context(&videoCodecCtx)
        }
        if videoSwsCtx != nil {
            sws_freeContext(videoSwsCtx)
            videoSwsCtx = nil
        }
        videoDecodeMode = .software
        useUntimedCompressedVideoSamples = false
        let ok = setupSoftwareVideoDecoder(codecpar: codecpar, codecparPtr: codecparPtr)
        #if os(iOS) || os(tvOS)
        // Losing hardware decode is the difference between a smooth 4K
        // session and a thermally throttled one, so the switch is recorded
        // even when it succeeds. `reason` carries the VT status that forced
        // it; the attributes re-state the pipeline because `decoder` (and
        // possibly the pixel format behind `fmt`) just changed underneath the
        // load-time breadcrumb.
        var attrs = videoPipelineAttributes()
        attrs["reason"] = .string(reason)
        DiagTrace.breadcrumb(
            .essential,
            level: ok ? .warning : .error,
            category: .playback,
            tag: "Player",
            message: ok ? "decoder fell back to software" : "software decoder fallback failed",
            attrs: attrs
        )
        #endif
        return ok
    }

    private func reportTerminalDecodeFailure(_ message: String) {
        decodeRecoveryLock.lock()
        if hasReportedDecodeFailure {
            decodeRecoveryLock.unlock()
            return
        }
        hasReportedDecodeFailure = true
        let failures = consecutiveDecodeFailures
        decodeRecoveryLock.unlock()
        print("[CMP] ERROR: \(message) (consecutiveFailures=\(failures))")
        #if os(iOS) || os(tvOS)
        // This path deliberately bypasses `reportError` (it owns its own
        // once-only latch and failure tally), so it needs its own terminal
        // breadcrumb or the bundle would show the decode burst's recovery
        // attempts with no record of the outcome that ended playback.
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "Player",
            message: "decode failed terminally",
            attrs: [
                "reason": .string("decode_failures_exhausted"),
                "decoder": .string(videoDecodeMode == .software ? "software" : "videotoolbox"),
                "dropped_frames": .int(Int(clamping: vSyncDrops &+ totalVtFrameDrops)),
                "position_ms": .int(Self.positionMilliseconds(lastReportedSeconds)),
            ]
        )
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    /// Surfaces a VT decode error to `onError` if we've hit the threshold
    /// without ever producing a decoded frame. Prevents the "loading spinner
    /// forever" failure mode when VT can't decode the stream (e.g., tvOS
    /// simulator refusing HEVC, or malformed hvcC extradata from the
    /// container).
    ///
    /// Special-cases `kVTInvalidSessionErr` (-12903) — the VT decoder session
    /// gets invalidated by system interruptions (app background/foreground,
    /// audio-session interruption, audio-route change). The session itself
    /// is now permanently dead; `flush()` won't bring it back. We rebuild it
    /// in place instead of surfacing a fatal error. The submit path can do
    /// that inline on `videoFeedQueue`; the async output callback just marks
    /// the rebuild pending so the feed loop performs it before the next
    /// packet submission.
    private func rebuildDecoderAfterInvalidSession() {
        decodeRecoveryLock.lock()
        decoderRebuildPending = false
        decodeRecoveryLock.unlock()
        print("[CMP] decoder rebuild: tearing down + recreating after kVTInvalidSessionErr")
        videoToolboxDecoder.invalidate()
        let ok = createDecompressionSession()
        print("[CMP] decoder rebuild: \(ok ? "succeeded" : "FAILED")")
        // Reset counters so a second invalidation later in the session can
        // also trigger a rebuild instead of being stuck behind stale state.
        decodeRecoveryLock.lock()
        consecutiveDecodeFailures = 0
        hasReportedDecodeFailure = false
        isRebuildingDecoder = false
        decodeRecoveryLock.unlock()
    }

    /// Flush VideoToolbox and arm a decoder reset so playback resyncs at the
    /// next random-access frame (IDR), riding out a `-12909` bad-data burst
    /// without leaving the CoreMedia decoder. Mirrors the post-seek
    /// discontinuity path: drain async decodes, skip the broken GOP tail, reset
    /// VT at the next IDR via `ResetDecoderBeforeDecoding`, and widen the
    /// renderer's late-frame tolerance so it resyncs to the audio clock at the
    /// resume point. We deliberately do not recreate the VT session here — the
    /// reset attachment clears VT's stale references, and skipping a session
    /// recreate keeps this path failure-free. Runs on `videoFeedQueue`.
    private func performDecodeBurstResync() {
        decodeRecoveryLock.lock()
        pendingDecodeBurstResync = false
        decodeRecoveryLock.unlock()
        flushVideoDecoderAfterDiscontinuity()
        armDecoderReset()
        postDiscontinuityWallDeadline =
            CACurrentMediaTime() + Self.postDiscontinuityWindowSeconds
        // Clear failure state only after the async drain above, so the
        // in-flight failed callbacks counted during the flush don't leave a
        // stale tally that immediately re-trips the threshold.
        decodeRecoveryLock.lock()
        consecutiveDecodeFailures = 0
        hasReportedDecodeFailure = false
        isRecoveringDecodeBurst = false
        decodeRecoveryLock.unlock()
    }

    /// Refreshes the `-12909` recovery attempt budget once enough frames have
    /// decoded cleanly after a resync, so a later unrelated burst gets a fresh
    /// set of attempts. Runs on VT's callback thread alongside
    /// `consecutiveDecodeFailures` (same serialization).
    /// Caller must hold `decodeRecoveryLock`.
    private func noteDecodeSuccessForBurstRecoveryLocked() {
        guard decodeBurstRecoveryAttempts > 0 else { return }
        framesDecodedSinceRecovery += 1
        guard framesDecodedSinceRecovery >= Self.decodeBurstRecoveryStableFrames else { return }
        print("[CMP] VT bad-data recovery confirmed stable after "
            + "\(framesDecodedSinceRecovery) frames; resetting attempt budget")
        decodeBurstRecoveryAttempts = 0
        framesDecodedSinceRecovery = 0
    }

    private func currentDecodeFailureRecoveryCodec() -> DecodeFailureRecoveryPolicy.Codec {
        if currentVideoCodecIsH264() {
            return .h264
        }
        if currentVideoCodecIsHEVC() {
            return .hevc
        }
        return .other
    }

    private func recordDecodeFailure(
        status: OSStatus,
        canRebuildInline: Bool,
        ptsSeconds: Double = .nan,
        packetSize: Int = 0
    ) {
        // The recovery state machine is shared between VT's async output
        // callback thread and `videoFeedQueue` (submit failures), so the
        // increment + decision must be atomic. Decide under the lock, then run
        // any blocking decoder work after releasing it — `performDecodeBurst-
        // Resync`/`rebuildDecoderAfterInvalidSession` drain async frames that
        // re-enter here on the callback thread, so holding the lock across them
        // would deadlock.
        decodeRecoveryLock.lock()
        consecutiveDecodeFailures += 1
        let failures = consecutiveDecodeFailures
        // Snapshot pre-decision flag state for the diagnostic log below.
        let recoveryAttemptsSnapshot = decodeBurstRecoveryAttempts
        let rebuildPendingSnapshot = decoderRebuildPending
        let isRebuildingSnapshot = isRebuildingDecoder
        let recoveryCodec = currentDecodeFailureRecoveryCodec()

        let action = decideDecodeFailureActionLocked(
            status: status,
            canRebuildInline: canRebuildInline,
            failures: failures,
            recoveryCodec: recoveryCodec
        )
        decodeRecoveryLock.unlock()

        // Targeted diagnostic for the end-of-file `-8969` burst investigation.
        // Prints once at the start of a burst and once right before we trip
        // the user-visible threshold so we see the stream position + decoder
        // state when VT starts choking, without flooding the log with 70+
        // lines per burst. Built after unlocking (it reads the frame
        // scheduler, which has its own lock). Remove once the root cause is
        // nailed down.
        if failures == 1 || failures == 30 {
            let marker = failures == 1 ? "first" : "threshold"
            let pts = ptsSeconds.isFinite ? String(format: "%.3f", ptsSeconds) : "nan"
            let clock = String(format: "%.3f", lastReportedSeconds)
            let dur = String(format: "%.3f", durationSeconds)
            let wall = String(format: "%.3f", CACurrentMediaTime())
            let postSeekWindow = CACurrentMediaTime() < postDiscontinuityWallDeadline
            let line =
                "[CMP-DECODE-FAIL] \(marker) status=\(status) "
                + "pts=\(pts)s clock=\(clock)s dur=\(dur)s "
                + "pktSize=\(packetSize) "
                + "totalErrors=\(self.totalDecodeErrors) strippedNal=\(self.strippedNalCount) "
                + "vtIn=\(self.videoToolboxInFlightCount()) vDec=\(self.videoFrameScheduler.count) "
                + "recovery=\(recoveryAttemptsSnapshot)/\(Self.maxDecodeBurstRecoveryAttempts) "
                + "rebuildPending=\(rebuildPendingSnapshot) "
                + "isRebuilding=\(isRebuildingSnapshot) "
                + "convertNALSize=\(self.isConvertNALSize) stripHEVC=\(self.shouldStripHevcEnhancement) "
                + "postSeekWindow=\(postSeekWindow) "
                + "wall=\(wall)"
            Self.logger.error("\(line, privacy: .public)")
        }

        switch action {
        case .none:
            break
        case .burstResyncInline:
            performDecodeBurstResync()
        case .rebuildInline:
            rebuildDecoderAfterInvalidSession()
        case .reportUnsupported(let reason, let url):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onUnsupportedStream?(
                    reason,
                    url,
                    self.lastLoadHeaders,
                    self.lastLoadStartTime
                )
            }
        case .terminal(let message):
            reportTerminalDecodeFailure(message)
        }
    }

    /// Runs the decode-failure state machine. Caller must hold
    /// `decodeRecoveryLock`; this only mutates recovery flags and returns the
    /// (possibly blocking) work for the caller to perform after unlocking.
    private func decideDecodeFailureActionLocked(
        status: OSStatus,
        canRebuildInline: Bool,
        failures: Int,
        recoveryCodec: DecodeFailureRecoveryPolicy.Codec
    ) -> DecodeFailureAction {
        // A -12909 resync is already scheduled or draining: swallow the failures
        // that pour out of the broken GOP tail so they don't fall through to the
        // failover/terminal paths below. Cleared by `performDecodeBurstResync()`.
        if isRecoveringDecodeBurst,
           DecodeFailureRecoveryPolicy.shouldAttemptBurstResync(
               status: status,
               codec: recoveryCodec,
               attempts: 0,
               maxAttempts: 1
           ) {
            return .none
        }

        // kVTInvalidSessionErr: rebuild the decoder in place. Threshold-gated
        // (same 30-failure threshold the user-facing error uses) so we don't
        // thrash on a single transient packet error — invalidations from real
        // interruptions cascade across many packets, easily clearing the bar.
        if status == -12903 && failures >= 30 {
            if canRebuildInline {
                if decoderRebuildPending || !isRebuildingDecoder {
                    isRebuildingDecoder = true
                    return .rebuildInline
                }
                return .none
            }
            guard !isRebuildingDecoder else { return .none }
            isRebuildingDecoder = true
            decoderRebuildPending = true
            return .none
        }

        // ~30 failures ≈ 1 second at ~30fps. Low enough to feel responsive,
        // high enough to tolerate occasional reference-frame dependency
        // errors after a seek.
        guard failures >= 30, !hasReportedDecodeFailure else { return .none }

        // In-place recovery for a recoverable bad-data burst, before we
        // abandon the CoreMedia decoder. Flush and resync at the next IDR
        // instead of crashing on a local reference-frame cascade. Bounded so a
        // genuinely undecodable region still falls through to the
        // terminal/fallback paths below.
        if DecodeFailureRecoveryPolicy.shouldAttemptBurstResync(
            status: status,
            codec: recoveryCodec,
            attempts: decodeBurstRecoveryAttempts,
            maxAttempts: Self.maxDecodeBurstRecoveryAttempts
        ) {
            isRecoveringDecodeBurst = true
            decodeBurstRecoveryAttempts += 1
            framesDecodedSinceRecovery = 0
            print("[CMP] \(recoveryCodec.logLabel) VT bad-data burst: in-place resync attempt "
                + "\(decodeBurstRecoveryAttempts)/\(Self.maxDecodeBurstRecoveryAttempts) "
                + "status=\(status) "
                + "canRebuildInline=\(canRebuildInline)")
            if canRebuildInline {
                return .burstResyncInline
            }
            pendingDecodeBurstResync = true
            return .none
        }

        if Self.isH264BadDataStatus(status), currentVideoCodecIsH264() {
            if let url = lastLoadURL {
                print("[CMP] H264 VT bad-data threshold reached; rejecting direct decode status=\(status)")
                hasReportedDecodeFailure = true
                return .reportUnsupported(.videoToolboxBadDataH264, url)
            }
            return .terminal("H.264 decode failed after VideoToolbox rejected compressed samples.")
        }

        if status == -12909, currentVideoCodecIsHEVC() {
            if let url = lastLoadURL {
                print("[CMP] HEVC VT bad-data threshold reached; rejecting direct decode status=\(status)")
                hasReportedDecodeFailure = true
                return .reportUnsupported(.videoToolboxBadDataHEVC, url)
            }
            return .terminal("HEVC decode failed after VideoToolbox rejected compressed samples.")
        }

        switch status {
        case -12906: return .terminal("Video decoder unavailable (kVTCouldNotFindVideoDecoderErr). The tvOS simulator has limited HEVC support — try on an Apple TV 4K.")
        case -12909: return .terminal("Malformed video bitstream (kVTVideoDecoderBadDataErr).")
        case -8969:  return .terminal("Malformed video bitstream (VideoToolbox rejected compressed H.264 samples).")
        case -12911: return .terminal("Video decoder needs new configuration (kVTVideoDecoderNotAvailableNowErr).")
        default:     return .terminal("Video decode failed (\(status)).")
        }
    }

    private static func isH264BadDataStatus(_ status: OSStatus) -> Bool {
        status == -12909 || status == -8969
    }

    /// VT decoder output handler entry. Pushes the decoded frame onto the
    /// thread-safe bounded queue consumed by `videoDisplayLinkTick`. The
    /// sample buffer itself is constructed on-demand in the tick, so this
    /// function is only a short critical section plus a per-first-frame
    /// signpost.
    ///
    /// **PTS-ordered insert (critical for B-frames).** VT delivers frames in
    /// *decode order*, which for H.264/HEVC streams with B-frames is NOT the
    /// same as presentation order. A typical GOP delivers as
    /// `I, P, B, B, B, P, B, B, B, …` with PTSs
    /// `[0, 0.333, 0.083, 0.167, 0.25, 0.666, 0.416, 0.5, 0.583, …]`.
    /// If we FIFO-appended, the display-link tick would peek the head and
    /// see a future PTS (the P frame at 0.333 when the audio clock is at
    /// 0.083), hold it as "too early", and then drop the intermediate Bs as
    /// "too late" when they finally arrive. Net effect: only I+P frames
    /// shown → ~25 % yield → 24 fps source plays back at ~6 fps. Inserting
    /// sorted by PTS keeps the head == next-to-display in presentation
    /// order, which is what `videoDisplayLinkTick`'s sync predicate expects.
    private func handleDecodedVideoFrame(_ imageBuffer: CVImageBuffer, pts: CMTime) {
        guard !isCancelled else { return }
        let ptsSeconds = pts.seconds
        if !hasLoggedFirstDecodedVideoBuffer {
            hasLoggedFirstDecodedVideoBuffer = true
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            cmpLog(String(format:
                "[CMP] firstDecodedBuffer %dx%d pts=%.3f",
                width, height, ptsSeconds))
        }
        // Skip frames from the pre-target keyframe gap. The decoder still
        // processed them (they were needed as B/P reference anchors); we
        // just don't hand them to the display queue.
        if pendingSkipBelowPTS > 0,
           ptsSeconds.isFinite,
           ptsSeconds < pendingSkipBelowPTS - 0.005 {
            skippedPreTargetVideoFrames &+= 1
            return
        }
        videoFrameScheduler.insertSorted(imageBuffer: imageBuffer, pts: pts)

        if !hasFiredFirstFrameSignpost {
            hasFiredFirstFrameSignpost = true
            if #available(iOS 15.0, tvOS 15.0, *) {
                os_signpost(.event, log: Self.signpostLog, name: "FirstFrame",
                            "pts=%.3f", pts.seconds)
            }
            let ttffMs = Int((CFAbsoluteTimeGetCurrent() - ttffLoadAnchor) * 1000)
            Self.logger.info("[CMP-TTFF] route=playerCoreDirect first_frame_ms=\(ttffMs)")
            cmpLog("[CMP-TTFF] route=playerCoreDirect first_frame_ms=\(ttffMs)")
        }
    }

    /// A/V-sync recovery ladder state. Main-only (display tick + the
    /// main.sync blocks of seek/track-switch, which reset it).
    private var avSyncLadder = AVSyncLadder()

    /// Kill switch for the ladder's escalation rungs (the per-frame rung-0
    /// drop is unaffected). Defaults ON in debug builds and OFF in release
    /// until the on-device validation pass; override either way via the
    /// "PlayerAVSyncLadderEnabled" UserDefaults key.
    private let avSyncLadderEnabled: Bool = {
        if let value = UserDefaults.standard.object(forKey: "PlayerAVSyncLadderEnabled") as? Bool {
            return value
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Runs the escalation ladder for a late head frame. Returns true when
    /// a rung fired (the tick must return; the pipeline needs a beat before
    /// re-evaluating), false to fall through to the per-frame drop.
    /// Main thread (display tick).
    private func performAvsyncLadderRecovery(
        diff: Double,
        frameDuration: Double,
        clockSeconds: Double
    ) -> Bool {
        let action = avSyncLadder.evaluate(.init(
            diffSeconds: diff,
            frameDurationSeconds: frameDuration,
            decodedFrameCount: videoFrameScheduler.count,
            packetCount: videoPacketQueue.count,
            wallNow: CACurrentMediaTime()
        ))
        switch action {
        case .none:
            return false
        case .flushDecodedFrames:
            let flushed = videoFrameScheduler.count
            videoFrameScheduler.removeAll(keepingCapacity: true)
            vSyncDrops &+= UInt64(flushed)
            noteAvsyncAction(action)
            print(String(format:
                "[CMP] avsync rung=1 flushDecodedFrames diff=%.3f flushed=%d",
                diff, flushed))
            return true
        case .dropPacketsToNextKeyframe:
            // Arm the reset BEFORE dropping so the feed loop can't submit
            // the post-skip keyframe without the DPB-reset attachment.
            armDecoderReset()
            guard let dropped = videoPacketQueue.dropToNextKeyframe() else {
                // No keyframe in the backlog to skip to — nothing this rung
                // can do; let the per-frame drop keep grinding. The armed
                // reset is harmless (next applied sample consumes it).
                return false
            }
            let flushed = videoFrameScheduler.count
            videoFrameScheduler.removeAll(keepingCapacity: true)
            vSyncDrops &+= UInt64(flushed)
            noteAvsyncAction(action, droppedPacketSeconds: dropped.seconds)
            print(String(format:
                "[CMP] avsync rung=2 dropToNextKeyframe diff=%.3f packets=%d (%.2fs) flushedFrames=%d",
                diff, dropped.count, dropped.seconds, flushed))
            return true
        case .reseekToClock:
            noteAvsyncAction(action)
            print(String(format:
                "[CMP] avsync rung=3 reseekToClock diff=%.3f clock=%.3f",
                diff, clockSeconds))
            seek(to: max(0, clockSeconds))
            return true
        }
    }

    /// CADisplayLink tick — runs on main at display refresh rate. Peeks the
    /// head of `videoFrameScheduler`, decides early/on-time/late against the
    /// interpolated audio clock, and either holds (early), drops (late), or
    /// enqueues one frame onto `displayLayer` via the push path:
    /// `CMSampleBufferCreateReadyWithImageBuffer` + `.zero` PTS +
    /// `DisplayImmediately`. The layer's `controlTimebase` (running at rate
    /// 1.0 against the host clock) paces output; `DisplayImmediately` tells
    /// CoreMedia to show the frame on the next composition pass.
    @objc private func videoDisplayLinkTick() {
        autoreleasepool {
            guard !videoDisplayTickPaused else { return }
            guard !isCancelled, let layer = displayLayer else { return }

            // Hold video display until audio has delivered its first rendered
            // sample and re-anchored the playback clock. Without this hold,
            // video plays forward at display-link rate during the ~50–350 ms
            // decoder-spinup window, then the audio resync pulls the clock
            // back to the first-sample PTS and video is forced to freeze
            // while audio plays through the content video already showed.
            // Holding here keeps decoded frames buffered (up to the queue
            // cap) so the first visible frame aligns with the first audible
            // sample.
            if shouldResyncClockOnFirstAudio { return }

            // Peek + pop under the lock. Minimal critical section; we do the
            // heavy CMSampleBuffer work outside the lock.
            guard let head = videoFrameScheduler.peek() else { return }

            // Video clock sync predicate: hold if too early, drop if way
            // behind, display otherwise. `videoFPS` is pulled from stream
            // info at decode setup; fallback is 24fps.
            let audioSnapshot = audioClockSnapshot()
            let desire = audioSnapshot.current
            let frameSeconds = head.1.seconds
            let diff = frameSeconds.isFinite ? frameSeconds - desire : 0
            let frameDuration = videoFPS > 0 ? 1.0 / videoFPS : 1.0 / 24.0

            // Until the audio clock has been seeded by the engine render
            // callback, skip the sync predicate so we don't stall the very
            // first frames. Once it's set, apply the hold/drop/display logic
            // below.
            if audioSnapshot.hasBeenSet {
                if diff >= frameDuration * 0.5 {
                    // Too early — keep in queue for a later tick.
                    vSyncHolds &+= 1
                    return
                }
                // Behind-threshold:
                //   • Wide (-5.0 s) for `postDiscontinuityWindowSeconds` after
                //     a seek / audio-track switch / openAndDemux. Accommodates
                //     the keyframe gap left by `avformat_seek_file(...,
                //     BACKWARD)`: audioClock is seeded to the requested target
                //     but the first decoded frame sits at the nearest prior
                //     keyframe, so post-seek frames start with `diff ≈
                //     -(target - keyframe)` — up to ~5s for HLS GOPs. A
                //     tighter threshold here drops every post-seek frame and
                //     produces black video until the clocks converge.
                //   • Tight (-2 × frameDuration) during steady-state. Without
                //     this, a transient main-thread stall (e.g. the SwiftUI
                //     focus engine + material blur cost when opening the
                //     player HUD's Subtitles pane) freezes the display link,
                //     audio advances, and the head frame's `diff` drops to
                //     ~-200 ms — well above -5.0, so it gets enqueued late
                //     instead of dropped. Each subsequent tick pops the next
                //     frame, also late, so video falls progressively behind
                //     audio and never catches up. The tight bound forces a
                //     drop-and-recurse loop that skips ahead to a frame near
                //     the current audio clock, restoring sync.
                let inPostDiscontinuityWindow =
                    CACurrentMediaTime() < postDiscontinuityWallDeadline
                let dropThreshold: Double = inPostDiscontinuityWindow
                    ? -5.0
                    : -frameDuration * 2.0
                if diff < dropThreshold {
                    // Escalation ladder for multi-second desync (steady
                    // state only — the post-discontinuity window is the
                    // keyframe gap doing its normal thing). Rung 0, the
                    // per-frame drop below, stays as the base case.
                    if avSyncLadderEnabled, !inPostDiscontinuityWindow,
                       playbackClock.rate > 0,
                       performAvsyncLadderRecovery(diff: diff, frameDuration: frameDuration, clockSeconds: desire) {
                        return
                    }
                    videoFrameScheduler.dropHead()
                    vSyncDrops &+= 1
                    videoDisplayLinkTick()
                    return
                }
            }

            // Pop the frame we're about to display.
            guard let frame = videoFrameScheduler.popHead() else { return }

            let imageBuffer = frame.imageBuffer
            let framePts = frame.pts

            let renderResult = decodedVideoFrameRenderer.render(
                imageBuffer: imageBuffer,
                layer: layer
            )
            let displayLinkEnqueueCount: UInt64
            switch renderResult {
            case .failed(let status):
                Self.logger.error("decoded video render failed: \(status)")
                return
            case .enqueued(let count, let formatChanged, let requiresFlushToResumeDecoding, let rendererFailed):
                displayLinkEnqueueCount = count
                noteSeekFirstFrame()
                if formatChanged {
                    Self.logger.info("format-change detected; flushing display layer")
                }
                if requiresFlushToResumeDecoding {
                    Self.logger.info("displayLayer.requiresFlushToResumeDecoding; flushing")
                }
                if rendererFailed {
                    recoverDisplayLayerIfFailed(reason: "in-enqueue")
                }
            }

            // Milestone logs for debugging the "zero frames reach screen" bug.
            switch displayLinkEnqueueCount {
            case 1:
                onFirstFrame?(max(0, Int((CFAbsoluteTimeGetCurrent() - ttffLoadAnchor) * 1000)))
                Self.logger.info("displayLink: first frame enqueued pts=\(framePts.seconds)")
                print(String(format:
                    "[CMP] firstFrameEnqueued pts=%.3f sync=%.3f rate=%.2f ac.cur=%.3f diff=%.3f frameDur=%.4f videoFPS=%.2f skipped=%llu",
                    framePts.seconds, currentPlaybackTimeSeconds(),
                    Double(playbackClock.rate), desire, diff,
                    frameDuration, videoFPS, skippedPreTargetVideoFrames))
            case 30, 300, 3000:
                Self.logger.info("displayLink: enqueued \(displayLinkEnqueueCount) frames")
            default:
                break
            }

            // Pump the subtitle overlay once per vsync. Cheap on idle
            // frames — libass reports `detect_change == 0` and we skip
            // the compositor. On dirty frames we hop to the session
            // queue for the ~1-4ms composite + back to main to assign
            // the new CGImage to the overlay layer's contents.
            pumpSubtitleOverlay()
        }
    }

    // MARK: - Audio decode feed

    private func startAudioFeed() {
        guard audioStreamIndex >= 0 else { return }
        audioOutput.requestMediaDataWhenReady(on: audioFeedQueue) { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.audioFeedInvocations &+= 1
            while !self.isCancelled, self.audioOutput.isReadyForMoreMediaData {
                let maybePkt = self.audioPacketQueue.dequeue()
                guard let pkt = maybePkt else { return }
                self.decodeAudioPacket(pkt)
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                av_packet_free(&p)
            }
        }
    }

    private func decodeAudioPacket(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard let ctx = audioCodecCtx else { return }
        audioDecodePipeline.decodePacket(
            pkt,
            codecContext: ctx,
            timeBase: audioTimeBase,
            eagain: Self.ffmpegEAGAIN,
            outputForFrame: { [weak self] frame in
                self?.ensureAudioOutputConfigured(from: frame)
            }
        ) { [weak self] decoded in
            guard let self else { return }
            if self.pendingSkipBelowPTS > 0,
               decoded.ptsSeconds.isFinite,
               decoded.ptsSeconds < self.pendingSkipBelowPTS - 0.005 {
                self.skippedPreTargetAudioFrames &+= 1
                return
            }

            self.audioOutput.enqueue(decoded.chunk)
            self.audioEnqueueCount &+= 1
            if self.audioOutput.statusCode == 2 {
                let err = self.audioOutput.lastErrorDescription ?? "nil"
                print("[CMP] audioOutput FAILED after \(self.audioEnqueueCount) enqueues error=\(err)")
                Self.logger.error("audioOutput entered failed state: \(err, privacy: .public)")
            }
            if self.audioEnqueueCount == 1 {
                print(String(format:
                    "[CMP] firstAudioEnqueued pts=%.3f samples=%d outRate=%d channels=%d sync=%.3f rate=%.2f skipped=%llu",
                    decoded.ptsSeconds,
                    Int(decoded.convertedSamples),
                    decoded.chunk.sampleRate,
                    decoded.chunk.channelCount,
                    self.currentPlaybackTimeSeconds(),
                    Double(self.playbackClock.rate),
                    self.skippedPreTargetAudioFrames))
            }
        }
    }

    // MARK: - Subtitle decode

    private func setupSubtitleDecoder(streamIndex: Int32, slot: SubtitleSlot) -> Bool {
        guard let formatCtx else { return false }
        return embeddedSubtitlePipeline.setupDecoder(
            formatContext: formatCtx,
            streamIndex: streamIndex,
            slot: slot,
            session: subtitleSession
        )
    }

    private func startEmbeddedSubtitleFeeds() {
        embeddedSubtitlePipeline.startFeed(
            slot: .primary,
            session: subtitleSession,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
        embeddedSubtitlePipeline.startFeed(
            slot: .secondary,
            session: subtitleSession,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
    }

    /// Control-queue counterpart to `performAudioTrackSwitch`. Tears
    /// down the current subtitle decoder in the given slot and
    /// optionally opens a new one. Video + audio keep playing.
    private func performSubtitleTrackSwitch(newId: Int64?, slot: SubtitleSlot) {
        // Live AI path: the track is a synthetic in-memory libass track
        // already installed (and being fed cues) by `openLiveSubtitleTrack`.
        // Selecting it is a no-op — it stays installed and visible; there
        // is no decoder to spin up and no fetch to start. Must be checked
        // BEFORE the sidecar branch (the id ranges are disjoint, but the
        // intent is explicit: never tear down or re-open a live track on
        // selection).
        if let newId, SubtitleTrackIdSpace.isAILive(newId) {
            embeddedSubtitlePipeline.tearDownEmbeddedSlot(slot: slot)
            runtimeSubtitleExtractor?.stopFeeding(slot: slot)
            return
        }

        // Sidecar path: trackId >= sidecarBase means the user picked a
        // server-provided URL, not an embedded stream. Route to the
        // session and tear down any embedded decoder we had open in
        // this slot.
        if let newId, SubtitleTrackIdSpace.isSidecar(newId) {
            embeddedSubtitlePipeline.tearDownEmbeddedSlot(slot: slot)
            runtimeSubtitleExtractor?.stopFeeding(slot: slot)
            let idx = SubtitleTrackIdSpace.sidecarIndex(from: newId)
            subtitleSession?.openSidecar(urlIndex: idx, slot: slot)
            return
        }

        embeddedSubtitlePipeline.tearDownEmbeddedSlot(slot: slot)
        runtimeSubtitleExtractor?.stopFeeding(slot: slot)

        guard let formatCtx, let newId else {
            // No new track — user disabled subtitles in this slot.
            subtitleSession?.closeSlot(slot)
            return
        }

        let candidate = Int32(newId)
        if candidate < 0 || candidate >= Int32(formatCtx.pointee.nb_streams) {
            subtitleSession?.closeSlot(slot)
            return
        }

        // Runtime enable goes through the dedicated extractor, not the
        // in-band pipeline: the main demuxer has already read (and, with
        // the stream unselected, discarded) the subtitle packets for the
        // whole buffered region ahead of the playhead, so an in-band feed
        // would render nothing until that buffer plays through. The
        // extractor seeks its own context to the playhead and feeds cues
        // immediately. The in-band pipeline still serves selections made
        // during `openAndDemux`, where the demux head is at the playhead.
        if let extractor = ensureRuntimeSubtitleExtractor() {
            // Same race as `performAudioTrackSwitch`: a selection applied
            // while `openAndDemux` is still priming reads a ~0 playback
            // clock. `pendingSkipBelowPTS` holds the requested anchor
            // (load startTime or seek target) — without it, a resumed
            // playback's initial subtitle selection feeds cues from the
            // start of the file instead of the resume point.
            extractor.select(
                trackId: SubtitleTrackIdSpace.makeAVPlayerEmbeddedTrackId(streamIndex: candidate),
                slot: slot,
                startSeconds: max(0, currentPlaybackTimeSeconds(), pendingSkipBelowPTS)
            )
            return
        }

        // No source URL to re-open (should not happen after a successful
        // load) — fall back to the in-band feed.
        if !setupSubtitleDecoder(streamIndex: candidate, slot: slot) {
            Self.logger.warning(
                "setSubtitleTrack: decoder setup failed for id=\(candidate) slot=\(slot.rawValue)"
            )
            subtitleSession?.closeSlot(slot)
            return
        }
        embeddedSubtitlePipeline.startFeed(
            slot: slot,
            session: subtitleSession,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
    }

    /// Lazily creates the runtime subtitle extractor for the current
    /// load. Runs on `controlQueue`.
    private func ensureRuntimeSubtitleExtractor() -> AVPlayerEmbeddedSubtitleExtractor? {
        if let runtimeSubtitleExtractor { return runtimeSubtitleExtractor }
        guard let session = subtitleSession, let url = lastLoadURL else { return nil }
        let extractor = AVPlayerEmbeddedSubtitleExtractor(subtitleSession: session)
        extractor.currentMediaTimeProvider = { [weak self] in
            guard let self else { return 0 }
            // Pre-anchor the clock reads ~0; use the pending anchor so the
            // read-ahead throttle doesn't stall a resume-point feed against
            // a not-yet-started timeline.
            return max(0, self.currentPlaybackTimeSeconds(), self.pendingSkipBelowPTS)
        }
        extractor.configure(
            source: AVPlayerSubtitleExtractionSource(
                mediaURL: url,
                requestHeaders: lastLoadHeaders,
                routeLabel: "coremedia-runtime",
                seekable: true
            ),
            probe: false
        )
        runtimeSubtitleExtractor = extractor
        return extractor
    }

    // MARK: - Font attachments

    /// Walk `AVMEDIA_TYPE_ATTACHMENT` streams and register any embedded
    /// TTF/OTF fonts with libass. Anime releases ship custom fonts in
    /// MKV attachments; without this, libass falls back to the default
    /// font family and karaoke typesetting loses its look.
    private func registerEmbeddedFonts() {
        guard let formatCtx, let session = subtitleSession else { return }
        let nb = Int(formatCtx.pointee.nb_streams)
        let streams = formatCtx.pointee.streams
        for i in 0..<nb {
            guard let stream = streams?[i],
                  let codecparPtr = stream.pointee.codecpar else { continue }
            let codecpar = codecparPtr.pointee
            guard codecpar.codec_type == AVMEDIA_TYPE_ATTACHMENT,
                  codecpar.extradata_size > 0,
                  let ed = codecpar.extradata else { continue }

            // Accept TTF / OTF by mimetype or codec id. Some containers
            // label the codec as "truetype_font" or "opentype_font";
            // others leave it as NONE with a mimetype in the metadata
            // dictionary.
            var isFontMime = false
            var filename = "embedded_font_\(i)"
            if let meta = stream.pointee.metadata {
                if let entry = av_dict_get(meta, "mimetype", nil, 0),
                   let cstr = entry.pointee.value {
                    let mime = String(cString: cstr).lowercased()
                    if mime.contains("font") || mime.contains("truetype") || mime.contains("opentype") {
                        isFontMime = true
                    }
                }
                if let entry = av_dict_get(meta, "filename", nil, 0),
                   let cstr = entry.pointee.value {
                    let v = String(cString: cstr)
                    if !v.isEmpty { filename = v }
                }
            }
            // AV_CODEC_ID_TTF = 98305, AV_CODEC_ID_OTF = 98320 (FFmpeg
            // 7.x). Use explicit integers because the Swift import of
            // these codec ids as enums varies by header.
            let codecId = codecpar.codec_id.rawValue
            let isFontCodec = codecId == 98_305 || codecId == 98_320
            guard isFontMime || isFontCodec else { continue }

            let data = Data(bytes: ed, count: Int(codecpar.extradata_size))
            session.registerEmbeddedFont(name: filename, data: data)
        }
    }

    // MARK: - Overlay pump

    /// Called from the display-link tick once per vsync. Dispatches the
    /// actual render onto the session queue; hops the composited
    /// CGImage back to main for CALayer assignment.
    private func pumpSubtitleOverlay() {
        guard let session = subtitleSession else { return }

        let nowSeconds = currentPlaybackTimeSeconds()
        let nowMs = Int64(nowSeconds * 1000.0)

        guard let overlay = subtitleOverlay else { return }
        let renderer = session.underlyingRenderer
        guard renderer.hasAnyActiveTrack else {
            // Disabling a track drops it without a final render pass —
            // bailing here would leave the last composited cue on the
            // layer indefinitely. Clearing every tick while inactive also
            // covers an in-flight session-queue render re-pushing a stale
            // image right after the drop. Mirrors the AVPlayer route.
            DispatchQueue.main.async {
                overlay.clear()
            }
            return
        }

        let syncOffsetMs = Int64(session.currentParams.syncOffsetMs)
        let assNowMs = nowMs - syncOffsetMs
        let bounds = overlay.bounds
        let videoInsets = overlay.videoInsets
        #if os(macOS)
        let scale = overlay.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        let scale = overlay.window?.screen.scale ?? overlay.traitCollection.displayScale
        #endif

        // DIAG: while a live AI subtitle slot is active, sample the render once
        // a second to record whether libass is actually rasterizing a cue
        // (`hasContent`) at the current playhead. `hasContent=0` while cues are
        // being fed at the right time ⇒ the miss is in shaping/font/style, not
        // the cue pipeline; `hasContent=1` while nothing shows ⇒ the miss is in
        // compositing/overlay.
        let liveDiag: Bool
        if session.isLiveSlot(.primary), nowSeconds - lastLiveOverlayDiagSeconds >= 1.0 {
            lastLiveOverlayDiagSeconds = nowSeconds
            liveDiag = true
        } else {
            liveDiag = false
        }

        renderer.sessionQueue.async { [weak overlay] in
            let out = renderer.renderOnSessionQueue(
                atMilliseconds: assNowMs,
                frameSize: bounds.size,
                scale: scale,
                videoInsets: videoInsets
            )
            if liveDiag {
                Self.logger.info(
                    "[AI-LIVE-DIAG] render assNowMs=\(assNowMs, privacy: .public) hasContent=\(out.hasContent ? 1 : 0, privacy: .public) dirty=\(out.isDirty ? 1 : 0, privacy: .public) frame=\(Int(bounds.width), privacy: .public)x\(Int(bounds.height), privacy: .public)"
                )
            }
            guard out.isDirty else { return }
            let image = out.image
            let imageFrame = out.imageFrame
            DispatchQueue.main.async {
                overlay?.updateContents(image, frame: imageFrame)
            }
        }
    }

    // MARK: - Teardown

    private func teardownMedia(deferFrees: Bool = false) {
        videoToolboxDecoder.invalidate()

        // Detach every FFmpeg context from `self` synchronously; free them
        // either inline (deinit path) or behind the control queue.
        //
        // Why defer: `performSeek` runs on the control queue and can be
        // inside a blocking `avformat_seek_file` when `dispose()` fires from
        // another thread. The dispose barriers cover demux/feed queues but
        // deliberately not control — performSeek does `DispatchQueue.main.sync`,
        // so a control barrier taken from main would deadlock. Serializing
        // the frees behind the control queue means an in-flight seek (which
        // captured `formatCtx` before its disposed-check) finishes against
        // valid pointers; later control-queue work re-checks `isDisposed` /
        // nil properties and bails. The block captures `self` strongly so
        // the FFmpeg interrupt callback's unretained pointer stays valid
        // through `avformat_close_input`.
        var videoCtxToFree = videoCodecCtx
        videoCodecCtx = nil
        let videoSwsCtxToFree = videoSwsCtx
        videoSwsCtx = nil
        var audioCtxToFree = audioCodecCtx
        audioCodecCtx = nil
        var audioSwrCtxToFree = audioSwrCtx
        audioSwrCtx = nil
        var formatCtxToFree = formatCtx
        formatCtx = nil
        let freeContexts = {
            if videoCtxToFree != nil {
                avcodec_free_context(&videoCtxToFree)
            }
            if videoSwsCtxToFree != nil {
                sws_freeContext(videoSwsCtxToFree)
            }
            if audioCtxToFree != nil {
                avcodec_free_context(&audioCtxToFree)
            }
            if audioSwrCtxToFree != nil {
                swr_free(&audioSwrCtxToFree)
            }
            if formatCtxToFree != nil {
                avformat_close_input(&formatCtxToFree)
            }
        }
        if deferFrees {
            controlQueue.async { [self] in
                freeContexts()
                _ = self // keep the interrupt-callback target alive until closed
            }
        } else {
            freeContexts()
        }

        videoDecodeMode = .videoToolbox
        videoFormatDescription = nil
        publishVideoPresentationSize()
        videoDecodeOutputDimensions = nil
        useUntimedCompressedVideoSamples = false
        isRebuildingDecoder = false
        decoderRebuildPending = false
        audioOutputConfig = nil

        embeddedSubtitlePipeline.teardown()
        runtimeSubtitleExtractor?.teardown()
        runtimeSubtitleExtractor = nil

        videoStreamIndex = -1
        audioStreamIndex = -1

        videoPacketQueue.drain()
        audioPacketQueue.drain()
        embeddedSubtitlePipeline.drainQueues()
    }

    private func reportError(_ message: String) {
        // If the failure happened mid-load, drop any parked track switch —
        // the VM re-applies selections on reload. No-op otherwise.
        endLoadGate(applyDeferredSwitch: false)
        Self.logger.error("\(message, privacy: .public)")
        print("[CMP] ERROR: \(message)")
        #if os(iOS) || os(tvOS)
        // Every engine-fatal path funnels through here, so this is the one
        // place a classified failure can be recorded. `reason` is the stable
        // token — the raw message stays in the `[CMP] ERROR:` stdout line and
        // in the VM's terminal breadcrumb, which is where prose belongs.
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "Player",
            message: "engine error",
            attrs: [
                "reason": .string(Self.engineErrorReason(message)),
                "position_ms": .int(Self.positionMilliseconds(currentPlaybackTimeSeconds())),
            ]
        )
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    /// Collapses an engine error message into a stable classification token
    /// for the `playback.reason` attribute. Messages are English prose that
    /// gets reworded between builds; these tokens are what a report can be
    /// grouped and compared on, so they must stay put even when the wording
    /// moves.
    ///
    /// Order is load-bearing. The source-open and stream-info arms come before
    /// the generic `decoder`/`codec` substrings because both interpolate an
    /// `av_strerror` string that can itself mention a codec ("Failed to open
    /// file: Invalid data found when processing input" is the benign case; the
    /// codec-mentioning ones are not) — the message's own prefix is a stronger
    /// signal than a substring anywhere in FFmpeg's appended text.
    static func engineErrorReason(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("seek stalled") { return "seek_stalled" }
        if value.contains("dolby vision") { return "dolby_vision_display_unavailable" }
        if value.contains("media services were reset") { return "audio_services_reset" }
        if value.contains("audio output failed") { return "audio_output_failed" }
        if value.contains("no supported video stream") { return "no_video_stream" }
        if value.contains("failed to open") || value.contains("stream info") {
            return "source_open_failed"
        }
        if value.contains("decoder") { return "decoder_unavailable" }
        if value.contains("codec") { return "unsupported_codec" }
        return "engine_error"
    }

    // MARK: - AVDisplayManager (tvOS-only)

    #if os(tvOS)
    /// Profile-5-only: request DV mode and watch `AVDisplayManager` for the
    /// switch to complete. If the user has `isDisplayCriteriaMatchingEnabled`
    /// off we refuse immediately; if the manager is still mid-switch after 3 s
    /// we fire a descriptive error. The base layer of Profile 5 is PQ-encoded
    /// bytes that are not valid HDR10, so letting playback proceed on a
    /// non-DV display would render wrong colors.
    @MainActor
    private func applyDvGatedDisplayCriteria(refreshRate: Float) {
        guard let dm = TVDisplayCriteria.activeTVWindow()?.avDisplayManager else {
            Self.logger.warning("applyDvGatedDisplayCriteria: no avDisplayManager")
            print("[CMP] applyDvGatedDisplayCriteria: no avDisplayManager")
            return
        }
        let profile5Hint = "Dolby Vision Profile 5 requires a Dolby Vision display connected via HDMI with 'Match Content: Dynamic Range' enabled (Settings → Video and Audio → Match Content)."
        // Shares `TVDisplayCriteria`'s public format-description write rather
        // than constructing criteria here, so the `dvh1` request this gate
        // makes is identical to every other Dolby Vision path.
        switch TVDisplayCriteria.setCriteria(
            .dolbyVision(baseLayer: .hdr10),
            refreshRate: refreshRate
        ) {
        case .matchingDisabled:
            print("[CMP] dv gate REFUSE: isDisplayCriteriaMatchingEnabled=false")
            reportError(profile5Hint)
            return
        case .formatUnavailable:
            // No DV request could be made, so a non-DV panel would render the
            // Profile 5 base layer as wrong colors. Refuse like the gate does
            // for disabled matching.
            print("[CMP] dv gate REFUSE: format description unavailable")
            reportError(profile5Hint)
            return
        case .noDisplayManager:
            // Raced the guard above; matches its silent bail.
            print("[CMP] dv gate: avDisplayManager disappeared")
            return
        case .applied:
            break
        }
        print(String(format:
            "[CMP] dv gate applyCriteria fps=%.3f format=dolbyVision(hdr10) (profile-5)",
            Double(refreshRate)))

        dvGateObservation?.invalidate()
        dvGateObservation = dm.observe(
            \.isDisplayModeSwitchInProgress,
            options: [.new]
        ) { _, change in
            let inProgress = change.newValue ?? false
            print("[CMP] dv gate switchInProgress=\(inProgress)")
        }

        dvGateTimeoutItem?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak dm] in
            guard let self else { return }
            if dm?.isDisplayModeSwitchInProgress == true {
                print("[CMP] dv gate TIMEOUT still-switching=true")
                self.reportError(profile5Hint)
            } else {
                print("[CMP] dv gate settled")
            }
            self.dvGateObservation?.invalidate()
            self.dvGateObservation = nil
            self.dvGateTimeoutItem = nil
        }
        dvGateTimeoutItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeout)
    }
    #endif
}

// MARK: - Picture in Picture delegate

#if !os(macOS)
@available(iOS 15.0, tvOS 15.0, *)
extension PlayerCore: AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate {
    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Self.logger.info("PiP will start")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Self.logger.info("PiP did start")
        isPictureInPictureActive = true
        DispatchQueue.main.async { [weak self] in
            self?.onPictureInPictureActiveChange?(true)
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Self.logger.info("PiP will stop")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Self.logger.info("PiP did stop")
        isPictureInPictureActive = false
        DispatchQueue.main.async { [weak self] in
            self?.onPictureInPictureActiveChange?(false)
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let message = "PiP failed to start: \(error.localizedDescription)"
        Self.logger.error("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        if playing {
            play()
        } else {
            pause()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        // PiP expects a finite duration for scrubbing. For live/unknown
        // durations we return a "positive infinity" range so PiP treats
        // content as streaming.
        guard durationSeconds > 0 else {
            return CMTimeRange(
                start: .negativeInfinity,
                duration: .positiveInfinity
            )
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        isPaused()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Self.logger.info(
            "PiP render size=\(newRenderSize.width)x\(newRenderSize.height)"
        )
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let now = currentPlaybackTimeSeconds()
        let delta = skipInterval.seconds
        let target = max(0, now + delta)
        seek(to: target)
        // The completion handler unblocks PiP's transport-bar — must be
        // called even if the seek is still in-flight. Seek is async but the
        // user will see the scrubber snap regardless.
        completionHandler()
    }
}
#endif

// MARK: - DynamicRange (raw values used by the private AVDisplayCriteria API)

/// Dynamic-range int values. On tvOS these are the raw values the private
/// `AVDisplayCriteria` initializer accepts; on iOS the enum is still useful
/// as a classifier for the stream's transfer function driving EDR decisions.
/// Named "Spike" historically (Phase 0 origin); kept as-is to avoid a rename
/// churn.
internal enum SpikeDynamicRange: Int32 {
    case sdr = 0
    case hdr10 = 2
    case hlg = 3
    case dolbyVision = 5
}

// MARK: - PacketQueue (bounded, condition-variable-blocking)
