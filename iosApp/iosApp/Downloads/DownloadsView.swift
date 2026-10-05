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
    /// Selected in-progress downloads, by record id; `selection` holds the
    /// finished list's items.
    @State private var activeSelection: Set<String> = []
    @State private var showReclaim = false
    /// Confirmation gate for the bulk/context-menu deletes — downloads are
    /// costly to re-fetch, so a stray tap must not remove them outright.
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion {
        /// Finished downloads.
        let ids: [String]
        /// Downloads in progress, cancelled only if they still are when the
        /// user confirms.
        var activeIds: [String] = []
        let endsSelection: Bool
        /// Every id is a download still in progress.
        var inProgressOnly = false

        var count: Int { ids.count + activeIds.count }
    }

    var body: some View {
        Group {
            if !manager.downloadsEnabled {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "Downloads Unavailable",
                    subtitle: "Downloads aren't enabled for this profile."
                )
            } else if !manager.hasRecords && manager.subscriptions.isEmpty {
                noDownloadsState
            } else {
                content
            }
        }
        #if os(macOS)
        .siloPageBackground()
        #else
        .background(Color.siloBackground.ignoresSafeArea())
        #endif
        .navigationTitle(isSelecting ? "\(selectedCount) Selected" : "Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showReclaim) { DownloadReclaimSheet() }
        .task { await AutoDownloadSchedule.shared.refresh() }
        // An alert, not a confirmation dialog: on iPhone the dialog anchors
        // to this whole page and appears at its top, far from the row or
        // bottom bar that asked for it.
        .alert(
            pendingDeletion?.inProgressOnly == true ? "Cancel downloads?" : "Delete downloaded files?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { pending in
            let verb = pending.inProgressOnly ? "Cancel" : "Delete"
            Button(
                pending.count == 1 ? "\(verb) Download" : "\(verb) \(pending.count) Downloads",
                role: .destructive
            ) {
                // One that finished while the dialog was open keeps its file.
                let stillActive = manager.activeRecordIds
                manager.deleteDownloads(ids: pending.ids + pending.activeIds.filter(stillActive.contains))
                if pending.endsSelection { exitSelectMode() }
            }
            Button("Keep", role: .cancel) {}
        }
        .siloToolbarColorSchemeDark()
    }

    // MARK: - Content

    private var listItems: [DownloadListItem] {
        manager.downloadListItems(sortedBy: settings.sortOption)
    }

    /// Mirrors `EmptyStateView` but adds a route into content: an empty
    /// Downloads tab is most often a brand-new user, so hand them the
    /// browse entry point rather than a dead end.
    /// Points to monitoring too, since its list is reached from here only
    /// once something is downloaded or monitored.
    private var noDownloadsHint: String {
        let base = "Downloaded movies and episodes appear here for offline viewing."
        guard manager.canMonitorSeries else { return base }
        return base + " To get new episodes automatically, open a series, tap Download, and choose Monitor."
    }

    private var noDownloadsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundColor(.siloOnSurface.opacity(0.3))
            Text("No Downloads")
                .font(.siloSubheadline)
                .foregroundColor(.siloOnSurface)
            Text(noDownloadsHint)
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SiloTheme.largePadding)
            Button {
                router.switchTab(to: .libraries)
            } label: {
                Text("Browse Libraries")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Color.siloChromeSelectedFill)
                            .overlay(Capsule().stroke(Color.siloChromeSelectedBorder, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        // Each manager accessor walks every record, and this body re-runs on
        // every progress publish, so read each list once.
        let inProgress = manager.inProgressRecords
        let failed = manager.failedRecords
        let items = listItems
        return ScrollView {
            LazyVStack(spacing: 0) {
                DownloadsStorageHeader(
                    used: manager.totalBytesUsed,
                    breakdown: manager.storageBreakdown,
                    activeCount: inProgress.count
                )
                .downloadGroupedRow(showReclaimBanner ? .first : .only)
                .padding(.top, 6)

                if showReclaimBanner {
                    DownloadReclaimBanner(
                        episodeCount: manager.reclaimableRecords.count,
                        bytes: manager.reclaimableBytes
                    ) { showReclaim = true }
                    .downloadGroupedRow(.last, separatorInset: 16)
                }

                if showsAutoDownloads {
                    AutoDownloadsEntryRow(
                        count: manager.subscriptions.count,
                        nextEpisodeDay: nextAutoDownloadDay
                    ) {
                        router.navigate(to: .autoDownloads)
                    }
                    .downloadGroupedRow(.only)
                    .padding(.top, 12)
                }

                if !inProgress.isEmpty {
                    DownloadSectionHeader(title: "Downloading", count: inProgress.count)
                    if isSelecting {
                        Button(allActiveSelected ? "Clear In Progress" : "Select All In Progress") {
                            if allActiveSelected { activeSelection.removeAll() }
                            else { activeSelection = Set(inProgress.map(\.id)) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)
                    }
                    #if os(iOS)
                    if manager.canShowProgressOnLockScreen, !isSelecting {
                        Button {
                            manager.showProgressOnLockScreen()
                        } label: {
                            Label("Show Progress on Lock Screen", systemImage: "lock.iphone")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.siloOnSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.siloChromeSelectedFill))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                    #endif
                    ForEach(Array(inProgress.enumerated()), id: \.element.id) { index, record in
                        // Re-reads the rate each second: a stalled transfer
                        // sends no progress that would otherwise redraw the
                        // row and clear its last speed. Only transferring rows
                        // show a rate, so the others tick hourly; one view type
                        // keeps the row's identity when its status changes.
                        TimelineView(.periodic(from: .now, by: record.localStatus == .downloading ? 1 : 3600)) { context in
                            DownloadActiveRow(
                                record: record,
                                bytesPerSecond: manager.transferRate(id: record.id, at: context.date),
                                wait: manager.wait(for: record),
                                selecting: isSelecting,
                                selected: activeSelection.contains(record.id),
                                groupPosition: DownloadGroupPosition(index: index, count: inProgress.count),
                                onSelectToggle: { toggleActive(record.id) },
                                onPauseResume: {
                                    if record.localStatus == .paused { manager.resumeDownload(id: record.id) }
                                    else { manager.pauseDownload(id: record.id) }
                                },
                                onCancel: { manager.deleteDownload(id: record.id) }
                            )
                        }
                        .downloadGroupInset()
                    }
                    #if os(iOS)
                    if !isSelecting {
                        Text("Downloads keep going when you leave Silo or lock your phone. Closing Silo from the app switcher pauses them until you open it again.")
                            .font(.footnote)
                            .foregroundColor(.siloSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.top, 7)
                    }
                    #endif
                }

                if !failed.isEmpty {
                    DownloadSectionHeader(title: "Needs attention", count: failed.count)
                    ForEach(Array(failed.enumerated()), id: \.element.id) { index, record in
                        DownloadAttentionRow(
                            record: record,
                            onRetry: { manager.retryDownload(id: record.id) },
                            onDelete: { manager.deleteDownload(id: record.id) }
                        )
                        .downloadGroupedRow(DownloadGroupPosition(index: index, count: failed.count))
                    }
                }

                if !items.isEmpty {
                    DownloadSortControl(option: $settings.sortOption, itemCount: items.count)
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(for: item, position: DownloadGroupPosition(index: index, count: items.count))
                        .downloadGroupInset()
                }

                Color.clear.frame(height: 24)
            }
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: isSelecting)
        }
    }

    /// One list row, drawn as its slice of the group inside the context menu
    /// so the lifted preview keeps the cell's shape.
    @ViewBuilder
    private func row(for item: DownloadListItem, position: DownloadGroupPosition) -> some View {
        switch item {
        case .series(let group):
            DownloadSeriesRow(
                group: group,
                selecting: isSelecting,
                selected: selection.contains(item.id),
                isWatched: { manager.isWatched($0) },
                onSelectToggle: { toggle(item.id) },
                onOpenSeries: { router.navigate(to: .offlineSeriesBrowse(seriesId: group.seriesId)) },
                onPlayEpisode: { router.playOffline($0) },
                onDeleteEpisode: { manager.deleteDownload(id: $0.id) }
            )
            .downloadGroupSlice(position)
            .contextMenu {
                if !isSelecting {
                    Button(role: .destructive) {
                        pendingDeletion = PendingDeletion(
                            ids: group.allRecords.map(\.id),
                            endsSelection: false
                        )
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
            .downloadGroupSlice(position)
            .contextMenu {
                if !isSelecting {
                    Button(role: .destructive) {
                        pendingDeletion = PendingDeletion(ids: [record.id], endsSelection: false)
                    } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// The Auto-Downloads row shows wherever monitoring is offered, and
    /// whenever monitors exist, so they stay reachable.
    private var showsAutoDownloads: Bool {
        !isSelecting && (manager.canMonitorSeries || !manager.subscriptions.isEmpty)
    }

    /// When the soonest episode an active monitor covers airs, e.g. "Thursday".
    private var nextAutoDownloadDay: String? {
        let schedule = AutoDownloadSchedule.shared
        let next = manager.subscriptions
            .filter(\.active)
            .compactMap { subscription -> UpcomingEpisode? in
                guard let mode = SubscriptionMode(rawValue: subscription.mode) else { return nil }
                return AutoDownloadRules.nextEpisode(
                    mode: mode,
                    targetSeason: subscription.targetSeason,
                    seasonNumbers: subscription.seasonNumbers,
                    upcoming: schedule.upcoming(forSeriesId: subscription.seriesId),
                    excluding: manager.knownEpisodeIds(forSeriesId: subscription.seriesId)
                )
            }
            .min { $0.airDate < $1.airDate }
        return next.map {
            AutoDownloadRules.relativeDay($0.airDate, now: Date(), calendar: .current, preposition: false)
        }
    }

    // MARK: - Toolbar & select mode

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            SidebarToggleButton()
        }
        #endif

        if isSelecting {
            ToolbarItem(placement: .navigation) {
                Button(allSelected ? "Clear" : "Select All") { toggleSelectAll() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { exitSelectMode() }
            }
        } else if manager.hasRecord(where: { $0.isOnDevice || $0.localStatus.isActive }) {
            ToolbarItem(placement: .primaryAction) {
                Button("Select") { isSelecting = true }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isSelecting && selectedCount > 0 {
            Button {
                pendingDeletion = PendingDeletion(
                    ids: selectedDownloadIds,
                    activeIds: Array(liveActiveSelection),
                    endsSelection: true,
                    inProgressOnly: selection.isEmpty
                )
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: selection.isEmpty ? "xmark.circle" : "trash")
                    Text(bottomBarTitle)
                        .fontWeight(.bold)
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.siloOnSurface)
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
        let items = listItems
        let activeIds = manager.activeRecordIds
        guard !items.isEmpty || !activeIds.isEmpty else { return false }
        return Set(items.map(\.id)).isSubset(of: selection) && activeIds.isSubset(of: activeSelection)
    }

    private var selectedCount: Int {
        selection.count + liveActiveSelection.count
    }

    /// Selected downloads that are still in progress. One that finished or
    /// failed after it was selected drops out, so cancelling never deletes a
    /// finished file.
    private var liveActiveSelection: Set<String> {
        activeSelection.intersection(manager.activeRecordIds)
    }

    private var allActiveSelected: Bool {
        manager.activeRecordIds.isSubset(of: activeSelection)
    }

    private var bottomBarTitle: String {
        if selection.isEmpty {
            return selectedCount == 1 ? "Cancel 1 Download" : "Cancel \(selectedCount) Downloads"
        }
        let partialBytes = liveActiveSelection
            .reduce(Int64(0)) { $0 + (manager.record(id: $1)?.bytesDownloaded ?? 0) }
        return "Delete \(selectedCount) · Free \(DownloadFormatting.bytes(selectedBytes + partialBytes))"
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

    private func toggleActive(_ id: String) {
        if activeSelection.contains(id) { activeSelection.remove(id) } else { activeSelection.insert(id) }
    }

    private func toggleSelectAll() {
        if allSelected {
            selection.removeAll()
            activeSelection.removeAll()
        } else {
            selection = Set(listItems.map(\.id))
            activeSelection = manager.activeRecordIds
        }
    }

    private func exitSelectMode() {
        isSelecting = false
        selection.removeAll()
        activeSelection.removeAll()
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
