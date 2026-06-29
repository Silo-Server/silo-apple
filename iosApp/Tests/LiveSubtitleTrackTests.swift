import XCTest
@testable import Silo

/// Tests for `LiveSubtitleTrack` — the pure cue→ASS conversion that feeds
/// the libass `ass_process_chunk` live-render path. The crux is that the
/// produced `eventText` matches the FFmpeg `rect.ass` *chunk* format the
/// proven embedded path already feeds:
/// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
/// (no Start/End — those ride as the `startMs`/`durationMs` args).
final class LiveSubtitleTrackTests: XCTestCase {

    // MARK: - Event body format

    func testEventBodyMatchesFFmpegChunkFormat() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 1.0, end: 3.0, text: "Hello world")
        XCTAssertNotNil(cue)
        // ReadOrder 0 for the first cue, Layer 0, Style Default, empty
        // Name, zero margins, empty Effect, then the escaped text.
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,Hello world")
    }

    func testEventBodyHasNoTimestampsInline() {
        // Start/End must NOT appear in the chunk body — they are passed
        // separately to ass_process_chunk. Guard against a regression that
        // accidentally emits a full `Dialogue:` line.
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 65.0, end: 70.0, text: "No timestamps here")
        XCTAssertNotNil(cue)
        XCTAssertFalse(cue!.eventText.contains("Dialogue:"))
        XCTAssertFalse(cue!.eventText.contains("1:05"))     // no ASS H:MM:SS
        XCTAssertFalse(cue!.eventText.contains("0:01:05"))
        XCTAssertTrue(cue!.eventText.hasPrefix("0,0,Default,,0,0,0,,"))
    }

    func testReadOrderMonotonicallyIncrements() {
        var track = LiveSubtitleTrack()
        let c0 = track.makeCue(start: 0, end: 1, text: "a")
        let c1 = track.makeCue(start: 1, end: 2, text: "b")
        let c2 = track.makeCue(start: 2, end: 3, text: "c")
        XCTAssertEqual(c0?.eventText, "0,0,Default,,0,0,0,,a")
        XCTAssertEqual(c1?.eventText, "1,0,Default,,0,0,0,,b")
        XCTAssertEqual(c2?.eventText, "2,0,Default,,0,0,0,,c")
    }

    // MARK: - Seconds → milliseconds

    func testSecondsToMilliseconds() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 1.5, end: 4.25, text: "x")
        XCTAssertEqual(cue?.startMs, 1500)
        XCTAssertEqual(cue?.durationMs, 2750)
        XCTAssertEqual(cue?.endMs, 4250)
    }

    func testSecondsToMsRoundsToNearest() {
        XCTAssertEqual(LiveSubtitleTrack.secondsToMs(1.2345), 1235)   // .5 ms rounds up
        XCTAssertEqual(LiveSubtitleTrack.secondsToMs(1.2344), 1234)
        XCTAssertEqual(LiveSubtitleTrack.secondsToMs(0.0), 0)
    }

    func testNegativeAndNonFiniteSecondsClampToZero() {
        XCTAssertEqual(LiveSubtitleTrack.secondsToMs(-5.0), 0)
        XCTAssertEqual(LiveSubtitleTrack.secondsToMs(.nan), 0)
        XCTAssertEqual(LiveSubtitleTrack.secondsToMs(.infinity), 0)
    }

    // MARK: - Newline → \N

    func testNewlineBecomesHardBreak() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "line one\nline two")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,line one\\Nline two")
    }

    func testCarriageReturnNewlinesNormalised() {
        var track = LiveSubtitleTrack()
        let crlf = track.makeCue(start: 0, end: 1, text: "a\r\nb")
        XCTAssertEqual(crlf?.eventText, "0,0,Default,,0,0,0,,a\\Nb")

        var track2 = LiveSubtitleTrack()
        let cr = track2.makeCue(start: 0, end: 1, text: "a\rb")
        XCTAssertEqual(cr?.eventText, "0,0,Default,,0,0,0,,a\\Nb")
    }

    func testMultipleNewlines() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "one\ntwo\nthree")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,one\\Ntwo\\Nthree")
    }

    // MARK: - Brace / backslash escaping

    func testBracesAreStripped() {
        var track = LiveSubtitleTrack()
        // Literal braces would open a rogue ASS override block; they are
        // dropped along with the backslash (matching VTTToASSConverter), so
        // "{\b1}bold{\b0}" collapses to "b1boldb0".
        let cue = track.makeCue(start: 0, end: 1, text: "a {\\b1}bold{\\b0} b")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,a b1boldb0 b")
    }

    func testBackslashIsStripped() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "path\\to\\file")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,pathtofile")
    }

    func testBackslashNLiteralInSourceDoesNotSurviveAsOverride() {
        // A literal backslash followed by 'n' (not a real newline char):
        // the backslash is dropped, leaving "n". This prevents injecting
        // an ASS escape from cue text.
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "a\\nb")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,anb")
    }

    func testWhitespaceTrimmed() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "   padded   ")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,padded")
    }

    func testUnicodeIsPreserved() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "日本語 émoji 🎬")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,日本語 émoji 🎬")
    }

    // MARK: - Dedupe

    func testDuplicateCueIsDropped() {
        var track = LiveSubtitleTrack()
        let first = track.makeCue(start: 1.0, end: 2.0, text: "same")
        let second = track.makeCue(start: 1.0, end: 2.0, text: "same")
        XCTAssertNotNil(first)
        XCTAssertNil(second, "identical (start,end,text) cue must dedupe to nil")
    }

    func testDifferentTextAtSameTimeIsNotDuplicate() {
        var track = LiveSubtitleTrack()
        let first = track.makeCue(start: 1.0, end: 2.0, text: "alpha")
        let second = track.makeCue(start: 1.0, end: 2.0, text: "beta")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        // Second still gets a fresh ReadOrder.
        XCTAssertEqual(second?.eventText, "1,0,Default,,0,0,0,,beta")
    }

    func testSameTextAtDifferentTimeIsNotDuplicate() {
        var track = LiveSubtitleTrack()
        let first = track.makeCue(start: 1.0, end: 2.0, text: "repeat")
        let second = track.makeCue(start: 5.0, end: 6.0, text: "repeat")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.startMs, 5000)
    }

    func testDedupeKeyedOnEscapedText() {
        // Two source strings that escape to the same ASS body should
        // dedupe (the dedupe key uses the escaped text).
        var track = LiveSubtitleTrack()
        let first = track.makeCue(start: 1.0, end: 2.0, text: "a{b}c")
        let second = track.makeCue(start: 1.0, end: 2.0, text: "abc")
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.eventText, "0,0,Default,,0,0,0,,abc")
        XCTAssertNil(second, "cues escaping to identical text at the same time must dedupe")
    }

    // MARK: - Overlapping / out-of-order

    func testOverlappingCuesBothEmitted() {
        var track = LiveSubtitleTrack()
        let a = track.makeCue(start: 0.0, end: 5.0, text: "long cue")
        let b = track.makeCue(start: 2.0, end: 4.0, text: "overlapping cue")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.startMs, 0)
        XCTAssertEqual(a?.durationMs, 5000)
        XCTAssertEqual(b?.startMs, 2000)
        XCTAssertEqual(b?.durationMs, 2000)
    }

    func testOutOfOrderCuesPreserveTheirOwnTimes() {
        var track = LiveSubtitleTrack()
        let later = track.makeCue(start: 10.0, end: 12.0, text: "later")
        let earlier = track.makeCue(start: 1.0, end: 2.0, text: "earlier")
        XCTAssertEqual(later?.startMs, 10_000)
        XCTAssertEqual(earlier?.startMs, 1_000)
        // ReadOrder follows feed order, not media time.
        XCTAssertEqual(later?.eventText, "0,0,Default,,0,0,0,,later")
        XCTAssertEqual(earlier?.eventText, "1,0,Default,,0,0,0,,earlier")
    }

    func testEndBeforeStartClampsDurationToZero() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 5.0, end: 3.0, text: "inverted")
        XCTAssertEqual(cue?.startMs, 5000)
        XCTAssertEqual(cue?.durationMs, 0, "end before start must not produce a negative duration")
        XCTAssertEqual(cue?.endMs, 5000)
    }

    func testEmptyTextProducesEmptyBody() {
        var track = LiveSubtitleTrack()
        let cue = track.makeCue(start: 0, end: 1, text: "")
        XCTAssertEqual(cue?.eventText, "0,0,Default,,0,0,0,,")
    }
}
