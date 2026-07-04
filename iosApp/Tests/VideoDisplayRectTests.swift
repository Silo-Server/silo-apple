import AVFoundation
import XCTest

@testable import Silo

final class VideoDisplayRectTests: XCTestCase {
    func testAspectFitLetterboxesWideVideoInPortraitBounds() {
        // 2.4:1 movie on an iPhone portrait canvas: full width, centered.
        let rect = VideoDisplayRect.compute(
            videoSize: CGSize(width: 1920, height: 800),
            bounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            gravity: .resizeAspect
        )
        XCTAssertEqual(rect.minX, 0, accuracy: 0.5)
        XCTAssertEqual(rect.width, 390, accuracy: 0.5)
        XCTAssertEqual(rect.height, 390 * 800 / 1920, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 422, accuracy: 0.5)
    }

    func testAspectFitPillarboxesTallVideoInLandscapeBounds() {
        let rect = VideoDisplayRect.compute(
            videoSize: CGSize(width: 1080, height: 1920),
            bounds: CGRect(x: 0, y: 0, width: 844, height: 390),
            gravity: .resizeAspect
        )
        XCTAssertEqual(rect.height, 390, accuracy: 0.5)
        XCTAssertEqual(rect.width, 390 * 1080 / 1920, accuracy: 0.5)
        XCTAssertEqual(rect.midX, 422, accuracy: 0.5)
    }

    func testUnknownVideoSizeFallsBackToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let rect = VideoDisplayRect.compute(
            videoSize: .zero,
            bounds: bounds,
            gravity: .resizeAspect
        )
        XCTAssertEqual(rect, bounds)
    }

    func testFillAndStretchGravityReturnBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let videoSize = CGSize(width: 1920, height: 800)
        XCTAssertEqual(
            VideoDisplayRect.compute(videoSize: videoSize, bounds: bounds, gravity: .resizeAspectFill),
            bounds
        )
        XCTAssertEqual(
            VideoDisplayRect.compute(videoSize: videoSize, bounds: bounds, gravity: .resize),
            bounds
        )
    }
}
