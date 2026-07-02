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

    /// Drives presentation of the provider subtitle-search menu.
    @State private var showSubtitleSearchMenu = false

    /// Whether any AI subtitle action is available (translate or transcribe),
    /// per the server's capability probes **and** the current track list.
    /// Gates the "Translate with AI…" row so it never opens an empty menu.
    private var aiSubtitlesAvailable: Bool {
        SubtitleTranslateMenu.hasActionableSource(viewModel)
    }

    /// Whether provider subtitle search is available (active server session +
    /// sidecar-capable backend). Hidden for offline/local playback.
    private var subtitleSearchAvailable: Bool {
        viewModel.subtitleSearchAvailable
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

                if aiSubtitlesAvailable || subtitleSearchAvailable {
                    HStack(spacing: 16) {
                        if aiSubtitlesAvailable {
                            MenuEntryRow(
                                title: "AI Subtitles…",
                                systemImage: "sparkles",
                                accessibilityLabel: "AI Subtitles"
                            ) { showAITranslateMenu = true }
                        }
                        if subtitleSearchAvailable {
                            MenuEntryRow(
                                title: "Search Subtitles…",
                                systemImage: "magnifyingglass",
                                accessibilityLabel: "Search Subtitles"
                            ) { showSubtitleSearchMenu = true }
                        }
                    }
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
            // While an overlay menu is up, exclude the base panel from
            // focus and dim it so the d-pad can't escape behind the overlay.
            // Mirrors the `TVPlayerInfoHUD` appearance-dialog precedent.
            .disabled(showAITranslateMenu || showSubtitleSearchMenu)
            .opacity((showAITranslateMenu || showSubtitleSearchMenu) ? 0.28 : 1)

            if showAITranslateMenu {
                SubtitleTranslateMenu(
                    viewModel: viewModel,
                    onDismiss: { showAITranslateMenu = false },
                    // Job accepted: close both this menu and the track panel so
                    // the live overlay is visible on the player.
                    onJobStarted: {
                        showAITranslateMenu = false
                        onDismiss()
                    }
                )
                .transition(.opacity)
            } else if showSubtitleSearchMenu {
                SubtitleSearchMenu(
                    viewModel: viewModel,
                    // Back-out returns to the track panel; a successful
                    // download (track already selected) closes both.
                    onDismiss: { showSubtitleSearchMenu = false },
                    onDownloaded: {
                        showSubtitleSearchMenu = false
                        onDismiss()
                    }
                )
                .transition(.opacity)
            }
        }
        .onExitCommand { onDismiss() }
    }

    /// tvOS entry row that opens a subtitle tools menu (AI translate / provider
    /// search). Mirrors the bare-`focusable` + row-fill focus idiom of `TrackRow`.
    private struct MenuEntryRow: View {
        let title: String
        let systemImage: String
        let accessibilityLabel: String
        let action: () -> Void
        @FocusState private var isFocused: Bool

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text(title)
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
            .accessibilityLabel(accessibilityLabel)
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

        TrackRow(
            name: "Off",
            attributes: nil,
            isSelected: isOffSelected
        ) {
            if isSecondary { viewModel.disableSecondarySubtitles() }
            else           { viewModel.disableSubtitles() }
        }

        ForEach(isSecondary ? viewModel.availableSecondarySubtitleTracks : viewModel.orderedSubtitleTracks) { track in
            let isSelected = isSecondary
                ? viewModel.selectedSecondarySubtitleId == track.trackId
                : viewModel.selectedSubtitleId == track.trackId
            // Primary-selected track is disabled in the secondary column
            // so users can't pick the same sub twice.
            let isDisabled = isSecondary && viewModel.selectedSubtitleId == track.trackId

            // Subtitle rows lead with the language — embedded titles are
            // unreliable (format names, filenames) so a meaningful title
            // demotes to the detail slot and the language pill is dropped.
            let pills = track.attributePillLabels(includeLanguage: track.normalizedLanguageCode == nil)

            TrackRow(
                name: track.languageFirstPrimaryLabel,
                detail: track.languageFirstDetailLabel,
                attributes: pills.isEmpty ? nil : pills.joined(separator: " · "),
                pills: pills,
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
                if aiSubtitlesAvailable || subtitleSearchAvailable {
                    Section {
                        if aiSubtitlesAvailable {
                            Button {
                                showAITranslateMenu = true
                            } label: {
                                Label("AI Subtitles…", systemImage: "sparkles")
                            }
                        }
                        if subtitleSearchAvailable {
                            Button {
                                showSubtitleSearchMenu = true
                            } label: {
                                Label("Search Subtitles…", systemImage: "magnifyingglass")
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Audio & Subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                // Job accepted: close both this menu and the track sheet so the
                // live overlay is visible on the player.
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
                // Download succeeded (track already selected): close both this
                // menu and the track sheet so the player is visible.
                onDownloaded: {
                    showSubtitleSearchMenu = false
                    onDismiss()
                }
            )
            .presentationDetents([.large])
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
    /// Meaningful embedded title when the language leads (subtitle rows).
    var detail: String? = nil
    let attributes: String?
    /// Unused on tvOS (the panel keeps its one-line attribute text) but part
    /// of the shared row-builder call signature.
    var pills: [String] = []
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    /// One-line secondary text: detail first, then the attribute summary.
    private var secondaryText: String? {
        let combined = [detail, attributes].compactMap { $0 }.joined(separator: " · ")
        return combined.isEmpty ? nil : combined
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let secondaryText {
                    Text(secondaryText)
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
/// Track row for iOS/macOS: name plus a row of small metadata pills
/// (language, layout, codec, SDH/Forced/External flags), trailing checkmark
/// on the selected track. Uses `.plain` so text stays label-colored — the
/// default borderless List button tints every row blue, which reads as a
/// page of links instead of a picker.
private struct TrackRow: View {
    let name: String
    /// Meaningful embedded title when the language leads (subtitle rows).
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
                    // Name leads; a meaningful embedded title ("Dub (SDH)",
                    // "Signs & Songs") trails in secondary color.
                    HStack(spacing: 6) {
                        Text(name)
                            .lineLimit(1)
                            // Sidecar tracks are often named after the media
                            // file; the interesting part is at both ends.
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
