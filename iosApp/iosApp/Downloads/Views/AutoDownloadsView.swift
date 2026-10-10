#if !os(tvOS)
import SwiftUI

/// Every series this device auto-downloads: what each one downloads and
/// what it does next. Tapping a series opens its options.
struct AutoDownloadsView: View {
    @Environment(AppRouter.self) private var router
    private var manager: DownloadManager { DownloadManager.shared }
    private var schedule: AutoDownloadSchedule { AutoDownloadSchedule.shared }

    @State private var editing: DownloadSubscription?

    /// Active series first, each group by title.
    private var subscriptions: [DownloadSubscription] {
        manager.subscriptions.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            return title(for: lhs).localizedStandardCompare(title(for: rhs)) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if manager.subscriptions.isEmpty {
                EmptyStateView(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "No Monitored Series",
                    subtitle: "Open a series, tap Download, and choose Monitor to get new episodes on this \(SeriesDownloadSheet.deviceName) automatically."
                )
            } else {
                list
            }
        }
        .background(Color.siloBackground.ignoresSafeArea())
        .navigationTitle("Monitored")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await schedule.refresh() }
        .sheet(item: $editing) { subscription in
            SeriesDownloadSheet(seriesId: subscription.seriesId, seriesTitle: title(for: subscription), startsOnMonitor: true)
        }
        .siloToolbarColorSchemeDark()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let rows = subscriptions
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, subscription in
                    Button {
                        editing = subscription
                    } label: {
                        AutoDownloadRow(
                            title: title(for: subscription),
                            info: schedule.info(forSeriesId: subscription.seriesId),
                            rule: AutoDownloadRules.ruleSummary(for: subscription),
                            status: schedule.status(for: subscription)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .downloadGroupSlice(DownloadGroupPosition(index: index, count: rows.count), separatorInset: 77)
                    .contextMenu {
                        Button {
                            router.navigate(to: .itemDetail(contentId: subscription.seriesId))
                        } label: {
                            Label("Go to Series", systemImage: "tv")
                        }
                        Button {
                            editing = subscription
                        } label: {
                            Label("Options", systemImage: "slider.horizontal.3")
                        }
                    }
                    .downloadGroupInset()
                }

                Text("New episodes download after they air\(DownloadSettings.shared.wifiOnly ? ", over Wi-Fi" : ""). To add a series, tap Download on it and choose Monitor.")
                    .font(.footnote)
                    .foregroundColor(.siloSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            }
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .refreshable {
            await manager.runMonitoringAndProgressSync()
            await schedule.refresh(force: true)
        }
    }

    private func title(for subscription: DownloadSubscription) -> String {
        schedule.info(forSeriesId: subscription.seriesId)?.title ?? subscription.seriesTitle ?? "Series"
    }
}

/// One auto-downloaded series: poster, title, what it downloads, and what
/// happens next.
struct AutoDownloadRow: View {
    let title: String
    let info: AutoDownloadSchedule.SeriesInfo?
    let rule: String
    let status: AutoDownloadStatus

    var body: some View {
        HStack(spacing: 13) {
            poster
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Text(rule)
                    .font(.subheadline)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
                Label {
                    Text(AutoDownloadRules.statusLine(status))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: AutoDownloadStatusStyle.icon(for: status))
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(AutoDownloadStatusStyle.color(for: status))
                .padding(.top, 4)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.siloSecondaryText.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(status == .paused ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let url = info?.posterUrl {
                AsyncImageView(
                    url: url,
                    thumbhash: info?.posterThumbhash,
                    targetSize: CGSize(width: 48, height: 72),
                    contentMode: .fill
                )
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: 48, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The Downloads tab's way into the Auto-Downloads list.
struct AutoDownloadsEntryRow: View {
    let count: Int
    let nextEpisodeDay: String?
    let action: () -> Void

    private var subtitle: String {
        guard count > 0 else { return "Keep new episodes coming automatically" }
        let series = "\(count) series"
        guard let nextEpisodeDay else { return series }
        return "\(series) · next episode \(nextEpisodeDay)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.siloOnSurface)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.siloIconTile))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monitored")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.siloSecondaryText.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Icon and tint for an auto-download status line.
enum AutoDownloadStatusStyle {
    static func icon(for status: AutoDownloadStatus) -> String {
        switch status {
        case .paused: return "pause.fill"
        case .storageLimit: return "exclamationmark.triangle"
        case .downloading: return "arrow.down.circle"
        case .waiting(_, let phase):
            switch phase {
            case .waitingForWiFi: return "wifi"
            case .waitingForConnection: return "wifi.slash"
            default: return "hourglass"
            }
        case .next: return "clock"
        case .upToDate: return "checkmark"
        case .monitoring: return "dot.radiowaves.left.and.right"
        }
    }

    static func color(for status: AutoDownloadStatus) -> Color {
        switch status {
        case .storageLimit: return .siloWarning
        case .downloading: return .siloBrandOrange
        case .next: return .siloOnSurface
        default: return .siloSecondaryText
        }
    }
}
#endif
