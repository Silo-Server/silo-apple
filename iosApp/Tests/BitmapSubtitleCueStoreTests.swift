import CoreGraphics
import XCTest
@testable import Silo

/// Timing/expiry semantics of the bitmap subtitle cue store, including
/// the PGS "next event trims the previous cue" model.
final class BitmapSubtitleCueStoreTests: XCTestCase {

    private static let image: CGImage = {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()

    private func makeCue(start: Double, end: Double) -> BitmapSubtitleCue {
        BitmapSubtitleCue(
            startSeconds: start,
            endSeconds: end,
            image: Self.image,
            normalizedFrame: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1)
        )
    }

    // MARK: - Active lookup boundaries

    func testActiveCuesStartInclusiveEndExclusive() {
        let store = BitmapSubtitleCueStore()
        store.apply(cues: [makeCue(start: 1, end: 3)])
        XCTAssertTrue(store.activeCues(at: 0.999).isEmpty)
        XCTAssertEqual(store.activeCues(at: 1.0).count, 1)
        XCTAssertEqual(store.activeCues(at: 2.9).count, 1)
        XCTAssertTrue(store.activeCues(at: 3.0).isEmpty)
    }

    func testOverlappingCuesBothActive() {
        let store = BitmapSubtitleCueStore()
        // Insert out of order; the store keeps them sorted by start.
        store.apply(cues: [makeCue(start: 2, end: 5)])
        store.apply(cues: [makeCue(start: 1, end: 3)])
        XCTAssertEqual(store.activeCues(at: 2.5).count, 2)
        XCTAssertEqual(store.activeCues(at: 1.5).count, 1)
        XCTAssertEqual(store.activeCues(at: 4.0).count, 1)
    }

    func testNonPositiveDurationCueIsIgnored() {
        let store = BitmapSubtitleCueStore()
        store.apply(cues: [makeCue(start: 2, end: 2)])
        XCTAssertEqual(store.cueCount, 0)
    }

    // MARK: - PGS trim semantics

    func testTrimShortensOpenEndedCueToNextEvent() {
        let store = BitmapSubtitleCueStore()
        // PGS cue with the 5 s default ceiling...
        store.apply(cues: [makeCue(start: 10, end: 15)], trimActiveAt: 10)
        // ...next composition at 12 replaces it.
        store.apply(cues: [makeCue(start: 12, end: 17)], trimActiveAt: 12)
        let atTwelve = store.activeCues(at: 12)
        XCTAssertEqual(atTwelve.count, 1)
        XCTAssertEqual(atTwelve[0].startSeconds, 12)
        // The old cue now ends exactly at 12.
        let atEleven = store.activeCues(at: 11)
        XCTAssertEqual(atEleven.count, 1)
        XCTAssertEqual(atEleven[0].endSeconds, 12)
    }

    func testEmptyClearEventEndsCueWithoutAddingOne() {
        let store = BitmapSubtitleCueStore()
        store.apply(cues: [makeCue(start: 10, end: 15)], trimActiveAt: 10)
        // PGS clear event (no rects) at 13.
        store.apply(cues: [], trimActiveAt: 13)
        XCTAssertEqual(store.activeCues(at: 12).count, 1)
        XCTAssertTrue(store.activeCues(at: 13).isEmpty)
        XCTAssertTrue(store.activeCues(at: 14).isEmpty)
    }

    func testTrimDoesNotTouchAlreadyEndedCues() {
        let store = BitmapSubtitleCueStore()
        store.apply(cues: [makeCue(start: 10, end: 12)])
        store.apply(cues: [], trimActiveAt: 13)
        XCTAssertEqual(store.activeCues(at: 11).first?.endSeconds, 12)
    }

    // MARK: - Retention + cap

    func testRetentionPruneDropsStaleCues() {
        let store = BitmapSubtitleCueStore(retentionSeconds: 30)
        store.apply(cues: [makeCue(start: 0, end: 2)])
        XCTAssertEqual(store.activeCues(at: 1).count, 1)
        // A far-future event prunes anything ending before now − 30 s.
        store.apply(cues: [makeCue(start: 100, end: 103)])
        XCTAssertTrue(store.activeCues(at: 1).isEmpty)
        XCTAssertEqual(store.cueCount, 1)
    }

    func testCountCapDropsOldestCues() {
        let store = BitmapSubtitleCueStore(retentionSeconds: 1000, maxCueCount: 3)
        for i in 0..<5 {
            let start = Double(i)
            store.apply(cues: [makeCue(start: start, end: start + 0.5)])
        }
        XCTAssertEqual(store.cueCount, 3)
        XCTAssertTrue(store.activeCues(at: 0.25).isEmpty)
        XCTAssertTrue(store.activeCues(at: 1.25).isEmpty)
        XCTAssertEqual(store.activeCues(at: 4.25).count, 1)
    }

    // MARK: - Revision + clear

    func testRevisionBumpsOnMutationsOnly() {
        let store = BitmapSubtitleCueStore()
        let initial = store.currentRevision

        // No cues, no trim reference → nothing observable changed.
        store.apply(cues: [])
        XCTAssertEqual(store.currentRevision, initial)

        // A trim timestamp that intersects nothing is also a no-op.
        store.apply(cues: [], trimActiveAt: 50)
        XCTAssertEqual(store.currentRevision, initial)

        store.apply(cues: [makeCue(start: 1, end: 2)])
        let afterInsert = store.currentRevision
        XCTAssertGreaterThan(afterInsert, initial)

        // Trim that shortens the active cue bumps again.
        store.apply(cues: [], trimActiveAt: 1.5)
        XCTAssertGreaterThan(store.currentRevision, afterInsert)
    }

    func testClearEmptiesAndBumpsRevision() {
        let store = BitmapSubtitleCueStore()
        store.apply(cues: [makeCue(start: 1, end: 2)])
        let before = store.currentRevision
        store.clear()
        XCTAssertEqual(store.cueCount, 0)
        XCTAssertGreaterThan(store.currentRevision, before)
        // Clearing an empty store changes nothing.
        let after = store.currentRevision
        store.clear()
        XCTAssertEqual(store.currentRevision, after)
    }

    // MARK: - Isolation

    func testStoresAreIndependent() {
        let primary = BitmapSubtitleCueStore()
        let secondary = BitmapSubtitleCueStore()
        primary.apply(cues: [makeCue(start: 1, end: 2)])
        XCTAssertEqual(primary.cueCount, 1)
        XCTAssertEqual(secondary.cueCount, 0)
        secondary.clear()
        XCTAssertEqual(primary.activeCues(at: 1.5).count, 1)
    }
}
