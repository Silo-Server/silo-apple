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
        var viewport: CGSize?
    }

    private struct Harness: View {
        let presentation: Presentation
        let engine: AetherEngine
        var legacy = false
        var reduceMotion = true
        var nextUpModel: PlayerViewModel?

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
                            if presentation.preview, let nextUpModel {
                                PlayerNextUpScreen(viewModel: nextUpModel, onBack: {})
                            } else if presentation.preview && presentation.hasPreviewBounds {
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
            .frame(width: presentation.viewport?.width, height: presentation.viewport?.height)
            .transaction { $0.disablesAnimations = reduceMotion }
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
        var rotation = CGRect.zero
        var viewport = CGRect.zero
        var extrasAppeared = false
    }

    private struct MeasuredFramesKey: PreferenceKey {
        static var defaultValue: [String: CGRect] { [:] }
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func nextUpFixture() throws -> PlayerViewModel {
        let episode = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"synthetic-episode-b","seasonNumber":1,"episodeNumber":2,"title":"The next chapter"}"#.utf8
        ))
        let model = PlayerViewModel()
        model.nextUpEpisode = PlayerNextUpEpisode(episode: episode, seriesId: "synthetic-series", seriesTitle: "Playback regression fixture")
        model.nextUpCountdownSeconds = 5
        return model
    }

    func testMobileActionsStayBelowThePreviewAndFitBothOrientations() async throws {
        let model = try nextUpFixture()
        defer { model.cleanup() }
        for size in [CGSize(width: 568, height: 320), CGSize(width: 844, height: 390),
                     CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            let frames = MobileFrames()
            let layout = PlayerNextUpMobileLayout {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("mobile-layout")) } action: { frames.preview = $0 }
            } panel: { compact in
                // Measure the real production metadata/buttons.
                PlayerNextUpScreen(viewModel: model, onBack: {}).mobileNextUpPanel(compact: compact)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("mobile-layout")) } action: { frames.panel = $0 }
            } extras: {
                Color.gray.frame(height: 1000)
                    .onAppear { frames.extrasAppeared = true }
            }
            let viewport = layout
                .frame(width: size.width, height: size.height - MobilePlayerRotationControls.topClearance)
                .padding(.top, MobilePlayerRotationControls.topClearance)
            let window = makeWindow(viewport
                .coordinateSpace(name: "mobile-layout").ignoresSafeArea())
            defer { window.isHidden = true; window.rootViewController = nil }
            try await settle(window)
            print("Mobile layout \(size): preview=\(frames.preview), actions=\(frames.panel)")
            // Render the requested viewport, not the host simulator's fixed
            // window size (which would crop portrait/iPad proof images).
            let renderer = ImageRenderer(content: viewport
                .coordinateSpace(name: "mobile-layout").ignoresSafeArea())
            let snapshot = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "Next Up controls \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(frames.panel.height, 0)
            XCTAssertGreaterThanOrEqual(frames.panel.minY, MobilePlayerRotationControls.topClearance)
            XCTAssertLessThanOrEqual(frames.panel.maxY, size.height)
            XCTAssertLessThanOrEqual(frames.panel.maxX, size.width)
            XCTAssertGreaterThan(frames.panel.minY, frames.preview.maxY)
            XCTAssertGreaterThan(frames.preview.height, 30)
            XCTAssertLessThanOrEqual(frames.preview.width, 300)
            XCTAssertEqual(frames.preview.midX, frames.panel.midX, accuracy: 1)
            XCTAssertFalse(frames.extrasAppeared, "iOS must not mount an On Deck shelf")
        }
    }

    func testFullNextUpScreenFitsArtworkAndPopulatedOnDeckDataThroughRepeatedRotation() async throws {
        let model = try nextUpFixture()
        // A non-nil still exercises the complete background-artwork branch.
        // Empty URL paints its placeholder without contacting any server.
        let episode = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"synthetic-episode","seasonNumber":1,"episodeNumber":2,"title":"A longer episode title for a narrow screen","stillUrl":""}"#.utf8
        ))
        model.nextUpEpisode = PlayerNextUpEpisode(episode: episode, seriesId: "fixture", seriesTitle: "Synthetic series title")
        model.nextUpOnDeckItems = try (0..<8).map { index in
            let item = try JSONDecoder().decode(SectionItem.self, from: Data(
                "{\"contentId\":\"fixture-deck-\(index)\",\"type\":\"movie\",\"title\":\"On Deck fixture \(index)\"}".utf8
            ))
            return PlayerOnDeckItem(item: item)
        }
        let state = Presentation()
        state.viewport = CGSize(width: 390, height: 844)
        let frames = MobileFrames()
        let viewport = FullNextUpHarness(presentation: state, model: model)
            .overlayPreferenceValue(PlayerPreviewBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.preference(key: MeasuredFramesKey.self, value: [
                        "preview": anchors.bounds.map { proxy[$0] } ?? .zero,
                        "panel": anchors.actions.map { proxy[$0] } ?? .zero,
                        "viewport": CGRect(origin: .zero, size: proxy.size)
                    ])
                }
            }
            .onPreferenceChange(MeasuredFramesKey.self) { value in
                frames.preview = value["preview"] ?? .zero
                frames.panel = value["panel"] ?? .zero
                frames.viewport = value["viewport"] ?? .zero
            }
        let window = makeWindow(viewport)
        defer { window.isHidden = true; window.rootViewController = nil; model.cleanup() }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390),
                     CGSize(width: 568, height: 320), CGSize(width: 390, height: 844),
                     CGSize(width: 844, height: 390), CGSize(width: 1024, height: 768)] {
            state.viewport = size
            try await settle(window)
            XCTAssertGreaterThan(frames.preview.height, 30)
            XCTAssertGreaterThan(frames.panel.height, 0)
            XCTAssertGreaterThan(frames.panel.minY, frames.preview.maxY)
            XCTAssertGreaterThanOrEqual(frames.preview.minY, MobilePlayerRotationControls.topClearance)
            XCTAssertGreaterThanOrEqual(frames.panel.minX, 0)
            XCTAssertLessThanOrEqual(frames.panel.maxX, frames.viewport.width + 1)
            XCTAssertLessThanOrEqual(frames.panel.maxY, frames.viewport.height + 1)
            XCTAssertEqual(frames.preview.midX, frames.panel.midX, accuracy: 1)
            XCTAssertFalse(hasScrollView(in: window), "On Deck must not render on iOS")
        }
    }

    private struct FullNextUpHarness: View {
        let presentation: Presentation
        let model: PlayerViewModel
        var body: some View {
            PlayerNextUpScreen(viewModel: model, onBack: {})
                .frame(width: presentation.viewport?.width, height: presentation.viewport?.height)
        }
    }

    private func hasScrollView(in view: UIView) -> Bool {
        view is UIScrollView || view.subviews.contains { hasScrollView(in: $0) }
    }

    func testPlayerGlassButtonsMatchTheDetailControlSize() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let frames = MobileFrames()
            let viewport = HStack {
                Button {} label: {
                    Image(systemName: "xmark").frame(width: ContinuumTheme.topBarIconHitSize)
                }
                .buttonStyle(MobilePlayerGlassButtonStyle())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("button-sizing")) } action: { frames.preview = $0 }
                Button {} label: {
                    Label("Audio & Subtitles", systemImage: "captions.bubble").padding(.horizontal, 12)
                }
                .buttonStyle(MobilePlayerGlassButtonStyle())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("button-sizing")) } action: { frames.panel = $0 }
                Menu { Button("Auto") {} } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.button)
                    .buttonStyle(MobilePlayerGlassButtonStyle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("button-sizing")) } action: { frames.rotation = $0 }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "button-sizing")
            let window = makeWindow(viewport)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await settle(window)
            XCTAssertEqual(frames.preview.width, 44, accuracy: 0.5)
            for frame in [frames.preview, frames.panel, frames.rotation] {
                XCTAssertEqual(frame.height, ContinuumTheme.topBarIconHitSize, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frame.width, ContinuumTheme.topBarIconHitSize)
            }
        }
    }

    func testPersistentRotationPillKeepsItsSizeAndTopRightPosition() async throws {
        XCTAssertNotNil(UIImage(systemName: "rectangle.landscape.rotate"))
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390),
                     CGSize(width: 568, height: 320)] {
            let frames = MobileFrames()
            let viewport = Color.black
                .overlay(alignment: .topTrailing) {
                    MobilePlayerRotationControls(orientationCoordinator: .shared, isVisible: true)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("rotation-layout"))
                        } action: { frames.rotation = $0 }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }
                .frame(width: size.width, height: size.height)
                .coordinateSpace(name: "rotation-layout")
                .ignoresSafeArea()
            let window = makeWindow(viewport)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await settle(window)
            XCTAssertEqual(frames.rotation.width, MobilePlayerRotationControls.width, accuracy: 1)
            XCTAssertEqual(frames.rotation.height, MobilePlayerRotationControls.height, accuracy: 1)
            XCTAssertEqual(frames.rotation.maxX, size.width - 16, accuracy: 1)
            XCTAssertEqual(frames.rotation.minY, 16, accuracy: 1)
            let renderer = ImageRenderer(content: viewport)
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "Persistent rotation controls \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
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
        let model = try nextUpFixture()
        let window = makeWindow(Harness(presentation: presentation, engine: engine, reduceMotion: false, nextUpModel: model))
        defer { window.isHidden = true; window.rootViewController = nil; engine.stop(); model.cleanup() }
        try await settle(window)
        let surface = try XCTUnwrap(surfaces(in: window).first)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v3_h264_aac", withExtension: "mp4"))
        // Hosted CI simulators report no VideoToolbox hardware decoder and
        // the normal probe chooses software. Use the native URL route to
        // exercise AVPlayer/layer retention with the same local MP4 fixture.
        var options = LoadOptions()
        options.nativeRemoteHLS = true
        try await engine.load(url: url, options: options)
        engine.play()
        let player = try XCTUnwrap(engine.currentAVPlayer)
        let item = try XCTUnwrap(player.currentItem)
        let layer = try XCTUnwrap(surface.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        let deadline = ContinuousClock.now + .seconds(15)
        while !layer.isReadyForDisplay && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(layer.isReadyForDisplay, "The synthetic video must actually have a picture before expansion")
        func attachFrame(_ name: String) {
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachFrame("Before expansion - playing synthetic preview")
        let position = player.currentTime().seconds
        var itemChanges = 0
        let observation = player.publisher(for: \.currentItem, options: [.new]).sink { _ in itemChanges += 1 }
        defer { observation.cancel() }
        // Resize the actual playing Next Up screen before expanding it, not
        // just an isolated panel. The preview must remain the same ready layer.
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390),
                     CGSize(width: 390, height: 844)] {
            presentation.viewport = size
            try await settle(window)
            XCTAssertTrue(surfaces(in: window).first === surface)
            XCTAssertTrue(engine.currentAVPlayer === player)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertTrue(layer.superlayer === surface.layer)
            XCTAssertTrue(layer.isReadyForDisplay)
            XCTAssertGreaterThan(surface.bounds.height, 30)
            XCTAssertEqual(itemChanges, 0)
        }
        presentation.viewport = nil
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
        attachFrame("After expansion - same synthetic video item")

        // The rotation pill changes scene geometry, not playback. Exercise
        // both resulting viewport shapes on the live native video surface.
        // Actual UIKit rotation/button delivery is checked interactively.
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let previousPosition = player.currentTime().seconds
            presentation.viewport = size
            try await settle(window)
            XCTAssertTrue(surfaces(in: window).first === surface)
            XCTAssertTrue(engine.currentAVPlayer === player)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertTrue(layer.superlayer === surface.layer)
            XCTAssertTrue(layer.isReadyForDisplay)
            // The surface deliberately paints through safe-area strips;
            // the simulator adds 14 points in this landscape-sized fixture.
            // Verify the orientation, not equality with the outer safe frame.
            if size.width > size.height {
                XCTAssertGreaterThan(surface.bounds.width, surface.bounds.height)
            } else {
                XCTAssertGreaterThan(surface.bounds.height, surface.bounds.width)
            }
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, previousPosition)
            XCTAssertEqual(itemChanges, 0)
        }
        presentation.viewport = nil
        try await settle(window)

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
        try await engine.load(url: url, options: options)
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
