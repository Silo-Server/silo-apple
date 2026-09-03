import AetherEngine
import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import Silo

@MainActor
final class PlayerSurfaceLayoutTests: XCTestCase {
    @Observable final class Presentation {
        var preview = false
        var hasPreviewBounds = true
    }

    private struct Harness: View {
        let presentation: Presentation
        let engine: AetherEngine
        var legacy = false
        var reduceMotion = true

        var body: some View {
            Group {
                if legacy {
                    // Negative control: the two structural branches used by
                    // PlayerView before this fix really do recreate the host.
                    if presentation.preview {
                        VStack { AetherPlayerSurface(engine: engine).frame(width: 240, height: 135) }
                    } else {
                        AetherPlayerSurface(engine: engine)
                    }
                } else {
                    PlayerSurfaceLayout(isPreview: presentation.preview) {
                        AetherPlayerSurface(engine: engine)
                    } content: {
                        ZStack {
                            Color.black.ignoresSafeArea()
                            if presentation.preview && presentation.hasPreviewBounds {
                                Color.clear
                                    .frame(width: 240, height: 135)
                                    .anchorPreference(key: PlayerPreviewBoundsKey.self, value: .bounds) {
                                        .init(bounds: $0)
                                    }
                            }
                        }
                    }
                }
            }
            .environment(\.accessibilityReduceMotion, reduceMotion)
        }
    }

    private func surfaces(in view: UIView) -> [AetherPlayerView] {
        (view as? AetherPlayerView).map { [$0] } ?? view.subviews.flatMap { surfaces(in: $0) }
    }

    private func settle(_ window: UIWindow) async throws {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        window.layoutIfNeeded()
    }

