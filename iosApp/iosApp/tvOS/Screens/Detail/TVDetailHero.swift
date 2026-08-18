#if os(tvOS)
import SwiftUI

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
    /// (4K Dolby Vision / DD+ Atmos / CC).
    let factsLine: [TVHeroFactToken]
    /// Optional "Starring A, B, C" line floated on the right of the hero
    /// at mid-height. Hidden when nil.
    let starringText: String?
    @ViewBuilder let actions: () -> Actions
    /// Affordance rendered directly under the synopsis (e.g. the on-view
    /// description-translation control). Pass `{ EmptyView() }` when there's
    /// nothing to show.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    private let heroHeight: CGFloat = 980
    private let contentMaxWidth: CGFloat = 1200

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            leftGradient
            bottomFade
            content
        }
        .overlay(alignment: .trailing) { starringOverlay }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        Group {
            if let url = backdropUrl, !url.isEmpty {
                CachedAsyncImage(url: url, contentMode: .fill)
            } else {
                Color.continuumSurface
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    /// Heavy left-side darkening → clear on the right so the backdrop
    /// imagery breathes while text stays legible.
    private var leftGradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.92), location: 0.0),
                .init(color: Color.black.opacity(0.70), location: 0.22),
                .init(color: Color.black.opacity(0.35), location: 0.55),
                .init(color: .clear, location: 0.88),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Soft bottom fade into the scroll body — subtle so the seam is
    /// invisible and a hint of the next rail peeks through.
    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.55),
                .init(color: Color.continuumBackground.opacity(0.55), location: 0.85),
                .init(color: Color.continuumBackground, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Content column

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            editorialColumn

            // Give the action cluster the full hero width with leading
            // content (instead of `HStack { actions(); Spacer() }`) so the
            // selector row inside can stretch its own focus section full-width
            // for Down navigation — a trailing Spacer would split the width
            // with that greedy child and leave the section too narrow.
            // Still a full-width focus destination so lower rails can move
            // "up" into this cluster even from a far-right card.
            actions()
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        .padding(.leading, ContinuumTheme.safePadding)
        .padding(.trailing, ContinuumTheme.safePadding)
        // Keep this tight: the detail pages' outer VStack already adds its
        // own spacing between the hero and the first content section, so a
        // large inset here reads as a dead band under the selector row.
        .padding(.bottom, 48)
    }

    private var editorialColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let eyebrow, !eyebrow.isEmpty {
                TVHeroEyebrow(text: eyebrow)
            }
            titleBlock
                .padding(.top, eyebrow == nil ? 0 : 4)
            sourceRow
            if let overview, !overview.isEmpty {
                TVExpandableSynopsis(overview: overview)
            }
            belowSynopsis()
            factsRow
        }
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let episodeSeriesTitle {
            TVEpisodeHierarchyTitle(seriesTitle: episodeSeriesTitle, episodeTitle: title)
        } else if let logoUrl, !logoUrl.isEmpty {
            CachedAsyncImage(url: logoUrl, contentMode: .fit, placeholderStyle: .clear)
                .frame(maxWidth: 620, maxHeight: 220, alignment: .bottomLeading)
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

    // MARK: - Source row (type · genre · rating-chip)

    @ViewBuilder
    private var sourceRow: some View {
        if !sourceTokens.isEmpty || ratingChip != nil {
            HStack(spacing: 14) {
                ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                    Text(token)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.92))
                }
                if let ratingChip, !ratingChip.isEmpty {
                    Text(ratingChip)
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(1.0)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                        )
                        .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - Facts + quality row

    @ViewBuilder
    private var factsRow: some View {
        if !factsLine.isEmpty {
            HStack(spacing: 14) {
                ForEach(Array(factsLine.enumerated()), id: \.offset) { index, token in
                    if index > 0, case .text = token, case .text = factsLine[index - 1] {
                        Text("·")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.45))
                    }
                    factsItem(token)
                }
            }
        }
    }

    @ViewBuilder
    private func factsItem(_ token: TVHeroFactToken) -> some View {
        switch token {
        case .text(let value):
            Text(value)
                .font(.system(size: 22, weight: .medium))
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

    // MARK: - Starring overlay (right-aligned, vertical center)

    @ViewBuilder
    private var starringOverlay: some View {
        if let starringText, !starringText.isEmpty {
            Text(starringText)
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(Color.white.opacity(0.8))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 460, alignment: .trailing)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                .padding(.trailing, ContinuumTheme.safePadding)
                .padding(.bottom, heroHeight * 0.45)
        }
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
                .shadow(color: .black.opacity(0.55), radius: 16, y: 4)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(subtitleFont)
                    .foregroundColor(Color.white.opacity(0.95))
                    .tracking(1.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
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

    var body: some View {
        let parts = split(episodeTitle)
        VStack(alignment: .leading, spacing: 10) {
            Text(seriesTitle.uppercased())
                .font(seriesFont)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.55), radius: 16, y: 4)
            Text(parts.primary)
                .font(episodeFont)
                .foregroundColor(Color.white.opacity(0.94))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(subtitleFont)
                    .foregroundColor(Color.white.opacity(0.82))
                    .tracking(1.2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            }
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
            return .system(size: 50, weight: .heavy).width(.compressed)
        }
        return .system(size: 48, weight: .heavy)
    }

    private var subtitleFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 32, weight: .heavy).width(.compressed)
        }
        return .system(size: 30, weight: .heavy)
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
/// `.chip` renders an outlined pill (e.g. 4K Dolby Vision / DD+ Atmos).
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
            var tokens: [String] = []
            if let label = episodeNumberLabel(from: detail) {
                tokens.append(label)
            }
            if let genres = detail.genres, !genres.isEmpty {
                tokens.append(contentsOf: genres.prefix(1))
            }
            return tokens
        }
        var tokens: [String] = [typeLabel(detail: detail)]
        if let genres = detail.genres, !genres.isEmpty {
            tokens.append(contentsOf: genres.prefix(2))
        }
        return tokens
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
        var tokens: [String] = ["TV Show"]
        if let genres = detail.genres, !genres.isEmpty {
            tokens.append(contentsOf: genres.prefix(2))
        }
        return tokens
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
        if let imdb = detail.ratingImdb {
            tokens.append(.text(String(format: "★ %.1f", imdb)))
        }
        tokens.append(contentsOf: qualityTokens(from: detail, version: selectedVersion))
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
        if let imdb = detail.ratingImdb {
            tokens.append(.text(String(format: "★ %.1f", imdb)))
        }
        tokens.append(contentsOf: qualityTokens(from: detail))
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
        if let video = DetailPlaybackFormatting.heroVideoBadgeLabel(version) {
            tokens.append(.chip(video))
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

    private static func primaryAudioLabel(version: FileVersion) -> String? {
        let tracks = version.audioTracks ?? []
        let defaultTrack = tracks.first(where: { $0.isDefault == true }) ?? tracks.first
        guard let track = defaultTrack else { return nil }

        if let atmos = DetailPlaybackFormatting.atmosBadgeLabel(track) { return atmos }
        if let layout = track.channelLayout?.lowercased() {
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
