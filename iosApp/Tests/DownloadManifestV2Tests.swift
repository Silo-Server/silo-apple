import Foundation
import XCTest
@testable import Silo

final class DownloadManifestV2Tests: XCTestCase {
    private func data() throws -> Data { try APIv2FixtureTestSupport.data(named: "download_manifest", bundleClass: Self.self) }

    func testManifestPreservesOfflineFieldsAndLocalRoundTrip() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2DownloadManifest.self, from: data())
        let value = try wire.validated(downloadID: "entry", contentID: "movie", episodeID: nil, mediaFileID: 42, revision: 2)
        XCTAssertEqual(value.manifestVersion, 3)
        XCTAssertEqual(value.title, "Synthetic film")
        XCTAssertEqual(value.subtitles?.first?.fetchUrl, "/api/v2/downloads/entry/subtitles/external:0")
        XCTAssertEqual(value.artworkUrls?.poster, "/api/v2/downloads/entry/artwork/poster")
        XCTAssertEqual(value.chapters?.count, 1)
        let restored = try JSONDecoder().decode(OfflineManifest.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertThrowsError(try wire.validated(downloadID: "other", contentID: "movie", episodeID: nil, mediaFileID: 42, revision: 2))
        XCTAssertThrowsError(try wire.validated(downloadID: "entry", contentID: "movie", episodeID: nil, mediaFileID: 42, revision: 3))
        XCTAssertThrowsError(try wire.validated(downloadID: "entry", contentID: "movie", episodeID: "episode", mediaFileID: 42, revision: 2))
    }

    func testV3RequiresCanonicalStringMediaIdentityAndKnownVersion() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        let decoder = HTTPClient.makeJSONDecoder()
        for raw: Any in [42, "01", "9223372036854775808", "opaque"] {
            object["media_file_id"] = raw
            XCTAssertThrowsError(try decoder.decode(APIv2DownloadManifest.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        object["media_file_id"] = "9007199254740993"
        let large = try decoder.decode(APIv2DownloadManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(large.value.mediaFileId, 9007199254740993)
        object["manifest_version"] = 2
        object["media_file_id"] = 42
        let legacy = try decoder.decode(OfflineManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.mediaFileId, 42)
        XCTAssertThrowsError(try decoder.decode(APIv2DownloadManifest.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testAssetsStayWithinExactDownloadAndPreserveReturnedQuery() throws {
        try APIv2DownloadManifest.validateAsset("/api/v2/downloads/entry/subtitles/external:0?signature=a%2Bb", downloadID: "entry", artwork: nil)
        for path in ["https://other.example/api/v2/downloads/entry/artwork/poster", "/api/v2/downloads/other/artwork/poster", "/api/v1/downloads/entry/artwork/poster"] {
            XCTAssertThrowsError(try APIv2DownloadManifest.validateAsset(path, downloadID: "entry", artwork: "poster"))
        }
        for suffix in ["../file", "%2E%2E", "%2fother", "ref#fragment"] {
            XCTAssertThrowsError(try APIv2DownloadManifest.validateAsset("/api/v2/downloads/entry/subtitles/" + suffix, downloadID: "entry", artwork: nil))
        }
        XCTAssertEqual(try APIv2DownloadManifest.fileURL(origin: "https://media.example/install", downloadID: "entry").absoluteString,
                       "https://media.example/install/api/v2/downloads/entry/file")
    }
}
