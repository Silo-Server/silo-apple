#if os(iOS)
import SwiftUI

/// Scrollable audio, subtitle, and secondary-subtitle picker for iPhone and
/// iPad. Track inventories can be much taller than a landscape popover, so the
/// rows live in a `List` instead of a native `Menu`.
struct TrackSelectionSheet: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    @State private var showAITranslateMenu = false
    @State private var showSubtitleSearchMenu = false

    private var aiSubtitlesAvailable: Bool {
        SubtitleTranslateMenu.hasActionableSource(viewModel)
    }

    var body: some View {
        NavigationStack {
            List {
                if !viewModel.audioTracks.isEmpty {
                    Section("Audio") { audioRows }
                }

                if !viewModel.subtitleTracks.isEmpty {
                    Section("Subtitles") { subtitleRows(isSecondary: false) }

                    timingSection

                    if viewModel.supportsSecondarySubtitles,
                       viewModel.selectedSubtitleId != nil,
                       !viewModel.availableSecondarySubtitleTracks.isEmpty {
                        Section("Secondary Subtitles") { subtitleRows(isSecondary: true) }
                    }
                }

                if aiSubtitlesAvailable || viewModel.subtitleSearchVisible {
                    subtitleToolsSection
                }
            }
            .listStyle(.insetGrouped)
            .onAppear { viewModel.refreshSubtitleSync() }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
        .sheet(isPresented: $showAITranslateMenu) {
            SubtitleTranslateMenu(
                viewModel: viewModel,
                onDismiss: { showAITranslateMenu = false },
                onJobStarted: {
                    showAITranslateMenu = false
                    onDismiss()
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSubtitleSearchMenu) {
            SubtitleSearchMenu(
                viewModel: viewModel,
                onDismiss: { showSubtitleSearchMenu = false },
                onDownloaded: {
                    showSubtitleSearchMenu = false
                    onDismiss()
                }
            )
            .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private var audioRows: some View {
        ForEach(viewModel.audioTracks) { track in
            TrackSelectionRow(
                name: track.primaryLabel,
                attributes: track.attributesLabel,
                pills: track.attributePillLabels,
                isSelected: viewModel.selectedAudioId == track.trackId
            ) {
                viewModel.selectAudio(track)
            }
        }
    }

    @ViewBuilder
    private func subtitleRows(isSecondary: Bool) -> some View {
        let isOffSelected = isSecondary
            ? viewModel.selectedSecondarySubtitleId == nil
            : viewModel.selectedSubtitleId == nil

        TrackSelectionRow(
            name: "Off",
            attributes: nil,
            isSelected: isOffSelected
        ) {
            if isSecondary {
                viewModel.disableSecondarySubtitles()
            } else {
                viewModel.disableSubtitles()
            }
        }

        ForEach(
            isSecondary
                ? viewModel.availableSecondarySubtitleTracks
                : viewModel.orderedSubtitleTracks
        ) { track in
            let isSelected = isSecondary
                ? viewModel.selectedSecondarySubtitleId == track.trackId
                : viewModel.selectedSubtitleId == track.trackId
            let isDisabled = isSecondary && viewModel.selectedSubtitleId == track.trackId
            let pills = track.attributePillLabels(
                includeLanguage: track.normalizedLanguageCode == nil
            )

            TrackSelectionRow(
                name: track.languageFirstPrimaryLabel,
                detail: track.languageFirstDetailLabel,
                attributes: pills.isEmpty ? nil : pills.joined(separator: " · "),
                pills: pills,
                status: viewModel.subtitleSyncStatus(for: track),
                isSelected: isSelected,
                isDisabled: isDisabled
            ) {
                if isSecondary {
                    viewModel.selectSecondarySubtitle(track)
                } else {
                    viewModel.selectSubtitle(track)
                }
            }
        }
    }

    /// "Sync to Audio" and "Reset Timing" for the selected track, stored or a
    /// file next to the media, with a running sync's progress and the last
    /// result. Anyone who can play the file may retime it; a refusal (demo
    /// mode) replaces the actions with a short explanation.
    @ViewBuilder
    private var timingSection: some View {
        let sync = viewModel.subtitleSync
        if let key = viewModel.selectedSubtitleSyncKey, let entry = sync.entry(for: key),
           sync.showsTimingControls(entry) {
            Section {
                if entry.isForbidden {
                    Text(sync.forbiddenMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if sync.canSync(entry) {
                        Button {
                            Task { await sync.requestSync(key: key) }
                        } label: {
                            Label(entry.isInProgress ? "Syncing…" : "Sync to Audio", systemImage: "waveform")
                        }
                        .disabled(entry.isBusy || entry.isInProgress)
                    }
                    if entry.canReset {
                        Button {
                            Task { await sync.resetTiming(key: key) }
                        } label: {
                            Label("Reset Timing", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(entry.isBusy || entry.isInProgress)
                    }
                }
                if let job = entry.job, job.isInProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        SubtitleSyncProgressBar(percent: SubtitleSyncLabel.percent(job) ?? 0)
                        if let phase = SubtitleSyncLabel.phase(job) {
                            Text(phase)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let result = entry.result {
                    Label {
                        Text(result.text)
                    } icon: {
                        Image(systemName: result.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(result.isWarning ? Color.siloWarning : Color.secondary)
                    }
                    .font(.footnote)
                    .foregroundStyle(result.isWarning ? Color.siloWarning : Color.secondary)
                }
                if let error = entry.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Timing")
            } footer: {
                if !entry.isForbidden, sync.canSync(entry), !entry.isInProgress, entry.result == nil {
                    Text(entry.actionNote)
                }
            }
        }
    }

    private var subtitleToolsSection: some View {
        Section {
            if aiSubtitlesAvailable {
                Button {
                    showAITranslateMenu = true
                } label: {
                    Label("AI Subtitles…", systemImage: "sparkles")
                }
            }

            if viewModel.subtitleSearchVisible {
                Button {
                    showSubtitleSearchMenu = true
                } label: {
                    Label {
                        Text("Search Subtitles…")
                        if let reason = viewModel.subtitleSearchUnavailableReason {
                            Text(reason)
                        }
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(!viewModel.subtitleSearchEnabled)
            }
        }
    }
}

private struct TrackSelectionRow: View {
    let name: String
    var detail: String? = nil
    let attributes: String?
    var pills: [String] = []
    /// A subtitle's sync status ("Syncing… 40%", "Synced −3.0 s").
    var status: String? = nil
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if !pills.isEmpty {
                        pillRow
                    } else if let attributes {
                        Text(attributes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    private var pillRow: some View {
        HStack(spacing: 4) {
            ForEach(pills, id: \.self) { pill in
                Text(pill.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                    )
            }
        }
    }
}
#endif
