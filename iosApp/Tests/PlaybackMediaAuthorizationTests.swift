import Foundation
import XCTest
@testable import Silo

final class PlaybackMediaAuthorizationTests: XCTestCase {
    func testAPIMasterAuthorizesOnlyItsOwnSessionMedia() throws {
        let scope = try PlaybackMediaAuthorization.Scope(
            sourceURL: url("https://api.example/silo/api/v1/playback/transcode/session-one/master.m3u8"),
            serverURL: "https://api.example/silo/",
            sessionID: "session-one"
        )

        XCTAssertTrue(scope.allows(url("https://api.example/silo/api/v1/playback/transcode/session-one/master.m3u8")))
        XCTAssertTrue(scope.allows(url("https://api.example:443/silo/api/v1/playback/transcode/session-one/segment/init.mp4")))
        XCTAssertTrue(scope.allows(url("https://api.example/silo/api/v1/playback/transcode/session-one/segment/seg_00001.m4s")))
        XCTAssertFalse(scope.allows(url("https://api.example/silo/api/v1/playback/transcode/session-two/segment/seg_00001.m4s")))
        XCTAssertFalse(scope.allows(url("https://api.example/silo/api/v1/auth/refresh")))
        XCTAssertFalse(scope.allows(url("https://api.example/silo/api/v1/stream/session-one")))
        XCTAssertFalse(scope.allows(url("https://api.example/api/v1/playback/transcode/session-one/master.m3u8")))
    }

    func testProxyMasterNeverAuthorizesAnotherOriginOrRouteFamily() throws {
        let scope = try PlaybackMediaAuthorization.Scope(
            sourceURL: url("https://proxy.example:8443/stream/v3/session-one/master.m3u8"),
            serverURL: "https://api.example/silo",
            sessionID: "session-one"
        )
        XCTAssertTrue(scope.allows(url("https://PROXY.example:8443/stream/v3/session-one/segment/seg_00001.ts")))
        for value in [
            "https://proxy.example/stream/v3/session-one/segment/seg_00001.ts",
            "http://proxy.example:8443/stream/v3/session-one/segment/seg_00001.ts",
            "https://another-proxy.example:8443/stream/v3/session-one/segment/seg_00001.ts",
            "https://api.example/silo/api/v1/playback/transcode/session-one/master.m3u8",
            "https://proxy.example:8443/stream/v3/session-two/master.m3u8",
            "https://proxy.example:8443/stream/v3/session-one",
            "https://proxy.example:8443/api/v1/auth/refresh",
        ] {
            XCTAssertFalse(scope.allows(url(value)), value)
        }
    }

    func testProgressiveRoutesAuthorizeOnlyTheirPinnedPathAndSeekQuery() throws {
        for source in [
            "https://api.example/silo/api/v1/stream/session-one?seek=8",
            "https://proxy.example/stream/v3/session-one?seek=8",
        ] {
            let scope = try PlaybackMediaAuthorization.Scope(
                sourceURL: url(source), serverURL: "https://api.example/silo", sessionID: "session-one"
            )
            let path = String(source.split(separator: "?")[0])
            XCTAssertTrue(scope.allows(url(source)))
            XCTAssertTrue(scope.allows(url(path)))
            XCTAssertTrue(scope.allows(url(path + "?seek=12.5")))
            XCTAssertFalse(scope.allows(url(path + "/master.m3u8")))
            XCTAssertFalse(scope.allows(url(path + "/segment/seg_00001.m4s")))
            XCTAssertFalse(scope.allows(url(path + "/subtitles/0.vtt")))
        }
    }

    func testHTTPDeploymentKeepsItsExplicitOriginAndPort() throws {
        let source = url("http://api.example:8080/base/api/v1/playback/transcode/session-one/master.m3u8")
        let scope = try PlaybackMediaAuthorization.Scope(
            sourceURL: source, serverURL: "http://api.example:8080/base", sessionID: "session-one"
        )
        XCTAssertTrue(scope.allows(source))
        XCTAssertFalse(scope.allows(url("http://api.example/base/api/v1/playback/transcode/session-one/master.m3u8")))
        XCTAssertFalse(scope.allows(url("https://api.example:8080/base/api/v1/playback/transcode/session-one/master.m3u8")))
    }

