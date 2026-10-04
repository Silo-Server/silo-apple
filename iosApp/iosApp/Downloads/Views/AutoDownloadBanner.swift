#if !os(tvOS)
import SwiftUI

/// The series page's one-line answer to "am I getting the next episode?",
/// shown while the series is auto-downloaded. Tapping it opens the options.
struct AutoDownloadBanner: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]

    @State private var showOptions = false
    private var manager: DownloadManager { DownloadManager.shared }
    private var schedule: AutoDownloadSchedule { AutoDownloadSchedule.shared }

    var body: some View {
        if manager.canMonitorSeries, let subscription = manager.subscription(forSeriesId: seriesId) {
            let status = schedule.status(for: subscription)
            Button {
                showOptions = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: AutoDownloadStatusStyle.icon(for: status))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.siloOnSurface)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AutoDownloadRules.headline(status))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.siloOnSurface)
                            .lineLimit(1)
                        Text(AutoDownloadRules.ruleSummary(for: subscription))
                            .font(.footnote)
                            .foregroundColor(.siloSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.siloSecondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Monitoring. \(AutoDownloadRules.headline(status)). \(AutoDownloadRules.ruleSummary(for: subscription))")
            .accessibilityHint("Shows monitoring options")
            .task(id: seriesId) { await schedule.refresh() }
            .sheet(isPresented: $showOptions) {
                SeriesDownloadSheet(seriesId: seriesId, seriesTitle: seriesTitle, seasons: seasons, startsOnMonitor: true)
            }
        }
    }
}
#endif
