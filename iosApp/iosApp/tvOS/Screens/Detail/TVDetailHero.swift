#if os(tvOS)
import SwiftUI

/// Shared 1920×1080 detail metrics. These are deliberately separate from the
/// root Skyline metrics: the detail experience has its own approved rhythm,
/// while Home and Browse keep their existing layout untouched.
enum TVDetailLayout {
    static let horizontalInset: CGFloat = 100
    static let heroHeight: CGFloat = 690
    static let heroTopInset: CGFloat = 88
    static let heroContentWidth: CGFloat = 1_080
    static let bodySectionSpacing: CGFloat = 64
    static let sectionHeaderSpacing: CGFloat = 14
    static let pageBottomPadding: CGFloat = 140
}

/// Fully opaque page surface sampled from the title artwork. The sampled tint
/// is composited over black, so this remains a cheap, solid background rather
/// than a live material or blur. Artwork itself lives inside the scrolling
/// hero and therefore leaves the screen naturally as the viewer moves down.
struct TVDetailPageSurface<Content: View>: View {
    let backdropURL: String?
    @ViewBuilder let content: () -> Content

    @State private var sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)

    var body: some View {
        ZStack {
            Color.black
            sampledTint.opacity(0.42)
            content()
        }
        .ignoresSafeArea()
        .task(id: backdropURL) {
            guard let rawURL = backdropURL,
                  let url = URL(string: rawURL) else {
                sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)
                return
            }

            if let cached = HeroBackdropPalette.cachedTint(for: url) {
                sampledTint = cached
            }
            if let tint = await HeroBackdropPalette.tintColor(for: url) {
                sampledTint = tint
            }
        }
    }
}

