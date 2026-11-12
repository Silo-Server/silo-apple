import AVFoundation
import AetherEngine
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// Fill crops the picture to the surface. A subtitle with no authored
/// position has to stay on the part of the picture that is still on screen.
///
/// The software route is the one under test: there the overlay works the
/// picture's rectangle out itself, where the native route reads it from the
/// player layer, which reports its own bounds in Fill.
@MainActor
final class AetherSubtitleOverlayFillLayoutTests: XCTestCase {
    private static let longLine = "The quick brown fox jumps over the lazy dog near the river bank"

    /// The fixture filling a tall surface loses its left and right.
    func testFillKeepsALongLineInsideASurfaceNarrowerThanThePicture() async throws {
        let surface = CGSize(width: 300, height: 600)
        let drawn = try await drawnSubtitle(Self.longLine, surface: surface, gravity: .resizeAspectFill)
        XCTAssertGreaterThan(surface.height * drawn.pictureSize.width / drawn.pictureSize.height, surface.width,
                             "Fill crops the picture's sides here")
        XCTAssertGreaterThanOrEqual(drawn.text.minX, 10, "the line starts inside the surface")
        XCTAssertLessThanOrEqual(drawn.text.maxX, surface.width - 10, "the line ends inside the surface")
    }

    /// The same picture filling a wide surface loses its top and bottom.
    func testFillKeepsTheLineAboveTheBottomOfASurfaceWiderThanThePicture() async throws {
        try await assertFillKeepsTheLineAboveTheBottom(live: false)
    }

    /// Live cues take their own path through the overlay.
    func testFillKeepsALiveLineAboveTheBottomOfASurfaceWiderThanThePicture() async throws {
        try await assertFillKeepsTheLineAboveTheBottom(live: true)
    }

    /// Fit shows the whole picture, and the subtitle stays on it. A square
    /// surface letterboxes the fixture to a band across its middle.
    func testFitKeepsTheLineOnTheLetterboxedPicture() async throws {
        let surface = CGSize(width: 600, height: 600)
        let drawn = try await drawnSubtitle("SUBTITLE LINE", surface: surface, gravity: .resizeAspect)
        let pictureHeight = surface.width * drawn.pictureSize.height / drawn.pictureSize.width
        XCTAssertLessThan(pictureHeight, surface.height, "Fit letterboxes the picture here")
        XCTAssertGreaterThan(drawn.text.minY, surface.height / 2, "the line sits in the picture's lower half")
        XCTAssertLessThan(drawn.text.maxY, (surface.height + pictureHeight) / 2,
                          "the line stays above the picture's bottom edge")
    }

    private func assertFillKeepsTheLineAboveTheBottom(live: Bool) async throws {
        let surface = CGSize(width: 600, height: 200)
        let drawn = try await drawnSubtitle("SUBTITLE LINE", live: live, surface: surface, gravity: .resizeAspectFill)
        XCTAssertGreaterThan(surface.width * drawn.pictureSize.height / drawn.pictureSize.width, surface.height,
                             "Fill crops the picture's top and bottom here")
        XCTAssertLessThanOrEqual(drawn.text.maxY, surface.height - 10,
                                 "the line sits above the surface's bottom edge")
    }

    /// Plays the bundled video on a surface of the given size, shows one cue
    /// over it, and returns the picture's size with where the cue's text was
    /// drawn, in the surface's points. The cue comes from a sidecar, or is
    /// handed to the overlay as a live cue.
    private func drawnSubtitle(
        _ line: String,
        live: Bool = false,
        surface: CGSize,
        gravity: AVLayerVideoGravity
    ) async throws -> (pictureSize: CGSize, text: CGRect) {
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let engine = controller.engine
        let liveCues = LiveCues()

        let window = UIWindow(frame: CGRect(origin: .zero, size: surface))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(
            rootView: SurfaceWithSubtitles(controller: controller, liveCues: liveCues).ignoresSafeArea()
        )
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v3_h264_aac", withExtension: "mp4"))
        var options = LoadOptions()
        options.preferredDecodePath = .software
        engine.videoGravity = gravity
        try await engine.load(url: video, options: options)
        XCTAssertEqual(engine.videoGravity, gravity, "loading keeps the chosen gravity")
        let pictureDeadline = ContinuousClock.now + .seconds(15)
        while engine.softwareDisplaySize == nil, ContinuousClock.now < pictureDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pictureSize = try XCTUnwrap(engine.softwareDisplaySize, "the software route reports the picture's size")

        // The cue arrives after the picture's size is known, so the overlay
        // lays it out with that size in hand.
        let sidecar = FileManager.default.temporaryDirectory.appendingPathComponent("fill-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: sidecar) }
        if live {
            liveCues.cues = [LiveSubtitleCue(text: line, startMs: 0, endMs: 10_000)]
        } else {
            try "1\n00:00:00,000 --> 00:00:10,000\n\(line)\n\n".write(to: sidecar, atomically: true, encoding: .utf8)
            let appID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
            controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: sidecar), appTrackID: appID)
            controller.selectSubtitleTrack(id: appID)
            let decodeDeadline = ContinuousClock.now + .seconds(5)
            while engine.subtitleCues.isEmpty, ContinuousClock.now < decodeDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(engine.subtitleCues.isEmpty, "Aether decodes the sidecar")
        }

        let drawDeadline = ContinuousClock.now + .seconds(2)
        var text = lightPixelBounds(in: window)
        while text == nil, ContinuousClock.now < drawDeadline {
            try await Task.sleep(for: .milliseconds(50))
            text = lightPixelBounds(in: window)
        }
        return (pictureSize, try XCTUnwrap(text, "the subtitle is drawn on screen"))
    }

    /// The smallest rectangle around the window's near-white pixels, in
    /// points, or nil when it has none.
    private func lightPixelBounds(in window: UIWindow) -> CGRect? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                guard pixels[index] > 200, pixels[index + 1] > 200, pixels[index + 2] > 200 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Live cues the test publishes once the picture's size is known.
@MainActor
@Observable
private final class LiveCues {
    var cues: [LiveSubtitleCue] = []
}

/// The player's surface under its subtitle overlay.
private struct SurfaceWithSubtitles: View {
    let controller: AetherPlaybackController
    let liveCues: LiveCues

    var body: some View {
        ZStack {
            AetherPlayerSurface(engine: controller.engine)
            // Covers the picture, so the only light pixels are the cue's text.
            Color.black
            AetherSubtitleOverlay(
                engine: controller.engine,
                assSubtitles: controller.assSubtitles,
                cueHold: controller.cueHold,
                sourceTime: 2,
                primaryUsesMovieTimeline: true,
                secondaryUsesMovieTimeline: true,
                livePrimaryCues: liveCues.cues,
                liveSecondaryCues: [],
                appearance: .default,
                subtitleSyncMs: 0
            )
        }
    }
}
