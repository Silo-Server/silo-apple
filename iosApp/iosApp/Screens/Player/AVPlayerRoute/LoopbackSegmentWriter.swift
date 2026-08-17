//
//  LoopbackSegmentWriter.swift
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

/// Resolves the duration written for a look-behind video packet. Matroska
/// commonly supplies a constant `DefaultDuration` even when its millisecond
/// block timestamps produce a 41/42 ms DTS cadence. Prefer the forward DTS
/// delta whenever it is usable so movenc's accumulated track duration cannot
/// drift past the next real DTS at a fragment boundary.
enum LoopbackVideoSampleDurationPolicy {
    static func resolve(
        existingDuration: Int64,
        dts: Int64,
        nextDTS: Int64?,
        fallback: Int64
    ) -> Int64 {
        if let nextDTS, dts != Int64.min, nextDTS != Int64.min {
            let (delta, overflow) = nextDTS.subtractingReportingOverflow(dts)
            if !overflow, delta > 0 {
                return delta
            }
        }
        if existingDuration > 0 {
            return existingDuration
        }
        return max(fallback, 1)
    }
}

enum LoopbackLengthPrefixedHEVCValidator {
    static func isValid(bytes: [UInt8], nalLengthSize: Int) -> Bool {
        bytes.withUnsafeBufferPointer {
            isValid(packetBytes: $0, nalLengthSize: nalLengthSize)
        }
    }

    static func isValid(
        packetBytes: UnsafeBufferPointer<UInt8>,
        nalLengthSize: Int
    ) -> Bool {
        guard (1...4).contains(nalLengthSize), !packetBytes.isEmpty else { return false }
        var cursor = 0
        var nalCount = 0
        while cursor < packetBytes.count {
            guard cursor + nalLengthSize <= packetBytes.count else { return false }
            var nalSize = 0
            for index in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(packetBytes[cursor + index])
            }
            let nalStart = cursor + nalLengthSize
            guard nalSize >= 2, nalStart + nalSize <= packetBytes.count else { return false }

            // HEVC forbidden_zero_bit must be zero and nuh_temporal_id_plus1
            // must never be zero. Checking both catches damaged access units
            // whose length prefixes happen to remain in range.
            let byte0 = packetBytes[nalStart]
            let byte1 = packetBytes[nalStart + 1]
            guard byte0 & 0x80 == 0, byte1 & 0x07 != 0 else { return false }

            nalCount += 1
            cursor = nalStart + nalSize
        }
        return nalCount > 0 && cursor == packetBytes.count
    }
}

struct LoopbackCorruptVideoRecoveryState {
    enum Action: Equatable {
        case keep
        case drop(startedRecovery: Bool)
        case resumeAtRandomAccess
    }

    private var waitingForRandomAccess = false

    mutating func evaluate(structurallyValid: Bool, isRandomAccess: Bool) -> Action {
        guard structurallyValid else {
            let startedRecovery = !waitingForRandomAccess
            waitingForRandomAccess = true
            return .drop(startedRecovery: startedRecovery)
        }
        guard waitingForRandomAccess else { return .keep }
        guard isRandomAccess else { return .drop(startedRecovery: false) }
        waitingForRandomAccess = false
        return .resumeAtRandomAccess
    }
}

enum LoopbackVODPreGateAudioBufferPolicy {
    static let maxPackets = 512
    static let maxBytes = 8 * 1024 * 1024

    static func canBuffer(
        isRestart: Bool,
        isSelectedAudio: Bool,
        isWaitingForVideoGate: Bool,
        bufferedPackets: Int,
        bufferedBytes: Int,
        packetBytes: Int,
        maxPackets: Int = Self.maxPackets,
        maxBytes: Int = Self.maxBytes
    ) -> Bool {
        guard isRestart, isSelectedAudio, isWaitingForVideoGate else { return false }
        let bytes = max(packetBytes, 0)
        return bufferedPackets < maxPackets && bufferedBytes + bytes <= maxBytes
    }

    static func shouldDropReplayedPacket(
        dts: Int64,
        duration: Int64,
        gateDTS: Int64
    ) -> Bool {
        let span = max(duration, 0)
        if span > 0 {
            let (end, overflow) = dts.addingReportingOverflow(span)
            return !overflow && end <= gateDTS
        }
        return dts < gateDTS
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

/// Latch-once detector for HDR10+ dynamic tone-mapping metadata in a
/// compressed HEVC bitstream. SMPTE ST 2094-40 metadata travels in an
/// ITU-T T.35 user-data-registered SEI whose payload opens with a fixed
/// six-byte header: country code 0xB5 (USA), provider code 0x003C
/// (Samsung), provider-oriented code 0x0001, application identifier 4.
/// The header contains no adjacent 0x00 0x00 pair, so HEVC
/// emulation-prevention bytes (inserted only after two zero bytes) can
/// never split a match — scanning the raw escaped bitstream is safe.
/// A chance collision inside entropy-coded slice data is ~2^-48 per byte
/// offset, negligible; the badge impact would be cosmetic anyway.
struct HDR10PlusSEIDetector {
    private static let metadataHeader: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    /// ST 2094-40 metadata rides an SEI on every picture of HDR10+ content,
    /// so a stream that has shown none after this many video packets never
    /// will. Without this budget, plain-HDR10 films paid the scan on every
    /// packet forever — and as a whole-packet byte sweep it cost ~4 ms of
    /// A12 CPU per 4K packet, capping the loopback producer at ~12 Mbps and
    /// stalling playback (2026-07-05 device log). The budget plus the
    /// SEI-only NAL walk in `scanVideoPacket` bound the cost structurally.
    static let scanBudgetPackets = 600

    /// True once any scanned packet has contained the header. Latched for
    /// the detector's lifetime; later scans short-circuit without reading.
    private(set) var detected = false
    private var scannedPackets = 0

    /// True while scanning is still worthwhile: no hit yet and the packet
    /// budget has not been exhausted.
    var isActive: Bool { !detected && scannedPackets < Self.scanBudgetPackets }

    /// Walks a length-prefixed video packet and scans only SEI NAL payloads
    /// (HEVC prefix/suffix SEI 39/40, H.264 SEI 6) — SEI units are tiny, so
    /// this touches a few hundred bytes per packet instead of megabytes. A
    /// malformed NAL walk falls back to a raw scan of the remainder so a
    /// quirky container cannot hide the metadata.
    mutating func scanVideoPacket(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        nalLengthSize: Int,
        isHEVC: Bool
    ) -> Bool {
        guard isActive else { return false }
        scannedPackets += 1
        guard (1...4).contains(nalLengthSize) else {
            return scan(bytes: bytes, count: count)
        }
        var cursor = 0
        while cursor + nalLengthSize < count {
            var nalLength = 0
            for index in 0..<nalLengthSize {
                nalLength = (nalLength << 8) | Int(bytes[cursor + index])
            }
            let payloadStart = cursor + nalLengthSize
            guard nalLength > 0, payloadStart + nalLength <= count else {
                return scan(bytes: bytes + cursor, count: count - cursor)
            }
            let nalType = isHEVC
                ? Int((bytes[payloadStart] >> 1) & 0x3F)
                : Int(bytes[payloadStart] & 0x1F)
            let isSEI = isHEVC ? (nalType == 39 || nalType == 40) : nalType == 6
            if isSEI, scan(bytes: bytes + payloadStart, count: nalLength) {
                return true
            }
            cursor = payloadStart + nalLength
        }
        return false
    }

    /// Raw scan of one buffer. Returns true only for the FIRST buffer that
    /// carries the header; every later call returns false.
    mutating func scan(bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard !detected, count >= Self.metadataHeader.count else { return false }
        for offset in 0...(count - Self.metadataHeader.count) {
            if bytes[offset] == Self.metadataHeader[0],
               bytes[offset + 1] == Self.metadataHeader[1],
               bytes[offset + 2] == Self.metadataHeader[2],
               bytes[offset + 3] == Self.metadataHeader[3],
               bytes[offset + 4] == Self.metadataHeader[4],
               bytes[offset + 5] == Self.metadataHeader[5] {
                detected = true
                return true
            }
        }
        return false
    }

    mutating func scan(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return scan(bytes: base, count: data.count)
        }
    }
}

/// Decision core for the bridged-audio drift governor (see
/// `noteBridgedAudioDriftIfNeeded`): pure sample arithmetic so the
/// persistence/cooldown policy is unit-testable without FFmpeg.
///
/// The bridged clock free-runs on accumulated output samples, so decode
/// losses slide all later content early against its timestamps and nothing
/// re-converges until the next producer restart. This governor watches the
/// per-frame drift observations and emits a content correction once drift
/// is SUSTAINED: at least `requiredConsecutiveFrames` in a row past the
/// floor with one sign, sized by the window's minimum magnitude so a
/// single bogus container timestamp can inflate one observation without
/// inflating the correction. The floor keeps corrections rare and below
/// lipsync perceptibility (~45 ms); the cooldown lets one correction fully
/// flow through the FIFO before drift is trusted again.
struct LoopbackBridgedDriftGovernor {
    static let correctionFloorMs: Int64 = 40
    /// Post-anchor top-up floor: seam priming loss lands within seconds of
    /// a run anchor (28–59 ms observed on device) and should be corrected
    /// to ~0 there, not parked just under the steady-state floor. 5 ms is
    /// ~5× the MKV timestamp-quantization noise.
    static let postAnchorFloorMs: Int64 = 5
    static let postAnchorWindowSeconds: Int64 = 15
    static let requiredConsecutiveFrames = 8
    static let cooldownSeconds: Int64 = 10

    private var consecutive = 0
    private var minMagnitudeDrift: Int64 = 0
    private var cooldownUntil: Int64 = 0

