#if !os(tvOS)
import SwiftUI

/// Playback preferences sub-screen — a native grouped list in the
/// style of the iOS Settings app: plain rows, navigation-link pickers,
/// and footers for the fine print.
struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            if viewModel.hasHeldPlaybackChanges {
                HeldSettingChangesSection(
                    retry: { await viewModel.retryHeldPlaybackChanges() },
                    discard: { await viewModel.discardHeldPlaybackChanges() },
                    message: viewModel.heldPlaybackChangesMessage
                )
            }
            if viewModel.playbackChangeWasRejected {
                rejectedChangeSection
            }
            streamingSection
            behaviorSection
            SeekIntervalSettingsSections()
            resetSection
        }
        .settingsListChrome()
        .navigationTitle("Playback")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }

    // MARK: - Streaming

    private var streamingSection: some View {
        Section {
            Picker("Quality", selection: Binding(
                get: { viewModel.preferredQualityPresetId ?? Self.customPresetTag },
                set: { newValue in
                    guard newValue != Self.customPresetTag else { return }
                    viewModel.setQualityPreset(newValue)
                }
            )) {
                // A pair no preset covers — set through the API, or written by
                // a client whose ladder has a rung this table does not — gets
                // its own disabled entry describing what is actually stored,
                // rather than the picker showing a preset the user never chose.
                if viewModel.preferredQualityPresetId == nil {
                    Text(viewModel.preferredQualityLabel)
                        .tag(Self.customPresetTag)
                }
                ForEach(SiloQualityPresets.all) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Picker("Audio Language", selection: $viewModel.preferredAudioLanguage) {
                Text(
                    SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.unsetLabel
                        ?? "No preference"
                ).tag("")
                ForEach(viewModel.audioLanguageOptions) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Toggle("Dolby Vision", isOn: $viewModel.dolbyVisionEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Toggle("Seek Cache", isOn: $viewModel.seekCacheEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Picker("Buffer Ahead", selection: $viewModel.bufferAhead) {
                ForEach(BufferAheadMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Toggle("Lossless Multichannel Audio", isOn: $viewModel.losslessAudioEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Toggle("TrueHD Atmos", isOn: $viewModel.trueHDAtmosEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Picker("Deinterlacing", selection: $viewModel.deinterlaceMode) {
                ForEach(DeinterlacePreference.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Picker("Deinterlacing Field Rate", selection: $viewModel.deinterlaceFieldRate) {
                ForEach(DeinterlaceFieldRatePreference.allCases, id: \.self) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            // iOS only: the engine's background policy is driven by the app
            // lifecycle notifications, which macOS does not post — a toggle
            // there would control nothing.
            #if os(iOS)
            Toggle("Background Playback", isOn: $viewModel.backgroundPlaybackEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
            #endif
        } header: {
            Text("Streaming")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(streamingFooterText)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var streamingFooterText: String {
        // Leads with what the chosen quality actually means, since the preset
        // labels ("1080p High") name a tier without stating its bitrate.
        var text = "\(viewModel.preferredQualityLabel)."
        if let preset = SiloQualityPresets.preset(id: viewModel.preferredQualityPresetId) {
            text = preset.description
        }
        text += " If surround plays as stereo, turn off Lossless Multichannel Audio."
        text += " TrueHD Atmos adds height channels but plays those tracks as compressed audio."
        return text
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle("Auto-Play Next Episode", isOn: $viewModel.autoPlayNext)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Picker("Show Next Up", selection: $viewModel.nextUpPromptSeconds) {
                ForEach(nextUpPromptOptions, id: \.0) { seconds, label in
                    Text(label).tag(seconds)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            // Three-way (labels fixed by the contract).
            Picker("Skip Intros", selection: $viewModel.introSkipMode) {
                ForEach(IntroSkipMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Toggle("Skip Credits", isOn: $viewModel.skipCredits)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
        } header: {
            Text("Episodes")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Refused change

    private var rejectedChangeSection: some View {
        Section {
            Button("OK") {
                Task { await viewModel.acknowledgeRejectedPlaybackChange() }
            }
        } header: {
            Text("Not Saved")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(SettingsViewModel.rejectedPlaybackChangeMessage)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset Playback Overrides", role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            }
        } footer: {
            Text("Resets playback choices for this device and profile back to the server fallback.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Options

    /// Tag for the "stored pair matches no preset" entry. Not a preset id, so
    /// selecting it is a no-op rather than a write.
    private static let customPresetTag = "__custom__"

    private var nextUpPromptOptions: [(Int, String)] {
        [
            (0, "At end"),
            (10, "10 seconds before end"),
            (30, "30 seconds before end"),
            (60, "1 minute before end"),
            (120, "2 minutes before end"),
        ]
    }
}
#endif
