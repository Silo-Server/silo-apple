#if os(tvOS)
import SwiftUI

/// tvOS focus behavior for the shared profile presentation.
struct TVProfileTile: View {
    let profile: UserProfile
    var isLastUsed: Bool = false
    var prefersDefaultFocus: Bool = false
    var defaultFocusNamespace: Namespace.ID? = nil
    let action: () -> Void

    var body: some View {
        ProfileTile(
            profile: profile,
            isLastUsed: isLastUsed,
            action: action
        )
        // Lets the first profile tile claim initial focus instead of the
        // engine landing on the top-right Sign Out / Change Server chips.
        .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
        .focusEffectDisabled()
    }
}
#endif
