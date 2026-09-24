#if os(iOS) || os(tvOS)
import SwiftUI

/// Keep party playback in the app's existing player presentation. The same
/// cover survives lobby navigation and replaces its player on selection changes.
struct WatchPartyPresentationModifier: ViewModifier {
    let router: AppRouter
    private let session = WatchPartySession.shared

    func body(content: Content) -> some View {
        content.onChange(of: session.playbackContext, initial: true) { _, context in
            router.presentWatchParty(context)
        }
    }
}
#endif
