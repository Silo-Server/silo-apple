#if os(tvOS)
import SwiftUI

/// tvOS focus behavior for the shared profile presentation. The picker
/// binds its own focus state to each tile to seed and restore focus.
struct TVProfileTile: View {
    let profile: UserProfile
    var isRemembered: Bool = false
    let action: () -> Void

    var body: some View {
        ProfileTile(
            profile: profile,
            isRemembered: isRemembered,
            action: action
        )
        .focusEffectDisabled()
    }
}
#endif
