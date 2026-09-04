import XCTest
@testable import Silo

final class PlaybackTimelineMapperTests: XCTestCase {
    func testDirectTimelineUsesPlayerAxisWithoutOffset() throws {
        let mapper = try PlaybackTimelineMapper(validating: timeline(
            sourceStart: 321,
            playerStart: 321,
            canSeekAnywhere: true,
            seekRestoration: "player_position"
        ))

        XCTAssertEqual(mapper.aetherStartPosition, 321)
        XCTAssertEqual(mapper.sourcePosition(forPlayerTime: 400), 400)
        XCTAssertEqual(mapper.seekDisposition(forSourceTime: 12), .local(playerSeconds: 12))
    }

    func testCopyRemuxTimelineMapsPrerollAndRequiresReplan() throws {
        let mapper = try PlaybackTimelineMapper(validating: timeline(
            sourceStart: 1086.2,
            streamOrigin: 1085.501,
            playerStart: 0.699,
            offset: 1085.501,
            windowStart: 1085.501,
            canSeekAnywhere: false,
            seekRestoration: "source_position"
        ))

        XCTAssertEqual(mapper.aetherStartPosition, 0.699, accuracy: 0.000_001)
        XCTAssertEqual(mapper.sourcePosition(forPlayerTime: 0.699), 1086.2, accuracy: 0.000_001)
        XCTAssertEqual(mapper.playerPosition(forSourceTime: 1086.2), 0.699, accuracy: 0.000_001)
        XCTAssertEqual(mapper.seekDisposition(forSourceTime: 1200), .replan(sourceSeconds: 1200))
    }

    func testBackwardSeekBeforeTimelineOffsetReplansWithoutASeekWindow() throws {
        // A re-anchored transport that advertises no seek window still cannot
        // express any source position below its offset: player zero *is* the
        // offset. Clamping there would play the wrong moment silently.
        let mapper = try PlaybackTimelineMapper(validating: timeline(
            sourceStart: 1200,
            streamOrigin: 1000,
            playerStart: 200,
            offset: 1000,
            canSeekAnywhere: true,
            seekRestoration: "source_position"
        ))

        XCTAssertEqual(mapper.earliestLocalSourceSeconds, 1000)
        XCTAssertEqual(mapper.seekDisposition(forSourceTime: 60), .replan(sourceSeconds: 60))
        XCTAssertEqual(mapper.seekDisposition(forSourceTime: 0), .replan(sourceSeconds: 0))
        XCTAssertEqual(
            mapper.seekDisposition(forSourceTime: 1000),
            .local(playerSeconds: 0)
        )
        XCTAssertEqual(
            mapper.seekDisposition(forSourceTime: 1300),
            .local(playerSeconds: 300)
        )
    }

    func testArtifactTimingOriginMapsOntoActivePlayerAxis() throws {
        let mapper = try PlaybackTimelineMapper(validating: timeline(
            sourceStart: 42,
            streamOrigin: 40,
            playerStart: 2,
            offset: 40,
            canSeekAnywhere: false,
            seekRestoration: "source_position"
        ))

        XCTAssertEqual(
            mapper.playerPosition(forArtifactTime: 3.5, timingOriginSeconds: 40),
            3.5
        )
    }

    func testRejectsMalformedTimelineBeforeLoad() {
        XCTAssertThrowsError(try PlaybackTimelineMapper(validating: timeline(
            sourceStart: 10,
            playerStart: .nan,
            canSeekAnywhere: true,
            seekRestoration: "player_position"
        ))) { error in
            XCTAssertEqual(
                error as? PlaybackTimelineMapper.ValidationError,
                .nonFinite(field: "player_start_seconds")
            )
        }

        XCTAssertThrowsError(try PlaybackTimelineMapper(validating: timeline(
            sourceStart: 10,
            playerStart: 10,
            canSeekAnywhere: true,
            seekRestoration: "invented"
        )))
    }

    private func timeline(
        sourceStart: Double,
        streamOrigin: Double = 0,
        playerStart: Double,
        offset: Double = 0,
        windowStart: Double? = nil,
        windowEnd: Double? = nil,
        canSeekAnywhere: Bool,
        seekRestoration: String
    ) -> PlaybackV3Timeline {
        PlaybackV3Timeline(
            sourceStartSeconds: sourceStart,
            streamOriginSeconds: streamOrigin,
            playerStartSeconds: playerStart,
            timelineOffsetSeconds: offset,
            seekWindowStartSeconds: windowStart,
            seekWindowEndSeconds: windowEnd,
            canSeekAnywhere: canSeekAnywhere,
            seekRestoration: seekRestoration
        )
    }
}
