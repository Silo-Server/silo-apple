#if os(iOS)
import SwiftUI

/// Scrollable audio, subtitle, and secondary-subtitle picker for iPhone and
/// iPad. Track inventories can be much taller than a landscape popover, so the
/// rows live in a `List` instead of a native `Menu`.
struct TrackSelectionSheet: View {
    let viewModel: PlayerViewModel
    /// A sheet this one opened covers the whole player.
    @Binding var nestedSheetCoversPlayer: Bool
    let onDismiss: () -> Void

    @State private var showAITranslateMenu = false
    @State private var translateDetent: PresentationDetent = .medium
    @State private var showSubtitleSearchMenu = false
    @Environment(\.locale) private var locale
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var aiSubtitlesAvailable: Bool {
        SubtitleTranslateMenu.hasActionableSource(viewModel)
    }

    var body: some View {
        NavigationStack {
            Group {
                // A phone on its side is too short to stack the two lists, so
                // audio and subtitles sit side by side and both stay in view.
                if verticalSizeClass == .compact, !viewModel.audioTracks.isEmpty {
                    HStack(spacing: 0) {
                        List {
                            Section { audioRows } header: { Text(.playerTracksAudio) }
                        }
                        List {
                            subtitleSections
                        }
                    }
                } else {
                    List {
                        if !viewModel.audioTracks.isEmpty {
                            Section { audioRows } header: { Text(.playerTracksAudio) }
                        }
                        subtitleSections
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onAppear {
                viewModel.refreshSubtitleSync()
                viewModel.refreshSubtitleProviders()
            }
            .navigationTitle(Text(.playerTracksTitle))
            .navigationBarTitleDisplayMode(.inline)
            .playerSheetNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { onDismiss() } label: { Text(.commonDone) }
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
            .presentationDetents([.medium, .large], selection: $translateDetent)
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
        .onChange(of: showAITranslateMenu) { _, shown in
            if !shown { translateDetent = .medium }
        }
        .onChange(of: nestedCovers, initial: true) { _, covers in
            nestedSheetCoversPlayer = covers
        }
    }

    @ViewBuilder
    private var subtitleSections: some View {
        if !viewModel.subtitleTracks.isEmpty {
            Section { subtitleRows(isSecondary: false) } header: { Text(.playerTracksSubtitles) }

            timingSection

            if viewModel.supportsSecondarySubtitles,
               viewModel.selectedSubtitleId != nil,
               !viewModel.availableSecondarySubtitleTracks.isEmpty {
                Section {
                    subtitleRows(isSecondary: true)
                } header: {
                    Text(.playerTracksSecondarySubtitles)
                }
            }
        }

        if aiSubtitlesAvailable || viewModel.subtitleSearchEnabled {
            subtitleToolsSection
        }
    }

    private var nestedCovers: Bool {
        showSubtitleSearchMenu || (showAITranslateMenu && translateDetent == .large)
    }

    @ViewBuilder
    private var audioRows: some View {
        ForEach(viewModel.audioTracks) { track in
            TrackSelectionRow(
                name: track.primaryLabel,
                detail: track.detailLabel,
                pills: track.attributePillLabels(),
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
            name: AppLanguage.string(.playerTracksSubtitlesOff, locale: locale),
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
            let isDisabled = track.hasUnsupportedFormat
                || isSecondary && viewModel.selectedSubtitleId == track.trackId

            TrackSelectionRow(
                name: track.primaryLabel,
                detail: track.detailLabel,
                pills: track.attributePillLabels(),
                status: track.hasUnsupportedFormat
                    ? PlayerTrack.unsupportedFormatLabel
                    : viewModel.subtitleSyncStatus(for: track),
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
                            Label {
                                Text(entry.isInProgress
                                     ? LocalizedStringResource.playerTracksSyncing
                                     : .playerTracksSyncToAudioButton)
                            } icon: {
                                Image(systemName: "waveform")
                            }
                        }
                        .disabled(entry.isBusy || entry.isInProgress)
                    }
                    if entry.canReset {
                        Button {
                            Task { await sync.resetTiming(key: key) }
                        } label: {
                            Label {
                                Text(.playerTracksResetTimingButton)
                            } icon: {
                                Image(systemName: "arrow.uturn.backward")
                            }
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
                Text(.playerTracksTiming)
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
                    Label {
                        Text(.playerAiTranslateOpenMenu)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
            }

            if viewModel.subtitleSearchEnabled {
                Button {
                    showSubtitleSearchMenu = true
                } label: {
                    Label {
                        Text(.optionsSearchSubtitles)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }
}

private struct TrackSelectionRow: View {
    let name: String
    var detail: String? = nil
    var pills: [String] = []
    /// A subtitle's sync status ("Syncing… 40%", "Synced −3.0 s").
    var status: String? = nil
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Name and format chips on one line; a long title (a
                // commentary's description) gets its own two lines under it
                // instead of being cut in the middle.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(name)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !pills.isEmpty {
                            pillRow
                        }
                    }

                    if let detail {
                        // Up to three lines: a commentary names its speakers,
                        // which is what tells same-language tracks apart.
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
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
