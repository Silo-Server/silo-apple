//
//  DVSegmentWriter.swift
//  Continuum (iOS + tvOS) — Dolby Vision AVPlayer loopback route
//
//  Re-demuxes a remote source with libavformat, re-muxes it into fragmented
//  MP4 via the `mp4` muxer (the `hls` muxer isn't compiled into our
//  xcframework), and splits the output stream into HLS segments by parsing
//  ISO BMFF boxes as the muxer emits them.
//
//  Why this design:
//    - Our FFmpeg build only has the `mp4` muxer — no `hls`, no `segment`.
//      So we produce a single fragmented MP4 stream via the mp4 muxer with
//      `movflags = +frag_keyframe+delay_moov+default_base_moof`, which emits
//      `ftyp + moov` (init) followed by a series of multiplexed `moof + mdat`
//      pairs. We split those into segment files from Swift.
//    - AVPlayer's HLS pipeline requires proper `'dvh1'` FourCC on the video
//      track so it routes the stream through its DV-aware internal decoder.
//      We force that by setting the output stream's codec_tag. This is the
//      whole point of this path: AVPlayer via HLS honors dvcC / dvh1 and
//      invokes its own DV decoder even when the original source container
//      would not have been playable as a native-direct asset.
//
//  Threading:
//    All libavformat I/O runs on a dedicated serial queue
//    (`com.continuum.dv.mux`). The only cross-thread communication is the
//    initial start()/stop() and an Atomic callback that notifies the backend
//    when enough initial media is ready to serve (so AVPlayer can begin
//    loading the manifest without a guessing race).

import Foundation
import OSLog
import Darwin
import Libavcodec
import Libavformat
import Libavutil
import Libdovi
import Libswresample

enum DVPreVideoAudioTailPolicy {
    static let maxPackets = 512
    static let maxBytes = 8 * 1024 * 1024

    static func headDropCountBeforeAppending(
        existingByteSizes: [Int],
        retainedBytes: Int,
        incomingBytes: Int,
        maxPackets: Int = Self.maxPackets,
        maxBytes: Int = Self.maxBytes
    ) -> Int? {
        guard incomingBytes <= maxBytes else { return nil }
        var dropCount = 0
        var remainingBytes = retainedBytes
        while dropCount < existingByteSizes.count,
              existingByteSizes.count - dropCount >= maxPackets || remainingBytes + incomingBytes > maxBytes {
            remainingBytes = max(0, remainingBytes - max(0, existingByteSizes[dropCount]))
            dropCount += 1
        }
        return dropCount
    }
}

enum DVTrueHDMajorSyncScanner {
    private static let syncWord: [UInt8] = [0xF8, 0x72, 0x6F, 0xBA]

    static func containsMajorSync(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return containsMajorSync(bytes: base, count: data.count)
        }
    }

    static func containsMajorSync(bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count >= syncWord.count else { return false }
        for offset in 0...(count - syncWord.count) {
            if bytes[offset] == syncWord[0],
               bytes[offset + 1] == syncWord[1],
               bytes[offset + 2] == syncWord[2],
               bytes[offset + 3] == syncWord[3] {
                return true
            }
        }
        return false
    }
}

