#if os(tvOS)
import SwiftUI

/// Playback pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. Option pickers present as full-screen
/// covers (plain sheets render as narrow clipped cards on tvOS 26).
struct TVPlaybackSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    @State private var activePicker: PickerKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            streamingSection
            episodesSection
            resetSection
        }
        .fullScreenCover(item: $activePicker) { kind in
            pickerSheet(for: kind)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var streamingSection: some View {
        TVSettingsSectionHeader("STREAMING")

        TVSettingsPickerRow(
            title: "Quality",
            value: TVSettingsOptions.label(for: viewModel.preferredQuality, in: TVSettingsOptions.quality)
        ) { activePicker = .quality }

        TVSettingsPickerRow(
            title: "Audio Language",
            value: TVSettingsOptions.label(for: viewModel.preferredAudioLanguage, in: TVSettingsOptions.audioLanguage)
        ) { activePicker = .audioLanguage }

        TVSettingsToggleRow(
            title: "Profile 7 HDR10 Fallback",
            isOn: viewModel.preferProfile7HDR10Fallback
        ) {
            let value = !viewModel.preferProfile7HDR10Fallback
            viewModel.preferProfile7HDR10Fallback = value
            Task { await viewModel.setPreferProfile7HDR10Fallback(value) }
        }

        TVSettingsToggleRow(
            title: "Seek Cache",
            isOn: viewModel.seekCacheEnabled
        ) {
            let value = !viewModel.seekCacheEnabled
            viewModel.seekCacheEnabled = value
            Task { await viewModel.setSeekCacheEnabled(value) }
        }

        TVSettingsFooter("The fallback plays Dolby Vision Profile 7 as HDR10 on this Apple TV. Seek Cache keeps recently streamed video in temporary storage during playback so skipping forward and back is instant.")
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
        ) { activePicker = .nextUpPrompt }

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

    @ViewBuilder
    private func pickerSheet(for kind: PickerKind) -> some View {
        switch kind {
        case .quality:
            TVSettingsPickerSheet(
                title: "Quality",
                options: TVSettingsOptions.quality,
                selection: Binding(
                    get: { viewModel.preferredQuality },
                    set: { value in
                        viewModel.preferredQuality = value
                        Task { await viewModel.setPreferredQuality(value) }
                    }
                )
            )
        case .audioLanguage:
            TVSettingsPickerSheet(
                title: "Audio Language",
                options: TVSettingsOptions.audioLanguage,
                selection: Binding(
                    get: { viewModel.preferredAudioLanguage },
                    set: { value in
                        viewModel.preferredAudioLanguage = value
                        Task { await viewModel.setPreferredAudioLanguage(value) }
                    }
                )
            )
        case .nextUpPrompt:
            TVSettingsPickerSheet(
                title: "Show Next Up",
                options: TVSettingsOptions.nextUpPrompt,
                selection: Binding(
                    get: { String(viewModel.nextUpPromptSeconds) },
                    set: { value in
                        guard let seconds = Int(value) else { return }
                        viewModel.nextUpPromptSeconds = seconds
                        Task { await viewModel.setNextUpPromptSeconds(seconds) }
                    }
                )
            )
        }
    }

    enum PickerKind: String, Identifiable {
        case quality
        case audioLanguage
        case nextUpPrompt

        var id: String { rawValue }
    }
}
#endif
