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

    /// The timeline draws every occurrence of every kind, previews included,
    /// and overlapping occurrences each keep a band.
    func testBandsCoverEveryOccurrenceOfEveryKind() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("recap", 0, 100),
            segment("intro", 100, 200),
            segment("intro", 500, 600),
            segment("recap", 550, 650),
            segment("credits", 800, 850),
            segment("credits", 900, 950),
            segment("preview", 950, 1_000),
        ])

        XCTAssertEqual(timeline.bands(duration: 1_000), [
            .init(kind: .recap, start: 0, end: 0.1),
            .init(kind: .intro, start: 0.1, end: 0.2),
            .init(kind: .intro, start: 0.5, end: 0.6),
            .init(kind: .recap, start: 0.55, end: 0.65),
            .init(kind: .credits, start: 0.8, end: 0.85),
            .init(kind: .credits, start: 0.9, end: 0.95),
            .init(kind: .preview, start: 0.95, end: 1),
        ])
    }

    func testBandsClampToTheTimelineAndNeedADuration() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("intro", 50, 150),
            segment("credits", 900, 1_200),
            segment("preview", 1_100, 1_200),
        ])

        XCTAssertEqual(timeline.bands(duration: 1_000), [
            .init(kind: .intro, start: 0.05, end: 0.15),
            .init(kind: .credits, start: 0.9, end: 1),
        ])
        XCTAssertEqual(timeline.bands(duration: 0), [])
        XCTAssertEqual(timeline.bands(duration: .nan), [])
    }

    /// The server finishes an item at its end credits only when they start
    /// in the file's tail window, and a file spanning several episodes ends
    /// at the last one's.
    func testEndCreditsStartIsTheLastCreditsInTheTailWindow() {
        let timeline = PlayerMarkerTimeline(markerSegments: [
            segment("credits", 1_200, 1_300),
            segment("credits", 2_200, 2_400),
            segment("credits", 2_500, 2_590),
            segment("intro", 2_550, 2_560),
        ])
        XCTAssertEqual(timeline.endCreditsStart(duration: 2_600, isEpisode: true), 2_500)

        // An episode's window is the last 450 s or 40%; a movie's the last
        // 900 s or 25%.
        let credits = PlayerMarkerTimeline(markerSegments: [segment("credits", 6_500, 7_100)])
        XCTAssertNil(credits.endCreditsStart(duration: 7_200, isEpisode: true))
        XCTAssertEqual(credits.endCreditsStart(duration: 7_200, isEpisode: false), 6_500)
        let short = PlayerMarkerTimeline(markerSegments: [segment("credits", 700, 990)])
        XCTAssertEqual(short.endCreditsStart(duration: 1_000, isEpisode: true), 700)
        XCTAssertNil(short.endCreditsStart(duration: 1_000, isEpisode: false))

        XCTAssertNil(credits.endCreditsStart(duration: 0, isEpisode: false))
        XCTAssertNil(PlayerMarkerTimeline.empty.endCreditsStart(duration: 2_600, isEpisode: true))
    }

    private func segment(_ kind: String, _ start: Double, _ end: Double) -> PlaybackMarkerSegment {
        PlaybackMarkerSegment(kind: kind, startSeconds: start, endSeconds: end)
    }
}
