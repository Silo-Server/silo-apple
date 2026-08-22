#if os(iOS)
import Foundation
import OSLog

/// Brings the full-screen player back for a Picture in Picture restore.
///
/// The player is presented as a `fullScreenCover` keyed off
/// `AppRouter.presentedPlayer`, and `PictureInPictureCoordinator` keeps the
/// engaged `PlayerViewModel` alive after that cover goes away. Restoring is
/// therefore two things that have to happen together: put the cover back, and
/// make the new `PlayerView` adopt the *same* view model. A fresh `PlayerView`
/// mints its own `PlayerViewModel` and calls `loadAndPlay`, which would restart
/// the title from the resume point instead of restoring the session already in
/// flight.
///
/// Everything here is `@MainActor` and single-instance because the presentation
/// it stands for is: one router, one cover, one engaged player at a time.
@MainActor
enum PlayerPresentationRestoration {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PictureInPicture"
    )

    /// The router that owns the full-screen player cover. Weak: the restoration
    /// path must never be the reason the app's navigation state stays alive.
    static weak var presenter: AppRouter?

    /// The payload the current player was presented with. Recorded by the
    /// presentation site rather than rebuilt from `PlayerView`'s parameters,
    /// which do not carry `returnToContentId`.
    private static var lastPresentation: AppRouter.PlayerPresentation?

    /// The view model the next `PlayerView` must adopt. Strong on purpose:
    /// between AVKit's stop and SwiftUI mounting the cover, the coordinator has
    /// already released `engagedOwner` and nothing else retains it.
    private static var pendingAdoption: (viewModel: PlayerViewModel, contentId: String)?

    static func recordPresentation(_ payload: AppRouter.PlayerPresentation) {
        lastPresentation = payload
    }

    /// Re-present the full-screen player for a view model AVKit is restoring.
    /// Returns false when there is nothing to present into — the caller must
    /// then tear the session down rather than let it play on with no surface.
    static func reopen(_ viewModel: PlayerViewModel) -> Bool {
        guard let presenter, let payload = lastPresentation else {
            logger.error("No player presentation owner available for a PiP restore")
            return false
        }
        pendingAdoption = (viewModel, payload.contentId)
        // A fresh identity is what makes `fullScreenCover(item:)` re-present
        // even if the router is still holding the outgoing payload.
        presenter.presentedPlayer = payload.reopened()
        return true
    }

    /// Claimed by `PlayerView.onAppear`. The content check keeps an unconsumed
    /// adoption from being handed to an unrelated player the user started in
    /// the meantime.
    static func consumeAdoption(matching contentId: String) -> PlayerViewModel? {
        guard let pendingAdoption, pendingAdoption.contentId == contentId else { return nil }
        Self.pendingAdoption = nil
        return pendingAdoption.viewModel
    }

    /// Drop a staged adoption whose view model is being torn down, so a restore
    /// that never reached SwiftUI cannot strand the whole playback graph.
    static func discardAdoption(for viewModel: PlayerViewModel) {
        if pendingAdoption?.viewModel === viewModel {
            pendingAdoption = nil
        }
    }
}

extension AppRouter.PlayerPresentation {
    /// A copy with a fresh identity. `id` is defaulted, so the memberwise
    /// initializer mints a new `UUID` and `fullScreenCover(item:)` treats the
    /// result as a new presentation.
    func reopened() -> Self {
        AppRouter.PlayerPresentation(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            returnToContentId: returnToContentId,
            offlineDownloadId: offlineDownloadId,
            posterURL: posterURL,
            backdropURL: backdropURL
        )
    }
}
#endif
