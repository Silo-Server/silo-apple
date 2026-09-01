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
                    selectedSeason: selectedSeason,
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
    let selectedSeason: Season?
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
            .background(Color.continuumBackground)
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
        .buttonStyle(.plain)
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
