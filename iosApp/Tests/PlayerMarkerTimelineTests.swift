import XCTest
@testable import Silo

/// `marker_segments` may hold a kind more than once. Skip controls act on the
/// occurrence under the playhead and never span the content between two.
final class PlayerMarkerTimelineTests: XCTestCase {
    func testEachCreditsRangeIsItsOwnOccurrenceAndTheGapHasNone() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("recap", 20, 107),
            segment("intro", 108, 220),
            segment("credits", 2_975.5, 3_167.4),
            segment("credits", 3_189, 3_300),
        ])

        XCTAssertEqual(timeline.activeOccurrence(.credits, at: 3_000), TimeRange(start: 2_975.5, end: 3_167.4))
        XCTAssertNil(timeline.activeOccurrence(.credits, at: 3_167.4))
        XCTAssertNil(timeline.activeOccurrence(.credits, at: 3_180))
        XCTAssertEqual(timeline.activeOccurrence(.credits, at: 3_189), TimeRange(start: 3_189, end: 3_300))
        XCTAssertNil(timeline.activeOccurrence(.credits, at: 3_300))
        XCTAssertEqual(timeline.activeOccurrence(.recap, at: 20), TimeRange(start: 20, end: 107))
        XCTAssertEqual(timeline.activeOccurrence(.intro, at: 150), TimeRange(start: 108, end: 220))
    }

    /// The player keeps one range per kind for its latches and Next Up logic:
    /// the active occurrence, else the last one played, else the next one.
    /// With a single occurrence that is always the same range, as before.
    func testCurrentOccurrenceOutsideARangeIsTheLastPlayedElseTheNext() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("credits", 1_500, 1_600),
            segment("credits", 1_700, 1_800),
        ])

        XCTAssertEqual(timeline.currentOccurrence(.credits, at: 100), TimeRange(start: 1_500, end: 1_600))
        XCTAssertEqual(timeline.currentOccurrence(.credits, at: 1_650), TimeRange(start: 1_500, end: 1_600))
        XCTAssertEqual(timeline.currentOccurrence(.credits, at: 1_750), TimeRange(start: 1_700, end: 1_800))
        XCTAssertEqual(timeline.currentOccurrence(.credits, at: 1_900), TimeRange(start: 1_700, end: 1_800))
        XCTAssertNil(timeline.currentOccurrence(.intro, at: 1_750))
    }

    func testSingularFieldsApplyOnlyWhenTheCollectionIsAbsent() {
        let credits = TimeRange(start: 2_975.5, end: 3_167.4)
        let legacy = PlayerMarkerTimeline(markerSegments: nil, intro: TimeRange(start: 108, end: 220), credits: credits)
        XCTAssertEqual(legacy.activeOccurrence(.credits, at: 3_000), credits)
        XCTAssertEqual(legacy.activeOccurrence(.intro, at: 108), TimeRange(start: 108, end: 220))

        // An empty collection says the file has no markers; the singular
        // projections must not bring one back.
        let cleared = PlayerMarkerTimeline(markerSegments: [], credits: credits)
        XCTAssertNil(cleared.currentOccurrence(.credits, at: 3_000))

        let full = PlayerMarkerTimeline(
            markerSegments: [segment("credits", 2_975.5, 3_167.4), segment("credits", 3_189, 3_300)],
            credits: credits
        )
        XCTAssertEqual(full.activeOccurrence(.credits, at: 3_200), TimeRange(start: 3_189, end: 3_300))
    }

    func testUnsortedOverlappingAndInvalidSegments() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("credits", 1_700, 1_800),
            segment("credits", 1_500, 1_600),
            segment("credits", 1_550, 1_580),
            segment("credits", 900, 800),
            segment("credits", .nan, 50),
            segment("future_kind", 0, 10),
        ])

        XCTAssertEqual(timeline.activeOccurrence(.credits, at: 1_520), TimeRange(start: 1_500, end: 1_600))
        // Inside a nested range the innermost one is active; skipping it
        // lands back inside the outer one, which is then skipped on its own.
        XCTAssertEqual(timeline.activeOccurrence(.credits, at: 1_560), TimeRange(start: 1_550, end: 1_580))
        XCTAssertEqual(timeline.activeOccurrence(.credits, at: 1_580), TimeRange(start: 1_500, end: 1_600))
        XCTAssertEqual(timeline.activeOccurrence(.credits, at: 1_750), TimeRange(start: 1_700, end: 1_800))
        XCTAssertNil(timeline.activeOccurrence(.credits, at: 850))
        XCTAssertNil(timeline.activeOccurrence(.credits, at: .nan))
        XCTAssertEqual(timeline.currentOccurrence(.credits, at: 0), TimeRange(start: 1_500, end: 1_600))
    }

    /// After Skip Credits runs to the end, the item counts as finished only
    /// while the playhead stays in the final credits, not the scene before.
    func testFinalCreditsExcludeTheSceneBetweenOccurrences() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("credits", 2_975.5, 3_167.4),
            segment("credits", 3_189, 3_300),
        ])
        XCTAssertFalse(timeline.isInFinalCredits(at: 3_000))
        XCTAssertFalse(timeline.isInFinalCredits(at: 3_175))
        XCTAssertTrue(timeline.isInFinalCredits(at: 3_189))
        XCTAssertTrue(timeline.isInFinalCredits(at: 3_300))
        // Without credits markers there is nothing to leave.
        XCTAssertTrue(PlayerMarkerTimeline.empty.isInFinalCredits(at: 10))
    }

    private func segment(_ kind: String, _ start: Double, _ end: Double) -> PlaybackMarkerSegment {
        PlaybackMarkerSegment(kind: kind, startSeconds: start, endSeconds: end)
    }
}
