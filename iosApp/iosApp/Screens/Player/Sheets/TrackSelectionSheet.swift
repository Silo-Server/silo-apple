import SwiftUI

/// Audio / subtitle / secondary-subtitle picker. On tvOS renders as a
/// centered floating panel on top of the video — Infuse / VidHub idiom
/// rather than a full-takeover sheet. Rows are compact (name on top,
/// one-line attributes below, checkmark on selection) with a simple
/// row-fill focus highlight — no card parallax, no system button halo.
/// Menu dismisses. iPhone keeps its sectioned `List`.
struct TrackSelectionSheet: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    /// Drives presentation of the AI translate/transcribe menu.
    @State private var showAITranslateMenu = false

    /// Whether any AI subtitle action is available (translate or transcribe),
    /// per the server's capability probes. Gates the "Translate with AI…" row.
    private var aiSubtitlesAvailable: Bool {
        let caps = AICapabilities.shared
        return caps.subtitleEnabled || caps.transcribeEnabled
    }

    var body: some View {
        #if os(tvOS)
        tvOSPanel
        #else
        phoneList
        #endif
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSPanel: some View {
        ZStack {
            // Dimmed backdrop; tapping it dismisses so the user can bail
            // with the remote touch surface just by clicking anywhere
            // outside the panel. Video stays faintly visible behind.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 32) {
                    if !viewModel.audioTracks.isEmpty {
                        column(title: "Audio") { audioRows }
                    }
                    if !viewModel.subtitleTracks.isEmpty {
                        column(title: "Subtitles") { subtitleRows(isSecondary: false) }
                        // Secondary subs only when a primary is set. The shared
                        // player contract forbids the same track occupying both
                        // subtitle slots, so offering a secondary picker before
                        // the primary slot is chosen would be misleading.
                        if viewModel.supportsSecondarySubtitles,
                           viewModel.selectedSubtitleId != nil,
                           !viewModel.availableSecondarySubtitleTracks.isEmpty {
                            column(title: "Secondary") { subtitleRows(isSecondary: true) }
                        }
                    }
                }

                if aiSubtitlesAvailable {
                    AITranslateEntryRow { showAITranslateMenu = true }
                }
            }
            .padding(28)
            .frame(maxWidth: 1440, maxHeight: 680)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            if showAITranslateMenu {
                SubtitleTranslateMenu(viewModel: viewModel) { showAITranslateMenu = false }
                    .transition(.opacity)
            }
        }
        .onExitCommand { onDismiss() }
    }

    /// tvOS entry row that opens the AI translate/transcribe menu. Mirrors the
    /// bare-`focusable` + row-fill focus idiom of `TrackRow`.
    private struct AITranslateEntryRow: View {
        let action: () -> Void
        @FocusState private var isFocused: Bool

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Translate with AI…")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .onTapGesture(perform: action)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Translate with AI")
        }
    }

    @ViewBuilder
    private func column<Content: View>(
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 16, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 12)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    content()
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    // MARK: - Row builders

    @ViewBuilder
    private var audioRows: some View {
        ForEach(viewModel.audioTracks) { track in
            TrackRow(
                name: track.primaryLabel,
                attributes: track.attributesLabel,
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

        TrackRow(
            name: "Off",
            attributes: nil,
            isSelected: isOffSelected
        ) {
            if isSecondary { viewModel.disableSecondarySubtitles() }
            else           { viewModel.disableSubtitles() }
        }

        ForEach(isSecondary ? viewModel.availableSecondarySubtitleTracks : viewModel.subtitleTracks) { track in
            let isSelected = isSecondary
                ? viewModel.selectedSecondarySubtitleId == track.trackId
                : viewModel.selectedSubtitleId == track.trackId
            // Primary-selected track is disabled in the secondary column
            // so users can't pick the same sub twice.
            let isDisabled = isSecondary && viewModel.selectedSubtitleId == track.trackId

            TrackRow(
                name: track.primaryLabel,
                attributes: track.attributesLabel,
                isSelected: isSelected,
                isDisabled: isDisabled
            ) {
                if isSecondary { viewModel.selectSecondarySubtitle(track) }
                else           { viewModel.selectSubtitle(track) }
            }
        }
    }

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneList: some View {
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
            if aiSubtitlesAvailable {
                Section {
                    Button {
                        showAITranslateMenu = true
                    } label: {
                        Label("Translate with AI…", systemImage: "sparkles")
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
        .sheet(isPresented: $showAITranslateMenu) {
            SubtitleTranslateMenu(viewModel: viewModel) { showAITranslateMenu = false }
                .presentationDetents([.medium, .large])
        }
    }
    #endif
}

#if os(tvOS)
/// Infuse-style track row for tvOS: two lines, subtle row-fill focus highlight,
/// trailing checkmark for selection. Uses bare `.focusable(true)` + tap
/// gesture rather than a `Button` to avoid the tvOS system focus halo.
private struct TrackRow: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let attributes {
                    Text(attributes)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isFocused)
        .onTapGesture(perform: action)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
#else
/// Simple track row for iOS: standard List row with a trailing checkmark.
private struct TrackRow: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(.primary)
                    if let attributes {
                        Text(attributes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isDisabled)
    }
}
#endif
