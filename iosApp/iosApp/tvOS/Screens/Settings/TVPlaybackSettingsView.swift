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
    @State private var showSpeakerTest = false

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
        .fullScreenCover(isPresented: $showSpeakerTest) {
            TVAtmosSpeakerTestView { showSpeakerTest = false }
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
            title: "Dolby Vision",
            isOn: viewModel.dolbyVisionEnabled
        ) {
            let value = !viewModel.dolbyVisionEnabled
            viewModel.dolbyVisionEnabled = value
            Task { await viewModel.setDolbyVisionEnabled(value) }
        }

        TVSettingsToggleRow(
            title: "Seek Cache",
            isOn: viewModel.seekCacheEnabled
        ) {
            let value = !viewModel.seekCacheEnabled
            viewModel.seekCacheEnabled = value
            Task { await viewModel.setSeekCacheEnabled(value) }
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
            Task { await viewModel.setLosslessAudioEnabled(value) }
        }

        TVSettingsToggleRow(
            title: "TrueHD Atmos",
            isOn: viewModel.trueHDAtmosEnabled
        ) {
            let value = !viewModel.trueHDAtmosEnabled
            viewModel.trueHDAtmosEnabled = value
            Task { await viewModel.setTrueHDAtmosEnabled(value) }
        }

        TVSettingsPickerRow(title: "Atmos Speaker Test", value: "") {
            showSpeakerTest = true
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
        var text = "\(viewModel.preferredQualityLabel). "
        if let preset = SiloQualityPresets.preset(id: viewModel.preferredQualityPresetId) {
            text = "\(preset.description) "
        }
        text += "Turn off Dolby Vision to play Dolby Vision titles as HDR10 instead. Profile 5 titles have no HDR10-compatible layer and always play in Dolby Vision."
        text += " Seek Cache keeps recently streamed video in temporary storage during playback so skipping forward and back is instant."
        text += " Buffer Ahead controls how much video is downloaded ahead of the playhead; longer windows ride out network dropouts, and Unlimited buffers as much as fits in temporary storage, which is cleared when playback ends."
        text += " Lossless Multichannel Audio delivers TrueHD and DTS-HD audio as lossless multichannel PCM, and needs a receiver or soundbar that accepts multichannel PCM over eARC. If surround plays as stereo, turn it off to use a surround-compatible Dolby Digital Plus bridge instead. For TrueHD tracks that carry Atmos, the TrueHD Atmos setting takes precedence."
        text += " TrueHD Atmos converts TrueHD Atmos tracks so their height channels play: when this Apple TV is connected to a Dolby Atmos receiver or soundbar, Silo decodes the track's Atmos objects, mixes them into a 7.1.4 speaker layout and sends that through the Apple TV's Atmos output, which is why your system shows Dolby Atmos. This is Silo's own conversion, not the original Atmos stream and not Dolby's decoder, and the result is compressed audio, so these tracks are no longer lossless. Turn it off to play them without heights, as lossless 7.1 when Lossless Multichannel Audio is on."
        text += " Deinterlacing applies to interlaced sources such as DVDs and broadcast recordings; Automatic uses this Apple TV's hardware deinterlacer and falls back to software, while Software always deinterlaces on the CPU. Field Rate applies to the hardware deinterlacer only: Full Motion doubles the frame rate (50/60 fps), and Film keeps one frame per field pair."
        return text
    }

    @ViewBuilder
    private var episodesSection: some View {
        TVSettingsSectionHeader("EPISODES")

        TVSettingsToggleRow(
            title: "Auto-Play Next Episode",
            isOn: viewModel.autoPlayNext
        ) {
            let value = !viewModel.autoPlayNext
            viewModel.autoPlayNext = value
            Task { await viewModel.setAutoPlayNext(value) }
        }

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

        TVSettingsToggleRow(
            title: "Skip Credits",
            isOn: viewModel.skipCredits
        ) {
            let value = !viewModel.skipCredits
            viewModel.skipCredits = value
            Task { await viewModel.setSkipCredits(value) }
        }
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
            Task { await viewModel.resetPlaybackDeviceSettings() }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22, weight: .medium))
                Text("Reset Playback Overrides")
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))

        TVSettingsFooter("Resets playback choices for this Apple TV and profile back to the server fallback.")
    }

    // MARK: - Pickers

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        switch kind {
        case .quality:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Quality",
                options: TVSettingsOptions.quality(
                    // A stored pair no preset covers gets its own entry
                    // describing what is actually stored, so the sheet never
                    // highlights a preset the user did not choose.
                    including: viewModel.preferredQualityPresetId == nil
                        ? viewModel.preferredQualityLabel
                        : nil
                ),
                selection: Binding(
                    get: { viewModel.preferredQualityPresetId ?? TVSettingsOptions.customQualityId },
                    set: { value in
                        guard value != TVSettingsOptions.customQualityId else { return }
                        Task { await viewModel.setQualityPreset(value) }
                    }
                ),
                returnFocus: .top
            )
        case .audioLanguage:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Audio Language",
                options: TVSettingsOptions.audioLanguage(viewModel.audioLanguageOptions),
                selection: Binding(
                    get: { viewModel.preferredAudioLanguage },
                    set: { value in
                        viewModel.preferredAudioLanguage = value
                        Task { await viewModel.setPreferredAudioLanguage(value) }
                    }
                ),
                returnFocus: .playbackAudioLanguage
            )
        case .bufferAhead:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Buffer Ahead",
                options: TVSettingsOptions.bufferAhead,
                selection: Binding(
                    get: { viewModel.bufferAhead.rawValue },
                    set: { value in
                        guard let mode = BufferAheadMode(rawValue: value) else { return }
                        viewModel.bufferAhead = mode
                        Task { await viewModel.setBufferAhead(mode) }
                    }
                ),
                returnFocus: .playbackBufferAhead
            )
        case .deinterlaceMode:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Deinterlacing",
                options: TVSettingsOptions.deinterlaceMode,
                selection: Binding(
                    get: { viewModel.deinterlaceMode.rawValue },
                    set: { value in
                        guard let mode = DeinterlacePreference(rawValue: value) else { return }
                        viewModel.deinterlaceMode = mode
                        Task { await viewModel.setDeinterlaceMode(mode) }
                    }
                ),
                returnFocus: .playbackDeinterlaceMode
            )
        case .deinterlaceFieldRate:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Deinterlacing Field Rate",
                options: TVSettingsOptions.deinterlaceFieldRate,
                selection: Binding(
                    get: { viewModel.deinterlaceFieldRate.rawValue },
                    set: { value in
                        guard let rate = DeinterlaceFieldRatePreference(rawValue: value) else {
                            return
                        }
                        viewModel.deinterlaceFieldRate = rate
                        Task { await viewModel.setDeinterlaceFieldRate(rate) }
                    }
                ),
                returnFocus: .playbackDeinterlaceFieldRate
            )
        case .nextUpPrompt:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Show Next Up",
                options: TVSettingsOptions.nextUpPrompt,
                selection: Binding(
                    get: { String(viewModel.nextUpPromptSeconds) },
                    set: { value in
                        guard let seconds = Int(value) else { return }
                        viewModel.nextUpPromptSeconds = seconds
                        Task { await viewModel.setNextUpPromptSeconds(seconds) }
                    }
                ),
                returnFocus: .playbackNextUpPrompt
            )
        case .introSkipMode:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Skip Intros",
                options: TVSettingsOptions.introSkipMode,
                selection: Binding(
                    get: { viewModel.introSkipMode.wireValue },
                    set: { value in
                        guard let mode = IntroSkipMode(wireValue: value) else { return }
                        viewModel.introSkipMode = mode
                        Task { await viewModel.setIntroSkipMode(mode) }
                    }
                ),
                returnFocus: .playbackIntroSkipMode
            )
        case .skipInterval(let media, let direction):
            TVSettingsPickerRequest(
                id: kind.id,
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

    enum PickerKind: Identifiable {
        case quality
        case audioLanguage
        case bufferAhead
        case deinterlaceMode
        case deinterlaceFieldRate
        case nextUpPrompt
        case introSkipMode
        case skipInterval(SeekMedia, SeekDirection)

        var id: String {
            switch self {
            case .quality: return "quality"
            case .audioLanguage: return "audioLanguage"
            case .bufferAhead: return "bufferAhead"
            case .deinterlaceMode: return "deinterlaceMode"
            case .deinterlaceFieldRate: return "deinterlaceFieldRate"
            case .nextUpPrompt: return "nextUpPrompt"
            case .introSkipMode: return "introSkipMode"
            case .skipInterval(let media, let direction):
                return "skipInterval.\(media.rawValue).\(direction.rawValue)"
            }
        }
    }
}
#endif