    private func makeWindow<Content: View>(_ content: Content, attachToScene: Bool = true) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        if attachToScene {
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        }
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        return window
    }

    private final class MobileFrames {
        var preview = CGRect.zero
        var panel = CGRect.zero
    }

    func testMobileActionsStayVisibleBesideOrBelowTheSmallerPreview() async throws {
        for size in [CGSize(width: 568, height: 320), CGSize(width: 844, height: 390),
                     CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            let frames = MobileFrames()
            let layout = PlayerNextUpMobileLayout {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.preview = $0 }
            } panel: {
                // Reserve more than the compact metadata + two action rows
                // need, with a long On Deck shelf competing for space below.
                Color.blue.frame(height: 240)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.panel = $0 }
            } extras: {
                Color.gray.frame(height: 1000)
            }
            let window = makeWindow(layout, attachToScene: false)
            window.frame = CGRect(origin: .zero, size: size)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await settle(window)
            XCTAssertGreaterThan(frames.panel.height, 0)
            XCTAssertGreaterThanOrEqual(frames.panel.minY, 0)
            XCTAssertLessThanOrEqual(frames.panel.maxY, size.height)
            XCTAssertLessThanOrEqual(frames.panel.maxX, size.width)
            if size.width > size.height {
                XCTAssertGreaterThan(frames.panel.minX, frames.preview.maxX)
            } else {
                XCTAssertGreaterThan(frames.panel.minY, frames.preview.maxY)
                XCTAssertLessThanOrEqual(frames.preview.width, 260)
            }
        }
    }

    func testTwentyPreviewCyclesKeepOneActualAetherView() async throws {
        let engine = try AetherEngine()
        let presentation = Presentation()
        let window = makeWindow(Harness(presentation: presentation, engine: engine))
        defer { window.isHidden = true; window.rootViewController = nil; engine.stop() }
        try await settle(window)
        let original = try XCTUnwrap(surfaces(in: window).first)
        for _ in 0..<20 {
            presentation.preview = true
            try await settle(window)
            XCTAssertEqual(surfaces(in: window).count, 1)
            XCTAssertTrue(surfaces(in: window).first === original)
            XCTAssertEqual(original.bounds.width, 240, accuracy: 1)
            XCTAssertEqual(original.bounds.height, 135, accuracy: 1)
            presentation.preview = false
            try await settle(window)
            XCTAssertTrue(surfaces(in: window).first === original)
            XCTAssertGreaterThan(original.bounds.width, 240)
        }
        print("Preview lifecycle: 40 transitions, 1 Aether view, 0 replacements")
    }

    func testEarlyExpansionAndMissingPreviewGeometryKeepTheSurface() async throws {
        let engine = try AetherEngine()
        let presentation = Presentation()
        let window = makeWindow(Harness(presentation: presentation, engine: engine))
        defer { window.isHidden = true; window.rootViewController = nil; engine.stop() }
        try await settle(window)
        let original = try XCTUnwrap(surfaces(in: window).first)
        presentation.hasPreviewBounds = false
        presentation.preview = true
        try await settle(window)
        XCTAssertTrue(surfaces(in: window).first === original)
        presentation.preview = false
        presentation.preview = true
        presentation.preview = false
        try await settle(window)
        XCTAssertEqual(surfaces(in: window).count, 1)
        XCTAssertTrue(surfaces(in: window).first === original)
    }

    func testLegacyNegativeControlRecreatesTheVideoView() async throws {
        let engine = try AetherEngine()
        let presentation = Presentation()
        let window = makeWindow(Harness(presentation: presentation, engine: engine, legacy: true))
        defer { window.isHidden = true; window.rootViewController = nil; engine.stop() }
        try await settle(window)
        let original = try XCTUnwrap(surfaces(in: window).first)
        presentation.preview = true
        try await settle(window)
        XCTAssertFalse(surfaces(in: window).first === original)
    }

    func testPlayingPreviewExpandsWithoutReplacingItemOrLosingItsLayer() async throws {
        let engine = try AetherEngine()
        let presentation = Presentation()
        presentation.preview = true
        let window = makeWindow(Harness(presentation: presentation, engine: engine, reduceMotion: false))
        defer { window.isHidden = true; window.rootViewController = nil; engine.stop() }
        try await settle(window)
        let surface = try XCTUnwrap(surfaces(in: window).first)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v3_h264_aac", withExtension: "mp4"))
        try await engine.load(url: url)
        engine.play()
        let player = try XCTUnwrap(engine.currentAVPlayer)
        let item = try XCTUnwrap(player.currentItem)
        let layer = try XCTUnwrap(surface.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        let deadline = ContinuousClock.now + .seconds(15)
        while !layer.isReadyForDisplay && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(layer.isReadyForDisplay, "The synthetic video must actually have a picture before expansion")
        let position = player.currentTime().seconds
        var itemChanges = 0
        let observation = player.publisher(for: \.currentItem, options: [.new]).sink { _ in itemChanges += 1 }
        defer { observation.cancel() }
        presentation.preview = false
        try await settle(window)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(surfaces(in: window).first === surface)
        XCTAssertTrue(engine.currentAVPlayer === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertTrue(layer.superlayer === surface.layer)
        XCTAssertTrue(layer.isReadyForDisplay)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, position)
        XCTAssertEqual(itemChanges, 0)

        engine.pause()
        let pausedPosition = player.currentTime().seconds
        presentation.preview = true
        try await settle(window)
        presentation.preview = false
        try await settle(window)
        XCTAssertEqual(player.rate, 0, "Resizing must not resume a paused preview")
        XCTAssertEqual(player.currentTime().seconds, pausedPosition, accuracy: 0.1)
        XCTAssertEqual(itemChanges, 0)

        // Next pressed before a preview can lay out: one actual successor
        // load, using the same player/view/layer, with its own first-frame latch.
        var nilItems = 0
        let nilObservation = player.publisher(for: \.currentItem, options: [.new]).sink {
            if $0 == nil { nilItems += 1 }
        }
        defer { nilObservation.cancel() }
        presentation.hasPreviewBounds = false
        presentation.preview = true
        engine.prepareForItemReplacement()
        try await engine.load(url: url)
        presentation.hasPreviewBounds = true
        engine.play()
        let successorDeadline = ContinuousClock.now + .seconds(15)
        while !engine.hasFirstFrameReadyForDisplay && ContinuousClock.now < successorDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(engine.hasFirstFrameReadyForDisplay)
        XCTAssertTrue(layer.isReadyForDisplay)
        presentation.preview = false
        try await settle(window)
        XCTAssertTrue(surfaces(in: window).first === surface)
        XCTAssertTrue(engine.currentAVPlayer === player)
        XCTAssertTrue(layer.superlayer === surface.layer)
        XCTAssertFalse(player.currentItem === item)
        XCTAssertEqual(itemChanges, 1)
        XCTAssertEqual(nilItems, 0)
        print("Synthetic next episode: 1 item swap, 0 nil items, same view/player/layer, successor first frame ready")
    }
}
