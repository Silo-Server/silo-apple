import SwiftUI

/// Shared layout metrics for the requests surfaces, so the hub, detail,
/// search section, and My Requests all agree on card geometry.
enum RequestsUI {
    #if os(tvOS)
    /// Slightly denser than `SiloTheme.posterCardWidth` so rails fit
    /// more titles at 10 feet, matching the search grid's card size.
    static let cardWidth: CGFloat = 220
    static let railSpacing: CGFloat = 32
    static let headerSpacing: CGFloat = 20
    /// Headroom for the `.card` focus lift so scaled posters aren't clipped
    /// by the rail's scroll bounds — same treatment as `TVSimilarRail`.
    static let railVerticalPadding: CGFloat = 24
    #else
    static let cardWidth: CGFloat = SiloTheme.posterCardWidth
    static let railSpacing: CGFloat = 12
    static let headerSpacing: CGFloat = 10
    #endif
}

/// Horizontal poster rail shared by every requests surface. Focus scoping
/// stays with the caller — some rails share a `.focusSection()` with their
/// header controls (e.g. the hub's "See all" button), so the rail itself
/// doesn't own one.
struct RequestCardRail<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        #if os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: RequestsUI.railSpacing) {
                ForEach(items) { item in
                    card(item)
                }
            }
            .padding(.vertical, RequestsUI.railVerticalPadding)
        }
        .scrollClipDisabled()
        // Pull the rail back to the header rhythm the padding pushed out.
        .padding(.vertical, -RequestsUI.railVerticalPadding)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: RequestsUI.railSpacing) {
                ForEach(items) { item in
                    card(item)
                }
            }
            .phoneMediaRailBounds()
        }
        #endif
    }
}

/// Section header for requests rails, in the detail pages' editorial
/// grammar (`PhoneSectionHeader` / `TVSectionHeader`): an optional tracked
/// eyebrow over the title, and an optional trailing link.
struct RequestsSectionHeader: View {
    var label: String? = nil
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let label, !label.isEmpty {
                    Text(label.uppercased())
                        .font(.system(size: labelSize, weight: .bold))
                        .tracking(1.6)
                        .foregroundColor(.siloOnSurface.opacity(0.55))
                }
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let trailing, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(trailing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: trailingSize * 0.8, weight: .semibold))
                    }
                    .font(.system(size: trailingSize, weight: .medium))
                    .foregroundColor(.siloSecondaryText)
                }
                #if os(tvOS)
                .buttonStyle(.plain)
                #else
                .buttonStyle(.borderless)
                #endif
            }
        }
    }

    private var labelSize: CGFloat {
        #if os(tvOS)
        17
        #else
        11
        #endif
    }

    private var titleSize: CGFloat {
        #if os(tvOS)
        30
        #else
        22
        #endif
    }

    private var trailingSize: CGFloat {
        #if os(tvOS)
        22
        #else
        13
        #endif
    }
}
