#if !os(tvOS)
import SwiftUI

/// Horizontal rail of episode cards used on the phone series and
/// season detail pages, plus the episode page (where it shows the
/// other episodes in the same season). Tapping a card navigates to
/// that episode's detail page.
struct PhoneEpisodeRail: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    var onPlay: ((String) -> Void)? = nil
    var currentContentId: String? = nil
    var selectsCenteredEpisode = false
    var captionStyleOverride: CardCaptionStyle? = nil

    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var visibleEpisodeId: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardWidth: CGFloat {
        240 * uiCustomization.cardPresentation.posterSize.scale
    }
    private var stillHeight: CGFloat { cardWidth * 9 / 16 }
    private let cardSpacing: CGFloat = 14
    private let stillCornerRadius: CGFloat = 8

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(episodes) { episode in
                    PhoneEpisodeCard(
                        episode: episode,
                        isCurrent: currentContentId == episode.contentId,
                        cardWidth: cardWidth,
                        stillHeight: stillHeight,
                        stillCornerRadius: stillCornerRadius,
                        captionStyle: captionStyleOverride ?? uiCustomization.cardPresentation.caption,
                        onSelect: { onSelect(episode.contentId) },
                        onPlay: onPlay.map { play in
                            { play(episode.contentId) }
                        }
                    )
                    .id(episode.contentId)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $visibleEpisodeId, anchor: .center)
        .onAppear {
            visibleEpisodeId = currentContentId ?? episodes.first?.contentId
        }
        .onChange(of: episodes.map(\.contentId)) { _, newIds in
            guard !newIds.isEmpty, !newIds.contains(visibleEpisodeId ?? "") else { return }
            // A season replacement invalidates the previous rail id. Seed the
            // new rail synchronously instead of animating a scroll from an id
            // that no longer exists.
            if let currentContentId, newIds.contains(currentContentId) {
                visibleEpisodeId = currentContentId
            } else {
                visibleEpisodeId = newIds.first
            }
        }
        .onChange(of: currentContentId) { _, newId in
            guard let newId, visibleEpisodeId != newId else { return }
            if reduceMotion {
                visibleEpisodeId = newId
            } else {
                withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                    visibleEpisodeId = newId
                }
            }
        }
        .onScrollPhaseChange { _, newPhase in
            guard selectsCenteredEpisode,
                  newPhase == .idle,
                  let visibleEpisodeId,
                  visibleEpisodeId != currentContentId else { return }
            // Native scroll settling has already animated the card into place.
            // A second enclosing animation makes every dependent view animate
            // its layout and is the source of the apparent vertical judder.
            onSelect(visibleEpisodeId)
        }
    }
}

private struct PhoneEpisodeCard: View {
    let episode: EpisodeListItem
    let isCurrent: Bool
    let cardWidth: CGFloat
    let stillHeight: CGFloat
    let stillCornerRadius: CGFloat
    let captionStyle: CardCaptionStyle
    let onSelect: () -> Void
    let onPlay: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)

            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.94)))
                }
                .buttonStyle(.plain)
                .padding(.top, (stillHeight - 42) / 2)
                .accessibilityLabel(
                    "Play Season \(episode.seasonNumber), Episode \(episode.episodeNumber)"
                )
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            still
            if captionStyle.showsTitle {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(PhoneEpisodeFormatting.cardNumberLabel(for: episode))
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.0)
                            .foregroundStyle(Color.continuumOnSurface.opacity(0.55))
                        if isCurrent {
                            nowViewingTag
                        }
                    }

                    Text(PhoneEpisodeFormatting.title(for: episode))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    if captionStyle.showsMetadata {
                        if let metadataLine = PhoneEpisodeFormatting.metadataLine(for: episode) {
                            Text(metadataLine)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.continuumSecondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.leading)
                        }

                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color.continuumSecondaryText)
                                .lineLimit(3, reservesSpace: true)
                                .lineSpacing(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
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

    private var accessibilityDescription: String {
        PhoneEpisodeFormatting.accessibilityDescription(for: episode, isCurrent: isCurrent)
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(
                url: episode.stillUrl ?? "",
                thumbhash: episode.stillThumbhash,
                targetSize: CGSize(width: cardWidth, height: stillHeight),
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
        .animation(.easeOut(duration: 0.18), value: isCurrent)
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
        PhoneEpisodeFormatting.progressFraction(for: episode)
    }
}
#endif
