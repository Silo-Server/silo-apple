#if !os(tvOS)
import SwiftUI

/// Series-level download + monitoring control for the series/season detail
/// action row. A circle menu offering whole-season / whole-series download
/// and a series-monitoring subscription editor. Reads
/// `DownloadManager.shared` directly so it reflects live state.
struct SeriesDownloadMenuButton: View {
    let detail: ItemDetail
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]

    private var manager: DownloadManager { DownloadManager.shared }
    @State private var activeSheet: SeriesDownloadSheet?
    @State private var pendingMonitorSheet = false

    /// Presentation of the trigger. `labeled` matches the detail page's named
    /// action row; `circle` is the original chrome, still used elsewhere.
    enum Style {
        case circle
        case labeled
    }

    var style: Style = .circle

    private var seriesId: String { detail.seriesId ?? detail.contentId }
    private var isMonitored: Bool { manager.subscription(forSeriesId: seriesId) != nil }
    private var cachedEpisodesBySeason: [Int: [EpisodeListItem]] {
        var cached = episodesBySeason
        if let seasonNumber = selectedSeason?.seasonNumber,
           cached[seasonNumber]?.isEmpty != false,
           !episodes.isEmpty {
            cached[seasonNumber] = episodes
        }
        return cached
    }

    private var circleLabel: some View {
        Image(systemName: isMonitored ? "arrow.down.circle.fill" : "arrow.down.circle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
            .background(
                Circle()
                    .fill(Color.white.opacity(isMonitored ? 0.18 : 0.10))
                    .overlay(Circle().stroke(Color.white.opacity(isMonitored ? 0.55 : 0.25), lineWidth: 1))
            )
    }

    /// Filled, borderless circle over a caption, matching
    /// `PhoneLabeledAction`'s metrics.
    private var labeledLabel: some View {
        VStack(spacing: 6) {
            Image(systemName: isMonitored ? "arrow.down.circle.fill" : "arrow.down.to.line")
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(Color.continuumOnSurface)
                .frame(width: 42, height: 42)
                .background(
                    Circle().fill(Color.white.opacity(isMonitored ? 0.18 : 0.10))
                )
            Text(isMonitored ? "Monitored" : "Download")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.continuumOnSurface.opacity(isMonitored ? 0.92 : 0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }

    var body: some View {
        Button {
            activeSheet = .downloadOptions
        } label: {
            switch style {
            case .circle: circleLabel
            case .labeled: labeledLabel
            }
        }
        .accessibilityLabel("Download or monitor series")
        .accessibilityValue(isMonitored ? "Monitored" : "Not monitored")
        // Chaining sheets from `onDismiss` waits out the real dismiss
        // animation instead of guessing a delay — a fixed sleep silently
        // fails to present when teardown runs long (slow device,
        // accessibility animations, low power).
        .sheet(item: $activeSheet, onDismiss: {
            if pendingMonitorSheet {
                pendingMonitorSheet = false
                activeSheet = .monitor
            }
        }) { sheet in
            switch sheet {
            case .downloadOptions:
                SeriesDownloadOptionsSheet(
                    seriesId: seriesId,
                    seriesTitle: detail.title,
                    seasons: seasons,
                    selectedSeason: selectedSeason,
                    cachedEpisodesBySeason: cachedEpisodesBySeason,
                    posterThumbhash: detail.posterThumbhash,
                    canDownloadSeason: manager.canDownloadSeason,
                    canMonitorSeries: manager.canMonitorSeries,
                    isMonitored: isMonitored,
                    onMonitor: { pendingMonitorSheet = true }
                )
            case .monitor:
                SeriesMonitorSheet(seriesId: seriesId, seriesTitle: detail.title, seasons: seasons)
            }
        }
    }
}

private enum SeriesDownloadSheet: Identifiable {
    case downloadOptions
    case monitor

    var id: String {
        switch self {
        case .downloadOptions: return "downloadOptions"
        case .monitor: return "monitor"
        }
    }
}

private struct SeriesDownloadOptionsSheet: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]
    let selectedSeason: Season?
    let cachedEpisodesBySeason: [Int: [EpisodeListItem]]
    let posterThumbhash: String?
    let canDownloadSeason: Bool
    let canMonitorSeries: Bool
    let isMonitored: Bool
    let onMonitor: () -> Void

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !availableSeasons.isEmpty {
                        NavigationLink {
                            SeriesSeasonDownloadPicker(
                                seriesId: seriesId,
                                seriesTitle: seriesTitle,
                                seasons: availableSeasons,
                                cachedEpisodesBySeason: cachedEpisodesBySeason,
                                posterThumbhash: posterThumbhash
                            )
                        } label: {
                            optionLabel(
                                title: "Choose Episodes",
                                detail: "Open a season and select episodes",
                                icon: "checklist"
                            )
                        }
                    }

                    if canDownloadSeason, let selectedSeason {
                        optionButton(
                            title: "Download Season \(selectedSeason.seasonNumber)",
                            detail: "Original quality · \(selectedSeason.episodeCount) episode\(selectedSeason.episodeCount == 1 ? "" : "s")",
                            icon: "arrow.down.square.on.square"
                        ) {
                            startDownload {
                                try await manager.downloadSeason(seriesId: seriesId, seasonNumber: selectedSeason.seasonNumber)
                            }
                        }
                    }

                    optionButton(
                        title: "Download All Episodes",
                        detail: "Original quality",
                        icon: "arrow.down.circle"
                    ) {
                        startDownload {
                            try await manager.downloadSeries(seriesId: seriesId)
                        }
                    }
                } header: {
                    Text("Download")
                } footer: {
                    Text("Series and season downloads use original quality.")
                }

                if canMonitorSeries {
                    Section("Monitoring") {
                        optionButton(
                            title: isMonitored ? "Edit Monitoring" : "Monitor Series",
                            detail: isMonitored ? "Change auto-download rules" : "Auto-download future episodes",
                            icon: "antenna.radiowaves.left.and.right"
                        ) {
                            dismiss()
                            onMonitor()
                        }
                        if isMonitored {
                            Button(role: .destructive) {
                                if let sub = manager.subscription(forSeriesId: seriesId) {
                                    Task { await manager.deleteSubscription(id: sub.id) }
                                }
                                dismiss()
                            } label: {
                                Label("Stop Monitoring", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle(seriesTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .continuumScrollContentBackgroundHidden()
            .continuumPageBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var availableSeasons: [Season] {
        let sorted = seasons.sortedForDisplay()
        if sorted.isEmpty, let selectedSeason { return [selectedSeason] }
        return sorted
    }

    /// Run a download request, dismissing only on success — a silent
    /// `try?` here made an offline/unauthenticated tap look like it worked.
    private func startDownload(_ work: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func optionButton(
        title: String,
        detail: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            optionLabel(title: title, detail: detail, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func optionLabel(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.continuumOnSurface)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
                Text(detail)
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.continuumSecondaryText)
        }
        .padding(.vertical, 4)
    }
}

/// First level of the single-episode flow. Keeping seasons as navigation
/// destinations makes the download sheet scale to long-running series without
/// turning the first screen into one enormous checklist.
private struct SeriesSeasonDownloadPicker: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]
    let cachedEpisodesBySeason: [Int: [EpisodeListItem]]
    let posterThumbhash: String?

    var body: some View {
        List {
            Section {
                ForEach(seasons.sortedForDisplay()) { season in
                    NavigationLink {
                        SeriesEpisodeDownloadPicker(
                            seriesId: seriesId,
                            seriesTitle: seriesTitle,
                            season: season,
                            initialEpisodes: cachedEpisodesBySeason[season.seasonNumber] ?? [],
                            posterThumbhash: season.posterThumbhash ?? posterThumbhash
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(seasonName(season))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.continuumOnSurface)
                            Text("\(season.episodeCount) episode\(season.episodeCount == 1 ? "" : "s")")
                                .font(.continuumCaption)
                                .foregroundColor(.continuumSecondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Select a season")
            }
        }
        .navigationTitle("Choose Episodes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .continuumScrollContentBackgroundHidden()
        .continuumPageBackground()
    }

    private func seasonName(_ season: Season) -> String {
        if season.isSpecials == true || season.seasonNumber == 0 {
            return season.title ?? "Specials"
        }
        return "Season \(season.seasonNumber)"
    }
}

/// Native multi-selection for one season. A season's episode list is reused
/// from the detail model when available and fetched on demand otherwise.
private struct SeriesEpisodeDownloadPicker: View {
    let seriesId: String
    let seriesTitle: String
    let season: Season
    let posterThumbhash: String?

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var episodes: [EpisodeListItem]
    @State private var selectedEpisodeIds: Set<String> = []
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        seriesId: String,
        seriesTitle: String,
        season: Season,
        initialEpisodes: [EpisodeListItem],
        posterThumbhash: String?
    ) {
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.season = season
        self.posterThumbhash = posterThumbhash
        _episodes = State(initialValue: Self.sorted(initialEpisodes))
    }

    private var selectableEpisodeIds: Set<String> {
        Set(episodes.compactMap { episode in
            isSelectable(episode) ? episode.contentId : nil
        })
    }

    private var selectedEpisodes: [EpisodeListItem] {
        episodes.filter {
            selectedEpisodeIds.contains($0.contentId) && isSelectable($0)
        }
    }

    private var allSelectableAreSelected: Bool {
        !selectableEpisodeIds.isEmpty
            && selectableEpisodeIds.isSubset(of: selectedEpisodeIds)
    }

    var body: some View {
        Group {
            if isLoading, episodes.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading episodes…")
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if episodes.isEmpty {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No Episodes",
                    subtitle: "No downloadable episodes were found for this season."
                )
            } else {
                List {
                    Section {
                        ForEach(episodes) { episode in
                            episodeRow(episode)
                        }
                    } header: {
                        HStack {
                            Text("Episodes")
                            Spacer()
                            if !selectableEpisodeIds.isEmpty {
                                Button(allSelectableAreSelected ? "Clear" : "Select All") {
                                    toggleSelectAll()
                                }
                                .textCase(nil)
                            }
                        }
                    }
                }
                .continuumScrollContentBackgroundHidden()
            }
        }
        .continuumPageBackground()
        .navigationTitle(seasonName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            if !episodes.isEmpty {
                downloadBar
            }
        }
        .task { await loadEpisodesIfNeeded() }
        .alert(
            "Couldn't Continue",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var seasonName: String {
        if season.isSpecials == true || season.seasonNumber == 0 {
            return season.title ?? "Specials"
        }
        return "Season \(season.seasonNumber)"
    }

    private var downloadBar: some View {
        Button(action: startSelectedDownloads) {
            HStack(spacing: 9) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                } else {
                    Image(systemName: "arrow.down.to.line")
                }
                Text(downloadButtonTitle)
                    .fontWeight(.bold)
            }
            .font(.system(size: 15))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(selectedEpisodes.isEmpty ? Color.continuumDisabled : Color.continuumOnSurface)
            .foregroundColor(.black)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selectedEpisodes.isEmpty || isWorking)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var downloadButtonTitle: String {
        let count = selectedEpisodes.count
        if count == 0 { return "Select Episodes" }
        return "Download \(count) Episode\(count == 1 ? "" : "s")"
    }

    private func episodeRow(_ episode: EpisodeListItem) -> some View {
        let selectable = isSelectable(episode)
        return Button {
            guard selectable, !isWorking else { return }
            toggle(episode.contentId)
        } label: {
            HStack(spacing: 12) {
                selectionIndicator(for: episode)

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title ?? "Episode \(episode.episodeNumber)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(1)
                    Text(episodeDetailText(episode))
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let status = statusText(for: episode) {
                    Text(status)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(statusTint(for: episode))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable || isWorking)
    }

    @ViewBuilder
    private func selectionIndicator(for episode: EpisodeListItem) -> some View {
        if manager.isRegistering(contentId: episode.contentId) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        } else if let record = manager.record(forContentId: episode.contentId) {
            Image(systemName: statusIcon(for: record.localStatus))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(statusTint(for: episode))
                .frame(width: 24, height: 24)
        } else {
            DownloadSelectionCircle(selected: selectedEpisodeIds.contains(episode.contentId))
        }
    }

    private func episodeDetailText(_ episode: EpisodeListItem) -> String {
        var parts = ["Episode \(episode.episodeNumber)"]
        if let runtime = episode.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.joined(separator: " · ")
    }

    private func statusText(for episode: EpisodeListItem) -> String? {
        if manager.isRegistering(contentId: episode.contentId) { return "Preparing" }
        guard let record = manager.record(forContentId: episode.contentId) else { return nil }
        switch record.localStatus {
        case .registering, .preparing, .queued, .fetchingAssets: return "Preparing"
        case .downloading: return "\(Int((record.progressFraction * 100).rounded()))%"
        case .paused: return "Paused"
        case .completed, .revoked: return "Downloaded"
        case .failed: return "Failed"
        }
    }

    private func statusIcon(for status: LocalDownloadStatus) -> String {
        switch status {
        case .registering, .preparing, .queued, .fetchingAssets: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed, .revoked: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func statusTint(for episode: EpisodeListItem) -> Color {
        guard let status = manager.record(forContentId: episode.contentId)?.localStatus else {
            return .continuumSecondaryText
        }
        switch status {
        case .completed, .revoked: return .green
        case .failed: return .orange
        default: return .continuumOnSurface.opacity(0.78)
        }
    }

    private func isSelectable(_ episode: EpisodeListItem) -> Bool {
        manager.record(forContentId: episode.contentId) == nil
            && !manager.isRegistering(contentId: episode.contentId)
    }

    private func toggle(_ contentId: String) {
        if selectedEpisodeIds.contains(contentId) {
            selectedEpisodeIds.remove(contentId)
        } else {
            selectedEpisodeIds.insert(contentId)
        }
    }

    private func toggleSelectAll() {
        if allSelectableAreSelected {
            selectedEpisodeIds.subtract(selectableEpisodeIds)
        } else {
            selectedEpisodeIds.formUnion(selectableEpisodeIds)
        }
    }

    private func loadEpisodesIfNeeded() async {
        guard episodes.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await ContinuumAPI.shared.episodes(
                seriesId: seriesId,
                seasonNumber: season.seasonNumber
            )
            guard !Task.isCancelled else { return }
            episodes = Self.sorted(response.episodes)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSelectedDownloads() {
        let targets = selectedEpisodes
        guard !targets.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            do {
                for episode in targets {
                    guard isSelectable(episode) else {
                        selectedEpisodeIds.remove(episode.contentId)
                        continue
                    }
                    try await manager.downloadEpisode(
                        seriesId: seriesId,
                        episodeId: episode.contentId,
                        displayTitle: episode.title ?? "Episode \(episode.episodeNumber)",
                        displaySubtitle: "S\(episode.seasonNumber) · E\(episode.episodeNumber)",
                        posterThumbhash: posterThumbhash,
                        quality: DownloadSettings.shared.resolvedFormat(
                            allowedFormats: manager.capability?.qualityPresets ?? []
                        )
                    )
                    selectedEpisodeIds.remove(episode.contentId)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private static func sorted(_ episodes: [EpisodeListItem]) -> [EpisodeListItem] {
        episodes.sorted { lhs, rhs in
            if lhs.episodeNumber != rhs.episodeNumber {
                return lhs.episodeNumber < rhs.episodeNumber
            }
            return lhs.contentId < rhs.contentId
        }
    }
}

/// Create / edit a series-monitoring subscription. The retention fields
/// (`delete_watched`, `max_storage_bytes`) are client-enforced; the server
/// only soft-gates auto-registration.
struct SeriesMonitorSheet: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var mode: SubscriptionMode = .all
    @State private var selectedSeasons: Set<Int> = []
    @State private var deleteWatched: Bool = DownloadSettings.shared.defaultDeleteWatched
    @State private var maxStorageGB: Int = DownloadSettings.shared.defaultMaxStorageGB
    @State private var isSaving = false
    @State private var saveError: String?

    private var existing: DownloadSubscription? { manager.subscription(forSeriesId: seriesId) }
    private var availableModes: [SubscriptionMode] {
        manager.monitoringModes.isEmpty ? SubscriptionMode.allCases : manager.monitoringModes
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Keep Downloaded") {
                    Picker("Episodes", selection: $mode) {
                        ForEach(availableModes, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if mode == .specificSeasons {
                        ForEach(seasons) { season in
                            Toggle("Season \(season.seasonNumber)", isOn: Binding(
                                get: { selectedSeasons.contains(season.seasonNumber) },
                                set: { isOn in
                                    if isOn { selectedSeasons.insert(season.seasonNumber) }
                                    else { selectedSeasons.remove(season.seasonNumber) }
                                }
                            ))
                            .tint(.continuumAccent)
                        }
                    }
                }
                Section("Storage") {
                    Toggle("Delete watched episodes", isOn: $deleteWatched)
                        .tint(.continuumAccent)
                    Picker("Limit", selection: $maxStorageGB) {
                        ForEach(storageLimitOptionsGB, id: \.self) { gb in
                            Text(gb == 0 ? "Unlimited" : "\(gb) GB").tag(gb)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Monitor Series" : "Edit Monitoring")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || (mode == .specificSeasons && selectedSeasons.isEmpty))
                }
            }
            .onAppear(perform: prefill)
            .alert(
                "Couldn't Save Monitoring",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    /// Common caps, plus the stored value when it doesn't match one —
    /// subscriptions written by the old stepper (or another client) must
    /// stay representable rather than silently snapping to a preset.
    private var storageLimitOptionsGB: [Int] {
        var options = [0, 10, 25, 50, 100]
        if !options.contains(maxStorageGB) {
            options.append(maxStorageGB)
            options.sort()
        }
        return options
    }

    private func prefill() {
        guard let existing else { return }
        mode = SubscriptionMode(rawValue: existing.mode) ?? .all
        selectedSeasons = Set(existing.seasonNumbers ?? [])
        deleteWatched = existing.deleteWatched
        maxStorageGB = Int(existing.maxStorageBytes / DownloadSettings.bytesPerGB)
    }

    private func save() {
        isSaving = true
        let bytes = Int64(maxStorageGB) * DownloadSettings.bytesPerGB
        let seasonNumbers = mode == .specificSeasons ? Array(selectedSeasons).sorted() : nil
        Task {
            do {
                if let existing {
                    try await manager.updateSubscription(
                        id: existing.id,
                        mode: mode,
                        seasonNumbers: seasonNumbers,
                        deleteWatched: deleteWatched,
                        maxStorageBytes: bytes,
                        active: true
                    )
                } else {
                    try await manager.createSubscription(
                        seriesId: seriesId,
                        seriesTitle: seriesTitle,
                        mode: mode,
                        seasonNumbers: seasonNumbers,
                        deleteWatched: deleteWatched,
                        maxStorageBytes: bytes
                    )
                }
                dismiss()
            } catch {
                // Keep the sheet up so the edits aren't lost — the user can
                // retry or cancel once they've seen why the save failed.
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}
#endif
