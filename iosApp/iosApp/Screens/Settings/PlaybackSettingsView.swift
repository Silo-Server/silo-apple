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
                get: { viewModel.preferredQuality },
                set: { newValue in
                    viewModel.preferredQuality = newValue
                    Task { await viewModel.setPreferredQuality(newValue) }
                }
            )) {
                ForEach(qualityOptions, id: \.0) { tag, label in
                    Text(label).tag(tag)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Audio Language", selection: Binding(
                get: { viewModel.editorAudioLanguage },
                set: { newValue in
                    viewModel.editorAudioLanguage = newValue
                    Task { await viewModel.saveAudioLanguage() }
                }
            )) {
                Text("No Preference").tag(PlaybackPrefSentinel.none)
                ForEach(PlaybackLanguageOption.options(including: viewModel.editorAudioLanguage)) { option in
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
            VStack(alignment: .leading, spacing: 6) {
                Text(streamingFooterText)
                // Audio Language saves to the server from this section, so its
                // result has to be visible here rather than only on the
                // Subtitles screen.
                if let state = viewModel.prefSaveState {
                    PrefSaveStateLabel(state: state)
                }
            }
            .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }

    private var streamingFooterText: String {
        var text = "Audio Language picks which spoken track starts first; it applies to your profile on every device, not just this one."
        text += " Turn off Dolby Vision to play Dolby Vision titles as HDR10 instead. Profile 5 titles have no HDR10-compatible layer and always play in Dolby Vision."
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
            // Deliberately scoped to "this device": the reset clears the
            // device-scoped rows, and Audio Language is a profile field that it
            // does not touch. The previous wording promised the profile too.
            Text("Resets this device's playback choices back to the server fallback. Audio Language applies to your whole profile and is not affected.")
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }

    // MARK: - Options

    private var qualityOptions: [(String, String)] {
        ApplePlaybackQuality.settingsOptions.map { ($0.id, $0.labelWithBitrate) }
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
