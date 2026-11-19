#if os(tvOS)
import SwiftUI

/// The collections holding a movie or series, on its tvOS page. When one
/// collection holds the title, its other titles show under its name, ending
/// with an Explore all card that opens it. Otherwise an "Also in" row shows a
/// poster card for every collection. A native focus graph like
/// `TVSimilarRail`: one focus section, entered on its first card.
struct TVItemCollectionsRow: View {
    let content: ItemCollectionsRowContent
    /// Reports focus entering and leaving the row.
    var onFocusChange: ((Bool) -> Void)? = nil

    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.browseLibraryId) private var pageLibraryId
    @FocusState private var focusedItemId: String?

    /// The detail page's poster rails' size.
    private let cardWidth: CGFloat = 220
    private let cardSpacing: CGFloat = 44
    private let railVerticalPadding: CGFloat = 12

    var body: some View {
        rows
            .onChange(of: focusedItemId != nil) { _, focused in
                onFocusChange?(focused)
            }
    }

    @ViewBuilder
    private var rows: some View {
        switch content {
        case .titles(let collection, let items):
            section(title: collection.title, firstItemId: items.first?.contentId) {
                titles(items, in: collection)
            }
        case .collections(let cards):
            section(title: AppLanguage.string(.detailAlsoIn, locale: locale), firstItemId: cards.first?.rowKey) {
                collections(cards)
            }
        }
    }

    private func section(title: String, firstItemId: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    content()
                }
                .padding(.vertical, railVerticalPadding)
            }
            .focusSection()
            .tvDefaultFocus(firstItemId, in: $focusedItemId)
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func titles(_ items: [BrowseItem], in collection: SectionCollectionCard) -> some View {
        // A server collection's titles open in its library, as its page
        // opens them; a personal collection's keep the page's library.
        let libraryId = collection.libraryId ?? pageLibraryId
        ForEach(items) { item in
            TVMediaCard(
                title: item.title,
                posterUrl: item.posterUrl ?? "",
                posterThumbhash: item.posterThumbhash,
                mediaType: item.type,
                year: item.year,
                userState: item.userState,
                overlayData: OverlayData.from(item),
                action: { router.navigate(to: .itemDetail(browseItem: item, libraryId: libraryId)) },
                cardWidth: cardWidth,
                focusTreatment: .ring,
                focusBinding: $focusedItemId,
                focusContentId: item.contentId,
                contentId: item.contentId
            )
        }
        SectionExploreAllCard(
            size: TVMediaCard.artworkSize(cardWidth: cardWidth, aspect: .poster),
            rowTitle: collection.title,
            focusedItemId: $focusedItemId,
            action: { router.navigate(to: collection.route()) }
        )
    }

    private func collections(_ cards: [SectionCollectionCard]) -> some View {
        ForEach(cards, id: \.rowKey) { card in
            TVCollectionPosterCard(
                collection: card.libraryCollection,
                action: { router.navigate(to: card.route()) },
                cardWidth: cardWidth,
                focusBinding: $focusedItemId,
                focusContentId: card.rowKey
            )
        }
    }
}
#endif
