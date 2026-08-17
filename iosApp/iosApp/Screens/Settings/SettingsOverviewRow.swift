#if os(iOS)
import SwiftUI

/// Web-style Settings destination row with a descriptive second line and an
/// optional current value. The containing NavigationLink or Button owns the
/// interaction so the full row remains a native 44-point target.
struct SettingsOverviewRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .siloAccent
    var value: String? = nil
    var showsChevron = true

    var body: some View {
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
                    .foregroundStyle(Color.siloOnSurface)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(Color.siloSecondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
