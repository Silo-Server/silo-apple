#if os(tvOS)
import SwiftUI

/// Collection poster card (Skyline §6.3): a standard 2:3 poster built from the
/// collection's own artwork, sharing the library Browse poster grammar
/// (`TVMediaCard` — native `.card` focus lift, `cornerRadius`, centered caption)
/// so a collection reads as a first-class browseable tile rather than a
/// bespoke surface. The caption carries the collection name with an item-count
/// line beneath it, paralleling the title/year caption on media cards.
///
/// Artwork: `LibraryCollection.posterUrl`. When the server returns no poster
/// the card degrades to a deterministic gradient with a stack glyph, so an
/// art-less collection still reads as a collection rather than a blank tile.
struct TVCollectionPosterCard: View {
    let collection: LibraryCollection
    let action: () -> Void

    /// Poster width; height tracks the 2:3 ratio. Defaults to the standard
    /// tvOS poster so the collections grid matches the library grid.
    var cardWidth: CGFloat = ContinuumTheme.posterCardWidth
    /// Default-focus hook for the grid's first card on tab entry.
    var prefersDefaultFocus: Bool = false
    var defaultFocusNamespace: Namespace.ID? = nil
    /// External focus binding so the grid can route d-pad-entry focus onto a
    /// specific card (mirrors `TVMediaCard.focusBinding`).
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusContentId: String? = nil

    @FocusState private var isFocused: Bool
    @State private var uiCustomization = UICustomizationPreferences.shared

    // Standard 2:3 movie-poster aspect ratio — height tracks width.
    private var resolvedCardWidth: CGFloat {
        cardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat { resolvedCardWidth * 1.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            posterButton
            if uiCustomization.cardPresentation.caption.showsTitle {
                caption
            }
        }
        .frame(width: resolvedCardWidth)
    }

    private var posterButton: some View {
        Button(action: action) { poster }
            .buttonStyle(.card)
            .focused($isFocused)
            .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
            .applyCollectionFocusBinding(focusBinding, contentId: focusContentId)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Poster

    @ViewBuilder
    private var poster: some View {
        Group {
            if let url = collection.posterUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: resolvedCardWidth, height: cardHeight),
                    thumbhash: collection.posterThumbhash,
                    contentMode: .fill
                )
            } else {
                placeholder
            }
        }
        .frame(width: resolvedCardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
    }

    /// Art-less fallback: a deterministic gradient + stack glyph so the tile
    /// still reads as a collection. Same derivation the card used before the
    /// poster redesign, so missing-art collections look consistent.
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.50, brightness: 0.42),
                    Color(hue: hue, saturation: 0.32, brightness: 0.22),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "square.stack.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    // MARK: - Caption

    /// Centered name with an item-count line beneath — the collection analogue
    /// of `TVMediaCard`'s title/year caption.
    private var caption: some View {
        VStack(spacing: 4) {
            Text(collection.name)
                .font(.continuumPosterTitle)
                .foregroundColor(isFocused ? .continuumOnSurface : .continuumOnSurface.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: resolvedCardWidth, alignment: .center)
                .clipped()
                .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)

            if uiCustomization.cardPresentation.caption.showsMetadata, let countText {
                Text(countText)
                    .font(.continuumPosterMetadata)
                    .foregroundColor(.continuumSecondaryText)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: resolvedCardWidth, alignment: .center)
    }

    // MARK: - Derived

    /// `12 MOVIES`-style caps count. Uses the collection's content noun when
    /// the type is known, else the neutral `ITEMS`.
    private var countText: String? {
        guard let count = collection.itemCount, count > 0 else { return nil }
        return "\(count) \(countNoun(for: count))".uppercased()
    }

    private func countNoun(for count: Int) -> String {
        let plural = count != 1
        switch collection.collectionType?.lowercased() {
        case "movie", "movies":
            return plural ? "movies" : "movie"
        case "series", "show", "shows", "tvshows":
            return plural ? "shows" : "show"
        case "album", "albums":
            return plural ? "albums" : "album"
        case "audiobook", "audiobooks", "book", "books":
            return plural ? "books" : "book"
        default:
            return plural ? "items" : "item"
        }
    }

    private var accessibilityLabel: String {
        var label = "\(collection.name), collection"
        if let count = collection.itemCount, count > 0 {
            label += ", \(count) \(count == 1 ? "item" : "items")"
        }
        return label
    }

    /// Stable hue for the art-less placeholder, derived from the id so a
    /// collection's fallback tile looks the same each time it appears.
    private var hue: Double {
        var hasher = Hasher()
        hasher.combine(collection.id)
        let raw = UInt(bitPattern: hasher.finalize())
        return Double(raw % 360) / 360.0
    }
}

private extension View {
    /// Binds the inner button to the grid's `@FocusState` so the grid can route
    /// d-pad-entry default focus onto this specific card. No-op when no binding
    /// is supplied. Mirrors `TVMediaCard.applyRailFocus`.
    @ViewBuilder
    func applyCollectionFocusBinding(_ binding: FocusState<String?>.Binding?, contentId: String?) -> some View {
        if let binding, let contentId {
            self.focused(binding, equals: contentId)
        } else {
            self
        }
    }
}
#endif
