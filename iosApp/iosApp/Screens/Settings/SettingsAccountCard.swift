#if os(iOS)
import SwiftUI

/// The active profile at the top of the Settings list; tapping it opens the
/// profile switcher.
struct SettingsAccountCard: View {
    let avatar: String?
    /// Server-resolved avatar image URL (`avatar_url`), preferred over the
    /// raw `avatar` ref when present.
    var avatarImageUrl: String? = nil
    let name: String
    let subtitle: String
    let isAdministrator: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ProfileAvatarView(avatar: avatar, imageUrl: avatarImageUrl, name: name, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isAdministrator {
                    Text("Admin")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.siloSecondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.siloChromeSelectedFill, in: Capsule())
                }

                SettingsRowChevron()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Switches to a different profile")
    }
}
#endif
