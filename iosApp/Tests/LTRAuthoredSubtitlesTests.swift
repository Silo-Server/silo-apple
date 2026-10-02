import AetherEngine
import XCTest
@testable import Silo

final class LTRAuthoredSubtitlesTests: XCTestCase {
    private let lrm = LTRAuthoredSubtitles.leftToRightMark

    /// Lines from a community Arabic file written for left-to-right players:
    /// the dialogue dash is last and the closing ellipsis is first.
    private let ltrAuthored = [
        "ماذا حدث للتو؟ -",
        "...لأنه بالنسبة إليهم",
        "إنها حالة طارئة وليهدأ الجميع -",
        "لقد انفجر -",
        "لا أعرف",
    ]

    /// The same lines in logical order, as release-derived files carry them.
    private let logical = [
        "- ماذا حدث للتو؟",
        "لأنه بالنسبة إليهم...",
        "- إنها حالة طارئة وليهدأ الجميع",
        "- لقد انفجر",
        "لا أعرف",
    ]

    private func cues(_ lines: [String], firstID: Int = 0) -> [SubtitleCue] {
        lines.enumerated().map { offset, line in
            let id = firstID + offset
            return SubtitleCue(id: id, startTime: Double(id), endTime: Double(id) + 1, body: .text(line))
        }
    }

    private func laidOut(_ cues: [SubtitleCue]) -> [String] {
        var track = LTRAuthoredSubtitles.Track()
        return track.laidOutAsAuthored(cues, trackID: 1).compactMap(\.text)
    }

    func testLTRAuthoredTrackGetsALeftToRightBaseOnEveryRightToLeftLine() {
        XCTAssertEqual(laidOut(cues(ltrAuthored + ["OK -"])), ltrAuthored.map { lrm + $0 } + ["OK -"])
    }

    func testLogicalOrderTrackIsLeftAlone() {
        XCTAssertEqual(laidOut(cues(logical)), logical)
    }

    func testAFewStrayLinesDoNotFlipALogicalTrack() {
        XCTAssertEqual(laidOut(cues(logical + ["...ثم", "نعم -"])), logical + ["...ثم", "نعم -"])
        XCTAssertEqual(laidOut(cues(["لقد انفجر -", "لا أعرف"])), ["لقد انفجر -", "لا أعرف"])
    }

    func testAlreadyMarkedTrackIsNotMarkedAgain() {
        let marked = laidOut(cues(ltrAuthored))
        XCTAssertEqual(laidOut(cues(marked)), marked)
    }

    /// Embedded cues arrive as a window around the playhead. Evidence that
    /// has scrolled out of the window still counts, so the layout holds.
    func testDecisionHoldsAfterItsEvidenceLeavesTheWindow() {
        var track = LTRAuthoredSubtitles.Track()
        _ = track.laidOutAsAuthored(cues(ltrAuthored), trackID: 1)
        let later = track.laidOutAsAuthored(cues(["لا أعرف", "بالطبع"], firstID: 100), trackID: 1)
        XCTAssertEqual(later.compactMap(\.text), [lrm + "لا أعرف", lrm + "بالطبع"])
    }

    func testANewTrackStartsWithoutTheOldTracksEvidence() {
        var track = LTRAuthoredSubtitles.Track()
        _ = track.laidOutAsAuthored(cues(ltrAuthored), trackID: 1)
        let next = track.laidOutAsAuthored(cues(logical, firstID: 100), trackID: 2)
        XCTAssertEqual(next.compactMap(\.text), logical)
        XCTAssertFalse(track.isLTRAuthored)
    }

    /// The engine clears a channel's cues when it selects a track. The next
    /// track's evidence starts from nothing, even when its cue IDs repeat.
    func testAnEmptyPublicationStartsOver() {
        var track = LTRAuthoredSubtitles.Track()
        _ = track.laidOutAsAuthored(cues(ltrAuthored))
        _ = track.laidOutAsAuthored([])
        XCTAssertEqual(track.laidOutAsAuthored(cues(logical)).compactMap(\.text), logical)
    }

    /// A backfill from an already-decoded store replaces the cues without a
    /// clear but under a new engine track index.
    func testANewEngineTrackIndexStartsOverWithRepeatedCueIDs() {
        var track = LTRAuthoredSubtitles.Track()
        _ = track.laidOutAsAuthored(cues(ltrAuthored), trackID: 1)
        XCTAssertEqual(track.laidOutAsAuthored(cues(logical), trackID: 2).compactMap(\.text), logical)
    }

    /// An early run of moved-looking lines does not lock the track in once
    /// the logical-order evidence outweighs it.
    func testLaterEvidenceCorrectsAnEarlyClassification() {
        var track = LTRAuthoredSubtitles.Track()
        _ = track.laidOutAsAuthored(cues(["...ثم", "...وبعد ذلك", "...لكن"]))
        XCTAssertTrue(track.isLTRAuthored)
        let later = cues(Array(repeating: "- لقد انفجر", count: 4), firstID: 100)
        XCTAssertEqual(track.laidOutAsAuthored(later).compactMap(\.text), later.compactMap(\.text))
    }

    func testSentenceEndAfterASpaceCountsAsLogicalOrder() {
        let lines = ["...ثم", "...وبعد ذلك", "...لكن", "مرحبا ...", "نعم !"]
        XCTAssertEqual(laidOut(cues(lines)), lines)
    }

    func testArabicCommaMovedToTheStartCountsAsLTRAuthored() {
        let lines = ["،ثم ذهبنا إلى البيت", "،وبعد ذلك", "،لكنه لم يأت", "لا أعرف"]
        XCTAssertEqual(laidOut(cues(lines)), lines.map { lrm + $0 })
    }

    func testStyledRunsGetTheMarkWhereEachLineStarts() {
        let runs = [
            SubtitleTextRun(text: "ماذا حدث", color: nil, isItalic: true),
            SubtitleTextRun(text: " للتو؟ -\nOK\r", color: nil),
            SubtitleTextRun(text: "\nلا أعرف", color: nil, isBold: true),
        ]
        guard case .richText(let marked) = LTRAuthoredSubtitles.applyingLeftToRightBase(to: .richText(runs)) else {
            return XCTFail("expected rich text")
        }
        XCTAssertEqual(marked.map(\.text), [lrm + "ماذا حدث", " للتو؟ -\nOK\r", "\n" + lrm + "لا أعرف"])
        XCTAssertEqual(marked.map(\.isItalic), [true, false, false])
        XCTAssertEqual(marked.map(\.isBold), [false, false, true])
    }
}
