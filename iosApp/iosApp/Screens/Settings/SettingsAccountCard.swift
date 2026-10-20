#if os(iOS)
import SwiftUI

/// The open account at the top of the Settings list: its username, email,
/// and server. Not a button: Who's Watching and Switch Account are a tap
/// away elsewhere.
struct SettingsAccountCard: View {
    let header: SettingsAccountHeader
    let isAdministrator: Bool

    var body: some View {
        HStack(spacing: 14) {
            ProfileAvatarView(avatar: nil, imageUrl: nil, name: header.name, size: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(header.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)

                ForEach(header.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
#endif
