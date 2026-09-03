import SwiftUI
import Observation
import XCTest
@testable import Silo

private actor ContinueWatchingResponseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class DetailDismissalNavigationTests: XCTestCase {
    func testCloseAndRotationControlsWaitForTapInEveryPhase() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        for phase in ["loading", "playing", "next-up", "error"] {
            model.isLoading = phase == "loading"
            model.showNextUpScreen = phase == "next-up"
            model.error = phase == "error" ? "Synthetic playback error" : nil
            XCTAssertFalse(model.shouldShowMobilePlayerChrome, "Close/rotate/lock stay hidden before a tap during \(phase)")
            model.toggleControls()
            XCTAssertTrue(model.shouldShowMobilePlayerChrome, "A tap reveals all chrome during \(phase)")
            model.toggleControls()
            XCTAssertFalse(model.shouldShowMobilePlayerChrome, "A second tap hides all chrome during \(phase)")
            model.revealControls()
            model.dismissControls()
            XCTAssertFalse(model.shouldShowMobilePlayerChrome, "Dismissal hides all chrome during \(phase)")
        }
        model.error = nil
        model.isPlaying = true
        model.toggleControls()
        try await Task.sleep(for: .milliseconds(5300))
        XCTAssertFalse(model.showControls)
        XCTAssertFalse(model.shouldShowMobilePlayerChrome, "Close/rotate/lock auto-hide with transport")
    }

    func testContinueWatchingOpensTheExistingSeriesCardWithTheExactResumeContext() throws {
        let item = try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"episode-s3e2","type":"episode","title":"Second chapter","seriesId":"series","seriesTitle":"A sample series","seasonNumber":3,"episodeNumber":2,"positionSeconds":450,"durationSeconds":2700}"#.utf8
        ))
        let router = AppRouter()
        router.presentContinueWatchingDetail(for: item)
        let presentation = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertEqual(presentation.contentId, "series")
        XCTAssertEqual(presentation.resumeContext?.episodeContentId, "episode-s3e2")
        XCTAssertEqual(presentation.resumeContext?.seasonNumber, 3)
        XCTAssertTrue(router.itemDetailPath.isEmpty, "No intermediate episode page may be pushed")
        XCTAssertNil(router.presentedPlayer, "Opening the card must not start playback")
        router.dismissItemDetail()
        router.presentItemDetail(contentId: "series")
        XCTAssertEqual(router.presentedItemDetail?.contentId, presentation.contentId)
        XCTAssertNil(router.presentedItemDetail?.resumeContext, "A poster open retains its existing defaults")
    }

    func testContinueWatchingKeepsMoviesAndMissingParentFallbacksUnchanged() throws {
        let items = try JSONDecoder().decode([SectionItem].self, from: Data(#"""
        [
          {"contentId":"movie","type":"movie","title":"Movie"},
          {"contentId":"episode","type":"episode","title":"Episode","seriesId":"   "},
          {"contentId":"audio","type":"audiobook","title":"Audio"}
        ]
        """#.utf8))
        let router = AppRouter()
        for item in items {
            router.presentContinueWatchingDetail(for: item)
            XCTAssertEqual(router.presentedItemDetail?.contentId, item.contentId)
            XCTAssertNil(router.presentedItemDetail?.resumeContext)
            router.dismissItemDetail()
        }
    }

    func testContinueWatchingSeasonIntentWinsWithoutChangingPosterDefaults() throws {
        let seasons = try JSONDecoder().decode([Season].self, from: Data(#"""
        [
          {"contentId":"season-1","seasonNumber":1,"episodeCount":8},
          {"contentId":"season-3","seasonNumber":3,"episodeCount":8},
          {"contentId":"specials","seasonNumber":0,"episodeCount":1}
        ]
        """#.utf8))
        let model = ItemDetailViewModel()
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 1)
        model.initialResumeSeasonNumber = 3
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 3)
        model.initialResumeSeasonNumber = 0
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 0)
        model.initialResumeSeasonNumber = 99
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 1)
        model.initialResumeSeasonNumber = nil
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 1)
    }

    func testPreferredInitialSeasonFallsBackToUnplayedSpecials() throws {
        let seasons = try JSONDecoder().decode([Season].self, from: Data(#"""
        [
          {"contentId":"specials","seasonNumber":0,"isSpecials":true,"episodeCount":1},
          {"contentId":"season-1","seasonNumber":1,"episodeCount":8,"userData":{"played":true,"watchedCount":8}},
          {"contentId":"season-2","seasonNumber":2,"episodeCount":8,"userData":{"played":true,"watchedCount":8}}
        ]
        """#.utf8))
        let model = ItemDetailViewModel()
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 0)
    }

    private func resumeLoadFixture() throws -> (ItemDetail, SeasonsResponse, EpisodesResponse) {
        let decoder = JSONDecoder()
        return (
            try decoder.decode(ItemDetail.self, from: Data(#"{"contentId":"resume-speed-series","type":"series","title":"Synthetic series"}"#.utf8)),
            try decoder.decode(SeasonsResponse.self, from: Data(#"{"seasons":[{"contentId":"resume-speed-season","seasonNumber":3,"episodeCount":2}]}"#.utf8)),
            try decoder.decode(EpisodesResponse.self, from: Data(#"{"episodes":[{"contentId":"resume-speed-e2","seasonNumber":3,"episodeNumber":2},{"contentId":"resume-speed-e1","seasonNumber":3,"episodeNumber":1}]}"#.utf8))
        )
    }

    private func clearResumeLoadFixture() {
        ResponseCache.shared.removeAll(withPrefix: "item:resume-speed-series")
    }

    func testContinueWatchingCachedSeasonAndEpisodesPaintWithoutAwaitingNetwork() throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        ResponseCache.shared.set(detail, for: CacheKey.itemDetail(detail.contentId))
        ResponseCache.shared.set(seasons, for: CacheKey.itemSeasons(detail.contentId))
        ResponseCache.shared.set(episodes, for: CacheKey.itemEpisodes(seriesId: detail.contentId, seasonNumber: 3))
        let model = ItemDetailViewModel()
        model.initialResumeSeasonNumber = 3
        model.hydrateFromCache(contentId: detail.contentId)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 3)
        XCTAssertEqual(model.episodes.map(\.episodeNumber), [1, 2])
        XCTAssertEqual(model.episodesBySeason[3], model.episodes)
        XCTAssertFalse(model.isLoadingEpisodes)

        let posterModel = ItemDetailViewModel()
        posterModel.hydrateFromCache(contentId: detail.contentId)
        XCTAssertNil(posterModel.selectedSeason, "Poster initialization must remain unchanged")
        XCTAssertTrue(posterModel.episodes.isEmpty)
    }

    func testContinueWatchingRequestsBothResourcesBeforeEitherResponseReturns() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        let seasonStarted = expectation(description: "Seasons dispatched")
        let episodesStarted = expectation(description: "Episodes dispatched")
        let gate = ContinueWatchingResponseGate()
        let model = ItemDetailViewModel()
        let load = Task {
            await model.loadContinueWatchingStructure(
                contentId: detail.contentId, seasonNumber: 3,
                fetchSeasons: { _ in
                    seasonStarted.fulfill()
                    await gate.wait()
                    return seasons
                },
                fetchEpisodes: { _, number in
                    XCTAssertEqual(number, 3)
                    episodesStarted.fulfill()
                    await gate.wait()
                    return episodes
                }
            )
        }
        await fulfillment(of: [seasonStarted, episodesStarted], timeout: 2)
        await gate.open()
        await load.value
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 3)
        XCTAssertEqual(model.episodes.map(\.episodeNumber), [1, 2])
    }

    func testContinueWatchingRefreshDoesNotRebuildUnchangedScrollContent() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        let model = ItemDetailViewModel()
        model.seasons = seasons.seasons
        model.selectedSeason = seasons.seasons[0]
        model.episodes = episodes.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        model.episodesBySeason[3] = model.episodes
        let changed = expectation(description: "Unchanged scroll content must not be republished")
        changed.isInverted = true
        withObservationTracking {
            _ = model.seasons
            _ = model.selectedSeason
            _ = model.episodes
            _ = model.episodesBySeason
            _ = model.isLoadingEpisodes
        } onChange: {
            changed.fulfill()
        }
        await model.loadContinueWatchingStructure(
            contentId: detail.contentId, seasonNumber: 3,
            fetchSeasons: { _ in seasons }, fetchEpisodes: { _, _ in episodes }
        )
        await fulfillment(of: [changed], timeout: 0.05)
        XCTAssertFalse(model.isLoadingEpisodes)
    }

    func testContinueWatchingHierarchySuccessDoesNotConsumePendingCatalogIntent() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        let model = ItemDetailViewModel()
        model.initialResumeSeasonNumber = 3
        let loaded = await model.loadContinueWatchingStructure(
            contentId: detail.contentId, seasonNumber: model.initialResumeSeasonNumber,
            fetchSeasons: { _ in seasons }, fetchEpisodes: { _, _ in episodes }
        )
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 3)
        XCTAssertEqual(model.initialResumeSeasonNumber, 3,
                       "Hierarchy success alone must not consume the intent while catalog can still fail")
        XCTAssertNil(model.detail, "This response arrived before a successful catalog load")
    }

    func testContinueWatchingHierarchyFailuresRetainTheRequestedSeasonForRetry() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        for failedResource in ["seasons", "episodes", "both"] {
            let model = ItemDetailViewModel()
            model.initialResumeSeasonNumber = 3
            let loaded = await model.loadContinueWatchingStructure(
                contentId: detail.contentId, seasonNumber: model.initialResumeSeasonNumber,
                fetchSeasons: { _ in
                    if failedResource != "episodes" { throw URLError(.notConnectedToInternet) }
                    return seasons
                },
                fetchEpisodes: { _, _ in
                    if failedResource != "seasons" { throw URLError(.notConnectedToInternet) }
                    return episodes
                }
            )
            XCTAssertFalse(loaded)
            XCTAssertEqual(model.initialResumeSeasonNumber, 3)
            let retried = await model.loadContinueWatchingStructure(
                contentId: detail.contentId, seasonNumber: model.initialResumeSeasonNumber,
                fetchSeasons: { _ in seasons }, fetchEpisodes: { _, _ in episodes }
            )
            XCTAssertTrue(retried)
            XCTAssertEqual(model.selectedSeason?.seasonNumber, 3)
            XCTAssertEqual(model.episodes.map(\.episodeNumber), [1, 2])
        }
    }

    func testContinueWatchingEntryCannotOverwriteASeasonTapWhileRequestsArePending() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        let started = expectation(description: "Entry request started")
        let gate = ContinueWatchingResponseGate()
        let model = ItemDetailViewModel()
        model.initialResumeSeasonNumber = 3
        // A cached manually selected page uses the existing instant tap path.
        let manualSeason = try JSONDecoder().decode(Season.self, from: Data(
            #"{"contentId":"manual-season","seasonNumber":1,"episodeCount":0}"#.utf8
        ))
        model.episodesBySeason[1] = []
        let load = Task {
            await model.loadContinueWatchingStructure(
                contentId: detail.contentId, seasonNumber: 3,
                fetchSeasons: { _ in
                    started.fulfill()
                    await gate.wait()
                    return seasons
                }, fetchEpisodes: { _, _ in episodes }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        await model.selectSeason(manualSeason)
        await gate.open()
        await load.value
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 1)
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertNil(model.initialResumeSeasonNumber)
    }

    func testContinueWatchingFailedRefreshKeepsTheCachedPageAndCancellationPublishesNothing() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        let model = ItemDetailViewModel()
        model.seasons = seasons.seasons
        model.selectedSeason = seasons.seasons[0]
        model.episodes = episodes.episodes
        await model.loadContinueWatchingStructure(
            contentId: detail.contentId, seasonNumber: 3,
            fetchSeasons: { _ in throw URLError(.notConnectedToInternet) },
            fetchEpisodes: { _, _ in throw URLError(.notConnectedToInternet) }
        )
        XCTAssertEqual(model.episodes, episodes.episodes)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 3)
        XCTAssertFalse(model.isLoadingEpisodes)

        let started = expectation(description: "Cancellable request started")
        let gate = ContinueWatchingResponseGate()
        let cancelledModel = ItemDetailViewModel()
        cancelledModel.initialResumeSeasonNumber = 3
        let load = Task {
            await cancelledModel.loadContinueWatchingStructure(
                contentId: detail.contentId, seasonNumber: 3,
                fetchSeasons: { _ in
                    started.fulfill()
                    await gate.wait()
                    return seasons
                }, fetchEpisodes: { _, _ in episodes }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        load.cancel()
        await gate.open()
        await load.value
        XCTAssertTrue(cancelledModel.seasons.isEmpty)
        XCTAssertTrue(cancelledModel.episodes.isEmpty)
        XCTAssertNil(cancelledModel.selectedSeason)
        XCTAssertEqual(cancelledModel.initialResumeSeasonNumber, 3,
                       "Cancellation must not consume the pending resume entry")
    }

    func testContinueWatchingHierarchyRequestBenchmark() async throws {
        let (detail, seasons, episodes) = try resumeLoadFixture()
        defer { clearResumeLoadFixture() }
        let clock = ContinuousClock()
        var serialMilliseconds: [Double] = []
        var resumeMilliseconds: [Double] = []
        let fetchSeasons: @Sendable (String) async throws -> SeasonsResponse = { _ in
            try await Task.sleep(for: .milliseconds(150))
            return seasons
        }
        let fetchEpisodes: @Sendable (String, Int) async throws -> EpisodesResponse = { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return episodes
        }
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        for _ in 0..<5 {
            let serialStart = clock.now
            _ = try await fetchSeasons(detail.contentId)
            _ = try await fetchEpisodes(detail.contentId, 3)
            serialMilliseconds.append(milliseconds(serialStart.duration(to: clock.now)))
            let model = ItemDetailViewModel()
            let resumeStart = clock.now
            await model.loadContinueWatchingStructure(
                contentId: detail.contentId, seasonNumber: 3,
                fetchSeasons: fetchSeasons, fetchEpisodes: fetchEpisodes
            )
            resumeMilliseconds.append(milliseconds(resumeStart.duration(to: clock.now)))
            XCTAssertEqual(model.episodes.count, 2)
        }
        // Synthetic hierarchy latency only, not server timing or a scroll-FPS claim.
        print("CW hierarchy benchmark; 5 repetitions; 150ms per resource; serial-ms=\(serialMilliseconds); resume-ms=\(resumeMilliseconds)")
    }

    func testRotationLockCapturesTheExactScreenOrientation() {
        for orientation: UIInterfaceOrientationMask in [.portrait, .landscapeLeft, .landscapeRight] {
            var state = PlayerRotationState()
            state.activate()
            state.toggleLock(at: orientation)
            XCTAssertTrue(state.isLocked)
            XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
                isPlayerActive: state.isPlayerActive, lockedOrientation: state.lockedOrientation
            ), orientation)
            XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
                isPlayerActive: state.isPlayerActive, preferredOrientation: .allButUpsideDown,
                lockedOrientation: state.lockedOrientation
            ), orientation)
        }
    }

    func testManualRotationWorksWhileLockedAndKeepsTheNewOrientationLocked() {
        var state = PlayerRotationState()
        state.activate()
        state.toggleLock(at: .portrait)
        for target: UIInterfaceOrientationMask in [.landscapeRight, .portrait, .landscapeLeft, .portrait] {
            state.manuallyRotate(to: target)
            XCTAssertTrue(state.isLocked)
            XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
                isPlayerActive: state.isPlayerActive, preferredOrientation: target,
                lockedOrientation: state.lockedOrientation
            ), target)
        }
    }

    func testUnlockingRestoresPhoneRotationAndClosingClearsTheSessionLock() {
        var state = PlayerRotationState()
        state.activate()
        state.toggleLock(at: .landscapeRight)
        state.toggleLock(at: .landscapeRight)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: state.isPlayerActive, lockedOrientation: state.lockedOrientation
        ), .allButUpsideDown)
        state.toggleLock(at: .landscapeLeft)
        state.deactivate()
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: state.isPlayerActive, lockedOrientation: state.lockedOrientation,
            browsingOrientations: .portrait
        ), .portrait)
        state.activate()
        XCTAssertFalse(state.isLocked)
    }

    func testPersistedLandscapeLockOpensTheSessionLockedAndMapsBackToTheRemoteMode() {
        var state = PlayerRotationState()
        state.activate(lockedOrientation: .landscapeRight)
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.persistedOrientationMode, .landscapeLocked)
        state.toggleLock(at: .landscapeRight)
        XCTAssertEqual(state.persistedOrientationMode, .rotateFreely)
        // A portrait lock has no remote representation; leave the stored mode alone.
        state.toggleLock(at: .portrait)
        XCTAssertNil(state.persistedOrientationMode)
        state.manuallyRotate(to: .landscapeLeft)
        XCTAssertEqual(state.persistedOrientationMode, .landscapeLocked)
    }

    func testBrowsingStaysPortraitOnPhoneAndRotatesOnPad() {
        XCTAssertEqual(PlayerOrientationCoordinator.browsingOrientations(isPad: false), .portrait)
        XCTAssertEqual(PlayerOrientationCoordinator.browsingOrientations(isPad: true), .allButUpsideDown)
        XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
            isPlayerActive: false, preferredOrientation: .landscape, browsingOrientations: .allButUpsideDown
        ), .landscape)
    }

    func testManualRotationDoesNotImplicitlyEnableTheLock() {
        var state = PlayerRotationState()
        state.activate()
        state.manuallyRotate(to: .landscapeRight)
        state.manuallyRotate(to: .portrait)
        XCTAssertFalse(state.isLocked)
        state.deactivate()
        state.toggleLock(at: .landscapeRight)
        state.manuallyRotate(to: .landscapeLeft)
        XCTAssertFalse(state.isLocked)
    }

    func testRotationPillFollowsTheActualInterfaceOrientation() {
        XCTAssertEqual(PlayerScreenOrientation(interfaceOrientation: .portrait)?.toggled, .landscape)
        XCTAssertEqual(PlayerScreenOrientation(interfaceOrientation: .landscapeLeft)?.toggled, .portrait)
        XCTAssertEqual(PlayerScreenOrientation(interfaceOrientation: .landscapeRight)?.toggled, .portrait)
        XCTAssertNil(PlayerScreenOrientation(interfaceOrientation: .unknown))
    }

    func testManualRotationRequestsDoNotLockSubsequentPhoneRotation() {
        for orientation in [PlayerScreenOrientation.portrait, .landscape] {
            XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
                isPlayerActive: true, preferredOrientation: orientation.mask
            ), orientation.mask)
            XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(isPlayerActive: true), .allButUpsideDown)
        }
    }

    func testAQueuedVideoRotationCannotUnlockBrowsingPages() {
        for mask: UIInterfaceOrientationMask in [.portrait, .landscape, .landscapeLeft, .landscapeRight, .all] {
            XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
                isPlayerActive: false, preferredOrientation: mask, browsingOrientations: .portrait
            ), .portrait)
        }
    }

    func testVideoAllowsPortraitAndBothLandscapeDirections() {
        let playback = PlayerOrientationCoordinator.orientationMask(isPlayerActive: true)
        XCTAssertTrue(playback.contains(.portrait))
        XCTAssertTrue(playback.contains(.landscapeLeft))
        XCTAssertTrue(playback.contains(.landscapeRight))
        XCTAssertFalse(playback.contains(.portraitUpsideDown))
    }

    func testLeavingVideoRestoresPortraitEvenWhenTheDeviceStaysLandscape() {
        let browsing = PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: false, browsingOrientations: .portrait
        )
        XCTAssertEqual(browsing, .portrait)
        XCTAssertFalse(browsing.contains(.landscapeLeft))
        XCTAssertFalse(browsing.contains(.landscapeRight))
    }

    func testPlayerFromDetailHasOneOwnerAndReturnsToTheSameNestedPage() throws {
        let router = AppRouter()
        router.presentItemDetail(contentId: "series")
        router.navigate(to: .personDetail(personId: 42))
        router.presentItemDetail(contentId: "movie")
        let detail = try XCTUnwrap(router.presentedItemDetail)
        router.presentPlayer(contentId: "movie")
        let player = try XCTUnwrap(router.presentedPlayer)

        XCTAssertNil(router.playerPresentation(forDetailID: nil))
        XCTAssertEqual(router.playerPresentation(forDetailID: detail.id)?.id, player.id)
        XCTAssertNil(router.playerPresentation(forDetailID: UUID()))
        router.dismissPlayerPresentation(id: player.id)
        XCTAssertNil(router.presentedPlayer)
        XCTAssertEqual(router.presentedItemDetail?.id, detail.id)
        XCTAssertEqual(router.presentedItemDetail?.contentId, "series")
        XCTAssertEqual(router.itemDetailPath.count, 2)
    }

    func testRootPlayerDoesNotCreateOrDismissAnUnrelatedDetail() throws {
        let router = AppRouter()
        router.presentPlayer(contentId: "movie")
        let player = try XCTUnwrap(router.playerPresentation(forDetailID: nil))
        XCTAssertNil(player.detailPresentationID)
        router.dismissPlayerPresentation(id: player.id)
        XCTAssertNil(router.presentedItemDetail)
        XCTAssertTrue(router.itemDetailPath.isEmpty)
    }

    func testOfflinePlayerPreservesItsDetailOwner() throws {
        let router = AppRouter()
        router.presentItemDetail(contentId: "movie")
        let detail = try XCTUnwrap(router.presentedItemDetail)
        router.presentOfflinePlayer(downloadId: "download", contentId: "movie")
        let player = try XCTUnwrap(router.presentedPlayer)
        XCTAssertEqual(player.detailPresentationID, detail.id)
        XCTAssertEqual(player.offlineDownloadId, "download")
        router.dismissPlayerPresentation(id: player.id)
        XCTAssertEqual(router.presentedItemDetail?.id, detail.id)
    }

    func testOutgoingPlayerCannotDismissANewerPresentation() throws {
        let router = AppRouter()
        router.presentPlayer(contentId: "first")
        let first = try XCTUnwrap(router.presentedPlayer)
        router.presentPlayer(contentId: "second")
        let second = try XCTUnwrap(router.presentedPlayer)
        router.dismissPlayerPresentation(id: first.id)
        XCTAssertEqual(router.presentedPlayer?.id, second.id)
    }

    func testReopenedPiPPayloadRetainsOwnerAndPlaybackChoices() throws {
        let router = AppRouter()
        router.presentItemDetail(contentId: "series")
        router.presentPlayer(contentId: "episode", fileId: 7, audioTrackIndex: 2,
                             subtitleTrackIndex: 3, resumePosition: 120)
        let original = try XCTUnwrap(router.presentedPlayer)
        let reopened = original.reopened()
        XCTAssertNotEqual(reopened.id, original.id)
        XCTAssertEqual(reopened.detailPresentationID, original.detailPresentationID)
        XCTAssertEqual(reopened.contentId, original.contentId)
        XCTAssertEqual(reopened.fileId, original.fileId)
        XCTAssertEqual(reopened.audioTrackIndex, original.audioTrackIndex)
        XCTAssertEqual(reopened.subtitleTrackIndex, original.subtitleTrackIndex)
        XCTAssertEqual(reopened.resumePosition, original.resumePosition)
    }

    func testActorPullGoesBackOnePageWithoutClosingTheSheet() throws {
        let router = AppRouter()
        router.presentItemDetail(contentId: "series")
        let detail = try XCTUnwrap(router.presentedItemDetail)
        router.presentItemDetail(contentId: "episode")
        router.navigate(to: .personDetail(personId: 42))
        router.goBackInItemDetail()
        XCTAssertEqual(router.itemDetailPath.count, 1)
        XCTAssertEqual(router.presentedItemDetail?.id, detail.id)
        router.goBackInItemDetail()
        router.goBackInItemDetail()
        XCTAssertTrue(router.itemDetailPath.isEmpty)
        XCTAssertEqual(router.presentedItemDetail?.id, detail.id)
    }

    func testLateSheetDismissCallbackCannotClearAnOpenDetailOrItsPlayer() throws {
        let router = AppRouter()
        router.presentItemDetail(contentId: "series")
        router.navigate(to: .personDetail(personId: 42))
        router.presentPlayer(contentId: "episode")
        let detail = router.presentedItemDetail
        let player = router.presentedPlayer
        router.itemDetailPresentationDidDismiss()
        XCTAssertEqual(router.presentedItemDetail, detail)
        XCTAssertEqual(router.presentedPlayer, player)
        XCTAssertEqual(router.itemDetailPath.count, 1)
    }

    func testDismissedSheetClearsOnlyItsNestedPath() {
        let router = AppRouter()
        router.presentItemDetail(contentId: "series")
        router.navigate(to: .personDetail(personId: 42))
        router.presentedItemDetail = nil // SwiftUI's sheet binding clears first.
        router.itemDetailPresentationDidDismiss()
        XCTAssertTrue(router.itemDetailPath.isEmpty)
    }

    func testTopHandoffIncludesBounceWithoutWaitingForAnIdlePhase() {
        for offset in [-95.0, -60.0, -59.0] {
            XCTAssertTrue(DetailDismissalPolicy.isAtTop(offset: offset, topInset: 60))
        }
        XCTAssertFalse(DetailDismissalPolicy.isAtTop(offset: -58, topInset: 60))
        XCTAssertFalse(DetailDismissalPolicy.isAtTop(offset: 400, topInset: 60))
    }

    func testBackGestureDoesNotStealHorizontalUpwardOrMidPageScrolling() {
        XCTAssertTrue(DetailDismissalPolicy.canBeginBack(isAtTop: true, velocity: .init(x: 10, y: 200)))
        XCTAssertFalse(DetailDismissalPolicy.canBeginBack(isAtTop: false, velocity: .init(x: 0, y: 500)))
        XCTAssertFalse(DetailDismissalPolicy.canBeginBack(isAtTop: true, velocity: .init(x: 500, y: 20)))
        XCTAssertFalse(DetailDismissalPolicy.canBeginBack(isAtTop: true, velocity: .init(x: 0, y: -500)))
    }

    func testBackRequiresADecisivePullAndAllowsCancel() {
        XCTAssertTrue(DetailDismissalPolicy.shouldCompleteBack(translation: .init(x: 0, y: 110), velocity: .zero))
        XCTAssertTrue(DetailDismissalPolicy.shouldCompleteBack(translation: .init(x: 5, y: 40), velocity: .init(x: 0, y: 950)))
        XCTAssertFalse(DetailDismissalPolicy.shouldCompleteBack(translation: .init(x: 0, y: 20), velocity: .zero))
        XCTAssertFalse(DetailDismissalPolicy.shouldCompleteBack(translation: .init(x: 0, y: -10), velocity: .zero))
        XCTAssertFalse(DetailDismissalPolicy.shouldCompleteBack(translation: .init(x: 120, y: 110), velocity: .zero))
    }
}
