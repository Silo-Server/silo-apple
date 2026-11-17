#if os(tvOS)
import SwiftUI
import os

/// A row of collections on tvOS Home and library pages. It draws and moves
/// like `MediaRow`'s tvOS rows beside it in the Skyline feed: the same
/// header, strip metrics, poster size, focus section, entry claim and
/// detail-return restoration, with one `TVCollectionPosterCard` per
/// collection. It has no Explore all card; each collection is its own page.
struct TVCollectionsRow: View {
    let section: ResolvedSection
    /// See `MediaRow.prefersDefaultFocusOnFirstItem`.
    var prefersDefaultFocusOnFirstItem: Bool = false
    /// See `MediaRow.defaultFocusPriority`.
    var defaultFocusPriority: DefaultFocusEvaluationPriority = .userInitiated
    /// Monotonic hand-down token: each new value claims the first card.
    var focusRequest: Int = 0
    /// Monotonic token emitted when a pushed page pops. The row that still
    /// owns restoration reclaims the card it last focused.
    var detailReturnFocusRequest: Int = 0
    var onMoveUp: (() -> Void)? = nil
    /// Reports the card that took focus; focus leaving the row is not
    /// reported, so the marquee keeps the last preview.
    var onCollectionFocus: ((SectionCollectionCard) -> Void)? = nil
    /// Poster width before the poster-size setting scales it, as
    /// `MediaCard.cardWidthOverride` takes it, so these posters match the
    /// title posters in the rows around them.
    var cardWidth: CGFloat? = nil
    var cardVerticalPadding: CGFloat? = nil
    var onMoveDown: (() -> Void)? = nil
    /// Live ownership gate for focus restoration; see
    /// `MediaRow.focusRestorationOwner`.
    var focusRestorationOwner: Binding<Bool>? = nil

    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    /// A library page's Movies or Shows filter, kept by the collections it opens.
    @Environment(\.browseMediaScope) private var mediaScope