/// Full-bleed cinematic hero for the tvOS item-detail screen. Modeled
/// after Apple TV's detail page: a nearly full-viewport backdrop layered
/// with a tall left-column editorial stack (eyebrow pill → title →
/// source row → overview → facts+quality → actions) and a quiet
/// right-side "Starring ..." line positioned mid-hero.
///
/// The intent is to show enough of the below-fold rail peeking at the
/// bottom that the viewer instinctively drifts down when they want
/// episodes / similar titles — rather than reaching the "end" of the
/// hero.
struct TVDetailHero<Actions: View, BelowSynopsis: View>: View {
    let title: String
    let seriesTitle: String?
    let logoUrl: String?
    let backdropUrl: String?
    /// Optional short editorial line placed in a capsule above the title
    /// (e.g. "New Episode Friday", "Continuing Series"). Hidden when nil.
    let eyebrow: String?
    /// Source/genre line shown under the title. Text items are
    /// pipe-separated; a single optional rating token is rendered as an
    /// outlined chip at the end of the row.
    let sourceTokens: [String]
    let ratingChip: String?
    /// Short description shown in the hero. Clamped to 3 lines.
    let overview: String?
    /// Inline facts row shown above the action buttons. Mixes plain text
    /// (year / runtime / maturity) and outlined quality chips
    /// (4K / HDR / ATMOS / CC).
    let factsLine: [TVHeroFactToken]
    /// Optional "Starring A, B, C" line floated on the right of the hero
    /// at mid-height. Hidden when nil.
    let starringText: String?
    /// Optional, non-interactive playback readout shown directly below the
    /// credits. Series overview uses this to disclose the remembered version
    /// that Play will launch without adding a second selector to the page.
    let playbackSummaryText: String?
    @ViewBuilder let actions: () -> Actions
    /// Affordance rendered directly under the synopsis (e.g. the on-view
    /// description-translation control). Pass `{ EmptyView() }` when there's
    /// nothing to show.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            content
        }
        .frame(height: TVDetailLayout.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        GeometryReader { geometry in
            let artworkWidth = geometry.size.width * 0.64
            let artworkHeight = min(
                TVDetailLayout.heroHeight * 0.94,
                artworkWidth * 9 / 16
            )

            if let url = backdropUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: artworkWidth, height: artworkHeight),
                    contentMode: .fill
                )
                .frame(width: artworkWidth, height: artworkHeight)
                .clipped()
                .mask { artworkFadeMask }
                .frame(
                    width: geometry.size.width,
                    height: TVDetailLayout.heroHeight,
                    alignment: .topTrailing
                )
            }
        }
    }

    /// The image is crisp in the top-right and dissolves into the solid page
    /// tint on its leading and lower edges. No blur or translucent material.
    private var artworkFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.46),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .trailing,
            endPoint: .leading
        )
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.70),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Content column

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            editorialColumn

            // Give the action cluster the full hero width with leading
            // content (instead of `HStack { actions(); Spacer() }`) so the
            // selector row inside can stretch its own focus section full-width
            // for Down navigation — a trailing Spacer would split the width
            // with that greedy child and leave the section too narrow.
            // Still a full-width focus destination so lower rails can move
            // "up" into this cluster even from a far-right card.
            actions()
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        .padding(.top, TVDetailLayout.heroTopInset)
        .padding(.horizontal, TVDetailLayout.horizontalInset)
        .frame(
            maxWidth: .infinity,
            maxHeight: TVDetailLayout.heroHeight,
            alignment: .topLeading
        )
    }

    private var editorialColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow, !eyebrow.isEmpty {
                TVHeroEyebrow(text: eyebrow)
            }
            titleBlock
                .padding(.top, eyebrow == nil ? 0 : 2)
            metadataBlock
            if let overview, !overview.isEmpty {
                TVExpandableSynopsis(overview: overview)
            }
            belowSynopsis()
            if let starringText, !starringText.isEmpty {
                heroCredit(starringText)
            }
            if let playbackSummaryText, !playbackSummaryText.isEmpty {
                Text(playbackSummaryText)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(
                        .easeInOut(duration: ContinuumTheme.fastDuration),
                        value: playbackSummaryText
                    )
                    .accessibilityLabel("Playback: \(playbackSummaryText)")
            }
        }
        .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .leading)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let episodeSeriesTitle {
            TVEpisodeHierarchyTitle(
                seriesTitle: episodeSeriesTitle,
                episodeTitle: title,
                logoUrl: logoUrl
            )
        } else if let logoUrl, !logoUrl.isEmpty {
            CachedAsyncImage(
                url: logoUrl,
                contentMode: .fit,
                alignment: .bottomLeading,
                placeholderStyle: .clear
            )
                .frame(maxWidth: 650, maxHeight: 160, alignment: .bottomLeading)
                .accessibilityLabel(title)
        } else {
            TVHeroTitle(title: title)
        }
    }

    private var episodeSeriesTitle: String? {
        guard let trimmed = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataBlock: some View {
        if episodeSeriesTitle != nil {
            sourceRow
            factsRow(includeSourceTokens: false)
        } else {
            factsRow(includeSourceTokens: true)
        }
    }

    @ViewBuilder
    private var sourceRow: some View {
        if !sourceTokens.isEmpty {
            HStack(spacing: 14) {
                ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                    Text(token)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.78))
                }
            }
        }
    }

    // MARK: - Facts + quality row

    @ViewBuilder
    private func factsRow(includeSourceTokens: Bool) -> some View {
        if !factsLine.isEmpty || (includeSourceTokens && !sourceTokens.isEmpty) || ratingChip != nil {
            HStack(spacing: 14) {
                ForEach(Array(factsLine.enumerated()), id: \.offset) { index, token in
                    if index > 0 { metadataDivider }
                    factsItem(token)
                }

                if includeSourceTokens {
                    ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                        if !factsLine.isEmpty || index > 0 { metadataDivider }
                        Text(token)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.90))
                    }
                }

                if let ratingChip, !ratingChip.isEmpty {
                    if !factsLine.isEmpty || (includeSourceTokens && !sourceTokens.isEmpty) {
                        metadataDivider
                    }
                    ratingBadge(ratingChip)
                }
            }
        }
    }

    private var metadataDivider: some View {
        Text("·")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.45))
    }

    private func ratingBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.78), lineWidth: 1.5)
            )
    }

    @ViewBuilder
    private func factsItem(_ token: TVHeroFactToken) -> some View {
        switch token {
        case .text(let value):
            Text(value)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Color.white.opacity(0.88))
        case .rating(let value):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.continuumSuccess.opacity(0.9))
                Text(value)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.88))
            }
        case .chip(let value):
            Text(value)
                .font(.system(size: 16, weight: .heavy))
                .tracking(1.0)
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1.2)
                )
        }
    }

    private func heroCredit(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 23, weight: .regular))
            .foregroundColor(Color.white.opacity(0.70))
            .lineLimit(1)
    }
}

