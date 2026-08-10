#if !os(tvOS)
import SwiftUI

/// Loading, empty, compact-rail, and expanded-list states for one season.
struct PhoneEpisodePage: View {
    let episodes: [EpisodeListItem]
    let isLoading: Bool
    let usesExpandedList: Bool
    let onSelect: (String) -> Void
    var currentContentId: String? = nil

    var body: some View {
        Group {
            if isLoading, episodes.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.continuumOnSurface)
                        .padding(32)
                    Spacer()
                }
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ContinuumTheme.safePadding)
                    .padding(.vertical, 12)
            } else if usesExpandedList {
                PhoneEpisodeList(
                    episodes: episodes,
                    onSelect: onSelect,
                    currentContentId: currentContentId
                )
            } else {
                PhoneEpisodeRail(
                    episodes: episodes,
                    onSelect: onSelect,
                    currentContentId: currentContentId
                )
            }
        }
    }
}
#endif
