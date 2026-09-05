import AetherEngine
import CoreGraphics
import Foundation
import XCTest
@testable import Silo

final class ASSSubtitleRendererTests: XCTestCase {
    private let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,40,&H000000FF,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
    """
    private let size = CGSize(width: 320, height: 180)

    private func drawing(x: Int, y: Int, color: String = "0000FF") -> String {
        "0,0,Default,,0,0,0,,{\\an7\\pos(\(x),\(y))\\1c&H\(color)&\\p1}m 0 0 l 20 0 20 20 0 20"
    }

    func testOverlappingEventsWithRepeatedReadOrderKeepAuthoredPositionsAndColors() async throws {
        let renderer = ASSSubtitleRenderer()
        let events = [
            ASSSubtitleRenderer.Event(text: drawing(x: 20, y: 30), start: 1, end: 4),
            ASSSubtitleRenderer.Event(text: drawing(x: 140, y: 90, color: "00FF00"), start: 1, end: 4),
        ]
        let frame = try await renderer.render(header: header + "\0", fonts: [], events: events,
                                             revision: 1, time: 2, size: size, scale: 1)
        XCTAssertGreaterThan(pixel(frame, x: 25, y: 35).r, 200)
        XCTAssertGreaterThan(pixel(frame, x: 145, y: 95).g, 200)
        XCTAssertEqual(pixel(frame, x: 80, y: 80).a, 0)
        let duplicate = try await renderer.render(header: header, fonts: [], events: events + events,
                                                 revision: 2, time: 2, size: size, scale: 1)
        XCTAssertEqual(pixel(duplicate, x: 25, y: 35).r, pixel(frame, x: 25, y: 35).r)
    }

    func testAnimationAndBackwardSeekUseRequestedTime() async throws {
        let renderer = ASSSubtitleRenderer()
        let event = ASSSubtitleRenderer.Event(
            text: "0,0,Default,,0,0,0,,{\\an7\\move(20,30,220,30)\\p1}m 0 0 l 20 0 20 20 0 20",
            start: 0, end: 4)
        let early = try await renderer.render(header: header, fonts: [], events: [event],
                                             revision: 1, time: 0.5, size: size, scale: 1)
        let later = try await renderer.render(header: header, fonts: [], events: [event],
                                             revision: 1, time: 2.5, size: size, scale: 1)
        XCTAssertGreaterThan(pixel(early, x: 50, y: 35).a, 200)
        XCTAssertEqual(pixel(later, x: 50, y: 35).a, 0)
        XCTAssertGreaterThan(pixel(later, x: 150, y: 35).a, 200)
        let back = try await renderer.render(header: header, fonts: [], events: [event],
                                            revision: 1, time: 0.5, size: size, scale: 1)
        XCTAssertGreaterThan(pixel(back, x: 50, y: 35).a, 200)
    }

    func testExpiredAndReplacedCuesLeaveNoOldPixels() async throws {
        let renderer = ASSSubtitleRenderer()
        let old = ASSSubtitleRenderer.Event(text: drawing(x: 20, y: 30), start: 0, end: 2)
        _ = try await renderer.render(header: header, fonts: [], events: [old],
                                      revision: 1, time: 1, size: size, scale: 1)
        let expired = try await renderer.render(header: header, fonts: [], events: [old],
                                               revision: 1, time: 2, size: size, scale: 1)
        XCTAssertEqual(pixel(expired, x: 25, y: 35).a, 0)
        let replacement = ASSSubtitleRenderer.Event(text: drawing(x: 140, y: 90), start: 0, end: 2)
        let next = try await renderer.render(header: header, fonts: [], events: [replacement],
                                            revision: 2, time: 1, size: size, scale: 1)
        XCTAssertEqual(pixel(next, x: 25, y: 35).a, 0)
        XCTAssertGreaterThan(pixel(next, x: 145, y: 95).a, 200)
        let cleared = try await renderer.render(header: header, fonts: [], events: [],
                                               revision: 3, time: 1, size: size, scale: 1)
        XCTAssertEqual(pixel(cleared, x: 145, y: 95).a, 0)
    }

    func testAttachedFontActuallyShapesTheRenderedGlyph() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SiloASSFixture", withExtension: "ttf"))
        let font = FontAttachment(filename: "fixture.ttf", mimeType: "font/ttf", data: try Data(contentsOf: url))
        let event = ASSSubtitleRenderer.Event(text: "0,0,Default,,0,0,0,,{\\an7\\pos(20,30)\\fnSilo ASS Fixture}X", start: 0, end: 2)
        let renderer = ASSSubtitleRenderer()
        let frame = try await renderer.render(header: header, fonts: [font], events: [event],
                                             revision: 1, time: 1, size: size, scale: 1)
        // The fixture's X is a solid rectangle, unlike the system fallback X.
        XCTAssertGreaterThan(pixel(frame, x: 25, y: 45).a, 200)
        XCTAssertGreaterThan(pixel(frame, x: 50, y: 45).a, 200)
        let fallback = try await ASSSubtitleRenderer().render(header: header, fonts: [], events: [event],
                                                             revision: 1, time: 1, size: size, scale: 1)
        XCTAssertNotEqual(alphaCount(frame), alphaCount(fallback))
    }

    func testMovieAndEmbeddedTimingRetainDelaySignAcrossReanchor() {
        XCTAssertEqual(ASSSubtitleSession.renderTime(engineTime: 5, timelineOffset: 600,
                                                     isExternal: true, delaySeconds: 0.5), 604.5)
        XCTAssertEqual(ASSSubtitleSession.renderTime(engineTime: 5, timelineOffset: 600,
                                                     isExternal: false, delaySeconds: 0.5), 4.5)
    }

    func testFontBundleDecodingRejectsMalformedData() throws {
        let decoded = try ASSSubtitleSession.decodeFonts(Data("[{\"name\":\"font.ttf\",\"data\":\"AQID\"}]".utf8))
        XCTAssertEqual(decoded.first?.data, Data([1, 2, 3]))
        XCTAssertThrowsError(try ASSSubtitleSession.decodeFonts(Data("[{\"name\":\"font.ttf\",\"data\":\"bad base64\"}]".utf8)))
        XCTAssertThrowsError(try ASSSubtitleSession.decodeFonts(Data("[{\"name\":\"\",\"data\":\"AQID\"}]".utf8)))
        XCTAssertEqual(try ASSSubtitleSession.decodeFonts(Data("[]".utf8)), [])
    }

    @MainActor
    func testAetherEmbeddedAndSidecarASSReachRendererWithFontsAndTrackSwitching() async throws {
        let bundle = Bundle(for: Self.self)
        let movie = try XCTUnwrap(bundle.url(forResource: "authored", withExtension: "mkv"))
        let sidecar = try XCTUnwrap(bundle.url(forResource: "authored", withExtension: "ass"))
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false,
                                      panelIsInHDRMode: false)
        XCTAssertTrue(spec.options.preserveASSMarkup)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        XCTAssertEqual(controller.engine.fontAttachments.count, 1)
        controller.selectSubtitleTrack(id: 2)
        try await waitForASS(controller)
        await controller.assSubtitles.render(size: size, scale: 1, delaySeconds: 0)
        XCTAssertTrue(controller.assSubtitles.handlesCurrentTrack)
        XCTAssertGreaterThan(pixel(controller.assSubtitles.frame, x: 25, y: 45).a, 200)
        XCTAssertGreaterThan(pixel(controller.assSubtitles.frame, x: 145, y: 95).g, 200)

        controller.selectSubtitleTrack(id: 3)
        XCTAssertNil(controller.assSubtitles.frame, "Outgoing track must clear synchronously")
        try await waitForASS(controller)
        await controller.assSubtitles.render(size: size, scale: 1, delaySeconds: 0)
        XCTAssertEqual(pixel(controller.assSubtitles.frame, x: 25, y: 45).a, 0)
        XCTAssertGreaterThan(pixel(controller.assSubtitles.frame, x: 225, y: 95).g, 200)

        let externalID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 20)
        controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: sidecar), appTrackID: externalID)
        controller.selectSubtitleTrack(id: externalID)
        try await waitForASS(controller)
        XCTAssertNotNil(controller.engine.sidecarASSHeader)
        await controller.assSubtitles.render(size: size, scale: 1, delaySeconds: 0)
        XCTAssertGreaterThan(pixel(controller.assSubtitles.frame, x: 25, y: 45).a, 200)
        controller.selectSubtitleTrack(id: nil)
        XCTAssertNil(controller.assSubtitles.frame)
        XCTAssertFalse(controller.assSubtitles.handlesCurrentTrack)
    }

    @MainActor
    private func waitForASS(_ controller: AetherPlaybackController) async throws {
        for _ in 0..<100 {
            if !controller.engine.isLoadingSubtitles, !controller.engine.subtitleCues.isEmpty { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Aether did not publish ASS cues")
    }

    private actor PendingFonts {
        private var pending: [String: CheckedContinuation<[FontAttachment], Error>] = [:]
        func load(_ request: URLRequest) async throws -> [FontAttachment] {
            try await withCheckedThrowingContinuation { pending[request.url!.lastPathComponent] = $0 }
        }
        func contains(_ key: String) -> Bool { pending[key] != nil }
        func finish(_ key: String, error: Error? = nil) {
            let continuation = pending.removeValue(forKey: key)
            if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume(returning: []) }
        }
    }

    @MainActor
    func testSupersededFontDownloadCannotFailOrFinishNewSelection() async throws {
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        let pending = PendingFonts()
        let session = ASSSubtitleSession(engine: engine, fontLoader: { try await pending.load($0) })
        session.finishLoad()
        let first = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing-a.ass")))
        let second = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing-b.ass")))
        session.registerFontRequest(URLRequest(url: URL(string: "https://example.test/a")!), trackID: first.id)
        session.registerFontRequest(URLRequest(url: URL(string: "https://example.test/b")!), trackID: second.id)
        engine.selectSubtitleTrack(index: first.id)
        await session.render(size: size, scale: 1, delaySeconds: 0)
        for _ in 0..<100 where !(await pending.contains("a")) { await Task.yield() }
        let firstStarted = await pending.contains("a")
        XCTAssertTrue(firstStarted)
        engine.selectSubtitleTrack(index: second.id)
        await session.render(size: size, scale: 1, delaySeconds: 0)
        for _ in 0..<100 where !(await pending.contains("b")) { await Task.yield() }
        let secondStarted = await pending.contains("b")
        XCTAssertTrue(secondStarted)
        await pending.finish("a", error: URLError(.timedOut))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(session.failureMessage)
        XCTAssertTrue(session.isLoadingFonts, "Old completion must not dismiss the new track's loading state")
        await pending.finish("b")
        for _ in 0..<100 where session.isLoadingFonts { await Task.yield() }
        XCTAssertFalse(session.isLoadingFonts)
        XCTAssertNil(session.failureMessage)
        engine.clearSubtitle()
        XCTAssertNil(session.frame)
        XCTAssertFalse(session.isLoadingFonts)
    }

    private func pixel(_ frame: ASSSubtitleRenderer.Frame?, x: Int, y: Int) -> (r: UInt8, g: UInt8, a: UInt8) {
        guard let frame, let data = frame.image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        let px = x - Int(frame.rect.minX), py = y - Int(frame.rect.minY)
        guard px >= 0, py >= 0, px < frame.image.width, py < frame.image.height else { return (0, 0, 0) }
        let offset = py * frame.image.bytesPerRow + px * 4
        return (bytes[offset + 2], bytes[offset + 1], bytes[offset + 3])
    }

    private func alphaCount(_ frame: ASSSubtitleRenderer.Frame?) -> Int {
        guard let frame, let data = frame.image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        return stride(from: 3, to: CFDataGetLength(data), by: 4).filter { bytes[$0] > 0 }.count
    }
}
