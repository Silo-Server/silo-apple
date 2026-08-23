#if !os(tvOS)
import SwiftUI

/// Playback preferences sub-screen — a native grouped list in the
/// style of the iOS Settings app: plain rows, navigation-link pickers,
/// and footers for the fine print.
struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            SettingsPageHeader(
                title: "Playback",
                subtitle: "Quality, language, and episode behavior for this device.",
                systemImage: "play.fill"
            )
            .settingsPageHeaderRow()

            streamingSection
            behaviorSection
            resetSection
        }
        .settingsListChrome()
        .navigationTitle("")
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumToolbarColorSchemeDark()
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
            .foregroundStyle(Color.continuumOnSurface)
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
            .foregroundStyle(Color.continuumOnSurface)
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
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)

            Toggle("Seek Cache", isOn: Binding(
                get: { viewModel.seekCacheEnabled },
                set: { enabled in
                    viewModel.seekCacheEnabled = enabled
                    Task { await viewModel.setSeekCacheEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)

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
            .foregroundStyle(Color.continuumOnSurface)
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
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)

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
            .foregroundStyle(Color.continuumOnSurface)
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
            .foregroundStyle(Color.continuumOnSurface)
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
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)
            #endif
        } header: {
            Text("Streaming")
                .foregroundStyle(Color.continuumSecondaryText)
        } footer: {
            Text(streamingFooterText)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }

    private var streamingFooterText: String {
        // Leads with what the chosen quality actually means, since the preset
        // labels ("1080p High") name a tier without stating its bitrate.
        var text = "\(viewModel.preferredQualityLabel). "
        if let preset = SiloQualityPresets.preset(id: viewModel.preferredQualityPresetId) {
            text = "\(preset.description) "
        }
        text += "Turn off Dolby Vision to play Dolby Vision titles as HDR10 instead. Profile 5 titles have no HDR10-compatible layer and always play in Dolby Vision."
        text += " Seek Cache keeps recently streamed video in temporary storage during playback so skipping forward and back is instant; it is cleared when playback ends."
        text += " Buffer Ahead controls how much video is downloaded ahead of the playhead; longer windows ride out network dropouts, and Unlimited buffers as much as fits in temporary storage, which is cleared when playback ends."
        text += " Lossless Multichannel Audio delivers TrueHD and DTS-HD audio as lossless multichannel PCM, and needs a receiver or soundbar that accepts multichannel PCM over eARC. If surround plays as stereo, turn it off to use a surround-compatible Dolby Digital Plus bridge instead."
        text += " Deinterlacing applies to interlaced sources such as DVDs and broadcast recordings; Automatic uses this device's hardware deinterlacer and falls back to software, while Software always deinterlaces on the CPU. Field Rate applies to the hardware deinterlacer only: Full Motion doubles the frame rate (50/60 fps), and Film keeps one frame per field pair."
        #if os(iOS)
        text += " Background Playback continues audio when the app moves to the background, including Picture in Picture; turning it off stops playback when you leave the app. Audiobooks always keep playing in the background."
        #endif
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
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)

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
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle("Skip Intros", isOn: Binding(
                get: { viewModel.skipIntros },
                set: { enabled in
                    viewModel.skipIntros = enabled
                    Task { await viewModel.setSkipIntros(enabled) }
                }
            ))
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)

            Toggle("Skip Credits", isOn: Binding(
                get: { viewModel.skipCredits },
                set: { enabled in
                    viewModel.skipCredits = enabled
                    Task { await viewModel.setSkipCredits(enabled) }
                }
            ))
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)
        } header: {
            Text("Episodes")
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset Playback Overrides", role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            }
        } footer: {
            Text("Resets playback choices for this device and profile back to the server fallback.")
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
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
