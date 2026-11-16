#if os(tvOS)
import SwiftUI

/// Below-the-hero body of the Lounge audiobook detail page: About (the
/// description beside the book's facts), alternate narrations, and the
/// discovery rails (series, more-by-author, related). Selections navigate
/// directly via `onNavigateToItem`.
///
/// Focus: a vertical progression of native focus stops. About is one
/// full-width focus target, so Down from any hero action lands on it before
/// the rails; Select opens the whole description when it is cut off. Each
/// rail lands d-pad entry on its first card (see `AudiobookCoverRail`). The
/// section holding focus is reported through `focusedSection` so the page
/// can keep its heading on screen.
struct TVAudiobookDetailSections: View {
    /// Each section's focus identity, doubling as its scroll ID.
    enum Section: String, Hashable {
        case about = "audiobook-about"
        case narrations = "audiobook-narrations"
        case series = "audiobook-series"
        case moreByAuthor = "audiobook-more-by-author"
        case related = "audiobook-related"
    }

    let detail: ItemDetail
    let focusedSection: FocusState<Section?>.Binding
    let onNavigateToItem: (String) -> Void

    @Environment(\.locale) private var locale
    @State private var showFullDescription = false

    /// Whether the detail has anything to show below the hero. The parent
    /// skips the section block entirely when empty so a bare audiobook page
    /// stays a single screen instead of scrolling into blank space.
    static func hasContent(_ detail: ItemDetail) -> Bool {
        if overview(of: detail) != nil { return true }
        if !DetailFacts(detail: detail).assembleFacts().isEmpty { return true }
        guard let audiobook = detail.audiobook else { return false }
        return !audiobook.otherNarrations.isEmpty
            || !(audiobook.series?.entries.isEmpty ?? true)
            || !(audiobook.related?.alsoByAuthor.isEmpty ?? true)
            || !(audiobook.related?.similar.isEmpty ?? true)
    }

    private static func overview(of detail: ItemDetail) -> String? {
        guard let overview = detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty else { return nil }
        return overview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
            aboutSection
            narrationsSection
            seriesRail
            moreByAuthorRail
            relatedRail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(isPresented: $showFullDescription) {
            if let overview = Self.overview(of: detail) {
                TVAudiobookDescriptionView(detail: detail, overview: overview)
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        let overview = Self.overview(of: detail)
        let facts = DetailFacts(detail: detail).assembleFacts(locale: locale)
        if overview != nil || !facts.isEmpty {
            VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
                TVSectionHeader(title: AppLanguage.string(.detailAudiobookAbout, locale: locale))
                AboutBlock(
                    overview: overview,
                    facts: facts,
                    onShowFullDescription: { showFullDescription = true }
                )
                .focused(focusedSection, equals: .about)
            }
            .id(Section.about.rawValue)
        }
    }

    // MARK: - Narrations

    @ViewBuilder
    private var narrationsSection: some View {
        let narrations = detail.audiobook?.otherNarrations ?? []
        if !narrations.isEmpty {
            VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
                TVSectionHeader(title: AppLanguage.string(.detailAudiobookNarrations, locale: locale))
                VStack(spacing: 10) {
                    ForEach(narrations) { narration in
                        narrationRow(narration)
                    }
                }
                .frame(maxWidth: 1380, alignment: .leading)
                .focusSection()
            }
            .focused(focusedSection, equals: .narrations)
            .id(Section.narrations.rawValue)
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
                title: series.name ?? AppLanguage.string(.detailAudiobookSeries, locale: locale),
                items: series.entries,
                // Every card in the rail repeats the series name the heading
                // already shows, so drop it and keep the book's own title.
                stripsSeriesName: series.name,
                onSelect: onNavigateToItem
            )
            .focused(focusedSection, equals: .series)
            .id(Section.series.rawValue)
        }
    }

    @ViewBuilder
    private var moreByAuthorRail: some View {
        if let items = detail.audiobook?.related?.alsoByAuthor, !items.isEmpty {
            AudiobookCoverRail(
                title: AppLanguage.string(.detailAudiobookMoreByAuthor, locale: locale),
                items: items,
                onSelect: onNavigateToItem
            )
            .focused(focusedSection, equals: .moreByAuthor)
            .id(Section.moreByAuthor.rawValue)
        }
    }

    @ViewBuilder
    private var relatedRail: some View {
        if let items = detail.audiobook?.related?.similar, !items.isEmpty {
            AudiobookCoverRail(
                title: AppLanguage.string(.detailAudiobookRelated, locale: locale),
                items: items,
                onSelect: onNavigateToItem
            )
            .focused(focusedSection, equals: .related)
            .id(Section.related.rawValue)
        }
    }
}

