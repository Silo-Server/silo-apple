import SwiftUI
import XCTest
@testable import Silo

@MainActor
final class DetailDismissalNavigationTests: XCTestCase {
    func testRotationControlsWaitForTapAndFollowTransportVisibilityInEveryPhase() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        for phase in ["loading", "playing", "next-up", "error"] {
            model.isLoading = phase == "loading"
            model.showNextUpScreen = phase == "next-up"
            model.error = phase == "error" ? "Synthetic playback error" : nil
            XCTAssertFalse(model.shouldShowMobileRotationControls, "Hidden before a tap during \(phase)")
            model.toggleControls()
            XCTAssertTrue(model.shouldShowMobileRotationControls, "A tap reveals both buttons during \(phase)")
            model.toggleControls()
            XCTAssertFalse(model.shouldShowMobileRotationControls, "A second tap hides both buttons during \(phase)")
            model.revealControls()
            model.dismissControls()
            XCTAssertFalse(model.shouldShowMobileRotationControls, "Dismissal hides both buttons during \(phase)")
        }
        model.error = nil
        model.isPlaying = true
        model.toggleControls()
        try await Task.sleep(for: .milliseconds(5300))
        XCTAssertFalse(model.showControls)
        XCTAssertFalse(model.shouldShowMobileRotationControls, "Both buttons auto-hide with transport")
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
            isPlayerActive: state.isPlayerActive, lockedOrientation: state.lockedOrientation
        ), .portrait)
        state.activate()
        XCTAssertFalse(state.isLocked)
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
                isPlayerActive: false, preferredOrientation: mask
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
        let browsing = PlayerOrientationCoordinator.orientationMask(isPlayerActive: false)
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
