import XCTest
@testable import Silo

final class AudiobookProgressTests: XCTestCase {

    private func chapter(_ index: Int, _ start: Double) -> AudioPlaybackChapter {
        AudioPlaybackChapter(
            index: index,
            title: "Chapter \(index + 1)",
            startSeconds: start,
            endSeconds: nil,
            trackIndex: 0
        )
    }

    // MARK: - Downloaded book

    private func downloadedBook(manifestJSON: String) throws -> AudiobookPlaybackContext? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(OfflineManifest.self, from: Data(manifestJSON.utf8))
        let record = DownloadRecord(
            id: "d1", contentId: "book-1", episodeId: nil, batchId: nil, mediaFileId: "77",
            format: "original", serverStatus: "ready", localStatus: .completed, fileSize: 1, bytesDownloaded: 1,
            mediaFilename: "media.m4a", manifestFilename: "manifest.json", posterFilename: nil,
            backdropFilename: nil, logoFilename: nil, subtitleFilenames: [:], title: "Mistborn",
            subtitle: "Brandon Sanderson", type: "audiobook", seriesId: nil, posterThumbhash: nil,
            container: "mp4", stableIdentity: nil, registeredAt: Date(), downloadedAt: nil, lastError: nil,
            retryCount: 0, taskIdentifier: nil
        )
        return AudiobookPlaybackContext(download: record, manifest: manifest, posterUrl: nil, resumePositionSeconds: 9_000)
    }

    /// Offline, the stored manifest is the book: one track over the whole
    /// file, its chapters, and a length measured from them when the file
    /// reported none.
    func testDownloadedBookPlaysAsOneTrackWithItsChapters() throws {
        let book = try XCTUnwrap(downloadedBook(manifestJSON: """
        {"download_id":"d1","content_id":"book-1","type":"audiobook","title":"Mistborn","quality":"original",
         "media_file_id":"77","chapters":[{"index":1,"title":"Two","start_seconds":1800,"end_seconds":3600},
         {"index":0,"title":"One","start_seconds":0,"end_seconds":1800}]}
        """))

        XCTAssertEqual(book.tracks.map(\.fileId), [77])
        XCTAssertEqual(book.tracks.first?.startOffsetSeconds, 0)
        XCTAssertEqual(book.totalDurationSeconds, 3600)
        XCTAssertEqual(book.chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(book.resumePositionSeconds, 3600, "a resume point past the end is clamped to it")
        XCTAssertEqual(book.title, "Mistborn")
        XCTAssertEqual(book.subtitle, "Brandon Sanderson")
    }

    func testDownloadedBookWithoutALengthIsRefused() throws {
        XCTAssertNil(try downloadedBook(manifestJSON: """
        {"download_id":"d1","content_id":"book-1","type":"audiobook","title":"Mistborn","quality":"original","media_file_id":"77"}
        """))
    }

    // MARK: - resumePosition

    func testResumeNilUnderThirtySeconds() {
        XCTAssertNil(AudiobookProgress.resumePosition(position: 12, totalDuration: 3600))
    }

    func testResumeValueAboveThreshold() {
        XCTAssertEqual(AudiobookProgress.resumePosition(position: 900, totalDuration: 3600), 900)
    }

    func testResumeNilWithinFiveSecondsOfEnd() {
        XCTAssertNil(AudiobookProgress.resumePosition(position: 3597, totalDuration: 3600))
    }

    func testResumeNilForNonFinitePosition() {
        XCTAssertNil(AudiobookProgress.resumePosition(position: .infinity, totalDuration: 3600))
        XCTAssertNil(AudiobookProgress.resumePosition(position: .nan, totalDuration: 3600))
    }

    func testResumeNilForNilPosition() {
        XCTAssertNil(AudiobookProgress.resumePosition(position: nil, totalDuration: 3600))
    }

    func testResumeIgnoresEndGuardWhenDurationUnknown() {
        // With no known duration the end guard can't apply, so any position
        // past the intro grace still resumes.
        XCTAssertEqual(AudiobookProgress.resumePosition(position: 5000, totalDuration: 0), 5000)
    }

    // MARK: - isFinished

    func testFinishedByPlayedFlag() {
        XCTAssertTrue(AudiobookProgress.isFinished(played: true, position: 0, totalDuration: 3600))
    }

    func testFinishedByPositionNearEnd() {
        XCTAssertTrue(AudiobookProgress.isFinished(played: false, position: 3598, totalDuration: 3600))
    }

    func testNotFinishedMidBook() {
        XCTAssertFalse(AudiobookProgress.isFinished(played: false, position: 1800, totalDuration: 3600))
    }

    func testNotFinishedWithZeroDuration() {
        XCTAssertFalse(AudiobookProgress.isFinished(played: false, position: 1800, totalDuration: 0))
    }

    // MARK: - currentChapterIndex

    func testCurrentChapterEmptyListIsNil() {
        XCTAssertNil(AudiobookProgress.currentChapterIndex(chapters: [], position: 100))
    }

    func testCurrentChapterBeforeFirstStartIsZero() {
        let chapters = [chapter(0, 10), chapter(1, 100)]
        XCTAssertEqual(AudiobookProgress.currentChapterIndex(chapters: chapters, position: 0), 0)
    }

    func testCurrentChapterExactBoundary() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 200)]
        XCTAssertEqual(AudiobookProgress.currentChapterIndex(chapters: chapters, position: 100), 1)
    }

    func testCurrentChapterBetweenChapters() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 200)]
        XCTAssertEqual(AudiobookProgress.currentChapterIndex(chapters: chapters, position: 150), 1)
    }

    func testCurrentChapterPastLast() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 200)]
        XCTAssertEqual(AudiobookProgress.currentChapterIndex(chapters: chapters, position: 9999), 2)
    }

    // MARK: - chapterDuration

    func testChapterDurationMiddle() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 250)]
        XCTAssertEqual(
            AudiobookProgress.chapterDuration(chapters: chapters, at: 1, totalDuration: 600),
            150
        )
    }

    func testChapterDurationLastUsesTotal() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 250)]
        XCTAssertEqual(
            AudiobookProgress.chapterDuration(chapters: chapters, at: 2, totalDuration: 600),
            350
        )
    }

    func testChapterDurationClampedNonNegative() {
        // A stale total shorter than the last chapter start must not go negative.
        let chapters = [chapter(0, 0), chapter(1, 500)]
        XCTAssertEqual(
            AudiobookProgress.chapterDuration(chapters: chapters, at: 1, totalDuration: 300),
            0
        )
    }

    func testChapterDurationOutOfRange() {
        let chapters = [chapter(0, 0)]
        XCTAssertEqual(
            AudiobookProgress.chapterDuration(chapters: chapters, at: 5, totalDuration: 600),
            0
        )
    }

    // MARK: - isChapterFinished

    func testChapterFinishedWhenPositionPastEnd() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 250)]
        // Chapter 0 ends at 100; position 120 is past it.
        XCTAssertTrue(
            AudiobookProgress.isChapterFinished(chapters: chapters, at: 0, position: 120, totalDuration: 600)
        )
    }

    func testChapterNotFinishedMidChapter() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 250)]
        XCTAssertFalse(
            AudiobookProgress.isChapterFinished(chapters: chapters, at: 1, position: 150, totalDuration: 600)
        )
    }

    func testChapterFinishedAtExactBoundary() {
        let chapters = [chapter(0, 0), chapter(1, 100), chapter(2, 250)]
        // Chapter 0 ends exactly at 100 — the boundary counts as finished.
        XCTAssertTrue(
            AudiobookProgress.isChapterFinished(chapters: chapters, at: 0, position: 100, totalDuration: 600)
        )
    }
}