// MARK: - Title treatment

/// Heavy condensed display title. Splits on ": " into title + subtitle
/// when the source title contains a colon — e.g. "Monarch: Legacy of
/// Monsters" becomes a two-line composition with a larger lead and a
/// smaller, still-heavy underline, matching the Apple TV wordmark
/// treatment.
private struct TVHeroTitle: View {
    let title: String

    var body: some View {
        let parts = split(title)
        VStack(alignment: .leading, spacing: 4) {
            Text(parts.primary.uppercased())
                .font(primaryFont)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(subtitleFont)
                    .foregroundColor(Color.white.opacity(0.95))
                    .tracking(1.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primaryFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 92, weight: .black).width(.compressed)
        }
        return .system(size: 88, weight: .black)
    }

    private var subtitleFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 40, weight: .heavy).width(.compressed)
        }
        return .system(size: 38, weight: .heavy)
    }

    private func split(_ raw: String) -> (primary: String, subtitle: String?) {
        let separators: [String] = [": ", " — ", " – ", " - "]
        for sep in separators {
            if let range = raw.range(of: sep) {
                let head = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let tail = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !tail.isEmpty {
                    return (head, tail)
                }
            }
        }
        return (raw, nil)
    }
}

private struct TVEpisodeHierarchyTitle: View {
    let seriesTitle: String
    let episodeTitle: String
    let logoUrl: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let logoUrl, !logoUrl.isEmpty {
                CachedAsyncImage(
                    url: logoUrl,
                    contentMode: .fit,
                    alignment: .bottomLeading,
                    placeholderStyle: .clear
                )
                    .frame(maxWidth: 650, maxHeight: 140, alignment: .bottomLeading)
                    .accessibilityLabel(seriesTitle)
            } else {
                Text(seriesTitle.uppercased())
                    .font(seriesFont)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(episodeTitle)
                .font(episodeFont)
                .foregroundColor(Color.white.opacity(0.94))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var seriesFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 92, weight: .black).width(.compressed)
        }
        return .system(size: 88, weight: .black)
    }

    private var episodeFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 46, weight: .bold)
        }
        return .system(size: 44, weight: .bold)
    }
}

// MARK: - Eyebrow pill

private struct TVHeroEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
    }
}

// MARK: - Tokens

/// A token in the combined facts row. `.text` items get pipe separators
/// between them; `.rating` renders a green check + maturity label;
/// `.chip` renders an outlined pill (e.g. 4K / HDR / ATMOS).
enum TVHeroFactToken: Hashable {
    case text(String)
    case rating(String)
    case chip(String)
}

// MARK: - Metadata builders

enum TVHeroMetadata {
    // Source row (type · genres)

