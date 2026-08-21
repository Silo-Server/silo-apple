import XCTest
@testable import Silo

final class StreamRequestAuthorizationTests: XCTestCase {
    func testSignedPlaybackURLDoesNotReceiveAccountAuthorizationHeader() {
        let url = URL(string: "https://example.test/api/v1/playback/transcode/session/master.m3u8?st=signed-stream-token")!

        XCTAssertFalse(PlayerViewModel.shouldAttachAccountAuthorization(to: url))
    }

    func testUnsignedPlaybackURLStillReceivesAccountAuthorizationHeader() {
        let url = URL(string: "https://example.test/api/v1/stream/session")!

        XCTAssertTrue(PlayerViewModel.shouldAttachAccountAuthorization(to: url))
    }

    func testFileURLDoesNotReceiveAccountAuthorizationHeader() {
        XCTAssertFalse(
            PlayerViewModel.shouldAttachAccountAuthorization(
                to: URL(fileURLWithPath: "/tmp/offline.mp4")
            )
        )
    }
}
