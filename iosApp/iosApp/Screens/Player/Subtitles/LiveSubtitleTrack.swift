import Foundation

/// App-owned, engine-neutral cue used by realtime AI subtitles.
///
/// Times are absolute Silo source seconds. Rendering filters these cues
/// against Aether's public source clock; no renderer-specific representation
/// leaks into the product layer.
struct LiveSubtitleCue: Equatable, Hashable, Sendable, Identifiable {
    let text: String
    let startMs: Int64
    let endMs: Int64

    var id: Self { self }
    var startTime: Double { Double(startMs) / 1_000 }
    var endTime: Double { Double(endMs) / 1_000 }
    var durationMs: Int64 { endMs - startMs }
}

/// Per-live-track normalization and deduplication.
struct LiveSubtitleTrack {
    private var seen: Set<LiveSubtitleCue> = []

    mutating func makeCue(start: Double, end: Double, text: String) -> LiveSubtitleCue? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        let startMs = Self.secondsToMilliseconds(max(0, start))
        let endMs = Self.secondsToMilliseconds(max(0, end))
        guard endMs > startMs else { return nil }
        let normalizedText = Self.normalizeText(text)
        guard !normalizedText.isEmpty else { return nil }

        let cue = LiveSubtitleCue(
            text: normalizedText,
            startMs: startMs,
            endMs: endMs
        )
        guard seen.insert(cue).inserted else { return nil }
        return cue
    }

    static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func secondsToMilliseconds(_ seconds: Double) -> Int64 {
        let value = (seconds * 1_000).rounded()
        guard value < Double(Int64.max) else { return Int64.max }
        return Int64(value)
    }
}
