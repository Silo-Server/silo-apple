#if os(tvOS)
import SwiftUI

/// tvOS focus behavior for the shared profile presentation.
struct TVProfileTile: View {
    let profile: UserProfile
    var isRemembered: Bool = false
    /// The picker's focus, keyed by profile ID (`ProfileTile.focus`).
    var focus: FocusState<String?>.Binding? = nil
    let action: () -> Void

    var body: some View {
        ProfileTile(
            profile: profile,
            isRemembered: isRemembered,
            focus: focus,
            action: action
        )
        .focusEffectDisabled()
    }
}
#endif
