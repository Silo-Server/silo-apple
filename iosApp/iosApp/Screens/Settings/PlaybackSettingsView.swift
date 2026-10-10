#if !os(tvOS)
import SwiftUI

/// Playback preferences sub-screen — a native grouped list in the
/// style of the iOS Settings app: plain rows, navigation-link pickers,
/// and footers for the fine print.
struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var spoilers = EpisodeSpoilerPreferences.shared
    @State private var showUseProfileSettingsConfirmation = false

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
            // Hidden entirely on servers that do not serve the two keys.
            if spoilers.showsSettings {
                EpisodeSpoilerSettingsSection(store: spoilers)
            }
            SeekIntervalSettingsSections()
            resetSection
        }
        .task { await spoilers.refresh() }
        .settingsListChrome()
        .navigationTitle("Playback")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
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

    // MARK: - Streaming

    private var streamingSection: some View {
        Section {
            choiceRow("Quality", .quality, value: viewModel.preferredQualityLabel, options: qualityChoices)

            choiceRow("Audio Language", .audioLanguage, value: audioLanguageLabel, options: audioLanguageChoices)

            Toggle("HDR", isOn: $viewModel.hdrEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Toggle("Dolby Vision", isOn: $viewModel.dolbyVisionEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
                .disabled(!viewModel.hdrEnabled)

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
        text += " " + SettingsViewModel.hdrFooterText
        text += " If surround plays as stereo, turn off Lossless Multichannel Audio."
        text += " TrueHD Atmos adds height channels but plays those tracks as compressed audio."
        return text
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            // On / Off choices rather than switches: a switch has no third
            // position for going back to the profile's choice.
            choiceRow(
                "Auto-Play Next Episode",
                .autoPlayNext,
                value: viewModel.autoPlayNext ? "On" : "Off",
                options: onOffChoices
            )

            choiceRow(
                "Show Next Up",
                .nextUpPrompt,
                value: nextUpPromptOptions.first { $0.0 == viewModel.nextUpPromptSeconds }?.1
                    ?? "\(viewModel.nextUpPromptSeconds) seconds before end",
                options: nextUpPromptOptions.map { SettingsChoice(id: String($0.0), label: $0.1) }
            )

            // Three-way (labels fixed by the contract).
            choiceRow(
                "Skip Intros",
                .introSkipMode,
                value: viewModel.introSkipMode.label,
                options: IntroSkipMode.allCases.map { SettingsChoice(id: $0.wireValue, label: $0.label) }
            )

            choiceRow(
                "Skip Credits",
                .autoSkipCredits,
                value: viewModel.skipCredits ? "On" : "Off",
                options: onOffChoices
            )
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

    // MARK: - Use Profile Settings

    private var resetSection: some View {
        Section {
            Button("Use Profile Settings", role: .destructive) {
                showUseProfileSettingsConfirmation = true
            }
        } footer: {
            Text("Removes the settings changed on this device, so it uses your profile's settings again.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Options

    /// A profile-backed row. The row always shows the value that applies,
    /// wherever it comes from; the choice list leads with "Use Profile
    /// Setting", checked while this device has no value of its own.
    private func choiceRow(
        _ title: String,
        _ setting: ProfileBackedPlaybackSetting,
        value: String,
        options: [SettingsChoice]
    ) -> some View {
        SettingsChoiceRow(
            title: title,
            value: value,
            options: [
                SettingsChoice(
                    id: SettingsViewModel.useProfileSettingTag,
                    label: SettingsViewModel.useProfileSettingLabel
                ),
            ] + options,
            selection: Binding(
                get: { viewModel.playbackSelectionTag(setting) },
                set: { viewModel.selectPlayback($0, for: setting) }
            )
        )
    }

    private var qualityChoices: [SettingsChoice] {
        // A pair no preset covers — set through the API, or written by a
        // client whose ladder has a rung this table does not — gets its own
        // entry describing what is actually stored, rather than the list
        // checking a preset the user never chose.
        var choices: [SettingsChoice] = []
        if !viewModel.usesProfileSetting(.quality), viewModel.preferredQualityPresetId == nil {
            choices.append(SettingsChoice(
                id: SettingsViewModel.customQualityTag,
                label: viewModel.preferredQualityLabel
            ))
        }
        return choices + SiloQualityPresets.all.map { SettingsChoice(id: $0.id, label: $0.label) }
    }

    private var noAudioLanguageLabel: String {
        SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.unsetLabel ?? "No preference"
    }

    private var audioLanguageLabel: String {
        let code = viewModel.preferredAudioLanguage
        guard !code.isEmpty else { return noAudioLanguageLabel }
        return viewModel.audioLanguageOptions.first { $0.code == code }?.label ?? code
    }

    private var audioLanguageChoices: [SettingsChoice] {
        let stored = viewModel.hasStoredNoAudioLanguagePreference
            ? [SettingsChoice(id: "", label: noAudioLanguageLabel)]
            : []
        return stored + viewModel.audioLanguageOptions.map { SettingsChoice(id: $0.code, label: $0.label) }
    }

    private var onOffChoices: [SettingsChoice] {
        [
            SettingsChoice(id: SettingsViewModel.onTag, label: "On"),
            SettingsChoice(id: SettingsViewModel.offTag, label: "Off"),
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

struct SettingsChoice: Identifiable, Hashable {
    let id: String
    let label: String
}

/// A settings row whose trailing text is the value that applies, which a
/// native Picker cannot show once its selected option is "Use Profile
/// Setting". Looks like the navigation-link pickers beside it on iOS and a
/// menu picker on macOS.
struct SettingsChoiceRow: View {
    let title: String
    let value: String
    let options: [SettingsChoice]
    @Binding var selection: String

    var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(value)
            }
            .fixedSize()
        }
        .foregroundStyle(Color.siloOnSurface)
        #else
        NavigationLink {
            SettingsChoiceList(title: title, options: options, selection: $selection)
        } label: {
            LabeledContent(title, value: value)
        }
        .foregroundStyle(Color.siloOnSurface)
        #endif
    }
}

#if !os(macOS)
/// The pushed choice list, in the style of the navigation-link picker it
/// stands in for: a checkmark on the selected row, and back on choosing.
struct SettingsChoiceList: View {
    let title: String
    let options: [SettingsChoice]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.id
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(Color.siloOnSurface)
                            Spacer(minLength: 16)
                            if option.id == selection {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(option.id == selection ? .isSelected : [])
                }
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .navigationTitle(title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }
}
#endif
#endif