    /// The focused card's `rowKey`.
    @FocusState private var focusedKey: String?
    /// Each focus token is applied once, on appear or on change, so a row
    /// mounted after the token arrived still claims it.
    @State private var lastAppliedFocusRequest = 0
    @State private var lastFocusedKey: String?
    @State private var focusRestorationGeneration = 0
    @State private var lastAppliedDetailReturnFocusRequest = 0
    private static let focusLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "TVFocus"
    )

    private var cards: [SectionCollectionCard] { section.collections }

    private var posterWidth: CGFloat { cardWidth ?? SiloTheme.posterCardWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            ScrollViewReader { proxy in
                strip(proxy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .modifier(TVRowMoveHandler(onMoveUp: onMoveUp, onMoveDown: onMoveDown))
        .modifier(TVRowFocusObserver(focusedItemId: $focusedKey) { key in
            guard let index = cards.firstIndex(where: { $0.rowKey == key }) else { return }
            lastFocusedKey = key
            onCollectionFocus?(cards[index])
            warmCards(after: index)
        })
        .onChange(of: cards.map(\.rowKey)) { oldKeys, newKeys in
            restoreFocusAfterCardRemoval(from: oldKeys, to: newKeys)
        }
        .onChange(of: focusRestorationOwner?.wrappedValue ?? false) { _, ownsRestoration in
            guard !ownsRestoration else { return }
            focusRestorationGeneration += 1
        }
    }

    // MARK: - Layout

    /// Title only, as `MediaRow`'s tvOS header: a focusable title would add
    /// a stop above the row.
    private var header: some View {
        HStack {
            Text(section.displayTitle(in: locale))
                .font(.siloHeadline)
                .foregroundColor(.siloOnSurface)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, SiloTheme.safePadding)
    }

    private func strip(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Top, not the rails' centre: a collection with no titles has no
            // count line, and centring would drop its poster below the others.
            LazyHStack(alignment: .top, spacing: 40) {
                ForEach(cards, id: \.rowKey) { card in
                    TVCollectionPosterCard(
                        collection: card.libraryCollection,
                        action: { router.navigate(to: card.route(mediaScope: mediaScope)) },
                        cardWidth: posterWidth,
                        focusBinding: $focusedKey,
                        focusContentId: card.rowKey
                    )
                }
            }
            .padding(.vertical, cardVerticalPadding ?? 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The gutter sits outside the scroll view, as in `MediaRow`, so
        // native focus scrolling and the entry scroll share one origin.
        .padding(.horizontal, SiloTheme.safePadding)
        .scrollClipDisabled()
        .applyDefaultFirstItemFocus(
            enabled: prefersDefaultFocusOnFirstItem,
            binding: $focusedKey,
            firstItemId: cards.first?.rowKey,
            priority: defaultFocusPriority
        )
        .onAppear { applyFocusRequest(focusRequest, proxy: proxy) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request, proxy: proxy) }
        .onAppear { restoreFocusAfterDetailReturn(detailReturnFocusRequest, proxy: proxy) }
        .onChange(of: detailReturnFocusRequest) { _, request in
            restoreFocusAfterDetailReturn(request, proxy: proxy)
        }
    }

    // MARK: - Artwork

    /// The poster a card draws, at the size it draws it.
    static func cardArtwork(for card: SectionCollectionCard, cardWidth: CGFloat?) -> CardArtwork? {
        guard let url = card.posterUrl else { return nil }
        return CardArtwork(url: url, pointSize: MediaCard.artworkSize(cardWidthOverride: cardWidth, aspect: .poster))
    }

    private func warmCards(after index: Int) {
        ArtworkLookahead.warmCards(after: index, in: cards) { card in
            Self.cardArtwork(for: card, cardWidth: cardWidth)
        }
    }

    // MARK: - Focus

    /// Scroll the first card into view without animation, then claim it a
    /// turn later: a strip left deep in its LazyHStack can keep that card
    /// unmounted, and the focus engine drops writes to views it can't focus.
    private func applyFocusRequest(_ request: Int, proxy: ScrollViewProxy) {
        guard request > 0, request != lastAppliedFocusRequest,
              let target = cards.first,
              focusRestorationOwner?.wrappedValue != false else { return }
        lastAppliedFocusRequest = request
        focusRestorationGeneration += 1
        let generation = focusRestorationGeneration
        // A recycled row can keep this value after UIKit drops its focus.
        focusedKey = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(target.rowKey, anchor: .center)
        }
        DispatchQueue.main.async {
            Self.focusLogger.debug("collectionsRow.applyFocus request=\(request, privacy: .public)")
            claimRequestedFocus(target.rowKey, generation: generation)
        }
    }

    /// Write the claim, then check it held and write it again if not, for a
    /// bounded window: the engine's repair after the top bar resigns and the
    /// layout that mounts the card can both land after the first write.
    private func claimRequestedFocus(_ key: String, generation: Int, attempt: Int = 0) {
        guard generation == focusRestorationGeneration,
              focusRestorationOwner?.wrappedValue != false,
              let card = cards.first(where: { $0.rowKey == key }) else { return }
        focusedKey = key
        lastFocusedKey = key
        onCollectionFocus?(card)
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard generation == focusRestorationGeneration,
                  focusRestorationOwner?.wrappedValue != false,
                  cards.contains(where: { $0.rowKey == key }),
                  focusedKey != key else { return }
            Self.focusLogger.debug("collectionsRow.reclaimFocus attempt=\(attempt + 1, privacy: .public)")
            claimRequestedFocus(key, generation: generation, attempt: attempt + 1)
        }
    }

    /// A reload can drop the focused collection (deleted or no longer shared
    /// elsewhere). Hand focus to the card that slid into its place, or the
    /// one before it when it was last, as `MediaRow` does for its titles,
    /// rather than leave the engine to pick a card.
    private func restoreFocusAfterCardRemoval(from oldKeys: [String], to newKeys: [String]) {
        guard focusRestorationOwner?.wrappedValue == true,
              let removedKey = lastFocusedKey,
              let removedIndex = oldKeys.firstIndex(of: removedKey),
              !newKeys.contains(removedKey),
              !newKeys.isEmpty else { return }
        let replacementKey = newKeys[min(removedIndex, newKeys.count - 1)]
        focusRestorationGeneration += 1
        let generation = focusRestorationGeneration
        lastFocusedKey = replacementKey
        claimReplacementFocus(replacementKey, removedKey: removedKey, engineFallbackKey: newKeys.first, generation: generation)
    }

    /// Claim the replacement once the strip has mounted it, and again for a
    /// short window while it hasn't taken. Stops once it has, or once focus
    /// is somewhere the person could have put it; the engine's own move to
    /// the first card in the first two turns doesn't count as theirs.
    private func claimReplacementFocus(
        _ key: String,
        removedKey: String,
        engineFallbackKey: String?,
        generation: Int,
        attempt: Int = 0
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.08)) {
            let movedByEngine = attempt < 2 && focusedKey == engineFallbackKey
            guard generation == focusRestorationGeneration,
                  focusRestorationOwner?.wrappedValue == true,
                  focusedKey == nil || focusedKey == removedKey || movedByEngine,
                  let card = cards.first(where: { $0.rowKey == key }) else { return }
            focusedKey = key
            onCollectionFocus?(card)
            guard attempt < 8 else { return }
            claimReplacementFocus(key, removedKey: removedKey, engineFallbackKey: engineFallbackKey,
                                  generation: generation, attempt: attempt + 1)
        }
    }

    /// Returning from a collection's page: when this row launched it, scroll
    /// its last focused card back into the strip and reclaim it.
    private func restoreFocusAfterDetailReturn(_ request: Int, proxy: ScrollViewProxy) {
        guard request > 0,
              request != lastAppliedDetailReturnFocusRequest,
              focusRestorationOwner?.wrappedValue == true,
              let key = lastFocusedKey,
              cards.contains(where: { $0.rowKey == key }) else { return }
        lastAppliedDetailReturnFocusRequest = request
        focusRestorationGeneration += 1
        let generation = focusRestorationGeneration
        proxy.scrollTo(key, anchor: .center)
        DispatchQueue.main.async {
            claimDetailReturnFocus(key, generation: generation)
        }
    }

    /// Reassert only while this row and card still own restoration, so a
    /// move the person makes after focus lands is never undone.
    private func claimDetailReturnFocus(_ key: String, generation: Int, attempt: Int = 0) {
        guard generation == focusRestorationGeneration,
              focusRestorationOwner?.wrappedValue == true,
              lastFocusedKey == key,
              let card = cards.first(where: { $0.rowKey == key }) else { return }
        focusedKey = key
        onCollectionFocus?(card)
        guard attempt < 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard generation == focusRestorationGeneration,
                  focusRestorationOwner?.wrappedValue == true,
                  lastFocusedKey == key,
                  focusedKey != key else { return }
            Self.focusLogger.debug(
                "collectionsRow.reclaimDetailReturnFocus attempt=\(attempt + 1, privacy: .public)"
            )
            claimDetailReturnFocus(key, generation: generation, attempt: attempt + 1)
        }
    }
}
#endif
