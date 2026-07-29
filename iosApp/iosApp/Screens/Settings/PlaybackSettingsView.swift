#if !os(tvOS)
import SwiftUI

/// Playback preferences sub-screen — a native grouped list in the
/// style of the iOS Settings app: plain rows, navigation-link pickers,
/// and footers for the fine print.
struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            streamingSection
            behaviorSection
            resetSection
        }
        .continuumGroupedListStyle()
        .continuumScrollContentBackgroundHidden()
        .background(Color.continuumBackground.ignoresSafeArea())
        .navigationTitle("Playback")
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
                ForEach(audioLanguageOptions, id: \.0) { tag, label in
                    Text(label).tag(tag)
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

            if viewModel.dolbyVisionEnabled {
                Toggle("Profile 7 HDR10 Fallback", isOn: Binding(
                    get: { viewModel.preferProfile7HDR10Fallback },
                    set: { enabled in
                        viewModel.preferProfile7HDR10Fallback = enabled
                        Task { await viewModel.setPreferProfile7HDR10Fallback(enabled) }
                    }
                ))
                .foregroundStyle(Color.continuumOnSurface)
                .tint(.continuumAccent)
            }

            Toggle("Seek Cache", isOn: Binding(
                get: { viewModel.seekCacheEnabled },
                set: { enabled in
                    viewModel.seekCacheEnabled = enabled
                    Task { await viewModel.setSeekCacheEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumAccent)
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
        if viewModel.dolbyVisionEnabled {
            text += " The fallback plays Dolby Vision Profile 7 as HDR10 on this device."
        }
        text += " Seek Cache keeps recently streamed video in temporary storage during playback so skipping forward and back is instant; it is cleared when playback ends."
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

    private var audioLanguageOptions: [(String, String)] {
        [
            ("", "Default"),
            ("en", "English"),
            ("es", "Spanish"),
            ("fr", "French"),
            ("de", "German"),
            ("it", "Italian"),
            ("pt", "Portuguese"),
            ("ja", "Japanese"),
            ("ko", "Korean"),
        ]
    }

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
