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

    // MARK: - Fixtures

    private func version(intro: TimeRange?, recap: TimeRange?) throws -> FileVersion {
        var json: [String: Any] = ["file_id": 42]
        if let intro { json["intro"] = ["start": intro.start, "end": intro.end] }
        if let recap { json["recap"] = ["start": recap.start, "end": recap.end] }
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
