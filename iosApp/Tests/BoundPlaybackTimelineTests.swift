import Foundation
import XCTest
@testable import Silo

final class BoundPlaybackTimelineTests: XCTestCase {
    private func manifest(parts: String = #"[{"file_id":"43","offset_seconds":0,"duration_seconds":60},{"file_id":"42","offset_seconds":60,"duration_seconds":30}]"#) throws -> APIv2PlaybackManifest {
        let wire = """
        {"installation_id":"installation","timeline_id":"\(String(repeating: "a", count: 64))","media_item_id":"book","edition_id":"edition","duration_seconds":90,"parts":\(parts)}
        """
        return try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackManifest.self, from: Data(wire.utf8))
    }

    func testRetainsServerOrderAndMapsGlobalResumeWithoutDetailDurations() throws {
        let manifest = try manifest()
        try manifest.validate(installation: "installation", item: "book", anchor: 42)
        let detail = try HTTPClient.makeJSONDecoder().decode(ItemDetail.self,
            from: Data(#"{"content_id":"book","type":"audiobook","title":"Book","versions":[{"file_id":42,"duration":999},{"file_id":43,"duration":888}]}"#.utf8))
        let context = try AudiobookPlaybackContext(detail: detail, manifest: manifest)
        XCTAssertEqual(context.tracks.map(\.fileId), [43, 42])
        XCTAssertEqual(context.totalDurationSeconds, 90)
        XCTAssertEqual(AudioPlaybackTimeline.trackIndex(at: 60, tracks: context.tracks), 1)
        XCTAssertEqual(AudioPlaybackTimeline.localTime(for: 75, in: context.tracks[1]), 15)
        XCTAssertEqual(try manifest.binding(fileID: 42).partOffsetSeconds, 60)
    }

    func testRejectsGapsDuplicatesAndForeignManifestAuthority() throws {
        for parts in [
            #"[{"file_id":"42","offset_seconds":1,"duration_seconds":89}]"#,
            #"[{"file_id":"42","offset_seconds":0,"duration_seconds":60},{"file_id":"42","offset_seconds":60,"duration_seconds":30}]"#,
            #"[{"file_id":"42","offset_seconds":0,"duration_seconds":0}]"#
        ] {
            XCTAssertThrowsError(try manifest(parts: parts).validate(installation: "installation", item: "book", anchor: 42))
        }
        XCTAssertThrowsError(try manifest().validate(installation: "other", item: "book", anchor: 42))
        XCTAssertThrowsError(try manifest().validate(installation: "installation", item: "other", anchor: 42))
        XCTAssertThrowsError(try manifest().validate(installation: "installation", item: "book", anchor: 99))
    }

    func testReceiptPreservesGlobalZero() throws {
        let binding = try manifest().binding(fileID: 43)
        let sample = try JSONDecoder().decode(PlaybackSequencedSample.self,
            from: Data("{\"sequence\":1,\"position\":0,\"is_paused\":true,\"timeline_id\":\"\(binding.timelineId)\",\"item_position\":0}".utf8))
        try binding.validateReceipt(sample)
        XCTAssertEqual(sample.itemPosition, 0)
    }
}
