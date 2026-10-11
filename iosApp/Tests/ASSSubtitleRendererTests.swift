import AetherEngine
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SwiftLibass
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
    private let canvas = ASSSubtitleRenderer.Canvas(width: 320, height: 180)
    private let everything = -1_000.0...1_000.0

    private func drawing(x: Int, y: Int, color: String = "0000FF") -> String {
        "0,0,Default,,0,0,0,,{\\an7\\pos(\(x),\(y))\\1c&H\(color)&\\p1}m 0 0 l 20 0 20 20 0 20"
    }

    private func cue(_ id: Int, _ lines: [String], start: Double, end: Double) -> ASSSubtitleRenderer.Cue {
        ASSSubtitleRenderer.Cue(id: id, start: start, end: end, lines: lines)
    }

    private func frame(_ output: ASSSubtitleRenderer.Output) -> CVPixelBuffer? {
        if case .frame(let buffer) = output { return buffer }
        return nil
    }

    // MARK: - Renderer

    func testOverlappingEventsWithRepeatedReadOrderKeepAuthoredPositionsAndColors() throws {
        let renderer = ASSSubtitleRenderer()
        let cues = [cue(1, [drawing(x: 20, y: 30), drawing(x: 140, y: 90, color: "00FF00")], start: 1, end: 4)]
        _ = try renderer.update(header: header + "\0", fonts: [], cues: cues, window: everything)
        let first = frame(renderer.render(time: 2, canvas: canvas, force: true))
        XCTAssertGreaterThan(pixel(first, x: 25, y: 35).r, 200)
        XCTAssertGreaterThan(pixel(first, x: 145, y: 95).g, 200)
        XCTAssertEqual(pixel(first, x: 80, y: 80).a, 0)
        // A second cue carrying the same events must not draw them twice.
        _ = try renderer.update(header: header, fonts: [], cues: cues + [cue(2, cues[0].lines, start: 1, end: 4)],
                                window: everything)
        let duplicate = frame(renderer.render(time: 2, canvas: canvas, force: true))
        XCTAssertEqual(pixel(duplicate, x: 25, y: 35).r, pixel(first, x: 25, y: 35).r)
    }

    func testAnimationAndBackwardSeekUseRequestedTime() throws {
        let renderer = ASSSubtitleRenderer()
        let line = "0,0,Default,,0,0,0,,{\\an7\\move(20,30,220,30)\\p1}m 0 0 l 20 0 20 20 0 20"
        _ = try renderer.update(header: header, fonts: [], cues: [cue(1, [line], start: 0, end: 4)], window: everything)
        let early = frame(renderer.render(time: 0.5, canvas: canvas, force: false))
        let later = frame(renderer.render(time: 2.5, canvas: canvas, force: false))
        XCTAssertGreaterThan(pixel(early, x: 50, y: 35).a, 200)
        XCTAssertEqual(pixel(later, x: 50, y: 35).a, 0)
        XCTAssertGreaterThan(pixel(later, x: 150, y: 35).a, 200)
        let back = frame(renderer.render(time: 0.5, canvas: canvas, force: false))
        XCTAssertGreaterThan(pixel(back, x: 50, y: 35).a, 200)
    }

    func testUnchangedFramesAreNotRedrawnAndExpiredCuesRenderEmpty() throws {
        let renderer = ASSSubtitleRenderer()
        _ = try renderer.update(header: header, fonts: [], cues: [cue(1, [drawing(x: 20, y: 30)], start: 0, end: 2)],
                                window: everything)
        XCTAssertNotNil(frame(renderer.render(time: 1, canvas: canvas, force: false)))
        guard case .unchanged = renderer.render(time: 1.5, canvas: canvas, force: false) else {
            return XCTFail("A static sign must not produce a new canvas")
        }
        guard case .empty = renderer.render(time: 2, canvas: canvas, force: false) else {
            return XCTFail("An expired cue must clear the overlay")
        }
        let scaled = frame(renderer.render(time: 1, canvas: .init(width: 640, height: 360), force: false))
        XCTAssertGreaterThan(pixel(scaled, x: 50, y: 70).r, 200, "A new canvas size redraws at the new scale")
        XCTAssertEqual(pixel(scaled, x: 90, y: 110).a, 0)
    }

    func testAgedOutCuesStayForABackwardSeekButRetractedCuesAreRemoved() throws {
        let renderer = ASSSubtitleRenderer()
        let old = cue(1, [drawing(x: 20, y: 30)], start: 0, end: 2)
        let current = cue(2, [drawing(x: 140, y: 90)], start: 400, end: 402)
        _ = try renderer.update(header: header, fonts: [], cues: [old, current], window: 400...401)
        // Aether drops cues from its retained window once they are minutes old.
        let pruned = try renderer.update(header: header, fonts: [], cues: [current], window: 400...401)
        XCTAssertFalse(pruned, "Pruning old cues must not invalidate queued frames")
        XCTAssertGreaterThan(pixel(frame(renderer.render(time: 1, canvas: canvas, force: true)), x: 25, y: 35).a, 200,
                             "An aged-out event still renders after a backward seek")

        // A cue that disappears while it can still be drawn was retracted.
        let retracted = try renderer.update(header: header, fonts: [], cues: [], window: 400...401)
        XCTAssertTrue(retracted)
        guard case .empty = renderer.render(time: 401, canvas: canvas, force: true) else {
            return XCTFail("A retracted cue must not render")
        }
        let retimed = try renderer.update(header: header, fonts: [],
                                          cues: [cue(2, current.lines, start: 400, end: 400.5)], window: 400...401)
        XCTAssertTrue(retimed)
        XCTAssertNotNil(frame(renderer.render(time: 400.2, canvas: canvas, force: true)))
        guard case .empty = renderer.render(time: 401, canvas: canvas, force: false) else {
            return XCTFail("A cue's new end time must replace its old one")
        }
        XCTAssertFalse(try renderer.update(header: header, fonts: [],
                                           cues: [cue(2, current.lines, start: 400, end: 400.5),
                                                  cue(3, [drawing(x: 20, y: 30)], start: 900, end: 901)],
                                           window: 400...401),
                       "A cue outside the window does not stale queued frames")
    }

    func testAttachedFontActuallyShapesTheRenderedGlyph() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SiloASSFixture", withExtension: "ttf"))
        let font = FontAttachment(filename: "fixture.ttf", mimeType: "font/ttf", data: try Data(contentsOf: url))
        let cues = [cue(1, ["0,0,Default,,0,0,0,,{\\an7\\pos(20,30)\\fnSilo ASS Fixture}X"], start: 0, end: 2)]
        let renderer = ASSSubtitleRenderer()
        _ = try renderer.update(header: header, fonts: [font], cues: cues, window: everything)
        let attached = frame(renderer.render(time: 1, canvas: canvas, force: true))
        // The fixture's X is a solid rectangle, unlike the system fallback X.
        XCTAssertGreaterThan(pixel(attached, x: 25, y: 45).a, 200)
        XCTAssertGreaterThan(pixel(attached, x: 50, y: 45).a, 200)
        let fallbackRenderer = ASSSubtitleRenderer()
        _ = try fallbackRenderer.update(header: header, fonts: [], cues: cues, window: everything)
        let fallback = frame(fallbackRenderer.render(time: 1, canvas: canvas, force: true))
        XCTAssertNotEqual(alphaCount(attached), alphaCount(fallback))
    }

    func testCompositorBlendsPremultipliedOverExistingPixelsAndClipsToTheCanvas() {
        let width = 4, height = 2, bytesPerRow = width * 4
        var canvas = [UInt32](repeating: 0, count: width * height)
        canvas[1] = 0xFF00_00FF // opaque blue
        var mask: [UInt8] = [255, 128, 128, 0, 255, 255]
        mask.withUnsafeMutableBufferPointer { mask in
            // A 3x2 half-transparent red mask hanging one pixel off the left edge.
            var image = ASS_Image()
            image.w = 3
            image.h = 2
            image.stride = 3
            image.bitmap = mask.baseAddress
            image.color = 0xFF00_0080
            image.dst_x = -1
            image.dst_y = 0
            canvas.withUnsafeMutableBytes { bytes in
                let dirty = ASSImageCompositor.composite(&image, into: bytes.baseAddress!, width: width,
                                                         height: height, bytesPerRow: bytesPerRow)
                XCTAssertEqual(dirty, CGRect(x: 0, y: 0, width: 2, height: 2))
            }
        }
        func channels(_ pixel: UInt32) -> [UInt32] { [pixel >> 24, (pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF] }
        // Opacity 127/255 × coverage 128 over transparent: premultiplied red.
        XCTAssertEqual(channels(canvas[0]), [64, 64, 0, 0])
        // The same over opaque blue keeps full alpha and darkens the blue.
        XCTAssertEqual(channels(canvas[1]), [255, 64, 0, 191])
        // Full coverage on the second row still carries the colour's opacity.
        XCTAssertEqual(channels(canvas[4]), [127, 127, 0, 0])
        XCTAssertEqual(canvas[2], 0, "Pixels outside the mask are untouched")
    }

    // MARK: - Frame schedule and presenter

    func testFrameScheduleOrdersDecodeOrderReportsAndRetiresRestartedEpochs() {
        let schedule = ASSFrameSchedule()
        func report(_ milliseconds: Int64, epoch: UInt64) {
            schedule.record(NativeVideoFrameTime(source: CMTime(value: milliseconds + 10_000, timescale: 1_000),
                                                 item: CMTime(value: milliseconds, timescale: 1_000),
                                                 segmentIndex: 0, isKeyframe: false, epoch: epoch))
        }
        // Decode order: a B-frame pyramid reports later frames first.
        for milliseconds: Int64 in [0, 125, 42, 83, 167] { report(milliseconds, epoch: 5) }
        XCTAssertEqual(schedule.frames(after: 0, through: 1, in: .native).map(\.presentation), [0.042, 0.083, 0.125, 0.167])
        XCTAssertEqual(schedule.frame(atOrBefore: 0.1, in: .native)?.source, 10.083)
        // A restart at 0.09 re-muxes from there; the old epoch's later frames go.
        report(90, epoch: 7)
        XCTAssertEqual(schedule.frames(after: 0, through: 1, in: .native).map(\.presentation), [0.042, 0.083, 0.09])
        report(200, epoch: 5)
        XCTAssertEqual(schedule.frames(after: 0.09, through: 1, in: .native), [],
                       "A superseded epoch's late report is ignored")

        // The software path numbers its generations from its own sequence.
        schedule.record(SoftwareVideoFrameTime(presentation: CMTime(value: 1, timescale: 10), generation: 2))
        XCTAssertEqual(schedule.frames(after: 0, through: 1, in: .software).map(\.presentation), [0.1])
        XCTAssertEqual(schedule.frames(after: 0, through: 1, in: .native).count, 3, "each path keeps its own frames")

        // With no overlay pruning, a long playback trims the oldest frames in batches.
        for index in 0...ASSFrameSchedule.capacity {
            schedule.record(SoftwareVideoFrameTime(presentation: CMTime(value: Int64(index), timescale: 24), generation: 3))
        }
        let newest = Double(ASSFrameSchedule.capacity) / 24
        XCTAssertEqual(schedule.frame(atOrBefore: .infinity, in: .software)?.presentation ?? -1, newest, accuracy: 1e-9)
        XCTAssertNil(schedule.frame(atOrBefore: newest - Double(ASSFrameSchedule.capacity) * 3 / 4 / 24, in: .software),
                     "the oldest quarter is gone")
    }

    func testPresenterRendersEachReportedFrameAtItsOwnTimestamp() async throws {
        let (presenter, output, schedule) = await makePresenter()
        let interval = 1_001.0 / 24_000
        recordFrames(48, into: schedule)
        // A tracked sign: one event per frame, timed between frame timestamps
        // the way typesetters do, moving 30 px each frame.
        let cues = (0..<12).map { index in
            cue(index, [drawing(x: 10 + 30 * index, y: 30)],
                start: (Double(index) - 0.5) * interval, end: (Double(index) + 0.5) * interval)
        }
        await presenter.updateCues(cues, revision: 1)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        let queued = output.queued
        XCTAssertEqual(queued.count, Int(ASSOverlayPresenter.lookaheadSeconds / interval) + 1)
        for (index, entry) in queued.enumerated() {
            XCTAssertEqual(entry.time, Double(index) * interval, accuracy: 1e-9, "frame \(index) keeps its timestamp")
            let x = 15 + 30 * index
            XCTAssertGreaterThan(pixel(entry.buffer, x: x, y: 35).a, 200, "frame \(index) shows its own event")
            XCTAssertEqual(pixel(entry.buffer, x: x + 30, y: 35).a, 0, "frame \(index) shows no later event")
            if index > 0 { XCTAssertEqual(pixel(entry.buffer, x: x - 30, y: 35).a, 0, "frame \(index) shows no earlier event") }
        }
    }

    func testNativePathStampsCanvasesWithTheItemClockAndRendersTheSourceTime() async throws {
        // The native path muxes source PTS onto the player item's axis with a shift.
        let shift = 100.0
        let (presenter, output, schedule) = await makePresenter(axisMap: { .anchored(shiftSeconds: shift) })
        let interval = 1_001.0 / 24_000
        for index in 0..<24 {
            let item = CMTime(value: Int64(index) * 1_001, timescale: 24_000)
            schedule.record(NativeVideoFrameTime(source: item + CMTime(seconds: shift, preferredTimescale: 24_000),
                                                 item: item, segmentIndex: 0, isKeyframe: false, epoch: 3))
        }
        let cues = (0..<8).map { index in
            cue(index, [drawing(x: 10 + 30 * index, y: 30)],
                start: shift + (Double(index) - 0.5) * interval, end: shift + (Double(index) + 0.5) * interval)
        }
        await presenter.updateCues(cues, revision: 1)
        _ = try await presenter.step(ASSOverlayPresenter.Timing(canvas: canvas, cueOffset: 0, axis: .nativeItem,
                                                                frameInterval: interval),
                                     generation: 1)
        XCTAssertEqual(output.queued.count, 8)
        for (index, entry) in output.queued.enumerated() {
            XCTAssertEqual(entry.stamp, CMTime(value: Int64(index) * 1_001, timescale: 24_000),
                           "frame \(index) carries the item timestamp Aether reported, unrounded")
            XCTAssertGreaterThan(pixel(entry.buffer, x: 15 + 30 * index, y: 35).a, 200, "frame \(index) shows its own event")
        }
    }

    func testRemoteHLSPathSpacesFramesByFrameRateAndSubtractsTheMeasuredLead() async throws {
        let (presenter, output, _) = await makePresenter()
        let interval = 0.04
        // Item time leads source time by 2 s; no frame times are reported.
        let cues = (0..<10).map { index in
            cue(index, [drawing(x: 10 + 30 * index, y: 30)],
                start: (Double(index) - 0.5) * interval, end: (Double(index) + 0.5) * interval)
        }
        await presenter.updateCues(cues, revision: 1)
        output.now = 2
        _ = try await presenter.step(ASSOverlayPresenter.Timing(canvas: canvas, cueOffset: 0,
                                                                axis: .item(leadSeconds: 2), frameInterval: interval),
                                     generation: 1)
        XCTAssertEqual(output.queued.count, Int(ASSOverlayPresenter.lookaheadSeconds / interval) + 1)
        for (index, entry) in output.queued.enumerated() {
            XCTAssertEqual(entry.time, 2 + Double(index) * interval, accuracy: 1e-6)
            XCTAssertGreaterThan(pixel(entry.buffer, x: 15 + 30 * index, y: 35).a, 200, "frame \(index) shows its own event")
        }
    }

    func testRemoteHLSRendersTheNextGridFrameAfterAnOffGridStart() async throws {
        let (presenter, output, _) = await makePresenter()
        let interval = 0.04
        let cues = (0..<10).map { index in
            cue(index, [drawing(x: 10 + 30 * index, y: 30)],
                start: Double(index) * interval, end: Double(index + 1) * interval)
        }
        await presenter.updateCues(cues, revision: 1)
        output.now = 0.035
        _ = try await presenter.step(ASSOverlayPresenter.Timing(canvas: canvas, cueOffset: 0,
                                                                axis: .item(leadSeconds: 0), frameInterval: interval),
                                     generation: 1)
        let times = output.queued.prefix(3).map(\.time)
        XCTAssertEqual(times.count, 3)
        for (time, expected) in zip(times, [0.035, 0.04, 0.08]) {
            XCTAssertEqual(time, expected, accuracy: 1e-6, "the grid frame just after the frame on screen renders")
        }
    }

    func testACueForTheFrameOnScreenRefillsItEvenWhenTheClockHasMovedOn() async throws {
        let (presenter, output, schedule) = await makePresenter()
        let interval = 1_001.0 / 24_000
        recordFrames(24, into: schedule)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        // Frame 0 is on screen and the clock has moved past its stamp, though not far enough to
        // read as a seek, when a cue that ends before the clock arrives for it.
        output.now = 0.015
        await presenter.updateCues([cue(1, [drawing(x: 20, y: 30)], start: 0, end: 0.01)], revision: 2)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.queued.first?.time ?? -1, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(pixel(output.queued.first?.buffer, x: 25, y: 35).a, 200,
                             "the frame on screen is redrawn with the late cue")
    }

    func testPresenterQueuesOnlyChangesAndClearsAfterTheLastSign() async throws {
        let (presenter, output, schedule) = await makePresenter()
        let interval = 1_001.0 / 24_000
        recordFrames(24, into: schedule)
        await presenter.updateCues([cue(1, [drawing(x: 20, y: 30)], start: 0, end: 0.1)], revision: 1)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.queued.count, 2)
        XCTAssertEqual(output.queued.first?.time ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(output.queued.last?.time ?? -1, 3 * interval, accuracy: 1e-9)
        XCTAssertGreaterThan(pixel(output.queued[0].buffer, x: 25, y: 35).a, 200)
        XCTAssertEqual(CVPixelBufferGetWidth(output.queued[1].buffer), 2, "The sign ends with a clear canvas")

        // A late update moves the sign away: the canvas kept on screen must be cleared.
        await presenter.updateCues([cue(1, [drawing(x: 20, y: 30)], start: 5, end: 6)], revision: 2)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.lastFlushRemovedImage, false)
        XCTAssertEqual(output.queued.count, 1)
        XCTAssertEqual(output.queued.first.map { CVPixelBufferGetWidth($0.buffer) }, 2,
                       "An empty frame after a kept canvas queues a clear canvas")
    }

    func testPresenterRefillsFromTheFrameOnScreenAfterASeekOrAStaleCueUpdate() async throws {
        let (presenter, output, schedule) = await makePresenter()
        let interval = 1_001.0 / 24_000
        recordFrames(240, into: schedule)
        let sign = cue(1, [drawing(x: 20, y: 30)], start: 0, end: 10)
        await presenter.updateCues([sign], revision: 1)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        let initialFlushes = output.flushes
        XCTAssertEqual(output.queued.count, 1)

        output.now = 5.01
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, initialFlushes + 1, "A clock jump flushes the queued frames")
        XCTAssertEqual(output.lastFlushRemovedImage, true, "A seek never shows the old position's signs")
        XCTAssertEqual(try XCTUnwrap(output.queued.first?.time), 120 * interval, accuracy: 1e-9,
                       "The refill starts with the frame on screen")

        await presenter.updateCues([sign, cue(2, [drawing(x: 140, y: 90)], start: 100, end: 101)], revision: 2)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, initialFlushes + 1, "A cue far ahead does not touch queued frames")

        await presenter.updateCues([sign, cue(3, [drawing(x: 140, y: 90)], start: 5, end: 6)], revision: 3)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, initialFlushes + 2, "A cue inside the queued span replaces those frames")
        XCTAssertEqual(output.lastFlushRemovedImage, false, "Late cues must not blank the signs on screen")
        XCTAssertGreaterThan(pixel(output.queued.first?.buffer, x: 145, y: 95).a, 200)

        await presenter.load(generation: 2, header: header, fonts: [])
        XCTAssertEqual(output.flushes, initialFlushes + 3, "A new selection clears the overlay at once")
        XCTAssertEqual(output.lastFlushRemovedImage, true)
    }

    func testPlayAndPauseAreNotSeeksButAFrameStepBackIs() async throws {
        let (presenter, output, schedule) = await makePresenter()
        let interval = 1_001.0 / 24_000
        recordFrames(48, into: schedule)
        await presenter.updateCues([cue(1, [drawing(x: 20, y: 30)], start: 0, end: 10)], revision: 1)
        output.now = 1
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        let flushes = output.flushes
        // Play starts between two steps: the clock moves less than the new rate predicts.
        output.rate = 1
        output.now = 1.004
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, flushes, "Starting playback is not a seek")
        output.rate = 0
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, flushes, "Pausing is not a seek")
        output.now = 1.004 - interval
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, flushes + 1, "A step back one frame refreshes the overlay")
    }

    func testCanvasesOfAnOutgoingSelectionAreRefused() async throws {
        let (presenter, output, schedule) = await makePresenter()
        recordFrames(24, into: schedule)
        let sign = cue(1, [drawing(x: 20, y: 30)], start: 0, end: 10)
        await presenter.updateCues([sign], revision: 1)
        // The session moves to another selection while this step is still to run.
        output.accept(generation: 2)
        _ = try await presenter.step(timing(interval: 1_001.0 / 24_000), generation: 1)
        XCTAssertTrue(output.queued.isEmpty)
        await presenter.load(generation: 2, header: header, fonts: [])
        await presenter.updateCues([sign], revision: 2)
        // The outgoing selection's step reaches the actor late.
        await presenter.load(generation: 1, header: header, fonts: [])
        await presenter.updateCues([], revision: 1)
        let late = ASSOverlayPresenter.Timing(canvas: canvas, cueOffset: 600, axis: .source,
                                              frameInterval: 1_001.0 / 24_000)
        _ = try await presenter.step(late, generation: 1)
        XCTAssertTrue(output.queued.isEmpty, "a late step renders nothing with its outgoing timing")
        _ = try await presenter.step(timing(interval: 1_001.0 / 24_000), generation: 2)
        XCTAssertEqual(output.queued.count, 1, "the new selection's own canvases show")
    }

    func testAReloadReplacesEveryEventAndKeepsTheSignsOnScreen() async throws {
        let (presenter, output, _) = await makePresenter()
        let interval = 1_001.0 / 24_000
        let deleted = cue(1, [drawing(x: 20, y: 30)], start: 0, end: 2)
        let current = cue(2, [drawing(x: 140, y: 90)], start: 400, end: 402)
        await presenter.updateCues([deleted, current], revision: 1)
        output.now = 400.5
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        let flushes = output.flushes
        // Without the replacement, an event that ended minutes ago would stay for a backward seek.
        await presenter.updateCues([current], revision: 2, replacing: true)
        _ = try await presenter.step(timing(interval: interval), generation: 1)
        XCTAssertEqual(output.flushes, flushes + 1)
        XCTAssertEqual(output.lastFlushRemovedImage, false, "The reload keeps the signs on screen")
        XCTAssertGreaterThan(pixel(output.queued.first?.buffer, x: 145, y: 95).a, 200)
        let past = try await presenter.snapshot(cueTime: 1, canvas: canvas, generation: 1)
        XCTAssertNil(past, "A cue the reload deleted no longer renders")
    }

    func testLibassTimeIsTruncatedSoAnEventWaitsForItsFrame() throws {
        // 23.976 fps frame 199 is presented at 8.29996 s; an event authored to start at 8.30 belongs
        // to frame 200.
        XCTAssertEqual(ASSSubtitleRenderer.libassMilliseconds(199.0 * 1_001 / 24_000), 8_299)
        XCTAssertEqual(ASSSubtitleRenderer.libassMilliseconds(8.3), 8_300)
        XCTAssertEqual(ASSSubtitleRenderer.libassMilliseconds(0.1 + 0.2), 300)
        let renderer = ASSSubtitleRenderer()
        _ = try renderer.update(header: header, fonts: [],
                                cues: [cue(1, [drawing(x: 20, y: 30)], start: 0, end: 8.3),
                                       cue(2, [drawing(x: 140, y: 90)], start: 8.3, end: 9)],
                                window: everything)
        let frame199 = frame(renderer.render(time: 199.0 * 1_001 / 24_000, canvas: canvas, force: true))
        XCTAssertGreaterThan(pixel(frame199, x: 25, y: 35).a, 200)
        XCTAssertEqual(pixel(frame199, x: 145, y: 95).a, 0)
    }

    func testAReloadedCueWithTheSameIDAndNewTextReplacesTheOldEvent() throws {
        // A reloaded sidecar numbers its cues from zero again.
        let renderer = ASSSubtitleRenderer()
        _ = try renderer.update(header: header, fonts: [], cues: [cue(0, [drawing(x: 20, y: 30)], start: 0, end: 4)],
                                window: everything)
        XCTAssertTrue(try renderer.update(header: header, fonts: [],
                                          cues: [cue(0, [drawing(x: 140, y: 90)], start: 0, end: 4)],
                                          window: everything))
        let reloaded = frame(renderer.render(time: 1, canvas: canvas, force: true))
        XCTAssertEqual(pixel(reloaded, x: 25, y: 35).a, 0)
        XCTAssertGreaterThan(pixel(reloaded, x: 145, y: 95).a, 200)
    }

    func testCanvasIsCappedAtTheAreaOf1080p() {
        XCTAssertEqual(ASSSubtitleSession.canvas(for: CGSize(width: 1_920, height: 1_080), scale: 1),
                       .init(width: 1_920, height: 1_080))
        XCTAssertEqual(ASSSubtitleSession.canvas(for: CGSize(width: 1_920, height: 1_080), scale: 2),
                       .init(width: 1_920, height: 1_080), "A 4K output renders a 1080p canvas")
        let phone = ASSSubtitleSession.canvas(for: CGSize(width: 852, height: 393), scale: 3)
        XCTAssertLessThanOrEqual(Double((phone?.width ?? 0) * (phone?.height ?? 0)), 1_920 * 1_080 * 1.001)
        XCTAssertEqual(Double(phone?.width ?? 0) / Double(phone?.height ?? 1), 852.0 / 393, accuracy: 0.01)
        XCTAssertNil(ASSSubtitleSession.canvas(for: .zero, scale: 2))
    }

    func testMovieAndEmbeddedTimingRetainDelaySign() {
        XCTAssertEqual(ASSSubtitleSession.cueOffset(timelineOffset: 600, isExternal: true, delaySeconds: 0.5), 599.5)
        XCTAssertEqual(ASSSubtitleSession.cueOffset(timelineOffset: 600, isExternal: false, delaySeconds: 0.5), -0.5)
        XCTAssertEqual(ASSSubtitleSession.frameInterval(fps: 25), 0.04)
        XCTAssertEqual(ASSSubtitleSession.frameInterval(fps: nil), 1_001.0 / 24_000)
    }

    func testAHeldReloadReplacesTheOutgoingCuesEvenWhenItEndsEmpty() {
        let outgoing = [SubtitleCue(id: 0, startTime: 0, endTime: 2, body: .text("old"))]
        let reloaded = [SubtitleCue(id: 0, startTime: 0, endTime: 3, body: .text("new"))]
        var feed = ASSSubtitleSession.CueFeed()
        feed.publish(outgoing, held: false)
        XCTAssertFalse(feed.takeReplacement(through: feed.revision), "an ordinary publication adds cues")

        // Aether clears the track as the reload starts; the hold keeps the outgoing cues up.
        feed.publish([], held: true)
        XCTAssertEqual(feed.cues.map(\.id), [0])
        feed.publish(reloaded, held: true)
        XCTAssertEqual(feed.cues.first?.text, "new")
        feed.loadingFinished(with: reloaded)
        XCTAssertEqual(feed.revision, 2, "a reload that published its cues is not taken twice")
        XCTAssertTrue(feed.takeReplacement(through: feed.revision))
        XCTAssertFalse(feed.takeReplacement(through: feed.revision), "a replacement is taken once")

        // A reload that ends with no cues publishes nothing the hold lets through.
        feed.publish([], held: true)
        feed.publish([], held: true)
        XCTAssertEqual(feed.cues.count, 1)
        feed.loadingFinished(with: [])
        XCTAssertTrue(feed.cues.isEmpty)
        XCTAssertTrue(feed.takeReplacement(through: feed.revision))
    }

    private final class FakeOutput: ASSOverlayOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var time: Double = 0
        private var currentRate: Double = 0
        private var entries: [(time: Double, stamp: CMTime, buffer: CVPixelBuffer)] = []
        private var flushCount = 0
        private var removedImage: Bool?
        private var acceptedGeneration: UInt64?

        var now: Double {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
        var rate: Double {
            get { lock.withLock { currentRate } }
            set { lock.withLock { currentRate = newValue } }
        }
        var queued: [(time: Double, stamp: CMTime, buffer: CVPixelBuffer)] { lock.withLock { entries } }
        var flushes: Int { lock.withLock { flushCount } }
        var lastFlushRemovedImage: Bool? { lock.withLock { removedImage } }

        /// What the session does for the sink before it awaits the presenter.
        func accept(generation: UInt64?) { lock.withLock { acceptedGeneration = generation } }

        func enqueue(_ buffer: CVPixelBuffer, at time: CMTime, generation: UInt64) {
            lock.withLock {
                guard generation == acceptedGeneration else { return }
                entries.append((time.seconds, time, buffer))
            }
        }
        func flush(removingImage: Bool) {
            lock.withLock {
                flushCount += 1
                removedImage = removingImage
                entries.removeAll()
            }
        }
    }

    /// Software-path frame reports at 23.976 fps from 0 s.
    private func recordFrames(_ count: Int, into schedule: ASSFrameSchedule) {
        for index in 0..<count {
            schedule.record(SoftwareVideoFrameTime(presentation: CMTime(value: Int64(index) * 1_001, timescale: 24_000),
                                                   generation: 1))
        }
    }

    private func makePresenter(
        axisMap: @escaping @Sendable () -> PresentationAxisMap = { PresentationAxisMap() }
    ) async -> (ASSOverlayPresenter, FakeOutput, ASSFrameSchedule) {
        let schedule = ASSFrameSchedule()
        let presenter = ASSOverlayPresenter(schedule: schedule, axisMap: axisMap)
        let output = FakeOutput()
        output.accept(generation: 1)
        await presenter.attach(output)
        await presenter.load(generation: 1, header: header, fonts: [])
        return (presenter, output, schedule)
    }

    private func timing(interval: Double) -> ASSOverlayPresenter.Timing {
        ASSOverlayPresenter.Timing(canvas: canvas, cueOffset: 0, axis: .source, frameInterval: interval)
    }

    // MARK: - Fonts

    func testFontBundleDecodingReadsTheV2CollectionAndRejectsMalformedData() throws {
        let decoded = try ASSSubtitleSession.decodeFonts(Data(#"{"items":[{"name":"font.ttf","data":"AQID"}]}"#.utf8))
        XCTAssertEqual(decoded.first?.data, Data([1, 2, 3]))
        XCTAssertThrowsError(try ASSSubtitleSession.decodeFonts(Data(#"{"items":[{"name":"font.ttf","data":"bad base64"}]}"#.utf8)))
        XCTAssertThrowsError(try ASSSubtitleSession.decodeFonts(Data(#"{"items":[{"name":"","data":"AQID"}]}"#.utf8)))
        XCTAssertThrowsError(try ASSSubtitleSession.decodeFonts(Data(#"[{"name":"font.ttf","data":"AQID"}]"#.utf8)),
                             "the bare array is the retired v1 shape")
        XCTAssertEqual(try ASSSubtitleSession.decodeFonts(Data(#"{"items":[]}"#.utf8)), [])
    }

    // MARK: - Aether integration

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
        // Start the playback packet pump so embedded cues do not depend on
        // the background prefetcher winning CPU time on a busy CI runner.
        controller.setMuted(true)
        controller.play()
        controller.selectSubtitleTrack(id: 2)
        try await waitForASS(controller, timeout: .seconds(20))
        controller.pause()
        let session = controller.assSubtitles
        XCTAssertTrue(session.handlesCurrentTrack)
        await session.step(size: size, scale: 1, delaySeconds: 0)
        XCTAssertNotNil(session.overlayLayer, "The overlay layer joins the playing item's clock")
        let embedded = try await session.snapshot(cueTime: 1, size: size, scale: 1)
        XCTAssertGreaterThan(pixel(embedded, x: 25, y: 45).a, 200)
        XCTAssertGreaterThan(pixel(embedded, x: 145, y: 95).g, 200)

        controller.selectSubtitleTrack(id: 3)
        try await waitForASS(controller)
        let alternate = try await session.snapshot(cueTime: 1, size: size, scale: 1)
        XCTAssertEqual(pixel(alternate, x: 25, y: 45).a, 0, "The outgoing track's events are gone")
        XCTAssertGreaterThan(pixel(alternate, x: 225, y: 95).g, 200)

        let externalID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 20)
        controller.addExternalSubtitleTrack(ExternalSubtitleTrack(url: sidecar), appTrackID: externalID)
        controller.selectSubtitleTrack(id: externalID)
        try await waitForASS(controller)
        XCTAssertNotNil(controller.engine.sidecarASSHeader)
        let external = try await session.snapshot(cueTime: 1, size: size, scale: 1)
        XCTAssertGreaterThan(pixel(external, x: 25, y: 45).a, 200)
        controller.selectSubtitleTrack(id: nil)
        XCTAssertFalse(session.handlesCurrentTrack)
        let off = try await session.snapshot(cueTime: 1, size: size, scale: 1)
        XCTAssertNil(off)
    }

    @MainActor
    func testEmbeddedSecondaryASSKeepsNormalizedTextWhilePrimaryKeepsRawEvents() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "authored", withExtension: "mkv"))
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let spec = try AetherLoadSpec(offlineURL: movie, startPosition: 0, audioOnly: false,
                                      panelIsInHDRMode: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.setMuted(true)
        controller.play()
        controller.selectSubtitleTrack(id: 3)
        try await waitForASS(controller, timeout: .seconds(20))
        controller.selectSecondarySubtitleTrack(id: 2)
        for _ in 0..<100 {
            if !controller.engine.secondarySubtitleCues.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        controller.pause()
        let text = controller.engine.secondarySubtitleCues.compactMap(\.text)
        XCTAssertTrue(text.contains("X"), "The companion overlay must receive display text, not an ASS event")
        XCTAssertFalse(text.contains { $0.contains("Default,,") || $0.contains("\\pos(") })
        XCTAssertFalse(controller.engine.subtitleCues.flatMap(ASSSubtitleRenderer.Cue.lines(of:)).isEmpty,
                       "The primary overlay must retain authored ASS events")
    }

    @MainActor
    func testASSReadinessReturnsImmediatelyWhenCuesAreReady() async throws {
        let instant = ContinuousClock.now
        var didSleep = false
        try await waitForASS(timeout: .seconds(20), now: { instant }, sleep: { _ in
            didSleep = true
            throw ASSReadinessTimeout()
        }, isReady: { true })
        XCTAssertFalse(didSleep, "Published cues must not add a readiness delay")
    }

    @MainActor
    func testASSReadinessTimeoutStopsTheCaller() async throws {
        var instant = ContinuousClock.now
        let deadline = instant + .seconds(20)
        do {
            try await waitForASS(timeout: .seconds(20), now: {
                defer { instant = deadline }
                return instant
            }, sleep: { _ in
                XCTFail("An expired readiness deadline must not sleep")
                throw ASSReadinessTimeout()
            }, isReady: { false })
            XCTFail("A readiness timeout must throw before the caller continues")
        } catch is ASSReadinessTimeout {
            // Expected: rendering and content assertions require published cues.
        }
    }

    private struct ASSReadinessTimeout: LocalizedError {
        var errorDescription: String? { "Aether did not publish ASS cues before the readiness deadline" }
    }

    @MainActor
    private func waitForASS(_ controller: AetherPlaybackController, timeout: Duration? = nil) async throws {
        try await waitForASS(timeout: timeout, isReady: {
            !controller.engine.isLoadingSubtitles && !controller.engine.subtitleCues.isEmpty
        })
    }

    @MainActor
    private func waitForASS(
        timeout: Duration?,
        now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isReady: @MainActor () -> Bool
    ) async throws {
        guard let timeout else {
            for _ in 0..<100 {
                try Task.checkCancellation()
                if isReady() { return }
                try await sleep(.milliseconds(50))
            }
            throw ASSReadinessTimeout()
        }
        let deadline = now() + timeout
        while true {
            try Task.checkCancellation()
            let remaining = now().duration(to: deadline)
            guard remaining > .zero else { throw ASSReadinessTimeout() }
            if isReady() { return }
            try await sleep(min(.milliseconds(50), remaining))
        }
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
        let session = ASSSubtitleSession(engine: engine, fontLoader: { request, _ in try await pending.load(request) })
        session.finishLoad()
        let first = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing-a.ass")))
        let second = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing-b.ass")))
        session.registerFontRequest(URLRequest(url: URL(string: "https://example.test/a")!), trackID: first.id)
        session.registerFontRequest(URLRequest(url: URL(string: "https://example.test/b")!), trackID: second.id)
        engine.selectSubtitleTrack(index: first.id)
        await session.step(size: size, scale: 1, delaySeconds: 0)
        for _ in 0..<100 where !(await pending.contains("a")) { await Task.yield() }
        let firstStarted = await pending.contains("a")
        XCTAssertTrue(firstStarted)
        engine.selectSubtitleTrack(index: second.id)
        await session.step(size: size, scale: 1, delaySeconds: 0)
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
        XCTAssertFalse(session.handlesCurrentTrack)
        XCTAssertFalse(session.isLoadingFonts)
    }

    // MARK: - Pixels

    /// Premultiplied BGRA; opaque test drawings keep their authored channels.
    private func pixel(_ buffer: CVPixelBuffer?, x: Int, y: Int) -> (r: UInt8, g: UInt8, a: UInt8) {
        guard let buffer else { return (0, 0, 0) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard x >= 0, y >= 0, x < CVPixelBufferGetWidth(buffer), y < CVPixelBufferGetHeight(buffer),
              let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let bytes = base.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (bytes[2], bytes[1], bytes[3])
    }

    private func alphaCount(_ buffer: CVPixelBuffer?) -> Int {
        guard let buffer else { return 0 }
        var count = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) where pixel(buffer, x: x, y: y).a > 0 { count += 1 }
        }
        return count
    }
}
