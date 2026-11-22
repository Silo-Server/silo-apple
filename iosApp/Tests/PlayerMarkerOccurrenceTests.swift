import XCTest
@testable import Silo

/// The player follows the playhead from one marker occurrence to the next, so
/// a second credits range gets its own Skip Credits and the scene between the
/// two ranges gets none.
@MainActor
final class PlayerMarkerOccurrenceTests: XCTestCase {
    private let twoCredits = """
    [{"kind": "recap", "start_seconds": 20, "end_seconds": 107},
     {"kind": "intro", "start_seconds": 108, "end_seconds": 220},
     {"kind": "credits", "start_seconds": 2975.5, "end_seconds": 3167.4},
     {"kind": "credits", "start_seconds": 3189, "end_seconds": 3300}]
    """

    func testCreditsWindowFollowsEachOccurrenceAndSkipsTheGap() throws {
        let player = try playerOnFile42()
        XCTAssertNotNil(player.adoptReplannedVersion(try version(fileId: 43, segments: twoCredits)))

        player.currentTime = 3_000
        XCTAssertEqual(player.creditsRange, TimeRange(start: 2_975.5, end: 3_167.4))
        XCTAssertTrue(player.isInCreditsWindow)

        player.currentTime = 3_175
        XCTAssertFalse(player.isInCreditsWindow)

        player.currentTime = 3_189
        XCTAssertEqual(player.creditsRange, TimeRange(start: 3_189, end: 3_300))
        XCTAssertTrue(player.isInCreditsWindow)

        player.currentTime = 60
        XCTAssertEqual(player.recapRange, TimeRange(start: 20, end: 107))
        XCTAssertTrue(player.isInRecapWindow)
        XCTAssertEqual(player.introRange, TimeRange(start: 108, end: 220))
    }

    func testRealtimeSnapshotReplacesEveryOccurrence() async throws {
        let player = try playerOnFile42()
        await player.handleRealtimeEvent(try markersEvent(#""marker_segments": \#(twoCredits)"#))
        player.currentTime = 3_250
        XCTAssertEqual(player.creditsRange, TimeRange(start: 3_189, end: 3_300))
        XCTAssertTrue(player.isInCreditsWindow)

        // A full snapshot without credits clears both ranges.
        await player.handleRealtimeEvent(try markersEvent(
            #""credits": null, "marker_segments": [{"kind": "intro", "start_seconds": 108, "end_seconds": 220}]"#
        ))
        XCTAssertNil(player.creditsRange)
        XCTAssertFalse(player.isInCreditsWindow)
        XCTAssertEqual(player.introRange, TimeRange(start: 108, end: 220))
    }

    /// An event from a server without collections names only the kinds it
    /// changed; the other kinds keep every occurrence they had.
    func testSingularRealtimeUpdateKeepsOtherKindsOccurrences() async throws {
        let player = try playerOnFile42()
        await player.handleRealtimeEvent(try markersEvent(#""marker_segments": \#(twoCredits)"#))
        await player.handleRealtimeEvent(try markersEvent(#""recap": { "start": 0, "end": 30 }"#))

        player.currentTime = 10
        XCTAssertEqual(player.recapRange, TimeRange(start: 0, end: 30))
        player.currentTime = 3_250
        XCTAssertEqual(player.creditsRange, TimeRange(start: 3_189, end: 3_300))
    }

    func testReplanRollbackRestoresEveryOccurrence() async throws {
        let player = try playerOnFile42()
        await player.handleRealtimeEvent(try markersEvent(#""marker_segments": \#(twoCredits)"#))
        let replaced = try XCTUnwrap(player.adoptReplannedVersion(try version(fileId: 43, segments: "[]")))
        player.currentTime = 3_250
        XCTAssertNil(player.creditsRange)

        player.restoreReplacedMarkers(replaced)
        XCTAssertEqual(player.creditsRange, TimeRange(start: 3_189, end: 3_300))
    }

    func testV2WatchFileVersionKeepsEveryOccurrence() throws {
        let json = """
        {"file_id": "43", "bitrate": 1, "codec_audio": "aac", "codec_video": "h264", "container": "mkv",
         "duration_seconds": 3300, "file_size": 1, "hdr": false, "resolution": "1080p",
         "credits": {"start_seconds": 2975.5, "end_seconds": 3167.4},
         "marker_segments": \(twoCredits)}
        """
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.WatchFileVersion.self, from: Data(json.utf8))
        let timeline = PlayerMarkerTimeline(version: try FileVersion(watch: wire))
        XCTAssertEqual(timeline.ranges(.credits), [
            TimeRange(start: 2_975.5, end: 3_167.4), TimeRange(start: 3_189, end: 3_300),
        ])
    }

    // MARK: - Fixtures

    private func playerOnFile42() throws -> PlayerViewModel {
        let player = PlayerViewModel()
        let version = try version(fileId: 42, segments: nil)
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: WatchDetail(
                contentId: "episode-1", type: "episode", title: "Episode", year: nil, overview: nil,
                versions: [version], subtitles: nil,
                intro: nil, credits: nil, userData: nil,
                seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
                effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
                effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
            ),
            version: version
        )
        return player
    }

    private func version(fileId: Int, segments: String?) throws -> FileVersion {
        var json = #"{"file_id": \#(fileId), "credits": {"start": 2975.5, "end": 3167.4}"#
        if let segments { json += #", "marker_segments": \#(segments)"# }
        json += "}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FileVersion.self, from: Data(json.utf8))
    }

    private func markersEvent(_ fields: String) throws -> PlaybackRealtimeEventEnvelope {
        let json = """
        { "type": "event", "session_id": "session-1", "name": "markers_updated",
          "payload": { "session_id": "session-1", "file_id": 42, \(fields) } }
        """
        guard case .event(let event)? = parsePlaybackRealtimeInboundMessage(Data(json.utf8)) else {
            XCTFail("markers_updated fixture did not parse")
            throw CancellationError()
        }
        return event
    }
}
