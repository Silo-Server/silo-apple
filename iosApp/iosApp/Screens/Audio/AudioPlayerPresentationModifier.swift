#if os(iOS)
import SwiftUI

/// Presents the full audiobook player from whichever surface is on top: the
/// open item-detail sheet, or the tab root when no detail is showing. Attach
/// it to both. Presenting from the root while a detail sheet is up made
/// SwiftUI dismiss the detail first and re-present it afterwards.
///
/// The player is a page sheet rather than a full-screen cover, so it follows
/// the finger when pulled down and collapses to the mini player, like the
/// Now Playing screens in Apple Books and Plexamp.
struct AudioPlayerPresentationModifier: ViewModifier {
    let router: AppRouter
    /// The detail sheet this modifier is attached to; nil for the tab root.
    var detailPresentationID: UUID? = nil

    @Environment(AudioPlaybackStore.self) private var audioStore

    private var isTopmostHost: Bool {
        router.presentedItemDetail?.id == detailPresentationID
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { audioStore.isShowingFullPlayer && isTopmostHost },
            set: { isPresented in
                if !isPresented, isTopmostHost {
                    audioStore.dismissFullPlayer()
                }
            }
        )) {
            AudioFullPlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationSizing(.page)
        }
    }
}
#endif
