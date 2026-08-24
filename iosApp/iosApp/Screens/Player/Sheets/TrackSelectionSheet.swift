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
