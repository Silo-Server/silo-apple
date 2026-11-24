#if !os(tvOS)
import SwiftUI

/// A row of collections on Home and library pages (iOS, iPadOS, macOS). It
/// sits among the title rails, so it takes `HomeFeedRow`'s header, rail and
/// poster width, but has no full page: no See all and no Explore all card.
struct HomeCollectionsRow: View {
    let section: ResolvedSection
    var onMoveToTop: (() -> Void)? = nil
    var onHideRow: (() -> Void)? = nil
    var onCustomizeHome: (() -> Void)? = nil
    @Environment(AppRouter.self) private var router
    /// The app language, so a switch re-renders the title and bylines.
    @Environment(\.locale) private var locale
    /// A library page's Movies or Shows filter, kept by the collections it opens.
    @Environment(\.browseMediaScope) private var mediaScope
    /// This login's profiles, to name the owner of another profile's
    /// collection. Read once the row appears, so a Home painted before the
    /// profile list arrives still gets its "by Name" lines.
    @State private var profiles: [UserProfile]?

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(
                title: section.displayTitle(in: locale),
                onMoveToTop: onMoveToTop,
                onHideRow: onHideRow,
                onCustomizeHome: onCustomizeHome
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(Array(section.collections.enumerated()), id: \.element.rowKey) { index, card in
                        collectionCard(card)
                            .onAppear { warmCards(after: index) }
                    }
                }
                .scrollTargetLayout()
                .phoneMediaRailBounds()
                .mouseDragScrolling()
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
            .scrollClipDisabled()
            .mediaRailScrolling()
        }
        .task(id: section.collections.compactMap(\.creatorProfileId)) {
            guard CollectionOwnerName.needsProfiles(section.collections) else { return }
            profiles = await CollectionOwnerName.profiles()
        }
    }

    private func collectionCard(_ card: SectionCollectionCard) -> some View {
        let collection = card.libraryCollection
        let byline = CollectionOwnerName.byline(for: card, profiles: profiles, locale: locale)
        // A filtered page's collection page shows only that filter's titles,
        // so the whole collection's count would not match it; the
        // Collections tab leaves it out there too.
        let showsCount = mediaScope == nil
        // Through the router, not NavigationLink(value:), as the Collections
        // tab opens a collection, so the router's record of pushed routes
        // stays in step with the stack.
        return Button {
            router.navigate(to: card.route(mediaScope: mediaScope))
        } label: {
            LibraryCollectionCard(
                collection: collection,
                cardWidthOverride: HomeFeedRow.posterWidth,
                showItemCount: showsCount,
                byline: byline
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(libraryCollectionAccessibilityLabel(
            collection, showItemCount: showsCount, byline: byline, locale: locale
        ))
    }

    /// Decode the next posters before a swipe brings them into view.
    private func warmCards(after index: Int) {
        ArtworkLookahead.warmCards(after: index, in: section.collections, artwork: Self.cardArtwork)
    }

    /// The poster a card in this row draws, at the size it draws it.
    static func cardArtwork(for card: SectionCollectionCard) -> CardArtwork? {
        guard let url = card.posterUrl else { return nil }
        return CardArtwork(url: url, pointSize: LibraryCollectionCard.artworkSize(width: HomeFeedRow.posterWidth))
    }
}
#endif
