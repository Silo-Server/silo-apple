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

// MARK: - Baked-in letterbox

final class BakedLetterboxTests: XCTestCase {
    // The whole point: a 2.39:1 image inside a 1080p frame fills the screen,
    // so the picture's bottom edge is 12.9% above the frame's.
    func testPictureRectLiftsTheBottomEdgeOffTheBar() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let picture = VideoDisplayRect.pictureRect(
            in: frame,
            letterbox: BakedLetterbox(topFraction: 0.1287, bottomFraction: 0.1287),
            gravity: .resizeAspect
        )
        XCTAssertEqual(picture.minY, 1080 * 0.1287, accuracy: 0.5)
        XCTAssertEqual(picture.maxY, 1080 - 1080 * 0.1287, accuracy: 0.5)
        XCTAssertEqual(picture.minX, frame.minX, accuracy: 0.5)
        XCTAssertEqual(picture.width, frame.width, accuracy: 0.5)
    }

    // Fill/zoom crop the frame by an amount this code cannot see, so the
    // surviving bars are smaller than the fractions claim — insetting anyway
    // would put cues over the picture's own bottom rows.
    func testFillGravityIsLeftAlone() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let letterbox = BakedLetterbox(topFraction: 0.13, bottomFraction: 0.13)

        XCTAssertEqual(
            VideoDisplayRect.pictureRect(in: frame, letterbox: letterbox, gravity: .resizeAspectFill),
            frame
        )
        XCTAssertEqual(
            VideoDisplayRect.pictureRect(in: frame, letterbox: letterbox, gravity: .resize),
            frame
        )
    }

    func testNoMeasurementLeavesTheRectUntouched() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            VideoDisplayRect.pictureRect(in: frame, letterbox: .none, gravity: .resizeAspect),
            frame
        )
    }

    // A bad measurement must not be able to push subtitles into the middle of
    // the picture, and 0.5% is rounding noise rather than a bar.
    func testAbsurdAndNoiseMeasurementsAreRefused() {
        XCTAssertFalse(BakedLetterbox(topFraction: 0.45, bottomFraction: 0.45).isDetected)
        XCTAssertFalse(BakedLetterbox(topFraction: 0.005, bottomFraction: 0.005).isDetected)
        XCTAssertFalse(BakedLetterbox(topFraction: .nan, bottomFraction: .infinity).isDetected)
        XCTAssertTrue(BakedLetterbox(topFraction: 0.13, bottomFraction: 0.13).isDetected)
    }

    // Asymmetric bars are real (a 21:9 image offset in the frame); each edge
    // is taken on its own rather than assumed mirrored.
    func testEachEdgeIsIndependent() {
        let picture = VideoDisplayRect.pictureRect(
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            letterbox: BakedLetterbox(topFraction: 0.10, bottomFraction: 0.20),
            gravity: .resizeAspect
        )
        XCTAssertEqual(picture.minY, 100, accuracy: 0.5)
        XCTAssertEqual(picture.height, 700, accuracy: 0.5)
    }
}
