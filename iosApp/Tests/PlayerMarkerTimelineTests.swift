import XCTest
@testable import Silo

final class PlayerMarkerTimelineTests: XCTestCase {
    func testCreditsSkipStopsBeforeTheSceneBetweenOccurrences() {
        let timeline = PlayerMarkerTimeline(segments: [
            segment("credits", 1_700, 1_800),
            segment("credits", 1_500, 1_600),
        ])

        XCTAssertEqual(timeline.activeSegment(kind: "credits", at: 1_550)?.endSeconds, 1_600)
        XCTAssertNil(timeline.activeSegment(kind: "credits", at: 1_600))
        XCTAssertNil(timeline.activeSegment(kind: "credits", at: 1_650))
        XCTAssertEqual(timeline.activeSegment(kind: "credits", at: 1_750)?.endSeconds, 1_800)
        XCTAssertNil(timeline.activeSegment(kind: "credits", at: 1_800))
    }

    func testFullSnapshotOverridesLegacyAndKeepsAllSupportedKinds() {
        let intro = TimeRange(start: 10, end: 30)
        XCTAssertEqual(PlayerMarkerTimeline(intro: intro).ranges(kind: "intro"), [intro])
        XCTAssertTrue(PlayerMarkerTimeline(segments: [], intro: intro).segments.isEmpty)

        let timeline = PlayerMarkerTimeline(segments: [
            segment("intro", 40, 50), segment("intro", 10, 20),
            segment("recap", 0, 5), segment("preview", 80, 90),
            segment("future_kind", 5, 8), segment("credits", 100, 99),
        ], intro: intro)
        XCTAssertEqual(timeline.ranges(kind: "intro"), [TimeRange(start: 10, end: 20), TimeRange(start: 40, end: 50)])
        XCTAssertEqual(timeline.activeSegment(at: 2)?.kind, "recap")
        XCTAssertEqual(timeline.activeSegment(at: 85)?.kind, "preview")
        XCTAssertNil(timeline.activeSegment(at: 6))
        XCTAssertNil(timeline.activeSegment(at: .nan))
        XCTAssertTrue(timeline.ranges(kind: "credits").isEmpty)
    }

    func testLegacyPartialUpdatePreservesOtherOccurrencesAndFullSnapshotClears() throws {
        let timeline = PlayerMarkerTimeline(segments: [
            segment("intro", 10, 20), segment("intro", 40, 50),
            segment("recap", 0, 5),
        ])
        let partial = try XCTUnwrap(PlaybackRealtimeMarkersUpdatedPayload(payload: [
            "file_id": .number(42), "recap": .null,
        ]))
        let updated = timeline.applying(partial)
        XCTAssertEqual(updated.ranges(kind: "intro"), timeline.ranges(kind: "intro"))
        XCTAssertTrue(updated.ranges(kind: "recap").isEmpty)

        let cleared = try XCTUnwrap(PlaybackRealtimeMarkersUpdatedPayload(payload: [
            "file_id": .number(42), "marker_segments": .array([]),
        ]))
        XCTAssertTrue(updated.applying(cleared).segments.isEmpty)
    }

    private func segment(_ kind: String, _ start: Double, _ end: Double) -> PlaybackMarkerSegment {
        PlaybackMarkerSegment(kind: kind, startSeconds: start, endSeconds: end)
    }
}
