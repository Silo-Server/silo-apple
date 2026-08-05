#if !os(tvOS)
import SwiftUI

/// Consistent introduction for Settings detail pages, matching the web
/// client's icon, title, and concise explanatory copy.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .continuumAccent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.13), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(tint.opacity(0.2), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(Color.continuumOnSurface)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func settingsPageHeaderRow() -> some View {
        listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 10, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func settingsListChrome() -> some View {
        continuumGroupedListStyle()
            .continuumScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
    }
}
#endif
