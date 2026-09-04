#if !os(tvOS)
import SwiftUI

/// Regular-width season pager. Chip taps and settled page swipes share one
/// selection, and previously loaded pages render from the view model cache.
struct PhoneSeasonEpisodePager: View {
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    let isLoadingEpisodes: Bool
    let onSelectSeason: (Season) -> Void
    let onSelectEpisode: (String) -> Void
    var onPlayEpisode: ((String) -> Void)? = nil
    var currentContentId: String? = nil
    var selectsCenteredEpisode = false
    var showsSeasonSelector = true
    let availableWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var estimatedRowHeight: CGFloat = 96
    @State private var visibleSeasonId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSeasonSelector {
                PhoneSeasonChips(
                    seasons: seasons,
                    selected: selectedSeason,
                    onSelect: onSelectSeason
                )
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(seasons) { season in
                        PhoneEpisodePage(
                            episodes: episodes(for: season),
                            isLoading: isLoading(season),
                            usesExpandedList: true,
                            onSelect: onSelectEpisode,
                            onPlay: onPlayEpisode,
                            currentContentId: currentContentId,
                            selectsCenteredEpisode: selectsCenteredEpisode
                        )
                        // A horizontal ScrollView otherwise proposes only a
                        // single-row height to this page when it is nested in
                        // the detail screen's vertical ScrollView.
                        .fixedSize(horizontal: false, vertical: true)
                        .containerRelativeFrame(.horizontal)
                        .id(season.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleSeasonId)
            .frame(height: visiblePageHeight)
            // NavigationSplitView does not reliably mask horizontally
            // translated SwiftUI scroll content to the detail column during
            // paging and rubber-banding. Keep adjacent season pages from
            // appearing beneath the iPad sidebar.
            .scrollClipDisabled(false)
            .clipped()
            .onAppear {
                visibleSeasonId = selectedSeason?.id ?? seasons.first?.id
            }
            .onChange(of: selectedSeason?.id) { _, newId in
                guard let newId, visibleSeasonId != newId else { return }
                if reduceMotion {
                    visibleSeasonId = newId
                } else {
                    withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                        visibleSeasonId = newId
                    }
                }
            }
            .onScrollPhaseChange { _, newPhase in
                guard newPhase == .idle else { return }
                selectVisibleSeasonIfNeeded()
            }
        }
    }

    private func episodes(for season: Season) -> [EpisodeListItem] {
        if let cached = episodesBySeason[season.seasonNumber] {
            return cached
        }
        if selectedSeason?.id == season.id {
            return episodes
        }
        return []
    }

    private func isLoading(_ season: Season) -> Bool {
        if selectedSeason?.id == season.id {
            return isLoadingEpisodes
        }
        return episodesBySeason[season.seasonNumber] == nil
    }

    private var visiblePageHeight: CGFloat {
        guard let season = visibleSeason else { return 72 }
        return PhoneEpisodeListLayout.estimatedHeight(
            episodeCount: episodeCount(for: season),
            availableWidth: availableWidth,
            rowHeight: estimatedRowHeight
        )
    }

    private var visibleSeason: Season? {
        if let visibleSeasonId,
           let season = seasons.first(where: { $0.id == visibleSeasonId }) {
            return season
        }
        return selectedSeason ?? seasons.first
    }

    private func episodeCount(for season: Season) -> Int {
        if let cached = episodesBySeason[season.seasonNumber] {
            return cached.count
        }
        if selectedSeason?.id == season.id, !episodes.isEmpty {
            return episodes.count
        }
        return season.episodeCount
    }

    private func selectVisibleSeasonIfNeeded() {
        guard let visibleSeasonId,
              visibleSeasonId != selectedSeason?.id,
              let season = seasons.first(where: { $0.id == visibleSeasonId })
        else { return }
        onSelectSeason(season)
    }
}
#endif