final class DVSegmentWriter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "DVSegmentWriter"
    )
    private static let traceTopLevelBoxes = false
    private static let verboseSegmentLogging =
        ProcessInfo.processInfo.environment["SILO_TRACE_DV_SEGMENTS"] == "1"
    private static let traceThroughput =
        ProcessInfo.processInfo.environment["SILO_TRACE_DV_THROUGHPUT"] == "1"
    private let avErrorAgain = -Int32(EAGAIN)
    private let avErrorInvalidData = Int32(-1094995529) // AVERROR_INVALIDDATA

    // MARK: - Inputs
    let sessionSpec: LoopbackSessionSpec
    let sourceURL: URL
    let sourceHeaders: [String: String]
    let sourceStartTimeSeconds: Double
    let outputDirectory: URL
    let segmentStore: DVSegmentStore?
    let debugOutputDirectory: URL?
    let selectedAudioTrackIndex: Int
    let videoMode: LoopbackSessionSpec.VideoMode
    let selectedAudioOutputMode: LoopbackSessionSpec.AudioOutputMode
    let manifestMetadata: LoopbackSessionSpec.ManifestMetadata
    /// Target fragment duration in seconds. Used to emit EXT-X-TARGETDURATION
    /// in the playlist; actual per-fragment duration is driven by source
    /// keyframe cadence (`+frag_keyframe`).
    let targetSegmentDuration: Double
    /// Minimum generated media duration before AVPlayer is allowed to attach
    /// to the local playlist. H.264 loopback starts more smoothly with a
    /// slightly larger runway; starting earlier can show one frame and then
    /// trip AVPlayer's buffering state while the writer catches up.
    let minimumStartupMediaDuration: Double
    /// EVENT playlists need enough visible runway before AVPlayer attaches.
    /// If we publish too early, AVPlayer reads the head of the playlist,
    /// drains those fragments, then waits roughly one target-duration refresh
    /// before it asks for the newly-written tail — a stall right after the
    /// first frame. AVPlayer treats the growing playlist like a live stream,
    /// so the initial window follows the HLS live-start rule of three target
    /// durations, plus one fragment of reload slack. The window is media
    /// time, not a segment count, so it tracks the source's keyframe
    /// cadence: short-GOP sources publish after a few seconds while long-GOP
    /// sources still wait for a safe run of fragments.
    private static let startupLiveEdgeTargetDurations = 3.0
    private static let minimumStartupPlaylistSegments = 3
    /// Keep a generous runway behind current playback before retiring local HLS
    /// spill files. This turns the spill budget into a current-cache budget
    /// without removing media AVPlayer may still retry during normal playback.
    private static let spillRetirementPlaybackSafetyWindowSeconds: Double = 45
    private static let minimumPlaylistSegmentsToKeep = 8
    private static let generatedAheadThrottleConstrainedSeconds: Double = 60
    private static let generatedAheadThrottleDefaultSeconds: Double = 90
    private static let generatedBitrateWindowSeconds: Double = 30
    private static let maxGeneratedAheadThrottleWaitSeconds: Double = 2
    /// Once the playhead has been stationary for at least this long while we are
    /// already beyond the generated-ahead cap, stop soft-releasing and HOLD
    /// generation until the playhead moves again or the session is torn down.
    /// This keeps a paused — or wedged — player from generating hundreds of
    /// seconds of HLS ahead of a stationary playhead and exhausting the spill
    /// budget. The short soft-release is preserved below this threshold so brief
    /// playlist-reload stalls do not deadlock the mux thread. The backend's
    /// playhead watchdog owns the decision to reanchor or fall back; the writer
    /// only refuses to run unbounded ahead of a clock that is not advancing.
    private static let parkedPlayheadHoldThresholdSeconds: Double = 3.0
    /// Upper bound on how long the mux thread will park waiting for the store
    /// to free spill capacity. Capacity only frees as the playhead advances
    /// past retired segments; if the position provider wedges, the wait would
    /// otherwise spin forever. On timeout the writer proceeds and lets the
    /// store evict, trading a possible over-budget blip for guaranteed
    /// forward progress.
    private static let maxSegmentStoreCapacityWaitSeconds: Double = 30

    // MARK: - Lifecycle callbacks (fired on muxQueue)
    /// Fires exactly once, after the init segment + initial media runway are
    /// on disk — i.e. when it's safe for AVPlayer to start reading the
    /// manifest. Passes the relative playlist filename ("playlist.m3u8").
    var onFirstSegmentReady: ((String) -> Void)?
    /// Fires whenever the media playlist on disk gains a new segment.
    var onSegmentAppended: ((_ segmentIndex: Int, _ totalMediaDuration: Double) -> Void)?
    /// Fires once the writer has seen the first video packet after an input
    /// seek and knows the exact source timestamp that maps to player time 0.
    var onTimelineAnchorResolved: ((_ sourceStartSeconds: Double) -> Void)?
    /// Fires with a rolling estimate of how quickly FFmpeg is reading the
    /// remote source, not how quickly AVPlayer is reading localhost HLS.
    var onSourceDownloadStats: ((_ bitsPerSecond: Double?, _ totalBytesRead: Int64?) -> Void)?
    struct GeneratedMediaStats: Equatable {
        let generation: UInt64
        let rollingBitrateBps: Double?
        let totalGeneratedBytes: Int64
        let playlistVisibleStartSeconds: Double
        let playlistVisibleEndSeconds: Double
        let firstMediaSequence: Int
        let lastMediaSequence: Int
        let targetDuration: Int
        let longestSegmentDuration: Double
        let segmentCount: Int
        let playlistBodyBytes: Int
        let playlistBodyHash: UInt64
        let playlistKind: String
        let tempSpillBytes: Int64
        let tempSpillBudgetBytes: Int64
        let durationSource: String
    }
    /// Fires after every playlist publish with generated HLS facts. The
    /// backend uses this for AVPlayer buffer sizing and live-edge diagnostics.
    var onGeneratedMediaStats: ((GeneratedMediaStats) -> Void)?
    /// Returns AVPlayer's current local playlist time. Used to keep the remuxer
    /// from producing minutes of HLS ahead of the player and forcing store
    /// eviction of segments that AVPlayer may still request.
    var playbackPositionProvider: (() -> Double?)?
    /// Fires once the muxer reaches EOF or errors irrecoverably. `error` nil
    /// means natural EOF + trailer written.
    var onFinished: ((_ error: Error?) -> Void)?

    // MARK: - Internal state (muxQueue only)
    private let muxQueue = DispatchQueue(label: "com.continuum.dv.mux", qos: .userInitiated)
    /// Cancellation flag. Guarded by `cancelLock` so `stop()` can flip it
    /// from any thread — including while the mux loop is blocked inside
    /// `av_read_frame` waiting on a network read. FFmpeg's
    /// `AVIOInterruptCB` polls this between I/O operations and bails the
    /// read immediately once set.
    private var _cancelled = false
    private let cancelLock = NSLock()
    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _cancelled
    }
    private var inputCtx: UnsafeMutablePointer<AVFormatContext>?
    private var outputCtx: UnsafeMutablePointer<AVFormatContext>?
    private var ioBuffer: UnsafeMutablePointer<UInt8>?
    private var ioContext: UnsafeMutablePointer<AVIOContext>?

    /// Maps input stream index → output stream index, so we can rewrite
    /// packet stream_index before handing to the output muxer. (Not all input
    /// streams round-trip; subtitles / data tracks are skipped in `openOutput`.)
    private var streamMap: [Int: Int] = [:]

    /// Running buffer of bytes emitted by the muxer but not yet split into
    /// a segment file. We parse top-level ISO BMFF boxes out of this buffer
    /// as they complete.
    private var boxBuffer = Data()
    /// Accumulated bytes of the init segment (ftyp + moov). Written once the
    /// moov is complete — triggered by seeing the first `moof` box header.
    private var initSegmentBytes = Data()
    private var initSegmentWritten = false
    /// Guards `onFirstSegmentReady` — the callback is one-shot by contract
    /// (AVPlayerBackend installs observers on that signal) and two fires
    /// would double-add the periodic time observer.
    private var firstSegmentReadyFired = false
    /// Tracks whether the playlist contains at least one video-bearing segment.
    /// Audio-only fragments before the first video sample are still discarded,
    /// but startup gating should not discard later segments while waiting for
    /// more playback runway.
    private var hasWrittenVideoSegment = false
    /// Current in-flight segment file — opened when we start a moof, closed
    /// when the following mdat finishes.
    private var currentSegmentIndex = 0
    private struct SegmentEntry {
        let index: Int
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }
    /// Playlist-visible media segments. We may discard muxer pre-roll fragments
    /// before the first video fragment so AVPlayer does not start on audio-only
    /// or otherwise unplayable fragments.
    /// We don't (yet) parse moof tfdt boxes — fall back to the caller's
    /// target duration hint for the playlist.
    private var segmentEntries: [SegmentEntry] = []
    /// Running total of media duration written to the playlist so we don't
    /// rescan `segmentEntries` on every append.
    private var totalMediaDuration: Double = 0
    /// Wall-clock-independent sliding retention remains disabled for the local
    /// fMP4 segments. Spill cleanup is instead coupled to AVPlayer playback
    /// position via `retireSegmentsBehindPlaybackIfNeeded()`, but normal spill
    /// retirement leaves the playlist append-only so AVPlayer keeps EVENT
    /// timeline semantics instead of switching to a sliding live item midstream.
    private static let segmentRetentionWindowSeconds: Double = 0
    /// Media sequence number of the first segment currently in
    /// `segmentEntries`. Bumped each time the head is evicted; emitted as
    /// `#EXT-X-MEDIA-SEQUENCE` so AVPlayer's EVENT-style refetch sees a
    /// monotonic sliding window.
    private var firstMediaSequence: Int = 0
    /// Set to true once the trailer is written. Playlist then emits
    /// EXT-X-ENDLIST so AVPlayer treats it as VOD.
    private var finished = false
    private var loggedMasterManifest = false
    private var repairedMissingVideoDTSCount = 0
    private let startupWallTime = CFAbsoluteTimeGetCurrent()
    private var lastSourceStatsWallTime: CFAbsoluteTime?
    private var lastSourceStatsBytesRead: Int64?
    private var lastSpillCapacityBackpressureLogWall: CFAbsoluteTime = 0
    private var lastGeneratedAheadBackpressureLogWall: CFAbsoluteTime = 0
    /// Last playback position observed by `waitForGeneratedAheadIfNeeded`, and
    /// the wall-clock time it last advanced. Tracked across calls (the throttle
    /// runs once per appended segment) so we can tell a momentarily-stale clock
    /// from a genuinely stationary playhead.
    private var generatedAheadObservedPlayback: Double = -1
    private var generatedAheadObservedPlaybackWall: CFAbsoluteTime = 0
    private var totalGeneratedSegmentBytes: Int64 = 0
    private var recentGeneratedSegments: [(bytes: Int, duration: Double)] = []
    private var lastSegmentDurationSource = "unknown"

    private var shouldIncludeAudio: Bool {
        if let explicit = sessionSpec.selectedAudio.ffIndex {
            return explicit >= 0
        }
        return selectedAudioTrackIndex >= 0
    }

    /// Which input stream index supplies the video track. -1 until openOutput
    /// sets it.
    private var videoInputStreamIndex: Int = -1
    private var selectedAudioStreamIndex: Int = -1
    private var audioOutputStreamIndex: Int = -1
    private var trackTimeBasesByID: [UInt32: AVRational] = [:]
    /// Last successfully written timestamps per output stream. Used to repair
    /// duplicate audio DTS before handing packets to the MP4 muxer.
    private var lastMuxedDTSByStream: [Int32: Int64] = [:]
    private var lastMuxedPTSByStream: [Int32: Int64] = [:]
    /// When the loopback starts from a resume point, FFmpeg seeks the source
    /// but source packet timestamps remain absolute. Subtract the first video
    /// timestamp so the generated localhost playlist begins at player time 0.
    private var outputTimestampBaseSeconds: Double?
    /// Packets we prefetch during bootstrap (to parse VPS/SPS/PPS from the
    /// first keyframe before writeHeader runs). Replayed to the muxer after
    /// writeHeader so the first keyframe isn't lost.
    private var pendingVideoPackets: [UnsafeMutablePointer<AVPacket>] = []
    /// Same pattern for any audio packets we intentionally keep before the
    /// main mux loop. In transcode mode we hold onto the selected stream's
    /// pre-video packets so the TrueHD decoder can see its first `major_sync`
    /// access unit (required to establish stream parameters); dropping them
    /// would force ~100ms of "Stream parameters not seen; skipping frame".
    /// Replayed through the audio decoder in `flushPendingAudioPackets` after
    /// `writeHeader`, but not emitted to the muxer. This lets TrueHD see its
    /// first `major_sync` access unit without putting pre-video audio into the
    /// first playable HLS segment.
    private var pendingAudioPackets: [UnsafeMutablePointer<AVPacket>] = []
    /// Raw bytes of the input's HEVC codec extradata (the 23-byte HVCC header
    /// MKV gives us). Read once in openOutput and reused in bootstrap for
    /// field layout — we rewrite the `numOfArrays` byte and append our own
    /// VPS/SPS/PPS arrays.
    private var inputHvccHeader: Data?
    /// Length prefix size for HEVC NAL units (from HVCC header byte 21's low
    /// 2 bits, +1). Typically 4; defensively handled.
    private var nalLengthSize: Int = 4
    /// Raw bytes of the input's H.264 avcC record. Used for the HLS CODECS
    /// string when the loopback path remuxes AVC without touching the video.
    private var inputAvccHeader: Data?
    /// Raw bytes of the DOVI decoder configuration record from the input
    /// stream (8 useful bytes matching FFmpeg's `AVDOVIDecoderConfigurationRecord`
    /// layout: version_major, version_minor, profile, level, rpu_flag, el_flag,
    /// bl_flag, bl_compat_id). Nil if the source isn't Dolby Vision. Used by
    /// `writeInitSegment` to synthesise a `dvvC` box — FFmpeg's mp4 muxer in
    /// our build doesn't emit one on its own, so AVPlayer can't see DV
    /// signalling and paints the IPT samples as YCbCr (green/purple).
    private var doviConfig: Data?
    private var doviRecord: DoviRecord?
    private var outputAudioCodecID: AVCodecID?
    private var outputAudioCodecToken: String?
    private var audioDecoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioEncoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioSwrCtx: OpaquePointer?
    private var audioSampleFifo: OpaquePointer?
    private var nextEncodedAudioPTS: Int64 = 0
    private var audioDecodedFrameCount = 0
    private var audioDecodeErrorCount = 0
    private var videoOutputTrackID: UInt32?

    /// Captures any fatal IO error seen by `writeInitSegment`,
    /// `finalizeCurrentSegment`, or playlist emit calls. Those run from the
    /// AVIO write callback (synchronously inside `av_interleaved_write_frame`),
    /// so they cannot throw directly. The mux loop checks this after every
    /// `av_interleaved_write_frame`/`av_write_trailer` and rethrows.
    private var fatalIOError: DVWriterError?
    /// Consecutive `av_interleaved_write_frame` failures. Reset on success.
    /// When this hits `maxConsecutiveMuxWriteFailures`, the mux loop aborts via
    /// `DVWriterError.muxWriteFailures` so callers see a real error instead of
    /// a silent no-op. Some negative codes are treated as fatal on first hit
    /// regardless of count — see `evaluateMuxWriteResult`.
    private var consecutiveMuxWriteFailures = 0
    private struct ThroughputTiming {
        var readMs: Double = 0
        var videoMs: Double = 0
        var audioMs: Double = 0
        var muxMs: Double = 0
        var muxIOMs: Double = 0
        var segmentWriteMs: Double = 0
        var playlistWriteMs: Double = 0
        var readCalls = 0
        var videoPackets = 0
        var audioPackets = 0
        var muxPackets = 0
        var muxIOCalls = 0
        var segmentWrites = 0
        var playlistWrites = 0

        mutating func reset() {
            self = ThroughputTiming()
        }

        var logLine: String {
            String(
                format: "read=%.1fms/%d video=%.1fms/%d audio=%.1fms/%d mux=%.1fms/%d io=%.1fms/%d segWrite=%.1fms/%d playlist=%.1fms/%d",
                readMs, readCalls,
                videoMs, videoPackets,
                audioMs, audioPackets,
                muxMs, muxPackets,
                muxIOMs, muxIOCalls,
                segmentWriteMs, segmentWrites,
                playlistWriteMs, playlistWrites
            )
        }
    }
    private var throughputTiming = ThroughputTiming()
    /// Threshold tuned to tolerate the brief reorder bursts the fmp4 muxer
    /// occasionally emits during keyframe boundary realignment without
    /// missing a genuinely broken stream.
    private static let maxConsecutiveMuxWriteFailures = 5

    private struct DoviRecord {
        let versionMajor: UInt8
        let versionMinor: UInt8
        let profile: UInt8
        let level: UInt8
        let rpuPresent: Bool
        let elPresent: Bool
        let blPresent: Bool
        let compatibilityID: UInt8

        var logLine: String {
            "version=\(versionMajor).\(versionMinor) profile=\(profile) level=\(level) compat=\(compatibilityID) rpu=\(rpuPresent ? 1 : 0) el=\(elPresent ? 1 : 0) bl=\(blPresent ? 1 : 0)"
        }
    }

    // MARK: - Init

    init(
        sessionSpec: LoopbackSessionSpec,
        outputDirectory: URL,
        segmentStore: DVSegmentStore? = nil,
        debugOutputDirectory: URL? = nil,
        targetSegmentDuration: Double = 4.0,
        minimumStartupMediaDuration: Double? = nil,
        vodPlan: LoopbackSegmentPlan? = nil,
        vodBaseIndex: Int = 0
    ) {
        self.sessionSpec = sessionSpec
        self.sourceURL = sessionSpec.sourceURL
        self.sourceHeaders = sessionSpec.headers
        self.sourceStartTimeSeconds = sessionSpec.sourceStartTimeSeconds
        self.outputDirectory = outputDirectory
        self.segmentStore = segmentStore
        self.debugOutputDirectory = debugOutputDirectory
        self.selectedAudioTrackIndex = sessionSpec.selectedAudio.trackIndex
        self.videoMode = sessionSpec.videoMode
        self.selectedAudioOutputMode = sessionSpec.selectedAudio.outputMode
        self.manifestMetadata = sessionSpec.manifestMetadata
        self.targetSegmentDuration = targetSegmentDuration
        self.vodPlan = vodPlan
        self.vodBaseIndex = max(0, vodBaseIndex)
        self.minimumStartupMediaDuration = max(
            0,
            minimumStartupMediaDuration
                ?? Self.defaultMinimumStartupMediaDuration(for: sessionSpec.videoMode)
        )
    }

    // MARK: - VOD serving mode (loopback-primary plan, Stage 1c)

    /// Static-plan serving state. Populated only when the session spec asks
    /// for `.vodPlan` AND a plan could be resolved; the EVENT path never
    /// touches these. The plan is resolved once per player item — a
    /// restarted producer receives the already-resolved plan via init and
    /// must reproduce the same segment grid.
    private var vodPlan: LoopbackSegmentPlan?
    private let vodBaseIndex: Int
    private var vodCutter: LoopbackSegmentCutter?
    private var vodOpenSegmentIndex = 0
    private var vodClosingSegmentIndex: Int?
    private var vodHasRoutedVideo = false
    private var vodDidFlushFirstFragment = false
    /// True once the VOD pipeline is actually engaged for this session.
    /// Resolution can fail (unknown duration, degenerate index); the writer
    /// then degrades to the EVENT path instead of failing the load.
    private var vodActive = false
    /// Fired once, on the session that resolves the plan, so the backend can
    /// hand the same plan to restarted producers.
    var onSegmentPlanResolved: ((LoopbackSegmentPlan) -> Void)?

    /// Resolves (or installs) the segment plan and cutter. Runs after
    /// `openInput` — the keyframe index needs `find_stream_info` plus the
    /// cue-prewarm seek — and before `openOutput`/`writeHeader`, which pick
    /// muxer flags off `vodActive`.
    private func resolveVODPlanIfNeeded() throws {
        guard sessionSpec.servingMode == .vodPlan else { return }
        if vodPlan == nil {
            vodPlan = harvestVODPlan()
            if let plan = vodPlan {
                onSegmentPlanResolved?(plan)
            }
        }
        guard let plan = vodPlan, plan.segmentCount > 0 else {
            print("[CMP-AVP] vod plan unavailable; degrading to EVENT serving")
            return
        }
        let clampedBase = min(vodBaseIndex, plan.segmentCount - 1)
        vodCutter = LoopbackSegmentCutter(
            boundaries: Array(plan.boundaries[clampedBase...]),
            baseIndex: clampedBase
        )
        vodOpenSegmentIndex = clampedBase
        vodAnchorPts = plan.boundaries[0]
        if let inCtx = inputCtx,
           videoInputStreamIndex >= 0,
           let stream = inCtx.pointee.streams?[videoInputStreamIndex] {
            vodVideoTimeBase = stream.pointee.time_base
        }
        vodAwaitingRestartKeyframe = clampedBase > 0
        vodActive = true
        if selectedAudioOutputMode != .copy {
            // Bridged audio re-encodes on a synthesized clock; its restart
            // continuity is not validated yet (plan risk table). Copy-mode
            // sources are exact.
            print("[CMP-AVP] vod: bridged audio (\(selectedAudioOutputMode)) — restart timeline continuity unvalidated")
        }
    }

    /// Session timeline anchor: the plan's first boundary, on the source
    /// video time base. A plan constant, so every producer session — first
    /// or restarted — applies the identical shift and a restarted segment's
    /// tfdt continues the session timeline instead of zero-basing (M3).
    private var vodAnchorPts: Int64 = 0
    private var vodVideoTimeBase = AVRational(num: 1, den: 90000)
    /// Restart pre-roll gate: the restarted demuxer seek can land before the
    /// restart boundary; nothing before the first keyframe at-or-after that
    /// boundary may reach the muxer, or the restarted segment differs from
    /// its continuous twin.
    private var vodAwaitingRestartKeyframe = false
    private var vodFirstRoutedVideoDts: Int64?

    private func applyVODAnchorShift(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputTimeBase: AVRational
    ) {
        guard vodAnchorPts != 0 else { return }
        let anchor = av_rescale_q(vodAnchorPts, vodVideoTimeBase, inputTimeBase)
        if pkt.pointee.dts != Int64.min { pkt.pointee.dts -= anchor }
        if pkt.pointee.pts != Int64.min { pkt.pointee.pts -= anchor }
    }

    /// Drops packets that must not reach the muxer in VOD mode: restart
    /// pre-roll video before the restart boundary's keyframe, audio ahead
    /// of the video gate on a restart, and head-of-stream audio that would
    /// map below the plan anchor (tfdt is unsigned and the muxer no longer
    /// absorbs negatives with `avoid_negative_ts=disabled`).
    private func vodShouldDropPacket(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputIdx: Int
    ) -> Bool {
        guard vodActive, let plan = vodPlan else { return false }
        if inputIdx == videoInputStreamIndex {
            if vodAwaitingRestartKeyframe {
                let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
                let boundary = plan.boundaries[min(vodBaseIndex, plan.segmentCount - 1)]
                if isKeyframe, pkt.pointee.pts != Int64.min, pkt.pointee.pts >= boundary {
                    vodAwaitingRestartKeyframe = false
                    vodFirstRoutedVideoDts = pkt.pointee.dts
                    return false
                }
                return true
            }
            if vodFirstRoutedVideoDts == nil {
                vodFirstRoutedVideoDts = pkt.pointee.dts
            }
            return false
        }
        guard pkt.pointee.dts != Int64.min,
              let inCtx = inputCtx,
              videoInputStreamIndex >= 0,
              let videoStream = inCtx.pointee.streams?[videoInputStreamIndex],
              let thisStream = inCtx.pointee.streams?[inputIdx] else {
            return false
        }
        let thresholdVideoTB: Int64
        if vodBaseIndex == 0 {
            // Head of stream: audio at-or-after the plan anchor rides, even
            // ahead of the first video packet — the source's A/V offset is
            // part of the timeline. Audio before the anchor would map below
            // tfdt 0 and is dropped.
            thresholdVideoTB = vodAnchorPts
        } else {
            // Restart: audio waits for the video gate, then everything
            // before the gate's DTS is dropped so the restarted interleave
            // reproduces the continuous run's.
            guard let gate = vodFirstRoutedVideoDts else { return true }
            thresholdVideoTB = gate
        }
        let threshold = av_rescale_q(
            thresholdVideoTB,
            videoStream.pointee.time_base,
            thisStream.pointee.time_base
        )
        // A frame belongs to the timeline region its SPAN overlaps, not the
        // region its start timestamp falls in: the demuxer's per-track seek
        // lands on the audio sample containing the target instant, and the
        // continuous run's interleaver assigns that same overlapping frame
        // forward. Dropping it would lose exactly one frame per restart
        // (and break restart byte-identity with the continuous run).
        let duration = max(0, pkt.pointee.duration)
        if duration > 0 {
            return pkt.pointee.dts + duration <= threshold
        }
        return pkt.pointee.dts < threshold
    }

    private func harvestVODPlan() -> LoopbackSegmentPlan? {
        guard let inCtx = inputCtx,
              videoInputStreamIndex >= 0,
              let stream = inCtx.pointee.streams?[videoInputStreamIndex] else {
            return nil
        }
        let rawDuration = inCtx.pointee.duration
        guard rawDuration > 0 else { return nil }
        let durationSeconds = Double(rawDuration) / Double(AV_TIME_BASE)

        // Cue prewarm: a bounded mid-file seek forces the demuxer to load
        // the container's keyframe index (MKV Cues / mp4 stss) before
        // planning. Each read is bounded by the AVIO rw_timeout; a failed
        // prewarm leaves whatever the open scan indexed and the plan's
        // trust gates decide whether that is usable.
        if durationSeconds > 1 {
            let mid = Int64(durationSeconds * 0.5 * Double(AV_TIME_BASE))
            _ = avformat_seek_file(inCtx, -1, Int64.min, mid, Int64.max, AVSEEK_FLAG_BACKWARD)
        }

        var keyframePts: [Int64] = []
        let entryCount = avformat_index_get_entries_count(stream)
        keyframePts.reserveCapacity(Int(entryCount))
        for entryIndex in 0..<entryCount {
            guard let entry = avformat_index_get_entry(stream, entryIndex) else { continue }
            // AVINDEX_KEYFRAME == 0x0001 (bitfield; the macro doesn't import).
            if (entry.pointee.flags & 1) != 0 {
                keyframePts.append(entry.pointee.timestamp)
            }
        }

        // Rewind to the session start; the prewarm seek moved the cursor.
        if sourceStartTimeSeconds > 0 {
            try? seekInputToStartTimeIfNeeded(inCtx)
        } else {
            _ = avformat_seek_file(inCtx, -1, Int64.min, 0, Int64.max, AVSEEK_FLAG_BACKWARD)
        }

        let tb = stream.pointee.time_base
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframePts,
            timeBaseNum: tb.num,
            timeBaseDen: tb.den,
            sourceDurationSeconds: durationSeconds,
            targetSegmentDurationSeconds: targetSegmentDuration
        )
        print("[CMP-AVP] vod plan resolved segments=\(plan.segmentCount) keyframes=\(keyframePts.count) trusted=\(plan.usedKeyframeIndex) duration=\(String(format: "%.1f", plan.totalDurationSeconds))s")
        return plan
    }

    /// Routes a video packet through the plan cutter and flushes the open
    /// fragment when the packet opens a new segment. Runs BEFORE
    /// `rewritePacketForOutput` so the packet's PTS is still on the source
    /// video time base — the same axis as the plan boundaries.
    private func vodCutBeforeVideoPacketIfNeeded(pkt: UnsafeMutablePointer<AVPacket>) throws {
        guard vodActive, vodCutter != nil else { return }
        let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
        let target = vodCutter!.index(pts: pkt.pointee.pts, isKeyframe: isKeyframe)
        if !vodHasRoutedVideo {
            vodHasRoutedVideo = true
            vodOpenSegmentIndex = target
            return
        }
        guard target != vodOpenSegmentIndex else { return }
        try performVODFragmentCut(closingSegment: vodOpenSegmentIndex)
        vodOpenSegmentIndex = target
        waitForVODWindowIfNeeded(nextSegmentIndex: target)
    }

    /// Producer pacing for the VOD mode: block before filling a segment past
    /// the consumer's window (`target + forwardWindow`). Replaces the EVENT
    /// generated-ahead throttle — and inherently parks when the playhead
    /// wedges, since a frozen consumer stops advancing the target.
    private func waitForVODWindowIfNeeded(nextSegmentIndex: Int) {
        guard vodActive, let store = segmentStore else { return }
        var logged = false
        while !isCancelled, !store.vodProducerMayAppend(segmentIndex: nextSegmentIndex) {
            if !logged {
                logged = true
                print("[CMP-AVP] vod window backpressure parked segment=\(nextSegmentIndex)")
            }
            usleep(200_000)
        }
    }

    private func performVODFragmentCut(closingSegment: Int) throws {
        guard let outCtx = outputCtx else { return }
        vodClosingSegmentIndex = closingSegment
        // Drain the interleaver before flushing: audio the muxer buffered
        // while waiting for video DTS to catch up must land in the closing
        // fragment, not spill into the next one.
        let drainRC = av_interleaved_write_frame(outCtx, nil)
        if drainRC < 0 {
            throw DVWriterError.muxWriteFailures(lastRC: drainRC, consecutive: 1)
        }
        let flushRC = av_write_frame(outCtx, nil)
        if flushRC < 0 {
            throw DVWriterError.muxWriteFailures(lastRC: flushRC, consecutive: 1)
        }
        if !vodDidFlushFirstFragment {
            vodDidFlushFirstFragment = true
            // The first flush can split ftyp+moov and the fragment across
            // two calls (delay_moov); flush once more so the closing
            // segment is fully emitted before the next packet is written.
            let secondRC = av_write_frame(outCtx, nil)
            if secondRC < 0 {
                throw DVWriterError.muxWriteFailures(lastRC: secondRC, consecutive: 1)
            }
        }
        try throwIfFatalIOError()
    }

    private static func defaultMinimumStartupMediaDuration(
        for videoMode: LoopbackSessionSpec.VideoMode
    ) -> Double {
        switch videoMode {
        case .passthroughH264:
            // H264 startup is historically flakier — keep a longer runway.
            return 12.0
        default:
            // Was 8.0s. Lowered to 4.0s after measuring 4K DV P7 resume
            // seeks: the muxer outpaces playback at >2.7× realtime, the
            // 4K HEVC GOP keeps the first segment naturally large
            // (typically 12–14s of media in a single seg), and AVPlayer
            // already requests `preferredForwardBufferDuration=4.0s`
            // ahead. The 8s floor was forcing the gate to wait for a
            // second segment in the rare case seg 0 was a partial GOP
            // (after a mid-GOP seek), adding wall time without buying
            // any underflow safety. 4.0 remains the media-duration floor;
            // the separate EVENT-playlist gate below still waits for a
            // complete live-start window before AVPlayer attaches.
            return 4.0
        }
    }

    // MARK: - Public API

    func start() {
        muxQueue.async { [weak self] in
            self?.runMuxLoop()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        // Flip the flag synchronously so the in-flight `av_read_frame` bails
        // via the interrupt callback on its next poll, rather than waiting
        // for the muxQueue to drain.
        cancelLock.lock()
        _cancelled = true
        cancelLock.unlock()

        if let completion {
            muxQueue.async(execute: completion)
        }
    }

    // MARK: - Main loop

    private func runMuxLoop() {
        do {
            try prepareOutputDirectory()
            try openInput()
            try resolveVODPlanIfNeeded()
            try openOutput()
            // Prefetch + filter until we have a complete hvcC in extradata.
            // Filtered packets are stashed in pendingVideoPackets and replayed
            // below.
            try bootstrapVideoExtradata()
            try writeHeader()
            // writeHeader's `av_write_header` synchronously calls our AVIO
            // sink, which writes init.mp4 to disk via writeInitSegment. If
            // that disk write failed it set fatalIOError; surface it now
            // rather than continuing with no init segment.
            try throwIfFatalIOError()

            // Replay packets consumed during bootstrap. Video first so the
            // muxer's interleaver sees the keyframe DTS before any audio,
            // then audio. Both queues use the shared helper.
            if let outCtx = outputCtx {
                try flushPendingPackets(&pendingVideoPackets, label: "video", outCtx: outCtx)
                try flushPendingAudioPackets(outCtx: outCtx)
            }

            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }

            let avNoPTS = Int64.min  // AV_NOPTS_VALUE
            while !isCancelled {
                let rc: Int32
                if DVSegmentWriter.traceThroughput {
                    let started = CFAbsoluteTimeGetCurrent()
                    rc = av_read_frame(inputCtx, packet)
                    throughputTiming.readMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                    throughputTiming.readCalls += 1
                } else {
                    rc = av_read_frame(inputCtx, packet)
                }
                if isCancelled {
                    break
                }
                if rc < 0 {
                    // AVERROR_EOF or any other negative code — treat as
                    // end-of-input. Fine-grained error handling isn't
                    // worth the noise for a v1 spike.
                    break
                }
                emitSourceDownloadStatsIfNeeded()
                guard let pkt = packet else { break }
                let inputIdx = Int(pkt.pointee.stream_index)
                defer { av_packet_unref(pkt) }
                if isCancelled {
                    continue
                }
                guard let outIdx = streamMap[inputIdx] else { continue }
                // Skip packets with no usable presentation timestamp. Some
                // MKV/H.264 files expose the first keyframe with PTS but no
                // DTS; keep that packet and repair DTS below so AVPlayer does
                // not wait for the next keyframe before video appears.
                if !repairMissingMuxerTimestampsIfNeeded(
                    pkt: pkt,
                    inputStreamIndex: inputIdx,
                    noPTS: avNoPTS
                ) {
                    continue
                }

                if vodActive, vodShouldDropPacket(pkt: pkt, inputIdx: inputIdx) {
                    continue
                }

                if inputIdx == selectedAudioStreamIndex, selectedAudioOutputMode != .copy {
                    if Self.traceThroughput {
                        let started = CFAbsoluteTimeGetCurrent()
                        try transcodeAudioPacket(pkt)
                        throughputTiming.audioMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                        throughputTiming.audioPackets += 1
                    } else {
                        try transcodeAudioPacket(pkt)
                    }
                    continue
                }

                if inputIdx == videoInputStreamIndex {
                    if isCancelled {
                        continue
                    }
                    if Self.traceThroughput {
                        let started = CFAbsoluteTimeGetCurrent()
                        try transformVideoPacketIfNeeded(pkt)
                        throughputTiming.videoMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                        throughputTiming.videoPackets += 1
                    } else {
                        try transformVideoPacketIfNeeded(pkt)
                    }
                    try vodCutBeforeVideoPacketIfNeeded(pkt: pkt)
                }

                if isCancelled {
                    continue
                }
                rewritePacketForOutput(pkt: pkt, outStreamIndex: Int32(outIdx),
                                       inputStreamIndex: inputIdx)
                let wr: Int32
                if DVSegmentWriter.traceThroughput {
                    let started = CFAbsoluteTimeGetCurrent()
                    wr = av_interleaved_write_frame(outputCtx, pkt)
                    throughputTiming.muxMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                    throughputTiming.muxPackets += 1
                } else {
                    wr = av_interleaved_write_frame(outputCtx, pkt)
                }
                try evaluateMuxWriteResult(wr, packet: pkt)
            }

            if !isCancelled {
                try finishTranscodedAudio()
                if vodActive {
                    // The trailer flushes the final open fragment; name it.
                    vodClosingSegmentIndex = vodOpenSegmentIndex
                }
                let trailerRC = av_write_trailer(outputCtx)
                try throwIfFatalIOError()
                if trailerRC < 0 {
                    let detail = Self.ffmpegError(trailerRC)
                    Self.logger.error(
                        "av_write_trailer failed: rc=\(trailerRC) (\(detail, privacy: .public))"
                    )
                    throw DVWriterError.muxWriteFailures(
                        lastRC: trailerRC,
                        consecutive: 1
                    )
                }
                finalizePlaylistAsVOD()
                try throwIfFatalIOError()
            }
            teardown()
            if !isCancelled {
                onFinished?(nil)
            }
        } catch {
            Self.logger.error("DVSegmentWriter failed: \(String(describing: error), privacy: .public)")
            teardown()
            onFinished?(error)
        }
    }

    /// Throws any fatal disk-write error captured by the AVIO write callback
    /// path (`writeInitSegment`, `finalizeCurrentSegment`, `emitPlaylists`,
    /// `emitMasterPlaylist`). Those run synchronously from the muxer's write
    /// callback so they cannot throw directly — this helper drains the
    /// captured error at the next safe point.
    private func throwIfFatalIOError() throws {
        if let fatalIOError {
            throw fatalIOError
        }
    }

    /// Decodes an FFmpeg negative return code into a readable string via
    /// `av_strerror`. Used in error log lines so triage doesn't have to
    /// reverse-map AVERROR integers.
    private static func ffmpegError(_ code: Int32) -> String {
        var buf = [Int8](repeating: 0, count: 256)
        _ = av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }

    /// Centralizes the post-`av_interleaved_write_frame` bookkeeping. If the
    /// write callback set `fatalIOError` (init/segment/playlist write to disk
    /// failed), rethrow immediately. Otherwise track consecutive failures and
    /// throw `DVWriterError.muxWriteFailures` when the threshold is reached
    /// (or immediately for unambiguously-fatal codes).
    private func evaluateMuxWriteResult(_ rc: Int32, packet: UnsafeMutablePointer<AVPacket>? = nil) throws {
        try throwIfFatalIOError()
        if rc < 0 {
            consecutiveMuxWriteFailures += 1
            let detail = Self.ffmpegError(rc)
            Self.logger.error(
                "av_interleaved_write_frame failed: rc=\(rc) (\(detail, privacy: .public)) consecutive=\(self.consecutiveMuxWriteFailures)"
            )
            if rc == avErrorInvalidData
                || consecutiveMuxWriteFailures >= Self.maxConsecutiveMuxWriteFailures {
                throw DVWriterError.muxWriteFailures(
                    lastRC: rc,
                    consecutive: consecutiveMuxWriteFailures
                )
            }
            return
        }
        consecutiveMuxWriteFailures = 0
        if let packet {
            recordMuxedPacketTimestamps(packet)
        }
    }

    private func emitSourceDownloadStatsIfNeeded(force: Bool = false) {
        guard let inputCtx,
              let ioContext = inputCtx.pointee.pb else {
            return
        }
        let bytesRead = Int64(ioContext.pointee.bytes_read)
        guard bytesRead > 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard let previousWallTime = lastSourceStatsWallTime,
              let previousBytesRead = lastSourceStatsBytesRead else {
            lastSourceStatsWallTime = now
            lastSourceStatsBytesRead = bytesRead
            onSourceDownloadStats?(nil, bytesRead)
            return
        }

        let elapsed = now - previousWallTime
        guard force || elapsed >= 1 else { return }

        let byteDelta = bytesRead - previousBytesRead
        let bitsPerSecond = elapsed > 0 && byteDelta > 0
            ? Double(byteDelta) * 8 / elapsed
            : nil
        lastSourceStatsWallTime = now
        lastSourceStatsBytesRead = bytesRead
        onSourceDownloadStats?(bitsPerSecond, bytesRead)
        if Self.traceThroughput {
            cmpLog("[CMP-AVP] loopback throughput stages \(throughputTiming.logLine)")
            throughputTiming.reset()
        }
    }

    // MARK: - Setup

    private func prepareOutputDirectory() throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func openInput() throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard ctx != nil else {
            throw DVWriterError.allocInput
        }

        // Install an interrupt callback so `stop()` can unblock an in-flight
        // network read. FFmpeg polls this between / during I/O ops; returning
        // 1 causes `av_read_frame` (or open/probe) to bail with AVERROR_EXIT.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ctx!.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                let writer = Unmanaged<DVSegmentWriter>.fromOpaque(opaque).takeUnretainedValue()
                return writer.isCancelled ? 1 : 0
            },
            opaque: selfPtr
        )

        var options: OpaquePointer?
        if !sourceHeaders.isEmpty {
            let headerString = sourceHeaders
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n") + "\r\n"
            av_dict_set(&options, "headers", headerString, 0)
        }
        // Reasonable network timeout — 10 s — so a broken source doesn't
        // hang the mux loop forever.
        av_dict_set(&options, "rw_timeout", "10000000", 0)
        // Cap probe cost. We only mux video + the selected audio stream
        // (subtitles, fonts, attachments, extra audio are dropped at mux
        // time — see filtering below and at packet copy in the main loop).
        // Without these caps, a multi-track MKV with many embedded
        // subtitle streams (especially PGS) makes
        // `avformat_find_stream_info` walk every stream up to `probesize`
        // looking for codec params it will never find, costing several
        // seconds of bootstrap time on 4K resume seeks.
        av_dict_set(&options, "analyzeduration", "500000", 0) // 500 ms
        av_dict_set(&options, "probesize", "1000000", 0)      // 1 MiB

        let inputLocation = sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
        let rc = avformat_open_input(&ctx, inputLocation, nil, &options)
        av_dict_free(&options)
        if rc < 0 {
            throw DVWriterError.openInput(rc)
        }
        guard let openedContext = ctx else {
            throw DVWriterError.allocInput
        }
        inputCtx = openedContext

        // Tell ffmpeg to skip every stream we won't mux. This both shortens
        // `avformat_find_stream_info` (no per-stream probe-to-`probesize`
        // for subs that have no header) and prevents `av_read_frame` from
        // delivering packets we'd otherwise drop in the main loop.
        // The selected audio is resolved up-front from sessionSpec so
        // unselected audio streams can be discarded too — without this,
        // bootstrap reads ~800 packets from the unselected audio track
        // looking for the first video keyframe before realizing they go
        // straight to the floor.
        videoInputStreamIndex = try Self.resolveSelectedVideoStreamIndex(
            in: openedContext,
            videoMode: videoMode
        )

        Self.discardUnusedStreamsForMux(
            in: openedContext,
            keepVideoIndex: videoInputStreamIndex,
            keepAudioOrdinal: shouldIncludeAudio ? selectedAudioTrackIndex : -1,
            keepAudioFfIndex: sessionSpec.selectedAudio.ffIndex
        )

        if avformat_find_stream_info(openedContext, nil) < 0 {
            throw DVWriterError.findStreamInfo
        }

        try seekInputToStartTimeIfNeeded(openedContext)
    }

    /// Marks every stream we won't mux as `AVDISCARD_ALL` so libavformat
    /// skips them during `find_stream_info` and `av_read_frame`. Discards
    /// (a) all non-audio / non-video streams unconditionally and (b) every
    /// audio stream other than the one selected by ordinal `keepAudioOrdinal`
    /// or explicit `keepAudioFfIndex`. Pass `keepAudioOrdinal=-1` to drop
    /// audio entirely.
    private static func discardUnusedStreamsForMux(
        in ctx: UnsafeMutablePointer<AVFormatContext>,
        keepVideoIndex: Int,
        keepAudioOrdinal: Int,
        keepAudioFfIndex: Int?
    ) {
        let nb = Int(ctx.pointee.nb_streams)
        var discardedSubtitles = 0
        var discardedOther = 0
        var discardedExtraVideo = 0
        var discardedExtraAudio = 0
        var keptVideo = 0
        var keptAudio = 0
        var audioOrdinal = 0
        if let streams = ctx.pointee.streams {
            for i in 0..<nb {
                guard let stream = streams[i] else { continue }
                let mediaType = stream.pointee.codecpar.pointee.codec_type
                if mediaType == AVMEDIA_TYPE_VIDEO {
                    if i == keepVideoIndex {
                        keptVideo += 1
                    } else {
                        stream.pointee.discard = AVDISCARD_ALL
                        discardedExtraVideo += 1
                    }
                    continue
                }
                if mediaType == AVMEDIA_TYPE_AUDIO {
                    let isSelected: Bool
                    if let ff = keepAudioFfIndex, ff >= 0 {
                        isSelected = (i == ff)
                    } else if keepAudioOrdinal >= 0 {
                        isSelected = (audioOrdinal == keepAudioOrdinal)
                    } else {
                        isSelected = false
                    }
                    audioOrdinal += 1
                    if isSelected {
                        keptAudio += 1
                    } else {
                        stream.pointee.discard = AVDISCARD_ALL
                        discardedExtraAudio += 1
                    }
                    continue
                }
                stream.pointee.discard = AVDISCARD_ALL
                if mediaType == AVMEDIA_TYPE_SUBTITLE {
                    discardedSubtitles += 1
                } else {
                    discardedOther += 1
                }
            }
        }
        // Log unconditionally — we want to confirm this ran even when the
        // walk finds nothing yet (e.g. some demuxers populate streams
        // lazily inside avformat_find_stream_info).
        cmpLog("[CMP-AVP] mux probe filter total=\(nb) keptVideo=\(keptVideo) keptAudio=\(keptAudio) discardedExtraVideo=\(discardedExtraVideo) discardedExtraAudio=\(discardedExtraAudio) discardedSubtitles=\(discardedSubtitles) discardedOther=\(discardedOther)")
    }

    private static func resolveSelectedVideoStreamIndex(
        in ctx: UnsafeMutablePointer<AVFormatContext>,
        videoMode: LoopbackSessionSpec.VideoMode
    ) throws -> Int {
        let preferredCodec: AVCodecID = switch videoMode {
        case .passthroughH264:
            AV_CODEC_ID_H264
        case .convertProfile7To81, .passthroughProfile8, .passthroughProfile5, .passthroughHEVC:
            AV_CODEC_ID_HEVC
        }

        let nb = Int(ctx.pointee.nb_streams)
        var fallbackIndex: Int?
        var selectedLog = "none"
        if let streams = ctx.pointee.streams {
            for i in 0..<nb {
                guard let stream = streams[i], let codecpar = stream.pointee.codecpar else { continue }
                guard codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
                let codecID = codecpar.pointee.codec_id
                guard codecID == AV_CODEC_ID_HEVC || codecID == AV_CODEC_ID_H264 else { continue }
                if fallbackIndex == nil {
                    fallbackIndex = i
                }
                if codecID == preferredCodec {
                    selectedLog = Self.videoStreamLog(index: i, stream: stream)
                    cmpLog("[CMP-AVP] selected video stream \(selectedLog) preferred=1")
                    return i
                }
            }
        }

        if let fallbackIndex,
           let stream = ctx.pointee.streams?[fallbackIndex] {
            selectedLog = Self.videoStreamLog(index: fallbackIndex, stream: stream)
            cmpLog("[CMP-AVP] selected video stream \(selectedLog) preferred=0")
            return fallbackIndex
        }

        throw DVWriterError.noStreams
    }

    private static func videoStreamLog(
        index: Int,
        stream: UnsafeMutablePointer<AVStream>
    ) -> String {
        guard let codecpar = stream.pointee.codecpar else { return "index=\(index) codec=unknown" }
        let codecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
        return "index=\(index) codec=\(codecName) codecId=\(codecpar.pointee.codec_id.rawValue) size=\(codecpar.pointee.width)x\(codecpar.pointee.height) disposition=\(stream.pointee.disposition)"
    }

    private func seekInputToStartTimeIfNeeded(
        _ ctx: UnsafeMutablePointer<AVFormatContext>
    ) throws {
        guard sourceStartTimeSeconds.isFinite, sourceStartTimeSeconds > 0 else { return }

        let timestamp = Int64(sourceStartTimeSeconds * Double(AV_TIME_BASE))
        var result = avformat_seek_file(
            ctx,
            -1,
            Int64.min,
            timestamp,
            Int64.max,
            AVSEEK_FLAG_BACKWARD
        )
        if result < 0 {
            result = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        }
        guard result >= 0 else {
            Self.logger.error(
                "[CMP-AVP] loopback source seek failed requested=\(self.sourceStartTimeSeconds, privacy: .public) rc=\(result, privacy: .public)"
            )
            throw DVWriterError.seekInput(result)
        }

        avformat_flush(ctx)
        cmpLog("[CMP-AVP] loopback source seek requested=\(sourceStartTimeSeconds) rc=\(result)")
    }

    /// Custom AVIOContext so the mp4 muxer's writes flow back into Swift
    /// where we can parse and split them into segment files.
    private func openOutput() throws {
        guard let inCtx = inputCtx else {
            throw DVWriterError.allocOutput
        }
        selectedAudioStreamIndex = shouldIncludeAudio
            ? try resolveSelectedAudioStreamIndex(in: inCtx)
            : -1

        let bufSize = 64 * 1024
        guard let buf = av_malloc(bufSize)?.assumingMemoryBound(to: UInt8.self) else {
            throw DVWriterError.allocOutput
        }
        ioBuffer = buf

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let avio = avio_alloc_context(
            buf, Int32(bufSize),
            /* write_flag */ 1,
            selfPtr,
            /* read_packet */ nil,
            /* write_packet */ { opaque, bufPtr, bufSize in
                guard let opaque, let bufPtr else { return 0 }
                let writer = Unmanaged<DVSegmentWriter>.fromOpaque(opaque).takeUnretainedValue()
                let slice = UnsafeBufferPointer(start: bufPtr, count: Int(bufSize))
                if DVSegmentWriter.traceThroughput {
                    let started = CFAbsoluteTimeGetCurrent()
                    writer.ingestMuxerBytes(slice)
                    writer.throughputTiming.muxIOMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                    writer.throughputTiming.muxIOCalls += 1
                } else {
                    writer.ingestMuxerBytes(slice)
                }
                return bufSize
            },
            /* seek */ nil
        )
        guard let avio else {
            av_free(ioBuffer)
            ioBuffer = nil
            throw DVWriterError.allocOutput
        }
        ioContext = avio

        var out: UnsafeMutablePointer<AVFormatContext>?
        let rc = avformat_alloc_output_context2(&out, nil, "mp4", nil)
        if rc < 0 || out == nil {
            throw DVWriterError.allocOutput
        }
        out!.pointee.pb = avio
        outputCtx = out

        // Copy streams. For each source stream, allocate an output stream,
        // copy its codecpar, then patch codec_tag for AVPlayer consumption:
        // `dvh1` for Dolby Vision, `hvc1` for plain HEVC HDR/SDR, or `avc1`
        // for H.264 passthrough.
        guard let outCtx = outputCtx else {
            throw DVWriterError.allocOutput
        }
        let nbStreams = Int(inCtx.pointee.nb_streams)
        for i in 0..<nbStreams {
            guard let inStream = inCtx.pointee.streams?[i] else { continue }
            let codecpar = inStream.pointee.codecpar!
            let mediaType = codecpar.pointee.codec_type

            if mediaType != AVMEDIA_TYPE_VIDEO && mediaType != AVMEDIA_TYPE_AUDIO {
                continue
            }
            if mediaType == AVMEDIA_TYPE_VIDEO && i != videoInputStreamIndex {
                continue
            }
            if mediaType == AVMEDIA_TYPE_AUDIO && (!shouldIncludeAudio || i != selectedAudioStreamIndex) {
                continue
            }

            guard let outStream = avformat_new_stream(outCtx, nil) else {
                throw DVWriterError.allocOutput
            }

            if mediaType == AVMEDIA_TYPE_VIDEO {
                if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) < 0 {
                    throw DVWriterError.allocOutput
                }
                outStream.pointee.time_base = inStream.pointee.time_base
                outStream.pointee.codecpar.pointee.codec_tag = 0
                let dovi = outputDoviConfig(from: readDoviConfig(codecpar: codecpar))
                let removedDoviSideData = removeDoviSideData(codecpar: outStream.pointee.codecpar)
                outStream.pointee.codecpar.pointee.codec_tag = sampleEntryTag(for: videoMode.sampleEntryCodec)
                videoInputStreamIndex = i
                let edSize = Int(codecpar.pointee.extradata_size)
                if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
                   edSize >= 22,
                   let edPtr = codecpar.pointee.extradata {
                    let sourceHvcc = Data(bytes: edPtr, count: edSize)
                    let outputHvcc = outputHvcCConfig(from: sourceHvcc)
                    inputHvccHeader = outputHvcc
                    nalLengthSize = Int((edPtr[21] & 0x03) + 1)
                    if outputHvcc != sourceHvcc {
                        setExtradata(codecpar: outStream.pointee.codecpar, data: outputHvcc)
                    }
                } else if codecpar.pointee.codec_id == AV_CODEC_ID_H264,
                          edSize >= 5,
                          let edPtr = codecpar.pointee.extradata {
                    inputAvccHeader = Data(bytes: edPtr, count: edSize)
                    nalLengthSize = Int((edPtr[4] & 0x03) + 1)
                }
                doviConfig = dovi
                doviRecord = dovi.flatMap(parseDoviRecord(from:))
                let codecTag = videoMode.sampleEntryCodec
                let doviLog = dovi.flatMap(parseDoviRecord(from:))?.logLine ?? "none"
                print("[CMP-AVP] out video codecpar tag=\(codecTag) initial extradataSize=\(edSize) nalLen=\(nalLengthSize) videoMode=\(videoMode.logToken) dovi=\(doviLog) removedDoviSideData=\(removedDoviSideData)")
            } else if selectedAudioOutputMode == .copy {
                if !audioCodecSupportsMp4Mux(codecpar.pointee.codec_id) {
                    let codecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
                    throw DVWriterError.unsupportedSelectedAudioCodec(codecName)
                }
                if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) < 0 {
                    throw DVWriterError.allocOutput
                }
                if codecpar.pointee.sample_rate > 0 {
                    outStream.pointee.time_base = AVRational(num: 1, den: codecpar.pointee.sample_rate)
                } else {
                    outStream.pointee.time_base = inStream.pointee.time_base
                }
                outStream.pointee.codecpar.pointee.codec_tag = 0
                ensureAudioFrameSize(codecpar: outStream.pointee.codecpar)
                outputAudioCodecID = codecpar.pointee.codec_id
                outputAudioCodecToken = codecToken(for: codecpar.pointee.codec_id)
                let codecName = outputAudioCodecToken ?? String(cString: avcodec_get_name(codecpar.pointee.codec_id))
                print("[CMP-AVP] selected audio copy sourceStream=\(i) codec=\(codecName) channels=\(codecpar.pointee.ch_layout.nb_channels)")
            } else {
                try openAudioTranscodePipeline(
                    inputStream: inStream,
                    inputStreamIndex: i,
                    outputStream: outStream
                )
            }

                let outIndex = Int(outCtx.pointee.nb_streams) - 1
                let trackID = UInt32(outIndex + 1)
                outStream.pointee.id = Int32(trackID)
                trackTimeBasesByID[trackID] = outStream.pointee.time_base
                if mediaType == AVMEDIA_TYPE_VIDEO {
                    videoOutputTrackID = trackID
                }
                streamMap[i] = outIndex
            }

        if streamMap.isEmpty {
            throw DVWriterError.noStreams
        }

        if shouldIncludeAudio {
            Self.logger.info(
                "[CMP-AVP] selected audio trackIndex=\(self.selectedAudioTrackIndex, privacy: .public) resolvedStreamIndex=\(self.selectedAudioStreamIndex, privacy: .public) codec=\(self.sessionSpec.selectedAudio.sourceCodec ?? "unknown", privacy: .public)"
            )
        } else {
            print("[CMP-AVP] no selected audio stream; emitting video-only loopback")
        }
    }

    private func resolveSelectedAudioStreamIndex(
        in inputCtx: UnsafeMutablePointer<AVFormatContext>
    ) throws -> Int {
        if let explicitStreamIndex = sessionSpec.selectedAudio.ffIndex,
           explicitStreamIndex >= 0,
           explicitStreamIndex < Int(inputCtx.pointee.nb_streams),
           let stream = inputCtx.pointee.streams?[explicitStreamIndex],
           stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            return explicitStreamIndex
        }

        var audioOrdinal = 0
        for i in 0 ..< Int(inputCtx.pointee.nb_streams) {
            guard let stream = inputCtx.pointee.streams?[i] else { continue }
            guard stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            if audioOrdinal == selectedAudioTrackIndex {
                return i
            }
            audioOrdinal += 1
        }

        throw DVWriterError.audioTranscodeSetup(
            "selected audio track \(selectedAudioTrackIndex) was not found in source stream map"
        )
    }

    /// Drain a queue of prefetched packets to the muxer. Each packet's
    /// input stream_index is read off the packet itself and mapped to the
    /// output stream via `streamMap`. Every packet is freed, and the queue
    /// is cleared — including on the unmapped-stream early-skip path — so
    /// no caller can leak packets by assuming the queue was drained.
    private func flushPendingPackets(_ queue: inout [UnsafeMutablePointer<AVPacket>],
                                     label: String,
                                     outCtx: UnsafeMutablePointer<AVFormatContext>) throws {
        var index = 0
        defer {
            // Free any packets we did not get to (write threw partway). Each
            // successfully-processed packet is already freed by the inner
            // defer below; this only drains the unprocessed tail. `teardown`
            // will then clear the queue.
            while index < queue.count {
                var free: UnsafeMutablePointer<AVPacket>? = queue[index]
                av_packet_free(&free)
                index += 1
            }
            queue.removeAll()
        }
        while index < queue.count {
            let pending = queue[index]
            index += 1
            let inIdx = Int(pending.pointee.stream_index)
            defer {
                var free: UnsafeMutablePointer<AVPacket>? = pending
                av_packet_free(&free)
            }
            guard let outIdx = streamMap[inIdx] else { continue }
            if vodActive, vodShouldDropPacket(pkt: pending, inputIdx: inIdx) { continue }
            if inIdx == videoInputStreamIndex {
                try vodCutBeforeVideoPacketIfNeeded(pkt: pending)
            }
            rewritePacketForOutput(pkt: pending,
                                   outStreamIndex: Int32(outIdx),
                                   inputStreamIndex: inIdx)
            let wr = av_interleaved_write_frame(outCtx, pending)
            do {
                try evaluateMuxWriteResult(wr, packet: pending)
            } catch {
                Self.logger.error("pending \(label, privacy: .public) write failed")
                throw error
            }
        }
    }

    /// Pre-read input packets until we've seen a video keyframe containing
    /// VPS/SPS/PPS NAL units. Extract those NALs, synthesise a full HVCC
    /// extradata, and install it on the output codecpar.
    ///
    /// MKV delivers HEVC as length-prefixed NAL units (AVCC-style), NOT
    /// Annex-B. FFmpeg's `extract_extradata` BSF assumes Annex-B by default,
    /// which is why it errored with "No start code is found" here. Manual
    /// parsing sidesteps the BSF entirely — we read the length prefix (size
    /// determined by HVCC byte 21), identify NAL type by `(byte[0] >> 1) & 0x3F`
    /// (HEVC NAL header is 2 bytes, type is bits 1-6 of the first byte), and
    /// collect any VPS(32) / SPS(33) / PPS(34) NALs we encounter.
    ///
    /// The prefetched packet is held in `pendingVideoPackets` and replayed to
    /// the muxer after `writeHeader` emits a hvcC-complete moov.
    private func bootstrapVideoExtradata() throws {
        guard let inCtx = inputCtx, let outCtx = outputCtx,
              let header = inputHvccHeader else {
            return
        }
        guard let videoOutIdx = streamMap[videoInputStreamIndex],
              let outStream = outCtx.pointee.streams?[videoOutIdx] else {
            return
        }

        let avNoPTS = Int64.min
        var vps: [Data] = []
        var sps: [Data] = []
        var pps: [Data] = []
        var totalPacketsRead = 0
        var videoPacketsRead = 0
        var droppedPreVideoPackets = 0
        var retainedPreVideoAudioBytes = 0
        var droppedPreVideoAudioPackets = 0
        var firstKeyframeNALSummary = "none"
        let maxPackets = 8_000
        let maxVideoPackets = 128
        // Keep the newest selected pre-video audio packets. TrueHD major_sync
        // units recur, but the first video keyframe can arrive after a long
        // audio preroll; a prefix cap drops the newer sync candidates. The
        // packet and byte caps bound memory while preserving the tail nearest
        // the first video packet.
        let maxQueuedPreVideoAudio = DVPreVideoAudioTailPolicy.maxPackets
        let maxQueuedPreVideoAudioBytes = DVPreVideoAudioTailPolicy.maxBytes
        let headerHasParameterSets = ISOBoxSurgery.hvcCContainsParameterSets(header)
        let keepSelectedAudioPreroll = shouldIncludeAudio && selectedAudioOutputMode != .copy

        while totalPacketsRead < maxPackets, videoPacketsRead < maxVideoPackets {
            let readPkt = av_packet_alloc()
            let rc = av_read_frame(inCtx, readPkt)
            if rc < 0 {
                var free = readPkt
                av_packet_free(&free)
                break
            }
            emitSourceDownloadStatsIfNeeded()
            guard let pkt = readPkt else { break }
            totalPacketsRead += 1
            let inIdx = Int(pkt.pointee.stream_index)

            if pkt.pointee.dts == avNoPTS || pkt.pointee.pts == avNoPTS {
                var free = readPkt
                av_packet_free(&free)
                droppedPreVideoPackets += 1
                continue
            }
            if inIdx != videoInputStreamIndex {
                // We drop other streams (extra audio tracks, subtitles) so the
                // HLS output doesn't start on audio-only preroll. But the
                // selected audio stream's pre-video packets are kept: TrueHD's
                // decoder needs a `major_sync` access unit to establish stream
                // parameters, and that unit almost always lives in the audio
                // packets that precede the first video keyframe. Dropping
                // them here would force the decoder to skip frames for ~100ms
                // of output until the next major_sync arrives. Packets are
                // replayed through transcodeAudioPacket in
                // flushPendingAudioPackets (called after writeHeader).
                if keepSelectedAudioPreroll,
                   inIdx == selectedAudioStreamIndex {
                    retainPreVideoAudioPacket(
                        pkt,
                        maxPackets: maxQueuedPreVideoAudio,
                        maxBytes: maxQueuedPreVideoAudioBytes,
                        retainedBytes: &retainedPreVideoAudioBytes,
                        droppedPackets: &droppedPreVideoAudioPackets
                    )
                } else {
                    var free = readPkt
                    av_packet_free(&free)
                    droppedPreVideoPackets += 1
                }
                continue
            }

            videoPacketsRead += 1
            let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
            guard isKeyframe else {
                var free = readPkt
                av_packet_free(&free)
                droppedPreVideoPackets += 1
                continue
            }

            // Scan this packet's length-prefixed NAL units for param sets.
            try transformVideoPacketIfNeeded(pkt)
            if let dataPtr = pkt.pointee.data {
                let size = Int(pkt.pointee.size)
                let packetBytes = UnsafeBufferPointer(start: dataPtr, count: size)
                firstKeyframeNALSummary = ISOBoxSurgery.nalSummary(
                    packetBytes: packetBytes,
                    nalLengthSize: nalLengthSize
                )
                ISOBoxSurgery.scanNALs(packetBytes: packetBytes,
                                       nalLengthSize: nalLengthSize,
                                       vps: &vps, sps: &sps, pps: &pps)
            }
            pendingVideoPackets.append(pkt)

            if (!vps.isEmpty && !sps.isEmpty && !pps.isEmpty) || headerHasParameterSets {
                break
            }
        }

        guard !pendingVideoPackets.isEmpty else {
            let syncFound = isSelectedAudioTrueHD()
                ? firstMLPMajorSyncIndex(in: pendingAudioPackets) != nil
                : false
            print("[CMP-AVP] bootstrap gave up: vps=\(vps.count) sps=\(sps.count) pps=\(pps.count) videoPackets=\(videoPacketsRead) totalPackets=\(totalPacketsRead) droppedPreVideo=\(droppedPreVideoPackets) retainedAudio=\(pendingAudioPackets.count) retainedAudioBytes=\(retainedPreVideoAudioBytes) droppedPreVideoAudio=\(droppedPreVideoAudioPackets) trueHDSyncFound=\(syncFound ? 1 : 0)")
            return
        }

        if !vps.isEmpty, !sps.isEmpty, !pps.isEmpty {
            let hvcc = ISOBoxSurgery.buildHvcC(header: header, vps: vps, sps: sps, pps: pps)
            setExtradata(codecpar: outStream.pointee.codecpar, data: hvcc)
            inputHvccHeader = hvcc
        } else if !headerHasParameterSets {
            print("[CMP-AVP] bootstrap keyframe found but no VPS/SPS/PPS available in packet or hvcC")
        }
        if let inStream = inCtx.pointee.streams?[videoInputStreamIndex] {
            doviConfig = outputDoviConfig(from: readDoviConfig(codecpar: inStream.pointee.codecpar))
            doviRecord = doviConfig.flatMap(parseDoviRecord(from:))
        }
        let doviLog = doviRecord?.logLine ?? "none"
        let syncFound = isSelectedAudioTrueHD()
            ? firstMLPMajorSyncIndex(in: pendingAudioPackets) != nil
            : false
        print("[CMP-AVP] bootstrap OK: hvcCParams=\(headerHasParameterSets ? 1 : 0) vps=\(vps.count) sps=\(sps.count) pps=\(pps.count) videoPackets=\(videoPacketsRead) totalPackets=\(totalPacketsRead) droppedPreVideo=\(droppedPreVideoPackets) pendingVideo=\(pendingVideoPackets.count) retainedAudio=\(pendingAudioPackets.count) retainedAudioBytes=\(retainedPreVideoAudioBytes) droppedPreVideoAudio=\(droppedPreVideoAudioPackets) trueHDSyncFound=\(syncFound ? 1 : 0) firstVideoNALs=\(firstKeyframeNALSummary) dovi=\(doviLog)")
    }

    private func retainPreVideoAudioPacket(
        _ packet: UnsafeMutablePointer<AVPacket>,
        maxPackets: Int,
        maxBytes: Int,
        retainedBytes: inout Int,
        droppedPackets: inout Int
    ) {
        let packetBytes = max(0, Int(packet.pointee.size))
        let existingByteSizes = pendingAudioPackets.map { max(0, Int($0.pointee.size)) }
        guard let headDropCount = DVPreVideoAudioTailPolicy.headDropCountBeforeAppending(
            existingByteSizes: existingByteSizes,
            retainedBytes: retainedBytes,
            incomingBytes: packetBytes,
            maxPackets: maxPackets,
            maxBytes: maxBytes
        ) else {
            var free: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&free)
            droppedPackets += 1
            return
        }

        for _ in 0..<headDropCount {
            let dropped = pendingAudioPackets.removeFirst()
            retainedBytes = max(0, retainedBytes - max(0, Int(dropped.pointee.size)))
            var free: UnsafeMutablePointer<AVPacket>? = dropped
            av_packet_free(&free)
            droppedPackets += 1
        }

        pendingAudioPackets.append(packet)
        retainedBytes += packetBytes
    }

    /// Pull the first `AV_PKT_DATA_DOVI_CONF` entry from a codec parameters'
    /// `coded_side_data` array, copied into a Swift `Data` for easy access.
    private func readDoviConfig(codecpar: UnsafeMutablePointer<AVCodecParameters>?) -> Data? {
        guard let cp = codecpar,
              let arr = cp.pointee.coded_side_data else { return nil }
        let n = Int(cp.pointee.nb_coded_side_data)
        for i in 0..<n {
            let entry = arr[i]
            guard entry.type == AV_PKT_DATA_DOVI_CONF,
                  let src = entry.data, entry.size > 0 else { continue }
            return Data(bytes: src, count: entry.size)
        }
        return nil
    }

    @discardableResult
    private func removeDoviSideData(codecpar: UnsafeMutablePointer<AVCodecParameters>?) -> Int {
        guard let cp = codecpar,
              let sideData = cp.pointee.coded_side_data,
              cp.pointee.nb_coded_side_data > 0 else {
            return 0
        }
        let before = cp.pointee.nb_coded_side_data
        av_packet_side_data_remove(sideData, &cp.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
        return Int(before - cp.pointee.nb_coded_side_data)
    }

    private func parseDoviRecord(from data: Data) -> DoviRecord? {
        guard data.count >= 8 else { return nil }
        let bytes = Array(data.prefix(8))
        return DoviRecord(
            versionMajor: bytes[0],
            versionMinor: bytes[1],
            profile: bytes[2],
            level: bytes[3],
            rpuPresent: bytes[4] != 0,
            elPresent: bytes[5] != 0,
            blPresent: bytes[6] != 0,
            compatibilityID: bytes[7]
        )
    }

    private func sampleEntryTag(for token: String) -> UInt32 {
        let chars = Array(token)
        guard chars.count == 4 else {
            return UInt32(MKTAG("h", "v", "c", "1"))
        }
        return UInt32(MKTAG(chars[0], chars[1], chars[2], chars[3]))
    }

    private func codecToken(for codecID: AVCodecID) -> String? {
        switch codecID {
        case AV_CODEC_ID_EAC3:
            return "ec-3"
        case AV_CODEC_ID_AC3:
            return "ac-3"
        case AV_CODEC_ID_AAC:
            return "mp4a.40.2"
        default:
            return nil
        }
    }

    private func masterCodecString() -> String {
        var codecs: [String] = [masterVideoCodecString()]
        if let outputAudioCodecToken {
            codecs.append(outputAudioCodecToken)
        }
        return codecs.joined(separator: ",")
    }

    private func masterVideoCodecString() -> String {
        let sampleEntry = masterManifestSampleEntryCodec()
        if videoMode == .passthroughH264 {
            return h264RFC6381CodecString(avccHeader: inputAvccHeader) ?? sampleEntry
        }
        return hevcRFC6381CodecString(sampleEntry: sampleEntry, hvccHeader: inputHvccHeader)
            ?? sampleEntry
    }

    private func masterManifestSampleEntryCodec() -> String {
        switch videoMode {
        case .convertProfile7To81, .passthroughProfile8:
            // Dolby Vision Profile 8.x is base-layer-compatible (HDR10 for 8.1,
            // HLG for 8.4). Apple HLS signaling keeps the base HEVC codec in
            // CODECS and advertises Dolby Vision through SUPPLEMENTAL-CODECS.
            return "hvc1"
        case .passthroughProfile5, .passthroughHEVC, .passthroughH264:
            return videoMode.sampleEntryCodec
        }
    }

    private func h264RFC6381CodecString(avccHeader: Data?) -> String? {
        guard let header = avccHeader, header.count >= 4 else { return nil }
        return String(format: "avc1.%02X%02X%02X", header[1], header[2], header[3])
    }

    private func hevcRFC6381CodecString(sampleEntry: String, hvccHeader: Data?) -> String? {
        guard let header = hvccHeader, header.count >= 13 else { return nil }

        let profileTierByte = header[1]
        let profileSpace = Int((profileTierByte & 0xC0) >> 6)
        let tierFlag = (profileTierByte & 0x20) != 0
        let profileIDC = Int(profileTierByte & 0x1F)

        let compatibilityRaw =
            (UInt32(header[2]) << 24) |
            (UInt32(header[3]) << 16) |
            (UInt32(header[4]) << 8) |
            UInt32(header[5])
        let compatibilityFlags = reversedBits32(compatibilityRaw)
        let compatibilityString = String(compatibilityFlags, radix: 16, uppercase: true)

        let levelIDC = Int(header[12])
        let profileSpacePrefix: String = switch profileSpace {
        case 1: "A"
        case 2: "B"
        case 3: "C"
        default: ""
        }

        let constraintBytes = Array(header[6...11])
        let lastNonZeroConstraintIndex = constraintBytes.lastIndex(where: { $0 != 0 })
        let constraintString = lastNonZeroConstraintIndex.map { lastIndex in
            constraintBytes[0...lastIndex]
                .map { String(format: "%02X", $0) }
                .joined()
        }

        var codec = "\(sampleEntry).\(profileSpacePrefix)\(profileIDC).\(compatibilityString).\(tierFlag ? "H" : "L")\(levelIDC)"
        if let constraintString, !constraintString.isEmpty {
            codec += ".\(constraintString)"
        }
        return codec
    }

    private func reversedBits32(_ value: UInt32) -> UInt32 {
        var input = value
        var output: UInt32 = 0
        for _ in 0..<32 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    private func supplementalCodecString() -> String? {
        let emitsSupplemental: Bool
        switch videoMode {
        case .convertProfile7To81, .passthroughProfile8:
            emitsSupplemental = true
        case .passthroughProfile5, .passthroughHEVC, .passthroughH264:
            emitsSupplemental = false
        }
        guard emitsSupplemental,
              let profile = manifestMetadata.advertisedDolbyVisionProfile else {
            return nil
        }
        let level = doviRecord?.level ?? 0
        let compat = manifestMetadata.compatibilityBrand ?? "db1p"
        return String(format: "dvh1.%02d.%02d/%@", profile, level, compat)
    }

    private func outputDoviConfig(from data: Data?) -> Data? {
        guard let data else { return nil }
        switch videoMode {
        case .convertProfile7To81:
            return derivedProfile81DoviConfig(from: data) ?? data
        case .passthroughProfile5, .passthroughProfile8:
            return data
        case .passthroughHEVC, .passthroughH264:
            return nil
        }
    }

    private func derivedProfile81DoviConfig(from data: Data?) -> Data? {
        guard var bytes = data, bytes.count >= 8 else { return nil }
        bytes[2] = 8
        bytes[4] = 1
        bytes[5] = 0
        bytes[6] = 1
        bytes[7] = 1
        return bytes
    }

    private func outputHvcCConfig(from source: Data) -> Data {
        guard videoMode == .convertProfile7To81,
              let filtered = profile81HvcCConfig(from: source) else {
            return source
        }
        return filtered
    }

    private func profile81HvcCConfig(from source: Data) -> Data? {
        guard source.count >= 23 else { return nil }

        var cursor = 23
        let declaredArrayCount = Int(source[22])
        var arrayPayload = Data()
        var keptArrayCount = 0
        var removedNALCount = 0

        for _ in 0..<declaredArrayCount {
            guard cursor + 3 <= source.count else { return nil }
            let arrayHeader = source[cursor]
            cursor += 1
            let nalCount = (Int(source[cursor]) << 8) | Int(source[cursor + 1])
            cursor += 2

            var keptNALs: [Data] = []
            for _ in 0..<nalCount {
                guard cursor + 2 <= source.count else { return nil }
                let nalSize = (Int(source[cursor]) << 8) | Int(source[cursor + 1])
                cursor += 2
                guard cursor + nalSize <= source.count else { return nil }
                let nal = Data(source[cursor..<(cursor + nalSize)])
                cursor += nalSize

                if shouldKeepProfile81HvcCNAL(nal) {
                    keptNALs.append(nal)
                } else {
                    removedNALCount += 1
                }
            }

            guard !keptNALs.isEmpty else { continue }
            keptArrayCount += 1
            arrayPayload.append(arrayHeader)
            arrayPayload.append(UInt8((keptNALs.count >> 8) & 0xFF))
            arrayPayload.append(UInt8(keptNALs.count & 0xFF))
            for nal in keptNALs {
                arrayPayload.append(UInt8((nal.count >> 8) & 0xFF))
                arrayPayload.append(UInt8(nal.count & 0xFF))
                arrayPayload.append(nal)
            }
        }

        guard keptArrayCount > 0 else { return nil }

        var output = Data(source.prefix(22))
        output.append(UInt8(keptArrayCount))
        output.append(arrayPayload)

        if removedNALCount > 0 || keptArrayCount != declaredArrayCount {
            print(
                "[CMP-AVP] profile7_to81_base_layer hvcC filtered for profile8.1 arrays \(declaredArrayCount)->\(keptArrayCount) removedNALs=\(removedNALCount)"
            )
        }
        return output
    }

    private func shouldKeepProfile81HvcCNAL(_ nal: Data) -> Bool {
        guard nal.count >= 2 else { return false }
        let byte0 = nal[nal.startIndex]
        let byte1 = nal[nal.index(after: nal.startIndex)]
        let nalType = Int((byte0 >> 1) & 0x3F)
        let layerID = Int(((byte0 & 0x01) << 5) | ((byte1 & 0xF8) >> 3))
        return layerID == 0 && nalType != 63
    }

    private func openAudioTranscodePipeline(
        inputStream: UnsafeMutablePointer<AVStream>,
        inputStreamIndex: Int,
        outputStream: UnsafeMutablePointer<AVStream>
    ) throws {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw DVWriterError.audioTranscodeSetup("audio decoder unavailable")
        }

        var decoderCtx = avcodec_alloc_context3(decoder)
        guard decoderCtx != nil else {
            throw DVWriterError.audioTranscodeSetup("audio decoder alloc failed")
        }
        if avcodec_parameters_to_context(decoderCtx, codecpar) < 0 || avcodec_open2(decoderCtx, decoder, nil) < 0 {
            avcodec_free_context(&decoderCtx)
            throw DVWriterError.audioTranscodeSetup("audio decoder open failed")
        }

        let sourceChannels = max(
            1,
            decoderCtx!.pointee.ch_layout.nb_channels > 0
                ? Int32(decoderCtx!.pointee.ch_layout.nb_channels)
                : Int32(sessionSpec.selectedAudio.sourceChannelCount ?? 2)
        )
        let sourceSampleRate = decoderCtx!.pointee.sample_rate > 0 ? decoderCtx!.pointee.sample_rate : 48_000

        let candidates = requestedAudioEncoderCandidates(for: selectedAudioOutputMode)
        var opened = false
        var lastError = "no encoder candidates"

        for candidate in candidates {
            guard let encoder = avcodec_find_encoder(candidate.codecID) else {
                lastError = "encoder missing \(candidate.codecToken)"
                continue
            }

            var encoderCtx = avcodec_alloc_context3(encoder)
            guard encoderCtx != nil else {
                lastError = "encoder alloc failed \(candidate.codecToken)"
                continue
            }

            let targetChannels = targetChannelCount(for: candidate.codecID, sourceChannels: sourceChannels)
            var targetLayout = AVChannelLayout()
            av_channel_layout_default(&targetLayout, targetChannels)

            encoderCtx!.pointee.sample_fmt = preferredSampleFormat(for: encoder)
            encoderCtx!.pointee.sample_rate = preferredSampleRate(
                for: encoder,
                preferred: sourceSampleRate
            )
            encoderCtx!.pointee.time_base = AVRational(num: 1, den: encoderCtx!.pointee.sample_rate)
            encoderCtx!.pointee.bit_rate = preferredBitRate(
                for: candidate.codecID,
                channelCount: targetChannels
            )
            encoderCtx!.pointee.ch_layout = targetLayout
            encoderCtx!.pointee.strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL
            if let oformat = outputCtx?.pointee.oformat,
               (oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
                encoderCtx!.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
            }

            let openR = avcodec_open2(encoderCtx, encoder, nil)
            if openR < 0 {
                lastError = "encoder open failed \(candidate.codecToken) rc=\(openR)"
                avcodec_free_context(&encoderCtx)
                continue
            }

            var inLayout = decoderCtx!.pointee.ch_layout
            if inLayout.nb_channels == 0 {
                av_channel_layout_default(&inLayout, sourceChannels)
            }
            var swr: OpaquePointer?
            let swrR = swr_alloc_set_opts2(
                &swr,
                &encoderCtx!.pointee.ch_layout,
                encoderCtx!.pointee.sample_fmt,
                encoderCtx!.pointee.sample_rate,
                &inLayout,
                decoderCtx!.pointee.sample_fmt,
                decoderCtx!.pointee.sample_rate,
                0,
                nil
            )
            if swrR < 0 || swr == nil || swr_init(swr) < 0 {
                lastError = "swr init failed \(candidate.codecToken)"
                if swr != nil {
                    swr_free(&swr)
                }
                avcodec_free_context(&encoderCtx)
                continue
            }

            outputStream.pointee.time_base = encoderCtx!.pointee.time_base
            if avcodec_parameters_from_context(outputStream.pointee.codecpar, encoderCtx) < 0 {
                lastError = "codecpar from encoder failed \(candidate.codecToken)"
                swr_free(&swr)
                avcodec_free_context(&encoderCtx)
                continue
            }
            outputStream.pointee.codecpar.pointee.codec_tag = 0
            ensureAudioFrameSize(codecpar: outputStream.pointee.codecpar)

            let initialFifoSamples = max(Int32(encoderCtx!.pointee.frame_size), 1024)
            let sampleFifo = av_audio_fifo_alloc(
                encoderCtx!.pointee.sample_fmt,
                Int32(targetChannels),
                initialFifoSamples
            )
            if sampleFifo == nil {
                lastError = "audio fifo alloc failed \(candidate.codecToken)"
                swr_free(&swr)
                avcodec_free_context(&encoderCtx)
                continue
            }

            audioDecoderCtx = decoderCtx
            audioEncoderCtx = encoderCtx
            audioSwrCtx = swr
            audioSampleFifo = sampleFifo
            outputAudioCodecID = candidate.codecID
            outputAudioCodecToken = candidate.codecToken
            audioOutputStreamIndex = Int(outputCtx?.pointee.nb_streams ?? 0) - 1
            nextEncodedAudioPTS = 0
            audioDecodedFrameCount = 0
            audioDecodeErrorCount = 0
            let sourceCodecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
            print(
                "[CMP-AVP] selected audio transcode sourceStream=\(inputStreamIndex) sourceCodec=\(sourceCodecName) outputCodec=\(candidate.codecToken) sourceChannels=\(sourceChannels) outputChannels=\(targetChannels) preservesAtmos=\(sessionSpec.selectedAudio.preservesAtmos ? 1 : 0) mode=\(sessionSpec.selectedAudio.outputMode.preferredCodecToken)"
            )
            opened = true
            break
        }

        if !opened {
            avcodec_free_context(&decoderCtx)
            throw DVWriterError.audioTranscodeSetup(lastError)
        }
    }

    private func requestedAudioEncoderCandidates(
        for mode: LoopbackSessionSpec.AudioOutputMode
    ) -> [(codecID: AVCodecID, codecToken: String)] {
        switch mode {
        case .copy:
            return []
        case .transcodeFLAC:
            return [
                (AV_CODEC_ID_FLAC, "fLaC"),
                (AV_CODEC_ID_EAC3, "ec-3"),
                (AV_CODEC_ID_AC3, "ac-3"),
                (AV_CODEC_ID_AAC, "mp4a.40.2"),
            ]
        case .requireFLAC:
            return [(AV_CODEC_ID_FLAC, "fLaC")]
        case .transcodeEC3:
            return [
                (AV_CODEC_ID_EAC3, "ec-3"),
                (AV_CODEC_ID_AC3, "ac-3"),
                (AV_CODEC_ID_AAC, "mp4a.40.2"),
            ]
        case .transcodeAC3:
            return [
                (AV_CODEC_ID_AC3, "ac-3"),
                (AV_CODEC_ID_AAC, "mp4a.40.2"),
            ]
        case .transcodeAAC:
            return [(AV_CODEC_ID_AAC, "mp4a.40.2")]
        }
    }

    private func targetChannelCount(for codecID: AVCodecID, sourceChannels: Int32) -> Int32 {
        switch codecID {
        case AV_CODEC_ID_AAC:
            return min(max(sourceChannels, 2), 2)
        case AV_CODEC_ID_FLAC:
            return min(max(sourceChannels, 2), 8)
        case AV_CODEC_ID_AC3:
            return min(max(sourceChannels, 2), 6)
        case AV_CODEC_ID_EAC3:
            return min(max(sourceChannels, 2), 8)
        default:
            return max(sourceChannels, 2)
        }
    }

    private func preferredBitRate(for codecID: AVCodecID, channelCount: Int32) -> Int64 {
        switch codecID {
        case AV_CODEC_ID_AAC:
            return channelCount > 2 ? 384_000 : 256_000
        case AV_CODEC_ID_AC3:
            return channelCount > 2 ? 640_000 : 384_000
        case AV_CODEC_ID_EAC3:
            return channelCount > 6 ? 1_024_000 : 768_000
        case AV_CODEC_ID_FLAC:
            return 0
        default:
            return 384_000
        }
    }

    private func preferredSampleRate(for codec: UnsafePointer<AVCodec>, preferred: Int32) -> Int32 {
        var configs: UnsafeRawPointer?
        var count: Int32 = 0
        let result = avcodec_get_supported_config(
            nil,
            codec,
            AV_CODEC_CONFIG_SAMPLE_RATE,
            0,
            &configs,
            &count
        )
        guard result >= 0, let configs, count > 0 else {
            return preferred
        }

        let supported = configs.bindMemory(to: Int32.self, capacity: Int(count))
        var first: Int32 = preferred
        for index in 0..<Int(count) {
            let value = supported[index]
            if index == 0 {
                first = value
            }
            if value == preferred || value == 48_000 {
                return value
            }
        }
        return first
    }

    private func preferredSampleFormat(for codec: UnsafePointer<AVCodec>) -> AVSampleFormat {
        var configs: UnsafeRawPointer?
        var count: Int32 = 0
        let result = avcodec_get_supported_config(
            nil,
            codec,
            AV_CODEC_CONFIG_SAMPLE_FORMAT,
            0,
            &configs,
            &count
        )
        guard result >= 0, let configs, count > 0 else {
            return AV_SAMPLE_FMT_FLTP
        }

        let formats = configs.bindMemory(to: AVSampleFormat.self, capacity: Int(count))
        var first = formats[0]
        for index in 0..<Int(count) {
            let format = formats[index]
            if index == 0 {
                first = format
            }
            if format == AV_SAMPLE_FMT_FLTP {
                return format
            }
        }
        return first
    }

    private func flushPendingAudioPackets(outCtx: UnsafeMutablePointer<AVFormatContext>) throws {
        if selectedAudioOutputMode == .copy {
            try flushPendingPackets(&pendingAudioPackets, label: "audio", outCtx: outCtx)
            return
        }
        // For TrueHD / MLP, drop everything up to the first packet that
        // carries a `major_sync_info` access unit. Feeding mid-stream MLP
        // frames before a sync makes the decoder emit ~30 "restart header
        // sync incorrect" / "Invalid blocksize" warnings while it realigns,
        // and the priming output is discarded anyway. The pre-major_sync
        // gap is at most ~170 ms (one major_sync interval).
        let trueHDSyncIndex = isSelectedAudioTrueHD()
            ? firstMLPMajorSyncIndex(in: pendingAudioPackets)
            : nil
        let primingStart = isSelectedAudioTrueHD()
            ? (trueHDSyncIndex ?? 0)
            : 0
        for index in 0..<primingStart {
            var free: UnsafeMutablePointer<AVPacket>? = pendingAudioPackets[index]
            av_packet_free(&free)
        }
        var primedCount = 0
        for index in primingStart..<pendingAudioPackets.count {
            let pending = pendingAudioPackets[index]
            defer {
                var free: UnsafeMutablePointer<AVPacket>? = pending
                av_packet_free(&free)
            }
            try transcodeAudioPacket(pending, emitDecodedFrames: false)
            primedCount += 1
        }
        if !pendingAudioPackets.isEmpty {
            let dropped = primingStart
            let syncFound = trueHDSyncIndex != nil
            if dropped > 0 {
                print("[CMP-AVP] primed audio decoder with \(primedCount) pre-video packets (skipped \(dropped) pre-major_sync, trueHDSyncFound=\(syncFound ? 1 : 0)) without muxing preroll")
            } else {
                print("[CMP-AVP] primed audio decoder with \(primedCount) pre-video packets (trueHDSyncFound=\(syncFound ? 1 : 0)) without muxing preroll")
            }
        }
        pendingAudioPackets.removeAll()
    }

    /// Returns the index of the first packet that contains the MLP/TrueHD
    /// `major_sync_info` 32-bit sync word `0xF8726FBA`. The canonical layout
    /// puts the sync word at offset 4 of an access unit (after a 4-byte
    /// check_nibble/length/input_timing header), and Matroska usually
    /// delivers one AU per packet, but some files concatenate AUs or carry
    /// preroll bytes — so scan the full packet rather than only the
    /// 4-byte slot. False positives are tolerable: the priming output is
    /// discarded, and a stray match still aligns the decoder's state to a
    /// real sync earlier than feeding raw mid-stream data would.
    private func firstMLPMajorSyncIndex(
        in packets: [UnsafeMutablePointer<AVPacket>]
    ) -> Int? {
        for (index, packet) in packets.enumerated() {
            let size = Int(packet.pointee.size)
            guard size >= 4, let data = packet.pointee.data else { continue }
            if DVTrueHDMajorSyncScanner.containsMajorSync(bytes: data, count: size) {
                return index
            }
        }
        return nil
    }

    /// True when the selected audio stream is encoded as TrueHD or its
    /// MLP predecessor — both share the same access-unit / major_sync
    /// framing, so the priming-skip logic applies to both.
    private func isSelectedAudioTrueHD() -> Bool {
        guard selectedAudioStreamIndex >= 0,
              let inCtx = inputCtx,
              selectedAudioStreamIndex < Int(inCtx.pointee.nb_streams),
              let stream = inCtx.pointee.streams?[selectedAudioStreamIndex] else {
            return false
        }
        let codecID = stream.pointee.codecpar.pointee.codec_id
        return codecID == AV_CODEC_ID_TRUEHD || codecID == AV_CODEC_ID_MLP
    }

    private func transcodeAudioPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        emitDecodedFrames: Bool = true
    ) throws {
        guard let decoderCtx = audioDecoderCtx else { return }
        let sendR = avcodec_send_packet(decoderCtx, pkt)
        if sendR < 0 && sendR != avErrorAgain {
            noteAudioDecodeError(stage: "send", rc: sendR)
            return
        }

        let avErrorEOF = -Int32(bitPattern: 0x20464F45)
        while true {
            var frame = av_frame_alloc()
            guard let decodedFrame = frame else {
                throw DVWriterError.allocOutput
            }
            let recvR = avcodec_receive_frame(decoderCtx, decodedFrame)
            if recvR == avErrorAgain || recvR == avErrorEOF {
                av_frame_free(&frame)
                return
            }
            if recvR < 0 {
                av_frame_free(&frame)
                noteAudioDecodeError(stage: "receive", rc: recvR)
                return
            }
            audioDecodeErrorCount = 0
            audioDecodedFrameCount += 1
            if emitDecodedFrames {
                try sendConvertedFrameToEncoder(decodedFrame)
            }
            av_frame_free(&frame)
        }
    }

    private func noteAudioDecodeError(stage: String, rc: Int32) {
        audioDecodeErrorCount += 1
        let shouldLog = audioDecodeErrorCount <= 8 || audioDecodeErrorCount % 64 == 0
        guard shouldLog else { return }
        let level = rc == avErrorInvalidData ? "invaliddata" : "error"
        Self.logger.warning(
            "[CMP-AVP] audio decoder \(stage, privacy: .public) \(level, privacy: .public) rc=\(rc, privacy: .public) consecutive=\(self.audioDecodeErrorCount, privacy: .public)"
        )
    }

    private func sendConvertedFrameToEncoder(_ decodedFrame: UnsafeMutablePointer<AVFrame>) throws {
        guard let encoderCtx = audioEncoderCtx,
              let swr = audioSwrCtx else { return }

        let inSamples = decodedFrame.pointee.nb_samples
        let outCapacity = swr_get_out_samples(swr, inSamples) + 32
        guard outCapacity > 0 else { return }

        var convertedFrame = av_frame_alloc()
        guard let outFrame = convertedFrame else {
            throw DVWriterError.allocOutput
        }
        outFrame.pointee.nb_samples = outCapacity
        outFrame.pointee.format = encoderCtx.pointee.sample_fmt.rawValue
        outFrame.pointee.sample_rate = encoderCtx.pointee.sample_rate
        outFrame.pointee.ch_layout = encoderCtx.pointee.ch_layout
        if av_frame_get_buffer(outFrame, 0) < 0 {
            av_frame_free(&convertedFrame)
            throw DVWriterError.audioTranscodeSetup("audio frame buffer alloc failed")
        }

        var inPtrs = withUnsafeBytes(of: decodedFrame.pointee.data) { raw -> [UnsafePointer<UInt8>?] in
            raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).map { $0.map { UnsafePointer($0) } }
        }
        let converted = inPtrs.withUnsafeMutableBufferPointer { inputPtrs -> Int32 in
            swr_convert(
                swr,
                outFrame.pointee.extended_data,
                outCapacity,
                inputPtrs.baseAddress,
                inSamples
            )
        }
        if converted <= 0 {
            av_frame_free(&convertedFrame)
            return
        }

        outFrame.pointee.nb_samples = converted
        let requiredFrameSize = encoderCtx.pointee.frame_size
        if requiredFrameSize > 0 {
            try writeConvertedAudioToFifo(outFrame, sampleCount: converted)
            av_frame_free(&convertedFrame)
            try drainAudioSampleFifo(final: false)
            return
        }

        outFrame.pointee.pts = nextEncodedAudioPTS
        nextEncodedAudioPTS += Int64(converted)
        let sendR = avcodec_send_frame(encoderCtx, outFrame)
        av_frame_free(&convertedFrame)
        if sendR < 0 && sendR != avErrorAgain {
            throw DVWriterError.audioTranscodeSetup("audio encoder send failed rc=\(sendR)")
        }
        try drainEncodedPackets()
    }

    private func writeConvertedAudioToFifo(
        _ convertedFrame: UnsafeMutablePointer<AVFrame>,
        sampleCount: Int32
    ) throws {
        guard let fifo = audioSampleFifo else {
            throw DVWriterError.audioTranscodeSetup("audio fifo unavailable")
        }
        let planePointers = unsafeBitCast(
            convertedFrame.pointee.extended_data,
            to: UnsafeMutablePointer<UnsafeMutableRawPointer?>?.self
        )
        let writeR = av_audio_fifo_write(fifo, planePointers, sampleCount)
        if writeR < 0 || writeR != sampleCount {
            throw DVWriterError.audioTranscodeSetup("audio fifo write failed rc=\(writeR)")
        }
    }

    private func drainAudioSampleFifo(final: Bool) throws {
        guard let encoderCtx = audioEncoderCtx,
              let fifo = audioSampleFifo else { return }

        let frameSize = max(Int32(encoderCtx.pointee.frame_size), 1)
        while true {
            let available = Int32(av_audio_fifo_size(fifo))
            if available <= 0 {
                return
            }

            let samplesToSend: Int32
            if available >= frameSize {
                samplesToSend = frameSize
            } else if final {
                samplesToSend = available
            } else {
                return
            }

            var frame = av_frame_alloc()
            guard let outFrame = frame else {
                throw DVWriterError.allocOutput
            }
            outFrame.pointee.nb_samples = samplesToSend
            outFrame.pointee.format = encoderCtx.pointee.sample_fmt.rawValue
            outFrame.pointee.sample_rate = encoderCtx.pointee.sample_rate
            outFrame.pointee.ch_layout = encoderCtx.pointee.ch_layout
            if av_frame_get_buffer(outFrame, 0) < 0 {
                av_frame_free(&frame)
                throw DVWriterError.audioTranscodeSetup("audio fifo frame buffer alloc failed")
            }

            let planePointers = unsafeBitCast(
                outFrame.pointee.extended_data,
                to: UnsafeMutablePointer<UnsafeMutableRawPointer?>?.self
            )
            let readR = av_audio_fifo_read(fifo, planePointers, samplesToSend)
            if readR < 0 || readR != samplesToSend {
                av_frame_free(&frame)
                throw DVWriterError.audioTranscodeSetup("audio fifo read failed rc=\(readR)")
            }

            outFrame.pointee.pts = nextEncodedAudioPTS
            nextEncodedAudioPTS += Int64(samplesToSend)
            try sendPreparedAudioFrameToEncoder(outFrame)
            av_frame_free(&frame)
        }
    }

    private func sendPreparedAudioFrameToEncoder(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        guard let encoderCtx = audioEncoderCtx else { return }
        let sendR = avcodec_send_frame(encoderCtx, frame)
        if sendR < 0 && sendR != avErrorAgain {
            throw DVWriterError.audioTranscodeSetup("audio encoder send failed rc=\(sendR)")
        }
        try drainEncodedPackets()
    }

    private func drainEncodedPackets() throws {
        guard let encoderCtx = audioEncoderCtx,
              let outCtx = outputCtx,
              let outStream = outCtx.pointee.streams?[audioOutputStreamIndex] else { return }

        let avErrorEOF = -Int32(bitPattern: 0x20464F45)
        while true {
            if isCancelled { return }
            var packet = av_packet_alloc()
            guard let encodedPacket = packet else {
                throw DVWriterError.allocOutput
            }
            let recvR = avcodec_receive_packet(encoderCtx, encodedPacket)
            if recvR == avErrorAgain || recvR == avErrorEOF {
                av_packet_free(&packet)
                return
            }
            if recvR < 0 {
                av_packet_free(&packet)
                throw DVWriterError.audioTranscodeSetup("audio encoder receive failed rc=\(recvR)")
            }

            encodedPacket.pointee.stream_index = Int32(audioOutputStreamIndex)
            av_packet_rescale_ts(encodedPacket, encoderCtx.pointee.time_base, outStream.pointee.time_base)
            normalizeMuxerTimestampsIfNeeded(pkt: encodedPacket, outStream: outStream)
            let wr = av_interleaved_write_frame(outCtx, encodedPacket)
            do {
                try evaluateMuxWriteResult(wr, packet: encodedPacket)
            } catch {
                av_packet_free(&packet)
                throw error
            }
            av_packet_free(&packet)
        }
    }

    private func finishTranscodedAudio() throws {
        guard selectedAudioOutputMode != .copy,
              let decoderCtx = audioDecoderCtx,
              let encoderCtx = audioEncoderCtx else { return }

        _ = avcodec_send_packet(decoderCtx, nil)
        let avErrorEOF = -Int32(bitPattern: 0x20464F45)
        while true {
            var frame = av_frame_alloc()
            guard let decodedFrame = frame else {
                throw DVWriterError.allocOutput
            }
            let recvR = avcodec_receive_frame(decoderCtx, decodedFrame)
            if recvR == avErrorAgain || recvR == avErrorEOF {
                av_frame_free(&frame)
                break
            }
            if recvR < 0 {
                av_frame_free(&frame)
                throw DVWriterError.audioTranscodeSetup("audio decoder flush failed rc=\(recvR)")
            }
            try sendConvertedFrameToEncoder(decodedFrame)
            av_frame_free(&frame)
        }

        try drainAudioSampleFifo(final: true)
        _ = avcodec_send_frame(encoderCtx, nil)
        try drainEncodedPackets()
        if audioDecodedFrameCount == 0 {
            throw DVWriterError.audioTranscodeSetup("audio decoder produced no frames")
        }
    }

    private func transformVideoPacketIfNeeded(_ pkt: UnsafeMutablePointer<AVPacket>) throws {
        guard videoMode == .convertProfile7To81 else { return }
        guard let dataPtr = pkt.pointee.data else { return }
        let packetBytes = UnsafeBufferPointer(start: dataPtr, count: Int(pkt.pointee.size))
        guard videoPacketNeedsProfile7Rewrite(packetBytes: packetBytes) else { return }
        let transformed = try transformedVideoPacketData(packetBytes: packetBytes)

        var replacement = av_packet_alloc()
        guard let newPacket = replacement else {
            throw DVWriterError.allocOutput
        }
        let allocR = av_new_packet(newPacket, Int32(transformed.count))
        guard allocR >= 0, let newData = newPacket.pointee.data else {
            av_packet_free(&replacement)
            throw DVWriterError.allocOutput
        }
        transformed.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(newData, base, transformed.count)
        }
        av_packet_copy_props(newPacket, pkt)
        av_packet_unref(pkt)
        av_packet_move_ref(pkt, newPacket)
        av_packet_free(&replacement)
    }

    private func transformedVideoPacketData(
        packetBytes: UnsafeBufferPointer<UInt8>
    ) throws -> Data {
        var output = Data()
        output.reserveCapacity(packetBytes.count)
        var cursor = 0
        while cursor + nalLengthSize <= packetBytes.count {
            let prefixStart = cursor
            var nalSize = 0
            for i in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(packetBytes[cursor + i])
            }
            let nalStart = cursor + nalLengthSize
            guard nalSize >= 2, nalStart + nalSize <= packetBytes.count else { break }

            let byte0 = packetBytes[nalStart]
            let byte1 = packetBytes[nalStart + 1]
            let nalType = Int((byte0 >> 1) & 0x3F)
            let layerID = Int(((byte0 & 0x01) << 5) | ((byte1 & 0xF8) >> 3))

            cursor = nalStart + nalSize

            if layerID > 0 || nalType == 63 {
                continue
            }

            if nalType == 62 {
                let nalData = Data(bytes: packetBytes.baseAddress!.advanced(by: nalStart), count: nalSize)
                let payload = try convertRpuNALToProfile81(nalData)
                appendLengthPrefixedNAL(payload, into: &output)
            } else {
                if let base = packetBytes.baseAddress {
                    output.append(base.advanced(by: prefixStart), count: nalLengthSize + nalSize)
                }
            }
        }
        return output.isEmpty ? Data(buffer: packetBytes) : output
    }

    private func videoPacketNeedsProfile7Rewrite(
        packetBytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        var cursor = 0
        while cursor + nalLengthSize <= packetBytes.count {
            var nalSize = 0
            for i in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(packetBytes[cursor + i])
            }
            let nalStart = cursor + nalLengthSize
            guard nalSize >= 2, nalStart + nalSize <= packetBytes.count else { return false }
            let byte0 = packetBytes[nalStart]
            let byte1 = packetBytes[nalStart + 1]
            let nalType = Int((byte0 >> 1) & 0x3F)
            let layerID = Int(((byte0 & 0x01) << 5) | ((byte1 & 0xF8) >> 3))
            if layerID > 0 || nalType == 62 || nalType == 63 {
                return true
            }
            cursor = nalStart + nalSize
        }
        return false
    }

    private func convertRpuNALToProfile81(_ nal: Data) throws -> Data {
        return try nal.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw DVWriterError.profile81ConversionFailed("empty_rpu_nal")
            }
            guard let parsed = dovi_parse_unspec62_nalu(base, raw.count) else {
                throw DVWriterError.profile81ConversionFailed("dovi_parse_unspec62_nalu")
            }
            defer { dovi_rpu_free(parsed) }
            let convertR = dovi_convert_rpu_with_mode(parsed, 2)
            if convertR != 0 {
                let error = dovi_rpu_get_error(parsed).map(String.init(cString:)) ?? "unknown"
                throw DVWriterError.profile81ConversionFailed("dovi_convert_rpu_with_mode \(error)")
            }
            guard let written = dovi_write_unspec62_nalu(parsed) else {
                throw DVWriterError.profile81ConversionFailed("dovi_write_unspec62_nalu")
            }
            defer { dovi_data_free(written) }
            return Data(bytes: written.pointee.data, count: written.pointee.len)
        }
    }

    private func appendLengthPrefixedNAL(_ nal: Data, into output: inout Data) {
        let length = nal.count
        for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
            output.append(UInt8((length >> shift) & 0xFF))
        }
        output.append(nal)
    }


    /// Replace codecpar.extradata with freshly allocated memory matching the
    /// given bytes. Any pre-existing buffer is freed. Adds the standard
    /// `AV_INPUT_BUFFER_PADDING_SIZE` (64) of zero padding FFmpeg expects.
    private func setExtradata(codecpar: UnsafeMutablePointer<AVCodecParameters>, data: Data) {
        let padding = 64
        let total = data.count + padding
        guard let raw = av_malloc(total) else { return }
        let ptr = raw.assumingMemoryBound(to: UInt8.self)
        data.withUnsafeBytes { src in
            if let base = src.baseAddress {
                memcpy(UnsafeMutableRawPointer(ptr), base, data.count)
            }
        }
        memset(UnsafeMutableRawPointer(ptr).advanced(by: data.count), 0, padding)
        if let existing = codecpar.pointee.extradata {
            av_free(existing)
        }
        codecpar.pointee.extradata = ptr
        codecpar.pointee.extradata_size = Int32(data.count)
    }

    private func writeHeader() throws {
        guard let outCtx = outputCtx else { throw DVWriterError.allocOutput }

        // Fragmented MP4 flags. `delay_moov` (instead of `empty_moov`) defers
        // writing the moov atom until the first fragment is cut, so FFmpeg's
        // mp4 muxer has already seen at least one compressed-audio packet by then
        // and can populate codec-private state required for moov emission.
        // `empty_moov` instead tries to write moov at `avformat_write_header`
        // time with no packets seen, which errors out for Dolby-family audio.
        // We intentionally avoid `separate_moof`: it emits track-separated
        // audio/video fragments, and publishing those as a single HLS media
        // playlist gives AVPlayer ragged starts before the first aligned
        // video sample pair arrives. `frag_keyframe` keeps HLS segment
        // boundaries independent for reliable AVPlayer resume/seek behavior,
        // especially with long-GOP H.264. `default_base_moof` keeps each
        // fragment self-describing. `strict=-2` is required for FFmpeg's
        // experimental TrueHD-in-MP4 path; without it, write_header rejects
        // the stream.
        var opts: OpaquePointer?
        if vodActive {
            // VOD serving mode (plan M3): `frag_custom` hands cut control to
            // the plan cutter instead of `frag_keyframe`'s implicit cuts;
            // `frag_discont` with `avoid_negative_ts=disabled` keeps each
            // fragment's tfdt on the producer's absolute output timestamps,
            // so a restart-produced segment continues the session timeline
            // instead of zero-basing; `use_editlist=0` keeps init.mp4
            // restart-invariant (AVPlayer fetches EXT-X-MAP once per item —
            // a per-restart elst would drift lipsync). `delay_moov` stays
            // for the Dolby-family sample-entry parsing described above.
            av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont", 0)
            av_dict_set(&opts, "use_editlist", "0", 0)
            av_dict_set(&opts, "avoid_negative_ts", "disabled", 0)
        } else {
            av_dict_set(&opts, "movflags", "+frag_keyframe+delay_moov+default_base_moof", 0)
        }
        av_dict_set(&opts, "strict", "-2", 0)

        let rc = avformat_write_header(outCtx, &opts)
        av_dict_free(&opts)
        if rc < 0 {
            throw DVWriterError.writeHeader(rc)
        }
        refreshOutputTrackTimeBases()
    }

    private func refreshOutputTrackTimeBases() {
        guard let outCtx = outputCtx else { return }
        var refreshed: [UInt32: AVRational] = [:]
        let count = Int(outCtx.pointee.nb_streams)
        for index in 0..<count {
            guard let stream = outCtx.pointee.streams?[index] else { continue }
            let trackID = stream.pointee.id > 0 ? UInt32(stream.pointee.id) : UInt32(index + 1)
            refreshed[trackID] = stream.pointee.time_base
        }
        if !refreshed.isEmpty {
            trackTimeBasesByID = refreshed
        }
    }

    private func rewritePacketForOutput(
        pkt: UnsafeMutablePointer<AVPacket>,
        outStreamIndex: Int32,
        inputStreamIndex: Int
    ) {
        guard let inCtx = inputCtx, let outCtx = outputCtx,
              let inStream = inCtx.pointee.streams?[inputStreamIndex],
              let outStream = outCtx.pointee.streams?[Int(outStreamIndex)]
        else { return }

        let inTB = inStream.pointee.time_base
        let outTB = outStream.pointee.time_base
        if vodActive {
            // Plan-anchored shift (M3): the session timeline is the plan's
            // 0-based playlist axis. The anchor is a plan constant, so a
            // restarted producer applies the identical shift and its tfdt
            // continues the session timeline — no per-session zero-basing.
            applyVODAnchorShift(pkt: pkt, inputTimeBase: inTB)
        } else {
            captureOutputTimestampBaseIfNeeded(
                pkt: pkt,
                inputStreamIndex: inputStreamIndex,
                inputTimeBase: inTB
            )
        }
        pkt.pointee.stream_index = outStreamIndex
        // `av_packet_rescale_ts` handles AV_NOPTS_VALUE, duration rescaling,
        // and the pos reset in one call — same result as av_rescale_q_rnd
        // triplet but terser and less error-prone.
        av_packet_rescale_ts(pkt, inTB, outTB)
        if !vodActive {
            normalizeSeekedTimelineIfNeeded(pkt: pkt, outStream: outStream)
        }
        normalizeMuxerTimestampsIfNeeded(pkt: pkt, outStream: outStream)
        pkt.pointee.pos = -1
    }

    private func captureOutputTimestampBaseIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputStreamIndex: Int,
        inputTimeBase: AVRational
    ) {
        guard outputTimestampBaseSeconds == nil,
              inputStreamIndex == videoInputStreamIndex else {
            return
        }
        let timestamp = pkt.pointee.dts != Int64.min ? pkt.pointee.dts : pkt.pointee.pts
        guard timestamp != Int64.min,
              inputTimeBase.num > 0,
              inputTimeBase.den > 0 else {
            return
        }
        outputTimestampBaseSeconds = Double(timestamp)
            * Double(inputTimeBase.num)
            / Double(inputTimeBase.den)
        if let base = outputTimestampBaseSeconds, base.isFinite, base >= 0 {
            Self.logger.info(
                "[CMP-AVP] loopback timeline anchor requested=\(self.sourceStartTimeSeconds, privacy: .public) actual=\(base, privacy: .public)"
            )
            onTimelineAnchorResolved?(base)
        }
    }

    private func normalizeSeekedTimelineIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        guard let base = outputTimestampBaseSeconds, base > 0 else { return }
        let baseTicks = ticks(forSeconds: base, timeBase: outStream.pointee.time_base)
        guard baseTicks > 0 else { return }

        if pkt.pointee.dts != Int64.min {
            pkt.pointee.dts = max(0, pkt.pointee.dts - baseTicks)
        }
        if pkt.pointee.pts != Int64.min {
            let normalizedPTS = pkt.pointee.pts - baseTicks
            pkt.pointee.pts = normalizedPTS < 0
                ? max(0, pkt.pointee.dts)
                : normalizedPTS
        }
    }

    private func ticks(forSeconds seconds: Double, timeBase: AVRational) -> Int64 {
        guard seconds.isFinite,
              timeBase.num > 0,
              timeBase.den > 0 else {
            return 0
        }
        return Int64((seconds * Double(timeBase.den) / Double(timeBase.num)).rounded())
    }

    private func repairMissingMuxerTimestampsIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputStreamIndex: Int,
        noPTS: Int64
    ) -> Bool {
        let missingPTS = pkt.pointee.pts == noPTS
        let missingDTS = pkt.pointee.dts == noPTS
        guard missingPTS || missingDTS else { return true }
        guard !missingPTS else { return false }

        let isVideo = inputStreamIndex == videoInputStreamIndex
        let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
        guard isVideo, isKeyframe else { return false }

        pkt.pointee.dts = pkt.pointee.pts
        repairedMissingVideoDTSCount += 1
        if repairedMissingVideoDTSCount <= 3 {
            print("[CMP-AVP] repaired missing video DTS on keyframe pts=\(pkt.pointee.pts) videoMode=\(videoMode.logToken)")
        }
        return true
    }

    private func normalizeMuxerTimestampsIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        guard let codecpar = outStream.pointee.codecpar else { return }
        switch codecpar.pointee.codec_type {
        case AVMEDIA_TYPE_AUDIO:
            normalizeAudioMuxerTimestampsIfNeeded(pkt: pkt, outStream: outStream)
        case AVMEDIA_TYPE_VIDEO:
            normalizeVideoMuxerTimestampsIfNeeded(pkt: pkt)
        default:
            return
        }
    }

    private func normalizeAudioMuxerTimestampsIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let streamIndex = pkt.pointee.stream_index
        let step = max(audioPacketStep(pkt: pkt, outStream: outStream), 1)

        if let lastDTS = lastMuxedDTSByStream[streamIndex],
           pkt.pointee.dts <= lastDTS {
            pkt.pointee.dts = lastDTS + step
        }

        if pkt.pointee.pts < pkt.pointee.dts {
            pkt.pointee.pts = pkt.pointee.dts
        }
        if let lastPTS = lastMuxedPTSByStream[streamIndex],
           pkt.pointee.pts <= lastPTS {
            pkt.pointee.pts = max(pkt.pointee.dts, lastPTS + step)
        }

        if pkt.pointee.duration <= 0 {
            pkt.pointee.duration = step
        }
    }

    private func normalizeVideoMuxerTimestampsIfNeeded(pkt: UnsafeMutablePointer<AVPacket>) {
        let streamIndex = pkt.pointee.stream_index
        if let lastDTS = lastMuxedDTSByStream[streamIndex],
           pkt.pointee.dts <= lastDTS {
            pkt.pointee.dts = lastDTS + 1
        }
        if pkt.pointee.pts < pkt.pointee.dts {
            pkt.pointee.pts = pkt.pointee.dts
        }
    }

    private func audioPacketStep(
        pkt: UnsafeMutablePointer<AVPacket>,
        outStream: UnsafeMutablePointer<AVStream>
    ) -> Int64 {
        if pkt.pointee.duration > 0 {
            return pkt.pointee.duration
        }
        guard let codecpar = outStream.pointee.codecpar else { return 1 }
        let frameSize = codecpar.pointee.frame_size
        let sampleRate = codecpar.pointee.sample_rate
        guard frameSize > 0, sampleRate > 0 else { return 1 }

        let sampleTB = AVRational(num: 1, den: sampleRate)
        let step = av_rescale_q(Int64(frameSize), sampleTB, outStream.pointee.time_base)
        return max(step, 1)
    }

    private func recordMuxedPacketTimestamps(_ pkt: UnsafeMutablePointer<AVPacket>) {
        let streamIndex = pkt.pointee.stream_index
        lastMuxedDTSByStream[streamIndex] = pkt.pointee.dts
        lastMuxedPTSByStream[streamIndex] = pkt.pointee.pts
    }

    // MARK: - Muxer byte sink + ISO BMFF box splitter

    /// Called on muxQueue from the AVIOContext write_packet callback. Appends
    /// bytes to `boxBuffer`, then walks complete top-level boxes and dispatches
    /// them to either the init segment or a media segment.
    fileprivate func ingestMuxerBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !isCancelled else { return }
        if let base = bytes.baseAddress, bytes.count > 0 {
            boxBuffer.append(base, count: bytes.count)
        }
        parseAndFlushCompletedBoxes()
    }

    private func parseAndFlushCompletedBoxes() {
        var cursor = 0
        while boxBuffer.count - cursor >= 8 {
            // Parse the 4-byte size + 4-byte type at `cursor`. `size == 1` is
            // the ISO BMFF "largesize" escape (8-byte size follows at [cursor+8];
            // the mp4 muxer doesn't emit these for our expected payloads so we
            // short-circuit). `size == 0` means "box extends to EOF" — also
            // irrelevant in the muxer's output pattern.
            let size = ISOBoxSurgery.readU32BE(boxBuffer, at: cursor)
            let type = ISOBoxSurgery.readFourCC(boxBuffer, at: cursor + 4)

            if size < 8 { return }  // malformed or truncated — wait for more
            let total = Int(size)
            if cursor + total > boxBuffer.count {
                break  // incomplete; wait for next ingest
            }

            // Capture this box's byte range.
            let boxRange = cursor ..< (cursor + total)
            handleTopLevelBox(type: type, range: boxRange)
            cursor += total
        }
        // Discard consumed prefix. Left-over tail (partial next box) stays
        // buffered for the next ingest.
        if cursor > 0 {
            boxBuffer.removeSubrange(0..<cursor)
        }
    }

    private func handleTopLevelBox(type: String, range: Range<Int>) {
        let slice = boxBuffer[range]
        if Self.traceTopLevelBoxes {
            print("[CMP-AVP] box \(type) size=\(range.count) initDone=\(initSegmentWritten)")
        }

        if !initSegmentWritten {
            // Everything up to and including the first `moov` is init segment.
            // `ftyp`, `free`, `moov`. First `moof` or `mdat` marks end of init.
            switch type {
            case "ftyp", "moov", "free", "skip":
                initSegmentBytes.append(slice)
                if type == "moov" {
                    writeInitSegment()
                }
                return
            case "sidx":
                if pendingSegmentBytes.isEmpty {
                    pendingSegmentBytes = Data(slice)
                    pendingSegmentHasMoof = false
                    pendingSegmentHasVideo = false
                } else {
                    appendToCurrentSegment(slice)
                }
                return
            case "styp":
                if pendingSegmentBytes.isEmpty {
                    pendingSegmentBytes = Data(slice)
                    pendingSegmentHasMoof = false
                    pendingSegmentHasVideo = false
                } else {
                    appendToCurrentSegment(slice)
                }
                return
            case "moof":
                // Muxer jumped to media without producing a moov we caught —
                // unusual, but flush whatever init bytes we've accumulated
                // rather than losing them.
                if !initSegmentBytes.isEmpty {
                    writeInitSegment()
                } else {
                    // No moov ever arrived — init.mp4 is missing from disk.
                    // Don't fire `onFirstSegmentReady` here; AVPlayer would
                    // 404 on EXT-X-MAP. Let `finalizeCurrentSegment` catch
                    // the fire signal once a real segment lands, and the
                    // caller sees a delayed-but-valid stream.
                    initSegmentWritten = true
                    emitPlaylists(isFinal: false)
                }
                let fragmentHasVideo = fragmentHasVideoTrack(in: slice)
                if pendingSegmentBytes.isEmpty {
                    startNewSegment(firstBox: slice, hasMoof: true, hasVideo: fragmentHasVideo)
                } else if pendingSegmentHasMoof {
                    startNewSegment(firstBox: slice, hasMoof: true, hasVideo: fragmentHasVideo)
                } else {
                    appendMoofToCurrentSegment(slice, hasVideo: fragmentHasVideo)
                }
                return
            default:
                initSegmentBytes.append(slice)
                return
            }
        }

        // Segment phase.
        switch type {
        case "styp", "sidx":
            if pendingSegmentBytes.isEmpty {
                pendingSegmentBytes = Data(slice)
                pendingSegmentHasMoof = false
                pendingSegmentHasVideo = false
            } else {
                appendToCurrentSegment(slice)
            }
        case "moof":
            let fragmentHasVideo = fragmentHasVideoTrack(in: slice)
            if pendingSegmentBytes.isEmpty {
                startNewSegment(firstBox: slice, hasMoof: true, hasVideo: fragmentHasVideo)
            } else if pendingSegmentHasMoof {
                startNewSegment(firstBox: slice, hasMoof: true, hasVideo: fragmentHasVideo)
            } else {
                appendMoofToCurrentSegment(slice, hasVideo: fragmentHasVideo)
            }
        case "mdat":
            // Completes the current segment (moof+mdat pair).
            appendToCurrentSegment(slice)
            finalizeCurrentSegment()
        default:
            // Any other box mid-segment: append to the current segment if any.
            appendToCurrentSegment(slice)
        }
    }

    private func fragmentHasVideoTrack(in moof: Data) -> Bool {
        guard let videoOutputTrackID else { return false }
        return moofTrackIDs(in: moof).contains(videoOutputTrackID)
    }

    private func moofTrackIDs(in moof: Data) -> Set<UInt32> {
        guard moof.count >= 8,
              ISOBoxSurgery.readFourCC(moof, at: 4) == "moof" else { return [] }
        return collectTfhdTrackIDs(in: moof, from: 8, to: moof.count)
    }

    private func collectTfhdTrackIDs(in bytes: Data, from start: Int, to end: Int) -> Set<UInt32> {
        var cursor = start
        var trackIDs: Set<UInt32> = []
        while cursor + 8 <= end {
            let size = Int(ISOBoxSurgery.readU32BE(bytes, at: cursor))
            guard size >= 8, cursor + size <= end else { return trackIDs }
            let type = ISOBoxSurgery.readFourCC(bytes, at: cursor + 4)
            switch type {
            case "traf", "moof":
                trackIDs.formUnion(collectTfhdTrackIDs(in: bytes, from: cursor + 8, to: cursor + size))
            case "tfhd":
                guard size >= 16 else { return trackIDs }
                trackIDs.insert(ISOBoxSurgery.readU32BE(bytes, at: cursor + 12))
            default:
                break
            }
            cursor += size
        }
        return trackIDs
    }

    // MARK: - Segment output

    private func writeArtifact(_ data: Data, name: String) throws {
        if let segmentStore {
            if name == "init.mp4" {
                segmentStore.putInitSegment(data)
            }
        } else {
            try data.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
        }
        if let debugOutputDirectory {
            try data.write(to: debugOutputDirectory.appendingPathComponent(name), options: .atomic)
        }
    }

    private func writeMediaSegment(_ data: Data, name: String, duration: Double) throws {
        if let segmentStore {
            let result = segmentStore.putSegment(name: name, data: data, duration: duration)
            removeEvictedSegmentsFromPlaylist(result.evictedSegmentNames)
        } else {
            try data.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
        }
        if let debugOutputDirectory {
            try data.write(to: debugOutputDirectory.appendingPathComponent(name), options: .atomic)
        }
    }

    private func writePlaylistArtifact(_ body: String, name: String) throws {
        if let segmentStore {
            if name == "playlist.m3u8" {
                segmentStore.putMediaPlaylist(body)
            } else if name == "master.m3u8" {
                segmentStore.putMasterPlaylist(body)
            }
        } else {
            try body.write(to: outputDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        if let debugOutputDirectory {
            try body.write(to: debugOutputDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func removeEvictedSegmentsFromPlaylist(_ names: [String]) {
        guard !names.isEmpty else { return }
        let evictedIndexes = Set(names.compactMap { name -> Int? in
            guard name.hasPrefix("seg_"), name.hasSuffix(".m4s") else { return nil }
            let body = name.dropFirst(4).dropLast(4)
            return Int(body)
        })
        guard !evictedIndexes.isEmpty else { return }
        let before = segmentEntries.count
        segmentEntries.removeAll { evictedIndexes.contains($0.index) }
        firstMediaSequence += before - segmentEntries.count
    }

    private func writeInitSegment() {
        // FFmpeg's mp4 muxer in our build doesn't emit a dvvC box even when
        // the video codec_tag is `dvh1` and DOVI side data is present on the
        // track's codecpar. Without dvvC, AVPlayer has no DV signalling in
        // the sample entry and decodes IPT-PQ-c2 as YCbCr → green/purple
        // render. Inject the dvvC ourselves before writing init.mp4 to disk.
        // Plain HEVC/HLG/HDR10 skips this and uses the muxer's normal hvcC.
        var bytes = initSegmentBytes
        if let dovi = doviConfig {
            if let patched = ISOBoxSurgery.injectDvvC(into: bytes, doviBytes: dovi) {
                bytes = patched
                let doviLog = doviRecord?.logLine ?? "unknown"
                print("[CMP-AVP] dvvC injected (init.mp4 grew by 32 bytes) \(doviLog)")
            } else {
                print("[CMP-AVP] dvvC injection failed — hvcC not found in init tree")
            }
        }
        do {
            if Self.traceThroughput {
                let started = CFAbsoluteTimeGetCurrent()
                try writeArtifact(bytes, name: "init.mp4")
                throughputTiming.segmentWriteMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                throughputTiming.segmentWrites += 1
            } else {
                try writeArtifact(bytes, name: "init.mp4")
            }
            initSegmentWritten = true
            print("[CMP-AVP] init.mp4 written (\(bytes.count) bytes)")
        } catch {
            Self.logger.error("writeInitSegment failed: \(String(describing: error), privacy: .public)")
            fatalIOError = .fileWriteFailed("init.mp4", error)
        }
        initSegmentBytes = Data()
        // Do NOT fire onFirstSegmentReady here — the playlist has no media
        // segments yet, and an empty VOD playlist confuses AVPlayer. Wait
        // until `finalizeCurrentSegment` has written at least one .m4s.
    }

    private var pendingSegmentBytes = Data()
    private var pendingSegmentHasVideo = false
    private var pendingSegmentHasMoof = false

    private func startNewSegment(firstBox: Data, hasMoof: Bool, hasVideo: Bool) {
        // If a segment was mid-write (shouldn't happen, but defensive), flush
        // it first — `finalizeCurrentSegment` empties `pendingSegmentBytes`.
        if !pendingSegmentBytes.isEmpty {
            finalizeCurrentSegment()
        }
        pendingSegmentBytes = Data(firstBox)
        pendingSegmentHasMoof = hasMoof
        pendingSegmentHasVideo = hasVideo
    }

    private func appendToCurrentSegment(_ slice: Data) {
        pendingSegmentBytes.append(slice)
    }

    private func appendMoofToCurrentSegment(_ slice: Data, hasVideo: Bool) {
        pendingSegmentBytes.append(slice)
        pendingSegmentHasMoof = true
        pendingSegmentHasVideo = pendingSegmentHasVideo || hasVideo
    }

    private func finalizeCurrentSegment() {
        guard !pendingSegmentBytes.isEmpty else { return }
        guard !isCancelled else {
            pendingSegmentBytes = Data()
            pendingSegmentHasVideo = false
            pendingSegmentHasMoof = false
            return
        }
        let segmentHasVideo = pendingSegmentHasVideo
        let segSize = pendingSegmentBytes.count
        if !hasWrittenVideoSegment, !segmentHasVideo {
            print("[CMP-AVP] discarded pre-video segment \(currentSegmentIndex) size=\(segSize)")
            pendingSegmentBytes = Data()
            pendingSegmentHasVideo = false
            pendingSegmentHasMoof = false
            return
        }

        if vodActive {
            // Plan-indexed naming: the fragment that just closed belongs to
            // the segment the cutter was filling when the cut fired (or the
            // currently open one, for the trailer's final flush).
            currentSegmentIndex = vodClosingSegmentIndex ?? vodOpenSegmentIndex
        }
        let name = String(format: "seg_%06d.m4s", currentSegmentIndex)
        let parsedDuration = segmentMediaDuration(in: pendingSegmentBytes)
        let duration = parsedDuration ?? targetSegmentDuration
        lastSegmentDurationSource = parsedDuration == nil ? "target_duration_fallback" : "fragment_timing"
        waitForGeneratedAheadIfNeeded()
        waitForSegmentStoreCapacityIfNeeded(nextSegmentBytes: segSize)
        guard !isCancelled else {
            pendingSegmentBytes = Data()
            pendingSegmentHasVideo = false
            pendingSegmentHasMoof = false
            return
        }
        do {
            if Self.traceThroughput {
                let started = CFAbsoluteTimeGetCurrent()
                try writeMediaSegment(pendingSegmentBytes, name: name, duration: duration)
                throughputTiming.segmentWriteMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                throughputTiming.segmentWrites += 1
            } else {
                try writeMediaSegment(pendingSegmentBytes, name: name, duration: duration)
            }
        } catch {
            Self.logger.error("segment write failed: \(String(describing: error), privacy: .public)")
            fatalIOError = .fileWriteFailed(name, error)
            pendingSegmentBytes = Data()
            pendingSegmentHasVideo = false
            pendingSegmentHasMoof = false
            return
        }
        // In VOD mode stats live on the plan axis (== the item timeline), so
        // the playhead watchdog compares like with like after a restart.
        let entryStart = vodActive
            ? (vodPlan.map { $0.startSeconds[min(currentSegmentIndex, $0.segmentCount - 1)] } ?? totalMediaDuration)
            : totalMediaDuration
        segmentEntries.append(SegmentEntry(index: currentSegmentIndex, start: entryStart, duration: duration))
        totalMediaDuration += duration
        recordGeneratedSegment(bytes: segSize, duration: duration)
        let idx = currentSegmentIndex
        if vodActive {
            vodClosingSegmentIndex = nil
        } else {
            currentSegmentIndex += 1
        }
        pendingSegmentBytes = Data()
        pendingSegmentHasVideo = false
        pendingSegmentHasMoof = false
        evictExpiredSegmentsIfNeeded()
        retireSegmentsBehindPlaybackIfNeeded()
        emitPlaylists(isFinal: false)
        if shouldLogSegmentProgress(index: idx) {
            print("[CMP-AVP] seg \(idx) written (\(segSize) bytes, video=\(segmentHasVideo ? 1 : 0), dur=\(String(format: "%.3f", duration))s), total dur=\(String(format: "%.1f", totalMediaDuration))s)")
        }
        onSegmentAppended?(idx, totalMediaDuration)
        if segmentHasVideo {
            hasWrittenVideoSegment = true
        }
        markStartupRunwayReadyIfNeeded(force: false)
    }

    private func shouldLogSegmentProgress(index: Int) -> Bool {
        Self.verboseSegmentLogging || index < 4 || index.isMultiple(of: 20)
    }

    private var generatedAheadThrottleSeconds: Double {
        #if os(tvOS)
        let constrained = ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
        return constrained
            ? Self.generatedAheadThrottleConstrainedSeconds
            : Self.generatedAheadThrottleDefaultSeconds
        #else
        return Self.generatedAheadThrottleDefaultSeconds
        #endif
    }

    private func waitForGeneratedAheadIfNeeded() {
        // VOD mode paces via the store's consumer window instead
        // (`waitForVODWindowIfNeeded`), on the plan axis.
        guard !vodActive else { return }
        guard firstSegmentReadyFired else { return }
        let cap = generatedAheadThrottleSeconds
        let waitStarted = CFAbsoluteTimeGetCurrent()
        let targetDuration = Double(
            publishedPlaylistTargetDuration > 0
                ? publishedPlaylistTargetDuration
                : max(1, Int(targetSegmentDuration.rounded()))
        )
        let waitBudget = Self.generatedAheadThrottleWaitBudgetSeconds(targetDuration: targetDuration)
        while !isCancelled {
            retireSegmentsBehindPlaybackIfNeeded()
            guard let playbackPosition = playbackPositionProvider?(),
                  playbackPosition.isFinite else { return }
            let generatedAhead = totalMediaDuration - max(0, playbackPosition)
            let now = CFAbsoluteTimeGetCurrent()
            if generatedAheadObservedPlayback < 0
                || playbackPosition > generatedAheadObservedPlayback + 0.05 {
                generatedAheadObservedPlayback = playbackPosition
                generatedAheadObservedPlaybackWall = now
            }
            guard generatedAhead > cap else { return }
            let stationaryFor = now - generatedAheadObservedPlaybackWall
            // Hold (instead of soft-releasing) once the playhead has clearly
            // stopped. Below the threshold the short soft-release still applies
            // so a brief playlist-reload stall cannot deadlock the mux thread.
            let playheadParked = stationaryFor >= Self.parkedPlayheadHoldThresholdSeconds
            if now - waitStarted >= waitBudget, !playheadParked {
                cmpLog(
                    "[CMP-HLS-STORE] generated-ahead throttle soft-release ahead=\(String(format: "%.1f", generatedAhead))s cap=\(String(format: "%.0f", cap))s wait=\(String(format: "%.1f", now - waitStarted))s targetDuration=\(String(format: "%.1f", targetDuration))s reason=playlist_reload_budget"
                )
                return
            }
            if now - lastGeneratedAheadBackpressureLogWall >= 5 {
                lastGeneratedAheadBackpressureLogWall = now
                cmpLog(
                    "[CMP-HLS-STORE] generated-ahead throttle ahead=\(String(format: "%.1f", generatedAhead))s cap=\(String(format: "%.0f", cap))s playback=\(String(format: "%.1f", playbackPosition))s generated=\(String(format: "%.1f", totalMediaDuration))s stationaryFor=\(String(format: "%.1f", stationaryFor))s hold=\(playheadParked ? 1 : 0) reason=\(playheadParked ? "parked_playhead" : "generated_ahead")"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func generatedAheadThrottleWaitBudgetSeconds(targetDuration: Double) -> Double {
        guard targetDuration.isFinite, targetDuration > 0 else {
            return maxGeneratedAheadThrottleWaitSeconds
        }
        return min(maxGeneratedAheadThrottleWaitSeconds, max(0.5, targetDuration * 0.5))
    }

    private func recordGeneratedSegment(bytes: Int, duration: Double) {
        totalGeneratedSegmentBytes += Int64(bytes)
        recentGeneratedSegments.append((bytes: bytes, duration: duration))
        var windowDuration = recentGeneratedSegments.reduce(0) { $0 + $1.duration }
        while recentGeneratedSegments.count > 1,
              windowDuration > Self.generatedBitrateWindowSeconds {
            let removed = recentGeneratedSegments.removeFirst()
            windowDuration -= removed.duration
        }
    }

    private var rollingGeneratedBitrateBps: Double? {
        let byteCount = recentGeneratedSegments.reduce(0) { $0 + $1.bytes }
        let duration = recentGeneratedSegments.reduce(0) { $0 + $1.duration }
        guard byteCount > 0, duration.isFinite, duration > 0 else { return nil }
        return Double(byteCount) * 8 / duration
    }

    private func waitForSegmentStoreCapacityIfNeeded(nextSegmentBytes: Int) {
        guard let segmentStore else { return }
        let waitDeadline = CFAbsoluteTimeGetCurrent() + Self.maxSegmentStoreCapacityWaitSeconds
        while !isCancelled {
            retireSegmentsBehindPlaybackIfNeeded()
            guard !segmentStore.canAppendSegment(byteCount: nextSegmentBytes) else { return }
            // Defensive escape: capacity only frees as the playhead advances
            // past retired segments. If the position provider is wedged the
            // loop would spin the mux thread indefinitely, so bound it and
            // proceed — the store evicts to satisfy the append rather than
            // livelocking the writer (and, with the live-playlist policy, the
            // evicted segments leave the manifest cleanly).
            if CFAbsoluteTimeGetCurrent() >= waitDeadline {
                cmpLog(
                    "[CMP-HLS-STORE] spill-capacity wait exceeded \(Int(Self.maxSegmentStoreCapacityWaitSeconds))s; proceeding to avoid mux-thread livelock nextBytes=\(nextSegmentBytes)"
                )
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSpillCapacityBackpressureLogWall >= 5 {
                lastSpillCapacityBackpressureLogWall = now
                let playbackPosition = playbackPositionProvider?() ?? 0
                let ahead = playbackPosition.isFinite
                    ? totalMediaDuration - max(0, playbackPosition)
                    : 0
                let stats = segmentStore.stats()
                cmpLog(
                    "[CMP-HLS-STORE] spill-capacity backpressure nextBytes=\(nextSegmentBytes) generatedAhead=\(String(format: "%.1f", ahead))s tempSpillBytes=\(stats.tempSpillBytes)"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func retireSegmentsBehindPlaybackIfNeeded() {
        // VOD retention is byte-budgeted and target-anchored in the store;
        // playback-position retirement is EVENT policy.
        guard !vodActive else { return }
        guard let segmentStore,
              let playbackPosition = playbackPositionProvider?(),
              playbackPosition.isFinite,
              segmentEntries.count > Self.minimumPlaylistSegmentsToKeep else {
            return
        }

        let retireBefore = max(0, playbackPosition - Self.spillRetirementPlaybackSafetyWindowSeconds)
        guard retireBefore > 0 else { return }

        let maxRetirable = segmentEntries.count - Self.minimumPlaylistSegmentsToKeep
        let candidates = segmentEntries
            .prefix(maxRetirable)
            .prefix { $0.end < retireBefore }
        let names = candidates.map { String(format: "seg_%06d.m4s", $0.index) }
        guard !names.isEmpty else { return }

        let retired = segmentStore.retireSegments(names: names)
        if LocalHLSPlaylistPolicy.shouldRemoveRetiredSegmentsFromPlaylist {
            removeEvictedSegmentsFromPlaylist(retired)
        }
    }

    /// Evict head segments whose end time is older than the retention window
    /// behind the live edge. Updates `firstMediaSequence` and removes the
    /// segment files from disk. No-op when the window is disabled or when
    /// fewer than 2 segments remain (we always keep the head segment so
    /// AVPlayer has at least one playable position).
    private func evictExpiredSegmentsIfNeeded() {
        guard !vodActive else { return }
        let window = Self.segmentRetentionWindowSeconds
        guard window > 0, segmentEntries.count > 1 else { return }
        var removable = 0
        var olderDuration: Double = 0
        for entry in segmentEntries {
            // Total duration of segments older than `entry`.
            if olderDuration + entry.duration < totalMediaDuration - window {
                olderDuration += entry.duration
                removable += 1
            } else {
                break
            }
        }
        // Always keep at least one entry so `EXT-X-MAP` / first-segment
        // semantics stay sensible while playback is running.
        removable = min(removable, segmentEntries.count - 1)
        guard removable > 0 else { return }
        for entry in segmentEntries.prefix(removable) {
            let name = String(format: "seg_%06d.m4s", entry.index)
            let url = outputDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.info(
                    "[CMP-AVP] evict failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        segmentEntries.removeFirst(removable)
        firstMediaSequence += removable
    }

    private struct TrackFragmentTiming {
        let trackID: UInt32
        let baseDecodeTime: UInt64
        let duration: UInt64
    }

    private func segmentMediaDuration(in segment: Data) -> Double? {
        var durationsByTrackID: [UInt32: Double] = [:]
        for moof in childBoxes(in: segment, from: 0, to: segment.count) where moof.type == "moof" {
            for timing in trackFragmentTimings(inMoof: segment, moof: moof.box) {
                guard timing.duration > 0,
                      let timeBase = trackTimeBasesByID[timing.trackID],
                      timeBase.num > 0,
                      timeBase.den > 0 else { continue }
                let scale = Double(timeBase.num) / Double(timeBase.den)
                let duration = Double(timing.duration) * scale
                guard duration.isFinite, duration > 0 else { continue }
                durationsByTrackID[timing.trackID, default: 0] += duration
            }
        }
        return durationsByTrackID.values.max()
    }

    private func trackFragmentTimings(inMoof data: Data, moof: ISOBoxSurgery.Box) -> [TrackFragmentTiming] {
        var timings: [TrackFragmentTiming] = []
        let moofEnd = moof.start + moof.size
        for traf in childBoxes(in: data, from: moof.start + 8, to: moofEnd) where traf.type == "traf" {
            guard let tfhd = childBoxes(in: data, from: traf.box.start + 8, to: traf.box.start + traf.box.size)
                .first(where: { $0.type == "tfhd" }),
                let header = parseTfhd(in: data, box: tfhd.box),
                let tfdt = childBoxes(in: data, from: traf.box.start + 8, to: traf.box.start + traf.box.size)
                    .first(where: { $0.type == "tfdt" }),
                let baseDecodeTime = parseTfdtBaseDecodeTime(in: data, box: tfdt.box) else {
                continue
            }

            var duration: UInt64 = 0
            for trun in childBoxes(in: data, from: traf.box.start + 8, to: traf.box.start + traf.box.size)
                where trun.type == "trun" {
                duration += parseTrunDuration(in: data, box: trun.box, defaultSampleDuration: header.defaultSampleDuration)
            }
            if duration > 0 {
                timings.append(TrackFragmentTiming(
                    trackID: header.trackID,
                    baseDecodeTime: baseDecodeTime,
                    duration: duration
                ))
            }
        }
        return timings
    }

    private func childBoxes(
        in data: Data,
        from start: Int,
        to end: Int
    ) -> [(type: String, box: ISOBoxSurgery.Box)] {
        var result: [(type: String, box: ISOBoxSurgery.Box)] = []
        var cursor = start
        while cursor + 8 <= end {
            let size = Int(ISOBoxSurgery.readU32BE(data, at: cursor))
            guard size >= 8, cursor + size <= end else { return result }
            let type = ISOBoxSurgery.readFourCC(data, at: cursor + 4)
            result.append((type, ISOBoxSurgery.Box(start: cursor, size: size)))
            cursor += size
        }
        return result
    }

    private func parseTfhd(
        in data: Data,
        box: ISOBoxSurgery.Box
    ) -> (trackID: UInt32, defaultSampleDuration: UInt32?)? {
        guard box.size >= 16 else { return nil }
        let flags = ISOBoxSurgery.readU24BE(data, at: box.start + 9)
        let trackID = ISOBoxSurgery.readU32BE(data, at: box.start + 12)
        var cursor = box.start + 16

        if flags & 0x000001 != 0 { cursor += 8 }
        if flags & 0x000002 != 0 { cursor += 4 }

        let defaultSampleDuration: UInt32?
        if flags & 0x000008 != 0, cursor + 4 <= box.start + box.size {
            defaultSampleDuration = ISOBoxSurgery.readU32BE(data, at: cursor)
        } else {
            defaultSampleDuration = nil
        }
        return (trackID, defaultSampleDuration)
    }

    private func parseTfdtBaseDecodeTime(in data: Data, box: ISOBoxSurgery.Box) -> UInt64? {
        guard box.size >= 16 else { return nil }
        let version = data[box.start + 8]
        if version == 1 {
            guard box.size >= 20 else { return nil }
            return ISOBoxSurgery.readU64BE(data, at: box.start + 12)
        }
        return UInt64(ISOBoxSurgery.readU32BE(data, at: box.start + 12))
    }

    private func parseTrunDuration(
        in data: Data,
        box: ISOBoxSurgery.Box,
        defaultSampleDuration: UInt32?
    ) -> UInt64 {
        guard box.size >= 16 else { return 0 }
        let flags = ISOBoxSurgery.readU24BE(data, at: box.start + 9)
        let sampleCount = UInt64(ISOBoxSurgery.readU32BE(data, at: box.start + 12))
        var cursor = box.start + 16

        if flags & 0x000001 != 0 { cursor += 4 }
        if flags & 0x000004 != 0 { cursor += 4 }

        let hasSampleDuration = flags & 0x000100 != 0
        let hasSampleSize = flags & 0x000200 != 0
        let hasSampleFlags = flags & 0x000400 != 0
        let hasSampleCompositionTimeOffset = flags & 0x000800 != 0

        if !hasSampleDuration {
            return UInt64(defaultSampleDuration ?? 0) * sampleCount
        }

        var duration: UInt64 = 0
        for _ in 0..<sampleCount {
            guard cursor + 4 <= box.start + box.size else { return duration }
            duration += UInt64(ISOBoxSurgery.readU32BE(data, at: cursor))
            cursor += 4
            if hasSampleSize { cursor += 4 }
            if hasSampleFlags { cursor += 4 }
            if hasSampleCompositionTimeOffset { cursor += 4 }
        }
        return duration
    }

    private func markStartupRunwayReadyIfNeeded(force: Bool) {
        guard !firstSegmentReadyFired,
              initSegmentWritten,
              hasWrittenVideoSegment,
              !segmentEntries.isEmpty else { return }
        if vodActive {
            // The static playlist already advertises the whole title and
            // AVPlayer buffers against it on its own; the EVENT runway
            // heuristics (segment count + live-start window) don't apply.
            // The first produced video segment is enough to attach.
            firstSegmentReadyFired = true
            print("[CMP-AVP] startup ready (vod plan) startPlaylist=playlist.m3u8 producedSegments=\(segmentEntries.count)")
            onFirstSegmentReady?("playlist.m3u8")
            return
        }
        let startupReason = force ? "forced" : "minimum_runway"
        let longestSegmentDuration = segmentEntries.map(\.duration).max() ?? targetSegmentDuration
        let playlistTargetDuration = Double(playlistTargetDurationForEmit())
        let minimumPlayableWindow = max(
            minimumStartupMediaDuration,
            playlistTargetDuration * Self.startupLiveEdgeTargetDurations + longestSegmentDuration
        )
        let hasEnoughSegments = segmentEntries.count >= Self.minimumStartupPlaylistSegments
        guard force || (hasEnoughSegments && totalMediaDuration >= minimumPlayableWindow) else {
            return
        }
        firstSegmentReadyFired = true
        let elapsed = max(0, CFAbsoluteTimeGetCurrent() - startupWallTime)
        let mediaRate = elapsed > 0
            ? String(format: "%.2fx", totalMediaDuration / elapsed)
            : "unknown"
        // Start AVPlayer from the media playlist. The multivariant manifest is
        // still emitted for artifact inspection and DV/HDR validation metadata,
        // but iOS rejected the current local master surface before fetching the
        // child playlist. The media playlist path is the proven playback path.
        print(
            "[CMP-AVP] startup runway ready startPlaylist=playlist.m3u8 generated=\(String(format: "%.1f", totalMediaDuration))s threshold=\(String(format: "%.1f", minimumPlayableWindow))s segments=\(segmentEntries.count) targetDuration=\(String(format: "%.1f", playlistTargetDuration))s elapsed=\(String(format: "%.2f", elapsed))s mediaRate=\(mediaRate) reason=\(startupReason) note=media_playlist_start_hint"
        )
        onFirstSegmentReady?("playlist.m3u8")
    }

    // MARK: - Playlist

    /// Largest EXT-X-TARGETDURATION published so far. Derived from observed
    /// fragment durations (the spec requires TARGETDURATION >= every
    /// segment's duration rounded to the nearest integer) so AVPlayer's
    /// live-edge window and playlist-reload cadence track the source's real
    /// keyframe cadence instead of the configured hint. Monotonic: the tag
    /// must never shrink while a client is reloading the playlist, including
    /// after the sliding window evicts the longest head segment.
    private var publishedPlaylistTargetDuration = 0

    private func playlistTargetDurationForEmit() -> Int {
        let observed = segmentEntries.map { max(1, Int($0.duration.rounded())) }.max()
        let fallback = max(1, Int(targetSegmentDuration.rounded()))
        publishedPlaylistTargetDuration = max(publishedPlaylistTargetDuration, observed ?? fallback)
        return publishedPlaylistTargetDuration
    }

    private func emitPlaylists(isFinal: Bool) {
        emitMediaPlaylist(isFinal: isFinal)
        emitMasterPlaylist()
    }

    private func emitMediaPlaylist(isFinal: Bool) {
        if vodActive, let plan = vodPlan {
            emitVODMediaPlaylist(plan: plan)
            return
        }
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        if LocalHLSPlaylistPolicy.shouldEmitStartTag(firstMediaSequence: firstMediaSequence) {
            lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
        }
        let targetDuration = playlistTargetDurationForEmit()
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(firstMediaSequence)")
        if let playlistTypeTag = LocalHLSPlaylistPolicy.playlistType(isFinal: isFinal).hlsTag {
            lines.append(playlistTypeTag)
        }
        lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        for segment in segmentEntries {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(String(format: "seg_%06d.m4s", segment.index))
        }
        if isFinal {
            lines.append("#EXT-X-ENDLIST")
        }
        let body = lines.joined(separator: "\n") + "\n"
        do {
            if Self.traceThroughput {
                let started = CFAbsoluteTimeGetCurrent()
                try writePlaylistArtifact(body, name: "playlist.m3u8")
                throughputTiming.playlistWriteMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                throughputTiming.playlistWrites += 1
            } else {
                try writePlaylistArtifact(body, name: "playlist.m3u8")
            }
        } catch {
            Self.logger.error("playlist write failed: \(String(describing: error), privacy: .public)")
            fatalIOError = .fileWriteFailed("playlist.m3u8", error)
        }
        emitGeneratedMediaStats(
            playlistBodyBytes: body.utf8.count,
            playlistBodyHash: Self.stablePlaylistHash(body),
            playlistKind: isFinal ? "vod" : "live_sliding",
            targetDuration: targetDuration
        )
    }

    /// The whole title, advertised up front: every plan segment with its
    /// planned EXTINF, `PLAYLIST-TYPE:VOD`, and `ENDLIST`. The body never
    /// changes across the session (segment *bytes* come and go in the store;
    /// the manifest does not), so re-emits are idempotent and only refresh
    /// the generated-media stats the playhead watchdog samples.
    private func emitVODMediaPlaylist(plan: LoopbackSegmentPlan) {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        let longestPlanned = (0..<plan.segmentCount)
            .map { plan.duration(ofSegment: $0) }
            .max() ?? targetSegmentDuration
        let target = max(1, Int(longestPlanned.rounded()))
        lines.append("#EXT-X-TARGETDURATION:\(target)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        for index in 0..<plan.segmentCount {
            lines.append(String(format: "#EXTINF:%.3f,", plan.duration(ofSegment: index)))
            lines.append(String(format: "seg_%06d.m4s", index))
        }
        lines.append("#EXT-X-ENDLIST")
        let body = lines.joined(separator: "\n") + "\n"
        do {
            try writePlaylistArtifact(body, name: "playlist.m3u8")
        } catch {
            Self.logger.error("vod playlist write failed: \(String(describing: error), privacy: .public)")
            fatalIOError = .fileWriteFailed("playlist.m3u8", error)
        }
        emitGeneratedMediaStats(
            playlistBodyBytes: body.utf8.count,
            playlistBodyHash: Self.stablePlaylistHash(body),
            playlistKind: "vod_plan",
            targetDuration: target
        )
    }

    private func emitGeneratedMediaStats(
        playlistBodyBytes: Int,
        playlistBodyHash: UInt64,
        playlistKind: String,
        targetDuration: Int
    ) {
        let storeStats = segmentStore?.stats()
        let visibleStart = segmentEntries.first?.start ?? totalMediaDuration
        let visibleEnd = segmentEntries.last?.end ?? totalMediaDuration
        let lastMediaSequence = firstMediaSequence + max(0, segmentEntries.count - 1)
        let longestSegmentDuration = segmentEntries.map(\.duration).max() ?? self.targetSegmentDuration
        onGeneratedMediaStats?(GeneratedMediaStats(
            generation: storeStats?.generation ?? segmentStore?.generation ?? 0,
            rollingBitrateBps: rollingGeneratedBitrateBps,
            totalGeneratedBytes: totalGeneratedSegmentBytes,
            playlistVisibleStartSeconds: visibleStart,
            playlistVisibleEndSeconds: visibleEnd,
            firstMediaSequence: firstMediaSequence,
            lastMediaSequence: lastMediaSequence,
            targetDuration: targetDuration,
            longestSegmentDuration: longestSegmentDuration,
            segmentCount: segmentEntries.count,
            playlistBodyBytes: playlistBodyBytes,
            playlistBodyHash: playlistBodyHash,
            playlistKind: playlistKind,
            tempSpillBytes: storeStats?.tempSpillBytes ?? 0,
            tempSpillBudgetBytes: storeStats?.tempSpillBudgetBytes ?? 0,
            durationSource: lastSegmentDurationSource
        ))
    }

    private static func stablePlaylistHash(_ body: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in body.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func emitMasterPlaylist() {
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=18000000,CODECS=\"\(masterCodecString())\""
        if let supplemental = supplementalCodecString() {
            inf += ",SUPPLEMENTAL-CODECS=\"\(supplemental)\""
        }
        inf += ",VIDEO-RANGE=\(manifestMetadata.videoRange)"
        if !loggedMasterManifest {
            loggedMasterManifest = true
            print("[CMP-AVP] master playlist stream-inf \(inf)")
        }

        let body = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            inf,
            "playlist.m3u8",
            ""
        ].joined(separator: "\n")
        do {
            if Self.traceThroughput {
                let started = CFAbsoluteTimeGetCurrent()
                try writePlaylistArtifact(body, name: "master.m3u8")
                throughputTiming.playlistWriteMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                throughputTiming.playlistWrites += 1
            } else {
                try writePlaylistArtifact(body, name: "master.m3u8")
            }
        } catch {
            Self.logger.error("master playlist write failed: \(String(describing: error), privacy: .public)")
            fatalIOError = .fileWriteFailed("master.m3u8", error)
        }
    }

    private func finalizePlaylistAsVOD() {
        // Flush any half-built segment (e.g. we got a moof but the mdat never
        // followed because of EOF/cancellation). In practice the mp4 muxer
        // emits complete moof+mdat pairs, so this is rarely non-empty.
        if !pendingSegmentBytes.isEmpty {
            finalizeCurrentSegment()
        }
        emitPlaylists(isFinal: true)
        markStartupRunwayReadyIfNeeded(force: true)
        finished = true
    }

    // MARK: - Teardown

    private func teardown() {
        for pending in pendingVideoPackets {
            var free: UnsafeMutablePointer<AVPacket>? = pending
            av_packet_free(&free)
        }
        pendingVideoPackets.removeAll()
        for pending in pendingAudioPackets {
            var free: UnsafeMutablePointer<AVPacket>? = pending
            av_packet_free(&free)
        }
        pendingAudioPackets.removeAll()
        if let ctx = outputCtx {
            // pb is our custom AVIOContext — we free it separately below so
            // avformat_free_context doesn't try to close it.
            ctx.pointee.pb = nil
            avformat_free_context(ctx)
            outputCtx = nil
        }
        if ioContext != nil {
            avio_context_free(&ioContext)
            // avio_context_free frees the internal buffer too.
            ioBuffer = nil
        }
        if inputCtx != nil {
            avformat_close_input(&inputCtx)
        }
        if audioSwrCtx != nil {
            swr_free(&audioSwrCtx)
        }
        if audioSampleFifo != nil {
            av_audio_fifo_free(audioSampleFifo)
            audioSampleFifo = nil
        }
        if audioEncoderCtx != nil {
            avcodec_free_context(&audioEncoderCtx)
        }
        if audioDecoderCtx != nil {
            avcodec_free_context(&audioDecoderCtx)
        }
        lastMuxedDTSByStream.removeAll()
        lastMuxedPTSByStream.removeAll()
    }

}

/// Byte-LE packing of a four-character code. The FFmpeg `codecpar.codec_tag`
/// field is written little-endian on disk, so 'd','v','h','1' → 0x31687664.
private func MKTAG(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> UInt32 {
    let av = UInt32(a.asciiValue ?? 0)
    let bv = UInt32(b.asciiValue ?? 0)
    let cv = UInt32(c.asciiValue ?? 0)
    let dv = UInt32(d.asciiValue ?? 0)
    return av | (bv << 8) | (cv << 16) | (dv << 24)
}

/// Per-codec `frame_size` values the MP4 muxer needs to emit moov. MKV
/// doesn't populate this field on compressed-audio codecpar, so we fill it
/// in ourselves.
private let mp4AudioFrameSizes: [AVCodecID: Int32] = [
    AV_CODEC_ID_AC3:  1536,
    AV_CODEC_ID_EAC3: 1536,
    AV_CODEC_ID_AAC:  1024,
]

/// Whether we can admit an audio codec into the MP4 muxer via the fMP4
/// path. Returning false here keeps a problem track from breaking the whole
/// session (see `openOutput`).
private func audioCodecSupportsMp4Mux(_ codecId: AVCodecID) -> Bool {
    mp4AudioFrameSizes[codecId] != nil
}

/// Populate `codecpar.frame_size` from `mp4AudioFrameSizes`. Callers must
/// already have filtered via `audioCodecSupportsMp4Mux`.
private func ensureAudioFrameSize(codecpar: UnsafeMutablePointer<AVCodecParameters>) {
    if codecpar.pointee.frame_size > 0 { return }
    if let fs = mp4AudioFrameSizes[codecpar.pointee.codec_id] {
        codecpar.pointee.frame_size = fs
    }
}

enum DVWriterError: Error {
    case allocInput
    case allocOutput
    case openInput(Int32)
    case seekInput(Int32)
    case findStreamInfo
    case noStreams
    case writeHeader(Int32)
    case unsupportedSelectedAudioCodec(String)
    case audioTranscodeSetup(String)
    case profile81ConversionFailed(String)
    /// `av_interleaved_write_frame` returned a negative code on three or more
    /// consecutive packets. The mux is no longer producing valid output; abort
    /// rather than continue writing a half-broken HLS presentation.
    case muxWriteFailures(lastRC: Int32, consecutive: Int)
    /// On-disk write of an init segment, media segment, or playlist failed.
    /// These are catastrophic for HLS playback and are propagated rather than
    /// silently logged.
    case fileWriteFailed(String, Error)
}
