//
//  LiveSubtitleTrack.swift
//  Continuum (iOS + tvOS)
//
//  Pure value-type conversion of a streamed AI subtitle cue
//  `(start, end, text)` (absolute media-time seconds) into the exact
//  libass `ass_process_chunk` event representation that the proven
//  embedded subtitle path already feeds successfully.
//
//  No libass import — fully unit-testable. The renderer's chunk-feed path
//  (`SubtitleRenderer.feedChunk` → `ass_process_chunk`) expects:
//
//    - `eventText`: the FFmpeg `rect.ass` *chunk* event body, which is
//      `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
//      Crucially this is NOT the full `Dialogue:` line — the Start/End
//      timestamps are passed separately as `startMs`/`durationMs`. (This
//      is why `SubtitleRenderer` disables `ass_set_check_readorder`: the
//      first field of the chunk *is* `ReadOrder`.)
//    - `startMs` / `durationMs`: absolute start and duration in whole
//      milliseconds.
//
//  The cue body escaping mirrors `VTTToASSConverter.translateCueBody`
//  exactly — the same `{`/`}`/`\` stripping and `\n`→`\N` mapping — so a
//  live AI cue renders identically to a sidecar/embedded cue.
//

import Foundation

/// A single converted live subtitle cue, ready to hand to
/// `SubtitleRenderer.feedChunk(slot:eventText:startMs:durationMs:)`.
struct LiveSubtitleCue: Equatable, Hashable {
    /// FFmpeg `rect.ass` chunk-event body:
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
    let eventText: String
    /// Absolute start time in whole milliseconds.
    let startMs: Int64
    /// Event duration in whole milliseconds (clamped to >= 0).
    let durationMs: Int64

    /// Convenience: absolute end time in whole milliseconds.
    var endMs: Int64 { startMs + durationMs }
}

/// Stateful converter that turns streamed AI cues into libass chunk
/// events. Holds a monotonic `ReadOrder` counter (libass parses but, with
/// readorder-dedup disabled in the renderer, does not act on it) and a
/// dedupe set keyed by `(startMs, endMs, text)` so a re-delivered cue
/// (the live websocket can resend on reconnect) is fed at most once.
///
/// Value semantics: a copy carries its own counter + dedupe state. The
/// owning session keeps a single instance per live slot.
struct LiveSubtitleTrack {

    /// Monotonic ReadOrder fed as the first chunk field. Each accepted cue
    /// increments it. Starts at 0 to match FFmpeg's per-packet ordering.
    private var nextReadOrder: Int = 0

    /// Cues already emitted, keyed by their identity. Prevents duplicate
    /// feeds when the upstream resends a cue.
    private var seen: Set<DedupeKey> = []

    init() {}

    private struct DedupeKey: Hashable {
        let startMs: Int64
        let endMs: Int64
        let text: String
    }

    /// Convert a streamed cue into a `LiveSubtitleCue`, or `nil` if it is
    /// a duplicate of one already produced by this converter.
    ///
    /// - Parameters:
    ///   - start: absolute cue start in media-time seconds.
    ///   - end: absolute cue end in media-time seconds.
    ///   - text: cue text. May contain `\n` line breaks and arbitrary
    ///     characters; escaped to ASS here.
    /// - Returns: the converted cue, or `nil` when it duplicates a prior
    ///   `(startMs, endMs, escapedText)`.
    mutating func makeCue(start: Double, end: Double, text: String) -> LiveSubtitleCue? {
        let startMs = Self.secondsToMs(start)
        // Clamp end to be no earlier than start so duration never goes
        // negative on out-of-order or malformed payloads.
        let rawEndMs = Self.secondsToMs(end)
        let endMs = max(startMs, rawEndMs)
        let durationMs = endMs - startMs

        let escaped = Self.escapeCueText(text)

        let key = DedupeKey(startMs: startMs, endMs: endMs, text: escaped)
        if seen.contains(key) { return nil }
        seen.insert(key)

        let readOrder = nextReadOrder
        nextReadOrder += 1

        let eventText = Self.makeEventBody(readOrder: readOrder, escapedText: escaped)
        return LiveSubtitleCue(eventText: eventText, startMs: startMs, durationMs: durationMs)
    }

    // MARK: - Pure helpers (static so they can be unit-tested directly)

    /// Convert media-time seconds to whole milliseconds, rounding to the
    /// nearest ms and clamping negatives to 0. Matches the embedded
    /// decode path's `Int64(seconds * 1000.0)` intent while rounding
    /// rather than truncating for sub-ms accuracy.
    static func secondsToMs(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let ms = (seconds * 1000.0).rounded()
        if ms <= 0 { return 0 }
        return Int64(ms)
    }

    /// Build the FFmpeg `rect.ass` chunk-event body for a cue:
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
    ///
    /// Layer 0, Style `Default` (the style defined by the synthetic
    /// header the live track is created with), empty Name, zero margins,
    /// empty Effect — identical in shape to what FFmpeg emits for text
    /// subtitle codecs.
    static func makeEventBody(readOrder: Int, escapedText: String) -> String {
        "\(readOrder),0,Default,,0,0,0,,\(escapedText)"
    }

    /// Escape cue text to ASS-safe inline content. Mirrors
    /// `VTTToASSConverter.translateCueBody`'s character handling so live
    /// cues render identically to sidecar cues:
    ///   - `\n` (and `\r\n` / `\r`) become the ASS hard break `\N`.
    ///   - Literal `{` / `}` are dropped (they would open a rogue ASS
    ///     override block — there is no safe literal escape).
    ///   - Literal `\` is dropped (not used for line breaks in source
    ///     text; left raw it would be parsed as an ASS escape).
    ///   - Leading/trailing whitespace and newlines are trimmed.
    static func escapeCueText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        // Normalise line endings to `\n` first so multi-line handling is
        // uniform regardless of the source's newline convention. Done
        // unconditionally because Swift collapses a CRLF into a single
        // `\r\n` grapheme — iterating character-by-character would never
        // match a bare `"\n"` case for CRLF, so the replacements must run
        // up front. `replacingOccurrences` matches literal scalars, so it
        // splits the CRLF grapheme correctly.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var out = String()
        out.reserveCapacity(normalised.count)
        for ch in normalised {
            switch ch {
            case "{", "}":
                // No safe ASS escape for literal braces; drop them to
                // avoid opening a rogue override block.
                continue
            case "\\":
                // Drop raw backslash so cue text can't inject ASS escapes.
                continue
            case "\n":
                out.append("\\N")
            default:
                out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
