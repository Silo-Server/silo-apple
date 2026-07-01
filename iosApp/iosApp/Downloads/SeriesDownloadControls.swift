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

    private var seriesId: String { detail.seriesId ?? detail.contentId }
    private var isMonitored: Bool { manager.subscription(forSeriesId: seriesId) != nil }

    var body: some View {
        Button {
            activeSheet = .downloadOptions
        } label: {
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
        .accessibilityLabel("Download or monitor series")
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .downloadOptions:
                SeriesDownloadOptionsSheet(
                    seriesId: seriesId,
                    seriesTitle: detail.title,
                    selectedSeason: selectedSeason,
                    canDownloadSeason: manager.canDownloadSeason,
                    canMonitorSeries: manager.canMonitorSeries,
                    isMonitored: isMonitored,
                    onMonitor: openMonitorSheet
                )
            case .monitor:
                SeriesMonitorSheet(seriesId: seriesId, seriesTitle: detail.title, seasons: seasons)
            }
        }
    }

    private func openMonitorSheet() {
        activeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            activeSheet = .monitor
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
                            Task { try? await manager.downloadSeason(seriesId: seriesId, seasonNumber: selectedSeason.seasonNumber) }
                            dismiss()
                        }
                    }

                    optionButton(
                        title: "Download All Episodes",
                        detail: "Original quality",
                        icon: "arrow.down.circle"
                    ) {
                        Task { try? await manager.downloadSeries(seriesId: seriesId) }
                        dismiss()
                    }
                } header: {
                    Text("Download")
                } footer: {
                    Text("Series and season downloads use Original quality in the current server contract.")
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
                        }
                    }
                }
                Section("Storage") {
                    Toggle("Delete watched episodes", isOn: $deleteWatched)
                    Stepper(
                        maxStorageGB == 0 ? "Limit: Unlimited" : "Limit: \(maxStorageGB) GB",
                        value: $maxStorageGB,
                        in: 0...1000,
                        step: 5
                    )
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
        }
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
            } catch {
                // Surface nothing for now; the sheet just closes.
            }
            dismiss()
        }
    }
}
#endif
