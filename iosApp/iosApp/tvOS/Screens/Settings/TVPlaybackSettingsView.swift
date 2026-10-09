#if os(tvOS)
import SwiftUI

/// Playback pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. The root view owns modal picker
/// presentation so only one focus graph is active at a time.
struct TVPlaybackSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void
    @State private var seekIntervals = SeekIntervalPreferences.shared
    @State private var showUseProfileSettingsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            streamingSection
            episodesSection
            if viewModel.hasHeldPlaybackChanges {
                TVHeldSettingChangesRows(
                    retry: { await viewModel.retryHeldPlaybackChanges() },
                    discard: { await viewModel.discardHeldPlaybackChanges() },
                    message: viewModel.heldPlaybackChangesMessage
                )
            }
            if viewModel.playbackChangeWasRejected {
                rejectedChangeRows
            }
            skipIntervalSection(media: .video)
            skipIntervalSection(media: .audiobook)
            resetSection
        }
        .task { await seekIntervals.refresh() }
        .alert(
            SettingsViewModel.useProfileSettingsTitle,
            isPresented: $showUseProfileSettingsConfirmation
        ) {
            Button("Use Profile Settings", role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.useProfileSettingsMessage)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var streamingSection: some View {
        TVSettingsSectionHeader("STREAMING")

        TVSettingsPickerRow(
            title: "Quality",
            value: viewModel.preferredQualityLabel
        ) { showPicker(.quality) }
        .focused(detailFocus, equals: .top)

        TVSettingsPickerRow(
            title: "Audio Language",
            value: TVSettingsOptions.label(
                for: viewModel.preferredAudioLanguage,
                in: TVSettingsOptions.audioLanguage(viewModel.audioLanguageOptions)
            )
        ) { showPicker(.audioLanguage) }
        .focused(detailFocus, equals: .playbackAudioLanguage)

        TVSettingsToggleRow(
            title: "HDR",
            isOn: viewModel.hdrEnabled
        ) {
            let value = !viewModel.hdrEnabled
            viewModel.hdrEnabled = value
        }

        TVSettingsToggleRow(
            title: "Dolby Vision",
            isOn: viewModel.dolbyVisionEnabled
        ) {
            let value = !viewModel.dolbyVisionEnabled
            viewModel.dolbyVisionEnabled = value
        }
        // Skipped by focus while HDR is off, like the skip-interval rows
        // below when the server cannot store them.
        .disabled(!viewModel.hdrEnabled)

        TVSettingsToggleRow(
            title: "Seek Cache",
            isOn: viewModel.seekCacheEnabled
        ) {
            let value = !viewModel.seekCacheEnabled
            viewModel.seekCacheEnabled = value
        }

        TVSettingsPickerRow(
            title: "Buffer Ahead",
            value: viewModel.bufferAhead.label
        ) { showPicker(.bufferAhead) }
        .focused(detailFocus, equals: .playbackBufferAhead)

        TVSettingsToggleRow(
            title: "Lossless Multichannel Audio",
            isOn: viewModel.losslessAudioEnabled
        ) {
            let value = !viewModel.losslessAudioEnabled
            viewModel.losslessAudioEnabled = value
        }

        TVSettingsToggleRow(
            title: "TrueHD Atmos",
            isOn: viewModel.trueHDAtmosEnabled
        ) {
            let value = !viewModel.trueHDAtmosEnabled
            viewModel.trueHDAtmosEnabled = value
        }

        TVSettingsPickerRow(
            title: "Deinterlacing",
            value: viewModel.deinterlaceMode.label
        ) { showPicker(.deinterlaceMode) }
        .focused(detailFocus, equals: .playbackDeinterlaceMode)

        TVSettingsPickerRow(
            title: "Deinterlacing Field Rate",
            value: viewModel.deinterlaceFieldRate.label
        ) { showPicker(.deinterlaceFieldRate) }
        .focused(detailFocus, equals: .playbackDeinterlaceFieldRate)

        TVSettingsFooter(streamingFooterText)
    }

    private var streamingFooterText: String {
        // Leads with what the chosen quality actually means, since the preset
        // labels ("1080p High") name a tier without stating its bitrate.
        var text = "\(viewModel.preferredQualityLabel)."
        if let preset = SiloQualityPresets.preset(id: viewModel.preferredQualityPresetId) {
            text = preset.description
        }
        text += " " + SettingsViewModel.hdrFooterText
        text += " If surround plays as stereo, turn off Lossless Multichannel Audio."
        text += " TrueHD Atmos adds height channels but plays those tracks as compressed audio."
        return text
    }

    @ViewBuilder
    private var episodesSection: some View {
        TVSettingsSectionHeader("EPISODES")

        // A picker rather than a one-press toggle: a toggle has no third
        // position for going back to the profile's choice.
        TVSettingsPickerRow(
            title: "Auto-Play Next Episode",
            value: viewModel.autoPlayNext ? "On" : "Off"
        ) { showPicker(.autoPlayNext) }
        .focused(detailFocus, equals: .playbackAutoPlayNext)

        TVSettingsPickerRow(
            title: "Show Next Up",
            value: TVSettingsOptions.label(for: String(viewModel.nextUpPromptSeconds), in: TVSettingsOptions.nextUpPrompt)
        ) { showPicker(.nextUpPrompt) }
        .focused(detailFocus, equals: .playbackNextUpPrompt)

        TVSettingsPickerRow(
            title: "Skip Intros",
            value: viewModel.introSkipMode.label
        ) { showPicker(.introSkipMode) }
        .focused(detailFocus, equals: .playbackIntroSkipMode)

        TVSettingsPickerRow(
            title: "Skip Credits",
            value: viewModel.skipCredits ? "On" : "Off"
        ) { showPicker(.skipCredits) }
        .focused(detailFocus, equals: .playbackSkipCredits)
    }

    /// "Video" and "Audiobooks" groups. The values belong to the profile on
    /// the server; the rows stay visible but unfocusable when this server
    /// cannot store them, and show the interval playback uses instead.
    @ViewBuilder
    private func skipIntervalSection(media: SeekMedia) -> some View {
        TVSettingsSectionHeader(media == .video ? "VIDEO" : "AUDIOBOOKS")

        ForEach(SeekDirection.allCases, id: \.self) { direction in
            TVSettingsPickerRow(
                title: direction == .backward ? "Skip Back" : "Skip Forward",
                value: SeekIntervalLabel.choiceLabel(
                    seekIntervals.seconds(direction, for: Self.surface(media))
                )
            ) { showPicker(.skipInterval(media, direction)) }
            .focused(detailFocus, equals: Self.focus(media, direction))
            .disabled(!seekIntervals.allowsEditing)
        }

        TVSettingsFooter(skipIntervalFooter(media: media))
    }

    private func skipIntervalFooter(media: SeekMedia) -> String {
        var lines = [
            media == .video
                ? "Used by clicks and swipes on the Siri Remote and the on-screen skip buttons. Applies to every device signed in to this profile."
                : "Used by the audiobook player's skip buttons. Applies to every device signed in to this profile.",
        ]
        if let status = seekIntervals.statusMessage {
            lines.append(status)
        }
        for direction in SeekDirection.allCases {
            if let error = seekIntervals.writeErrors[SeekIntervalContract.key(media, direction)] {
                lines.append(error)
            }
        }
        return lines.joined(separator: " ")
    }

    private static func surface(_ media: SeekMedia) -> SeekIntervalSurface {
        media == .video ? .videoPlayer : .audiobook
    }

    private static func focus(_ media: SeekMedia, _ direction: SeekDirection) -> TVSettingsDetailFocus {
        switch (media, direction) {
        case (.video, .backward): return .playbackVideoSkipBack
        case (.video, .forward): return .playbackVideoSkipForward
        case (.audiobook, .backward): return .playbackAudiobookSkipBack
        case (.audiobook, .forward): return .playbackAudiobookSkipForward
        }
    }

    @ViewBuilder
    private var rejectedChangeRows: some View {
        TVSettingsSectionHeader("NOT SAVED")

        Button {
            Task { await viewModel.acknowledgeRejectedPlaybackChange() }
        } label: {
            HStack(spacing: 16) {
                Text("OK")
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())

        TVSettingsWarningFooter(SettingsViewModel.rejectedPlaybackChangeMessage)
    }

    @ViewBuilder
    private var resetSection: some View {
        TVSettingsSectionHeader("RESET")

        Button {
            showUseProfileSettingsConfirmation = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22, weight: .medium))
                Text("Use Profile Settings")
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))

        TVSettingsFooter("Removes the settings changed on this Apple TV, so it uses your profile's settings again.")
    }

    // MARK: - Pickers

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        switch kind {
        case .quality:
            TVSettingsPickerRequest(
                title: "Quality",
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.quality(
                    // A stored pair no preset covers gets its own entry
                    // describing what is actually stored, so the sheet never
                    // highlights a preset the user did not choose.
                    including: !viewModel.usesProfileSetting(.quality)
                        && viewModel.preferredQualityPresetId == nil
                        ? viewModel.preferredQualityLabel
                        : nil
                ),
                selection: selection(.quality),
                returnFocus: .top
            )
        case .audioLanguage:
            TVSettingsPickerRequest(
                title: "Audio Language",
                options: TVSettingsOptions.deviceAudioLanguage(
                    viewModel.audioLanguageOptions,
                    includingNoPreference: viewModel.hasStoredNoAudioLanguagePreference
                ),
                selection: selection(.audioLanguage),
                returnFocus: .playbackAudioLanguage
            )
        case .bufferAhead:
            TVSettingsPickerRequest(
                title: "Buffer Ahead",
                options: TVSettingsOptions.bufferAhead,
                selection: Binding(
                    get: { viewModel.bufferAhead.rawValue },
                    set: { value in
                        guard let mode = BufferAheadMode(rawValue: value) else { return }
                        viewModel.bufferAhead = mode
                    }
                ),
                returnFocus: .playbackBufferAhead
            )
        case .deinterlaceMode:
            TVSettingsPickerRequest(
                title: "Deinterlacing",
                options: TVSettingsOptions.deinterlaceMode,
                selection: Binding(
                    get: { viewModel.deinterlaceMode.rawValue },
                    set: { value in
                        guard let mode = DeinterlacePreference(rawValue: value) else { return }
                        viewModel.deinterlaceMode = mode
                    }
                ),
                returnFocus: .playbackDeinterlaceMode
            )
        case .deinterlaceFieldRate:
            TVSettingsPickerRequest(
                title: "Deinterlacing Field Rate",
                options: TVSettingsOptions.deinterlaceFieldRate,
                selection: Binding(
                    get: { viewModel.deinterlaceFieldRate.rawValue },
                    set: { value in
                        guard let rate = DeinterlaceFieldRatePreference(rawValue: value) else {
                            return
                        }
                        viewModel.deinterlaceFieldRate = rate
                    }
                ),
                returnFocus: .playbackDeinterlaceFieldRate
            )
        case .nextUpPrompt:
            TVSettingsPickerRequest(
                title: "Show Next Up",
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.nextUpPrompt,
                selection: selection(.nextUpPrompt),
                returnFocus: .playbackNextUpPrompt
            )
        case .introSkipMode:
            TVSettingsPickerRequest(
                title: "Skip Intros",
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.introSkipMode,
                selection: selection(.introSkipMode),
                returnFocus: .playbackIntroSkipMode
            )
        case .autoPlayNext:
            TVSettingsPickerRequest(
                title: "Auto-Play Next Episode",
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.onOff,
                selection: selection(.autoPlayNext),
                returnFocus: .playbackAutoPlayNext
            )
        case .skipCredits:
            TVSettingsPickerRequest(
                title: "Skip Credits",
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.onOff,
                selection: selection(.autoSkipCredits),
                returnFocus: .playbackSkipCredits
            )
        case .skipInterval(let media, let direction):
            TVSettingsPickerRequest(
                title: "\(media == .video ? "Video" : "Audiobook") \(direction == .backward ? "Skip Back" : "Skip Forward")",
                options: SeekIntervalContract.choices.map {
                    TVSettingsOption(id: String($0), label: SeekIntervalLabel.choiceLabel($0))
                },
                selection: Binding(
                    get: { String(seekIntervals.seconds(direction, for: Self.surface(media))) },
                    set: { value in
                        guard let seconds = Int(value) else { return }
                        seekIntervals.setInterval(seconds, media: media, direction: direction)
                    }
                ),
                returnFocus: Self.focus(media, direction)
            )
        }
    }

    private func selection(_ setting: ProfileBackedPlaybackSetting) -> Binding<String> {
        Binding(
            get: { viewModel.playbackSelectionTag(setting) },
            set: { viewModel.selectPlayback($0, for: setting) }
        )
    }

    enum PickerKind {
        case quality
        case audioLanguage
        case autoPlayNext
        case skipCredits
        case bufferAhead
        case deinterlaceMode
        case deinterlaceFieldRate
        case nextUpPrompt
        case introSkipMode
        case skipInterval(SeekMedia, SeekDirection)
    }
}
#endif