    static func movieSourceTokens(from detail: ItemDetail) -> [String] {
        if detail.type == "episode" {
            if let label = episodeNumberLabel(from: detail) {
                return [label]
            }
            return []
        }
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    /// "Season 3 · Episode 8" (or "Specials · Episode 5" / "Episode 5")
    /// for an episode `ItemDetail`.
    private static func episodeNumberLabel(from detail: ItemDetail) -> String? {
        let seasonPart: String?
        if let season = detail.seasonNumber {
            seasonPart = season == 0 ? "Specials" : "Season \(season)"
        } else {
            seasonPart = nil
        }
        let episodePart = detail.episodeNumber.flatMap { n in n > 0 ? "Episode \(n)" : nil }

        switch (seasonPart, episodePart) {
        case let (.some(s), .some(e)): return "\(s) \u{00B7} \(e)"
        case let (.some(s), .none):    return s
        case let (.none, .some(e)):    return e
        case (.none, .none):           return nil
        }
    }

    static func seriesSourceTokens(from detail: ItemDetail) -> [String] {
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    static func contentRatingChip(from detail: ItemDetail) -> String? {
        guard let rating = detail.contentRating?
            .trimmingCharacters(in: .whitespaces), !rating.isEmpty
        else { return nil }
        return rating
    }

    // Facts line (year · runtime · maturity · quality chips)

    static func movieFactsLine(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [TVHeroFactToken] {
        var tokens: [TVHeroFactToken] = []
        if detail.type == "episode",
           let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(.text(airDate))
        } else if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let runtime = detail.runtime, runtime > 0 {
            tokens.append(.text(formatRuntime(runtime)))
        }
        return tokens
    }

    static func seriesFactsLine(from detail: ItemDetail) -> [TVHeroFactToken] {
        var tokens: [TVHeroFactToken] = []
        if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let count = detail.seasonCount, count > 0 {
            tokens.append(.text("\(count) Season\(count == 1 ? "" : "s")"))
        }
        return tokens
    }

    // Eyebrow (short editorial line)

    static func eyebrow(from detail: ItemDetail) -> String? {
        if detail.type == "episode" {
            if let seriesTitle = detail.seriesTitle?.trimmingCharacters(in: .whitespaces),
               !seriesTitle.isEmpty {
                return seriesTitle
            }
        }
        if let status = detail.status?.trimmingCharacters(in: .whitespaces),
           !status.isEmpty,
           detail.type == "series" {
            switch status.lowercased() {
            case "continuing", "returning series", "returning":
                return "Continuing Series"
            case "ended":
                return "Complete Series"
            case "in production":
                return "New Season Coming"
            default: break
            }
        }
        return nil
    }

    // Starring (first 3 cast names)

    static func starringText(from detail: ItemDetail) -> String? {
        if detail.type == "movie" {
            let directors = detail.crew?
                .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name) ?? []
            guard !directors.isEmpty else { return nil }
            return "Directed by " + directors.prefix(2).joined(separator: ", ")
        }
        if detail.type == "episode" { return nil }
        guard let cast = detail.cast, !cast.isEmpty else { return nil }
        let names = cast.prefix(3).map(\.name)
        guard !names.isEmpty else { return nil }
        return "Starring " + names.joined(separator: ", ")
    }

    // MARK: - Helpers

    private static func typeLabel(detail: ItemDetail) -> String {
        switch detail.type.lowercased() {
        case "movie": return "Movie"
        case "series": return "TV Show"
        case "episode": return "Episode"
        default: return detail.type.capitalized
        }
    }

    private static func qualityTokens(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [TVHeroFactToken] {
        guard let version = selectedVersion ?? preferredVersion(from: detail) else { return [] }
        var tokens: [TVHeroFactToken] = []
        if let res = resolutionLabel(version.resolution) {
            tokens.append(.chip(res))
        }
        if version.hdr == true {
            tokens.append(.chip(dolbyVisionLabel(version: version) ?? "HDR"))
        }
        if let audio = primaryAudioLabel(version: version) {
            tokens.append(.chip(audio))
        }
        if hasSubtitles(version: version) {
            tokens.append(.chip("CC"))
        }
        return tokens
    }

    private static func preferredVersion(from detail: ItemDetail) -> FileVersion? {
        guard let versions = detail.versions, !versions.isEmpty else { return nil }
        if let lastId = detail.userData?.lastFileId,
           let lastVersion = versions.first(where: { $0.fileId == lastId }) {
            return lastVersion
        }
        return versions.first
    }

    private static func resolutionLabel(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        if raw.contains("2160") || raw.contains("4k") { return "4K" }
        if raw.contains("1080") { return "HD" }
        if raw.contains("720") { return "HD" }
        if raw.contains("480") { return "SD" }
        return nil
    }

    private static func dolbyVisionLabel(version: FileVersion) -> String? {
        let videoTracks = version.videoTracks ?? []
        if videoTracks.contains(where: { ($0.dolbyVision ?? "").isEmpty == false }) {
            return "DOLBY VISION"
        }
        return nil
    }

    private static func primaryAudioLabel(version: FileVersion) -> String? {
        let tracks = version.audioTracks ?? []
        let defaultTrack = tracks.first(where: { $0.isDefault == true }) ?? tracks.first
        guard let track = defaultTrack else { return nil }

        if let layout = track.channelLayout?.lowercased() {
            if layout.contains("atmos") { return "ATMOS" }
            if layout.contains("7.1") { return "7.1" }
            if layout.contains("5.1") { return "5.1" }
            if layout.contains("stereo") || layout == "2.0" { return nil }
        }
        if let channels = track.channels {
            switch channels {
            case 8: return "7.1"
            case 6: return "5.1"
            default: return nil
            }
        }
        return nil
    }

    private static func hasSubtitles(version: FileVersion) -> Bool {
        !(version.subtitleTracks ?? []).isEmpty
    }

    private static func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
#endif
