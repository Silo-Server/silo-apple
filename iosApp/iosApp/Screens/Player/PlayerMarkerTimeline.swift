import Foundation

/// Every marker occurrence of the playing file, kept apart so a skip acts on
/// the occurrence under the playhead and never spans the content between two
/// occurrences of the same kind (a scene between two credits sequences).
///
/// Built from `marker_segments` when the server sends it. Older responses
/// carry only the singular `intro` / `credits` / `recap` fields, which hold
/// the first occurrence of each kind.
struct PlayerMarkerTimeline: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case intro, credits, recap
    }

    struct Occurrence: Equatable, Sendable {
        let kind: Kind
        let range: TimeRange
    }

    static let empty = PlayerMarkerTimeline(occurrences: [])

    /// Valid occurrences in source-time order.
    let occurrences: [Occurrence]

    /// A present `markerSegments` replaces the singular fields, even when empty.
    init(
        markerSegments: [PlaybackMarkerSegment]?,
        intro: TimeRange? = nil,
        credits: TimeRange? = nil,
        recap: TimeRange? = nil
    ) {
        let candidates: [Occurrence]
        if let markerSegments {
            candidates = markerSegments.compactMap { segment in
                guard let kind = Kind(rawValue: segment.kind) else { return nil }
                return Occurrence(kind: kind, range: TimeRange(start: segment.startSeconds, end: segment.endSeconds))
            }
        } else {
            candidates = [(Kind.intro, intro), (.credits, credits), (.recap, recap)]
                .compactMap { kind, range in range.map { Occurrence(kind: kind, range: $0) } }
        }
        self.init(occurrences: candidates)
    }

    init(version: FileVersion) {
        self.init(
            markerSegments: version.markerSegments,
            intro: version.intro,
            credits: version.credits,
            recap: version.recap
        )
    }

    private init(occurrences: [Occurrence]) {
        self.occurrences = occurrences
            .filter { Self.isValid($0.range) }
            .sorted { ($0.range.start, $0.range.end) < ($1.range.start, $1.range.end) }
    }

    func ranges(_ kind: Kind) -> [TimeRange] {
        occurrences.filter { $0.kind == kind }.map(\.range)
    }

    /// The occurrence of `kind` that contains `time`. When ranges nest, the
    /// one that started last; skipping it can land inside the outer one,
    /// which is then active on its own.
    func activeOccurrence(_ kind: Kind, at time: Double) -> TimeRange? {
        guard time.isFinite else { return nil }
        return ranges(kind).last { time >= $0.start && time < $0.end }
    }

    /// The one range of `kind` the player tracks at `time`: the active
    /// occurrence, else the last one played (so an intro's undo and the
    /// credits latch keep their range after a skip), else the next one.
    func currentOccurrence(_ kind: Kind, at time: Double) -> TimeRange? {
        if let active = activeOccurrence(kind, at: time) { return active }
        let ranges = ranges(kind)
        guard time.isFinite else { return ranges.first }
        let played = ranges.filter { $0.start <= time }.max { $0.end < $1.end }
        return played ?? ranges.first
    }

    /// Whether `time` is in the last credits occurrence, the one a skip to
    /// the end of the file covers. True when the file has no credits.
    func isInFinalCredits(at time: Double) -> Bool {
        guard let finalCredits = ranges(.credits).last else { return true }
        return time >= finalCredits.start
    }

    /// A `markers_updated` event's view of the file. Its `marker_segments`
    /// is a full snapshot. Without one, each singular field it names replaces
    /// every occurrence of that kind, and the kinds it omits keep theirs.
    func applying(_ update: PlaybackRealtimeMarkersUpdatedPayload) -> PlayerMarkerTimeline {
        if let markerSegments = update.markerSegments {
            return PlayerMarkerTimeline(markerSegments: markerSegments)
        }
        var occurrences = self.occurrences
        for (kind, change) in [(Kind.intro, update.introUpdate), (.credits, update.creditsUpdate), (.recap, update.recapUpdate)]
        where change != .unchanged {
            occurrences.removeAll { $0.kind == kind }
            if let range = change.range {
                occurrences.append(Occurrence(kind: kind, range: range))
            }
        }
        return PlayerMarkerTimeline(occurrences: occurrences)
    }

    private static func isValid(_ range: TimeRange) -> Bool {
        range.start.isFinite && range.end.isFinite && range.start >= 0 && range.end > range.start
    }
}
