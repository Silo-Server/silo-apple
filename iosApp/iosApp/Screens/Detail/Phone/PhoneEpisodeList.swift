#if !os(tvOS)
import SwiftUI

enum PhoneEpisodeListLayout {
    static let columnBreakpoint: CGFloat = 900
    static let rowSpacing: CGFloat = 16
    static let verticalPadding: CGFloat = 8

    static func columnCount(for availableWidth: CGFloat) -> Int {
        availableWidth >= columnBreakpoint ? 2 : 1
    }

    static func estimatedHeight(
        episodeCount: Int,
        availableWidth: CGFloat,
        rowHeight: CGFloat
    ) -> CGFloat {
        guard episodeCount > 0 else { return 72 }
        let columns = columnCount(for: availableWidth)
        let rows = Int(ceil(Double(episodeCount) / Double(columns)))
        return CGFloat(rows) * rowHeight
            + CGFloat(max(0, rows - 1)) * rowSpacing
            + verticalPadding
    }
}

/// Expanded episode presentation for regular-width detail containers.
/// Portrait uses one readable row per episode; wider landscape panes use two
/// columns so the browser gains density without shrinking the copy.
struct PhoneEpisodeList: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    var onPlay: ((String) -> Void)? = nil
    var currentContentId: String? = nil

    @State private var availableWidth: CGFloat = 0

    private var columnCount: Int {
        PhoneEpisodeListLayout.columnCount(for: availableWidth)
    }

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: episodes.count, by: columnCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneEpisodeListLayout.rowSpacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        let episodeIndex = rowStart + column
                        if episodes.indices.contains(episodeIndex) {
                            episodeRow(episodes[episodeIndex])
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, ContinuumTheme.safePadding)
        .padding(.vertical, 4)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - availableWidth) > 1 else { return }
            availableWidth = width
        }
    }

    private func episodeRow(_ episode: EpisodeListItem) -> some View {
        PhoneEpisodeListRow(
            episode: episode,
            isCurrent: currentContentId == episode.contentId,
            onSelect: { onSelect(episode.contentId) },
            onPlay: onPlay.map { play in
                { play(episode.contentId) }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
