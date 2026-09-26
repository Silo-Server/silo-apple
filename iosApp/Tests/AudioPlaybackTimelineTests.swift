import XCTest
@testable import Silo

/// `AudioPlaybackTimeline.chapter(at:in:)` backs the audiobook player's
/// current chapter, which it looks up on every clock tick.
final class AudioPlaybackTimelineTests: XCTestCase {
    func testChapterIsTheLastOneStartedAtThePlayhead() {
        let chapters = [chapter(0, at: 0), chapter(1, at: 60), chapter(2, at: 120)]

        XCTAssertEqual(AudioPlaybackTimeline.chapter(at: 0, in: chapters)?.index, 0)
        XCTAssertEqual(AudioPlaybackTimeline.chapter(at: 59.9, in: chapters)?.index, 0)
        XCTAssertEqual(AudioPlaybackTimeline.chapter(at: 60, in: chapters)?.index, 1)
        XCTAssertEqual(AudioPlaybackTimeline.chapter(at: 119.99, in: chapters)?.index, 1)
        XCTAssertEqual(AudioPlaybackTimeline.chapter(at: 5000, in: chapters)?.index, 2)
    }

    func testNoChapterBeforeTheFirstStartOrWithoutChapters() {
        XCTAssertNil(AudioPlaybackTimeline.chapter(at: 4.9, in: [chapter(0, at: 5)]))
        XCTAssertNil(AudioPlaybackTimeline.chapter(at: 30, in: []))
    }

    /// Server chapter data can repeat a start time. The player has always
    /// shown the first chapter with that start.
    func testChaptersSharingAStartResolveToTheFirst() {
        let chapters = [chapter(0, at: 0), chapter(1, at: 60), chapter(2, at: 60), chapter(3, at: 120)]

        XCTAssertEqual(AudioPlaybackTimeline.chapter(at: 90, in: chapters)?.index, 1)
    }

    private func chapter(_ index: Int, at start: Double) -> AudioPlaybackChapter {
        AudioPlaybackChapter(index: index, title: nil, startSeconds: start, endSeconds: nil, trackIndex: 0)
    }
}
