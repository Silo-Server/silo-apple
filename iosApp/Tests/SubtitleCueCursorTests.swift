import XCTest
@testable import Silo

final class SubtitleCueCursorTests: XCTestCase {
    private struct Cue: SubtitleCueTiming, Equatable {
        let id: Int
        let startTime: Double
        let endTime: Double
    }

    /// What the overlay used to compute on every tick.
    private func naive(_ cues: [Cue], at time: Double) -> [Cue] {
        cues.filter { $0.startTime <= time && time < $0.endTime }
    }

    private func cursor(_ cues: [Cue]) -> SubtitleCueCursor<Cue> {
        let cursor = SubtitleCueCursor<Cue>()
        cursor.reset(cues)
        return cursor
    }

    func testForwardPlaybackShowsAndHidesCuesAtTheirBoundaries() {
        let cues = [Cue(id: 0, startTime: 1, endTime: 2), Cue(id: 1, startTime: 3, endTime: 4)]
        let cursor = cursor(cues)
        for time in stride(from: 0.0, through: 5, by: 0.25) {
            XCTAssertEqual(cursor.active(at: time), naive(cues, at: time), "t=\(time)")
        }
    }

    func testOverlappingCuesKeepListOrderEvenWhenListIsNotSortedByStart() {
        let cues = [
            Cue(id: 0, startTime: 5, endTime: 9),
            Cue(id: 1, startTime: 2, endTime: 8),
            Cue(id: 2, startTime: 6, endTime: 7),
        ]
        let cursor = cursor(cues)
        XCTAssertEqual(cursor.active(at: 6.5).map(\.id), [0, 1, 2])
        XCTAssertEqual(cursor.active(at: 7).map(\.id), [0, 1])
        XCTAssertEqual(cursor.active(at: 3).map(\.id), [1])
    }

    func testBackwardSeekAndLargeJumpFindTheLongCueThatIsStillShowing() {
        let cues = [
            Cue(id: 0, startTime: 0, endTime: 600),
            Cue(id: 1, startTime: 10, endTime: 11),
            Cue(id: 2, startTime: 300, endTime: 302),
        ]
        let cursor = cursor(cues)
        XCTAssertEqual(cursor.active(at: 10.5).map(\.id), [0, 1])
        XCTAssertEqual(cursor.active(at: 301).map(\.id), [0, 2])
        XCTAssertEqual(cursor.active(at: 5).map(\.id), [0])
        XCTAssertEqual(cursor.active(at: 700), [])
    }

    func testDelayChangeAndRepositionMatchTheNaiveFilter() {
        let cues = (0..<20).map { Cue(id: $0, startTime: Double($0) * 2, endTime: Double($0) * 2 + 1.5) }
        let cursor = cursor(cues)
        _ = cursor.active(at: 10.2)
        // A +1.2 s delay moves the render clock backwards.
        XCTAssertEqual(cursor.active(at: 9.0), naive(cues, at: 9.0))
        cursor.reposition()
        XCTAssertEqual(cursor.active(at: 12.4), naive(cues, at: 12.4))
    }

    func testRandomPlaybackMatchesTheNaiveFilter() {
        var rng = SeededGenerator(seed: 0x5EED)
        for _ in 0..<20 {
            let cues = (0..<200).map { id -> Cue in
                let start = Double.random(in: 0..<600, using: &rng)
                let length = Double.random(in: 0..<8, using: &rng)
                return Cue(id: id, startTime: start, endTime: start + length)
            }
            let cursor = cursor(cues)
            var time = 0.0
            for _ in 0..<2_000 {
                switch Int.random(in: 0..<20, using: &rng) {
                case 0: time = Double.random(in: -10..<650, using: &rng)   // seek anywhere
                case 1: time -= Double.random(in: 0..<3, using: &rng)      // delay change or short rewind
                default: time += Double.random(in: 0..<0.5, using: &rng)   // playback tick
                }
                XCTAssertEqual(cursor.active(at: time), naive(cues, at: time), "t=\(time)")
            }
        }
    }

    func testAppendedLiveCuesAreFoundWithoutAnExplicitReset() {
        let cursor = SubtitleCueCursor<Cue>()
        var cues = [Cue(id: 0, startTime: 1, endTime: 3)]
        XCTAssertEqual(cursor.active(at: 2, in: cues).map(\.id), [0])
        // A translated cue arrives late for a window that already began.
        cues.append(Cue(id: 1, startTime: 1.5, endTime: 4))
        XCTAssertEqual(cursor.active(at: 2.1, in: cues).map(\.id), [0, 1])
        cues.removeFirst()
        XCTAssertEqual(cursor.active(at: 2.2, in: cues).map(\.id), [1])
    }
}

/// SplitMix64, so the random walk is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
