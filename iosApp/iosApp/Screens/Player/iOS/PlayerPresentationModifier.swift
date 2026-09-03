#if os(iOS)
import SwiftUI

/// Mount this at the app root and on the detail sheet. A payload selects one
/// owner, so exiting playback cannot take the underlying detail with it.
struct PlayerPresentationModifier: ViewModifier {
    @Bindable var router: AppRouter
    var detailPresentationID: UUID? = nil

    func body(content: Content) -> some View {
        let payload = router.playerPresentation(forDetailID: detailPresentationID)
        content.fullScreenCover(item: Binding(
            get: { router.playerPresentation(forDetailID: detailPresentationID) },
            set: { replacement in
                guard replacement == nil, let id = payload?.id else { return }
                router.dismissPlayerPresentation(id: id)
            }
        )) { presentation in
            PlayerView(
                contentId: presentation.contentId,
                preferredFileId: presentation.fileId,
                preferredAudioTrackIndex: presentation.audioTrackIndex,
                preferredSubtitleTrackIndex: presentation.subtitleTrackIndex,
                startFromBeginning: presentation.startFromBeginning,
                resumePositionOverride: presentation.resumePosition,
                prefersLastUsedVersion: presentation.prefersLastUsedVersion,
                offlineDownloadId: presentation.offlineDownloadId,
                posterURLHint: presentation.posterURL,
                backdropURLHint: presentation.backdropURL,
                onDismissRequested: { router.dismissPlayerPresentation(id: presentation.id) }
            )
            .onAppear {
                PlayerPresentationRestoration.presenter = router
                PlayerPresentationRestoration.recordPresentation(presentation)
            }
        }
    }
}
#endif
