#if !os(tvOS)
import SwiftUI

/// Horizontal rail of trailer / extra cards for the phone detail pages.
///
/// Pure presentation: the entries arrive with the `ItemDetail` the page
/// already loaded (`TrailerRail.entries` owns the merge and filter rules)
/// and every tap is handed straight back to the caller. The section header
/// lives in here so an item with no trailers renders nothing at all rather
/// than an orphaned title — the same reason `PhoneSimilarRail` owns its
/// header.
struct PhoneTrailersRail: View {
    let entries: [TrailerRailEntry]
    let onSelect: (TrailerRailEntry) -> Void

    /// Matched to `PhoneEpisodeRail` so the two landscape rails that can
    /// share an episode page line up card-for-card.
    private let cardWidth: CGFloat = 240
    private let thumbnailHeight: CGFloat = 135   // 16:9 of 240
    private let cardSpacing: CGFloat = 14
    private let thumbnailCornerRadius: CGFloat = 8

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                PhoneSectionHeader(title: "Trailers & More")
                    .padding(.horizontal, ContinuumTheme.safePadding)
                rail
            }
        }
    }

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(entries) { entry in
                    PhoneTrailerCard(
                        entry: entry,
                        cardWidth: cardWidth,
                        thumbnailHeight: thumbnailHeight,
                        thumbnailCornerRadius: thumbnailCornerRadius,
                        onSelect: { onSelect(entry) }
                    )
                }
            }
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Section wrapper

/// The rail plus the platform-specific handling of a remote card tap.
///
/// Both phone detail screens embed this instead of `PhoneTrailersRail`
/// directly: a remote trailer is handed to the YouTube app with the same
/// deep link used on tvOS, then falls back to the public watch page when no
/// app accepts it. That branch would otherwise be copied into
/// `MovieDetailContent` and `SeriesDetailContent` verbatim. Local extras are
/// ordinary playback targets, so those taps continue up to the detail view
/// that owns the player presentation.
struct PhoneTrailersSection: View {
    let entries: [TrailerRailEntry]
    let onPlayExtra: (_ contentId: String) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        PhoneTrailersRail(entries: entries, onSelect: handleSelection)
    }

    private func handleSelection(_ entry: TrailerRailEntry) {
        switch entry {
        case .local(let extra):
            onPlayExtra(extra.contentId)
        case .remote(let video):
            openRemoteTrailer(siteKey: video.siteKey)
        }
    }

    private func openRemoteTrailer(siteKey: String) {
        guard let appURL = TrailerRail.youtubeDeepLinkURL(siteKey: siteKey),
              let webURL = TrailerRail.youtubeWatchURL(siteKey: siteKey) else {
            return
        }

        openURL(appURL) { accepted in
            guard !accepted else { return }
            openURL(webURL)
        }
    }
}

// MARK: - Card

private struct PhoneTrailerCard: View {
    let entry: TrailerRailEntry
    let cardWidth: CGFloat
    let thumbnailHeight: CGFloat
    let thumbnailCornerRadius: CGFloat
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(kindLabel)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.continuumOnSurface.opacity(0.55))

                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.continuumOnSurface.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let durationLabel {
                        Text(durationLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.continuumSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title), \(ExtraKindLabels.label(for: entry.kind))")
    }

    // MARK: - Thumbnail

    private var thumbnail: some View {
        ZStack {
            artwork
            playGlyph
        }
        .frame(width: cardWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnailURL {
            // YouTube's `hqdefault` still is 4:3 with letterbox bars; a
            // fill-mode crop to 16:9 removes them almost exactly.
            AsyncImageView(
                url: thumbnailURL.absoluteString,
                targetSize: CGSize(width: cardWidth, height: thumbnailHeight),
                contentMode: .fill
            )
            .frame(width: cardWidth, height: thumbnailHeight)
            .clipped()
        } else {
            // Local extras have no artwork of their own — the scanner only
            // records the file — so they get the surface tile plus the
            // shared play glyph.
            Rectangle()
                .fill(Color.continuumSurfaceElevated)
                .frame(width: cardWidth, height: thumbnailHeight)
        }
    }

    private var playGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: 36, height: 36)
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Derived data

    private var kindLabel: String {
        ExtraKindLabels.label(for: entry.kind).uppercased()
    }

    private var thumbnailURL: URL? {
        guard case .remote(let video) = entry else { return nil }
        return TrailerRail.thumbnailURL(siteKey: video.siteKey)
    }

    /// Local extras are real files, so the scanner knows their runtime.
    /// Remote provider references carry no duration at all.
    private var durationLabel: String? {
        guard case .local(let extra) = entry,
              let seconds = extra.durationSeconds, seconds > 0
        else { return nil }
        return PlayerTimeFormatter.formatHMS(Double(seconds))
    }
}
#endif
