#if os(iOS)
import SwiftUI

/// One-line Settings destination row in the system Settings idiom: icon
/// tile, title, and the current value. The longer description is spoken as
/// the accessibility hint instead of printed. The containing NavigationLink
/// supplies its own chevron; plain buttons ask for one with `showsChevron`.
struct SettingsOverviewRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var value: String? = nil
    var showsChevron = false

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: systemImage)

            Text(title)
                .foregroundStyle(Color.siloOnSurface)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if showsChevron {
                SettingsRowChevron()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(subtitle)
    }
}

/// White glyph on a graphite rounded square — the leading icon of every
/// Settings overview row.
struct SettingsIconTile: View {
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.53, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Color.siloIconTile,
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
#endif
