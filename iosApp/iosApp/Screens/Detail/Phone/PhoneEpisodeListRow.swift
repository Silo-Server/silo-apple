#if !os(tvOS)
import SwiftUI

/// One regular-width episode row. The entire row keeps the existing Apple
/// behavior—opening episode detail—while exposing enough title, date,
/// runtime, progress, and overview context to make that choice useful.
struct PhoneEpisodeListRow: View {
    let episode: EpisodeListItem
    let isCurrent: Bool
    let onSelect: () -> Void
    let onPlay: (() -> Void)?

    private let thumbnailWidth: CGFloat = 168
    private var thumbnailHeight: CGFloat { thumbnailWidth * 9 / 16 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 14) {
                    thumbnail
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                PhoneEpisodeFormatting.accessibilityDescription(
                    for: episode,
                    isCurrent: isCurrent
                )
            )

            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.94), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(
                    x: (thumbnailWidth - 38) / 2,
                    y: (thumbnailHeight - 38) / 2
                )
                .accessibilityLabel(
                    "Play Season \(episode.seasonNumber), Episode \(episode.episodeNumber)"
                )
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(
                url: episode.stillUrl ?? "",
                thumbhash: episode.stillThumbhash,
                targetSize: CGSize(width: thumbnailWidth, height: thumbnailHeight),
                contentMode: .fill
            )
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipped()
            .accessibilityHidden(true)

            if episode.userData?.played == true {
                Color.black.opacity(0.3)
            }

            if isCurrent {
                Text("NOW VIEWING")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.white, in: Capsule())
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if episode.userData?.played == true {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 21, height: 21)
                    .background(.white, in: Circle())
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let progress = PhoneEpisodeFormatting.progressFraction(for: episode) {
                progressBar(fraction: progress)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius)
                .stroke(isCurrent ? Color.white.opacity(0.8) : .clear, lineWidth: 2)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(PhoneEpisodeFormatting.compactNumberLabel(for: episode))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if let metadataLine = PhoneEpisodeFormatting.metadataLine(for: episode) {
                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Text(PhoneEpisodeFormatting.title(for: episode))
                .font(.headline)
                .foregroundStyle(Color.continuumOnSurface)
                .lineLimit(1)

            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.6))
                Rectangle()
                    .fill(.white)
                    .frame(width: proxy.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 3)
    }
}
#endif
