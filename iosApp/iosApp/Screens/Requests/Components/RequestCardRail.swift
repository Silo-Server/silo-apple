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
