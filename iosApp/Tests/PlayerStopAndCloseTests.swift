import XCTest
@testable import Silo

/// The TV's remote receiver stops a title with `stopAndClose()` when a phone
/// takes over. A title started from a tvOS detail page is a pushed route that
/// the receiver can't dismiss itself, so the stop must not wait for the view
/// to disappear, and the view must be told to close.
@MainActor
final class PlayerStopAndCloseTests: XCTestCase {
    func testRemoteReplacementKeepsPlayerAliveAndPublishesTheNewSelection() {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        player.loadAndPlay(contentId: "outgoing", startFromBeginning: false)
        player.error = "old failure"

        player.replaceSiloControlPlayback(SiloControlPlaybackRequest(
            contentId: "incoming", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: true, resumePosition: 42
        ))

        let state = player.makeSiloControlPlaybackState(contentId: "outgoing")
        XCTAssertEqual(state.contentId, "incoming")
        XCTAssertNil(state.error)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(player.needsReplacementForPresentation)
        XCTAssertNil(player.remoteDismissToken)
    }

    func testRemoteReplacementCannotReviveADisposedPlayer() {
        let player = PlayerViewModel()
        player.loadAndPlay(contentId: "outgoing", startFromBeginning: false)
        player.cleanup()

        player.replaceSiloControlPlayback(SiloControlPlaybackRequest(
            contentId: "incoming", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: false, resumePosition: nil
        ))

        XCTAssertEqual(player.makeSiloControlPlaybackState(contentId: nil).contentId, "outgoing")
        XCTAssertTrue(player.needsReplacementForPresentation)
    }

    func testRemoteReplacementClearsTheOutgoingTitleAndEpisodeMetadata() {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        player.loadAndPlay(contentId: "outgoing", startFromBeginning: false)
        player.title = "Outgoing title"
        player.metadata = PlayerMetadata(
            seriesTitle: "Outgoing series", episodeTag: "S1 · E2",
            primaryTitle: "Outgoing episode", year: nil,
            overview: "Outgoing overview", badges: ["HD"]
        )

        player.replaceSiloControlPlayback(SiloControlPlaybackRequest(
            contentId: "incoming", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: false, resumePosition: nil
        ))

        let state = player.makeSiloControlPlaybackState(contentId: "outgoing")
        XCTAssertEqual(state.contentId, "incoming")
        XCTAssertEqual(state.title, "Loading")
        XCTAssertNil(state.subtitle)
        XCTAssertTrue(player.title.isEmpty)
        XCTAssertEqual(player.metadata, .empty)
    }

    func testRemoteReplacementPublishesOnlyThePreparedItemsSessionAndTimeline() throws {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let version = try decoder.decode(FileVersion.self, from: Data(#"{"file_id":42}"#.utf8))
        func bind(_ contentId: String, sessionId: String) {
            player.bindMarkerReconciliationForTesting(
                sessionId: sessionId,
                detail: WatchDetail(
                    contentId: contentId, type: "movie", title: contentId, year: nil, overview: nil,
                    versions: [version], subtitles: nil, intro: nil, credits: nil, userData: nil,
                    seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
                    effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
                    effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
                ),
                version: version
            )
        }
        player.loadAndPlay(contentId: "outgoing", startFromBeginning: false)
        bind("outgoing", sessionId: "outgoing-session")
        player.currentTime = 120
        player.duration = 3_600
        player.isPlaying = true

        player.replaceSiloControlPlayback(SiloControlPlaybackRequest(
            contentId: "incoming", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: false, resumePosition: nil
        ))

        for isLoading in [true, false] {
            player.isLoading = isLoading
            let state = player.makeSiloControlPlaybackState(contentId: "outgoing")
            XCTAssertEqual(state.contentId, "incoming")
            XCTAssertNil(state.sessionId)
            XCTAssertEqual(state.currentTime, 0)
            XCTAssertEqual(state.duration, 0)
            XCTAssertFalse(state.isPlaying)
        }
        XCTAssertEqual(player.currentTime, 120, "retain outgoing progress for finalization")

        bind("incoming", sessionId: "incoming-session")
        player.currentTime = 24
        player.duration = 1_800
        player.isPlaying = true
        let prepared = player.makeSiloControlPlaybackState(contentId: "outgoing")
        XCTAssertEqual(prepared.sessionId, "incoming-session")
        XCTAssertEqual(prepared.currentTime, 24)
        XCTAssertEqual(prepared.duration, 1_800)
        XCTAssertTrue(prepared.isPlaying)
    }

    func testStopsAtOnceWithoutWaitingForTheViewToDisappear() {
        let player = PlayerViewModel()
        player.stopAndClose()

        XCTAssertTrue(player.needsReplacementForPresentation, "the player must be torn down now")
    }

    func testAsksTheViewToClose() async {
        let player = PlayerViewModel()
        XCTAssertNil(player.remoteDismissToken)

        player.stopAndClose()

        await expectEventually("the view is asked to close") { player.remoteDismissToken != nil }
    }

    #if os(tvOS)
    /// A suspended tvOS app plays nothing, and one killed while suspended
    /// could never stop its session, so the next launch showed a second
    /// stream from the same Apple TV. Leaving the app stops and closes.
    func testLeavingTheAppStopsAndCloses() async {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        player.loadAndPlay(contentId: "movie", startFromBeginning: false)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        await expectEventually("the view is asked to close") { player.remoteDismissToken != nil }
        XCTAssertTrue(player.needsReplacementForPresentation, "cleanup, which stops the session, ran")
    }

    func testLeavingTheAppKeepsAWatchPartyPlayer() async {
        let player = PlayerViewModel()
        let adapter = WatchPartyPlaybackAdapter(player: player)
        defer {
            adapter.stop()
            player.cleanup()
        }
        adapter.prepare(WatchPartyPlaybackContext(
            roomId: "room", selectionRevision: 1, contentId: "movie",
            fileId: 42, libraryId: nil, startPosition: 0
        ))

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        let closed = await eventually(timeout: .milliseconds(300)) { player.remoteDismissToken != nil }
        XCTAssertFalse(closed, "the room needs this session")
        XCTAssertFalse(player.needsReplacementForPresentation)
    }
    #endif
}
