#if !os(tvOS)
import SwiftUI

/// Horizontal rail of episode cards used on the phone series and
/// season detail pages, plus the episode page (where it shows the
/// other episodes in the same season). Tapping a card navigates to
/// that episode's detail page.
struct PhoneEpisodeRail: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    var currentContentId: String? = nil
    /// Enables the per-card compact download control; `nil` (rails without a
    /// series scope) hides it. Capability gating happens per card so this
    /// stays a plain pass-through.
    var downloadContext: EpisodeDownloadContext? = nil

    private let cardWidth: CGFloat = 240
    private let stillHeight: CGFloat = 135   // 16:9 of 240
    private let cardSpacing: CGFloat = 14
    private let stillCornerRadius: CGFloat = 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(episodes) { episode in
                        PhoneEpisodeCard(
                            episode: episode,
                            isCurrent: currentContentId == episode.contentId,
                            cardWidth: cardWidth,
                            stillHeight: stillHeight,
                            stillCornerRadius: stillCornerRadius,
                            downloadContext: downloadContext,
                            onSelect: { onSelect(episode.contentId) }
                        )
                        .id(episode.contentId)
                    }
                }
                .padding(.horizontal, ContinuumTheme.safePadding)
                .padding(.vertical, 4)
            }
            .onAppear {
                guard let id = currentContentId else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct PhoneEpisodeCard: View {
    let episode: EpisodeListItem
    let isCurrent: Bool
    let cardWidth: CGFloat
    let stillHeight: CGFloat
    let stillCornerRadius: CGFloat
    let downloadContext: EpisodeDownloadContext?
    let onSelect: () -> Void

    private let downloadControlInset: CGFloat = 6

    var body: some View {
        cardButton
            // Sibling overlay rather than a control nested inside the card
            // button's label, so the menu / confirmation dialogs get their
            // own hit target instead of competing with the card tap.
            .overlay(alignment: .topTrailing) { downloadControl }
    }

    /// Compact one-tap download control pinned to the still's bottom-trailing
    /// corner (top-trailing hosts the watched check). Reads the same
    /// capability gate as every other download affordance.
    @ViewBuilder
    private var downloadControl: some View {
        if let downloadContext, DownloadManager.shared.downloadsEnabled {
            DownloadActionButton(episode: episode, context: downloadContext)
                .padding(.top, stillHeight - DownloadActionButton.compactDiameter - downloadControlInset)
                .padding(.trailing, downloadControlInset)
        }
    }

    private var cardButton: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                still
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(episodeNumberLabel)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.continuumOnSurface.opacity(0.55))
                        if isCurrent {
                            nowViewingTag
                        }
                    }

                    Text(episode.title ?? "Episode \(episode.episodeNumber)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(titleColor)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)

                    if let metadataLine = episodeMetadataLine {
                        Text(metadataLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.continuumSecondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)
                    }

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.continuumSecondaryText)
                            .lineLimit(3, reservesSpace: true)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var titleColor: Color {
        isCurrent ? .continuumOnSurface : Color.continuumOnSurface.opacity(0.92)
    }

    private var nowViewingTag: some View {
        Text("NOW VIEWING")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundColor(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
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
            AsyncImageView(
                url: episode.stillUrl ?? "",
                thumbhash: episode.stillThumbhash,
                contentMode: .fill
            )
            .frame(width: cardWidth, height: stillHeight)
            .clipped()

            if episode.userData?.played == true {
                Color.black.opacity(0.32)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if episode.userData?.played == true {
                VStack {
                    HStack {
                        Spacer()
                        watchedBadge.padding(8)
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
        isCurrent ? Color.white.opacity(0.7) : .clear
    }

    private var borderWidth: CGFloat {
        isCurrent ? 2 : 0
    }

    private var watchedBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.3), radius: 2)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
        }
    }

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(height: 3)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(fraction), height: 3)
            }
        }
        .frame(height: 3)
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
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
#endif
