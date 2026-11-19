#if !os(tvOS)
import SwiftUI

/// The collections holding a movie or series, on its page (iOS, iPadOS,
/// macOS). When one collection holds the title, its other titles show under
/// its name, ending with an Explore all card that opens it. Otherwise an
/// "Also in" row shows a card for every collection. The page draws nothing
/// until the read has an answer (see `ItemDetailViewModel.itemCollections`).
struct PhoneItemCollectionsRow: View {
    let content: ItemCollectionsRowContent

    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.browseLibraryId) private var pageLibraryId
    /// This login's profiles, to name the owner of another profile's
    /// collection.
    @State private var profiles: [UserProfile]?

    private let cardSpacing: CGFloat = 12

    var body: some View {
        switch content {
        case .titles(let collection, let items):
            section(title: collection.title) { titles(items, in: collection) }
        case .collections(let cards):
            section(title: AppLanguage.string(.detailAlsoIn, locale: locale)) { collections(cards) }
                .task(id: cards.compactMap(\.creatorProfileId)) {
                    guard CollectionOwnerName.needsProfiles(cards) else { return }
                    profiles = await CollectionOwnerName.profiles()
                }
        }
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: title)
                .padding(.horizontal, SiloTheme.safePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
                    content()
                }
                .padding(.horizontal, SiloTheme.safePadding)
                .padding(.vertical, 4)
                .mouseDragScrolling()
            }
            .scrollClipDisabled()
            .mediaRailScrolling()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func titles(_ items: [BrowseItem], in collection: SectionCollectionCard) -> some View {
        Group {
            ForEach(items) { item in
                MediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
                    mediaType: item.type,
                    year: item.year,
                    userState: item.userState,
                    overlayData: OverlayData.from(item),
                    action: {},
                    contentId: item.contentId,
                    detailSeedSource: .browse(item),
                    aspect: .poster
                )
            }
            SectionExploreAllCard(
                size: MediaCard.artworkSize(cardWidthOverride: nil, aspect: .poster),
                rowTitle: collection.title,
                action: { router.navigate(to: collection.route()) }
            )
        }
        // A server collection's titles open in its library, as its page
        // opens them; a personal collection's keep the page's library.
        .environment(\.browseLibraryId, collection.libraryId ?? pageLibraryId)
    }

    private func collections(_ cards: [SectionCollectionCard]) -> some View {
        ForEach(cards, id: \.rowKey) { card in
            let collection = card.libraryCollection
            let byline = CollectionOwnerName.byline(for: card, profiles: profiles, locale: locale)
            Button {
                router.navigate(to: card.route())
            } label: {
                LibraryCollectionCard(collection: collection, cardWidthOverride: nil, byline: byline)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(libraryCollectionAccessibilityLabel(collection, byline: byline, locale: locale))
        }
    }
}
#endif
