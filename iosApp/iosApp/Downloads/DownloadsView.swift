#if !os(tvOS)
import SwiftUI

/// The Downloads tab — a storage-forward "Manager": a storage hero, a
/// one-tap "reclaim watched" suggestion, in-progress transfers, and a
/// size-sortable list where each series collapses to one expandable card.
/// Reads `DownloadManager.shared` directly and drives offline playback
/// through the router.
struct DownloadsView: View {
    @Environment(AppRouter.self) private var router
    @Bindable private var settings = DownloadSettings.shared
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showReclaim = false

    var body: some View {
        Group {
            if !manager.downloadsEnabled {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "Downloads Unavailable",
                    subtitle: "Downloads aren't enabled for this profile."
                )
            } else if manager.records.isEmpty && manager.subscriptions.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "No Downloads",
                    subtitle: "Downloaded movies and episodes appear here for offline viewing."
                )
            } else {
                content
            }
        }
        .navigationTitle(isSelecting ? "\(selection.count) Selected" : "Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showReclaim) { DownloadReclaimSheet() }
        .continuumToolbarColorSchemeDark()
    }

    // MARK: - Content

    private var listItems: [DownloadListItem] {
        manager.downloadListItems(sortedBy: settings.sortOption)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                DownloadsStorageHeader(used: manager.totalBytesUsed, breakdown: manager.storageBreakdown)
                    .padding(.top, 6)

                if showReclaimBanner {
                    DownloadReclaimBanner(
                        episodeCount: manager.reclaimableRecords.count,
                        bytes: manager.reclaimableBytes
                    ) { showReclaim = true }
                }

                if !manager.activeRecords.isEmpty {
                    sectionLabel("In Progress", count: manager.activeRecords.count)
                    ForEach(manager.activeRecords) { record in
                        DownloadActiveRow(record: record) { manager.deleteDownload(id: record.id) }
                    }
                }

                let failed = manager.records.filter { $0.localStatus == .failed }
                if !failed.isEmpty {
                    sectionLabel("Needs Attention", count: failed.count)
                    ForEach(failed) { record in
                        DownloadAttentionRow(
                            record: record,
                            onRetry: { manager.retryDownload(id: record.id) },
                            onDelete: { manager.deleteDownload(id: record.id) }
                        )
                    }
                }

                DownloadSortControl(option: $settings.sortOption, itemCount: listItems.count)

                ForEach(listItems) { item in
                    row(for: item)
                }

                monitoredOnlySection

                Color.clear.frame(height: 24)
            }
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: isSelecting)
        }
        .background(Color.continuumBackground)
    }

    @ViewBuilder
    private func row(for item: DownloadListItem) -> some View {
        switch item {
        case .series(let group):
            DownloadSeriesRow(
                group: group,
                selecting: isSelecting,
                selected: selection.contains(item.id),
                isWatched: { manager.isWatched($0) },
                onSelectToggle: { toggle(item.id) },
                onOpenSeries: isSelecting ? nil : { router.navigate(to: .offlineSeriesBrowse(seriesId: group.seriesId)) },
                onPlayEpisode: { play($0) },
                onDeleteEpisode: { manager.deleteDownload(id: $0.id) }
            )
            .contextMenu {
                if !isSelecting {
                    Button(role: .destructive) {
                        manager.deleteDownloads(ids: group.allRecords.map(\.id))
                    } label: {
                        Label("Delete All Episodes", systemImage: "trash")
                    }
                }
            }
        case .movie(let record):
            DownloadMovieRow(
                record: record,
                watched: manager.isWatched(record),
                selecting: isSelecting,
                selected: selection.contains(item.id),
                onTap: {
                    if isSelecting { toggle(item.id) }
                    else { router.navigate(to: .offlineDownloadDetail(downloadId: record.id)) }
                }
            )
            .contextMenu {
                if !isSelecting {
                    Button(role: .destructive) {
                        manager.deleteDownload(id: record.id)
                    } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Monitored series that have no on-device episodes yet, so an active
    /// subscription is still visible (and stoppable) before its first download.
    @ViewBuilder
    private var monitoredOnlySection: some View {
        let groupedSeriesIds = Set(manager.seriesGroups.map(\.seriesId))
        let pending = manager.subscriptions.filter { !groupedSeriesIds.contains($0.seriesId) }
        if !pending.isEmpty {
            sectionLabel("Monitoring", count: pending.count)
            ForEach(pending) { subscription in
                monitoredRow(subscription)
            }
        }
    }

    private func monitoredRow(_ subscription: DownloadSubscription) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 17))
                .foregroundColor(.continuumOnSurface)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.seriesTitle ?? subscription.seriesId)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
                    .lineLimit(1)
                Text(SubscriptionMode(rawValue: subscription.mode)?.displayName ?? subscription.mode)
                    .font(.system(size: 12))
                    .foregroundColor(.continuumSecondaryText)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.continuumSurfaceVariant)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.continuumOutline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .contextMenu {
            Button(role: .destructive) {
                Task { await manager.deleteSubscription(id: subscription.id) }
            } label: {
                Label("Stop Monitoring", systemImage: "xmark.circle")
            }
        }
    }

    private func sectionLabel(_ text: String, count: Int) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.3)
                .foregroundColor(.continuumSecondaryText)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12.5))
                .foregroundColor(.continuumOnSurface.opacity(0.38))
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    // MARK: - Toolbar & select mode

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .navigation) {
                Button(allSelected ? "Clear" : "Select All") { toggleSelectAll() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { exitSelectMode() }
            }
        } else if !listItems.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Select") { isSelecting = true }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isSelecting && !selection.isEmpty {
            Button {
                manager.deleteDownloads(ids: selectedDownloadIds)
                exitSelectMode()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "trash")
                    Text("Delete \(selection.count) · Free \(DownloadFormatting.bytes(selectedBytes))")
                        .fontWeight(.bold)
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.continuumOnSurface)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
        }
    }

    private var showReclaimBanner: Bool {
        !isSelecting && !settings.keepWatchedDownloads && manager.reclaimableBytes > 0
    }

    private var allSelected: Bool {
        !listItems.isEmpty && Set(listItems.map(\.id)).isSubset(of: selection)
    }

    private var selectedItems: [DownloadListItem] {
        listItems.filter { selection.contains($0.id) }
    }

    private var selectedDownloadIds: [String] {
        selectedItems.flatMap(\.downloadIds)
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.totalBytes }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleSelectAll() {
        if allSelected { selection.removeAll() }
        else { selection = Set(listItems.map(\.id)) }
    }

    private func exitSelectMode() {
        isSelecting = false
        selection.removeAll()
    }

    // MARK: - Playback

    private func play(_ record: DownloadRecord) {
        guard record.isPlayableOffline else { return }
        let leafId = record.leafMediaItemId
        router.presentOfflinePlayer(
            downloadId: record.id,
            contentId: leafId,
            resumePosition: manager.localProgress(forMediaItemId: leafId)?.position
        )
    }
}

// MARK: - Formatting

enum DownloadFormatting {
    static func bytes(_ count: Int64) -> String {
        guard count > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
#endif
