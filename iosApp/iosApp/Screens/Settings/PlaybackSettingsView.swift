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
                    Task { await viewModel.setQualityPreset(newValue) }
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
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Audio Language", selection: Binding(
                get: { viewModel.preferredAudioLanguage },
                set: { newValue in
                    viewModel.preferredAudioLanguage = newValue
                    Task { await viewModel.setPreferredAudioLanguage(newValue) }
                }
            )) {
                Text(
                    SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.unsetLabel
                        ?? "No preference"
                ).tag("")
                ForEach(viewModel.audioLanguageOptions) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle("Dolby Vision", isOn: Binding(
                get: { viewModel.dolbyVisionEnabled },
                set: { enabled in
                    viewModel.dolbyVisionEnabled = enabled
                    Task { await viewModel.setDolbyVisionEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            Toggle("Seek Cache", isOn: Binding(
                get: { viewModel.seekCacheEnabled },
                set: { enabled in
                    viewModel.seekCacheEnabled = enabled
                    Task { await viewModel.setSeekCacheEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            Picker("Buffer Ahead", selection: Binding(
                get: { viewModel.bufferAhead },
                set: { newValue in
                    viewModel.bufferAhead = newValue
                    Task { await viewModel.setBufferAhead(newValue) }
                }
            )) {
                ForEach(BufferAheadMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle("Lossless Multichannel Audio", isOn: Binding(
                get: { viewModel.losslessAudioEnabled },
                set: { enabled in
                    viewModel.losslessAudioEnabled = enabled
                    Task { await viewModel.setLosslessAudioEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            Toggle("TrueHD Atmos", isOn: Binding(
                get: { viewModel.trueHDAtmosEnabled },
                set: { enabled in
                    viewModel.trueHDAtmosEnabled = enabled
                    Task { await viewModel.setTrueHDAtmosEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            Picker("Deinterlacing", selection: Binding(
                get: { viewModel.deinterlaceMode },
                set: { newValue in
                    viewModel.deinterlaceMode = newValue
                    Task { await viewModel.setDeinterlaceMode(newValue) }
                }
            )) {
                ForEach(DeinterlacePreference.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Deinterlacing Field Rate", selection: Binding(
                get: { viewModel.deinterlaceFieldRate },
                set: { newValue in
                    viewModel.deinterlaceFieldRate = newValue
                    Task { await viewModel.setDeinterlaceFieldRate(newValue) }
                }
            )) {
                ForEach(DeinterlaceFieldRatePreference.allCases, id: \.self) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            // iOS only: the engine's background policy is driven by the app
            // lifecycle notifications, which macOS does not post — a toggle
            // there would control nothing.
            #if os(iOS)
            Toggle("Background Playback", isOn: Binding(
                get: { viewModel.backgroundPlaybackEnabled },
                set: { enabled in
                    viewModel.backgroundPlaybackEnabled = enabled
                    Task { await viewModel.setBackgroundPlaybackEnabled(enabled) }
                }
            ))
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
            Toggle("Auto-Play Next Episode", isOn: Binding(
                get: { viewModel.autoPlayNext },
                set: { enabled in
                    viewModel.autoPlayNext = enabled
                    Task { await viewModel.setAutoPlayNext(enabled) }
                }
            ))
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            Picker("Show Next Up", selection: Binding(
                get: { viewModel.nextUpPromptSeconds },
                set: { newValue in
                    viewModel.nextUpPromptSeconds = newValue
                    Task { await viewModel.setNextUpPromptSeconds(newValue) }
                }
            )) {
                ForEach(nextUpPromptOptions, id: \.0) { seconds, label in
                    Text(label).tag(seconds)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            // Three-way, not a switch: the boolean this replaced could not
            // say "never". Labels and semantics are fixed by the contract.
            Picker("Skip Intros", selection: Binding(
                get: { viewModel.introSkipMode },
                set: { mode in
                    viewModel.introSkipMode = mode
                    Task { await viewModel.setIntroSkipMode(mode) }
                }
            )) {
                ForEach(IntroSkipMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle("Skip Credits", isOn: Binding(
                get: { viewModel.skipCredits },
                set: { enabled in
                    viewModel.skipCredits = enabled
                    Task { await viewModel.setSkipCredits(enabled) }
                }
            ))
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
