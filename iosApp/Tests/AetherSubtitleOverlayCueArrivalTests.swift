import AetherEngine
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// Aether decodes a sidecar after the track is picked. While playback is
/// paused no clock tick redraws the overlay, so the cues arriving must.
@MainActor
final class AetherSubtitleOverlayCueArrivalTests: XCTestCase {
    func testPrimaryCuesDecodedWhilePausedAreDrawn() async throws {
        try await assertDrawsCuesDecodedWhilePaused(
            select: { $0.selectSubtitleTrack(id: $1) },
            decoded: { !$0.engine.subtitleCues.isEmpty }
        )
    }

    func testSecondaryCuesDecodedWhilePausedAreDrawn() async throws {
        try await assertDrawsCuesDecodedWhilePaused(
            select: { $0.selectSecondarySubtitleTrack(id: $1) },
            decoded: { !$0.engine.secondarySubtitleCues.isEmpty }
        )
    }

    private func assertDrawsCuesDecodedWhilePaused(
        select: (AetherPlaybackController, Int64) -> Void,
        decoded: (AetherPlaybackController) -> Bool
    ) async throws {
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID().uuidString).srt")
        try "1\n00:00:00,000 --> 00:00:10,000\nSUBTITLE LINE\n\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let appID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
        controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url), appTrackID: appID)

        // Paused at 2 s: nothing the overlay is given changes from here on.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: ZStack {
            Color.black
            AetherSubtitleOverlay(
                engine: controller.engine,
                assSubtitles: controller.assSubtitles,
                cueHold: controller.cueHold,
                sourceTime: 2,
                primaryUsesMovieTimeline: true,
                secondaryUsesMovieTimeline: true,
                livePrimaryCues: [],
                liveSecondaryCues: [],
                appearance: .default,
                subtitleSyncMs: 0
            )
        })
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(whitePixels(in: window), 0, "no track is showing yet")

        select(controller, appID)
        let decodeDeadline = ContinuousClock.now + .seconds(5)
        while !decoded(controller), ContinuousClock.now < decodeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(decoded(controller), "Aether decodes the sidecar")

        let drawDeadline = ContinuousClock.now + .seconds(1)
        while whitePixels(in: window) == 0, ContinuousClock.now < drawDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(whitePixels(in: window), 50, "the cue covering 2 s is drawn without a clock tick")
    }

    private func whitePixels(in window: UIWindow) -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 200 && pixels[$0 + 1] > 200 && pixels[$0 + 2] > 200
        }.count
    }
}
