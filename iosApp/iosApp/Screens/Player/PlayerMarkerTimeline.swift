import Foundation

/// Keeps each occurrence separate so skipping credits cannot cross a scene
/// between two credit sequences.
struct PlayerMarkerTimeline: Equatable {
    let segments: [PlaybackMarkerSegment]

    init(
        segments: [PlaybackMarkerSegment]? = nil,
        intro: TimeRange? = nil,
        credits: TimeRange? = nil,
        recap: TimeRange? = nil,
        preview: TimeRange? = nil
    ) {
        let candidates = segments ?? [
            ("intro", intro), ("credits", credits), ("recap", recap), ("preview", preview),
        ].compactMap { kind, range -> PlaybackMarkerSegment? in
            guard let range else { return nil }
            return PlaybackMarkerSegment(kind: kind, startSeconds: range.start, endSeconds: range.end)
        }
        let validSegments = candidates.filter {
            ["intro", "credits", "recap", "preview"].contains($0.kind) && $0.range != nil
        }
        self.segments = Set(validSegments).sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            if $0.endSeconds != $1.endSeconds { return $0.endSeconds < $1.endSeconds }
            return $0.kind < $1.kind
        }
    }

    func ranges(kind: String) -> [TimeRange] {
        segments.filter { $0.kind == kind }.compactMap(\.range)
    }

    func activeSegment(kind: String? = nil, at time: Double) -> PlaybackMarkerSegment? {
        guard time.isFinite else { return nil }
        return segments.first {
            (kind == nil || $0.kind == kind) && time >= $0.startSeconds && time < $0.endSeconds
        }
    }

    func applying(_ update: PlaybackRealtimeMarkersUpdatedPayload) -> PlayerMarkerTimeline {
        if let segments = update.markerSegments {
            return PlayerMarkerTimeline(segments: segments)
        }
        var segments = self.segments
        for (kind, rangeUpdate) in [
            ("intro", update.introUpdate), ("credits", update.creditsUpdate),
            ("recap", update.recapUpdate), ("preview", update.previewUpdate),
        ] {
            guard rangeUpdate != .unchanged else { continue }
            segments.removeAll { $0.kind == kind }
            if let range = rangeUpdate.range {
                segments.append(PlaybackMarkerSegment(
                    kind: kind, startSeconds: range.start, endSeconds: range.end
                ))
            }
        }
        return PlayerMarkerTimeline(segments: segments)
    }
}
