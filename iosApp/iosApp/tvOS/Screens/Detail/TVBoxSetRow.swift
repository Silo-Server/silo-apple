#if os(tvOS)
import SwiftUI

/// The box set a movie belongs to, on the tvOS movie page between the
/// trailers and More Like This: its title, then as many of its movies as fit
/// across the page as poster cards in release order, ending with an Explore
/// all card that opens the box set page. The row does not scroll (see
/// `BoxSetRowWindow`). The movie on screen is outlined and labelled THIS
/// FILM, and moving down into the row lands on it. A native focus graph like
/// `TVSimilarRail`; Explore all is its last stop.
struct TVBoxSetRow: View {
    let boxSet: CatalogBoxSetDetail
    /// The movie whose page this is.
    let currentContentId: String

    @Environment(AppRouter.self) private var router
    @FocusState private var focusedItemId: String?
    @State private var rowWidth: CGFloat = 0

    private let cardWidth: CGFloat = 220
    private let cardSpacing: CGFloat = 44
    private let railVerticalPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: boxSet.boxSet.title)
            rail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var rail: some View {
        let route = Route.boxSet(boxSet.boxSet)
        let films = shownFilms(endsWithExploreAll: route != nil)
        return HStack(alignment: .top, spacing: cardSpacing) {
            ForEach(films) { movie in
                TVMediaCard(
                    title: movie.title,
                    posterUrl: movie.posterUrl ?? "",
                    posterThumbhash: movie.posterThumbhash,
                    mediaType: movie.type,
                    year: movie.year,
                    userState: movie.userState,
                    overlayData: OverlayData.from(movie),
                    action: { open(movie) },
                    cardWidth: cardWidth,
                    focusTreatment: .ring,
                    focusBinding: $focusedItemId,
                    focusContentId: movie.contentId,
                    contentId: movie.contentId,
                    marksCurrentFilm: movie.contentId == currentContentId
                )
            }
            if let route {
                SectionExploreAllCard(
                    size: TVMediaCard.artworkSize(cardWidth: cardWidth, aspect: .poster),
                    rowTitle: boxSet.boxSet.title,
                    focusedItemId: $focusedItemId,
                    action: { router.navigate(to: route) }
                )
            }
        }
        .padding(.vertical, railVerticalPadding)
        .focusSection()
        .tvDefaultFocus(entryItemId(in: films), in: $focusedItemId)
    }

    private func shownFilms(endsWithExploreAll: Bool) -> ArraySlice<BrowseItem> {
        let slots = BoxSetRowWindow.slots(
            width: rowWidth,
            cardWidth: TVMediaCard.artworkSize(cardWidth: cardWidth, aspect: .poster).width,
            spacing: cardSpacing
        )
        return BoxSetRowWindow.films(
            boxSet.items,
            currentContentId: currentContentId,
            slots: slots,
            endsWithExploreAll: endsWithExploreAll
        )
    }

    /// Down into the row lands on the film on screen when it is shown.
    private func entryItemId(in films: ArraySlice<BrowseItem>) -> String? {
        films.contains { $0.contentId == currentContentId }
            ? currentContentId
            : films.first?.contentId
    }

    private func open(_ movie: BrowseItem) {
        guard movie.contentId != currentContentId else { return }
        router.navigate(to: .itemDetail(browseItem: movie, libraryId: boxSet.boxSet.appLibraryId))
    }
}
#endif
