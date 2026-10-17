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
            "https://plugin.test/art/poster/cover.r1.jpg?variant=card",
            "https://bucket.test/items/42/poster/w500.webp?X-Amz-Signature=abc",
            "https://bucket.test/items/42/covers/w500.r1.webp?X-Amz-Signature=abc",
            "file:///api/v2/artwork/items/42/poster/w500.r1.webp",
        ] {
            let foreign = try url(value)
            XCTAssertNil(ArtworkCacheKey.stableImageID(for: foreign), value)
            XCTAssertEqual(ImageRequest(artwork: foreign).imageID, foreign.absoluteString, value)
        }
    }

    /// S3 presigned and Cloudflare token URLs are re-issued as they age;
    /// the path names the bytes and the query only authorizes.
    func testObjectStorageArtworkIsKeyedByPath() throws {
        let key = "https://bucket.test/silo/items/42/backdrop/original.3f9a1c.webp"
        for (first, second) in [
            ("?X-Amz-Date=20261016T000000Z&X-Amz-Signature=abc", "?X-Amz-Date=20261017T000000Z&X-Amz-Signature=def"),
            ("?verify=1800000000-abc%3D", "?verify=1800002700-def%3D"),
            ("", "?verify=1800002700-def%3D"),
        ] {
            let today = try url(key + first)
            let tomorrow = try url(key + second)
            XCTAssertEqual(ArtworkCacheKey.stableImageID(for: today), key, first)
            XCTAssertEqual(ImageRequest(artwork: today).imageID, ImageRequest(artwork: tomorrow).imageID, first)
        }
        let subpath = "https://cdn.test/silo/api/v2/artwork/items/42/poster/w500.r1.webp"
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: try url(subpath + "?exp=1&sig=abc")), subpath)
        // A constant item the presigner adds stays; only the signature drops.
        XCTAssertEqual(
            ArtworkCacheKey.stableImageID(for: try url(key + "?X-Amz-Signature=abc&x-id=GetObject")),
            key + "?x-id=GetObject"
        )
    }

    /// A query item that may choose the bytes keeps two URLs apart, even on a
    /// ladder-shaped path outside Silo's own storage.
    func testRepresentationQueryStaysInTheIdentity() throws {
        let card = try url("https://plugin.test/art/poster/w500.r1.jpg?variant=card")
        let hero = try url("https://plugin.test/art/poster/w500.r1.jpg?variant=hero&verify=1-abc")
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: card), card.absoluteString)
        XCTAssertEqual(ArtworkCacheKey.stableImageID(for: hero), "https://plugin.test/art/poster/w500.r1.jpg?variant=hero")
        XCTAssertNotEqual(ImageRequest(artwork: card).imageID, ImageRequest(artwork: hero).imageID)
    }

    func testLadderVariantRuleMatchesTheServerKeyLayout() {
        XCTAssertTrue(ArtworkCacheKey.isRevisionedLadderVariant(path: "/items/1/poster/w1000.r1.webp"))
        XCTAssertTrue(ArtworkCacheKey.isRevisionedLadderVariant(path: "/items/1/logo/original.r1.webp"))
        XCTAssertFalse(ArtworkCacheKey.isRevisionedLadderVariant(path: "/items/1/logo/original.webp"))
        XCTAssertFalse(ArtworkCacheKey.isRevisionedLadderVariant(path: "/items/1/logo/large.r1.webp"))
        XCTAssertFalse(ArtworkCacheKey.isRevisionedLadderVariant(path: "/items/1/logo/w.r1.webp"))
        XCTAssertFalse(ArtworkCacheKey.isRevisionedLadderVariant(path: "/items/1/w500/w500.r1.webp"))
        XCTAssertFalse(ArtworkCacheKey.isRevisionedLadderVariant(path: "w500.r1.webp"))
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
