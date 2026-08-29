import XCTest
@testable import Silo

final class PosterImageDiagnosticsTests: XCTestCase {
    func testArtworkPathKeepsOnlyClosedKindAndRung() throws {
        let url = try XCTUnwrap(URL(
            string: "https://private.example.test/library/Bury%20the%20Devil/poster/w780.private-hash.webp?X-Amz-Signature=secret"
        ))

        let path = PosterImageFailureClassifier.artworkPath(for: url)

        XCTAssertEqual(path, "/artwork/poster/w780")
        XCTAssertFalse(path.localizedCaseInsensitiveContains("bury"))
        XCTAssertFalse(path.contains("example"))
        XCTAssertFalse(path.contains("secret"))
    }

    func testUnknownImageURLFailsClosed() throws {
        let url = try XCTUnwrap(URL(
            string: "https://private.example.test/user-library/private-object.jpg?token=secret"
        ))

        XCTAssertEqual(
            PosterImageFailureClassifier.artworkPath(for: url),
            "/artwork/image/other"
        )
    }

    func testOriginalRungIsRecognized() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/backdrop/original/object.jpg"))

        XCTAssertEqual(
            PosterImageFailureClassifier.artworkPath(for: url),
            "/artwork/backdrop/original"
        )
    }

    func testCancellationIsNotReportedAsAnImageFailure() {
        XCTAssertNil(
            PosterImageFailureClassifier.transportErrorCode(for: .cancelled)
        )
    }
}