    func testUnexpectedQueriesAndURLCredentialsAreDenied() throws {
        let master = "https://api.example/api/v1/playback/transcode/session-one/master.m3u8"
        let scope = try PlaybackMediaAuthorization.Scope(
            sourceURL: url(master), serverURL: "https://api.example", sessionID: "session-one"
        )
        XCTAssertTrue(scope.allows(url(master + "?seek=0")))
        for suffix in [
            "?token=secret", "?st=secret", "?file_id=42", "?seek=1&seek=2",
            "?seek=-1", "?seek=nan", "?seek=inf", "?seek=", "?seek", "?other=1", "#fragment",
        ] {
            XCTAssertFalse(scope.allows(url(master + suffix)), suffix)
        }
        XCTAssertFalse(scope.allows(url(master.replacingOccurrences(of: "api.example", with: "user:password@api.example"))))
    }

    func testEncodedTraversalAndMalformedSegmentPathsAreDenied() throws {
        let prefix = "https://api.example/api/v1/playback/transcode/session-one/"
        let scope = try PlaybackMediaAuthorization.Scope(
            sourceURL: url(prefix + "master.m3u8"), serverURL: "https://api.example", sessionID: "session-one"
        )
        for suffix in [
            "segment/../master.m3u8", "segment/./init.mp4", "segment/%2e%2e", "segment/%2Einit.mp4",
            "segment/%2fadmin", "segment/%5cadmin", "segment/%252e%252e", "segment/%252fadmin",
            "segment/%255cadmin", "segment/\\admin", "segment/", "segment//init.mp4",
            "segment/nested/init.mp4", "segment/init.mp4/downloaded", "segment/init.mp4/",
            "segment/%00init.mp4", "segment/%0d%0ainit.mp4", "segment/init.mp4;admin",
            "master.m3u8/", "segment",
        ] {
            XCTAssertFalse(scope.allows(url(prefix + suffix)), suffix)
        }
    }

    func testInvalidSourceCannotCreateAScope() {
        for source in [
            "https://api.example/api/v1/playback/transcode/session-two/master.m3u8",
            "https://api.example/api/v1/playback/transcode/session-one/segment/init.mp4",
            "https://api.example/api/v1/stream/session-one/subtitles/0.vtt",
            "https://api.example/api/v1/auth/refresh",
            "https://foreign.example/api/v1/playback/transcode/session-one/master.m3u8",
            "https://proxy.example/stream/v3/session-two/master.m3u8",
            "http://proxy.example/stream/v3/session-one/master.m3u8",
            "https://api.example/api/v1/playback/transcode/session-one/master.m3u8?token=secret",
            "https://user@api.example/api/v1/playback/transcode/session-one/master.m3u8",
            "https://api.example/api/v1/playback/transcode/session-one/master.m3u8#fragment",
        ] {
            XCTAssertThrowsError(try PlaybackMediaAuthorization.Scope(
                sourceURL: url(source), serverURL: "https://api.example", sessionID: "session-one"
            ), source)
        }
        XCTAssertThrowsError(try PlaybackMediaAuthorization.Scope(
            sourceURL: url("https://proxy.example/stream/v3/session-one"),
            serverURL: "https://api.example", sessionID: ""
        ))
    }

    func testBasePathAndSessionCannotContainTraversal() {
        for server in ["https://api.example/base/..", "https://api.example/%2e%2e", "https://api.example/%252fbase"] {
            XCTAssertThrowsError(try PlaybackMediaAuthorization.Scope(
                sourceURL: url("https://proxy.example/stream/v3/session-one/master.m3u8"),
                serverURL: server, sessionID: "session-one"
            ), server)
        }
        for session in ["..", ".", "session/one", "session\\one", "session%2fone"] {
            XCTAssertThrowsError(try PlaybackMediaAuthorization.Scope(
                sourceURL: url("https://proxy.example/stream/v3/\(session)/master.m3u8"),
                serverURL: "https://api.example", sessionID: session
            ), session)
        }
    }

    private func url(_ value: String) -> URL {
        URL(string: value)!
    }
}
