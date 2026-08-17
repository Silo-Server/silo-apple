#if os(tvOS)
import SwiftUI

/// Below-the-fold body of the Lounge audiobook detail page: About (overview +
/// static credits), alternate narrations, and the discovery rails (series,
/// more-by-author, related). This content used to live on a separate
/// full-screen "⋯" info cover; it now scrolls under the hero like the
/// movie/series detail bodies, so selections navigate directly via
/// `onNavigateToItem` — there is no cover to dismiss first.
///
/// Focus: a vertical progression of native `focusSection` rows and rails;
/// each rail lands d-pad entry on its first card (see `AudiobookCoverRail`).
struct TVAudiobookDetailSections: View {
    let detail: ItemDetail
    let onNavigateToItem: (String) -> Void

    /// Whether the detail has anything to show below the fold. The parent
    /// skips the section block entirely when empty so a bare audiobook page
    /// stays a fixed single screen instead of scrolling into blank space.
    static func hasContent(_ detail: ItemDetail) -> Bool {
        if let overview = detail.overview, !overview.isEmpty { return true }
        guard let audiobook = detail.audiobook else { return false }
        return !audiobook.otherNarrations.isEmpty
            || !(audiobook.series?.entries.isEmpty ?? true)
            || !(audiobook.related?.alsoByAuthor.isEmpty ?? true)
            || !(audiobook.related?.similar.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 64) {
            aboutSection
            narrationsSection
            seriesRail
            moreByAuthorRail
            relatedRail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - About + credits

    @ViewBuilder
    private var aboutSection: some View {
        if let overview = detail.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeader("About")
                Text(overview)
                    .font(.system(size: 25))
                    .foregroundColor(.white.opacity(0.72))
                    .lineSpacing(4)
                    .frame(maxWidth: 1280, alignment: .leading)
                if let credits = staticCredits {
                    Text(credits)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
        } else if let credits = staticCredits {
            Text(credits)
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    /// "Written by … · Narrated by … · Publisher · Year" — empty pieces skipped.
    private var staticCredits: String? {
        var pieces: [String] = []
        if let authors = AudiobookDetailFormatting.peopleSummary(
            detail.audiobook?.authors.map(\.name) ?? [], visible: 3
        ) {
            pieces.append("Written by \(authors)")
        }
        if let narrators = AudiobookDetailFormatting.peopleSummary(
            detail.audiobook?.narrators.map(\.name) ?? [], visible: 3
        ) {
            pieces.append("Narrated by \(narrators)")
        }
        if let publisher = detail.audiobook?.publisher, !publisher.isEmpty {
            pieces.append(publisher)
        }
        if let year = detail.year {
            pieces.append(String(year))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    // MARK: - Narrations

    @ViewBuilder
    private var narrationsSection: some View {
        let narrations = detail.audiobook?.otherNarrations ?? []
        if !narrations.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeader("Narrations")
                VStack(spacing: 10) {
                    ForEach(narrations) { narration in
                        narrationRow(narration)
                    }
                }
                .frame(maxWidth: 1380, alignment: .leading)
                .focusSection()
            }
        }
    }

    private func narrationRow(_ narration: AudiobookNarration) -> some View {
        Button {
            onNavigateToItem(narration.contentId)
        } label: {
            NarrationRowLabel(narration: narration)
        }
        .buttonStyle(TVAudiobookRowStyle())
    }

    // MARK: - Rails

    @ViewBuilder
    private var seriesRail: some View {
        if let series = detail.audiobook?.series, !series.entries.isEmpty {
            AudiobookCoverRail(
                title: series.name ?? "Series",
                items: series.entries,
                onSelect: onNavigateToItem
            )
        }
    }

    @ViewBuilder
    private var moreByAuthorRail: some View {
        if let items = detail.audiobook?.related?.alsoByAuthor, !items.isEmpty {
            AudiobookCoverRail(title: "More by Author", items: items, onSelect: onNavigateToItem)
        }
    }

    @ViewBuilder
    private var relatedRail: some View {
        if let items = detail.audiobook?.related?.similar, !items.isEmpty {
            AudiobookCoverRail(title: "Related", items: items, onSelect: onNavigateToItem)
        }
    }

    // MARK: - Shared

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundColor(.white)
    }
}

// MARK: - Narration row label

private struct NarrationRowLabel: View {
    let narration: AudiobookNarration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white.opacity(0.72))
                .frame(width: 40)

            Text(narration.narrators.isEmpty ? narration.title : narration.narrators.joined(separator: ", "))
                .font(.system(size: 27, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .lineLimit(1)

            Spacer(minLength: 24)

            if let year = narration.year {
                Text(String(year))
                    .font(.system(size: 22))
                    .monospacedDigit()
                    .foregroundColor(isFocused ? .black.opacity(0.5) : .white.opacity(0.55))
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .contentShape(Rectangle())
    }
}

// MARK: - Cover rail

/// One horizontal rail of square audiobook covers (series / more-by-author /
/// related), built on the house `TVMediaCard` so the cards inherit the ring
/// focus treatment (system halo suppressed) and the cached Nuke renderer.
/// Owns a `@FocusState` so d-pad entry lands on the first card instead of
/// the geometrically-nearest one — same pattern as `TVSimilarRail`.
private struct AudiobookCoverRail: View {
    let title: String
    let items: [AudiobookRelatedItem]
    let onSelect: (String) -> Void

    @FocusState private var focusedItemId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(items) { item in
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            year: item.year,
                            subtitle: item.seriesIndex.map { "Book \($0)" },
                            action: { onSelect(item.contentId) },
                            cardWidth: 220,
                            aspect: .square,
                            focusTreatment: .ring,
                            focusBinding: $focusedItemId,
                            focusContentId: item.contentId
                        )
                    }
                }
                .padding(.vertical, 24)
            }
            .focusSection()
            .applyDefaultFocusIfPresent($focusedItemId, id: items.first?.contentId)
            .scrollClipDisabled()
        }
    }
}
#endif
