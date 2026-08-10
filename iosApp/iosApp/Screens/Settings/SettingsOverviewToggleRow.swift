#if os(iOS)
import SwiftUI

struct SettingsOverviewToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .continuumAccent
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.continuumOnSurface)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.continuumSecondaryText)
                }
            }
        }
        .tint(.continuumAccent)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
#endif
