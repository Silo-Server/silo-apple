//
//  PlaybackRealtimeSubtitleEvents.swift
//  Continuum (iOS + tvOS)
//
//  Typed decoders for the five AI subtitle live-streaming events that ride
//  the existing playback control websocket (Milestone 4). The generic
//  envelope parser (`parsePlaybackRealtimeInboundMessage`) already turns the
//  wire JSON into a `PlaybackRealtimePayload` tree; this file maps that loose
//  `[String: PlaybackRealtimeValue]` into a strongly-typed
//  ``PlaybackRealtimeSubtitleEvent`` the same way
//  `PlaybackRealtimeMarkersUpdatedPayload` does — keeping subtitle-specific
//  parsing out of the generic protocol file.
//
//  Wire shapes (see the design's "Realtime events" block):
//    subtitle_translation_started   { file_id, job_id, track_key, language, label, total_cues }
//    subtitle_translation_cues      { track_key, cues:[{start,end,text}], done, total }
//    subtitle_translation_completed { track_key, subtitle_id, language, label }
//    subtitle_translation_failed    { track_key, message }
//    subtitle_ready                 { file_id, subtitle_id, language, label }
//
//  `track_key = "ai-<jobID>"` joins the stream to the synthetic live track.
//
//  Cue `start`/`end` are **absolute media-time seconds**; `text` may carry
//  `\n` line breaks. They are kept as raw `Double` seconds + raw `String`
//  text here. The live-track sink normalizes and deduplicates them on Silo's
//  source timeline before the Aether-clocked overlay consumes them.
//

import Foundation

/// A single streamed cue, in **absolute media-time seconds**, exactly as the
/// server emits it. Millisecond normalization happens downstream in the sink.
struct PlaybackRealtimeSubtitleCue: Equatable {
    /// Absolute cue start in media-time seconds.
    let start: Double
    /// Absolute cue end in media-time seconds.
    let end: Double
    /// Cue text; may contain `\n` line breaks and remains normalized text in
    /// Silo's Aether-clocked presentation overlay.
    let text: String
}

/// A decoded AI subtitle live-streaming event.
///
/// `init?(name:payload:)` returns `nil` when the name isn't one of the five
/// subtitle events or the payload is missing a required field — the caller
/// treats `nil` as "not a subtitle event / malformed, ignore".
enum PlaybackRealtimeSubtitleEvent: Equatable {
    /// The server accepted a job and is about to stream cues for it.
    case started(Started)
    /// A batch of cues for an in-flight job.
    case cues(Cues)
    /// The job finished; the persisted subtitle is `subtitleId`.
    case completed(Completed)
    /// The job failed.
    case failed(Failed)
    /// A subtitle became available for the file (broadcast to any session of
    /// the file, not necessarily tied to a job this client started).
    case ready(Ready)

    struct Started: Equatable {
        let fileId: Int?
        let jobId: String?
        let trackKey: String
        let language: String?
        let label: String?
        let totalCues: Int?
    }

    struct Cues: Equatable {
        let trackKey: String
        let cues: [PlaybackRealtimeSubtitleCue]
        /// Server progress counter (`Done int` — cues produced so far), not a
        /// boolean flag. Carried through for diagnostics; the resume decision is
        /// gated on `!cues.isEmpty`, never on `done`.
        let done: Int?
        let total: Int?
    }

    struct Completed: Equatable {
        let trackKey: String
        let subtitleId: Int?
        let language: String?
        let label: String?
    }

    struct Failed: Equatable {
        let trackKey: String
        let message: String?
    }

    struct Ready: Equatable {
        let fileId: Int?
        let subtitleId: Int?
        let language: String?
        let label: String?
    }

    /// The `track_key` this event is scoped to, when it carries one. `ready`
    /// is file-scoped and has no track key.
    var trackKey: String? {
        switch self {
        case .started(let s): return s.trackKey
        case .cues(let c): return c.trackKey
        case .completed(let c): return c.trackKey
        case .failed(let f): return f.trackKey
        case .ready: return nil
        }
    }

    /// Build a typed subtitle event from a realtime event name + its loose
    /// payload tree. Returns `nil` for non-subtitle names or malformed
    /// payloads (a missing `track_key` on the track-scoped events).
    init?(name: PlaybackRealtimeEventName, payload: PlaybackRealtimePayload) {
        switch name {
        case .subtitleTranslationStarted:
            guard let trackKey = payload.string(forKeys: "track_key", "trackKey") else { return nil }
            self = .started(Started(
                fileId: payload.int(forKeys: "file_id", "fileId"),
                jobId: payload.string(forKeys: "job_id", "jobId"),
                trackKey: trackKey,
                language: payload.string(forKeys: "language", "lang"),
                label: payload.string(forKeys: "label"),
                totalCues: payload.int(forKeys: "total_cues", "totalCues")
            ))

        case .subtitleTranslationCues:
            guard let trackKey = payload.string(forKeys: "track_key", "trackKey") else { return nil }
            self = .cues(Cues(
                trackKey: trackKey,
                cues: payload.subtitleCues(forKey: "cues"),
                // `done` is the server's integer progress counter, not a bool.
                done: payload.int(forKeys: "done"),
                total: payload.int(forKeys: "total")
            ))

        case .subtitleTranslationCompleted:
            guard let trackKey = payload.string(forKeys: "track_key", "trackKey") else { return nil }
            self = .completed(Completed(
                trackKey: trackKey,
                subtitleId: payload.int(forKeys: "subtitle_id", "subtitleId"),
                language: payload.string(forKeys: "language", "lang"),
                label: payload.string(forKeys: "label")
            ))

        case .subtitleTranslationFailed:
            guard let trackKey = payload.string(forKeys: "track_key", "trackKey") else { return nil }
            self = .failed(Failed(
                trackKey: trackKey,
                message: payload.string(forKeys: "message", "error")
            ))

        case .subtitleReady:
            self = .ready(Ready(
                fileId: payload.int(forKeys: "file_id", "fileId"),
                subtitleId: payload.int(forKeys: "subtitle_id", "subtitleId"),
                language: payload.string(forKeys: "language", "lang"),
                label: payload.string(forKeys: "label")
            ))

        case .chapterThumbnailReady, .markersUpdated, .unknown:
            return nil
        }
    }
}

// MARK: - Payload helpers

extension Dictionary where Key == String, Value == PlaybackRealtimeValue {
    /// Decode the `cues` array (`[{start,end,text}]`) into typed cues, in
    /// absolute media-time seconds. Entries missing finite `start`/`end` are
    /// skipped; `text` defaults to empty (an empty cue is harmless — it is
    /// deduped/escaped to nothing downstream).
    func subtitleCues(forKey key: String) -> [PlaybackRealtimeSubtitleCue] {
        guard case .array(let entries)? = self[key] else { return [] }
        var out: [PlaybackRealtimeSubtitleCue] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            guard case .object(let object) = entry else { continue }
            guard case .number(let start)? = object["start"], start.isFinite,
                  case .number(let end)? = object["end"], end.isFinite else {
                continue
            }
            let text: String
            if case .string(let value)? = object["text"] {
                text = value
            } else {
                text = ""
            }
            out.append(PlaybackRealtimeSubtitleCue(start: start, end: end, text: text))
        }
        return out
    }
}
