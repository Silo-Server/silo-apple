import XCTest
import Nuke
@testable import Silo

final class ArtworkCacheKeyTests: XCTestCase {
    private let revisioned = "https://silo.test/api/v2/artwork/items/42/poster/w500.3f9a1c.webp"
    private let mutable = "https://silo.test/api/v2/artwork/libraries/7/poster/w500.webp"

    func testRevisionedArtworkDropsItsSignature() throws {
        let today = try url(revisioned + "?exp=1800000000&sig=abc")
        let tomorrow = try url(revisioned + "?exp=1800086400&sig=def")
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: today), revisioned)
        XCTAssertEqual(ImageRequest(artwork: today).imageID, ImageRequest(artwork: tomorrow).imageID)
        XCTAssertEqual(
            ImagePipeline.shared.cache.makeDataCacheKey(for: ImageRequest(artwork: today)),
            ImagePipeline.shared.cache.makeDataCacheKey(for: ImageRequest(artwork: tomorrow))
        )
    }

    func testMutableArtworkKeepsItsFullURL() throws {
        // Replaced in place on the server, so a new signature may mean new bytes.
        let signed = try url(mutable + "?exp=1800000000&sig=abc")
        XCTAssertNil(ArtworkCacheKey.stableImageID(for: signed))
        XCTAssertEqual(ImageRequest(artwork: signed).imageID, signed.absoluteString)
    }

    func testForeignArtworkKeepsItsFullURL() throws {
        for value in [
            "https://image.tmdb.org/t/p/w500/abc.r1.jpg?sig=abc",
            "https://cdn.test/silo/api/v2/artwork/items/42/poster/w500.r1.webp?exp=1&sig=abc",
            "file:///api/v2/artwork/items/42/poster/w500.r1.webp",
        ] {
            let foreign = try url(value)
            XCTAssertNil(ArtworkCacheKey.stableImageID(for: foreign), value)
            XCTAssertEqual(ImageRequest(artwork: foreign).imageID, foreign.absoluteString, value)
        }
    }

    func testOtherQueryItemsAreKeptInAStableOrder() throws {
        let first = try url(revisioned + "?size=large&exp=1&sig=abc&b=2")
        let second = try url(revisioned + "?b=2&sig=def&exp=2&size=large")
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: first), revisioned + "?b=2&size=large")
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: first), ArtworkCacheKey.stableImageID(for: second))
    }

    func testEncodedKeyPathIsPreserved() throws {
        let path = "https://silo.test/api/v2/artwork/items/a%20b/poster/w500.r1.webp"
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: try url(path + "?exp=1&sig=abc")), path)
    }

    func testRevisionRuleMatchesTheServer() {
        XCTAssertTrue(ArtworkCacheKey.isRevisioned(key: "items/1/poster/original.r1.webp"))
        XCTAssertTrue(ArtworkCacheKey.isRevisioned(key: "items/1/poster/w300.r1.jpg"))
        XCTAssertFalse(ArtworkCacheKey.isRevisioned(key: "items/1/poster/original.webp"))
        XCTAssertFalse(ArtworkCacheKey.isRevisioned(key: "items/1/poster/original"))
        XCTAssertFalse(ArtworkCacheKey.isRevisioned(key: "items/1/poster/w500..webp"))
    }

    func testReSignedURLFindsDecodesOfTheEarlierURL() throws {
        let previous = ImagePipeline.shared
        ImagePipeline.shared = ImagePipeline { $0.imageCache = ImageCache() }
        defer { ImagePipeline.shared = previous }

        let key = "https://silo.test/api/v2/artwork/items/\(UUID().uuidString)/poster/w500.r1.webp"
        let pointSize = CGSize(width: 176, height: 264)
        let yesterday = try XCTUnwrap(PosterImageCache.displayRequest(url: try url(key + "?exp=1&sig=a"), pointSize: pointSize, scale: 2))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 15)).image { _ in }
        ImagePipeline.shared.cache[yesterday] = ImageContainer(image: image)

        let pixelSize = try XCTUnwrap(PosterImageCache.decodePixelSize(forPointSize: pointSize, scale: 2))
        let served = try XCTUnwrap(PosterImageCache.cachedVariant(of: try url(key + "?exp=2&sig=b"), for: pixelSize))
        XCTAssertTrue(served.isSufficient)
    }

    private func url(_ value: String) throws -> URL {
        try XCTUnwrap(URL(string: value))
    }
}
