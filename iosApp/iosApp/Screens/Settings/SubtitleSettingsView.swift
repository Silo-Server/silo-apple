#if !os(tvOS)
import SwiftUI

/// Subtitle preferences sub-screen — a native grouped list. The
/// language / behavior / forced trio is profile-wide on the server;
/// the appearance block saves for the profile too, unless this device
/// keeps its own ("Only on This Device").
struct SubtitleSettingsView: View {
    let viewModel: SettingsViewModel
    /// The app language, so a switch re-renders the labels.
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            profileBackedSection
            if AICapabilities.shared.metadataEnabled {
                metadataLanguageSection
            }
            if viewModel.prefs.hasHeldChanges {
                HeldSettingChangesSection(
                    retry: { await viewModel.prefs.retryHeldChanges() },
                    discard: { await viewModel.prefs.discardHeldChanges() }
                )
            }
            appearanceSection
        }
        .settingsListChrome()
        .navigationTitle(Text(.settingsSubtitles))
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }

    // MARK: - Metadata language (server-backed, AI-gated)

    @ViewBuilder
    private var metadataLanguageSection: some View {
        Section {
            Picker(
                .settingsControlMetadataLanguage,
                selection: Binding(
                    get: { viewModel.prefs.preferredMetadataLanguage },
                    set: { value in Task { await viewModel.prefs.setPreferredMetadataLanguage(value) } }
                )
            ) {
                Text(verbatim:
                    SettingPresentationMetadata.unsetLabel(
                        for: .catalogMetadataLanguage, fallback: "Library default", language: AppLanguage.language(of: locale)
                    )
                ).tag(PlaybackPrefSentinel.none)
                ForEach(viewModel.metadataLanguageOptions) { option in
                    Text(verbatim: option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
        } header: {
            Text(.settingsSectionMetadata)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(.settingsMetadataLanguageNote)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .disabled(viewModel.prefs.serverUpgradeRequired)
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Profile prefs (server-backed)

    @ViewBuilder
    private var profileBackedSection: some View {
        Section {
            Picker(
                .settingsControlLanguage,
                selection: Binding(
                    get: { viewModel.prefs.subtitleLanguage },
                    set: { value in Task { await viewModel.prefs.setSubtitleLanguage(value) } }
                )
            ) {
                Text(verbatim:
                    SettingPresentationMetadata.unsetLabel(
                        for: .playbackSubtitleLanguage, fallback: "None", language: AppLanguage.language(of: locale)
                    )
                ).tag(PlaybackPrefSentinel.none)
                ForEach(viewModel.subtitleLanguageOptions) { option in
                    Text(verbatim: option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Picker(
                .settingsControlBehavior,
                selection: Binding(
                    get: { viewModel.prefs.subtitleMode },
                    set: { value in Task { await viewModel.prefs.setSubtitleMode(value) } }
                )
            ) {
                ForEach(SubtitleMode.allCases, id: \.rawValue) { mode in
                    Text(verbatim: mode.displayLabel).tag(mode.rawValue)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Toggle(
                .settingsControlForced,
                isOn: Binding(
                    get: { viewModel.prefs.showForcedSubtitles == "on" },
                    set: { isOn in Task { await viewModel.prefs.setShowForcedSubtitles(isOn) } }
                )
            )
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)
        } header: {
            Text(.settingsSubtitlesProfile)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.subtitleMatchesSystemAppearance {
                    Text(.settingsSubtitlesFollowsDevicePrefs)
                } else if viewModel.prefs.serverUpgradeRequired {
                    Text(ProfilePrefsEditor.serverUpgradeMessage)
                        .foregroundStyle(Color.siloError)
                } else {
                    Text(.settingsSubtitlesLanguageFooter)
                    if let overrideMessage = viewModel.prefs.subtitleProfileOverrideMessage {
                        Text(.settingsSubtitlesOverrideActive(AppLanguage.string(overrideMessage, locale: locale)))
                            .foregroundStyle(Color.siloWarning)
                    }
                }
                if let state = viewModel.prefs.saveState,
                   !(viewModel.prefs.serverUpgradeRequired && state == .serverUpgradeRequired) {
                    saveStateView(state)
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .disabled(viewModel.prefs.serverUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Appearance (profile, with an optional device override)

    private var manualEditingDisabled: Bool {
        viewModel.subtitleMatchesSystemAppearance
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            SubtitleAppearancePreview(appearance: viewModel.effectiveSubtitleAppearance)
                .listRowInsets(EdgeInsets())
        } header: {
            Text(.settingsSubtitlesAppearance)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            if !manualEditingDisabled && viewModel.subtitleAppearance.isLowLegibilityRisk {
                Text(.settingsSubtitlesLowLegibility)
                    .foregroundStyle(Color.siloError)
            }
        }
        .listRowBackground(Color.siloGroupedCell)

        Section {
            Toggle(
                .settingsSubtitlesUseDeviceSettings,
                isOn: Binding(
                    get: { viewModel.subtitleMatchesSystemAppearance },
                    set: { viewModel.setSubtitleMatchesSystemAppearance($0) }
                )
            )
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            Toggle(
                .settingsSubtitlesOnlyOnThisDevice,
                isOn: Binding(
                    get: { viewModel.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                )
            )
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)
            .disabled(manualEditingDisabled)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.subtitleMatchesSystemAppearance {
                    Text(.settingsSubtitlesFollowsSystemAppearance)
                } else if viewModel.subtitleUsesDeviceAppearanceOverride {
                    Text(.settingsSubtitlesScopeDeviceOnly)
                } else {
                    Text(.settingsSubtitlesScopeProfile)
                }
                if viewModel.subtitleMatchesSystemAppearance {
                    Text(.settingsSubtitlesAuthoredStyleSystem)
                } else {
                    Text(.settingsSubtitlesAuthoredStyle)
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)

        Section {
            Picker(.settingsSubtitlesFontSize, selection: appearanceBinding(\.fontSize)) {
                ForEach(SubtitleFontSizePreset.allCases) { option in
                    Text(verbatim: option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Picker(.settingsSubtitlesFontFamily, selection: appearanceBinding(\.fontFamily)) {
                ForEach(SubtitleFontFamilyPreset.allCases) { option in
                    Text(verbatim: option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            ColorChoicePicker(
                title: .settingsSubtitlesFontColor,
                colors: SubtitleAppearance.fontColors,
                selection: appearanceBinding(\.fontColor)
            )

            if viewModel.offersSubtitleTextOpacity {
                PercentField(
                    label: AppLanguage.string(.settingsSubtitlesOpacity, locale: locale),
                    accessibilityLabelText: AppLanguage.string(.settingsSubtitlesTextOpacity, locale: locale),
                    min: 1,
                    value: viewModel.subtitleAppearance.textOpacity
                ) { newValue in
                    var next = viewModel.subtitleAppearance
                    if next.textOpacity == newValue { return }
                    next.textOpacity = newValue
                    Task { await viewModel.setSubtitleAppearance(next) }
                }
                .foregroundStyle(Color.siloOnSurface)
            }

            Toggle(.settingsSubtitlesTextOutline, isOn: appearanceBinding(\.textOutline))
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            ColorChoicePicker(
                title: .settingsSubtitlesOutlineColor,
                colors: SubtitleAppearance.outlineColors,
                selection: appearanceBinding(\.textOutlineColor)
            )
            .disabled(!viewModel.subtitleAppearance.textOutline)
            .opacity(viewModel.subtitleAppearance.textOutline ? 1 : 0.45)
        } header: {
            Text(.settingsSubtitlesText)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)

        Section {
            Picker(.settingsSubtitlesBackgroundStyleShort, selection: backgroundStyleBinding) {
                ForEach(SubtitleBackgroundStylePreset.selectableCases) { option in
                    Text(verbatim: option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            opacityRow
                .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
                .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)

            ColorChoicePicker(
                title: .settingsSubtitlesBackgroundColorShort,
                colors: SubtitleAppearance.backgroundColors,
                selection: appearanceBinding(\.backgroundColor)
            )
            .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
            .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)
        } header: {
            Text(.settingsSubtitlesBackground)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)

        Section {
            Picker(.settingsSubtitlesPosition, selection: appearanceBinding(\.position)) {
                ForEach(SubtitlePositionPreset.allCases) { option in
                    Text(verbatim: option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
        } header: {
            Text(.settingsSubtitlesLayout)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)
    }

    /// Choosing Box with a fully transparent background would render
    /// nothing; give it the default opacity so the choice takes effect.
    private var backgroundStyleBinding: Binding<SubtitleBackgroundStylePreset> {
        Binding(
            get: { viewModel.subtitleAppearance.backgroundStyle },
            set: { newValue in
                var next = viewModel.subtitleAppearance
                if next.backgroundStyle == newValue { return }
                next.backgroundStyle = newValue
                if newValue == .box && next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var opacityRow: some View {
        PercentField(
            label: AppLanguage.string(.settingsSubtitlesOpacity, locale: locale),
            accessibilityLabelText: AppLanguage.string(.settingsSubtitlesBackgroundOpacity, locale: locale),
            min: 0,
            value: viewModel.subtitleAppearance.backgroundOpacity
        ) { newValue in
            var next = viewModel.subtitleAppearance
            if next.backgroundOpacity == newValue { return }
            next.backgroundOpacity = newValue
            Task { await viewModel.setSubtitleAppearance(next) }
        }
        .foregroundStyle(Color.siloOnSurface)
    }

    private func appearanceBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<SubtitleAppearance, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath] },
            set: { newValue in
                var next = viewModel.subtitleAppearance
                if next[keyPath: keyPath] == newValue { return }
                next[keyPath: keyPath] = newValue
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    @ViewBuilder
    private func saveStateView(_ state: ProfilePrefsEditor.PrefSaveState) -> some View {
        switch state {
        case .saving:
            Text(.settingsSaving)
        case .saved:
            Text(.settingsSubtitlesSaved)
        case .failed(let message):
            Text(.settingsSubtitlesSaveFailed(AppLanguage.string(message, locale: locale)))
                .foregroundStyle(Color.siloError)
        case .serverUpgradeRequired:
            Text(ProfilePrefsEditor.serverUpgradeMessage)
                .foregroundStyle(Color.siloError)
        case .held:
            Text(.settingsSubtitlesHeldNotice)
                .foregroundStyle(Color.siloWarning)
        }
    }
}

// MARK: - Color choice row

/// A named-color picker rendered as a standard row so every option gets a
/// full-size tap target.
private struct ColorChoicePicker: View {
    let title: LocalizedStringResource
    let colors: [(hex: String, label: String)]
    @Binding var selection: String

    var body: some View {
        Picker(selection: normalizedSelection) {
            ForEach(colors, id: \.hex) { color in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.siloSecondaryText.opacity(0.35), lineWidth: 1)
                        )
                    Text(verbatim: color.label)
                }
                .tag(color.hex)
            }
        } label: {
            Text(title)
                .foregroundStyle(Color.siloOnSurface)
        }
        .settingsPickerStyle()
    }

    /// Stored hex values may differ in case from the option list.
    private var normalizedSelection: Binding<String> {
        Binding(
            get: {
                colors.first(where: { $0.hex.caseInsensitiveCompare(selection) == .orderedSame })?.hex
                    ?? selection.lowercased()
            },
            set: { selection = $0 }
        )
    }
}
#endif
