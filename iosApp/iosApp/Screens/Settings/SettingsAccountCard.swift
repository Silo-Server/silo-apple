#if os(iOS)
import SwiftUI

struct SettingsAccountCard: View {
    let avatar: String?
    let name: String
    let subtitle: String
    let isAdministrator: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ProfileAvatarView(avatar: avatar, name: name, size: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Current profile")
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)

                    Text(name)
                        .font(.headline)
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isAdministrator {
                    Text("Admin")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(Color.siloAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.siloAccent.opacity(0.12), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(Color.siloSecondaryText)
                    .accessibilityHidden(true)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.siloSurfaceElevated.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.siloOutline, lineWidth: 1)
        }
        .accessibilityHint("Switches to a different profile")
    }
}
#endif
