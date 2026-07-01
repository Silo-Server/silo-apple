#if os(tvOS)
import SwiftUI

/// Horizontal rail of episode cards for the tvOS series/season/episode
/// detail screens. Pressing Select on a card navigates to the episode
/// detail page where the user can pick a version, mark watched, and
/// start playback — the rail is a browsing surface, not a direct play
/// launcher.
///
/// Pass `currentContentId` to highlight the episode currently represented
/// by the surrounding detail experience. The rail will also scroll that
/// card to the horizontal center on first appearance and make it the
/// default focus target when the user d-pads down into the rail, so they
/// land on the episode represented by the page's primary action rather
/// than the first card in the season.
struct TVEpisodeRail: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    /// When non-nil, the matching card is visually highlighted, anchored
    /// at first appearance, and made the default focus target when focus
    /// first enters the rail.
    var currentContentId: String? = nil

    private let cardSpacing: CGFloat = 36
    @FocusState private var focusedCardId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(episodes) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            isCurrent: currentContentId == episode.contentId,
                            onSelect: { onSelect(episode.contentId) }
                        )
                        .id(episode.contentId)
                        .focused($focusedCardId, equals: episode.contentId)
                    }
                }
                .padding(.vertical, 32)
                .padding(.horizontal, ContinuumTheme.safePadding)
            }
            .focusSection()
            .scrollClipDisabled()
            .applyRailDefaultFocus(currentContentId, binding: $focusedCardId)
            .onAppear {
                guard let id = currentContentId else { return }
                // Run on next tick so the LazyHStack has instantiated the
                // target cell before we try to anchor on it.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private extension View {
    /// Routes d-pad-driven focus arriving at the rail to the card matching
    /// `currentContentId`. `prefersDefaultFocus` only fires for automatic
    /// focus evaluations (scope first appears, structural changes); d-pad
    /// entry is user-initiated and falls back to geometric proximity
    /// unless we explicitly mark it `userInitiated`.
    @ViewBuilder
    func applyRailDefaultFocus(
        _ currentContentId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let currentContentId {
            self.defaultFocus(binding, currentContentId, priority: .userInitiated)
        } else {
            self
        }
    }
}

struct TVEpisodeCard: View {
    let episode: EpisodeListItem
    var isCurrent: Bool = false
    let onSelect: () -> Void

    private let cardWidth: CGFloat = 460
    private let stillHeight: CGFloat = 260
    private let stillCornerRadius: CGFloat = 10

    var body: some View {
        Button(action: onSelect) {
            EpisodeCardLabel(
                episode: episode,
                isCurrent: isCurrent,
                cardWidth: cardWidth,
                stillHeight: stillHeight,
                stillCornerRadius: stillCornerRadius
            )
        }
        .buttonStyle(EpisodeCardStyle())
    }
}

private struct EpisodeCardLabel: View {
    let episode: EpisodeListItem
    let isCurrent: Bool
    let cardWidth: CGFloat
    let stillHeight: CGFloat
    let stillCornerRadius: CGFloat

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            still
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(episodeNumberLabel)
                        .font(.system(size: 18, weight: .bold))
                        .tracking(2.0)
                        .foregroundColor(.continuumOnSurface.opacity(0.55))
                    if isCurrent {
                        nowViewingTag
                    }
                }

                Text(episode.title ?? "Episode \(episode.episodeNumber)")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(titleColor)
                    // Allow up to two lines for long titles, but don't reserve
                    // the second line — a single-line title (the common case)
                    // was leaving a full empty line of dead space above the
                    // description.
                    .lineLimit(2)

                if let metadataLine = episodeMetadataLine {
                    Text(metadataLine)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }

                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(3, reservesSpace: true)
                        .lineSpacing(3)
                        .padding(.top, 4)
                }
            }
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var titleColor: Color {
        if isCurrent { return .continuumOnSurface }
        return isFocused ? .continuumOnSurface : Color.continuumOnSurface.opacity(0.92)
    }

    private var nowViewingTag: some View {
        Text("NOW VIEWING")
            .font(.system(size: 14, weight: .heavy))
            .tracking(1.6)
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white))
    }

    private var episodeNumberLabel: String {
        "EPISODE \(episode.episodeNumber)"
    }

    private var episodeMetadataLine: String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(formatRuntime(runtime))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            Color.continuumSurfaceElevated
                .frame(width: cardWidth, height: stillHeight)

            if let url = episode.stillUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: cardWidth, height: stillHeight),
                    contentMode: .fill
                )
                .frame(width: cardWidth, height: stillHeight)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundColor(.continuumSecondaryText)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if episode.userData?.played == true {
                Color.black.opacity(0.35)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if episode.userData?.played == true {
                VStack {
                    HStack {
                        Spacer()
                        watchedBadge.padding(12)
                    }
                    Spacer()
                }
                .frame(width: cardWidth, height: stillHeight)
            }

            if let progress = progressFraction {
                progressBar(fraction: progress)
            }
        }
        .frame(width: cardWidth, height: stillHeight)
        .clipShape(RoundedRectangle(cornerRadius: stillCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: stillCornerRadius)
                .stroke(borderColor, lineWidth: borderWidth)
        )
    }

    private var borderColor: Color {
        if isFocused { return Color.white.opacity(0.9) }
        if isCurrent { return Color.white.opacity(0.7) }
        return .clear
    }

    private var borderWidth: CGFloat {
        if isFocused { return 3 }
        if isCurrent { return 2 }
        return 0
    }

    private var watchedBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.3), radius: 3)
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.black)
        }
    }

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(height: 5)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(fraction), height: 5)
            }
        }
        .frame(height: 5)
    }

    private var progressFraction: Double? {
        guard let userData = episode.userData,
              let pos = userData.positionSeconds,
              let dur = userData.durationSeconds,
              dur > 0, pos > 0, pos < dur
        else { return nil }
        return pos / dur
    }

    private func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

/// Custom style so the system doesn't paint its default focus halo over
/// the card. Scale + drop shadow only; the white overlay ring on the
/// still (driven by `isFocused` in the label) is the focus cue.
private struct EpisodeCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EpisodeCardStyleBody(configuration: configuration)
    }
}

private struct EpisodeCardStyleBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(isFocused ? 0.45 : 0.3),
                radius: isFocused ? 18 : 8,
                y: isFocused ? 8 : 4
            )
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused ? 1.04 : 1.0
        return configuration.isPressed ? base * 0.97 : base
    }
}
#endif
