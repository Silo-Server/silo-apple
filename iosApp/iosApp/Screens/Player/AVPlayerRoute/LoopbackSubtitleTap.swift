//
//  LoopbackSubtitleTap.swift
//  Silo (iOS + tvOS + macOS)
//
//  Persistent store for text-subtitle cues harvested from the loopback
//  writer's own demuxer ("subtitle tap"). The writer already reads the
//  source's full interleave to remux video+audio; keeping the text
//  subtitle streams in its keep-set and decoding their packets inline
//  costs microseconds and zero extra bandwidth — versus the legacy
//  extractor, which opened a SECOND demux context on the remote source
//  and paid open/seek/read on a WAN link the writer is saturating
//  (observed: 19 s find_stream_info, 234 s seeks on cue-poor files).
//
//  The store outlives producer restarts (each restart re-reads part of
//  the timeline; `ingest` dedups) and keeps harvesting while subtitles
//  are OFF, so enabling a track is a snapshot backfill plus live
//  forwarding — instant, on any title.
//
//  Threading: `ingest`/`registerTracks` are called from the writer's mux
//  queue; activation/deactivation from the main thread. All state is
//  guarded by `lock`. The live sink is invoked outside the lock and must
//  itself be thread-safe (SubtitleSession.feedEmbedded hops to the
//  renderer's session queue internally).
//

import Foundation

/// One decoded text-subtitle event, in libass chunk form (the content of
/// FFmpeg's `rect->ass`), on the SOURCE media timeline.
struct LoopbackSubtitleTapCue {
    let streamIndex: Int
    let eventText: String
    let startMs: Int64
    let durationMs: Int64
}

/// Metadata for one tapped text-subtitle stream, captured when the writer
/// opens (or re-claims) its demuxer.
struct LoopbackSubtitleTapTrackInfo {
    let streamIndex: Int
    let isNativeASS: Bool
    /// ASS script header (`subtitle_header` from the opened decoder, or
    /// the container extradata) — empty for header-less codings like SRT,
    /// where FFmpeg synthesises a default header at decode time.
    let header: Data
}

final class LoopbackSubtitleTap {
    /// Safety ceiling per stream. A feature film carries 1-3k dialogue
    /// events; the cap only exists so a pathological source cannot grow
    /// without bound. Ingest beyond the cap is dropped (text cues are
    /// tiny, and the active viewing window is always well inside it).
    private static let maxCuesPerStream = 12_000

    private let lock = NSLock()
    private var tracks: [Int: LoopbackSubtitleTapTrackInfo] = [:]
    private var cuesByStream: [Int: [LoopbackSubtitleTapCue]] = [:]
    private var dedupKeys: Set<String> = []
    private var activeStreamIndex: Int?
    private var liveSink: ((LoopbackSubtitleTapCue) -> Void)?
    private var ingestedCount = 0
    private var duplicateCount = 0
    private var lastIngestLogCount = 0

    // MARK: - Writer-side feed

    /// Register (or refresh) the tapped tracks for this source. Called on
    /// every writer start — restarts re-register identical infos.
    func registerTracks(_ infos: [LoopbackSubtitleTapTrackInfo]) {
        lock.lock()
        let isFirst = tracks.isEmpty && !infos.isEmpty
        for info in infos {
            tracks[info.streamIndex] = info
        }
        lock.unlock()
        if isFirst {
            cmpLog("[CMP-TAP] registered text subtitle streams=\(infos.map(\.streamIndex).sorted())")
        }
    }

    /// Ingest one decoded cue from the writer. Dedups against everything
    /// already stored (producer restarts re-read overlapping regions) and
    /// forwards to the live sink when the cue's stream is active.
    ///
    /// The dedup key strips the event's leading ReadOrder field: FFmpeg
    /// numbers ReadOrder per decoder instance, so the SAME cue re-decoded
    /// by a restarted producer arrives with a different prefix — keying on
    /// the full text would re-feed every cue after every restart (and
    /// libass renders duplicates verbatim; its ReadOrder dedup is off).
    func ingest(_ cue: LoopbackSubtitleTapCue) {
        let dedupText: Substring
        if let comma = cue.eventText.firstIndex(of: ",") {
            dedupText = cue.eventText[cue.eventText.index(after: comma)...]
        } else {
            dedupText = cue.eventText[...]
        }
        let key = "\(cue.streamIndex)|\(cue.startMs)|\(dedupText)"
        var forward: ((LoopbackSubtitleTapCue) -> Void)?
        lock.lock()
        if dedupKeys.contains(key) {
            duplicateCount += 1
            lock.unlock()
            return
        }
        var cues = cuesByStream[cue.streamIndex] ?? []
        if cues.count >= Self.maxCuesPerStream {
            lock.unlock()
            return
        }
        dedupKeys.insert(key)
        cues.append(cue)
        cuesByStream[cue.streamIndex] = cues
        ingestedCount += 1
        let shouldLog = ingestedCount - lastIngestLogCount >= 200 || ingestedCount == 1
        if shouldLog { lastIngestLogCount = ingestedCount }
        if activeStreamIndex == cue.streamIndex {
            forward = liveSink
        }
        let totals = (ingestedCount, duplicateCount)
        lock.unlock()
        if shouldLog {
            cmpLog("[CMP-TAP] cues ingested=\(totals.0) duplicates=\(totals.1)")
        }
        forward?(cue)
    }

    // MARK: - Backend-side selection

    func hasTrack(forStream streamIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracks[streamIndex] != nil
    }

    func trackInfo(forStream streamIndex: Int) -> LoopbackSubtitleTapTrackInfo? {
        lock.lock()
        defer { lock.unlock() }
        return tracks[streamIndex]
    }

    /// Atomically make `streamIndex` the live-forwarded stream and return
    /// the backfill snapshot. Every stored cue is either in the snapshot
    /// or delivered through `sink` afterwards — never both, never neither
    /// (libass ReadOrder dedup is disabled; exactly-once matters).
    func activate(
        streamIndex: Int,
        sink: @escaping (LoopbackSubtitleTapCue) -> Void
    ) -> [LoopbackSubtitleTapCue] {
        lock.lock()
        defer { lock.unlock() }
        activeStreamIndex = streamIndex
        liveSink = sink
        return cuesByStream[streamIndex] ?? []
    }

    func deactivate() {
        lock.lock()
        activeStreamIndex = nil
        liveSink = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        tracks.removeAll()
        cuesByStream.removeAll()
        dedupKeys.removeAll()
        activeStreamIndex = nil
        liveSink = nil
        ingestedCount = 0
        duplicateCount = 0
        lastIngestLogCount = 0
        lock.unlock()
    }
}
