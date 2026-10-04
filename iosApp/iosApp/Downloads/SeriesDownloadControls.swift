#if !os(tvOS)
import SwiftUI

/// The series action row's Download control. It opens
/// `SeriesDownloadSheet`, which downloads once or monitors the series.
/// Reads `DownloadManager.shared` directly so it reflects live state.
struct SeriesDownloadButton: View {
    let detail: ItemDetail
    let seasons: [Season]
    let selectedSeason: Season?
    /// The highlighted episode and the version its selector shows.
    let episode: EpisodeListItem?
    let episodeFileId: Int?

    private var manager: DownloadManager { DownloadManager.shared }
    @State private var showOptions = false

    private var seriesId: String { detail.seriesId ?? detail.contentId }
    private var isMonitored: Bool { manager.subscription(forSeriesId: seriesId)?.active == true }

    /// Filled, borderless circle over a caption, matching
    /// `PhoneLabeledAction`'s metrics.
    var body: some View {
        Button {
            showOptions = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isMonitored ? "arrow.down.circle.fill" : "arrow.down.to.line")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(Color.siloOnSurface)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(isMonitored ? 0.18 : 0.10)))
                Text("Download")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.siloOnSurface.opacity(isMonitored ? 0.92 : 0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download")
        .accessibilityValue(isMonitored ? "Monitoring" : "")
        .sheet(isPresented: $showOptions) {
            SeriesDownloadSheet(
                seriesId: seriesId,
                seriesTitle: detail.title,
                seasons: seasons,
                selectedSeason: selectedSeason,
                episode: episode,
                episodeFileId: episodeFileId,
                posterThumbhash: detail.posterThumbhash
            )
        }
    }
}
#endif
