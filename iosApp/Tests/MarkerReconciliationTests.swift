import XCTest
@testable import Silo

/// A reconnect reconcile reads the file's markers while live
/// `markers_updated` events can still arrive. Neither may hide the other.
@MainActor
final class MarkerReconciliationTests: XCTestCase {
    private final class PendingReads {
        var continuations: [CheckedContinuation<WatchDetail, Error>] = []
    }

    func testEventDuringReconcileReschedulesInsteadOfDroppingOmittedMarkers() async throws {
        let player = PlayerViewModel()
        let reads = PendingReads()
        player.markerDetailLoader = { _, _ in
            try await withCheckedThrowingContinuation { reads.continuations.append($0) }
        }
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: try detail(intro: nil, recap: nil),
            version: try version(intro: nil, recap: nil)
        )

        // The socket reconnects after missing an intro update.
        player.reconcileMarkersAfterRealtimeConnect()
        try await waitForReads(reads, count: 1)

        // A recap-only event lands while that read is in flight.
        await player.handleRealtimeEvent(try markersEvent(#""recap": { "start": 0, "end": 30 }"#))
        XCTAssertEqual(player.recapRange, TimeRange(start: 0, end: 30))
        try await waitForReads(reads, count: 2)

        // The superseded read answers with a snapshot older than the event;
        // the replacement read carries both the missed intro and the recap.
        reads.continuations[0].resume(returning: try detail(intro: nil, recap: nil))
        reads.continuations[1].resume(
            returning: try detail(intro: TimeRange(start: 40, end: 90), recap: TimeRange(start: 0, end: 30))
        )
        try await waitUntil { player.introRange != nil }

        XCTAssertEqual(player.introRange, TimeRange(start: 40, end: 90))
        XCTAssertEqual(player.recapRange, TimeRange(start: 0, end: 30))
    }

    func testEventWithoutReconcileInFlightDoesNotStartARead() async throws {
        let player = PlayerViewModel()
        let reads = PendingReads()
        player.markerDetailLoader = { _, _ in
            try await withCheckedThrowingContinuation { reads.continuations.append($0) }
        }
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: try detail(intro: nil, recap: nil),
            version: try version(intro: nil, recap: nil)
        )

        await player.handleRealtimeEvent(try markersEvent(#""recap": { "start": 0, "end": 30 }"#))
        await Task.yield()

        XCTAssertEqual(player.recapRange, TimeRange(start: 0, end: 30))
        XCTAssertTrue(reads.continuations.isEmpty)
    }

    func testReplanToAnotherFileAdoptsThatFilesMarkers() throws {
        let player = PlayerViewModel()
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: try detail(intro: nil, recap: nil),
            version: try version(intro: nil, recap: nil)
        )

        // Another edition: its own markers replace the previous file's.
        XCTAssertNotNil(player.adoptReplannedVersion(
            try version(fileId: 43, intro: TimeRange(start: 50, end: 95), recap: TimeRange(start: 0, end: 20))
        ))
        XCTAssertEqual(player.introRange, TimeRange(start: 50, end: 95))
        XCTAssertEqual(player.recapRange, TimeRange(start: 0, end: 20))

        // Back to a file without markers: nothing of the other file's stays.
        XCTAssertNotNil(player.adoptReplannedVersion(try version(fileId: 42, intro: nil, recap: nil)))
        XCTAssertNil(player.introRange)
        XCTAssertNil(player.recapRange)
    }

    func testReplanToAnotherFileHandsBackMarkersFromAnEventDuringTheReplan() async throws {
        let player = PlayerViewModel()
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: try detail(intro: nil, recap: nil),
            version: try version(intro: nil, recap: nil)
        )
        // Lands on the original file while the replan request is in flight.
        await player.handleRealtimeEvent(try markersEvent(#""recap": { "start": 0, "end": 30 }"#))

        // A rollback must put back the event's ranges, not the pre-request ones.
        let replaced = player.adoptReplannedVersion(
            try version(fileId: 43, intro: TimeRange(start: 50, end: 95), recap: nil)
        )
        XCTAssertEqual(replaced?.ranges(.recap), [TimeRange(start: 0, end: 30)])
        XCTAssertEqual(replaced?.ranges(.intro), [])
    }

    func testReplanOnTheSameFileKeepsNewerEventMarkers() async throws {
        let player = PlayerViewModel()
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: try detail(intro: nil, recap: nil),
            version: try version(intro: nil, recap: nil)
        )
        await player.handleRealtimeEvent(try markersEvent(#""recap": { "start": 0, "end": 30 }"#))

        // The replan's snapshot predates the event.
        XCTAssertNil(player.adoptReplannedVersion(try version(intro: nil, recap: nil)))
        XCTAssertEqual(player.recapRange, TimeRange(start: 0, end: 30))
    }

    /// Nobody asked for an automatic skip, so it moves the playhead without
    /// bringing up the controls.
    func testAutomaticCreditsSkipKeepsHiddenControlsHidden() throws {
        // The player reads the shared settings. Put them back as they were,
        // down to a value that was never stored: the settings migration takes
        // a stored one for this device's own choice.
        let settings = PlayerSettings.shared
        let defaults = UserDefaults.standard
        let wasOn = settings.autoSkipCredits
        let storedBefore = Set(defaults.dictionaryRepresentation().keys)
        settings.adoptProfileAutoSkipCredits(true)
        let newlyStored = Set(defaults.dictionaryRepresentation().keys).subtracting(storedBefore)
        defer {
            settings.adoptProfileAutoSkipCredits(wasOn)
            newlyStored.forEach(defaults.removeObject(forKey:))
        }

        let player = PlayerViewModel()
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: try detail(intro: nil, recap: nil),
            version: try version(intro: nil, recap: nil)
        )
        player.isLoading = false
        player.currentTime = 1_300

        // Another file's markers arrive with the playhead inside its credits.
        player.adoptReplannedVersion(
            try version(fileId: 43, intro: nil, recap: nil, credits: TimeRange(start: 1_290, end: 1_350))
        )

        XCTAssertEqual(player.currentTime, 1_350)
        XCTAssertFalse(player.showControls)
    }

    // MARK: - Fixtures

    private func version(
        fileId: Int = 42, intro: TimeRange?, recap: TimeRange?, credits: TimeRange? = nil
    ) throws -> FileVersion {
        var json: [String: Any] = ["file_id": fileId]
        if let intro { json["intro"] = ["start": intro.start, "end": intro.end] }
        if let recap { json["recap"] = ["start": recap.start, "end": recap.end] }
        if let credits { json["credits"] = ["start": credits.start, "end": credits.end] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FileVersion.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func detail(intro: TimeRange?, recap: TimeRange?) throws -> WatchDetail {
        WatchDetail(
            contentId: "episode-1", type: "episode", title: "Episode", year: nil, overview: nil,
            versions: [try version(intro: intro, recap: recap)], subtitles: nil,
            intro: nil, credits: nil, userData: nil,
            seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
            effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
            effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
        )
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

    private func waitForReads(_ reads: PendingReads, count: Int) async throws {
        try await waitUntil { reads.continuations.count >= count }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met in time")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}
