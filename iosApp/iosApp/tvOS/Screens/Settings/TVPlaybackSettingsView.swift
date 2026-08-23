#if os(tvOS)
import SwiftUI

/// Playback pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. The root view owns modal picker
/// presentation so only one focus graph is active at a time.
struct TVPlaybackSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            streamingSection
            episodesSection
            resetSection
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
        text += " Lossless Multichannel Audio delivers TrueHD and DTS-HD audio as lossless multichannel PCM, and needs a receiver or soundbar that accepts multichannel PCM over eARC. If surround plays as stereo, turn it off to use a surround-compatible Dolby Digital Plus bridge instead."
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

        TVSettingsToggleRow(
            title: "Skip Intros",
            isOn: viewModel.skipIntros
        ) {
            let value = !viewModel.skipIntros
            viewModel.skipIntros = value
            Task { await viewModel.setSkipIntros(value) }
        }

        TVSettingsToggleRow(
            title: "Skip Credits",
            isOn: viewModel.skipCredits
        ) {
            let value = !viewModel.skipCredits
            viewModel.skipCredits = value
            Task { await viewModel.setSkipCredits(value) }
        }
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
        }
    }

    enum PickerKind: String, Identifiable {
        case quality
        case audioLanguage
        case bufferAhead
        case deinterlaceMode
        case deinterlaceFieldRate
        case nextUpPrompt

        var id: String { rawValue }
    }
}
#endif