    /// Feed one drift observation (output samples; negative = content
    /// stamped early). `position` is the projected output-sample position,
    /// used only for cooldown bookkeeping. Returns 0, or the correction in
    /// samples: positive = silence to insert, negative = content to trim.
    mutating func observe(
        drift: Int64,
        position: Int64,
        sampleRate: Int64,
        floorMs: Int64 = LoopbackBridgedDriftGovernor.correctionFloorMs
    ) -> Int64 {
        guard position >= cooldownUntil else {
            consecutive = 0
            return 0
        }
        let floor = max(1, sampleRate * floorMs / 1000)
        guard abs(drift) >= floor else {
            consecutive = 0
            return 0
        }
        if consecutive > 0, (drift < 0) != (minMagnitudeDrift < 0) {
            consecutive = 0
        }
        if consecutive == 0 || abs(drift) < abs(minMagnitudeDrift) {
            minMagnitudeDrift = drift
        }
        consecutive += 1
        guard consecutive >= Self.requiredConsecutiveFrames else { return 0 }
        consecutive = 0
        cooldownUntil = position + sampleRate * Self.cooldownSeconds
        return -minMagnitudeDrift
    }
}

final class LoopbackSegmentWriter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "LoopbackSegmentWriter"
    )
    private static let verboseSegmentLogging =
        ProcessInfo.processInfo.environment["SILO_TRACE_DV_SEGMENTS"] == "1"
    /// Producer-loop stage timing, logged once per second beside the source
    /// rate (two clock reads per packet + per io flush while enabled).
    /// Opt-in: this is an investigation probe, not shipping behavior — it
    /// named the 2026-07-05 ingest ceiling (HDR10+ SEI whole-packet scan) by
    /// showing every instrumented stage near zero while the thread burned a
    /// core. Interpret: `read` includes waiting on the source; `io`
    /// (box-sink ingest) is nested inside `mux` (av_interleaved_write_frame).
    /// Enable: `defaults write <bundle> player.apple.loopback_trace_throughput -bool YES`
    private static let traceThroughput =
        ProcessInfo.processInfo.environment["SILO_TRACE_DV_THROUGHPUT"] == "1"
            || UserDefaults.standard.bool(forKey: "player.apple.loopback_trace_throughput")
    private let avErrorAgain = -Int32(EAGAIN)
    private let avErrorInvalidData = Int32(-1094995529) // AVERROR_INVALIDDATA

    // MARK: - Inputs
    let sessionSpec: LoopbackSessionSpec
    let sourceURL: URL
    let sourceHeaders: [String: String]
    let sourceStartTimeSeconds: Double
    let outputDirectory: URL
    let segmentStore: LoopbackSegmentStore?
    let selectedAudioTrackIndex: Int
    let videoMode: LoopbackSessionSpec.VideoMode
    /// Whether the video track is copied or re-encoded. Captured once, like
    /// `selectedAudioOutputMode`; every downstream branch is
    /// `videoOutputMode == .copy` vs not.
    let videoOutputMode: LoopbackSessionSpec.VideoOutputMode
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
    /// Fires at most once per writer, when the video bitstream first carries
    /// HDR10+ dynamic-metadata SEI. The backend installs it only for sessions
    /// whose stats badge currently reads "HDR10" and has not flipped yet;
    /// nil disables the per-packet scan entirely.
    var onHDR10PlusMetadataDetected: (() -> Void)?
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
    /// `.utility` kept the producer off performance cores because its
    /// demux/remux bursts (100-160 Mbps during window fill) contend with
    /// mediaserverd's 4K decode and the UI on A12-class Apple TVs. But a
    /// 2026-07-05 device log showed the opposite failure on a 16 Mbps-average
    /// HDR10 source: the mux thread pinned at ~90% of an efficiency core
    /// while the producer ingested a flat 12-16 Mbps — below the source's
    /// 20 Mbps peaks — even through locally cached byte ranges, stalling
    /// playback every segment. Default is now `.userInitiated`; the kill
    /// switch restores the efficiency-core behavior:
    /// `defaults write <bundle> player.apple.loopback_mux_qos_boost -bool NO`
    private static let muxQoSBoostEnabled =
        UserDefaults.standard.object(
            forKey: "player.apple.loopback_mux_qos_boost"
        ) as? Bool ?? true
    private let muxQueue = DispatchQueue(
        label: "com.continuum.dv.mux",
        qos: LoopbackSegmentWriter.muxQoSBoostEnabled ? .userInitiated : .utility
    )
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
    /// Latch-once HDR10+ SEI scan over outgoing video packets. Only consulted
    /// while `onHDR10PlusMetadataDetected` is installed.
    private var hdr10PlusSEIDetector = HDR10PlusSEIDetector()
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
    /// Media sequence number of the first segment currently in
    /// `segmentEntries`. Bumped each time the head is evicted; emitted as
    /// `#EXT-X-MEDIA-SEQUENCE` so AVPlayer's EVENT-style refetch sees a
    /// monotonic sliding window.
    private var firstMediaSequence: Int = 0
    /// Set to true once the trailer is written. Playlist then emits
    /// EXT-X-ENDLIST so AVPlayer treats it as VOD.
    private var finished = false
    private var loggedMasterManifest = false
    /// AVPlayer entry playlist. Apple grants premium-format claims (Dolby
    /// Atmos MAT output for E-AC-3 JOC) at master-variant level; a
    /// media-direct start never gets them. The historical iOS rejection of
    /// our local master surface was the missing RESOLUTION/FRAME-RATE and
    /// the faithful High-tier CODECS declaration — both fixed in
    /// `emitMasterPlaylist`/`hevcRFC6381CodecString` (AetherEngine ships the
    /// same master shape in production). Kill switch back to the old
    /// media-direct start:
    /// `defaults write <bundle> player.apple.loopback_master_start_enabled -bool NO`
    private lazy var masterStartEnabled =
        UserDefaults.standard.object(
            forKey: "player.apple.loopback_master_start_enabled"
        ) as? Bool ?? true
    private var startupPlaylistName: String {
        masterStartEnabled ? "master.m3u8" : "playlist.m3u8"
    }
    /// Output video dimensions, captured at stream setup for the master
    /// playlist's RESOLUTION attribute (Apple's HLS authoring spec requires
    /// RESOLUTION and FRAME-RATE on every variant; FRAME-RATE is
    /// load-bearing — see `emitMasterPlaylist`).
    private var masterVideoWidth: Int32 = 0
    private var masterVideoHeight: Int32 = 0
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

    // MARK: - Subtitle tap
    // Text-subtitle streams stay in the demuxer keep-set; their packets are
    // decoded inline on the mux thread (a text decode is a microsecond-scale
    // parse) and emitted as cues. Set both callbacks before start().
    var onSubtitleTapTracks: (([LoopbackSubtitleTapTrackInfo]) -> Void)?
    var onSubtitleTapCue: ((LoopbackSubtitleTapCue) -> Void)?
    /// Bitmap (PGS/DVD) subtitle tap. Unlike the text tap there is no
    /// persistent cue store — decoded RGBA cues have real memory weight —
    /// so bitmap streams stay readable but are only DECODED while one is
    /// selected via `setBitmapSubtitleTapStream`. Cues carry source-axis
    /// seconds; `trimActiveAt` mirrors the extractor's PGS semantics
    /// (every composition, including an empty clear, supersedes what is
    /// on screen). Fired on the mux thread.
    var onBitmapSubtitleTapCue: ((_ streamIndex: Int, _ cues: [BitmapSubtitleCue], _ trimActiveAt: Double?) -> Void)?
    /// Bitmap-subtitle input stream indices the tap can serve this run.
    /// Fired on the mux thread from every writer (re)configure.
    var onBitmapSubtitleTapTracks: (([Int]) -> Void)?
    /// Per-input-stream decoder contexts for tapped text subtitle streams.
    /// Mux-queue only; freed in teardown.
    private var subtitleTapDecoders: [Int: UnsafeMutablePointer<AVCodecContext>] = [:]
    private var subtitleTapTimeBases: [Int: AVRational] = [:]
    // Bitmap tap state. Mux queue only, except the selection box below.
    private var bitmapTapTimeBases: [Int: AVRational] = [:]
    private var bitmapTapCodecpars: [Int: UnsafeMutablePointer<AVCodecParameters>] = [:]
    private var bitmapTapDecoders: [Int: UnsafeMutablePointer<AVCodecContext>] = [:]
    private var bitmapTapFallbackCanvas: (width: Int32, height: Int32) = (0, 0)
    /// Rolling backlog of COMPRESSED bitmap-subtitle packets, per stream,
    /// kept for every bitmap stream whether or not one is selected. The
    /// producer's read head runs well ahead of both the playhead and the
    /// (main-thread) selection call, so without a backlog every packet
    /// read before selection lands is lost — PGS then shows nothing until
    /// playback reaches the frontier. Compressed PGS is tiny relative to
    /// its decoded RGBA (~kilobytes per cue), so buffering all streams is
    /// cheap. Mux thread only.
    private var bitmapTapBacklog: [Int: [(packet: UnsafeMutablePointer<AVPacket>, seconds: Double)]] = [:]
    private var bitmapTapBacklogBytes: [Int: Int] = [:]
    /// Per-stream caps: media window slightly wider than the cue store's
    /// 300 s retention, plus a byte ceiling for pathological streams.
    private static let bitmapTapBacklogWindowSeconds = 360.0
    private static let bitmapTapBacklogByteCap = 16 << 20
    /// Selected bitmap stream: written from the main thread, read per
    /// packet on the mux thread. `drainPending` asks the mux thread to
    /// replay the selected stream's backlog before further live decode.
    private let bitmapTapSelectionLock = NSLock()
    private var bitmapTapSelectedStreamLocked: Int?
    private var bitmapTapDrainPendingLocked = false

    /// Select (or clear) the bitmap subtitle stream the tap decodes.
    /// Thread-safe; takes effect on the next packet of that stream. Every
    /// non-nil selection schedules a backlog replay — the backend opens a
    /// fresh cue store per activation, so the replay repopulates it from
    /// the oldest buffered packet through the producer's read head.
    func setBitmapSubtitleTapStream(_ streamIndex: Int?) {
        bitmapTapSelectionLock.lock()
        bitmapTapSelectedStreamLocked = streamIndex
        if streamIndex != nil {
            bitmapTapDrainPendingLocked = true
        }
        bitmapTapSelectionLock.unlock()
    }

    private func bitmapTapSelectedStream() -> Int? {
        bitmapTapSelectionLock.lock()
        defer { bitmapTapSelectionLock.unlock() }
        return bitmapTapSelectedStreamLocked
    }

    /// Consume the drain request, returning the stream to replay (nil when
    /// no drain is pending).
    private func takeBitmapTapDrainRequest() -> Int? {
        bitmapTapSelectionLock.lock()
        defer { bitmapTapSelectionLock.unlock() }
        guard bitmapTapDrainPendingLocked else { return nil }
        bitmapTapDrainPendingLocked = false
        return bitmapTapSelectedStreamLocked
    }
    private var selectedAudioStreamIndex: Int = -1
    private var audioOutputStreamIndex: Int = -1
    private var trackTimeBasesByID: [UInt32: AVRational] = [:]
    /// Last successfully written timestamps per output stream. Used to repair
    /// duplicate audio DTS before handing packets to the MP4 muxer.
    private var lastMuxedDTSByStream: [Int32: Int64] = [:]
    private var lastMuxedPTSByStream: [Int32: Int64] = [:]
    /// One-packet look-behind for video duration telescoping. The next
    /// normalized video DTS supplies the pending packet's real duration.
    private var pendingMuxVideoPacket: UnsafeMutablePointer<AVPacket>?
    /// Audio packets encountered while a video packet is held. Deferring
    /// them preserves the original video-before-audio submission order; the
    /// queue is drained immediately after the held video is finalized.
    private var pendingMuxAudioPackets: [UnsafeMutablePointer<AVPacket>] = []
    private var lastResolvedVideoDurationByStream: [Int32: Int64] = [:]
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
    /// A malformed Matroska block can leave libavformat returning a damaged
    /// HEVC access unit followed by pictures whose references were lost.
    /// AVPlayer treats that sequence as terminal; keep it out of the fMP4 and
    /// resume only at the next self-contained random-access picture.
    private var corruptVideoRecoveryState = LoopbackCorruptVideoRecoveryState()
    private var corruptVideoPacketsDropped = 0
    /// Raw bytes of the input's H.264 avcC record. Used for the HLS CODECS
    /// string when the loopback path remuxes AVC without touching the video.
    private var inputAvccHeader: Data?
    /// Raw bytes of the DOVI decoder configuration record from the input
    /// stream (8 useful bytes matching FFmpeg's `AVDOVIDecoderConfigurationRecord`
    /// layout: version_major, version_minor, profile, level, rpu_flag, el_flag,
    /// bl_flag, bl_compat_id). Nil if the source isn't Dolby Vision. Used by
    /// `writeInitSegment` to synthesise the configuration box the profile
    /// names (`dvcC` up to 7, `dvvC` for 8+) — FFmpeg's mp4 muxer in our
    /// build doesn't emit one on its own, so AVPlayer can't see DV signalling
    /// and paints the IPT samples as YCbCr (green/purple).
    private var doviConfig: Data?
    private var doviRecord: DoviRecord?
    private var outputAudioCodecID: AVCodecID?
    private var outputAudioCodecToken: String?
    /// True when the selected copy-mode audio stream is E-AC-3 with a JOC
    /// (Atmos) extension — `codecpar.profile == 30`
    /// (`AV_PROFILE_EAC3_DDP_ATMOS`, libavcodec defs.h; set by the eac3
    /// decoder during stream probing when the bitstream carries
    /// `eac3_extension_type_a`). Drives the dec3 JOC surgery in
    /// `writeInitSegment`.
    private var selectedAudioIsAtmosJOC = false
    /// Software decode → VideoToolbox encode pipeline. Non-nil only when
    /// `videoOutputMode.isBridged`.
    private var videoBridge: LoopbackVideoBridge?
    /// The `hvcC` / `avcC` written into `moov` for a bridged session. Either
    /// the encoder's own record or the one the first producer of this player
    /// item published (`LoopbackSessionSpec.bridgedVideoParameterSets`).
    private var bridgedVideoExtradata: Data?
    /// Fires once, on the session that first resolves bridged parameter sets,
    /// so the backend can pin them onto the spec for restarted producers.
    /// AVPlayer fetches `EXT-X-MAP` once per item, so a restart that emitted
    /// different SPS/PPS/VPS bytes would publish undecodable segments.
    var onBridgedVideoParameterSetsResolved: ((Data) -> Void)?
    private var audioDecoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioEncoderCtx: UnsafeMutablePointer<AVCodecContext>?
    /// Reused across every decoded bridge frame (receive_frame unrefs it);
    /// allocated lazily on the mux queue, freed with the decoder.
    private var audioDecodedFrame: UnsafeMutablePointer<AVFrame>?
    private var audioSwrCtx: OpaquePointer?
    private var audioSampleFifo: OpaquePointer?
    private var nextEncodedAudioPTS: Int64 = 0
    /// VOD: whether `nextEncodedAudioPTS` has been anchored to the session
    /// timeline. The bridged (re-encoded) audio track otherwise zero-bases
    /// per producer run while remuxed video rides the plan axis; on a
    /// mid-title resume AVPlayer then sees an audio track that never covers
    /// the seek target and buffers forward forever without becoming ready
    /// (living-room DV P7 + TrueHD→FLAC resume failure).
    private var vodSeededBridgedAudioPTS = false
    /// Seam stitching state: the bridged audio of every anchored run is
    /// aligned to the run's own plan-boundary (session axis). A restarted
    /// TrueHD/MLP decoder silently eats ~40ms of packets before its first
    /// major_sync, so a source-accurate seed leaves that span as a hole in
    /// the audio track at every producer seam — audible as an intermittent
    /// glitch. The previous run's stored audio always ends at this
    /// boundary (the cutter's span-assignment invariant; its encode
    /// pipeline runs seconds ahead of the cut, so a counter handoff
    /// overshoots — measured −2.3s on device). A gap after the boundary is
    /// filled with encoded silence, an overlap is trimmed pre-timestamp.
    private var vodPendingSeamSilenceFillSamples: Int64 = 0
    private var vodPendingSeamTrimSamples: Int64 = 0
    private static let vodSeamFillMaxSamples: Int64 = 48_000 // 1 s @ 48 kHz
    private static let vodSeamTrimMaxSamples: Int64 = 12_000 // 250 ms @ 48 kHz
    private var audioDecodedFrameCount = 0
    private var audioDecodeErrorCount = 0
    /// Temporary [CMP-ADRIFT] diagnostics (see noteBridgedAudioDriftIfNeeded).
    /// Cumulative decode failures for the bridged track — unlike
    /// `audioDecodeErrorCount` this never resets on a successful frame, so
    /// it measures total timeline loss, not burst length.
    private var audioDecodeErrorTotal = 0
    private var bridgedDriftLastLoggedStep: Int64 = 0
    private var bridgedDriftNextHeartbeatPTS: Int64 = 0
    /// Output-sample position of the current run's audio anchor, captured
    /// at the first drift observation; bounds the post-anchor top-up
    /// window. -1 = not yet observed this run.
    private var bridgedDriftRunAnchorPTS: Int64 = -1
    private var bridgedDriftGovernor = LoopbackBridgedDriftGovernor()
    /// AetherEngine parity: its AudioBridge re-arms a source-PTS rebase of
    /// the encoder clock at every segment cut, so decode losses can never
    /// accumulate beyond one segment. Rebasing raw timestamps would break
    /// our contiguous-audio-timeline invariant (every segment's tfdt must
    /// equal the previous end), so our variant realigns the CONTENT through
    /// the seam stitch primitives instead — silence fill for content that
    /// slid early, FIFO trim for content that slid late. Kill switch:
    /// `defaults write <bundle> player.apple.loopback_bridged_drift_correction_enabled -bool NO`
    private lazy var bridgedDriftCorrectionEnabled =
        UserDefaults.standard.object(
            forKey: "player.apple.loopback_bridged_drift_correction_enabled"
        ) as? Bool ?? true
    private var videoOutputTrackID: UInt32?

    /// Captures any fatal IO error seen by `writeInitSegment`,
    /// `finalizeCurrentSegment`, or playlist emit calls. Those run from the
    /// AVIO write callback (synchronously inside `av_interleaved_write_frame`),
    /// so they cannot throw directly. The mux loop checks this after every
    /// `av_interleaved_write_frame`/`av_write_trailer` and rethrows.
    private var fatalIOError: LoopbackWriterError?
    /// Consecutive `av_interleaved_write_frame` failures. Reset on success.
    /// When this hits `maxConsecutiveMuxWriteFailures`, the mux loop aborts via
    /// `LoopbackWriterError.muxWriteFailures` so callers see a real error instead of
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
        segmentStore: LoopbackSegmentStore? = nil,
        targetSegmentDuration: Double = 4.0,
        minimumStartupMediaDuration: Double? = nil,
        vodPlan: LoopbackSegmentPlan? = nil,
        vodBaseIndex: Int = 0,
        recycledInputHandoff: LoopbackInputHandoff? = nil
    ) {
        self.recycledInputHandoff = recycledInputHandoff
        self.sessionSpec = sessionSpec
        self.sourceURL = sessionSpec.sourceURL
        self.sourceHeaders = sessionSpec.headers
        self.sourceStartTimeSeconds = sessionSpec.sourceStartTimeSeconds
        self.outputDirectory = outputDirectory
        self.segmentStore = segmentStore
        self.selectedAudioTrackIndex = sessionSpec.selectedAudio.trackIndex
        self.videoMode = sessionSpec.videoMode
        self.videoOutputMode = sessionSpec.videoOutputMode
        self.selectedAudioOutputMode = sessionSpec.selectedAudio.outputMode
        self.manifestMetadata = sessionSpec.manifestMetadata
        self.targetSegmentDuration = targetSegmentDuration
        self.vodPlan = vodPlan
        self.vodPlanProvidedAtInit = vodPlan != nil
        self.vodBaseIndex = max(0, vodBaseIndex)
        self.minimumStartupMediaDuration = max(
            0,
            minimumStartupMediaDuration
                ?? Self.defaultMinimumStartupMediaDuration(
                    for: sessionSpec.videoMode,
                    videoOutputMode: sessionSpec.videoOutputMode
                )
        )
    }

    // MARK: - VOD serving mode (loopback-primary plan, Stage 1c)

    /// Static-plan serving state. Populated only when the session spec asks
    /// for `.vodPlan` AND a plan could be resolved; the EVENT path never
    /// touches these. The plan is resolved once per player item — a
    /// restarted producer receives the already-resolved plan via init and
    /// must reproduce the same segment grid.
    private var vodPlan: LoopbackSegmentPlan?
    private let vodPlanProvidedAtInit: Bool
    private let vodBaseIndex: Int
    /// Incoming demuxer handoff from the producer this session replaces:
    /// openInput claims it (bounded wait) instead of reopening the source.
    private let recycledInputHandoff: LoopbackInputHandoff?
    /// Outgoing handoff for the producer replacing THIS session. Set by
    /// `stop(recyclingInputInto:)` under `cancelLock`; consumed by
    /// `teardown()` on the mux queue.
    private var outgoingInputHandoff: LoopbackInputHandoff?
    /// True when this session runs on a recycled demuxer — its cue index is
    /// already warm, so the restart re-seek skips the mid-file prewarm.
    private var recycledInputActive = false
    /// The interrupt-callback target for the input context (cancelLock-
    /// protected). Fresh per writer; REPLACED by the adopted token when a
    /// recycled demuxer is claimed, because FFmpeg's nested I/O contexts
    /// hold copies of the callback pointing at the token from the original
    /// open.
    private var interruptToken = LoopbackInterruptToken()
    /// Teardown-completed marker (cancelLock-protected): a stop() that
    /// arrives after teardown must cancel its handoff immediately or the
    /// successor burns its whole claim timeout on a dead publisher.
    private var didTeardown = false
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
    /// Fired (on the mux thread) once the session's effective anchor segment
    /// is known — for a resume-first session this differs from the passed
    /// base. The backend must seed the consumer window and its coverage
    /// bookkeeping from this before production begins.
    var onVODProducerAnchored: ((Int) -> Void)?
    /// The session's true anchor: `vodBaseIndex` for explicit restarts,
    /// resume-derived for a first session starting mid-title.
    private var vodEffectiveBaseIndex = 0

    /// Resolves (or installs) the segment plan and cutter. Runs after
    /// `openInput` — the keyframe index needs `find_stream_info` plus the
    /// cue-prewarm seek — and before `openOutput`/`writeHeader`, which pick
    /// muxer flags off `vodActive`.
    private func resolveVODPlanIfNeeded() throws {
        guard sessionSpec.servingMode == .vodPlan else { return }
        if vodPlan == nil {
            if var plan = harvestVODPlan() {
                // Resume-anchor bitstream check runs BEFORE the plan is
                // published — the playlist and every restarted producer are
                // built from whatever goes out here.
                plan = resumeAnchorValidatedPlan(plan)
                vodPlan = plan
                onSegmentPlanResolved?(plan)
            }
        } else {
            // Restarted (plan-provided) session: this demuxer's cue index is
            // cold, and a matroska start seek without cues lands by linear
            // estimate — up to a GOP away from the anchor, which misanchors
            // production past the requested segment (living-room bug 2).
            // Warm the cues exactly like the harvest path, then redo the
            // start seek so it lands on the anchor keyframe.
            prewarmVODCueIndexAndReseek()
        }
        guard let plan = vodPlan, plan.segmentCount > 0 else {
            cmpLog("[CMP-AVP] vod plan unavailable; degrading to EVENT serving")
            // A failed harvest may have bailed before its rewind/start seek
            // (openInput no longer seeks for vodPlan sessions).
            if let inCtx = inputCtx {
                try? seekInputToStartTimeIfNeeded(inCtx)
            }
            return
        }
        // The effective anchor: an explicit restart passes its base, but a
        // FIRST session resuming mid-title arrives with base 0 and a
        // mid-title start time — its true anchor is the resume segment.
        // Anchoring at 0 would park the producer against the consumer
        // window seeded at its own segment and strand AVPlayer's resume
        // fetches (the living-room resume startup timeout).
        var effectiveBase = min(vodBaseIndex, plan.segmentCount - 1)
        if sourceStartTimeSeconds > plan.anchorSourceSeconds + 0.05 {
            effectiveBase = max(effectiveBase, plan.segmentIndex(
                forPlaylistSeconds: sourceStartTimeSeconds - plan.anchorSourceSeconds
            ))
        }
        vodEffectiveBaseIndex = effectiveBase
        vodCutter = LoopbackSegmentCutter(
            boundaries: Array(plan.boundaries[effectiveBase...]),
            baseIndex: effectiveBase
        )
        vodOpenSegmentIndex = effectiveBase
        onVODProducerAnchored?(effectiveBase)
        cmpLog("[CMP-AVP] vod producer anchored segment=\(effectiveBase) start=\(sourceStartTimeSeconds)")
        let anchorBoundarySeconds = plan.sourceStartSeconds(ofSegment: effectiveBase)
        // The re-seek also runs whenever the resume-anchor probe consumed
        // packets — even an on-boundary resume needs the cursor put back.
        if resumeAnchorProbeMovedCursor || sourceStartTimeSeconds > anchorBoundarySeconds + 0.05,
           let inCtx = inputCtx {
            // Mid-segment resume: the open seek targeted the resume TIME,
            // which parks the demuxer mid-GOP inside the anchor segment —
            // the bootstrap then discards frames up to the NEXT keyframe
            // and the anchor segment AVPlayer's resume pre-seek fetches is
            // never produced (living-room startup stalls at segments
            // 1549/1711: endless 404s → ladder → Compatibility fallback).
            // Re-seek to the anchor BOUNDARY (a plan keyframe; cues are
            // warm and no packets are consumed yet — the same contract the
            // restart path relies on in prewarmVODCueIndexAndReseek).
            try? seekInput(inCtx, toSeconds: anchorBoundarySeconds)
            cmpLog("[CMP-AVP] vod anchor boundary re-seek boundary=\(anchorBoundarySeconds) resume=\(sourceStartTimeSeconds)")
        }
        vodAnchorPts = plan.boundaries[0]
        if let inCtx = inputCtx,
           videoInputStreamIndex >= 0,
           let stream = inCtx.pointee.streams?[videoInputStreamIndex] {
            vodVideoTimeBase = stream.pointee.time_base
        }
        vodAwaitingRestartKeyframe = effectiveBase > 0
        vodPrerollDroppedVideo = 0
        vodPrerollDroppedAudio = 0
        vodActive = true
        if selectedAudioOutputMode != .copy {
            // Bridged audio re-encodes on a synthesized clock; the encoder
            // counter is seeded from the first emitted frame's session-axis
            // timestamp (see seedVODBridgedAudioPTSIfNeeded). Copy-mode
            // sources are exact.
            cmpLog("[CMP-AVP] vod: bridged audio (\(selectedAudioOutputMode)) — session-anchored at first emitted frame")
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
    /// Seam telemetry only (no behavior): packets the restart pre-roll gate
    /// discards, reported once when the video gate opens so hardware passes
    /// can size the decode-ramp seam. Mux thread only.
    private var vodPrerollDroppedVideo = 0
    private var vodPrerollDroppedAudio = 0
    /// Selected-audio packets encountered while a restarted VOD producer is
    /// still scanning forward to its accepted video keyframe. Wide-interleave
    /// sources can put the matching audio earlier in file order; replaying it
    /// after the gate opens prevents a persistent post-recovery A/V offset.
    private var vodPreGateAudioPackets: [UnsafeMutablePointer<AVPacket>] = []
    private var vodPreGateAudioBytes = 0
    private var vodPreGateAudioOverflowLogged = false

    /// FFmpeg's mp4 muxer can only build the AC-3/E-AC-3/TrueHD sample-entry
    /// box (dac3/dec3/dmlp) after it has PARSED an audio packet, so under
    /// `+delay_moov` a flush that runs before any audio packet reaches the
    /// muxer fails moov emission with "Cannot write moov atom before EAC3
    /// packets parsed" — and `mov_write_packet(NULL)` swallows that error, so
    /// the writer never sees it. AAC (and every other codec) needs no parsed
    /// packet and must keep the stock code path.
    private var vodAudioNeedsParsedPacketForMoov = false
    /// Latched when the first selected-audio packet is routed to the muxer's
    /// interleaver this run (set in `rewritePacketForOutput`).
    private var vodAudioPacketRouted = false
    /// Late-start audio prefeed: input-axis DTS of the packet fed ahead of
    /// the mux loop so moov can be written. The mux loop drops the duplicate
    /// when the demuxer naturally reaches it, then clears the latch.
    private var vodPrefedAudioMaxDts: Int64?
    /// Bounded retry for the moov priming flush (a flush that keeps failing
    /// to emit moov must not be retried per audio packet).
    private var vodMoovPrimeAttempts = 0

    /// Codecs whose mp4 sample entry requires a parsed packet before moov
    /// can be written (see `vodAudioNeedsParsedPacketForMoov`).
    static func audioCodecNeedsParsedPacketForMoov(_ codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_AC3
            || codecID == AV_CODEC_ID_EAC3
            || codecID == AV_CODEC_ID_TRUEHD
    }

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
            if videoOutputMode.isBridged {
                // A bridged restart cannot gate on the SOURCE keyframe: the
                // decoder needs the source keyframe preceding the boundary to
                // produce anything at all. Everything reaches the decoder; the
                // bridge's own emit threshold discards encoder input below the
                // boundary and `openBridgedRestartGateIfNeeded` opens the audio
                // gate on the first encoded packet.
                return false
            }
            if vodAwaitingRestartKeyframe {
                let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
                let boundary = plan.boundaries[min(vodEffectiveBaseIndex, plan.segmentCount - 1)]
                if isKeyframe, pkt.pointee.pts != Int64.min, pkt.pointee.pts >= boundary {
                    vodAwaitingRestartKeyframe = false
                    vodFirstRoutedVideoDts = pkt.pointee.dts
                    cmpLog("[CMP-AVP] vod restart preroll dropped video=\(vodPrerollDroppedVideo) audio=\(vodPrerollDroppedAudio) segment=\(vodEffectiveBaseIndex)")
                    return false
                }
                vodPrerollDroppedVideo += 1
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
        if vodEffectiveBaseIndex == 0 {
            // Head of stream: audio at-or-after the plan anchor rides, even
            // ahead of the first video packet — the source's A/V offset is
            // part of the timeline. Audio before the anchor would map below
            // tfdt 0 and is dropped.
            thresholdVideoTB = vodAnchorPts
        } else {
            // Restart: audio waits for the video gate, then everything
            // before the gate's DTS is dropped so the restarted interleave
            // reproduces the continuous run's.
            guard let gate = vodFirstRoutedVideoDts else {
                vodPrerollDroppedAudio += 1
                return true
            }
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
        let drops = LoopbackVODPreGateAudioBufferPolicy.shouldDropReplayedPacket(
            dts: pkt.pointee.dts,
            duration: pkt.pointee.duration,
            gateDTS: threshold
        )
        if drops { vodPrerollDroppedAudio += 1 }
        return drops
    }

    private func bufferVODPreGateAudioIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputIdx: Int
    ) -> Bool {
        let isRestart = vodActive && vodEffectiveBaseIndex > 0
        let isSelectedAudio = inputIdx == selectedAudioStreamIndex
        let waiting = vodAwaitingRestartKeyframe && vodFirstRoutedVideoDts == nil
        let packetBytes = max(0, Int(pkt.pointee.size))
        let canBuffer = LoopbackVODPreGateAudioBufferPolicy.canBuffer(
            isRestart: isRestart,
            isSelectedAudio: isSelectedAudio,
            isWaitingForVideoGate: waiting,
            bufferedPackets: vodPreGateAudioPackets.count,
            bufferedBytes: vodPreGateAudioBytes,
            packetBytes: packetBytes
        )
        guard canBuffer else {
            if isRestart, isSelectedAudio, waiting,
               !vodPreGateAudioOverflowLogged {
                vodPreGateAudioOverflowLogged = true
                let logLine = "[CMP-AVP] vod pre-gate audio buffer full "
                    + "packets=\(vodPreGateAudioPackets.count) "
                    + "bytes=\(vodPreGateAudioBytes); dropping further preroll"
                cmpLog(logLine)
            }
            return false
        }
        guard let held = av_packet_clone(pkt) else { return false }
        vodPreGateAudioPackets.append(held)
        vodPreGateAudioBytes += packetBytes
        return true
    }

    private func replayVODPreGateAudioPacketsIfNeeded() throws {
        guard !vodAwaitingRestartKeyframe,
              vodFirstRoutedVideoDts != nil,
              !vodPreGateAudioPackets.isEmpty,
              let outIdx = streamMap[selectedAudioStreamIndex] else { return }

        var packets = vodPreGateAudioPackets.sorted {
            Self.packetOrderingTimestamp($0) < Self.packetOrderingTimestamp($1)
        }
        let bufferedBytes = vodPreGateAudioBytes
        vodPreGateAudioPackets.removeAll()
        vodPreGateAudioBytes = 0

        var replayed = 0
        var dropped = 0
        defer {
            for packet in packets {
                var free: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&free)
            }
            packets.removeAll()
        }

        for packet in packets {
            if vodShouldDropPacket(pkt: packet, inputIdx: selectedAudioStreamIndex) {
                dropped += 1
                continue
            }
            if let prefedMax = vodPrefedAudioMaxDts {
                let dts = Self.packetOrderingTimestamp(packet)
                if dts != Int64.min, dts <= prefedMax {
                    dropped += 1
                    continue
                }
                vodPrefedAudioMaxDts = nil
            }

            if selectedAudioOutputMode != .copy {
                try transcodeAudioPacket(packet)
            } else {
                rewritePacketForOutput(
                    pkt: packet,
                    outStreamIndex: Int32(outIdx),
                    inputStreamIndex: selectedAudioStreamIndex
                )
                try writePacketToMux(packet)
            }
            replayed += 1
        }
        let logLine = "[CMP-AVP] vod pre-gate audio replay buffered=\(packets.count) "
            + "bytes=\(bufferedBytes) replayed=\(replayed) dropped=\(dropped)"
        cmpLog(logLine)
    }

    private static func packetOrderingTimestamp(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) -> Int64 {
        packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
    }

    private func prewarmVODCueIndexAndReseek() {
        guard let inCtx = inputCtx else { return }
        // A recycled demuxer carries the previous session's cue index — the
        // start seek below already lands on the anchor keyframe without the
        // mid-file warm-up seek (which costs a range request into the
        // remote source on every restart).
        if !recycledInputActive {
            let rawDuration = inCtx.pointee.duration
            if rawDuration > 0 {
                let durationSeconds = Double(rawDuration) / Double(AV_TIME_BASE)
                if durationSeconds > 1 {
                    let mid = Int64(durationSeconds * 0.5 * Double(AV_TIME_BASE))
                    _ = avformat_seek_file(inCtx, -1, Int64.min, mid, Int64.max, AVSEEK_FLAG_BACKWARD)
                }
            }
        }
        if sourceStartTimeSeconds > 0 {
            try? seekInputToStartTimeIfNeeded(inCtx)
        } else {
            _ = avformat_seek_file(inCtx, -1, Int64.min, 0, Int64.max, AVSEEK_FLAG_BACKWARD)
        }
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
            targetSegmentDurationSeconds: targetSegmentDuration,
            // A bridged session's output keyframes are the encoder's, forced
            // onto uniform fences; the source cue index describes a keyframe
            // cadence that no longer exists downstream.
            forceUniformStride: videoOutputMode.isBridged
        )
        cmpLog("[CMP-AVP] vod plan resolved segments=\(plan.segmentCount) keyframes=\(keyframePts.count) trusted=\(plan.usedKeyframeIndex) duration=\(String(format: "%.1f", plan.totalDurationSeconds))s")
        return plan
    }

    /// How far past the anchor the late-audio prefeed scan reads before
    /// giving up. A miss is not fatal — the first cut's moov check escalates
    /// to route fallback (the Compatibility engine plays such files) — so
    /// this bounds startup latency, not correctness.
    private static let vodLateAudioScanCapSeconds = 30.0
    /// Audio arriving within this window of the anchor reaches the muxer's
    /// interleaver before the first flush can attempt moov (interim flushes
    /// start at 1.5 s and are additionally gated on the audio latch), so no
    /// prefeed is needed and the scan stops at the first audio packet.
    private static let vodLateAudioPrefeedThresholdSeconds = 2.0

    /// Late-start audio prefeed (start-over deadlock, 2026-07-06). Some
    /// sources carry a selected audio track whose first packet sits seconds
    /// past the plan anchor — dub tracks that skip an undubbed recap are the
    /// common case. Under `+delay_moov` the muxer cannot emit moov (and so
    /// cannot emit init.mp4 or ANY media segment) until it has parsed one
    /// AC-3/E-AC-3/TrueHD packet; a start-over session on such a file would
    /// produce nothing, AVPlayer would never attach, and the producer would
    /// park against the consumer window forever. Scan the demuxer (bounded)
    /// for the track's first packet, stash it into `pendingAudioPackets`
    /// (the existing replay path routes it with full drop/rewrite/major-sync
    /// handling), and re-seek to the anchor — the same warm-cue seek
    /// contract the restart path relies on. The mux loop later drops the
    /// duplicate via `vodPrefedAudioMaxDts`; mp4 fragments carry per-track
    /// timestamps, so the early-delivered sample still presents at its real
    /// time.
    private func prefeedVODLateStartAudioIfNeeded() throws {
        guard vodActive,
              vodEffectiveBaseIndex == 0,
              vodAudioNeedsParsedPacketForMoov,
              shouldIncludeAudio,
              selectedAudioOutputMode == .copy,
              selectedAudioStreamIndex >= 0,
              videoInputStreamIndex >= 0,
              let inCtx = inputCtx,
              let plan = vodPlan else { return }
        let anchorSeconds = plan.sourceStartSeconds(ofSegment: 0)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var scannedPackets = 0
        var consumedAny = false
        var stashed: UnsafeMutablePointer<AVPacket>?
        var firstAudioSeconds: Double?
        while !isCancelled, scannedPackets < 50_000, stashed == nil {
            guard let pkt = packet else { break }
            guard deadlineBoundedReadFrame(inCtx, pkt) >= 0 else { break }
            consumedAny = true
            scannedPackets += 1
            defer { av_packet_unref(pkt) }
            let idx = Int(pkt.pointee.stream_index)
            guard let stream = inCtx.pointee.streams?[idx] else { continue }
            let tb = stream.pointee.time_base
            let ts = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            let seconds: Double? = (ts != Int64.min && tb.den > 0)
                ? Double(ts) * Double(tb.num) / Double(tb.den)
                : nil
            if idx == selectedAudioStreamIndex {
                if outputAudioCodecID == AV_CODEC_ID_TRUEHD {
                    // The replay path trims TrueHD to the first major sync;
                    // a prefed non-sync packet would be trimmed right back
                    // out, so keep scanning for a sync frame.
                    let size = Int(pkt.pointee.size)
                    guard size >= 4, let data = pkt.pointee.data,
                          DVTrueHDMajorSyncScanner.containsMajorSync(bytes: data, count: size)
                    else { continue }
                }
                firstAudioSeconds = seconds
                guard let seconds,
                      seconds - anchorSeconds > Self.vodLateAudioPrefeedThresholdSeconds else {
                    break
                }
                stashed = av_packet_clone(pkt)
            } else if idx == videoInputStreamIndex, let seconds,
                      seconds - anchorSeconds > Self.vodLateAudioScanCapSeconds {
                break
            }
        }
        guard consumedAny else { return }
        // The scan moved the cursor; production must start at the anchor
        // keyframe or the plan misanchors (living-room bug 2 class). A
        // failed seek here is fatal for the session, not ignorable.
        try seekInput(inCtx, toSeconds: anchorSeconds)
        if let stashed {
            let dts = stashed.pointee.dts != Int64.min ? stashed.pointee.dts : stashed.pointee.pts
            vodPrefedAudioMaxDts = dts
            pendingAudioPackets.append(stashed)
            let gap = (firstAudioSeconds ?? anchorSeconds) - anchorSeconds
            cmpLog("[CMP-AVP] vod late-audio prefeed: first audio +\(String(format: "%.2f", gap))s after anchor — prefed one packet for moov (scanned \(scannedPackets) packets)")
        } else if firstAudioSeconds == nil {
            cmpLog("[CMP-AVP] vod late-audio prefeed: no \(outputAudioCodecToken ?? "audio") packet within \(Int(Self.vodLateAudioScanCapSeconds))s of anchor (scanned \(scannedPackets) packets); first cut escalates if moov stays blocked")
        }
    }

    /// Cap on how many plan boundaries the resume-anchor validation walks
    /// back looking for a true random-access point. Each probe costs one
    /// demuxer seek plus a partial GOP of reads (a range request on remote
    /// sources), and every merged segment adds decode-and-discard lead-in
    /// ahead of the resume frame.
    private static let maxResumeAnchorWalkBack = 4
    /// Whether the resume-anchor probe consumed demuxer packets — the
    /// anchor-boundary re-seek in resolveVODPlanIfNeeded must then run even
    /// when the resume time sits exactly on the anchor boundary.
    private var resumeAnchorProbeMovedCursor = false

    private struct AnchorOpenerProbe {
        let codecID: AVCodecID
        let nalLengthSize: Int
    }

    private enum AnchorOpenerVerdict {
        case trueRAP
        case notRAP(vclType: Int)
        case inconclusive
    }

    /// Resume-anchor bitstream validation. The plan's boundaries come from
    /// the container's keyframe index and `AV_PKT_FLAG_KEY`, both of which
    /// can call a frame "key" that the bitstream does not back as a
    /// random-access point (stale MKV cues, open-GOP H.264 I-frames).
    /// Forward play never notices — the decode is continuous — but the
    /// playlist advertises EXT-X-INDEPENDENT-SEGMENTS, so AVPlayer
    /// cold-decodes the resume segment from its first sample, and a non-RAP
    /// opener renders inter-predicted blocks against missing references
    /// until the next true keyframe (the resume-time macroblocking).
    ///
    /// Verify the resume segment's opener in the bitstream; when it fails,
    /// merge it into the nearest earlier segment whose opener IS a true RAP
    /// (never forward — that would visibly skip content). The cold decode
    /// then starts clean and the resume pre-seek discards the lead-in.
    private func resumeAnchorValidatedPlan(
        _ plan: LoopbackSegmentPlan
    ) -> LoopbackSegmentPlan {
        // Bridged sessions are exempt: the plan's openers are OUR encoder's
        // forced keyframes, which are random-access by construction, so
        // probing the source bitstream would judge frames that never reach
        // AVPlayer.
        guard !videoOutputMode.isBridged,
              sourceStartTimeSeconds > plan.anchorSourceSeconds + 0.05,
              plan.segmentCount > 0 else { return plan }
        let requested = plan.segmentIndex(
            forPlaylistSeconds: sourceStartTimeSeconds - plan.anchorSourceSeconds
        )
        guard requested > 0, let probe = makeAnchorOpenerProbe() else { return plan }
        var candidate = requested
        // Segment 0 is never probed: its boundary is the first indexed
        // keyframe — the same frame a cold head start decodes from — and the
        // head IRAP can arrive without AV_PKT_FLAG_KEY (the bootstrap's
        // flag-repair case), which would false-negative here.
        let lowest = max(1, requested - Self.maxResumeAnchorWalkBack)
        while candidate >= lowest {
            switch probeSegmentOpener(plan: plan, segment: candidate, probe: probe) {
            case .trueRAP:
                if candidate == requested {
                    cmpLog("[CMP-AVP] vod resume anchor validated segment=\(requested)")
                    return plan
                }
                cmpLog("[CMP-AVP] vod resume anchor walked back requested=\(requested) anchored=\(candidate)")
                return plan.coalescingSegments(after: candidate, through: requested)
            case .notRAP(let vclType):
                cmpLog("[CMP-AVP] vod resume anchor segment=\(candidate) opener is not a RAP vcl=\(vclType); walking back")
                candidate -= 1
            case .inconclusive:
                // Can't judge the bitstream (read failure, no VCL found).
                // Keep the plan as harvested rather than churn seeks.
                cmpLog("[CMP-AVP] vod resume anchor probe inconclusive segment=\(candidate); keeping plan")
                return plan
            }
        }
        if candidate == 0 {
            cmpLog("[CMP-AVP] vod resume anchor walked back requested=\(requested) anchored=0")
            return plan.coalescingSegments(after: 0, through: requested)
        }
        cmpLog("[CMP-AVP] vod resume anchor validation exhausted walk-back requested=\(requested); keeping plan")
        return plan
    }

    /// Codec + NAL length prefix for the resume-anchor probe, parsed from
    /// the input video stream's avcC/hvcC extradata. Nil (skip validation)
    /// for other codecs or Annex-B extradata.
    private func makeAnchorOpenerProbe() -> AnchorOpenerProbe? {
        guard let inCtx = inputCtx,
              videoInputStreamIndex >= 0,
              let stream = inCtx.pointee.streams?[videoInputStreamIndex],
              let codecpar = stream.pointee.codecpar,
              let extradata = codecpar.pointee.extradata else { return nil }
        let codecID = codecpar.pointee.codec_id
        let extradataSize = Int(codecpar.pointee.extradata_size)
        if codecID == AV_CODEC_ID_H264, extradataSize >= 7, extradata[0] == 1 {
            return AnchorOpenerProbe(
                codecID: codecID,
                nalLengthSize: Int((extradata[4] & 0x03) + 1)
            )
        }
        if codecID == AV_CODEC_ID_HEVC, extradataSize >= 23, extradata[0] == 1 {
            return AnchorOpenerProbe(
                codecID: codecID,
                nalLengthSize: Int((extradata[21] & 0x03) + 1)
            )
        }
        return nil
    }

    /// Seeks to a plan segment's boundary and inspects the packet the
    /// restart gate would open that segment on (first container-flagged
    /// keyframe at or after the boundary): does its bitstream actually hold
    /// a random-access point? H.264 requires IDR (VCL NAL 5) — open-GOP
    /// I-frames let later P-frames reference across them. HEVC accepts any
    /// IRAP (VCL NAL 16-23): trailing pictures after a CRA are clean by
    /// spec, and the cutter already keeps RASL pictures in the CRA's
    /// segment.
    private func probeSegmentOpener(
        plan: LoopbackSegmentPlan,
        segment: Int,
        probe: AnchorOpenerProbe
    ) -> AnchorOpenerVerdict {
        guard let inCtx = inputCtx else { return .inconclusive }
        do {
            try seekInput(inCtx, toSeconds: plan.sourceStartSeconds(ofSegment: segment))
        } catch {
            return .inconclusive
        }
        resumeAnchorProbeMovedCursor = true
        let boundary = plan.boundaries[segment]
        var packetsRead = 0
        while packetsRead < 600 {
            let readPkt = av_packet_alloc()
            let rc = deadlineBoundedReadFrame(inCtx, readPkt)
            guard rc >= 0, let pkt = readPkt else {
                var free = readPkt
                av_packet_free(&free)
                return .inconclusive
            }
            packetsRead += 1
            var verdict: AnchorOpenerVerdict?
            if Int(pkt.pointee.stream_index) == videoInputStreamIndex,
               (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0,
               pkt.pointee.pts != Int64.min,
               pkt.pointee.pts >= boundary {
                verdict = anchorOpenerVerdict(pkt: pkt, probe: probe)
            }
            var free = readPkt
            av_packet_free(&free)
            if let verdict { return verdict }
        }
        return .inconclusive
    }

    private func anchorOpenerVerdict(
        pkt: UnsafeMutablePointer<AVPacket>,
        probe: AnchorOpenerProbe
    ) -> AnchorOpenerVerdict {
        guard let dataPtr = pkt.pointee.data else { return .inconclusive }
        let packetBytes = UnsafeBufferPointer(start: dataPtr,
                                              count: Int(pkt.pointee.size))
        let vclType: Int?
        let isRAP: Bool
        if probe.codecID == AV_CODEC_ID_H264 {
            vclType = ISOBoxSurgery.firstAVCVCLNALType(
                packetBytes: packetBytes,
                nalLengthSize: probe.nalLengthSize
            )
            isRAP = vclType == 5
        } else {
            vclType = ISOBoxSurgery.firstHEVCVCLNALType(
                packetBytes: packetBytes,
                nalLengthSize: probe.nalLengthSize
            )
            isRAP = vclType.map { (16...23).contains($0) } ?? false
        }
        guard let vclType else { return .inconclusive }
        return isRAP ? .trueRAP : .notRAP(vclType: vclType)
    }

    /// Routes a video packet through the plan cutter and flushes the open
    /// fragment when the packet opens a new segment. Runs BEFORE
    /// `rewritePacketForOutput` changes the packet to the output axis, so the
    /// caller captures source PTS/keyframe state first and passes them here.
    private func vodCutBeforeVideoPacketIfNeeded(sourcePTS: Int64, isKeyframe: Bool) throws {
        guard vodActive, vodCutter != nil else { return }
        let target = vodCutter!.index(pts: sourcePTS, isKeyframe: isKeyframe)
        // Progressive anchor: request an interim fragment flush roughly
        // every 1.5 s of routed video. The look-behind path performs the
        // flush after this sample is actually written, so it is included.
        if vodProgressiveAccumulating, sourcePTS != Int64.min {
            if vodLastInterimFlushPts == Int64.min {
                vodLastInterimFlushPts = sourcePTS
            } else if sourcePTS - vodLastInterimFlushPts
                        >= ticks(forSeconds: 1.5, timeBase: vodVideoTimeBase) {
                vodInterimFlushRequested = true
                vodLastInterimFlushPts = sourcePTS
            }
        }
        if !vodHasRoutedVideo {
            vodHasRoutedVideo = true
            vodOpenSegmentIndex = target
            return
        }
        guard target != vodOpenSegmentIndex else { return }
        try performVODFragmentCut(closingSegment: vodOpenSegmentIndex)
        vodOpenSegmentIndex = target
        try waitForVODWindowIfNeeded(nextSegmentIndex: target)
    }

    /// How long the producer may park against the consumer window while the
    /// consumer has NEVER fetched a media segment before the park is treated
    /// as a startup wedge. A healthy attach fetches within ~2 s of the
    /// startup gate firing (the target latches on the GET request itself,
    /// not the transfer), so 20 s is generous even for high-RTT remotes.
    private static let vodStartupParkWedgeSeconds: Double = 20.0

    /// Producer pacing for the VOD mode: block before filling a segment past
    /// the consumer's window (`target + forwardWindow`). Replaces the EVENT
    /// generated-ahead throttle — and inherently parks when the playhead
    /// wedges, since a frozen consumer stops advancing the target.
    ///
    /// Wedge escape (AE #65/#93-parity): a park is healthy backpressure only
    /// if the consumer is fetching — its GETs are the sole thing that ever
    /// advances the target. If the consumer has never fetched a segment
    /// (AVPlayer never attached: startup gate never fired, init.mp4 missing,
    /// route misconfigured…), nothing can unpark the producer and the old
    /// unbounded loop hung the session silently. Fail the session instead so
    /// the route ladder falls back. Consumers that HAVE fetched keep the
    /// unbounded park (a paused player legitimately freezes the target for
    /// hours), but the periodic re-log keeps a genuine steady-state wedge
    /// diagnosable from device logs.
    private func waitForVODWindowIfNeeded(nextSegmentIndex: Int) throws {
        guard vodActive, let store = segmentStore else { return }
        var parkedSince: CFAbsoluteTime?
        var nextLogAtSeconds: Double = 0
        while !isCancelled, !store.vodProducerMayAppend(segmentIndex: nextSegmentIndex) {
            let now = CFAbsoluteTimeGetCurrent()
            let since = parkedSince ?? now
            parkedSince = since
            let parked = now - since
            let consumerFetched = store.vodConsumerHasFetchedSegment()
            if parked >= nextLogAtSeconds {
                nextLogAtSeconds = parked + 10
                cmpLog("[CMP-AVP] vod window backpressure parked segment=\(nextSegmentIndex) parked=\(Int(parked))s consumerFetched=\(consumerFetched ? 1 : 0)")
            }
            if !consumerFetched, parked >= Self.vodStartupParkWedgeSeconds {
                cmpLog("[CMP-AVP] vod window backpressure WEDGE: parked \(Int(parked))s at segment=\(nextSegmentIndex) with no consumer fetch ever — failing session for route fallback")
                throw LoopbackWriterError.vodStartupConsumerWedge(
                    parkedSeconds: Int(parked),
                    segment: nextSegmentIndex
                )
            }
            // A parked producer reads no packets, so a bitmap subtitle
            // enabled while parked would otherwise wait for the next
            // append slot before its backlog replays.
            drainBitmapTapBacklogIfNeeded()
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
            throw LoopbackWriterError.muxWriteFailures(lastRC: drainRC, consecutive: 1)
        }
        let flushRC = av_write_frame(outCtx, nil)
        if flushRC < 0 {
            throw LoopbackWriterError.muxWriteFailures(lastRC: flushRC, consecutive: 1)
        }
        if !vodDidFlushFirstFragment {
            vodDidFlushFirstFragment = true
            // The first flush can split ftyp+moov and the fragment across
            // two calls (delay_moov); flush once more so the closing
            // segment is fully emitted before the next packet is written.
            let secondRC = av_write_frame(outCtx, nil)
            if secondRC < 0 {
                throw LoopbackWriterError.muxWriteFailures(lastRC: secondRC, consecutive: 1)
            }
        }
        try throwIfFatalIOError()
        // Moov-wedge escalation (start-over deadlock, 2026-07-06): a cut
        // flush for a parse-needing audio codec MUST have emitted moov —
        // the muxer writes it lazily on the first successful flush, and
        // `mov_write_packet(NULL)` swallows the failure code, so a missing
        // init segment here is the only reliable signal. Without it AVPlayer
        // can never attach and the producer eventually parks forever; fail
        // the session instead so the route ladder falls back to an engine
        // that can play the file.
        if vodAudioNeedsParsedPacketForMoov, !initSegmentWritten {
            cmpLog("[CMP-AVP] vod cut segment=\(closingSegment) could not emit moov (audioRouted=\(vodAudioPacketRouted ? 1 : 0), primeAttempts=\(vodMoovPrimeAttempts)) — failing session for route fallback")
            throw LoopbackWriterError.vodMoovBlocked(
                closingSegment: closingSegment,
                audioRouted: vodAudioPacketRouted
            )
        }
    }

    private static func defaultMinimumStartupMediaDuration(
        for videoMode: LoopbackSessionSpec.VideoMode,
        videoOutputMode: LoopbackSessionSpec.VideoOutputMode
    ) -> Double {
        if videoOutputMode.isBridged {
            // Bridged output has a tight, predictable GOP — the encoder is
            // forced to a keyframe on every plan boundary — so the long-GOP
            // allowance below buys nothing but startup latency.
            return 4.0
        }
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

    func stop(
        recyclingInputInto handoff: LoopbackInputHandoff? = nil,
        completion: (() -> Void)? = nil
    ) {
        // Flip the flag synchronously so the in-flight `av_read_frame` bails
        // via the interrupt callback on its next poll, rather than waiting
        // for the muxQueue to drain.
        cancelLock.lock()
        _cancelled = true
        let token = interruptToken
        var deadHandoff: LoopbackInputHandoff?
        if let handoff {
            if didTeardown {
                deadHandoff = handoff
            } else {
                outgoingInputHandoff = handoff
            }
        }
        cancelLock.unlock()
        token.cancel()
        // Teardown already ran — nothing will ever be published; release the
        // successor to open fresh instead of waiting out its claim timeout.
        deadHandoff?.cancelPublication()

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
            installBridgedVideoPlanIfNeeded()
            try prefeedVODLateStartAudioIfNeeded()
            // Prefetch + filter until we have a complete hvcC in extradata.
            // Filtered packets are stashed in pendingVideoPackets and replayed
            // below.
            if videoOutputMode.isBridged {
                // There is no source `hvcC` to bootstrap from — the parameter
                // sets come from our own encoder. Normally they are already
                // installed by `openVideoTranscodePipeline` (the VideoToolbox
                // wrapper publishes them during `avcodec_open2` under the
                // global-header flag); the priming read is the fallback.
                try primeBridgedVideoExtradataIfNeeded()
            } else if vodActive, vodPlanProvidedAtInit {
                // Restarted VOD session: output extradata comes from codecpar
                // (the same source the first session already validated). The
                // bootstrap scan otherwise swallows up to a GOP of packets it
                // never replays, misanchoring production past the restart
                // target (living-room bug 2).
                cmpLog("[CMP-AVP] vod restart: extradata bootstrap skipped")
            } else {
                try bootstrapVideoExtradata()
            }
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
                if LoopbackSegmentWriter.traceThroughput {
                    let started = CFAbsoluteTimeGetCurrent()
                    rc = deadlineBoundedReadFrame(inputCtx, packet)
                    throughputTiming.readMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                    throughputTiming.readCalls += 1
                } else {
                    rc = deadlineBoundedReadFrame(inputCtx, packet)
                }
                if isCancelled {
                    break
                }
                if rc < 0 {
                    // Genuine end-of-content finalizes below; a source that
                    // died clearly short of the known bytes/plan throws so
                    // the truncation is never published as a complete VOD.
                    try throwIfPrematureSourceEnd(readRC: rc)
                    break
                }
                emitSourceDownloadStatsIfNeeded()
                guard let pkt = packet else { break }
                let inputIdx = Int(pkt.pointee.stream_index)
                defer { av_packet_unref(pkt) }
                if isCancelled {
                    continue
                }
                // Subtitle-tap streams are kept readable but never muxed:
                // decode inline, emit cues, and move on before the stream
                // map (they have no output stream).
                if subtitleTapDecoders[inputIdx] != nil {
                    tapDecodeSubtitlePacket(pkt: pkt, inputIdx: inputIdx)
                    continue
                }
                if bitmapTapTimeBases[inputIdx] != nil {
                    tapHandleBitmapSubtitlePacket(pkt: pkt, inputIdx: inputIdx)
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

                if bufferVODPreGateAudioIfNeeded(pkt: pkt, inputIdx: inputIdx) {
                    continue
                }

                if vodActive, vodShouldDropPacket(pkt: pkt, inputIdx: inputIdx) {
                    continue
                }

                if inputIdx == videoInputStreamIndex,
                   shouldDropCorruptHEVCVideoPacket(pkt) {
                    continue
                }

                // Late-audio prefeed duplicate: the packet fed ahead of the
                // loop comes around again when the demuxer reaches its file
                // position; drop everything at-or-before it once.
                if let prefedMax = vodPrefedAudioMaxDts, inputIdx == selectedAudioStreamIndex {
                    let dts = pkt.pointee.dts != Int64.min ? pkt.pointee.dts : pkt.pointee.pts
                    if dts != Int64.min, dts <= prefedMax {
                        continue
                    }
                    vodPrefedAudioMaxDts = nil
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

                if inputIdx == videoInputStreamIndex, videoOutputMode.isBridged {
                    if isCancelled {
                        continue
                    }
                    // Mirrors the bridged-audio branch above: the bridge
                    // routes its own encoder output and the packet never
                    // reaches the copy path's transform/route tail.
                    if Self.traceThroughput {
                        let started = CFAbsoluteTimeGetCurrent()
                        try transcodeVideoPacket(pkt, outStreamIndex: Int32(outIdx))
                        throughputTiming.videoMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
                        throughputTiming.videoPackets += 1
                    } else {
                        try transcodeVideoPacket(pkt, outStreamIndex: Int32(outIdx))
                    }
                    try replayVODPreGateAudioPacketsIfNeeded()
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
                }

                if isCancelled {
                    continue
                }
                if inputIdx == videoInputStreamIndex {
                    try routeVideoPacketToMux(
                        pkt,
                        outStreamIndex: Int32(outIdx),
                        inputStreamIndex: inputIdx
                    )
                    try replayVODPreGateAudioPacketsIfNeeded()
                } else {
                    rewritePacketForOutput(
                        pkt: pkt,
                        outStreamIndex: Int32(outIdx),
                        inputStreamIndex: inputIdx
                    )
                    try writePacketToMux(pkt)
                }
            }

            if !isCancelled {
                // Video first: the encoder's tail GOP has to be routed while
                // the one-packet look-behind can still telescope its duration.
                try finishTranscodedVideo()
                try finishTranscodedAudio()
                try flushPendingMuxVideoPacket(nextDTS: nil)
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
                    throw LoopbackWriterError.muxWriteFailures(
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
            Self.logger.error("LoopbackSegmentWriter failed: \(String(describing: error), privacy: .public)")
            teardown()
            onFinished?(error)
        }
    }

    /// Classifies a negative `av_read_frame` result and throws when the
    /// source clearly ended short of the known content. Both completeness
    /// signals ride state that is valid whether this producer started at
    /// byte 0 or was restarted mid-plan: the input IO position is measured
    /// against the transport's known size, and the plan-axis position uses
    /// the segment index (plan-absolute) rather than this instance's
    /// appended-duration counter.
    private func throwIfPrematureSourceEnd(readRC rc: Int32) throws {
        var bytePosition: Int64?
        var fileSizeBytes: Int64?
        if let pb = inputCtx?.pointee.pb {
            let position = avio_seek(pb, 0, SEEK_CUR)
            if position >= 0 { bytePosition = position }
            let size = avio_size(pb)
            if size > 0 { fileSizeBytes = size }
        }
        var reachedPlanSeconds: Double?
        var plannedTotalSeconds: Double?
        if vodActive, let plan = vodPlan, plan.segmentCount > 0 {
            plannedTotalSeconds = plan.totalDurationSeconds
            reachedPlanSeconds = plan.startSeconds[min(currentSegmentIndex, plan.segmentCount - 1)]
        }
        cancelLock.lock()
        let deadlineAborted = interruptToken.didAbortOnDeadline
        cancelLock.unlock()
        let verdict = LoopbackIngestEndPolicy.classify(
            readResult: rc,
            bytePosition: bytePosition,
            fileSizeBytes: fileSizeBytes,
            reachedPlanSeconds: reachedPlanSeconds,
            plannedTotalSeconds: plannedTotalSeconds,
            deadlineAborted: deadlineAborted
        )
        guard case let .prematureSourceEnd(shortfallBytes, shortfallSeconds) = verdict else {
            return
        }
        Self.logger.error(
            "[CMP-AVP] premature source end rc=\(rc) (\(Self.ffmpegError(rc), privacy: .public)) pos=\(bytePosition ?? -1) size=\(fileSizeBytes ?? -1) reached=\(reachedPlanSeconds ?? -1, format: .fixed(precision: 1))s planned=\(plannedTotalSeconds ?? -1, format: .fixed(precision: 1))s"
        )
        throw LoopbackWriterError.prematureSourceEnd(
            readRC: rc,
            shortfallBytes: shortfallBytes,
            shortfallSeconds: shortfallSeconds
        )
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
    /// throw `LoopbackWriterError.muxWriteFailures` when the threshold is reached
    /// (or immediately for unambiguously-fatal codes).
    private func evaluateMuxWriteResult(_ rc: Int32) throws {
        try throwIfFatalIOError()
        if rc < 0 {
            consecutiveMuxWriteFailures += 1
            let detail = Self.ffmpegError(rc)
            Self.logger.error(
                "av_interleaved_write_frame failed: rc=\(rc) (\(detail, privacy: .public)) consecutive=\(self.consecutiveMuxWriteFailures)"
            )
            // OSLog does not reach the devicectl console capture; mirror to
            // stdout so on-device runs surface dropped packets.
            cmpLog("[CMP-AVP] mux write failed rc=\(rc) (\(detail)) consecutive=\(consecutiveMuxWriteFailures)")
            if rc == avErrorInvalidData
                || consecutiveMuxWriteFailures >= Self.maxConsecutiveMuxWriteFailures {
                throw LoopbackWriterError.muxWriteFailures(
                    lastRC: rc,
                    consecutive: consecutiveMuxWriteFailures
                )
            }
            return
        }
        consecutiveMuxWriteFailures = 0
        // Last-muxed timestamps are recorded pre-write in
        // normalizeMuxerTimestampsIfNeeded; the packet is blank here
        // (av_interleaved_write_frame takes ownership on success).
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

    /// Normal blocking-read allowance — the semantic successor of the old
    /// 10 s avio `rw_timeout`, enforced by the interrupt-callback span
    /// deadline so it can stretch to the outage park allowance while the
    /// source proxy reports an origin outage.
    static let readDeadlineSeconds: Double = 10
    /// Span allowance for the whole `avformat_open_input` +
    /// `find_stream_info` bootstrap (multi-second legitimate on cold-cache
    /// 4K WAN opens; wedged opens must still fail well before the consumer
    /// watchdogs give up on the session).
    static let openDeadlineSeconds: Double = 60

    /// Live query into the source proxy's outage state, installed on the
    /// interrupt token at open so a blocking read can park through a flagged
    /// outage instead of timing out. Set by the backend before start.
    var isSourceOutageActive: (() -> Bool)?

    /// `av_read_frame` with the span deadline armed. Every read in this
    /// writer goes through here — with `rw_timeout` raised to a backstop,
    /// the token's deadline is the only thing bounding a wedged read.
    private func deadlineBoundedReadFrame(
        _ ctx: UnsafeMutablePointer<AVFormatContext>?,
        _ pkt: UnsafeMutablePointer<AVPacket>?
    ) -> Int32 {
        cancelLock.lock()
        let token = interruptToken
        cancelLock.unlock()
        token.beginBlockingSpan(allowanceSeconds: Self.readDeadlineSeconds)
        defer { token.endBlockingSpan() }
        return av_read_frame(ctx, pkt)
    }

    /// Installs the cancellation poll on a context. FFmpeg polls it
    /// between / during I/O ops; returning 1 bails `av_read_frame` (or
    /// open/probe) with AVERROR_EXIT. The opaque target is the writer's
    /// `interruptToken`, NEVER the writer itself: FFmpeg copies the
    /// AVIOInterruptCB struct into the nested http/tcp URLContext and
    /// AVIOContext at open time, and those copies must stay valid across
    /// demuxer handoffs after this writer deallocates (living-room SIGSEGV
    /// on the first recycled-demuxer seek).
    private func installInterruptCallback(
        on ctx: UnsafeMutablePointer<AVFormatContext>,
        token: LoopbackInterruptToken
    ) {
        let tokenPtr = Unmanaged.passUnretained(token).toOpaque()
        ctx.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                let token = Unmanaged<LoopbackInterruptToken>.fromOpaque(opaque).takeUnretainedValue()
                return token.shouldInterrupt() ? 1 : 0
            },
            opaque: tokenPtr
        )
    }

    private func openInput() throws {
        // Producer restart: claim the retiring session's demuxer instead of
        // reopening the source. Skips avformat_open_input +
        // find_stream_info + the matroska cue warm — the dominant fixed
        // cost of every seek-triggered restart. Any hiccup falls through
        // to a fresh open.
        if let handoff = recycledInputHandoff,
           let recycled = handoff.claim(timeout: 1.5) {
            // Adopt the token baked into the recycled context's nested I/O
            // contexts; the retiring writer's stop() left it cancelled.
            cancelLock.lock()
            interruptToken = recycled.token
            cancelLock.unlock()
            recycled.token.reset()
            recycled.token.setSourceOutageProvider(isSourceOutageActive)
            if isCancelled {
                // This writer was stopped between init and claim; re-cancel
                // so the context's reads abort instead of riding rw_timeout.
                recycled.token.cancel()
            }
            installInterruptCallback(on: recycled.context, token: recycled.token)
            do {
                videoInputStreamIndex = try Self.resolveSelectedVideoStreamIndex(
                    in: recycled.context,
                    videoMode: videoMode,
                    videoOutputMode: videoOutputMode
                )
                Self.discardUnusedStreamsForMux(
                    in: recycled.context,
                    keepVideoIndex: videoInputStreamIndex,
                    keepAudioOrdinal: shouldIncludeAudio ? selectedAudioTrackIndex : -1,
                    keepAudioFfIndex: sessionSpec.selectedAudio.ffIndex,
                    keepSubtitleIndices: subtitleTapKeepSet(in: recycled.context)
                )
                configureSubtitleTap(in: recycled.context)
                inputCtx = recycled.context
                recycledInputActive = true
                cmpLog("[CMP-AVP] vod restart: recycled source demuxer")
                return
            } catch {
                var doomed: UnsafeMutablePointer<AVFormatContext>? = recycled.context
                avformat_close_input(&doomed)
                cmpLog("[CMP-AVP] vod restart: recycled demuxer rejected (\(error)); reopening source")
            }
        }

        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard ctx != nil else {
            throw LoopbackWriterError.allocInput
        }

        cancelLock.lock()
        let token = interruptToken
        cancelLock.unlock()
        token.setSourceOutageProvider(isSourceOutageActive)
        installInterruptCallback(on: ctx!, token: token)
        // Bracket the whole open + stream-info probe: individual IO ops are
        // no longer bounded by rw_timeout (raised to a far backstop), so the
        // span deadline is what stops a wedged-at-open source from holding
        // the mux thread.
        token.beginBlockingSpan(allowanceSeconds: Self.openDeadlineSeconds)
        defer { token.endBlockingSpan() }

        var options: OpaquePointer?
        if !sourceHeaders.isEmpty {
            let headerString = sourceHeaders
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n") + "\r\n"
            av_dict_set(&options, "headers", headerString, 0)
        }
        // Wedge protection lives in the interrupt-callback span deadline
        // (`deadlineBoundedReadFrame` / the open bracket below): the token
        // enforces the normal 10 s read allowance but can park a read through
        // a flagged origin outage — a fixed avio `rw_timeout` cannot. This
        // avio-level timeout stays only as a far backstop above the token's
        // outage park allowance.
        av_dict_set(&options, "rw_timeout", "300000000", 0)
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
            throw LoopbackWriterError.openInput(rc)
        }
        guard let openedContext = ctx else {
            throw LoopbackWriterError.allocInput
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
            videoMode: videoMode,
            videoOutputMode: videoOutputMode
        )

        Self.discardUnusedStreamsForMux(
            in: openedContext,
            keepVideoIndex: videoInputStreamIndex,
            keepAudioOrdinal: shouldIncludeAudio ? selectedAudioTrackIndex : -1,
            keepAudioFfIndex: sessionSpec.selectedAudio.ffIndex,
            keepSubtitleIndices: subtitleTapKeepSet(in: openedContext)
        )

        if avformat_find_stream_info(openedContext, nil) < 0 {
            throw LoopbackWriterError.findStreamInfo
        }
        configureSubtitleTap(in: openedContext)

        if sessionSpec.servingMode != .vodPlan {
            try seekInputToStartTimeIfNeeded(openedContext)
        }
        // VOD-plan sessions seek in resolveVODPlanIfNeeded instead: both the
        // harvest and restart paths warm the matroska cue index and then
        // seek — with cold cues a BACKWARD seek lands by linear estimate,
        // potentially PAST the anchor segment's keyframe, and the producer
        // never generates the segment AVPlayer's resume pre-seek fetches
        // (living-room startup stall: resume 6199.7s mid-segment-1549,
        // first produced segment was 1550). Seeking here as well was a
        // wasted cold-cue seek — extra range requests into the remote
        // source on every producer restart.
    }

    /// Which input stream supplies the selected audio track, or nil when the
    /// selection names no audio stream in this context.
    ///
    /// An explicit `ffIndex` wins only when it actually points at an audio
    /// stream here. A stale index — or an ordinal-shaped one, as offline
    /// manifests carry (the server writes the audio-list ordinal and drops the
    /// real ffmpeg stream index) — falls through to the ordinal scan instead
    /// of naming a video stream or nothing at all.
    ///
    /// Both the demuxer discard pass and the mux setup resolve through this so
    /// they cannot disagree: when they did, the discard pass dropped the audio
    /// the muxer then waited forever to receive, surfacing as `vodMoovBlocked`
    /// with nothing naming the real cause.
    private static func audioStreamIndex(
        in ctx: UnsafeMutablePointer<AVFormatContext>,
        ffIndex: Int?,
        ordinal: Int
    ) -> Int? {
        let nb = Int(ctx.pointee.nb_streams)
        func isAudio(_ index: Int) -> Bool {
            guard index >= 0, index < nb,
                  let stream = ctx.pointee.streams?[index] else { return false }
            return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
        }
        if let ffIndex, isAudio(ffIndex) { return ffIndex }
        guard ordinal >= 0 else { return nil }
        var audioOrdinal = 0
        for i in 0..<nb where isAudio(i) {
            if audioOrdinal == ordinal { return i }
            audioOrdinal += 1
        }
        return nil
    }

    /// Marks every stream we won't mux as `AVDISCARD_ALL` so libavformat
    /// skips them during `find_stream_info` and `av_read_frame`. Discards
    /// (a) all non-audio / non-video streams unconditionally and (b) every
    /// audio stream other than the one `audioStreamIndex` resolves
    /// from `keepAudioFfIndex`/`keepAudioOrdinal`. Pass `keepAudioOrdinal=-1`
    /// with no `keepAudioFfIndex` to drop audio entirely.
    private static func discardUnusedStreamsForMux(
        in ctx: UnsafeMutablePointer<AVFormatContext>,
        keepVideoIndex: Int,
        keepAudioOrdinal: Int,
        keepAudioFfIndex: Int?,
        keepSubtitleIndices: Set<Int>
    ) {
        let nb = Int(ctx.pointee.nb_streams)
        let keepAudioIndex = audioStreamIndex(
            in: ctx,
            ffIndex: keepAudioFfIndex,
            ordinal: keepAudioOrdinal
        )
        var discardedSubtitles = 0
        var discardedOther = 0
        var discardedExtraVideo = 0
        var discardedExtraAudio = 0
        var keptVideo = 0
        var keptAudio = 0
        var keptSubtitles = 0
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
                    if i == keepAudioIndex {
                        keptAudio += 1
                    } else {
                        stream.pointee.discard = AVDISCARD_ALL
                        discardedExtraAudio += 1
                    }
                    continue
                }
                if mediaType == AVMEDIA_TYPE_SUBTITLE, keepSubtitleIndices.contains(i) {
                    // Subtitle-tap streams stay readable so their packets
                    // arrive through the same av_read_frame loop that feeds
                    // the muxer. Set explicitly (not just "don't discard")
                    // because a RECYCLED demuxer carries the prior writer's
                    // discard flags.
                    stream.pointee.discard = AVDISCARD_DEFAULT
                    keptSubtitles += 1
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
        cmpLog("[CMP-AVP] mux probe filter total=\(nb) keptVideo=\(keptVideo) keptAudio=\(keptAudio) keptSubtitles=\(keptSubtitles) discardedExtraVideo=\(discardedExtraVideo) discardedExtraAudio=\(discardedExtraAudio) discardedSubtitles=\(discardedSubtitles) discardedOther=\(discardedOther)")
    }

    /// Streams to keep readable for the subtitle tap. Empty when no tap
    /// consumer is wired, preserving the discard-everything behaviour.
    private func subtitleTapKeepSet(
        in ctx: UnsafeMutablePointer<AVFormatContext>
    ) -> Set<Int> {
        var keep: Set<Int> = []
        if onSubtitleTapCue != nil {
            keep.formUnion(Self.textSubtitleStreamIndices(in: ctx))
        }
        if onBitmapSubtitleTapCue != nil {
            // Bitmap streams stay readable (their packets are a rounding
            // error against the video interleave already being read) but
            // are only decoded while selected.
            keep.formUnion(Self.bitmapSubtitleStreamIndices(in: ctx))
        }
        return keep
    }

    /// Opens one text-subtitle decoder per tapped stream and reports the
    /// track set (header + codec kind) to the tap consumer. Mux queue only;
    /// runs on every writer start — restarts rebuild identical decoders.
    private func configureSubtitleTap(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard onSubtitleTapCue != nil else { return }
        freeSubtitleTapDecoders()
        var infos: [LoopbackSubtitleTapTrackInfo] = []
        guard let streams = ctx.pointee.streams else { return }
        for i in Self.textSubtitleStreamIndices(in: ctx).sorted() {
            guard let stream = streams[i],
                  let codecparPtr = stream.pointee.codecpar,
                  let codec = avcodec_find_decoder(codecparPtr.pointee.codec_id) else { continue }
            var codecCtx = avcodec_alloc_context3(codec)
            guard codecCtx != nil else { continue }
            if avcodec_parameters_to_context(codecCtx, codecparPtr) < 0
                || avcodec_open2(codecCtx, codec, nil) < 0 {
                avcodec_free_context(&codecCtx)
                continue
            }
            guard let openedCtx = codecCtx else { continue }
            subtitleTapDecoders[i] = openedCtx
            subtitleTapTimeBases[i] = stream.pointee.time_base

            let codecID = codecparPtr.pointee.codec_id
            let isNativeASS = codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA
            let header: Data
            if let sh = openedCtx.pointee.subtitle_header,
               openedCtx.pointee.subtitle_header_size > 0 {
                header = Data(bytes: sh, count: Int(openedCtx.pointee.subtitle_header_size))
            } else if let ed = codecparPtr.pointee.extradata,
                      codecparPtr.pointee.extradata_size > 0 {
                header = Data(bytes: ed, count: Int(codecparPtr.pointee.extradata_size))
            } else {
                header = Data()
            }
            infos.append(LoopbackSubtitleTapTrackInfo(
                streamIndex: i,
                isNativeASS: isNativeASS,
                header: header
            ))
        }
        if !infos.isEmpty {
            onSubtitleTapTracks?(infos)
        }
        configureBitmapSubtitleTap(in: ctx)
    }

    /// Records the bitmap-subtitle streams the tap can serve (time bases,
    /// codec parameters, canvas fallback) without opening decoders —
    /// decoding starts lazily on the first packet of a selected stream.
    private func configureBitmapSubtitleTap(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard onBitmapSubtitleTapCue != nil else { return }
        guard let streams = ctx.pointee.streams else { return }
        // Bitmap decoders position rects against a canvas the track header
        // can't always provide; seed from the container video dimensions.
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = streams[i],
                  let codecparPtr = stream.pointee.codecpar else { continue }
            if codecparPtr.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               codecparPtr.pointee.width > 0, codecparPtr.pointee.height > 0 {
                bitmapTapFallbackCanvas = (codecparPtr.pointee.width, codecparPtr.pointee.height)
                break
            }
        }
        var available: [Int] = []
        for i in Self.bitmapSubtitleStreamIndices(in: ctx).sorted() {
            guard let stream = streams[i],
                  let codecparPtr = stream.pointee.codecpar else { continue }
            bitmapTapTimeBases[i] = stream.pointee.time_base
            bitmapTapCodecpars[i] = codecparPtr
            available.append(i)
        }
        if !available.isEmpty {
            onBitmapSubtitleTapTracks?(available)
        }
    }

    private func freeSubtitleTapDecoders() {
        for (_, ctx) in subtitleTapDecoders {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&doomed)
        }
        subtitleTapDecoders.removeAll()
        subtitleTapTimeBases.removeAll()
        for (_, ctx) in bitmapTapDecoders {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&doomed)
        }
        bitmapTapDecoders.removeAll()
        bitmapTapTimeBases.removeAll()
        bitmapTapCodecpars.removeAll()
        freeBitmapTapBacklog()
    }

    /// Decode one tapped text-subtitle packet and emit its events. Text
    /// decodes are parses — microseconds — so this runs inline on the mux
    /// thread between av_read_frame calls.
    private func tapDecodeSubtitlePacket(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputIdx: Int
    ) {
        guard let codecCtx = subtitleTapDecoders[inputIdx],
              let timeBase = subtitleTapTimeBases[inputIdx],
              pkt.pointee.pts != Int64.min else { return }

        var sub = AVSubtitle()
        defer { avsubtitle_free(&sub) }
        var gotSubtitle: Int32 = 0
        let rc = avcodec_decode_subtitle2(codecCtx, &sub, &gotSubtitle, pkt)
        guard rc >= 0, gotSubtitle != 0 else { return }

        let basePtsSeconds = Double(pkt.pointee.pts)
            * Double(timeBase.num) / Double(timeBase.den)
        let startMs = Int64((basePtsSeconds + Double(sub.start_display_time) / 1000.0) * 1000.0)
        let endMs: Int64 = {
            if sub.end_display_time != UInt32.max,
               sub.end_display_time > sub.start_display_time {
                return Int64((basePtsSeconds + Double(sub.end_display_time) / 1000.0) * 1000.0)
            }
            if pkt.pointee.duration > 0 {
                let durSeconds = Double(pkt.pointee.duration)
                    * Double(timeBase.num) / Double(timeBase.den)
                return startMs + Int64(durSeconds * 1000.0)
            }
            return startMs + 5000
        }()
        let durationMs = max(Int64(0), endMs - startMs)

        for i in 0..<Int(sub.num_rects) {
            guard let rect = sub.rects[i]?.pointee,
                  rect.type == SUBTITLE_ASS,
                  let assPtr = rect.ass else { continue }
            let ass = String(cString: assPtr)
            guard !ass.isEmpty else { continue }
            onSubtitleTapCue?(LoopbackSubtitleTapCue(
                streamIndex: inputIdx,
                eventText: ass,
                startMs: startMs,
                durationMs: durationMs
            ))
        }
    }

    /// Route one tapped bitmap-subtitle packet: replay any pending backlog
    /// first (so a just-landed selection sees packets read before it),
    /// live-decode when the packet's stream is selected, and buffer it
    /// either way — the rolling backlog is what future (re)selections
    /// replay from.
    private func tapHandleBitmapSubtitlePacket(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputIdx: Int
    ) {
        drainBitmapTapBacklogIfNeeded()
        if bitmapTapSelectedStream() == inputIdx {
            tapDecodeBitmapSubtitlePacket(pkt: pkt, inputIdx: inputIdx)
        }
        bufferBitmapTapPacket(pkt: pkt, inputIdx: inputIdx)
    }

    /// Clone `pkt` into the stream's rolling backlog, pruning oldest-first
    /// past the media window / byte cap. Mux thread only.
    private func bufferBitmapTapPacket(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputIdx: Int
    ) {
        guard let timeBase = bitmapTapTimeBases[inputIdx],
              let clone = av_packet_clone(pkt) else { return }
        let noPts = Int64.min
        let ptsRaw: Int64 = pkt.pointee.pts != noPts ? pkt.pointee.pts
            : (pkt.pointee.dts != noPts ? pkt.pointee.dts : 0)
        let seconds = Double(ptsRaw) * Double(timeBase.num) / Double(timeBase.den)
        var entries = bitmapTapBacklog[inputIdx] ?? []
        var bytes = bitmapTapBacklogBytes[inputIdx] ?? 0
        entries.append((packet: clone, seconds: seconds))
        bytes += Int(clone.pointee.size)
        while let oldest = entries.first,
              bytes > Self.bitmapTapBacklogByteCap
                || oldest.seconds < seconds - Self.bitmapTapBacklogWindowSeconds {
            bytes -= Int(oldest.packet.pointee.size)
            var doomed: UnsafeMutablePointer<AVPacket>? = oldest.packet
            av_packet_free(&doomed)
            entries.removeFirst()
        }
        bitmapTapBacklog[inputIdx] = entries
        bitmapTapBacklogBytes[inputIdx] = bytes
    }

    /// Replay the selected stream's backlog through the decoder when a
    /// selection is pending. Called from the read loops and from the VOD
    /// backpressure park loop (a parked producer reads no packets, but a
    /// mid-playback enable still needs its drain promptly). Packets stay
    /// buffered afterwards — each activation opens a fresh cue store, so
    /// a later re-selection replays the full window again. Mux thread only.
    private func drainBitmapTapBacklogIfNeeded() {
        guard let selected = takeBitmapTapDrainRequest(),
              let entries = bitmapTapBacklog[selected], !entries.isEmpty else { return }
        cmpLog("[CMP-TAP] bitmap backlog drain stream=\(selected) packets=\(entries.count)")
        for entry in entries {
            tapDecodeBitmapSubtitlePacket(pkt: entry.packet, inputIdx: selected)
        }
    }

    private func freeBitmapTapBacklog() {
        for (_, entries) in bitmapTapBacklog {
            for entry in entries {
                var doomed: UnsafeMutablePointer<AVPacket>? = entry.packet
                av_packet_free(&doomed)
            }
        }
        bitmapTapBacklog.removeAll()
        bitmapTapBacklogBytes.removeAll()
    }

    /// Decode one tapped bitmap-subtitle packet (only while its stream is
    /// selected) and emit converted cues. A PGS decode is palette+RLE work
    /// on cue-sized regions — milliseconds, and cues are seconds apart —
    /// so, like the text tap, it runs inline on the mux thread.
    private func tapDecodeBitmapSubtitlePacket(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputIdx: Int
    ) {
        guard bitmapTapSelectedStream() == inputIdx,
              let timeBase = bitmapTapTimeBases[inputIdx],
              let codecCtx = ensureBitmapTapDecoder(inputIdx: inputIdx) else { return }

        var sub = AVSubtitle()
        defer { avsubtitle_free(&sub) }
        var gotSubtitle: Int32 = 0
        let rc = avcodec_decode_subtitle2(codecCtx, &sub, &gotSubtitle, pkt)
        let isPGS = codecCtx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        if rc >= 0, gotSubtitle == 0, isPGS, pkt.pointee.size > 30 {
            // Some Matroska remuxes drop the PGS display-set END segment,
            // leaving the decoder accumulating with nothing emitted. Push a
            // minimal synthetic END segment at the same timestamps to flush
            // the pending composition (mirrors the extractor's repair; only
            // for substantial packets — tiny ones ARE end/control segments).
            var payload = [UInt8](repeating: 0, count: 64)
            payload[0] = 0x80
            payload.withUnsafeMutableBufferPointer { buffer in
                var synthetic = AVPacket()
                synthetic.data = buffer.baseAddress
                synthetic.size = 3
                synthetic.pts = pkt.pointee.pts
                synthetic.dts = pkt.pointee.dts
                synthetic.duration = pkt.pointee.duration
                synthetic.stream_index = pkt.pointee.stream_index
                _ = avcodec_decode_subtitle2(codecCtx, &sub, &gotSubtitle, &synthetic)
            }
        }
        guard rc >= 0, gotSubtitle != 0 else { return }

        let noPts = Int64.min
        let ptsRaw: Int64 = pkt.pointee.pts != noPts ? pkt.pointee.pts
            : (pkt.pointee.dts != noPts ? pkt.pointee.dts : 0)
        let basePtsSeconds = Double(ptsRaw) * Double(timeBase.num) / Double(timeBase.den)
        let startMs = Int64((basePtsSeconds + Double(sub.start_display_time) / 1000.0) * 1000.0)
        let endMs: Int64 = {
            if sub.end_display_time != UInt32.max,
               sub.end_display_time > sub.start_display_time {
                return Int64((basePtsSeconds + Double(sub.end_display_time) / 1000.0) * 1000.0)
            }
            if pkt.pointee.duration > 0 {
                let durSeconds = Double(pkt.pointee.duration)
                    * Double(timeBase.num) / Double(timeBase.den)
                return startMs + Int64(durSeconds * 1000.0)
            }
            // No explicit end anywhere. PGS relies on the next composition
            // trimming this cue; 5 s is only the ceiling if the stream goes
            // quiet.
            return startMs + 5000
        }()
        let startSeconds = Double(startMs) / 1000.0
        let endSeconds = Double(max(startMs, endMs)) / 1000.0

        var cues: [BitmapSubtitleCue] = []
        for i in 0..<Int(sub.num_rects) {
            guard let rect = sub.rects[i]?.pointee,
                  rect.type == SUBTITLE_BITMAP,
                  let cue = Self.bitmapTapCue(
                      from: rect,
                      codecCtx: codecCtx,
                      fallbackCanvas: bitmapTapFallbackCanvas,
                      startSeconds: startSeconds,
                      endSeconds: endSeconds
                  ) else { continue }
            cues.append(cue)
        }
        if isPGS {
            // Every PGS composition — including an empty clear event —
            // supersedes whatever is on screen.
            onBitmapSubtitleTapCue?(inputIdx, cues, startSeconds)
        } else if !cues.isEmpty {
            // DVD subs carry explicit durations; empty events mean nothing.
            onBitmapSubtitleTapCue?(inputIdx, cues, nil)
        }
    }

    /// Lazily open the decoder for a selected bitmap stream.
    private func ensureBitmapTapDecoder(inputIdx: Int) -> UnsafeMutablePointer<AVCodecContext>? {
        if let existing = bitmapTapDecoders[inputIdx] { return existing }
        guard let codecparPtr = bitmapTapCodecpars[inputIdx],
              let codec = avcodec_find_decoder(codecparPtr.pointee.codec_id) else { return nil }
        var codecCtx = avcodec_alloc_context3(codec)
        guard codecCtx != nil else { return nil }
        if avcodec_parameters_to_context(codecCtx, codecparPtr) < 0 {
            avcodec_free_context(&codecCtx)
            return nil
        }
        if codecCtx!.pointee.width == 0 { codecCtx!.pointee.width = bitmapTapFallbackCanvas.width }
        if codecCtx!.pointee.height == 0 { codecCtx!.pointee.height = bitmapTapFallbackCanvas.height }
        if avcodec_open2(codecCtx, codec, nil) < 0 {
            avcodec_free_context(&codecCtx)
            return nil
        }
        bitmapTapDecoders[inputIdx] = codecCtx
        cmpLog("[CMP-TAP] bitmap decoder opened stream=\(inputIdx)")
        return codecCtx
    }

    /// Convert one decoded bitmap rect into an overlay cue: paletted plane
    /// → premultiplied RGBA (cropped to the opaque bounding box) → CGImage
    /// positioned as a normalized rect against the subtitle canvas.
    /// (Mirrors the extractor's conversion; the tap has no
    /// OpenedSubtitleDecoder so canvas fallback is passed explicitly.)
    private static func bitmapTapCue(
        from rect: AVSubtitleRect,
        codecCtx: UnsafeMutablePointer<AVCodecContext>,
        fallbackCanvas: (width: Int32, height: Int32),
        startSeconds: Double,
        endSeconds: Double
    ) -> BitmapSubtitleCue? {
        guard rect.w > 0, rect.h > 0,
              let indexPlane = rect.data.0,
              let palette = rect.data.1
        else { return nil }
        guard let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexPlane: indexPlane,
            width: Int(rect.w),
            height: Int(rect.h),
            stride: Int(rect.linesize.0),
            palette: palette
        ), let image = BitmapSubtitlePalette.makeImage(from: plane) else { return nil }

        let ctx = codecCtx.pointee
        let canvasWidth = ctx.width > 0 ? ctx.width : fallbackCanvas.width
        let canvasHeight = ctx.height > 0 ? ctx.height : fallbackCanvas.height
        let normalizedFrame: CGRect
        if canvasWidth > 0, canvasHeight > 0 {
            normalizedFrame = CGRect(
                x: Double(Int(rect.x) + plane.cropX) / Double(canvasWidth),
                y: Double(Int(rect.y) + plane.cropY) / Double(canvasHeight),
                width: Double(plane.cropWidth) / Double(canvasWidth),
                height: Double(plane.cropHeight) / Double(canvasHeight)
            )
        } else {
            normalizedFrame = CGRect(x: 0.2, y: 0.78, width: 0.6, height: 0.15)
        }
        return BitmapSubtitleCue(
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            image: image,
            normalizedFrame: normalizedFrame
        )
    }

    /// Input stream indices of bitmap subtitle codecs (PGS/DVD) the tap
    /// can decode on demand. DVB is excluded, matching the extractor.
    private static func bitmapSubtitleStreamIndices(
        in ctx: UnsafeMutablePointer<AVFormatContext>
    ) -> Set<Int> {
        var indices: Set<Int> = []
        guard let streams = ctx.pointee.streams else { return indices }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let codecID = codecpar.pointee.codec_id
            if codecID == AV_CODEC_ID_HDMV_PGS_SUBTITLE
                || codecID == AV_CODEC_ID_DVD_SUBTITLE {
                indices.insert(i)
            }
        }
        return indices
    }

    /// Input stream indices of text subtitle codecs the tap can decode.
    /// Bitmap codecs (PGS/DVD) go through the on-demand bitmap tap above —
    /// their RGBA cues have real memory weight, so they are decoded only
    /// while selected instead of harvested into a persistent store.
    private static func textSubtitleStreamIndices(
        in ctx: UnsafeMutablePointer<AVFormatContext>
    ) -> Set<Int> {
        var indices: Set<Int> = []
        guard let streams = ctx.pointee.streams else { return indices }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let codecID = codecpar.pointee.codec_id
            if codecID == AV_CODEC_ID_ASS
                || codecID == AV_CODEC_ID_SSA
                || codecID == AV_CODEC_ID_SUBRIP
                || codecID == AV_CODEC_ID_WEBVTT
                || codecID == AV_CODEC_ID_MOV_TEXT {
                indices.insert(i)
            }
        }
        return indices
    }

    private static func resolveSelectedVideoStreamIndex(
        in ctx: UnsafeMutablePointer<AVFormatContext>,
        videoMode: LoopbackSessionSpec.VideoMode,
        videoOutputMode: LoopbackSessionSpec.VideoOutputMode
    ) throws -> Int {
        // The copy path keeps its historical two-codec allowlist: only HEVC
        // and H.264 bitstreams are known to remux cleanly into the fMP4
        // AVPlayer consumes. Bridged and AV1-passthrough sessions instead
        // accept whatever video stream the container carries — the decoder
        // (or, for AV1, the device) is what decides whether it is playable,
        // and that was already settled by the planner.
        let preferredCodec: AVCodecID? = switch videoOutputMode {
        case .passthroughAV1:
            AV_CODEC_ID_AV1
        case .transcodeHEVC, .transcodeH264:
            nil
        case .copy:
            switch videoMode {
            case .passthroughH264: AV_CODEC_ID_H264
            case .convertProfile7To81, .passthroughProfile8, .passthroughProfile5, .passthroughHEVC:
                AV_CODEC_ID_HEVC
            }
        }
        let restrictToCopyCodecs = videoOutputMode == .copy

        let nb = Int(ctx.pointee.nb_streams)
        var fallbackIndex: Int?
        var selectedLog = "none"
        if let streams = ctx.pointee.streams {
            for i in 0..<nb {
                guard let stream = streams[i], let codecpar = stream.pointee.codecpar else { continue }
                guard codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
                // Cover art in MKV/AVI is a video stream with a single
                // attached picture; muxing it as the presentation track would
                // produce a one-frame movie.
                guard (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0 else { continue }
                let codecID = codecpar.pointee.codec_id
                if restrictToCopyCodecs {
                    guard codecID == AV_CODEC_ID_HEVC || codecID == AV_CODEC_ID_H264 else { continue }
                }
                if fallbackIndex == nil {
                    fallbackIndex = i
                }
                if let preferredCodec, codecID == preferredCodec {
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

        throw LoopbackWriterError.noStreams
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
        try seekInput(ctx, toSeconds: sourceStartTimeSeconds)
    }

    private func seekInput(
        _ ctx: UnsafeMutablePointer<AVFormatContext>,
        toSeconds seconds: Double
    ) throws {
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
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
                "[CMP-AVP] loopback source seek failed requested=\(seconds, privacy: .public) rc=\(result, privacy: .public)"
            )
            throw LoopbackWriterError.seekInput(result)
        }

        avformat_flush(ctx)
        cmpLog("[CMP-AVP] loopback source seek requested=\(seconds) rc=\(result)")
    }

    /// Custom AVIOContext so the mp4 muxer's writes flow back into Swift
    /// where we can parse and split them into segment files.
    private func openOutput() throws {
        guard let inCtx = inputCtx else {
            throw LoopbackWriterError.allocOutput
        }
        selectedAudioStreamIndex = shouldIncludeAudio
            ? try resolveSelectedAudioStreamIndex(in: inCtx)
            : -1

        let bufSize = 64 * 1024
        guard let buf = av_malloc(bufSize)?.assumingMemoryBound(to: UInt8.self) else {
            throw LoopbackWriterError.allocOutput
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
                let writer = Unmanaged<LoopbackSegmentWriter>.fromOpaque(opaque).takeUnretainedValue()
                let slice = UnsafeBufferPointer(start: bufPtr, count: Int(bufSize))
                if LoopbackSegmentWriter.traceThroughput {
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
            throw LoopbackWriterError.allocOutput
        }
        ioContext = avio

        var out: UnsafeMutablePointer<AVFormatContext>?
        let rc = avformat_alloc_output_context2(&out, nil, "mp4", nil)
        if rc < 0 || out == nil {
            throw LoopbackWriterError.allocOutput
        }
        out!.pointee.pb = avio
        outputCtx = out

        // Copy streams. For each source stream, allocate an output stream,
        // copy its codecpar, then patch codec_tag for AVPlayer consumption:
        // `dvh1` for Dolby Vision, `hvc1` for plain HEVC HDR/SDR, or `avc1`
        // for H.264 passthrough.
        guard let outCtx = outputCtx else {
            throw LoopbackWriterError.allocOutput
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
                throw LoopbackWriterError.allocOutput
            }

            if mediaType == AVMEDIA_TYPE_VIDEO, videoOutputMode.isBridged {
                // Bridged: the output codecpar comes from the ENCODER, never
                // from the source, exactly like the audio bridge's arm below.
                // Dimensions and time base still come from the source — the
                // bridge never rescales and keeps the source clock, so every
                // downstream timestamp path stays the copy path's.
                masterVideoWidth = codecpar.pointee.width
                masterVideoHeight = codecpar.pointee.height
                videoInputStreamIndex = i
                try openVideoTranscodePipeline(inputStream: inStream, outputStream: outStream)
            } else if mediaType == AVMEDIA_TYPE_VIDEO {
                if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) < 0 {
                    throw LoopbackWriterError.allocOutput
                }
                masterVideoWidth = codecpar.pointee.width
                masterVideoHeight = codecpar.pointee.height
                outStream.pointee.time_base = inStream.pointee.time_base
                outStream.pointee.codecpar.pointee.codec_tag = 0
                let dovi = outputDoviConfig(from: readDoviConfig(codecpar: codecpar))
                let removedDoviSideData = removeDoviSideData(codecpar: outStream.pointee.codecpar)
                // `.passthroughAV1` overrides the `VideoMode`-derived fourcc
                // with `av01`; every other copy mode defers to `VideoMode`,
                // which owns the Dolby Vision `dvh1` distinction.
                outStream.pointee.codecpar.pointee.codec_tag = sampleEntryTag(
                    for: videoOutputMode.sampleEntryCodec ?? videoMode.sampleEntryCodec
                )
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
                try requireUsableProfile5Record()
                let codecTag = videoMode.sampleEntryCodec
                let doviLog = dovi.flatMap(parseDoviRecord(from:))?.logLine ?? "none"
                cmpLog("[CMP-AVP] out video codecpar tag=\(codecTag) initial extradataSize=\(edSize) nalLen=\(nalLengthSize) videoMode=\(videoMode.logToken) dovi=\(doviLog) removedDoviSideData=\(removedDoviSideData)")
            } else if selectedAudioOutputMode == .copy {
                if !audioCodecSupportsMp4Mux(codecpar.pointee.codec_id) {
                    let codecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
                    throw LoopbackWriterError.unsupportedSelectedAudioCodec(codecName)
                }
                if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) < 0 {
                    throw LoopbackWriterError.allocOutput
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
                vodAudioNeedsParsedPacketForMoov =
                    Self.audioCodecNeedsParsedPacketForMoov(codecpar.pointee.codec_id)
                // AV_PROFILE_EAC3_DDP_ATMOS (= 30): the eac3 decoder sets it
                // during probing when the E-AC-3 bitstream carries a JOC
                // (Atmos) extension. The vendored FFmpeg 7.1 muxer writes no
                // dec3 JOC extension of its own, so writeInitSegment patches
                // one in — without it AVFoundation classifies the track as
                // plain E-AC-3 and Atmos never engages.
                selectedAudioIsAtmosJOC = codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                    && codecpar.pointee.profile == 30
                let codecName = outputAudioCodecToken ?? String(cString: avcodec_get_name(codecpar.pointee.codec_id))
                cmpLog("[CMP-AVP] selected audio copy sourceStream=\(i) codec=\(codecName) channels=\(codecpar.pointee.ch_layout.nb_channels) atmosJOC=\(selectedAudioIsAtmosJOC ? 1 : 0)")
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
            throw LoopbackWriterError.noStreams
        }

        if shouldIncludeAudio {
            Self.logger.info(
                "[CMP-AVP] selected audio trackIndex=\(self.selectedAudioTrackIndex, privacy: .public) resolvedStreamIndex=\(self.selectedAudioStreamIndex, privacy: .public) codec=\(self.sessionSpec.selectedAudio.sourceCodec ?? "unknown", privacy: .public)"
            )
        } else {
            cmpLog("[CMP-AVP] no selected audio stream; emitting video-only loopback")
        }
    }

    private func resolveSelectedAudioStreamIndex(
        in inputCtx: UnsafeMutablePointer<AVFormatContext>
    ) throws -> Int {
        guard let index = Self.audioStreamIndex(
            in: inputCtx,
            ffIndex: sessionSpec.selectedAudio.ffIndex,
            ordinal: selectedAudioTrackIndex
        ) else {
            throw LoopbackWriterError.audioTranscodeSetup(
                "selected audio track \(selectedAudioTrackIndex) was not found in source stream map"
            )
        }
        return index
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
            do {
                if inIdx == videoInputStreamIndex {
                    try routeVideoPacketToMux(
                        pending,
                        outStreamIndex: Int32(outIdx),
                        inputStreamIndex: inIdx
                    )
                    try replayVODPreGateAudioPacketsIfNeeded()
                } else {
                    rewritePacketForOutput(
                        pkt: pending,
                        outStreamIndex: Int32(outIdx),
                        inputStreamIndex: inIdx
                    )
                    try writePacketToMux(pending)
                }
            } catch {
                Self.logger.error("pending \(label, privacy: .public) write failed")
                throw error
            }
        }
    }

    /// Rewrites and holds one video packet until the next normalized video
    /// DTS is known. The previous packet is written before the current
    /// sample's keyframe cut, keeping it in its original segment.
    private func routeVideoPacketToMux(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        outStreamIndex: Int32,
        inputStreamIndex: Int
    ) throws {
        openBridgedRestartGateIfNeeded(pkt)
        let sourcePTS = pkt.pointee.pts
        let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
        rewritePacketForOutput(
            pkt: pkt,
            outStreamIndex: outStreamIndex,
            inputStreamIndex: inputStreamIndex
        )

        try flushPendingMuxVideoPacket(nextDTS: pkt.pointee.dts)
        try vodCutBeforeVideoPacketIfNeeded(sourcePTS: sourcePTS, isKeyframe: isKeyframe)

        guard let held = av_packet_clone(pkt) else {
            throw LoopbackWriterError.allocPacket
        }
        pendingMuxVideoPacket = held
    }

    private func flushPendingMuxVideoPacket(nextDTS: Int64?) throws {
        guard let pending = pendingMuxVideoPacket else { return }
        pendingMuxVideoPacket = nil
        defer {
            var free: UnsafeMutablePointer<AVPacket>? = pending
            av_packet_free(&free)
        }

        let streamIndex = pending.pointee.stream_index
        let fallback = lastResolvedVideoDurationByStream[streamIndex] ?? 1
        let resolved = LoopbackVideoSampleDurationPolicy.resolve(
            existingDuration: pending.pointee.duration,
            dts: pending.pointee.dts,
            nextDTS: nextDTS,
            fallback: fallback
        )
        pending.pointee.duration = resolved
        lastResolvedVideoDurationByStream[streamIndex] = resolved
        try writePacketToMuxImmediately(pending, performPostWriteActions: false)
        try flushPendingMuxAudioPackets(performPostWriteActions: false)
        try performMuxPostWriteActions()
    }

    private func writePacketToMux(_ pkt: UnsafeMutablePointer<AVPacket>) throws {
        if pendingMuxVideoPacket != nil {
            guard let held = av_packet_clone(pkt) else {
                throw LoopbackWriterError.allocPacket
            }
            pendingMuxAudioPackets.append(held)
            return
        }
        try writePacketToMuxImmediately(pkt)
    }

    private func flushPendingMuxAudioPackets(performPostWriteActions: Bool) throws {
        while !pendingMuxAudioPackets.isEmpty {
            let pending = pendingMuxAudioPackets.removeFirst()
            defer {
                var free: UnsafeMutablePointer<AVPacket>? = pending
                av_packet_free(&free)
            }
            try writePacketToMuxImmediately(
                pending,
                performPostWriteActions: performPostWriteActions
            )
        }
    }

    private func writePacketToMuxImmediately(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        performPostWriteActions: Bool = true
    ) throws {
        guard let outputCtx else { return }
        let wr: Int32
        if Self.traceThroughput {
            let started = CFAbsoluteTimeGetCurrent()
            wr = av_interleaved_write_frame(outputCtx, pkt)
            throughputTiming.muxMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
            throughputTiming.muxPackets += 1
        } else {
            wr = av_interleaved_write_frame(outputCtx, pkt)
        }
        try evaluateMuxWriteResult(wr)
        if performPostWriteActions {
            try performMuxPostWriteActions()
        }
    }

    private func performMuxPostWriteActions() throws {
        if vodActive, !initSegmentWritten {
            try primeVODMoovAfterFirstAudioIfNeeded()
        }
        if vodInterimFlushRequested {
            vodInterimFlushRequested = false
            performVODInterimFragmentFlush()
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
        var firstVideoPacketNALSummary = "none"
        var repairedKeyframeFlags = 0
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
            let rc = deadlineBoundedReadFrame(inCtx, readPkt)
            if rc < 0 {
                var free = readPkt
                av_packet_free(&free)
                break
            }
            emitSourceDownloadStatsIfNeeded()
            guard let pkt = readPkt else { break }
            totalPacketsRead += 1
            let inIdx = Int(pkt.pointee.stream_index)

            // Tap subtitle packets seen during bootstrap too (cues near the
            // anchor). Checked before the DTS guard — subtitle packets
            // legitimately carry PTS with no DTS.
            if subtitleTapDecoders[inIdx] != nil {
                tapDecodeSubtitlePacket(pkt: pkt, inputIdx: inIdx)
                var free = readPkt
                av_packet_free(&free)
                continue
            }
            if bitmapTapTimeBases[inIdx] != nil {
                tapHandleBitmapSubtitlePacket(pkt: pkt, inputIdx: inIdx)
                var free = readPkt
                av_packet_free(&free)
                continue
            }

            // Packets without a PTS are unusable. A video packet with PTS
            // but no DTS still reaches keyframe detection below — MKV/HEVC
            // sources expose the head keyframe that way, and the stash path
            // repairs its DTS exactly like the main loop does.
            if pkt.pointee.pts == avNoPTS
                || (pkt.pointee.dts == avNoPTS && inIdx != videoInputStreamIndex) {
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

            if shouldDropCorruptHEVCVideoPacket(pkt) {
                var free = readPkt
                av_packet_free(&free)
                droppedPreVideoPackets += 1
                continue
            }

            videoPacketsRead += 1
            if videoPacketsRead == 1, let dataPtr = pkt.pointee.data {
                firstVideoPacketNALSummary = ISOBoxSurgery.nalSummary(
                    packetBytes: UnsafeBufferPointer(start: dataPtr,
                                                     count: Int(pkt.pointee.size)),
                    nalLengthSize: nalLengthSize
                )
            }
            var isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
            if !isKeyframe, let dataPtr = pkt.pointee.data {
                // The matroska demuxer delivers the head-of-stream IRAP
                // without AV_PKT_FLAG_KEY, so a flag-gated scan skips all of
                // GOP 0 (a silent one-GOP video hole) — and when the GOP
                // outruns the packet caps it gives up entirely, muxing a
                // mid-GOP timeline whose tfdt no longer matches the playlist.
                // AVPlayer then freezes its fetches and the startup watchdog
                // burns ~15s before the Compatibility fallback (living-room
                // Ali Wong stall). The bitstream is authoritative: any VCL
                // IRAP NAL is a valid fragment opener, so repair the flag.
                let packetBytes = UnsafeBufferPointer(start: dataPtr,
                                                      count: Int(pkt.pointee.size))
                if let irapType = ISOBoxSurgery.firstIRAPNALType(
                    packetBytes: packetBytes,
                    nalLengthSize: nalLengthSize
                ) {
                    pkt.pointee.flags |= AV_PKT_FLAG_KEY
                    isKeyframe = true
                    repairedKeyframeFlags += 1
                    if repairedKeyframeFlags <= 3 {
                        cmpLog("[CMP-AVP] bootstrap keyframe flag repaired via NAL scan type=\(irapType) pts=\(pkt.pointee.pts)")
                    }
                }
            }
            guard isKeyframe else {
                var free = readPkt
                av_packet_free(&free)
                droppedPreVideoPackets += 1
                continue
            }
            if pkt.pointee.dts == avNoPTS,
               !repairMissingMuxerTimestampsIfNeeded(
                   pkt: pkt,
                   inputStreamIndex: inIdx,
                   noPTS: avNoPTS
               ) {
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
            cmpLog("[CMP-AVP] bootstrap gave up: vps=\(vps.count) sps=\(sps.count) pps=\(pps.count) videoPackets=\(videoPacketsRead) totalPackets=\(totalPacketsRead) droppedPreVideo=\(droppedPreVideoPackets) retainedAudio=\(pendingAudioPackets.count) retainedAudioBytes=\(retainedPreVideoAudioBytes) droppedPreVideoAudio=\(droppedPreVideoAudioPackets) trueHDSyncFound=\(syncFound ? 1 : 0) firstVideoNALs=\(firstVideoPacketNALSummary)")
            // Muxing from here would start mid-GOP with a tfdt the playlist
            // doesn't expect: AVPlayer freezes its fetches and the startup
            // watchdog spends ~15s before falling back. Fail the session now
            // so the route falls back immediately instead.
            throw LoopbackWriterError.bootstrapFailed(
                "no IRAP keyframe in \(videoPacketsRead) video packets (firstVideoNALs=\(firstVideoPacketNALSummary))"
            )
        }

        if !vps.isEmpty, !sps.isEmpty, !pps.isEmpty {
            let hvcc = ISOBoxSurgery.buildHvcC(header: header, vps: vps, sps: sps, pps: pps)
            setExtradata(codecpar: outStream.pointee.codecpar, data: hvcc)
            inputHvccHeader = hvcc
        } else if !headerHasParameterSets {
            // Without parameter sets in hvcC or in-band, the sample entry is
            // undecodable — same fetch-freeze endgame as the mid-GOP start.
            cmpLog("[CMP-AVP] bootstrap keyframe found but no VPS/SPS/PPS available in packet or hvcC")
            throw LoopbackWriterError.bootstrapFailed(
                "keyframe found but no VPS/SPS/PPS in packet or hvcC"
            )
        }
        if let inStream = inCtx.pointee.streams?[videoInputStreamIndex] {
            doviConfig = outputDoviConfig(from: readDoviConfig(codecpar: inStream.pointee.codecpar))
            doviRecord = doviConfig.flatMap(parseDoviRecord(from:))
        }
        let doviLog = doviRecord?.logLine ?? "none"
        let syncFound = isSelectedAudioTrueHD()
            ? firstMLPMajorSyncIndex(in: pendingAudioPackets) != nil
            : false
        cmpLog("[CMP-AVP] bootstrap OK: hvcCParams=\(headerHasParameterSets ? 1 : 0) vps=\(vps.count) sps=\(sps.count) pps=\(pps.count) videoPackets=\(videoPacketsRead) totalPackets=\(totalPacketsRead) droppedPreVideo=\(droppedPreVideoPackets) pendingVideo=\(pendingVideoPackets.count) retainedAudio=\(pendingAudioPackets.count) retainedAudioBytes=\(retainedPreVideoAudioBytes) droppedPreVideoAudio=\(droppedPreVideoAudioPackets) trueHDSyncFound=\(syncFound ? 1 : 0) repairedKeyFlags=\(repairedKeyframeFlags) firstVideoNALs=\(firstKeyframeNALSummary) dovi=\(doviLog)")
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

    /// Profile 5 is the one mode whose Dolby Vision signalling has no
    /// fallback: the base layer is IPT-PQ-c2, so a `dvh1` sample entry
    /// without a `dvcC` renders as garbage rather than as a lesser dynamic
    /// range, and the CODECS token cannot repair it (Dolby derives both the
    /// playlist profile and level from the configuration box, and its level
    /// IDs start at 1 — there is no `dvh1.05.00` to fall back on). A source
    /// whose DOVI record the demuxer never surfaced, or surfaced malformed,
    /// therefore fails the session here so the route ladder falls back
    /// immediately instead of publishing an unplayable presentation.
    private func requireUsableProfile5Record() throws {
        guard videoMode == .passthroughProfile5 else { return }
        guard let record = doviRecord else {
            throw LoopbackWriterError.profile5ConfigUnusable("no DOVI configuration record on the video track")
        }
        guard record.profile == 5 else {
            throw LoopbackWriterError.profile5ConfigUnusable("record declares profile \(record.profile), not 5")
        }
        guard record.level > 0 else {
            throw LoopbackWriterError.profile5ConfigUnusable("record declares level 0")
        }
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
        if videoOutputMode.isBridged {
            // CODECS must describe the ENCODER's output, not the source's:
            // the bridged bitstream is what AVPlayer's variant filter has to
            // claim. Both builders already take the header as a parameter, so
            // this is a straight substitution of the bridged record.
            let header = videoBridge?.codecStringHeader ?? bridgedVideoExtradata
            return videoOutputMode == .transcodeH264
                ? (h264RFC6381CodecString(avccHeader: header) ?? sampleEntry)
                : (hevcRFC6381CodecString(sampleEntry: sampleEntry, hvccHeader: header) ?? sampleEntry)
        }
        if videoOutputMode == .passthroughAV1 {
            return av1RFC6381CodecString() ?? sampleEntry
        }
        if videoMode == .passthroughH264 {
            return h264RFC6381CodecString(avccHeader: inputAvccHeader) ?? sampleEntry
        }
        // Profile 5 advertises Dolby Vision in CODECS itself, so it needs the
        // Dolby form. Running it through the HEVC builder produces a `dvh1`
        // fourcc glued to HEVC profile/level fields — the `dvh1.2.4.L150`
        // shape AVPlayer rejects with -15517 — so the HEVC path below must
        // never see a `dvh1` sample entry. The Dolby form is always available
        // here: a P5 session without a usable record never reaches the mux
        // (`requireUsableProfile5Record`), so the `hvc1` arm is inert.
        if videoMode == .passthroughProfile5 {
            return dolbyVisionRFC6381CodecString() ?? "hvc1"
        }
        return hevcRFC6381CodecString(sampleEntry: sampleEntry, hvccHeader: inputHvccHeader)
            ?? sampleEntry
    }

    /// Dolby Vision RFC 6381 form, `dvh1.<profile>.<level>` with both fields
    /// zero-padded to two digits. The one builder behind both CODECS
    /// (Profile 5) and SUPPLEMENTAL-CODECS (Profiles 7 and 8, which append a
    /// compatibility brand), so the two fields AVPlayer cross-validates
    /// cannot name different profiles for the same stream.
    private static func dolbyVisionRFC6381CodecString(profile: Int, level: Int) -> String {
        String(format: "dvh1.%02d.%02d", profile, level)
    }

    /// Nil when either field is unknown. Dolby derives the playlist profile
    /// and level from the configuration box, and its published level IDs
    /// begin at 01 — so a missing record cannot be papered over with a zero
    /// level. Omitting the token entirely leaves the caller on its HEVC
    /// fallback (Profile 8's base layer is viewable without the
    /// SUPPLEMENTAL-CODECS claim); Profile 5 never gets this far, because
    /// `requireUsableProfile5Record` fails the session at mux setup.
    private func dolbyVisionRFC6381CodecString() -> String? {
        guard let profile = outputDolbyVisionProfile,
              let level = doviRecord.map({ Int($0.level) }),
              level > 0 else {
            return nil
        }
        return Self.dolbyVisionRFC6381CodecString(profile: profile, level: level)
    }

    /// The Dolby Vision profile the written segments actually carry, which is
    /// not always the source's: `convertProfile7To81` rewrites the `dvcC` to
    /// Profile 8.1, so the parsed record's 7 would misdescribe the output.
    /// The planner derives `advertisedDolbyVisionProfile` from the same
    /// `videoMode` that selects what gets written, so it leads; the parsed
    /// record covers callers that build a spec without it. A source whose
    /// DOVI side data the demuxer never surfaced — `parseDoviRecord` also
    /// rejects records under 8 bytes — leaves only the advertised value.
    private var outputDolbyVisionProfile: Int? {
        switch videoMode {
        case .convertProfile7To81:
            // `derivedProfile81DoviConfig` stamps 8 into the written record.
            return 8
        case .passthroughProfile5, .passthroughProfile8:
            return manifestMetadata.advertisedDolbyVisionProfile
                ?? doviRecord.map { Int($0.profile) }
        case .passthroughHEVC, .passthroughH264:
            return nil
        }
    }

    /// `av01.<profile>.<level><tier>.<depth>` from the source's `av1C` record
    /// (ISO/IEC 23091, AV1-ISOBMFF §5). Byte 1 packs seq_profile in the top 3
    /// bits and seq_level_idx in the low 5; byte 2's top bit is the tier and
    /// the next two encode bit depth.
    private func av1RFC6381CodecString() -> String? {
        guard let inCtx = inputCtx,
              videoInputStreamIndex >= 0,
              let stream = inCtx.pointee.streams?[videoInputStreamIndex],
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.extradata_size >= 4,
              let extradata = codecpar.pointee.extradata else {
            return nil
        }
        let profile = Int((extradata[1] & 0xE0) >> 5)
        let level = Int(extradata[1] & 0x1F)
        let tier = (extradata[2] & 0x80) != 0 ? "H" : "M"
        let highBitDepth = (extradata[2] & 0x40) != 0
        let twelveBit = (extradata[2] & 0x20) != 0
        let depth = twelveBit ? 12 : (highBitDepth ? 10 : 8)
        return String(format: "av01.%d.%02d%@.%02d", profile, level, tier, depth)
    }

    private func masterManifestSampleEntryCodec() -> String {
        if let bridged = videoOutputMode.sampleEntryCodec {
            return bridged
        }
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

        // Always declare Main tier ('L') and omit the constraint suffix,
        // whatever the stream's actual tier flag says. AVPlayer's
        // master-level codec filter silently drops variants whose CODECS it
        // won't claim — a faithful "hvc1.2.4.H150.B0" (High tier, device
        // stream) was rejected with NSURLErrorDomain -1002 before the
        // variant playlist was ever fetched, while the lenient Main-tier
        // declaration is accepted everywhere (AetherEngine likewise always
        // declares L and never a constraint suffix). The declaration only
        // feeds variant selection; the bitstream is untouched.
        _ = tierFlag
        _ = constraintString
        return "\(sampleEntry).\(profileSpacePrefix)\(profileIDC).\(compatibilityString).L\(levelIDC)"
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
        guard emitsSupplemental, let token = dolbyVisionRFC6381CodecString() else {
            return nil
        }
        let compat = manifestMetadata.compatibilityBrand ?? "db1p"
        return "\(token)/\(compat)"
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
            cmpLog("[CMP-AVP] profile7_to81_base_layer hvcC filtered for profile8.1 arrays \(declaredArrayCount)->\(keptArrayCount) removedNALs=\(removedNALCount)")
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

    // MARK: - Video bridge

    /// Builds the decode → encode pair for a bridged video track and fills the
    /// already-allocated output stream from the encoder. Mirrors
    /// `openAudioTranscodePipeline`: the output stream exists (the generic
    /// `avformat_new_stream` above created it), this only populates it.
    private func openVideoTranscodePipeline(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>
    ) throws {
        let bridge = LoopbackVideoBridge(
            outputMode: videoOutputMode,
            targetSegmentDuration: targetSegmentDuration,
            sourceBitrateBps: sessionSpec.sourceBitrateBps,
            declaredFrameRate: sessionSpec.sourceVideoFrameRate
        )
        try bridge.open(
            inputStream: inputStream,
            outputStream: outputStream,
            outputFormat: outputCtx?.pointee.oformat
        )
        videoBridge = bridge
        outputStream.pointee.codecpar.pointee.codec_tag = sampleEntryTag(for: bridge.sampleEntryCodec)
        // VideoToolbox emits AVCC-style NALs with 4-byte length prefixes,
        // which is what every length-prefixed walker in this file assumes.
        nalLengthSize = 4
        try installBridgedVideoParameterSets(on: outputStream)
    }

    /// Installs the bridged parameter sets on the output codecpar. A restart
    /// installs the FIRST session's record (carried on the spec) and asserts
    /// its own encoder produced the same bytes; a mismatch fails the session
    /// rather than publishing segments the item's `init.mp4` cannot decode.
    @discardableResult
    private func installBridgedVideoParameterSets(
        on outStream: UnsafeMutablePointer<AVStream>
    ) throws -> Bool {
        guard let bridge = videoBridge else { return false }
        if let carried = sessionSpec.bridgedVideoParameterSets, !carried.isEmpty {
            if let fresh = bridge.parameterSets, fresh != carried {
                throw LoopbackWriterError.videoTranscodeSetup(
                    "bridged video parameter sets drifted across producer restart"
                    + " (carried=\(carried.count)B fresh=\(fresh.count)B)"
                )
            }
            bridgedVideoExtradata = carried
            setExtradata(codecpar: outStream.pointee.codecpar, data: carried)
            return true
        }
        guard let fresh = bridge.parameterSets, !fresh.isEmpty else { return false }
        bridgedVideoExtradata = fresh
        setExtradata(codecpar: outStream.pointee.codecpar, data: fresh)
        onBridgedVideoParameterSetsResolved?(fresh)
        return true
    }

    /// Hands the plan's segment fences to the bridge so encoder keyframes land
    /// exactly on them, plus the restart threshold below which frames are
    /// decoded for reference but never encoded.
    private func installBridgedVideoPlanIfNeeded() {
        guard let bridge = videoBridge else { return }
        guard vodActive, let plan = vodPlan, plan.segmentCount > 0 else {
            // EVENT sessions have no plan; the bridge synthesizes a uniform
            // keyframe stride so `+frag_keyframe` still cuts on cadence.
            bridge.installPlan(boundaries: [], emitThresholdPTS: nil)
            return
        }
        let base = min(max(0, vodEffectiveBaseIndex), plan.segmentCount - 1)
        bridge.installPlan(
            boundaries: Array(plan.boundaries[base...]),
            emitThresholdPTS: base > 0 ? plan.boundaries[base] : nil
        )
    }

    /// Pre-mux priming for a bridged session whose encoder did not publish
    /// parameter sets at open. Reads source packets, encodes them into
    /// `pendingVideoPackets` (replayed by the existing `flushPendingPackets`
    /// after `writeHeader`) and stops as soon as the record appears. This is
    /// the bridged twin of `bootstrapVideoExtradata`'s contract.
    private func primeBridgedVideoExtradataIfNeeded() throws {
        guard videoOutputMode.isBridged, bridgedVideoExtradata == nil else { return }
        guard let inCtx = inputCtx,
              let outCtx = outputCtx,
              let bridge = videoBridge,
              let videoOutIdx = streamMap[videoInputStreamIndex],
              let outStream = outCtx.pointee.streams?[videoOutIdx] else {
            throw LoopbackWriterError.videoTranscodeSetup("bridged video priming has no output stream")
        }

        let maxPackets = 8_000
        let maxVideoPackets = 128
        var totalPacketsRead = 0
        var videoPacketsRead = 0
        let keepSelectedAudioPreroll = shouldIncludeAudio && selectedAudioOutputMode != .copy
        var retainedPreVideoAudioBytes = 0
        var droppedPreVideoAudioPackets = 0

        while !isCancelled,
              bridge.parameterSets == nil,
              totalPacketsRead < maxPackets,
              videoPacketsRead < maxVideoPackets {
            let readPkt = av_packet_alloc()
            let rc = deadlineBoundedReadFrame(inCtx, readPkt)
            if rc < 0 {
                var free = readPkt
                av_packet_free(&free)
                break
            }
            emitSourceDownloadStatsIfNeeded()
            guard let pkt = readPkt else { break }
            totalPacketsRead += 1
            let inIdx = Int(pkt.pointee.stream_index)

            if subtitleTapDecoders[inIdx] != nil {
                tapDecodeSubtitlePacket(pkt: pkt, inputIdx: inIdx)
                var free = readPkt
                av_packet_free(&free)
                continue
            }
            if bitmapTapTimeBases[inIdx] != nil {
                tapHandleBitmapSubtitlePacket(pkt: pkt, inputIdx: inIdx)
                var free = readPkt
                av_packet_free(&free)
                continue
            }
            if inIdx != videoInputStreamIndex {
                if keepSelectedAudioPreroll, inIdx == selectedAudioStreamIndex {
                    retainPreVideoAudioPacket(
                        pkt,
                        maxPackets: DVPreVideoAudioTailPolicy.maxPackets,
                        maxBytes: DVPreVideoAudioTailPolicy.maxBytes,
                        retainedBytes: &retainedPreVideoAudioBytes,
                        droppedPackets: &droppedPreVideoAudioPackets
                    )
                } else {
                    var free = readPkt
                    av_packet_free(&free)
                }
                continue
            }

            videoPacketsRead += 1
            try bridge.transcodePacket(pkt, inputStreamIndex: videoInputStreamIndex) { encoded in
                guard let held = av_packet_clone(encoded) else {
                    throw LoopbackWriterError.allocPacket
                }
                pendingVideoPackets.append(held)
            }
            var free = readPkt
            av_packet_free(&free)
        }

        guard try installBridgedVideoParameterSets(on: outStream) else {
            throw LoopbackWriterError.videoTranscodeSetup(
                "video encoder produced no parameter sets after \(videoPacketsRead) source packets"
            )
        }
        cmpLog("[CMP-AVP] bridged video priming videoPackets=\(videoPacketsRead) totalPackets=\(totalPacketsRead) encoded=\(pendingVideoPackets.count) extradata=\(bridgedVideoExtradata?.count ?? 0)")
    }

    /// Mux-loop entry for a bridged video packet: decode, encode, and route
    /// every resulting packet through the ordinary copy-path plumbing.
    private func transcodeVideoPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>?,
        outStreamIndex: Int32
    ) throws {
        guard let bridge = videoBridge else { return }
        try bridge.transcodePacket(pkt, inputStreamIndex: videoInputStreamIndex) { [self] encoded in
            try routeVideoPacketToMux(
                encoded,
                outStreamIndex: outStreamIndex,
                inputStreamIndex: videoInputStreamIndex
            )
        }
    }

    /// Clean-EOF drain for the bridge. Runs before `finishTranscodedAudio` and
    /// before `flushPendingMuxVideoPacket(nextDTS: nil)` so the encoder's last
    /// GOP is routed while the look-behind can still telescope its duration.
    private func finishTranscodedVideo() throws {
        guard videoOutputMode.isBridged,
              let bridge = videoBridge,
              let outIdx = streamMap[videoInputStreamIndex] else { return }
        try bridge.finish(inputStreamIndex: videoInputStreamIndex) { [self] encoded in
            try routeVideoPacketToMux(
                encoded,
                outStreamIndex: Int32(outIdx),
                inputStreamIndex: videoInputStreamIndex
            )
        }
    }

    /// A bridged restart's video gate opens on the encoder's first emitted
    /// packet, not on a source keyframe: the input-side gate deliberately lets
    /// everything through so the decoder can warm up from the source keyframe
    /// preceding the anchor boundary.
    private func openBridgedRestartGateIfNeeded(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard vodActive, videoOutputMode.isBridged else { return }
        if vodAwaitingRestartKeyframe {
            vodAwaitingRestartKeyframe = false
            vodFirstRoutedVideoDts = pkt.pointee.dts
            cmpLog("[CMP-AVP] vod bridged restart gate opened at pts=\(pkt.pointee.pts) droppedAudio=\(vodPrerollDroppedAudio) segment=\(vodEffectiveBaseIndex)")
            return
        }
        if vodFirstRoutedVideoDts == nil {
            vodFirstRoutedVideoDts = pkt.pointee.dts
        }
    }

    private func openAudioTranscodePipeline(
        inputStream: UnsafeMutablePointer<AVStream>,
        inputStreamIndex: Int,
        outputStream: UnsafeMutablePointer<AVStream>
    ) throws {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw LoopbackWriterError.audioTranscodeSetup("audio decoder unavailable")
        }

        var decoderCtx = avcodec_alloc_context3(decoder)
        guard decoderCtx != nil else {
            throw LoopbackWriterError.audioTranscodeSetup("audio decoder alloc failed")
        }
        if avcodec_parameters_to_context(decoderCtx, codecpar) < 0 || avcodec_open2(decoderCtx, decoder, nil) < 0 {
            avcodec_free_context(&decoderCtx)
            throw LoopbackWriterError.audioTranscodeSetup("audio decoder open failed")
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

            // TrueHD/MLP may not expose a PCM format until a major-sync
            // frame decodes. The resampler is populated lazily below.
            let swr: OpaquePointer? = nil
            outputStream.pointee.time_base = encoderCtx!.pointee.time_base
            if avcodec_parameters_from_context(outputStream.pointee.codecpar, encoderCtx) < 0 {
                lastError = "codecpar from encoder failed \(candidate.codecToken)"
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
            vodSeededBridgedAudioPTS = false
            audioDecodedFrameCount = 0
            audioDecodeErrorCount = 0
            audioDecodeErrorTotal = 0
            bridgedDriftLastLoggedStep = 0
            bridgedDriftNextHeartbeatPTS = 0
            bridgedDriftRunAnchorPTS = -1
            bridgedDriftGovernor = LoopbackBridgedDriftGovernor()
            let sourceCodecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
            cmpLog("[CMP-AVP] selected audio transcode sourceStream=\(inputStreamIndex) sourceCodec=\(sourceCodecName) outputCodec=\(candidate.codecToken) sourceChannels=\(sourceChannels) outputChannels=\(targetChannels) preservesAtmos=\(sessionSpec.selectedAudio.preservesAtmos ? 1 : 0) mode=\(sessionSpec.selectedAudio.outputMode.preferredCodecToken)")
            opened = true
            break
        }

        if !opened {
            avcodec_free_context(&decoderCtx)
            throw LoopbackWriterError.audioTranscodeSetup(lastError)
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
                cmpLog("[CMP-AVP] primed audio decoder with \(primedCount) pre-video packets (skipped \(dropped) pre-major_sync, trueHDSyncFound=\(syncFound ? 1 : 0)) without muxing preroll")
            } else {
                cmpLog("[CMP-AVP] primed audio decoder with \(primedCount) pre-video packets (trueHDSyncFound=\(syncFound ? 1 : 0)) without muxing preroll")
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
        let decodedFrame = try reusableAudioDecodedFrame()
        while true {
            // avcodec_receive_frame unrefs the destination before filling
            // it, so one persistent frame serves every iteration — the
            // bridge decodes ~30-90 frames/s and per-frame alloc/free was
            // steady mux-thread churn.
            let recvR = avcodec_receive_frame(decoderCtx, decodedFrame)
            if recvR == avErrorAgain || recvR == avErrorEOF {
                return
            }
            if recvR < 0 {
                noteAudioDecodeError(stage: "receive", rc: recvR)
                return
            }
            audioDecodeErrorCount = 0
            audioDecodedFrameCount += 1
            if emitDecodedFrames {
                try sendConvertedFrameToEncoder(decodedFrame)
            }
            av_frame_unref(decodedFrame)
        }
    }

    private func reusableAudioDecodedFrame() throws -> UnsafeMutablePointer<AVFrame> {
        if let frame = audioDecodedFrame { return frame }
        guard let frame = av_frame_alloc() else {
            throw LoopbackWriterError.allocOutput
        }
        audioDecodedFrame = frame
        return frame
    }

    /// VOD: anchor the bridged-audio encoder clock to the session timeline
    /// before the first emitted frame's samples are stamped. Remuxed video
    /// packets get `applyVODAnchorShift` (source pts − plan.boundaries[0]);
    /// the re-encoded audio track must start from the same axis or AVPlayer
    /// sees disjoint track timelines on a mid-title resume and never reaches
    /// readyToPlay. Priming frames never reach the encoder
    /// (`emitDecodedFrames: false`), so the first frame seen here is the
    /// first muxed-bound one — its source timestamp IS the audio anchor.
    /// Frames without a usable timestamp defer seeding to the next frame.
    private func seedVODBridgedAudioPTSIfNeeded(
        from decodedFrame: UnsafeMutablePointer<AVFrame>,
        encoderCtx: UnsafeMutablePointer<AVCodecContext>
    ) {
        guard vodActive, !vodSeededBridgedAudioPTS else { return }
        guard let inCtx = inputCtx,
              selectedAudioStreamIndex >= 0,
              selectedAudioStreamIndex < Int(inCtx.pointee.nb_streams),
              let stream = inCtx.pointee.streams?[selectedAudioStreamIndex] else { return }
        var framePts = decodedFrame.pointee.best_effort_timestamp
        if framePts == Int64.min { framePts = decodedFrame.pointee.pts }
        guard framePts != Int64.min else { return }
        let inTB = stream.pointee.time_base
        let anchor = vodAnchorPts != 0
            ? av_rescale_q(vodAnchorPts, vodVideoTimeBase, inTB)
            : 0
        // Same encoder-tick axis the per-sample counter advances on
        // (`nextEncodedAudioPTS += nb_samples`, i.e. 1/sample_rate).
        var encoderTB = encoderCtx.pointee.time_base
        if encoderTB.num != 1 || encoderTB.den <= 0 {
            encoderTB = AVRational(num: 1, den: encoderCtx.pointee.sample_rate)
        }
        let seed = max(0, av_rescale_q(framePts - anchor, inTB, encoderTB))
        vodSeededBridgedAudioPTS = true
        guard seed > 0 else { return }
        var anchored = seed
        // Align to the run's own plan boundary: the previous contiguous
        // run's stored audio ends there, and the video track of this run
        // starts there. The typical delta is the ~40ms the restarted MLP
        // decoder ate finding major_sync (fill), or one straddling frame
        // (trim). Deltas beyond the caps keep the source-accurate seed.
        if let plan = vodPlan,
           vodEffectiveBaseIndex >= 0,
           vodEffectiveBaseIndex < plan.boundaries.count {
            let boundarySession = plan.boundaries[vodEffectiveBaseIndex] - vodAnchorPts
            let boundary = max(0, av_rescale_q(boundarySession, vodVideoTimeBase, encoderTB))
            let delta = seed - boundary
            if delta > 0, delta <= Self.vodSeamFillMaxSamples {
                anchored = boundary
                vodPendingSeamSilenceFillSamples = delta
                cmpLog("[CMP-AVP] vod bridged audio seam stitch boundary=\(boundary) seed=\(seed) fillSilence=\(delta)")
            } else if delta < 0, -delta <= Self.vodSeamTrimMaxSamples {
                anchored = boundary
                vodPendingSeamTrimSamples = -delta
                cmpLog("[CMP-AVP] vod bridged audio seam stitch boundary=\(boundary) seed=\(seed) trimOverlap=\(-delta)")
            } else if delta != 0 {
                cmpLog("[CMP-AVP] vod bridged audio seam stitch skipped delta=\(delta) (beyond stitch caps)")
            }
        }
        nextEncodedAudioPTS = anchored
        let seconds = Double(anchored) * Double(encoderTB.num) / Double(max(1, encoderTB.den))
        let logLine = String(
            format: "[CMP-AVP] vod bridged audio timeline anchored seed=%lld (%.3fs on session axis)",
            anchored, seconds
        )
        cmpLog(logLine)
    }

    /// Temporary [CMP-ADRIFT] diagnostic: after seeding, the bridged-audio
    /// clock free-runs on accumulated output samples, so any decode failure
    /// (zero emitted samples) slides every later sample earlier on the
    /// session axis with no correction until the next producer restart —
    /// suspected cause of gradual lipsync drift on multi-hour TrueHD
    /// watches. Projects where this frame's samples will be stamped
    /// (counter + pending stitch + swr backlog + FIFO fill) against the
    /// frame's own source timestamp, using the seeder's exact rescale math.
    /// Logs when the gap crosses another 100 ms step and heartbeats every
    /// 30 s of media so a silent probe is distinguishable from a dead one.
    /// Negative drift = content stamped early (audio leads video).
    private func noteBridgedAudioDriftIfNeeded(
        from decodedFrame: UnsafeMutablePointer<AVFrame>,
        encoderCtx: UnsafeMutablePointer<AVCodecContext>,
        swr: OpaquePointer
    ) {
        guard vodActive, vodSeededBridgedAudioPTS else { return }
        guard let inCtx = inputCtx,
              selectedAudioStreamIndex >= 0,
              selectedAudioStreamIndex < Int(inCtx.pointee.nb_streams),
              let stream = inCtx.pointee.streams?[selectedAudioStreamIndex] else { return }
        var framePts = decodedFrame.pointee.best_effort_timestamp
        if framePts == Int64.min { framePts = decodedFrame.pointee.pts }
        guard framePts != Int64.min else { return }

        let inTB = stream.pointee.time_base
        let anchor = vodAnchorPts != 0
            ? av_rescale_q(vodAnchorPts, vodVideoTimeBase, inTB)
            : 0
        var encoderTB = encoderCtx.pointee.time_base
        if encoderTB.num != 1 || encoderTB.den <= 0 {
            encoderTB = AVRational(num: 1, den: encoderCtx.pointee.sample_rate)
        }
        let expected = av_rescale_q(framePts - anchor, inTB, encoderTB)

        let sampleRate = Int64(max(1, encoderCtx.pointee.sample_rate))
        var projected = nextEncodedAudioPTS
            + vodPendingSeamSilenceFillSamples
            - vodPendingSeamTrimSamples
        projected += max(0, swr_get_delay(swr, sampleRate))
        if let fifo = audioSampleFifo {
            projected += Int64(av_audio_fifo_size(fifo))
        }

        let drift = projected - expected
        let ticksToMs = 1000.0 * Double(encoderTB.num) / Double(max(1, encoderTB.den))

        if bridgedDriftCorrectionEnabled {
            // Post-anchor top-up: the restarted TrueHD/MLP decoder keeps
            // eating packets for a moment AFTER the seam stitch aligned the
            // first emitted frame (28–59 ms observed on device), so inside
            // the first seconds of a run the correction floor drops to
            // ~noise level and the seam leak is topped up to ~0 instead of
            // parking just under the perceptibility floor.
            if bridgedDriftRunAnchorPTS < 0 { bridgedDriftRunAnchorPTS = projected }
            let inPostAnchorWindow = projected - bridgedDriftRunAnchorPTS
                < LoopbackBridgedDriftGovernor.postAnchorWindowSeconds * sampleRate
            let correction = bridgedDriftGovernor.observe(
                drift: drift,
                position: projected,
                sampleRate: sampleRate,
                floorMs: inPostAnchorWindow
                    ? LoopbackBridgedDriftGovernor.postAnchorFloorMs
                    : LoopbackBridgedDriftGovernor.correctionFloorMs
            )
            let phase = inPostAnchorWindow ? " postAnchor=1" : ""
            if correction > 0 {
                let fill = min(correction, Self.vodSeamFillMaxSamples)
                vodPendingSeamSilenceFillSamples += fill
                let logLine = String(
                    format: "[CMP-ADRIFT] correction fill=%lld samples (drift=%+.1fms) decErrTotal=%d",
                    fill, Double(drift) * ticksToMs, audioDecodeErrorTotal
                ) + phase
                cmpLog(logLine)
            } else if correction < 0 {
                let trim = min(-correction, Self.vodSeamTrimMaxSamples)
                vodPendingSeamTrimSamples += trim
                let logLine = String(
                    format: "[CMP-ADRIFT] correction trim=%lld samples (drift=%+.1fms) decErrTotal=%d",
                    trim, Double(drift) * ticksToMs, audioDecodeErrorTotal
                ) + phase
                cmpLog(logLine)
            }
        }

        let step = drift / max(1, sampleRate / 10)
        let heartbeatDue = projected >= bridgedDriftNextHeartbeatPTS
        guard step != bridgedDriftLastLoggedStep || heartbeatDue else { return }
        bridgedDriftLastLoggedStep = step
        bridgedDriftNextHeartbeatPTS = projected + 30 * sampleRate
        let logLine = String(
            format: "[CMP-ADRIFT] drift=%+.1fms expected=%.3fs projected=%lld decErrTotal=%d frames=%d",
            Double(drift) * ticksToMs,
            Double(expected) * ticksToMs / 1000.0,
            projected, audioDecodeErrorTotal, audioDecodedFrameCount
        )
        cmpLog(logLine, verbose: true)
    }

    private func noteAudioDecodeError(stage: String, rc: Int32) {
        audioDecodeErrorCount += 1
        audioDecodeErrorTotal += 1
        let shouldLog = audioDecodeErrorCount <= 8 || audioDecodeErrorCount % 64 == 0
        guard shouldLog else { return }
        let level = rc == avErrorInvalidData ? "invaliddata" : "error"
        Self.logger.warning(
            "[CMP-AVP] audio decoder \(stage, privacy: .public) \(level, privacy: .public) rc=\(rc, privacy: .public) consecutive=\(self.audioDecodeErrorCount, privacy: .public) total=\(self.audioDecodeErrorTotal, privacy: .public)"
        )
    }

    private func sendConvertedFrameToEncoder(_ decodedFrame: UnsafeMutablePointer<AVFrame>) throws {
        guard let encoderCtx = audioEncoderCtx else { return }
        let swr = try audioResampler(for: decodedFrame, encoderCtx: encoderCtx)
        seedVODBridgedAudioPTSIfNeeded(from: decodedFrame, encoderCtx: encoderCtx)
        noteBridgedAudioDriftIfNeeded(from: decodedFrame, encoderCtx: encoderCtx, swr: swr)

        let inSamples = decodedFrame.pointee.nb_samples
        let outCapacity = swr_get_out_samples(swr, inSamples) + 32
        guard outCapacity > 0 else { return }

        var convertedFrame = av_frame_alloc()
        guard let outFrame = convertedFrame else {
            throw LoopbackWriterError.allocOutput
        }
        outFrame.pointee.nb_samples = outCapacity
        outFrame.pointee.format = encoderCtx.pointee.sample_fmt.rawValue
        outFrame.pointee.sample_rate = encoderCtx.pointee.sample_rate
        outFrame.pointee.ch_layout = encoderCtx.pointee.ch_layout
        if av_frame_get_buffer(outFrame, 0) < 0 {
            av_frame_free(&convertedFrame)
            throw LoopbackWriterError.audioTranscodeSetup("audio frame buffer alloc failed")
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
            try applyPendingSeamSilenceFillIfNeeded(encoderCtx: encoderCtx)
            try writeConvertedAudioToFifo(outFrame, sampleCount: converted)
            drainPendingSeamTrimFromFifoIfNeeded()
            av_frame_free(&convertedFrame)
            try drainAudioSampleFifo(final: false)
            return
        }

        // Seam stitching is FIFO-only; every bridged codec we configure
        // (FLAC/AAC/AC3/EAC3) has a fixed frame_size and takes the FIFO
        // path above. Drop any pending stitch rather than misapply it.
        vodPendingSeamSilenceFillSamples = 0
        vodPendingSeamTrimSamples = 0
        outFrame.pointee.pts = nextEncodedAudioPTS
        nextEncodedAudioPTS += Int64(converted)
        let sendR = avcodec_send_frame(encoderCtx, outFrame)
        av_frame_free(&convertedFrame)
        if sendR < 0 && sendR != avErrorAgain {
            throw LoopbackWriterError.audioTranscodeSetup("audio encoder send failed rc=\(sendR)")
        }
        try drainEncodedPackets()
    }

    private func audioResampler(
        for decodedFrame: UnsafeMutablePointer<AVFrame>,
        encoderCtx: UnsafeMutablePointer<AVCodecContext>
    ) throws -> OpaquePointer {
        if let audioSwrCtx {
            return audioSwrCtx
        }

        let inputFormatRaw = decodedFrame.pointee.format
        guard inputFormatRaw >= 0 else {
            throw LoopbackWriterError.audioTranscodeSetup(
                "decoded audio frame has unknown sample format"
            )
        }
        let inputSampleRate = decodedFrame.pointee.sample_rate > 0
            ? decodedFrame.pointee.sample_rate
            : audioDecoderCtx?.pointee.sample_rate ?? 0
        guard inputSampleRate > 0 else {
            throw LoopbackWriterError.audioTranscodeSetup(
                "decoded audio frame has unknown sample rate"
            )
        }

        var inputLayout = decodedFrame.pointee.ch_layout
        if inputLayout.nb_channels <= 0, let decoderCtx = audioDecoderCtx {
            inputLayout = decoderCtx.pointee.ch_layout
        }
        if inputLayout.nb_channels <= 0 {
            let channelCount = Int32(sessionSpec.selectedAudio.sourceChannelCount ?? 2)
            av_channel_layout_default(&inputLayout, max(1, channelCount))
        }

        var swr: OpaquePointer?
        let allocateResult = swr_alloc_set_opts2(
            &swr,
            &encoderCtx.pointee.ch_layout,
            encoderCtx.pointee.sample_fmt,
            encoderCtx.pointee.sample_rate,
            &inputLayout,
            AVSampleFormat(rawValue: inputFormatRaw),
            inputSampleRate,
            0,
            nil
        )
        guard allocateResult >= 0, swr != nil else {
            throw LoopbackWriterError.audioTranscodeSetup(
                "swr alloc failed \(outputAudioCodecToken ?? "audio") rc=\(allocateResult) \(Self.ffmpegError(allocateResult))"
            )
        }
        let initializeResult = swr_init(swr)
        guard initializeResult >= 0, let swr else {
            swr_free(&swr)
            throw LoopbackWriterError.audioTranscodeSetup(
                "swr init failed \(outputAudioCodecToken ?? "audio") rc=\(initializeResult) \(Self.ffmpegError(initializeResult))"
            )
        }

        audioSwrCtx = swr
        cmpLog("[CMP-AVP] audio resampler configured sourceFormat=\(inputFormatRaw) sourceRate=\(inputSampleRate) sourceChannels=\(inputLayout.nb_channels) outputCodec=\(outputAudioCodecToken ?? "audio") outputRate=\(encoderCtx.pointee.sample_rate) outputChannels=\(encoderCtx.pointee.ch_layout.nb_channels)")
        return swr
    }

    private func writeConvertedAudioToFifo(
        _ convertedFrame: UnsafeMutablePointer<AVFrame>,
        sampleCount: Int32
    ) throws {
        guard let fifo = audioSampleFifo else {
            throw LoopbackWriterError.audioTranscodeSetup("audio fifo unavailable")
        }
        let planePointers = unsafeBitCast(
            convertedFrame.pointee.extended_data,
            to: UnsafeMutablePointer<UnsafeMutableRawPointer?>?.self
        )
        let writeR = av_audio_fifo_write(fifo, planePointers, sampleCount)
        if writeR < 0 || writeR != sampleCount {
            throw LoopbackWriterError.audioTranscodeSetup("audio fifo write failed rc=\(writeR)")
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
                throw LoopbackWriterError.allocOutput
            }
            outFrame.pointee.nb_samples = samplesToSend
            outFrame.pointee.format = encoderCtx.pointee.sample_fmt.rawValue
            outFrame.pointee.sample_rate = encoderCtx.pointee.sample_rate
            outFrame.pointee.ch_layout = encoderCtx.pointee.ch_layout
            if av_frame_get_buffer(outFrame, 0) < 0 {
                av_frame_free(&frame)
                throw LoopbackWriterError.audioTranscodeSetup("audio fifo frame buffer alloc failed")
            }

            let planePointers = unsafeBitCast(
                outFrame.pointee.extended_data,
                to: UnsafeMutablePointer<UnsafeMutableRawPointer?>?.self
            )
            let readR = av_audio_fifo_read(fifo, planePointers, samplesToSend)
            if readR < 0 || readR != samplesToSend {
                av_frame_free(&frame)
                throw LoopbackWriterError.audioTranscodeSetup("audio fifo read failed rc=\(readR)")
            }

            outFrame.pointee.pts = nextEncodedAudioPTS
            nextEncodedAudioPTS += Int64(samplesToSend)
            try sendPreparedAudioFrameToEncoder(outFrame)
            av_frame_free(&frame)
        }
    }

    /// Producer-seam gap fill: writes `vodPendingSeamSilenceFillSamples` of
    /// silence into the sample FIFO before the run's first content samples,
    /// covering [previous run's audio end, this run's first decoded frame)
    /// so the track timeline stays contiguous and lipsync stays exact.
    private func applyPendingSeamSilenceFillIfNeeded(
        encoderCtx: UnsafeMutablePointer<AVCodecContext>
    ) throws {
        guard vodPendingSeamSilenceFillSamples > 0 else { return }
        var remaining = vodPendingSeamSilenceFillSamples
        vodPendingSeamSilenceFillSamples = 0
        cmpLog("[CMP-AVP] vod seam silence fill samples=\(remaining)")
        while remaining > 0 {
            let n = Int32(min(remaining, 4096))
            var frame = av_frame_alloc()
            guard let silence = frame else {
                throw LoopbackWriterError.allocOutput
            }
            silence.pointee.nb_samples = n
            silence.pointee.format = encoderCtx.pointee.sample_fmt.rawValue
            silence.pointee.sample_rate = encoderCtx.pointee.sample_rate
            silence.pointee.ch_layout = encoderCtx.pointee.ch_layout
            if av_frame_get_buffer(silence, 0) < 0 {
                av_frame_free(&frame)
                throw LoopbackWriterError.audioTranscodeSetup("seam silence buffer alloc failed")
            }
            _ = av_samples_set_silence(
                silence.pointee.extended_data,
                0,
                n,
                encoderCtx.pointee.ch_layout.nb_channels,
                encoderCtx.pointee.sample_fmt
            )
            try writeConvertedAudioToFifo(silence, sampleCount: n)
            av_frame_free(&frame)
            remaining -= Int64(n)
        }
    }

    /// Producer-seam overlap trim: drains duplicated leading samples out of
    /// the FIFO before they are assigned timestamps, so a run whose first
    /// decoded frame lands before the previous run's audio end doesn't
    /// double-play that span (audible as phasing/"channels out of sync").
    private func drainPendingSeamTrimFromFifoIfNeeded() {
        guard vodPendingSeamTrimSamples > 0, let fifo = audioSampleFifo else { return }
        let available = Int64(av_audio_fifo_size(fifo))
        let n = min(vodPendingSeamTrimSamples, available)
        guard n > 0 else { return }
        if av_audio_fifo_drain(fifo, Int32(n)) >= 0 {
            vodPendingSeamTrimSamples -= n
            if vodPendingSeamTrimSamples == 0 {
                cmpLog("[CMP-AVP] vod seam overlap trim complete samples=\(n)")
            }
        }
    }

    private func sendPreparedAudioFrameToEncoder(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        guard let encoderCtx = audioEncoderCtx else { return }
        let sendR = avcodec_send_frame(encoderCtx, frame)
        if sendR < 0 && sendR != avErrorAgain {
            throw LoopbackWriterError.audioTranscodeSetup("audio encoder send failed rc=\(sendR)")
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
                throw LoopbackWriterError.allocOutput
            }
            let recvR = avcodec_receive_packet(encoderCtx, encodedPacket)
            if recvR == avErrorAgain || recvR == avErrorEOF {
                av_packet_free(&packet)
                return
            }
            if recvR < 0 {
                av_packet_free(&packet)
                throw LoopbackWriterError.audioTranscodeSetup("audio encoder receive failed rc=\(recvR)")
            }

            encodedPacket.pointee.stream_index = Int32(audioOutputStreamIndex)
            av_packet_rescale_ts(encodedPacket, encoderCtx.pointee.time_base, outStream.pointee.time_base)
            normalizeMuxerTimestampsIfNeeded(pkt: encodedPacket, outStream: outStream)
            do {
                try writePacketToMux(encodedPacket)
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
        let decodedFrame = try reusableAudioDecodedFrame()
        while true {
            let recvR = avcodec_receive_frame(decoderCtx, decodedFrame)
            if recvR == avErrorAgain || recvR == avErrorEOF {
                break
            }
            if recvR < 0 {
                throw LoopbackWriterError.audioTranscodeSetup("audio decoder flush failed rc=\(recvR)")
            }
            try sendConvertedFrameToEncoder(decodedFrame)
            av_frame_unref(decodedFrame)
        }

        try drainAudioSampleFifo(final: true)
        _ = avcodec_send_frame(encoderCtx, nil)
        try drainEncodedPackets()
        if audioDecodedFrameCount == 0 {
            throw LoopbackWriterError.audioTranscodeSetup("audio decoder produced no frames")
        }
    }

    private func transformVideoPacketIfNeeded(_ pkt: UnsafeMutablePointer<AVPacket>) throws {
        guard videoMode == .convertProfile7To81 else { return }
        guard pkt.pointee.data != nil, pkt.pointee.size > 0 else { return }
        // Compact in place instead of rebuilding: BL NALs lead the packet
        // and stay put, the dropped EL NALs open a gap only behind them,
        // and the RPU is rewritten where it stands. The old rebuild path
        // (walk + Data + av_new_packet + memcpy) copied every frame twice
        // at 60-75 Mbps — a steady mux-thread tax on A12-class devices.
        let writableR = av_packet_make_writable(pkt)
        guard writableR >= 0 else { throw LoopbackWriterError.allocOutput }
        guard let data = pkt.pointee.data else { return }
        let size = Int(pkt.pointee.size)

        var read = 0
        var write = 0
        var changed = false
        while read + nalLengthSize <= size {
            var nalSize = 0
            for i in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(data[read + i])
            }
            let nalStart = read + nalLengthSize
            guard nalSize >= 2, nalStart + nalSize <= size else {
                // Malformed tail: mirror the rebuild path — leave the whole
                // packet verbatim when nothing changed yet, drop the tail
                // once compaction has started.
                if !changed { return }
                break
            }
            let byte0 = data[nalStart]
            let byte1 = data[nalStart + 1]
            let nalType = Int((byte0 >> 1) & 0x3F)
            let layerID = Int(((byte0 & 0x01) << 5) | ((byte1 & 0xF8) >> 3))
            let next = nalStart + nalSize

            if layerID > 0 || nalType == 63 {
                changed = true
                read = next
                continue
            }
            if nalType == 62 {
                let nalData = Data(bytes: data + nalStart, count: nalSize)
                let payload = try convertRpuNALToProfile81(nalData)
                let needed = nalLengthSize + payload.count
                guard write + needed <= next else {
                    // Converted RPU outgrew the bytes consumed so far. With
                    // a pristine buffer (no NAL moved or rewritten yet) the
                    // old rebuild path handles it; after mutation the slack
                    // equals every dropped EL byte so far, so overrunning it
                    // means a pathologically grown RPU — surface it.
                    if !changed && write == read {
                        try rebuildProfile7Packet(pkt)
                        return
                    }
                    throw LoopbackWriterError.profile81ConversionFailed("rpu_grew_past_compaction_slack")
                }
                var length = payload.count
                for i in stride(from: nalLengthSize - 1, through: 0, by: -1) {
                    data[write + i] = UInt8(length & 0xFF)
                    length >>= 8
                }
                payload.withUnsafeBytes { raw in
                    if let base = raw.baseAddress, payload.count > 0 {
                        memcpy(data + write + nalLengthSize, base, payload.count)
                    }
                }
                write += needed
                changed = true
                read = next
                continue
            }
            let span = nalLengthSize + nalSize
            if write != read {
                memmove(data + write, data + read, span)
            }
            write += span
            read = next
        }
        guard changed else { return }
        guard write > 0 else {
            // Everything dropped — mirror the rebuild path's contract of
            // never emitting an empty packet.
            return
        }
        av_shrink_packet(pkt, Int32(write))
    }

    /// Structural corruption concealment for length-prefixed HEVC. FFmpeg's
    /// Matroska demuxer can recover after a damaged EBML block without marking
    /// the returned packet `AV_PKT_FLAG_CORRUPT`; the first recovered packet
    /// may nevertheless contain an impossible NAL length and the dependent
    /// pictures after it reference frames that were lost in the block. Passing
    /// those samples into fMP4 makes AVPlayer park the item permanently.
    ///
    /// Drop the malformed access unit and every dependent picture until a
    /// structurally valid IRAP arrives. Audio continues on its source clock,
    /// while the last good video picture naturally holds across the damaged
    /// span. This is the same decoder-resynchronization boundary used by the
    /// Compatibility path, but it keeps playback in SiloPlayer.
    private func shouldDropCorruptHEVCVideoPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>
    ) -> Bool {
        // Bridged sources are not HEVC — walking their packets as
        // length-prefixed HEVC would reject every one of them.
        guard videoOutputMode == .copy,
              videoMode != .passthroughH264,
              let data = pkt.pointee.data,
              pkt.pointee.size > 0 else { return false }
        let packetBytes = UnsafeBufferPointer(
            start: data,
            count: Int(pkt.pointee.size)
        )
        let structurallyValid = LoopbackLengthPrefixedHEVCValidator.isValid(
            packetBytes: packetBytes,
            nalLengthSize: nalLengthSize
        )
        let irapType = structurallyValid
            ? ISOBoxSurgery.firstIRAPNALType(
                packetBytes: packetBytes,
                nalLengthSize: nalLengthSize
            )
            : nil
        let action = corruptVideoRecoveryState.evaluate(
            structurallyValid: structurallyValid,
            isRandomAccess: irapType != nil
        )
        switch action {
        case .keep:
            return false
        case .drop(let startedRecovery):
            corruptVideoPacketsDropped += 1
            if startedRecovery {
                cmpLog(
                    "[CMP-AVP] malformed HEVC access unit dropped; suppressing dependent video until IRAP pts=\(pkt.pointee.pts) dts=\(pkt.pointee.dts) bytes=\(pkt.pointee.size)"
                )
            }
            return true
        case .resumeAtRandomAccess:
            pkt.pointee.flags |= AV_PKT_FLAG_KEY
            cmpLog(
                "[CMP-AVP] HEVC corruption recovery resumed at IRAP type=\(irapType ?? -1) pts=\(pkt.pointee.pts) dts=\(pkt.pointee.dts) dropped=\(corruptVideoPacketsDropped)"
            )
            corruptVideoPacketsDropped = 0
            return false
        }
    }

    /// Rare fallback for the in-place compaction: rebuild the packet into a
    /// fresh buffer (the pre-compaction transform path).
    private func rebuildProfile7Packet(_ pkt: UnsafeMutablePointer<AVPacket>) throws {
        guard let dataPtr = pkt.pointee.data else { return }
        let packetBytes = UnsafeBufferPointer(start: dataPtr, count: Int(pkt.pointee.size))
        let transformed = try transformedVideoPacketData(packetBytes: packetBytes)

        var replacement = av_packet_alloc()
        guard let newPacket = replacement else {
            throw LoopbackWriterError.allocOutput
        }
        let allocR = av_new_packet(newPacket, Int32(transformed.count))
        guard allocR >= 0, let newData = newPacket.pointee.data else {
            av_packet_free(&replacement)
            throw LoopbackWriterError.allocOutput
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

    private func convertRpuNALToProfile81(_ nal: Data) throws -> Data {
        return try nal.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw LoopbackWriterError.profile81ConversionFailed("empty_rpu_nal")
            }
            guard let parsed = dovi_parse_unspec62_nalu(base, raw.count) else {
                throw LoopbackWriterError.profile81ConversionFailed("dovi_parse_unspec62_nalu")
            }
            defer { dovi_rpu_free(parsed) }
            let convertR = dovi_convert_rpu_with_mode(parsed, 2)
            if convertR != 0 {
                let error = dovi_rpu_get_error(parsed).map(String.init(cString:)) ?? "unknown"
                throw LoopbackWriterError.profile81ConversionFailed("dovi_convert_rpu_with_mode \(error)")
            }
            guard let written = dovi_write_unspec62_nalu(parsed) else {
                throw LoopbackWriterError.profile81ConversionFailed("dovi_write_unspec62_nalu")
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
        guard let outCtx = outputCtx else { throw LoopbackWriterError.allocOutput }

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
            throw LoopbackWriterError.writeHeader(rc)
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

        // HDR10+ badge scan. This is the single choke point every written
        // packet passes through — including bootstrap-stashed video packets
        // replayed outside the main mux-loop video branch — so the SEI on
        // the very first keyframe is never missed. Gated on isActive (hit or
        // budget exhausted disarms it) and NAL-walked to touch only SEI
        // payloads: the original whole-packet sweep on every video packet of
        // a plain-HDR10 film was the ~12 Mbps producer ceiling.
        if inputStreamIndex == videoInputStreamIndex,
           videoOutputMode == .copy,
           onHDR10PlusMetadataDetected != nil,
           hdr10PlusSEIDetector.isActive,
           let packetData = pkt.pointee.data,
           hdr10PlusSEIDetector.scanVideoPacket(
               bytes: packetData,
               count: Int(pkt.pointee.size),
               nalLengthSize: nalLengthSize,
               isHEVC: videoMode != .passthroughH264
           ) {
            onHDR10PlusMetadataDetected?()
        }

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
        if vodActive, inputStreamIndex != videoInputStreamIndex, pkt.pointee.pts != Int64.min {
            vodAudioPacketRouted = true
        }
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

    /// Input-axis DTS of the last video packet that passed timestamp repair.
    /// The base for synthesizing a post-seek follower's missing DTS: after a
    /// matroska seek, libavformat leaves DTS unset on the first
    /// `has_b_frames` video packets (its pts-reorder buffer is cold), so the
    /// anchor IDR's immediate followers arrive PTS-only.
    private var lastRepairedVideoInputDTS: Int64?

    private func repairMissingMuxerTimestampsIfNeeded(
        pkt: UnsafeMutablePointer<AVPacket>,
        inputStreamIndex: Int,
        noPTS: Int64
    ) -> Bool {
        let isVideo = inputStreamIndex == videoInputStreamIndex
        let missingPTS = pkt.pointee.pts == noPTS
        let missingDTS = pkt.pointee.dts == noPTS
        guard missingPTS || missingDTS else {
            if isVideo { lastRepairedVideoInputDTS = pkt.pointee.dts }
            return true
        }
        guard !missingPTS, isVideo else { return false }

        let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
        if isKeyframe {
            // For an IRAP, pts == dts in decode order, so pts is the exact
            // repair — never subtract a reorder guess. A `video_delay` backoff
            // under-shoots deep-reorder streams (250ms real vs 84ms guessed,
            // living-room resume seam) and goes NEGATIVE at the stream head,
            // where tfdt is unsigned and `avoid_negative_ts=disabled` writes it
            // wrapped (2^64-1344, the living-room mid-play timeline jump).
            // Followers whose real DTS sits below pts are bumped forward by
            // normalizeVideoMuxerTimestampsIfNeeded instead of being dropped.
            pkt.pointee.dts = pkt.pointee.pts
        } else {
            // Post-seek follower with PTS but no DTS. These are REFERENCE
            // frames as often as not — the P right after a resume anchor's
            // IDR anchors the whole first mini-GOP — and dropping one makes
            // every dependent frame decode against a missing reference
            // (resume-time macroblocking until the next IDR). Cram its DTS
            // one tick above the previous video packet's; PTS is untouched,
            // and the true DTS cadence resumes once the demuxer's reorder
            // buffer warms up.
            guard let base = lastRepairedVideoInputDTS else { return false }
            pkt.pointee.dts = base + 1
        }
        lastRepairedVideoInputDTS = pkt.pointee.dts
        repairedMissingVideoDTSCount += 1
        if repairedMissingVideoDTSCount <= 6 {
            cmpLog("[CMP-AVP] repaired missing video DTS pts=\(pkt.pointee.pts) dts=\(pkt.pointee.dts) keyframe=\(isKeyframe) videoMode=\(videoMode.logToken)", verbose: true)
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
        // Record the final pre-write timestamps here — the write-side hook
        // never worked: `av_interleaved_write_frame` takes ownership and
        // blanks the packet, so reading it back after the write recorded
        // AV_NOPTS for stream 0 and the monotonicity bumps above never
        // fired (rc=-22 dropped frames at every restart/repair seam).
        recordMuxedPacketTimestamps(pkt)
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
        // buffered for the next ingest. Keep the capacity on a full drain —
        // the buffer re-grows to a whole mdat every fragment otherwise.
        if cursor >= boxBuffer.count {
            boxBuffer.removeAll(keepingCapacity: true)
        } else if cursor > 0 {
            boxBuffer.removeSubrange(0..<cursor)
        }
    }

    private func handleTopLevelBox(type: String, range: Range<Int>) {
        let slice = boxBuffer[range]
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
                    beginPendingSegment(firstBox: Data(slice), hasMoof: false, hasVideo: false)
                } else {
                    appendToCurrentSegment(slice)
                }
                return
            case "styp":
                if pendingSegmentBytes.isEmpty {
                    beginPendingSegment(firstBox: Data(slice), hasMoof: false, hasVideo: false)
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
                beginPendingSegment(firstBox: Data(slice), hasMoof: false, hasVideo: false)
            } else {
                appendToCurrentSegment(slice)
            }
        case "moof":
            let fragmentHasVideo = fragmentHasVideoTrack(in: slice)
            if pendingSegmentBytes.isEmpty {
                startNewSegment(firstBox: slice, hasMoof: true, hasVideo: fragmentHasVideo)
            } else if pendingSegmentHasMoof,
                      !vodProgressiveAccumulating,
                      !pendingSegmentIsProgressive {
                startNewSegment(firstBox: slice, hasMoof: true, hasVideo: fragmentHasVideo)
            } else {
                // Progressive anchor: interim fragments accumulate into one
                // multi-fragment segment instead of splitting per moof. The
                // `pendingSegmentIsProgressive` arm keeps the CLOSING
                // fragment in its segment — at cut time the accumulation
                // gate is already off (vodClosingSegmentIndex set), but the
                // cut flush's moof is the accumulated segment's tail, not
                // the start of the next one.
                appendMoofToCurrentSegment(slice, hasVideo: fragmentHasVideo)
            }
        case "mdat":
            appendToCurrentSegment(slice)
            if vodProgressiveAccumulating {
                // Anchor still open: stream the new fragment to the store;
                // the cut (vodClosingSegmentIndex set) finalizes as usual.
                pendingSegmentIsProgressive = true
                publishProgressivePartial()
            } else {
                // Completes the current segment (moof+mdat pair).
                finalizeCurrentSegment()
            }
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
    }

    private func writeMediaSegment(_ data: Data, name: String, duration: Double) throws {
        if let segmentStore {
            let result = segmentStore.putSegment(name: name, data: data, duration: duration)
            removeEvictedSegmentsFromPlaylist(result.evictedSegmentNames)
        } else {
            try data.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
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
        // FFmpeg's mp4 muxer in our build doesn't emit a Dolby Vision
        // configuration box even when the video codec_tag is `dvh1` and DOVI
        // side data is present on the track's codecpar. Without it AVPlayer
        // has no DV signalling in the sample entry and decodes IPT-PQ-c2 as
        // YCbCr → green/purple render. Inject the box ourselves before
        // writing init.mp4 to disk; the surgery picks `dvcC` or `dvvC` from
        // the record's profile, which `outputDoviConfig` has already rewritten
        // to the profile the segments actually carry. Plain HEVC/HLG/HDR10
        // skips this and uses the muxer's normal hvcC.
        var bytes = initSegmentBytes
        if let dovi = doviConfig {
            if let patched = ISOBoxSurgery.injectDolbyVisionConfig(into: bytes, doviBytes: dovi) {
                bytes = patched
                // Injection succeeded, so the record parsed: the box type it
                // chose is the one this profile names.
                let boxType = ISOBoxSurgery.dolbyVisionConfigBoxType(profile: doviRecord?.profile ?? 0)
                let doviLog = doviRecord?.logLine ?? "unknown"
                cmpLog("[CMP-AVP] \(boxType) injected (init.mp4 grew by 32 bytes) \(doviLog)")
            } else {
                cmpLog("[CMP-AVP] DV config injection failed — hvcC not found in init tree, or record malformed")
            }
        }
        if selectedAudioIsAtmosJOC {
            // complexity_index_type_a = 16 is the standard object count for
            // streaming DDP-Atmos; FFmpeg 7.1's parser does not expose the
            // stream's true value (no complexity_index_type_a in its
            // ac3_parser_internal.h), and the field is a decoder complexity
            // hint. A vendored FFmpeg ≥ 8 bump writes the parsed value
            // natively (the surgery then no-ops via its already-extended
            // guard).
            if let patched = ISOBoxSurgery.appendDec3JOCExtension(into: bytes, complexityIndex: 16) {
                bytes = patched
                cmpLog("[CMP-AVP] dec3 JOC extension appended (Atmos signalling, complexity=16)")
            } else {
                // print too: OSLog is invisible to devicectl console capture.
                cmpLog("[CMP-AVP] dec3 JOC extension append FAILED — Atmos will present as plain E-AC-3 5.1")
                Self.logger.error("dec3 JOC extension append failed — Atmos will present as plain E-AC-3 5.1")
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
            cmpLog("[CMP-AVP] init.mp4 written (\(bytes.count) bytes)")
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
    /// Size of the last finalized segment — the capacity hint for the next
    /// one (segment sizes are stable within a title).
    private var lastFinalizedSegmentBytes = 0
    private var pendingSegmentHasVideo = false
    private var pendingSegmentHasMoof = false

    // MARK: - Progressive anchor serving

    /// While a VOD session's FIRST segment (the seek anchor) is being
    /// produced, fragments are flushed every ~1.5 s of media and streamed
    /// to the store, so AVPlayer starts decoding the anchor while its tail
    /// is still downloading — the dominant share of seek latency on long-GOP
    /// sources whose anchor segments run 30–60 MB. Kill switch:
    /// `defaults write <bundle> player.apple.loopback_progressive_anchor_enabled -bool NO`
    /// Read per-instance (not a process-wide static) so each producer
    /// session — and the continuity tests — honor the current default.
    private lazy var progressiveAnchorServingEnabled =
        UserDefaults.standard.object(
            forKey: "player.apple.loopback_progressive_anchor_enabled"
        ) as? Bool ?? true
    private var vodProgressiveActiveName: String?
    private var vodProgressivePublishedBytes = 0
    private var vodLastInterimFlushPts = Int64.min
    private var vodInterimFlushRequested = false
    /// True while `pendingSegmentBytes` holds progressively-accumulated
    /// fragments — the closing cut's flush must append to it, not open a
    /// new segment.
    private var pendingSegmentIsProgressive = false

    /// The box sink accumulates fragments (instead of finalizing per
    /// moof+mdat pair) only while the anchor segment is open: VOD mode, no
    /// segment finalized yet this session, and no cut in flight.
    private var vodProgressiveAccumulating: Bool {
        progressiveAnchorServingEnabled
            && vodActive
            && segmentEntries.isEmpty
            && vodClosingSegmentIndex == nil
    }

    /// Streams the accumulated prefix of the open anchor segment to the
    /// store. Runs after each interim fragment lands in
    /// `pendingSegmentBytes`; deltas mirror that buffer exactly, so the
    /// streamed prefix is byte-identical to the segment
    /// `finalizeCurrentSegment` eventually stores. Publication starts only
    /// once the segment contains video — an audio-only prefix could belong
    /// to a segment the pre-video gate later discards.
    private func publishProgressivePartial() {
        guard let store = segmentStore, pendingSegmentHasVideo else { return }
        let name = String(format: "seg_%06d.m4s", vodOpenSegmentIndex)
        if vodProgressiveActiveName != name {
            vodProgressiveActiveName = name
            vodProgressivePublishedBytes = 0
            store.beginProgressiveSegment(named: name)
        }
        guard pendingSegmentBytes.count > vodProgressivePublishedBytes else { return }
        let delta = pendingSegmentBytes.subdata(
            in: vodProgressivePublishedBytes..<pendingSegmentBytes.count
        )
        store.appendProgressiveSegment(named: name, bytes: delta)
        vodProgressivePublishedBytes = pendingSegmentBytes.count
    }

    /// Emits the fragment accumulated in the muxer so far WITHOUT closing
    /// the open segment: the same drain+flush pair the cut uses, but with
    /// `vodClosingSegmentIndex` still nil, so the box sink appends and
    /// publishes instead of finalizing. Errors are left for the next real
    /// write/cut to surface.
    /// Moov-priming flush (AetherEngine #92-parity): once the first
    /// parse-needing audio packet is in the interleaver and video has opened
    /// the anchor segment, flush proactively so moov — and with it init.mp4 —
    /// is emitted NOW instead of waiting for the first cut. Gated on the
    /// progressive-anchor window so the emitted fragment appends to the open
    /// segment rather than splitting it, and attempt-capped so a flush that
    /// cannot produce moov (unparseable audio) is not retried per packet —
    /// the first cut's post-flush check escalates that case.
    private func primeVODMoovAfterFirstAudioIfNeeded() throws {
        guard vodActive,
              vodAudioNeedsParsedPacketForMoov,
              !initSegmentWritten,
              vodAudioPacketRouted,
              vodHasRoutedVideo,
              vodProgressiveAccumulating,
              vodMoovPrimeAttempts < 3,
              let outCtx = outputCtx else { return }
        vodMoovPrimeAttempts += 1
        let drainRC = av_interleaved_write_frame(outCtx, nil)
        guard drainRC >= 0 else { return }
        _ = av_write_frame(outCtx, nil)
        if !vodDidFlushFirstFragment {
            vodDidFlushFirstFragment = true
            // delay_moov can split ftyp+moov and the fragment across two
            // flush calls — same second flush the cut path performs.
            _ = av_write_frame(outCtx, nil)
        }
        try throwIfFatalIOError()
        if initSegmentWritten {
            cmpLog("[CMP-AVP] vod moov primed by first audio packet (attempt \(vodMoovPrimeAttempts))")
        }
    }

    private func performVODInterimFragmentFlush() {
        guard vodProgressiveAccumulating, let outCtx = outputCtx else { return }
        // Moov-wedge guard (AE #92-parity): before the first parse-needing
        // audio packet no flush can emit moov — FFmpeg fails moov emission
        // and keeps buffering, so the flush is a wasted error. Skipping is
        // harmless: the interleaver window just grows until audio arrives
        // (prefeed/priming) or the first cut escalates.
        if vodAudioNeedsParsedPacketForMoov, !initSegmentWritten, !vodAudioPacketRouted { return }
        let drainRC = av_interleaved_write_frame(outCtx, nil)
        guard drainRC >= 0 else { return }
        _ = av_write_frame(outCtx, nil)
        if !vodDidFlushFirstFragment {
            vodDidFlushFirstFragment = true
            // delay_moov can split ftyp+moov and the fragment across two
            // flush calls — same second flush the cut path performs.
            _ = av_write_frame(outCtx, nil)
        }
    }

    private func startNewSegment(firstBox: Data, hasMoof: Bool, hasVideo: Bool) {
        // If a segment was mid-write (shouldn't happen, but defensive), flush
        // it first — `finalizeCurrentSegment` empties `pendingSegmentBytes`.
        if !pendingSegmentBytes.isEmpty {
            finalizeCurrentSegment()
        }
        beginPendingSegment(firstBox: firstBox, hasMoof: hasMoof, hasVideo: hasVideo)
    }

    /// Start accumulating a new segment with the previous segment's size
    /// reserved up front — a fresh `Data` otherwise pays the realloc-doubling
    /// walk to ~35-45 MB on every 4K segment.
    private func beginPendingSegment(firstBox: Data, hasMoof: Bool, hasVideo: Bool) {
        var fresh = Data(capacity: max(lastFinalizedSegmentBytes, firstBox.count) + 1024)
        fresh.append(firstBox)
        pendingSegmentBytes = fresh
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

    /// Whether the pending buffer holds an actual media fragment — a top-level
    /// `moof` or `mdat`. The `av_write_trailer` `mfra`/`mfro` tail (and any
    /// stray `styp`/`sidx`-only leftover) carries neither and must not be
    /// published under a plan-indexed segment name.
    private func pendingSegmentContainsMediaBox() -> Bool {
        for box in ISOBoxSurgery.boxes(in: pendingSegmentBytes, from: 0, to: pendingSegmentBytes.count)
        where box.type == "moof" || box.type == "mdat" {
            return true
        }
        return false
    }

    private func finalizeCurrentSegment() {
        guard !pendingSegmentBytes.isEmpty else { return }
        // Whatever happens below consumes the pending buffer — close out the
        // progressive publication state alongside it. (putSegment replaces
        // the store's progressive entry with the complete data.)
        vodProgressiveActiveName = nil
        vodProgressivePublishedBytes = 0
        vodLastInterimFlushPts = Int64.min
        vodInterimFlushRequested = false
        pendingSegmentIsProgressive = false
        guard !isCancelled else {
            pendingSegmentBytes = Data()
            pendingSegmentHasVideo = false
            pendingSegmentHasMoof = false
            return
        }
        // A real media segment is defined by its box structure, not by a
        // status flag. `av_write_trailer` emits `mfra`/`mfro` after the last
        // fragment, and the box splitter's catch-all arm parks them in a fresh
        // pending buffer; publishing that as a media segment would reuse the
        // last segment's plan-indexed name and overwrite a decodable fragment
        // with an index box AVPlayer rejects (CoreMedia -17223). Keying on the
        // presence of a `moof`/`mdat` — rather than `pendingSegmentHasMoof`,
        // which a legitimately mid-stream-finalized fragment can fail to carry
        // — keeps that trailer fix while never discarding a fragment that holds
        // real media.
        guard pendingSegmentContainsMediaBox() else {
            pendingSegmentBytes = Data()
            pendingSegmentHasVideo = false
            pendingSegmentHasMoof = false
            return
        }
        let segmentHasVideo = pendingSegmentHasVideo
        let segSize = pendingSegmentBytes.count
        lastFinalizedSegmentBytes = segSize
        if !hasWrittenVideoSegment, !segmentHasVideo {
            cmpLog("[CMP-AVP] discarded pre-video segment \(currentSegmentIndex) size=\(segSize)")
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
        // Session-head ground truth (first 3 segments per session): the tfdt
        // each fragment carries, for diagnosing render stalls at the seam
        // where playback crosses producer sessions. Computed while
        // `pendingSegmentBytes` is still intact.
        var vodTfdtSummary: String?
        if vodActive, segmentEntries.count < 3 {
            var tfdts: [String] = []
            var firstVideoTfdt: UInt64?
            for moof in ISOBoxSurgery.boxes(in: pendingSegmentBytes, from: 0, to: pendingSegmentBytes.count)
            where moof.type == "moof" {
                for timing in trackFragmentTimings(inMoof: pendingSegmentBytes, moof: moof.box) {
                    tfdts.append("\(timing.trackID):\(timing.baseDecodeTime)")
                    if firstVideoTfdt == nil, timing.trackID == videoOutputTrackID {
                        firstVideoTfdt = timing.baseDecodeTime
                    }
                }
            }
            // Naming-drift check (diagnostic only): the video tfdt is on the
            // session/plan axis, so the first fragment of segment N must sit
            // at N's plan start. Drift means fragments were attributed to
            // the wrong segment index (e.g. a deferred-moov backlog dumped
            // several segments' media through one cut).
            if let firstVideoTfdt,
               let videoID = videoOutputTrackID,
               let tb = trackTimeBasesByID[videoID], tb.den > 0,
               let plan = vodPlan, currentSegmentIndex < plan.segmentCount {
                let tfdtSeconds = Double(firstVideoTfdt) * Double(tb.num) / Double(tb.den)
                let expected = plan.startSeconds[currentSegmentIndex]
                if abs(tfdtSeconds - expected) > 0.5 {
                    tfdts.append(String(
                        format: "NAMING-DRIFT tfdt=%.2fs expectedStart=%.2fs",
                        tfdtSeconds, expected
                    ))
                }
            }
            vodTfdtSummary = tfdts.joined(separator: ",")
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
        retireSegmentsBehindPlaybackIfNeeded()
        emitPlaylists(isFinal: false)
        if shouldLogSegmentProgress(index: idx) {
            cmpLog("[CMP-AVP] seg \(idx) written (\(segSize) bytes, video=\(segmentHasVideo ? 1 : 0), dur=\(String(format: "%.3f", duration))s), total dur=\(String(format: "%.1f", totalMediaDuration))s)")
        }
        onSegmentAppended?(idx, totalMediaDuration)
        if let vodTfdtSummary {
            cmpLog("[CMP-AVP] vod segment stored name=\(name) bytes=\(segSize) dur=\(String(format: "%.3f", duration)) tfdt=[\(vodTfdtSummary)]")
        } else if segmentEntries.count == 1 {
            cmpLog("[CMP-AVP] first segment stored name=\(name) bytes=\(segSize)")
        }
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
            if vodActive {
                // VOD reclamation lives in the disk-first store. The coupled
                // segment-count window bounds production; byte retention may
                // prune history but never blocks the active forward window.
                _ = segmentStore.makeRoomForAppend(byteCount: nextSegmentBytes)
            }
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
                let stats = segmentStore.stats()
                // playhead is on the session axis; runGenerated is this
                // producer run's cumulative output — they are different
                // axes, so log them separately (the old "generatedAhead"
                // subtraction printed nonsense like -3196s).
                cmpLog(
                    "[CMP-HLS-STORE] spill-capacity backpressure nextBytes=\(nextSegmentBytes) playhead=\(String(format: "%.1f", playbackPosition))s runGenerated=\(String(format: "%.1f", totalMediaDuration))s tempSpillBytes=\(stats.tempSpillBytes)"
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
        removeEvictedSegmentsFromPlaylist(retired)
    }

    private struct TrackFragmentTiming {
        let trackID: UInt32
        let baseDecodeTime: UInt64
        let duration: UInt64
    }

    private func segmentMediaDuration(in segment: Data) -> Double? {
        var durationsByTrackID: [UInt32: Double] = [:]
        for moof in ISOBoxSurgery.boxes(in: segment, from: 0, to: segment.count) where moof.type == "moof" {
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
        for traf in ISOBoxSurgery.childBoxes(in: data, parent: moof) where traf.type == "traf" {
            guard let tfhd = ISOBoxSurgery.childBoxes(in: data, parent: traf.box)
                .first(where: { $0.type == "tfhd" }),
                let header = parseTfhd(in: data, box: tfhd.box),
                let tfdt = ISOBoxSurgery.childBoxes(in: data, parent: traf.box)
                    .first(where: { $0.type == "tfdt" }),
                let baseDecodeTime = parseTfdtBaseDecodeTime(in: data, box: tfdt.box) else {
                continue
            }

            var duration: UInt64 = 0
            for trun in ISOBoxSurgery.childBoxes(in: data, parent: traf.box)
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
            cmpLog("[CMP-AVP] startup ready (vod plan) startPlaylist=\(startupPlaylistName) producedSegments=\(segmentEntries.count)")
            onFirstSegmentReady?(startupPlaylistName)
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
        // Start AVPlayer from the master playlist (see `masterStartEnabled`):
        // premium-format claims (Atmos MAT output) are granted at
        // master-variant level only. The historical iOS rejection of this
        // surface was the missing RESOLUTION/FRAME-RATE attributes and the
        // High-tier CODECS declaration, both since fixed.
        cmpLog("[CMP-AVP] startup runway ready startPlaylist=\(startupPlaylistName) generated=\(String(format: "%.1f", totalMediaDuration))s threshold=\(String(format: "%.1f", minimumPlayableWindow))s segments=\(segmentEntries.count) targetDuration=\(String(format: "%.1f", playlistTargetDuration))s elapsed=\(String(format: "%.2f", elapsed))s mediaRate=\(mediaRate) reason=\(startupReason) masterStart=\(masterStartEnabled ? 1 : 0)")
        onFirstSegmentReady?(startupPlaylistName)
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
        let bandwidth = LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
            sourceBitrateBps: sessionSpec.sourceBitrateBps,
            isAudioBridgedToLossless: selectedAudioOutputMode.bridgesToLosslessFLAC
        )
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth.peak)"
        if let average = bandwidth.average {
            inf += ",AVERAGE-BANDWIDTH=\(average)"
        }
        inf += ",CODECS=\"\(masterCodecString())\""
        if let supplemental = supplementalCodecString() {
            inf += ",SUPPLEMENTAL-CODECS=\"\(supplemental)\""
        }
        if masterVideoWidth > 0, masterVideoHeight > 0 {
            inf += ",RESOLUTION=\(masterVideoWidth)x\(masterVideoHeight)"
        }
        // FRAME-RATE is load-bearing for VIDEO-RANGE=PQ variants: AVFoundation
        // filters out a PQ variant that carries no FRAME-RATE before the media
        // playlist is fetched (NSURLError -1002 with zero errorLog events).
        // Always emit it, defaulting to the 23.976 film cadence (the same
        // default the display-criteria path uses) when the server provides no
        // parsable frame rate — otherwise DV/PQ files with missing fps
        // metadata would be dropped by the variant filter.
        let masterFrameRate = sessionSpec.sourceVideoFrameRate.flatMap { $0 > 0 ? $0 : nil } ?? 23.976
        inf += ",FRAME-RATE=\(String(format: "%.3f", Double(masterFrameRate)))"
        inf += ",VIDEO-RANGE=\(manifestMetadata.videoRange)"
        if !loggedMasterManifest {
            loggedMasterManifest = true
            cmpLog("[CMP-AVP] master playlist stream-inf \(inf)")
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
        if let pendingMuxVideoPacket {
            var free: UnsafeMutablePointer<AVPacket>? = pendingMuxVideoPacket
            av_packet_free(&free)
            self.pendingMuxVideoPacket = nil
        }
        for pending in pendingMuxAudioPackets {
            var free: UnsafeMutablePointer<AVPacket>? = pending
            av_packet_free(&free)
        }
        pendingMuxAudioPackets.removeAll()
        for pending in vodPreGateAudioPackets {
            var free: UnsafeMutablePointer<AVPacket>? = pending
            av_packet_free(&free)
        }
        vodPreGateAudioPackets.removeAll()
        vodPreGateAudioBytes = 0
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
        freeSubtitleTapDecoders()
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
        cancelLock.lock()
        didTeardown = true
        let handoff = outgoingInputHandoff
        let token = interruptToken
        outgoingInputHandoff = nil
        cancelLock.unlock()
        if let handoff {
            if let ctx = inputCtx {
                // The interrupt callback (top-level and the copies FFmpeg
                // baked into nested I/O contexts) targets the token, which
                // travels with the context; the successor adopts and resets
                // it on claim.
                handoff.publish(ctx, token: token)
                inputCtx = nil
            } else {
                handoff.cancelPublication()
            }
        } else if inputCtx != nil {
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
        if audioDecodedFrame != nil {
            av_frame_free(&audioDecodedFrame)
        }
        // After the input context is handed off / closed: the bridge holds no
        // reference to it, but freeing the codecs last keeps the ordering
        // identical to the audio bridge's.
        videoBridge?.teardown()
        videoBridge = nil
        lastMuxedDTSByStream.removeAll()
        lastMuxedPTSByStream.removeAll()
        lastResolvedVideoDurationByStream.removeAll()
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

enum LoopbackWriterError: Error {
    case allocInput
    case allocOutput
    case allocPacket
    case openInput(Int32)
    case seekInput(Int32)
    case findStreamInfo
    case noStreams
    case writeHeader(Int32)
    case unsupportedSelectedAudioCodec(String)
    case audioTranscodeSetup(String)
    /// The video bridge could not be built or kept running: no decoder for the
    /// source codec, no VideoToolbox encoder, no parameter sets, or a
    /// mid-session encode failure. Parallels `audioTranscodeSetup`.
    case videoTranscodeSetup(String)
    /// Sustained software-decode + encode throughput fell below realtime, so
    /// the producer can never stay ahead of the playhead. Failing routes the
    /// session to server HLS transcode instead of stuttering indefinitely.
    case videoBridgeTooSlow(fps: Double, required: Double)
    /// The pre-mux bootstrap could not produce a decodable stream head — no
    /// IRAP keyframe within the scan caps, or no parameter sets anywhere.
    /// Muxing anyway yields a presentation AVPlayer freezes on; failing the
    /// session lets the route fall back immediately instead of waiting out
    /// the startup watchdog.
    case bootstrapFailed(String)
    case profile81ConversionFailed(String)
    /// A Profile 5 session reached mux setup without a usable DOVI
    /// configuration record. Neither the sample entry nor the CODECS token
    /// can be written conformantly without one, and the IPT-PQ-c2 base layer
    /// has no viewable fallback, so the session fails instead of publishing a
    /// presentation that renders green/purple.
    case profile5ConfigUnusable(String)
    /// `av_interleaved_write_frame` returned a negative code on three or more
    /// consecutive packets. The mux is no longer producing valid output; abort
    /// rather than continue writing a half-broken HLS presentation.
    case muxWriteFailures(lastRC: Int32, consecutive: Int)
    /// On-disk write of an init segment, media segment, or playlist failed.
    /// These are catastrophic for HLS playback and are propagated rather than
    /// silently logged.
    case fileWriteFailed(String, Error)
    /// A VOD cut flush completed without the muxer ever emitting moov — the
    /// AC-3/E-AC-3/TrueHD sample entry needs a parsed audio packet and none
    /// was available (or parsing keeps failing). No init segment means
    /// AVPlayer can never attach; fail fast so the route ladder falls back.
    case vodMoovBlocked(closingSegment: Int, audioRouted: Bool)
    /// The producer parked against the consumer window but the consumer never
    /// fetched a single media segment — nothing can ever advance the target,
    /// so the park would deadlock the session silently.
    case vodStartupConsumerWedge(parkedSeconds: Int, segment: Int)
    /// `av_read_frame` ended clearly short of the known content (origin
    /// outage truncating the proxied body, `rw_timeout` expiry). Finalizing
    /// would publish a truncated movie as a complete VOD; failing routes the
    /// session into server-outage recovery instead. The name is matched by
    /// PlayerViewModel's error routing — keep it stable.
    case prematureSourceEnd(readRC: Int32, shortfallBytes: Int64?, shortfallSeconds: Double?)
}
