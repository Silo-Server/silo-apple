#if !os(tvOS)
import SwiftUI

/// The box set a movie belongs to, on the movie page between the trailers and
/// More Like This: its title, then as many of its movies as fit across the
/// page as poster cards in release order, ending with an Explore all card
/// that opens the box set page. The row does not scroll (see
/// `BoxSetRowWindow`); on an iPhone too narrow for three cards the cards
/// shrink so two films and Explore all fit. The movie on screen is outlined
/// and labelled THIS FILM. The page draws nothing until the box set has
/// loaded (see `ItemDetailViewModel.boxSet`).
struct PhoneBoxSetRow: View {
    let boxSet: CatalogBoxSetDetail
    /// The movie whose page this is.
    let currentContentId: String

    @Environment(AppRouter.self) private var router
    @State private var rowWidth: CGFloat = 0

    private let cardSpacing: CGFloat = 12
    /// Two films and Explore all, so the row always shows a neighbour.
    private static let minimumSlots = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: boxSet.boxSet.title)
                .padding(.horizontal, SiloTheme.safePadding)
            cards
                // Films open in the box set's library, as on tvOS and the
                // box set page, not in whichever library opened this movie.
                .environment(\.browseLibraryId, boxSet.boxSet.appLibraryId)
                .padding(.horizontal, SiloTheme.safePadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var cards: some View {
        let route = Route.boxSet(boxSet.boxSet)
        let layout = cardLayout
        return HStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
            ForEach(BoxSetRowWindow.films(
                boxSet.items,
                currentContentId: currentContentId,
                slots: layout.slots,
                endsWithExploreAll: route != nil
            )) { movie in
                card(movie, cardWidthOverride: layout.cardWidthOverride)
            }
            if let route {
                SectionExploreAllCard(
                    size: MediaCard.artworkSize(cardWidthOverride: layout.cardWidthOverride, aspect: .poster),
                    rowTitle: boxSet.boxSet.title,
                    action: { router.navigate(to: route) }
                )
            }
        }
        .padding(.vertical, 4)
    }

    /// How many cards fit across the row, and the width override that makes
    /// them fit when the normal size leaves fewer than `minimumSlots`.
    private var cardLayout: (slots: Int, cardWidthOverride: CGFloat?) {
        let width = rowWidth - 2 * SiloTheme.safePadding
        let normalWidth = MediaCard.artworkSize(cardWidthOverride: nil, aspect: .poster).width
        let slots = BoxSetRowWindow.slots(width: width, cardWidth: normalWidth, spacing: cardSpacing)
        guard slots < Self.minimumSlots, width > 0 else { return (slots, nil) }
        let fitted = (width - CGFloat(Self.minimumSlots - 1) * cardSpacing) / CGFloat(Self.minimumSlots)
        // The override is scaled by the poster-size setting like the default.
        return (Self.minimumSlots, SiloTheme.posterCardWidth * fitted / normalWidth)
    }

    private func card(_ movie: BrowseItem, cardWidthOverride: CGFloat?) -> some View {
        let isCurrent = movie.contentId == currentContentId
        // The current film's card opens nothing: its page is already here.
        return MediaCard(
            title: movie.title,
            posterUrl: movie.posterUrl ?? "",
            thumbhash: movie.posterThumbhash,
            mediaType: movie.type,
            year: movie.year,
            userState: movie.userState,
            overlayData: OverlayData.from(movie),
            action: {},
            contentId: isCurrent ? nil : movie.contentId,
            aspect: .poster,
            cardWidthOverride: cardWidthOverride,
            marksCurrentFilm: isCurrent
        )
    }
}
#endif