// MARK: - Narration row label

private struct NarrationRowLabel: View {
    let narration: AudiobookNarration

    @Environment(\.isFocused) private var isFocused
    @Environment(\.locale) private var locale

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
                Text(LocaleFormat.integer(year, locale: locale))
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

// MARK: - About block

/// The About section's single focus stop: the description, clamped, beside
/// the book's facts. Focusing it scrolls the whole section into view; when
/// the description is cut off, a MORE tag shows and Select opens the whole
/// text. A full-width target, so Down from any hero action reaches it.
private struct AboutBlock: View {
    let overview: String?
    let facts: [DetailFacts.Fact]
    let onShowFullDescription: () -> Void

    @Environment(\.locale) private var locale
    /// Heights of the clamped description and of the whole text at the same
    /// width; the description was cut off when they differ.
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > clampedHeight + 1 }

    private static let overviewLineLimit = 6

    var body: some View {
        Button {
            if isTruncated { onShowFullDescription() }
        } label: {
            HStack(alignment: .top, spacing: 80) {
                if let overview {
                    overviewColumn(overview)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                if !facts.isEmpty {
                    factsColumn
                        .frame(width: overview == nil ? 1000 : 520, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(AboutBlockStyle())
        .accessibilityHint(isTruncated ? Text(.detailOverviewMore) : Text(verbatim: ""))
    }

    private func overviewColumn(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(overview)
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.86))
                .lineSpacing(6)
                .lineLimit(Self.overviewLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                // A hidden unclamped copy measures the whole text.
                .background(alignment: .topLeading) {
                    Text(overview)
                        .font(.system(size: 26))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { clampedHeight = $0 }
            if isTruncated {
                MoreTag()
            }
        }
    }

    private var factsColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.label.uppercased(with: locale))
                        .font(.system(size: 17, weight: .bold))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.5))
                    Text(fact.value)
                        .font(.system(size: 23))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// "MORE" tag under a cut-off description; turns solid while the About block
/// has focus so it reads as what Select does.
private struct MoreTag: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(.detailOverviewMore)
            .font(.system(size: 18, weight: .bold))
            .tracking(1.5)
            .foregroundColor(isFocused ? .black : .white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.14))
            )
    }
}

/// A quiet focus treatment for a block of text: a faint panel that bleeds
/// past the text, so the text stays aligned with the heading above it.
private struct AboutBlockStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AboutBlockBody(configuration: configuration)
    }
}

private struct AboutBlockBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.08 : 0))
                    .padding(.horizontal, -32)
                    .padding(.vertical, -20)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
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
    /// A series name to strip from the start of each card's title.
    var stripsSeriesName: String? = nil
    let onSelect: (String) -> Void

    @Environment(\.locale) private var locale
    @FocusState private var focusedItemId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(items) { item in
                        TVMediaCard(
                            title: stripsSeriesName.map {
                                AudiobookDetailFormatting.cleanTitle(item.title, seriesName: $0)
                            } ?? item.title,
                            posterUrl: item.posterUrl ?? "",
                            year: item.year,
                            subtitle: item.seriesIndex.map {
                                AppLanguage.string(.detailAudiobookBookNumber($0), locale: locale)
                            },
                            action: { onSelect(item.contentId) },
                            cardWidth: 220,
                            aspect: .square,
                            focusTreatment: .ring,
                            focusBinding: $focusedItemId,
                            focusContentId: item.contentId
                        )
                    }
                }
                .padding(.vertical, 12)
            }
            .focusSection()
            .tvDefaultFocus(items.first?.contentId, in: $focusedItemId)
            .scrollClipDisabled()
        }
    }
}
#endif
