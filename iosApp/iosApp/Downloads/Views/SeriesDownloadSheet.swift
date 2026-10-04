#if !os(tvOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The series Download action. "One Time" downloads an episode, a season,
/// or every episode now. "Monitor" keeps a series downloading: All
/// Episodes, Future Episodes, or Last Season. Both start at the quality
/// set in Settings and can override it. The monitor's retention fields
/// (`delete_watched`, `max_storage_bytes`) are enforced on the device; the
/// server only soft-gates registration.
struct SeriesDownloadSheet: View {
    let seriesId: String
    let seriesTitle: String
    var seasons: [Season] = []
    /// The season the series page shows, offered for a one-time download.
    var selectedSeason: Season? = nil
    /// The episode the series page highlights, with the version its
    /// selector shows.
    var episode: EpisodeListItem? = nil
    var episodeFileId: Int? = nil
    var posterThumbhash: String? = nil
    /// Opens on Monitor, for callers about an existing monitor.
    var startsOnMonitor = false

    enum Kind: Hashable { case oneTime, monitor }

    private enum OneTime: Hashable { case episode, season, all }

    /// A monitor row. `custom` stands for a specific-seasons monitor
    /// another client created; it can be kept, not chosen.
    private enum Rule: Hashable {
        case mode(SubscriptionMode)
        case custom
    }

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }
    private var schedule: AutoDownloadSchedule { AutoDownloadSchedule.shared }

    @State private var kind: Kind = .oneTime
    @State private var oneTime: OneTime = .episode
    @State private var rule: Rule = .mode(.future)
    @State private var deleteWatched = DownloadSettings.shared.defaultDeleteWatched
    @State private var maxStorageBytes = Int64(DownloadSettings.shared.defaultMaxStorageGB) * DownloadSettings.bytesPerGB
    @State private var oneTimeQuality = DownloadFormat.original.rawValue
    @State private var monitorQuality = DownloadFormat.original.rawValue
    @State private var loadedSeasons: [Season] = []
    @State private var prefilled = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingStop = false

    private var existing: DownloadSubscription? { manager.subscription(forSeriesId: seriesId) }
    /// An existing monitor stays reachable, so it can be stopped, even when
    /// the server no longer offers monitoring.
    private var canShowMonitor: Bool { manager.canMonitorSeries || existing != nil }
    private var isMonitoring: Bool { existing?.active == true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Download", selection: $kind) {
                        Text("One Time").tag(Kind.oneTime)
                        if canShowMonitor {
                            Text("Monitor").tag(Kind.monitor)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(kind == .oneTime
                         ? "Download now. Nothing else downloads later."
                         : "Keep new episodes coming to this \(Self.deviceName) as they air.")
                        .font(.footnote)
                        .foregroundColor(.siloSecondaryText)
                        .padding(.horizontal, 4)

                    if kind == .oneTime {
                        optionList(oneTimeRows.map { row in
                            Option(id: AnyHashable(row), title: title(for: row), detail: detail(for: row),
                                   selected: oneTime == row, enabled: isAvailable(row)) { oneTime = row }
                        })
                        card {
                            qualityRow(selection: $oneTimeQuality, locked: oneTimeQualityLocked)
                        }
                    } else {
                        optionList(ruleRows.map { row in
                            Option(id: AnyHashable(row), title: title(for: row), detail: detail(for: row),
                                   selected: rule == row, enabled: true) { rule = row }
                        })
                        settingsCard
                        if existing != nil {
                            Button("Stop Monitoring", role: .destructive) { confirmingStop = true }
                                .font(.system(size: 15.5, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 2)
                                .disabled(isWorking)
                        }
                    }

                    if !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundColor(.siloSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .animation(.easeInOut(duration: 0.2), value: kind)
            }
            .safeAreaInset(edge: .bottom) { primaryButton }
            .navigationTitle(seriesTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .siloSheetBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task {
            prefill()
            await loadSeasonsIfNeeded()
            await schedule.refresh(evenWithoutMonitors: true)
        }
        .alert(
            kind == .oneTime ? "Download Failed" : "Couldn't Save Monitoring",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Stop monitoring \(seriesTitle)?", isPresented: $confirmingStop) {
            Button("Stop", role: .destructive, action: stopMonitoring)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Episodes already on this \(Self.deviceName) stay until you delete them.")
        }
    }

    // MARK: - Rows

    private struct Option: Identifiable {
        let id: AnyHashable
        let title: String
        let detail: String
        let selected: Bool
        let enabled: Bool
        let select: () -> Void
    }

    private func optionList(_ options: [Option]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().overlay(Color.siloDivider).padding(.leading, 52) }
                Button(action: option.select) {
                    HStack(spacing: 14) {
                        Image(systemName: option.selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundColor(option.selected ? .siloOnSurface : .siloSecondaryText.opacity(0.6))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.system(size: 16.5, weight: .semibold))
                                .foregroundColor(.siloOnSurface)
                            Text(option.detail)
                                .font(.footnote)
                                .foregroundColor(.siloSecondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .opacity(option.enabled ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
                .accessibilityAddTraits(option.selected ? .isSelected : [])
            }
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    /// The presets this user may download in, in the server's order, plus
    /// `current` when it isn't one, so a monitor's stored quality stays
    /// representable.
    private func qualityChoices(including current: String) -> [DownloadFormat] {
        var formats = manager.availableFormats
        if formats.isEmpty { formats = [.original] }
        if let stored = DownloadFormat(rawValue: current), !formats.contains(stored) {
            formats.append(stored)
        }
        return formats
    }

    private func qualityLabel(_ raw: String) -> String {
        guard let format = DownloadFormat(rawValue: raw) else { return raw }
        return manager.capability?.label(for: format) ?? format.displayName
    }

    /// A quality menu. `locked` shows Original alone, for a server that
    /// downloads seasons or monitors only in original quality.
    private func qualityRow(selection: Binding<String>, locked: Bool) -> some View {
        let choices = qualityChoices(including: selection.wrappedValue)
        let isMenu = !locked && choices.count > 1
        return HStack {
            // The menu carries its own "Quality" label for VoiceOver.
            Text("Quality")
                .foregroundColor(.siloOnSurface)
                .accessibilityHidden(isMenu)
            Spacer()
            if !isMenu {
                Text(locked ? DownloadFormat.original.displayName : qualityLabel(selection.wrappedValue))
                    .foregroundColor(.siloSecondaryText)
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
            } else {
                Picker("Quality", selection: selection) {
                    ForEach(choices, id: \.self) { format in
                        Text(qualityLabel(format.rawValue)).tag(format.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.siloSecondaryText)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .accessibilityElement(children: isMenu ? .contain : .combine)
    }

    private var settingsCard: some View {
        card {
            qualityRow(selection: $monitorQuality, locked: !manager.canChooseMonitorQuality)
            Divider().overlay(Color.siloDivider).padding(.leading, 16)
            Toggle("Delete after watching", isOn: $deleteWatched)
                .tint(.siloSwitchOn)
                .foregroundColor(.siloOnSurface)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            Divider().overlay(Color.siloDivider).padding(.leading, 16)
            HStack {
                // The menu carries its own "Storage limit" label for VoiceOver.
                Text("Storage limit")
                    .foregroundColor(.siloOnSurface)
                    .accessibilityHidden(true)
                Spacer()
                Picker("Storage limit", selection: $maxStorageBytes) {
                    ForEach(storageLimitOptions, id: \.self) { bytes in
                        Text(bytes == 0 ? "None" : AutoDownloadRules.limitText(bytes)).tag(bytes)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.siloSecondaryText)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
        }
    }

    /// One Time needs an available row; Monitor needs the server to still
    /// offer monitoring (an existing monitor can only be stopped).
    private var primaryEnabled: Bool {
        switch kind {
        case .oneTime: return isAvailable(oneTime)
        case .monitor: return manager.canMonitorSeries
        }
    }

    private var primaryButton: some View {
        Button(action: kind == .oneTime ? downloadOnce : saveMonitor) {
            Group {
                if isWorking {
                    ProgressView().tint(.black)
                } else {
                    Text(primaryTitle).fontWeight(.bold)
                }
            }
            .font(.system(size: 17))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.siloOnSurface)
            .foregroundColor(.black)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking || !primaryEnabled)
        .opacity(primaryEnabled ? 1 : 0.5)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }

    // MARK: - One time

    private var allSeasons: [Season] {
        (seasons.isEmpty ? loadedSeasons : seasons).sorted { $0.seasonNumber < $1.seasonNumber }
    }

    /// The season a one-time season download takes: the one the page
    /// shows, else the newest regular season.
    private var oneTimeSeason: Season? {
        selectedSeason ?? allSeasons.last { $0.seasonNumber > 0 && $0.isSpecials != true }
    }

    private var oneTimeRows: [OneTime] {
        var rows: [OneTime] = []
        if episode != nil { rows.append(.episode) }
        if manager.canDownloadSeason, oneTimeSeason != nil { rows.append(.season) }
        rows.append(.all)
        return rows
    }

    private var episodeDownloaded: Bool {
        episode.map {
            manager.isDownloaded(contentId: $0.contentId) || manager.isInFlight(contentId: $0.contentId)
                || manager.isRegistering(contentId: $0.contentId)
        } ?? false
    }

    private func isAvailable(_ row: OneTime) -> Bool {
        switch row {
        case .episode: return episode != nil && !episodeDownloaded
        case .season: return oneTimeSeason != nil
        case .all: return true
        }
    }

    private func title(for row: OneTime) -> String {
        switch row {
        case .episode:
            guard let episode else { return "This Episode" }
            return "S\(episode.seasonNumber) · E\(episode.episodeNumber) · \(episode.title ?? "Episode \(episode.episodeNumber)")"
        case .season: return oneTimeSeason?.downloadDisplayName ?? "Season"
        case .all: return "All Episodes"
        }
    }

    private func detail(for row: OneTime) -> String {
        switch row {
        case .episode:
            if let episode, manager.isDownloaded(contentId: episode.contentId) { return "On this \(Self.deviceName)" }
            if episodeDownloaded { return "Downloading" }
            return "This episode only"
        case .season:
            let count = oneTimeSeason?.episodeCount ?? 0
            return "\(count) episode\(count == 1 ? "" : "s")"
        case .all:
            return "Every season"
        }
    }

    /// A season or series download on a server that takes them only in
    /// original quality.
    private var oneTimeQualityLocked: Bool { oneTime != .episode && !manager.canChooseBatchQuality }

    private var oneTimeEffectiveQuality: String {
        oneTimeQualityLocked ? DownloadFormat.original.rawValue : oneTimeQuality
    }

    private func downloadOnce() {
        isWorking = true
        Task {
            do {
                switch oneTime {
                case .episode:
                    guard let episode else { break }
                    try await manager.downloadEpisode(
                        seriesId: seriesId,
                        episodeId: episode.contentId,
                        displayTitle: episode.title ?? "Episode \(episode.episodeNumber)",
                        displaySubtitle: "S\(episode.seasonNumber) · E\(episode.episodeNumber)",
                        posterThumbhash: posterThumbhash,
                        fileId: episodeFileId,
                        quality: oneTimeQuality
                    )
                case .season:
                    guard let season = oneTimeSeason else { break }
                    try await manager.downloadSeason(
                        seriesId: seriesId, seasonNumber: season.seasonNumber, quality: oneTimeEffectiveQuality)
                case .all:
                    try await manager.downloadSeries(seriesId: seriesId, quality: oneTimeEffectiveQuality)
                }
                dismiss()
            } catch DownloadError.registrationAlreadyInFlight {
                // The original request owns the Preparing state.
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    // MARK: - Monitor

    private var ruleRows: [Rule] {
        let advertised = manager.monitoringModes.isEmpty ? SubscriptionMode.allCases : manager.monitoringModes
        // An existing monitor's rule stays listed, so it can be kept, even
        // when the server no longer advertises it.
        let current = existing.flatMap { SubscriptionMode(rawValue: $0.mode) }
        var rows = [SubscriptionMode.all, .future, .latestSeason]
            .filter { advertised.contains($0) || $0 == current }
            .map(Rule.mode)
        if current == .specificSeasons { rows.append(.custom) }
        return rows
    }

    /// The season "Last Season" starts from: the monitor's own when it
    /// already uses that rule, else the newest regular season.
    private var latestSeasonNumber: Int? {
        if let existing, existing.mode == SubscriptionMode.latestSeason.rawValue, let target = existing.targetSeason {
            return target
        }
        return allSeasons.filter { $0.seasonNumber > 0 && $0.isSpecials != true }.map(\.seasonNumber).max()
    }

    private func title(for row: Rule) -> String {
        switch row {
        case .mode(.all): return "All Episodes"
        case .mode(.future): return "Future Episodes"
        case .mode(.latestSeason): return "Last Season"
        case .mode(.specificSeasons), .custom: return "Custom"
        }
    }

    private func detail(for row: Rule) -> String {
        switch row {
        case .mode(.all): return "Download every episode now, then new ones as they air"
        case .mode(.future): return "Only episodes that air from now on"
        case .mode(.latestSeason):
            return latestSeasonNumber.map { "Season \($0) and anything newer" } ?? "The latest season and anything newer"
        case .mode(.specificSeasons), .custom:
            return AutoDownloadRules.seasonList(existing?.seasonNumbers ?? [])
        }
    }

    /// Common caps, plus the stored value when it doesn't match one, so a
    /// limit another client wrote stays as it is unless the user picks
    /// another.
    private var storageLimitOptions: [Int64] {
        var options = [0, 10, 25, 50, 100].map { Int64($0) * DownloadSettings.bytesPerGB }
        if !options.contains(maxStorageBytes) {
            options.append(maxStorageBytes)
            options.sort()
        }
        return options
    }

    private var monitorHasChanges: Bool {
        guard let existing, existing.active else { return true }
        return Self.rule(for: existing) != rule
            || existing.deleteWatched != deleteWatched
            || existing.maxStorageBytes != maxStorageBytes
            || monitorQualityChange(from: existing) != nil
    }

    /// The quality to send, or nil when it stays as stored. An unchanged
    /// quality is never resent: the server rechecks transcode permission
    /// for any quality it receives.
    private func monitorQualityChange(from existing: DownloadSubscription?) -> String? {
        guard manager.canChooseMonitorQuality else { return nil }
        guard let existing else { return monitorQuality }
        return (existing.quality ?? DownloadFormat.original.rawValue) == monitorQuality ? nil : monitorQuality
    }

    private static func rule(for subscription: DownloadSubscription) -> Rule {
        let mode = SubscriptionMode(rawValue: subscription.mode) ?? .future
        return mode == .specificSeasons ? .custom : .mode(mode)
    }

    private func saveMonitor() {
        guard monitorHasChanges else {
            dismiss()
            return
        }
        isWorking = true
        Task {
            do {
                switch (rule, existing) {
                case (.custom, let existing?):
                    try await manager.updateSubscription(
                        id: existing.id, deleteWatched: deleteWatched, maxStorageBytes: maxStorageBytes, active: true,
                        quality: monitorQualityChange(from: existing))
                case (.mode(let mode), let existing?):
                    // An unchanged rule isn't resent: the server may no longer
                    // accept it as a new choice.
                    try await manager.updateSubscription(
                        id: existing.id, mode: rule == Self.rule(for: existing) ? nil : mode,
                        deleteWatched: deleteWatched, maxStorageBytes: maxStorageBytes, active: true,
                        quality: monitorQualityChange(from: existing))
                case (.mode(let mode), nil):
                    try await manager.createSubscription(
                        seriesId: seriesId, seriesTitle: seriesTitle, mode: mode, seasonNumbers: nil,
                        deleteWatched: deleteWatched, maxStorageBytes: maxStorageBytes,
                        quality: monitorQualityChange(from: nil))
                case (.custom, nil):
                    break
                }
                schedule.subscriptionsChanged()
                dismiss()
            } catch {
                // Keep the sheet up so the choice isn't lost.
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func stopMonitoring() {
        guard let existing else { return }
        Task {
            await manager.deleteSubscription(id: existing.id)
            schedule.subscriptionsChanged()
            dismiss()
        }
    }

    // MARK: - Shared

    private var primaryTitle: String {
        switch kind {
        case .oneTime: return "Download"
        case .monitor: return isMonitoring ? "Save" : "Start Monitoring"
        }
    }

    /// One plain sentence on what happens next.
    private var summary: String {
        switch kind {
        case .oneTime:
            if oneTime == .episode { return "" }
            if oneTimeQualityLocked { return "This server downloads seasons in original quality." }
            return oneTimeQuality == DownloadFormat.original.rawValue
                ? "" : "Episodes the server can't convert to this quality are skipped."
        case .monitor:
            let mode: SubscriptionMode
            switch rule {
            case .mode(let picked): mode = picked
            case .custom: mode = .specificSeasons
            }
            let quality = manager.canChooseMonitorQuality ? monitorQuality : DownloadFormat.original.rawValue
            var sentence = quality == DownloadFormat.original.rawValue
                ? "Monitored episodes download in original quality."
                : "Monitored episodes download at \(DownloadFormat(rawValue: quality)?.displayName ?? quality)."
            if let next = AutoDownloadRules.nextEpisode(
                mode: mode,
                targetSeason: mode == .latestSeason ? latestSeasonNumber : nil,
                seasonNumbers: existing?.seasonNumbers,
                upcoming: schedule.upcoming(forSeriesId: seriesId),
                excluding: manager.knownEpisodeIds(forSeriesId: seriesId)
            ) {
                sentence = AutoDownloadRules.headline(.next(next)) + ". " + sentence
            }
            return sentence
        }
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }

    private func prefill() {
        guard !prefilled else { return }
        prefilled = true
        let preferred = DownloadSettings.shared.resolvedFormat(allowedFormats: manager.capability?.qualityPresets ?? [])
        oneTimeQuality = preferred
        monitorQuality = preferred
        if let existing {
            monitorQuality = existing.quality ?? DownloadFormat.original.rawValue
            rule = Self.rule(for: existing)
            deleteWatched = existing.deleteWatched
            maxStorageBytes = existing.maxStorageBytes
        } else if !ruleRows.contains(rule), let first = ruleRows.first {
            // The server may not offer Future Episodes.
            rule = first
        }
        if canShowMonitor, startsOnMonitor || isMonitoring {
            kind = .monitor
        }
        if !isAvailable(oneTime), let first = oneTimeRows.first(where: isAvailable) {
            oneTime = first
        }
    }

    private func loadSeasonsIfNeeded() async {
        guard seasons.isEmpty, loadedSeasons.isEmpty else { return }
        if let response = try? await SiloAPI.shared.seasons(seriesId: seriesId) {
            loadedSeasons = response.seasons
        }
    }
}
#endif
