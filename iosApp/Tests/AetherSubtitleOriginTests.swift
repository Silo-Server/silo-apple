import Foundation
import XCTest
@testable import Silo

/// The trusted-origin rule that decides whether the Silo bearer travels with a
/// subtitle sidecar. Implicit ports are the interesting case: an explicit `:443`
/// on one side of the comparison used to strip the header from a same-origin
/// artifact, which Aether surfaces as a 401 on the sidecar only.
final class AetherSubtitleOriginTests: XCTestCase {
    private let headers = ["Authorization": "Bearer token"]

    func testImplicitHTTPSPortMatchesExplicitPort() {
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "https://silo.test:443/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(string: "https://silo.test/stream/v3/abc")!]
            ),
            headers
        )
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "https://silo.test/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(string: "https://silo.test:443/stream/v3/abc")!]
            ),
            headers
        )
    }

    func testImplicitHTTPPortMatchesExplicitPort() {
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "http://silo.test:80/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(string: "http://silo.test/stream/v3/abc")!]
            ),
            headers
        )
    }

    func testDifferentPortIsNotTrusted() {
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "https://silo.test:8443/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(string: "https://silo.test/stream/v3/abc")!]
            ),
            [:]
        )
    }

    func testDifferentSchemeOrHostIsNotTrusted() {
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "http://silo.test/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(string: "https://silo.test/stream/v3/abc")!]
            ),
            [:]
        )
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "https://cdn.silo.test/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(string: "https://silo.test/stream/v3/abc")!]
            ),
            [:]
        )
    }

    /// A `file://` media URL must never lend trust to a network sidecar, and a
    /// `file://` sidecar never carries headers at all.
    func testFileURLsCarryNoHeaders() {
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(fileURLWithPath: "/tmp/movie.en.srt"),
                trustedOriginURLs: [URL(string: "https://silo.test/stream/v3/abc")!]
            ),
            [:]
        )
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "https://silo.test/subtitles/1.vtt")!,
                trustedOriginURLs: [URL(fileURLWithPath: "/tmp/movie.mkv")]
            ),
            [:]
        )
    }

    /// The API origin is trusted alongside the media origin so
    /// `authorized_media_origins_v1` proxies do not strip the sidecar bearer.
    func testAPIOriginIsTrustedAlongsideProxyMediaOrigin() {
        XCTAssertEqual(
            AetherLoadSpec.subtitleRequestHeaders(
                headers,
                resourceURL: URL(string: "https://silo.test/api/v1/stream/s/subtitles/1.vtt")!,
                trustedOriginURLs: [
                    URL(string: "https://proxy.silo.test:8443/stream/v3/s")!,
                    URL(string: "https://silo.test:443")!,
                ]
            ),
            headers
        )
    }
}
