#if os(tvOS)
import SwiftUI

/// Subtitles pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. Profile-wide prefs (language / behavior
/// / forced / metadata language) save through the `ProfilePrefsEditor`
/// `set…` methods their controls call; the appearance block writes a
/// profile value, or this Apple TV's own while its override is on.
struct TVSubtitleSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void
    /// The app language, so a switch re-renders the labels.
    @Environment(\.locale) private var locale
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileSection
            if AICapabilities.shared.metadataEnabled {
                metadataLanguageSection
            }
            appearanceSection
        }
        .alert(Text(.settingsSubtitlesResetTitleApple), isPresented: $showResetConfirmation) {
            Button(.settingsSubtitlesResetConfirm, role: .destructive) {
                Task { await viewModel.setSubtitleAppearance(.default) }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(viewModel.subtitleUsesDeviceAppearanceOverride
                 ? LocalizedStringResource.settingsSubtitlesResetMessageAppleTv
                 : .settingsSubtitlesResetMessageProfile)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var profileSection: some View {
        TVSettingsSectionHeader(.settingsSubtitlesTvHeaderProfile)

        TVSettingsPickerRow(
            title: .settingsControlLanguage,
            value: TVSettingsOptions.label(
                for: viewModel.prefs.subtitleLanguage,
                in: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions, language: AppLanguage.language(of: locale))
            )
        ) { showPicker(.language) }
        .focused(detailFocus, equals: .top)
        .disabled(viewModel.prefs.serverUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)

        TVSettingsPickerRow(
            title: .settingsControlBehavior,
            value: TVSettingsOptions.label(for: viewModel.prefs.subtitleMode, in: TVSettingsOptions.subtitleMode)
        ) { showPicker(.mode) }
        .focused(detailFocus, equals: .subtitleBehavior)
        .disabled(viewModel.prefs.serverUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)

        TVSettingsToggleRow(
            title: .settingsControlForced,
            isOn: viewModel.prefs.showForcedSubtitles == "on"
        ) {
            Task { await viewModel.prefs.setShowForcedSubtitles(viewModel.prefs.showForcedSubtitles != "on") }
        }
        .disabled(viewModel.prefs.serverUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)

        if viewModel.subtitleMatchesSystemAppearance {
            TVSettingsFooter(.settingsSubtitlesFollowsDevicePrefsAppleTv)
        } else if viewModel.prefs.serverUpgradeRequired {
            TVSettingsWarningFooter(ProfilePrefsEditor.serverUpgradeMessage)
        } else {
            TVSettingsFooter(.settingsSubtitlesLanguageFooter)
            if let overrideMessage = viewModel.prefs.subtitleProfileOverrideMessage {
                TVSettingsFooter(.settingsSubtitlesOverrideActive(AppLanguage.string(overrideMessage, locale: locale)))
            }
        }
        prefSaveFooter
        if viewModel.prefs.hasHeldChanges {
            TVHeldSettingChangesRows(
                retry: { await viewModel.prefs.retryHeldChanges() },
                discard: { await viewModel.prefs.discardHeldChanges() }
            )
        }
    }

    @ViewBuilder
    private var metadataLanguageSection: some View {
        TVSettingsSectionHeader(.settingsSubtitlesTvHeaderMetadata)

        TVSettingsPickerRow(
            title: .settingsControlMetadataLanguage,
            value: TVSettingsOptions.label(
                for: viewModel.prefs.preferredMetadataLanguage,
                in: TVSettingsOptions.metadataLanguage(viewModel.metadataLanguageOptions, language: AppLanguage.language(of: locale))
            )
        ) { showPicker(.metadataLanguage) }
        .focused(detailFocus, equals: .subtitleMetadataLanguage)
        .disabled(viewModel.prefs.serverUpgradeRequired)

        TVSettingsFooter(.settingsMetadataLanguageNote)
    }

    @ViewBuilder
    private var appearanceSection: some View {
        TVSettingsSectionHeader(.settingsSubtitlesTvHeaderAppearance)

        TVSettingsSubtitlePreview(appearance: viewModel.effectiveSubtitleAppearance)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

        if !viewModel.subtitleMatchesSystemAppearance
            && viewModel.subtitleAppearance.isLowLegibilityRisk {
            TVSettingsFooter(.settingsSubtitlesLowLegibility)
        }

        TVSettingsToggleRow(
            title: .settingsSubtitlesUseDeviceSettings,
            isOn: viewModel.subtitleMatchesSystemAppearance
        ) {
            let enabled = !viewModel.subtitleMatchesSystemAppearance
            viewModel.setSubtitleMatchesSystemAppearance(enabled)
        }
        .focused(detailFocus, equals: .subtitleUseDeviceSettings)

        TVSettingsToggleRow(
            title: .settingsSubtitlesOnlyOnThisAppleTv,
            isOn: viewModel.subtitleUsesDeviceAppearanceOverride
        ) {
            let enabled = !viewModel.subtitleUsesDeviceAppearanceOverride
            Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
        }
        .disabled(viewModel.subtitleMatchesSystemAppearance)

        TVSettingsNestedGroup(
            enabled: appearanceEditable,
            disabledHint: .settingsSubtitlesUseDeviceSettingsLockedHint
        ) {
            pickerRow(.settingsSubtitlesFontSize, options: TVSettingsOptions.subtitleSize,
                      selection: viewModel.subtitleAppearance.fontSize.rawValue, kind: .fontSize)
            pickerRow(.settingsSubtitlesFontFamily, options: TVSettingsOptions.fontFamily,
                      selection: viewModel.subtitleAppearance.fontFamily.rawValue, kind: .fontFamily)
            pickerRow(.settingsSubtitlesFontColor, options: TVSettingsOptions.fontColor,
                      selection: viewModel.subtitleAppearance.fontColor.lowercased(), kind: .fontColor)

            if viewModel.offersSubtitleTextOpacity {
                TVSettingsPickerRow(
                    title: .settingsSubtitlesTextOpacity,
                    value: .verbatim("\(viewModel.subtitleAppearance.textOpacity)%")
                ) {
                    guard appearanceEditable else { return }
                    showPicker(.textOpacity)
                }
                .focused(detailFocus, equals: .subtitleTextOpacity)
            }

            TVSettingsToggleRow(
                title: .settingsSubtitlesTextOutline,
                isOn: viewModel.subtitleAppearance.textOutline
            ) {
                guard appearanceEditable else { return }
                var next = viewModel.subtitleAppearance
                next.textOutline.toggle()
                Task { await viewModel.setSubtitleAppearance(next) }
            }

            TVSettingsPickerRow(
                title: .settingsSubtitlesOutlineColor,
                value: viewModel.subtitleAppearance.textOutline
                    ? TVSettingsOptions.label(
                        for: viewModel.subtitleAppearance.textOutlineColor.lowercased(),
                        in: TVSettingsOptions.outlineColor
                    )
                    : .verbatim("—")
            ) {
                guard appearanceEditable else { return }
                showPicker(.outlineColor)
            }
            .focused(detailFocus, equals: .subtitleOutlineColor)

            pickerRow(.settingsSubtitlesBackgroundStyle, options: TVSettingsOptions.backgroundStyle,
                      selection: viewModel.subtitleAppearance.backgroundStyle.rawValue, kind: .backgroundStyle)

            TVSettingsPickerRow(
                title: .settingsSubtitlesBackgroundOpacity,
                value: .verbatim(viewModel.subtitleAppearance.backgroundStyle == .box
                    ? "\(viewModel.subtitleAppearance.backgroundOpacity)%"
                    : "—")
            ) {
                guard appearanceEditable else { return }
                showPicker(.backgroundOpacity)
            }
            .focused(detailFocus, equals: .subtitleBackgroundOpacity)

            TVSettingsPickerRow(
                title: .settingsSubtitlesBackgroundColor,
                value: viewModel.subtitleAppearance.backgroundStyle == .box
                    ? TVSettingsOptions.label(
                        for: viewModel.subtitleAppearance.backgroundColor.lowercased(),
                        in: TVSettingsOptions.backgroundColor
                    )
                    : .verbatim("—")
            ) {
                guard appearanceEditable else { return }
                showPicker(.backgroundColor)
            }
            .focused(detailFocus, equals: .subtitleBackgroundColor)

            pickerRow(.settingsSubtitlesPosition, options: TVSettingsOptions.position,
                      selection: viewModel.subtitleAppearance.position.rawValue, kind: .position)

            Button(.settingsSubtitlesResetAppearance, role: .destructive) {
                guard appearanceEditable else { return }
                showResetConfirmation = true
            }
            .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
        }

        TVSettingsFooter(.verbatim(appearanceFooterText))
    }

    /// Appearance edits save for the profile, or for this Apple TV while its
    /// override is on; only following the system captions locks them.
    private var appearanceEditable: Bool {
        !viewModel.subtitleMatchesSystemAppearance
    }

    private var appearanceFooterText: String {
        let source: LocalizedStringResource
        if viewModel.subtitleMatchesSystemAppearance {
            source = .settingsSubtitlesFollowsSystemAppearanceAppleTv
        } else if viewModel.subtitleUsesDeviceAppearanceOverride {
            source = .settingsSubtitlesScopeDeviceOnlyAppleTv
        } else {
            source = .settingsSubtitlesScopeProfile
        }
        let authoredStyleBehavior: LocalizedStringResource = viewModel.subtitleMatchesSystemAppearance
            ? .settingsSubtitlesAuthoredStyleSystem
            : .settingsSubtitlesAuthoredStyle
        return AppLanguage.string(source, locale: locale) + " " + AppLanguage.string(authoredStyleBehavior, locale: locale)
    }

    @ViewBuilder
    private var prefSaveFooter: some View {
        if let state = viewModel.prefs.saveState,
           !(viewModel.prefs.serverUpgradeRequired && state == .serverUpgradeRequired) {
            switch state {
            case .saving:
                TVSettingsFooter(.settingsSaving)
            case .saved:
                TVSettingsFooter(.settingsSubtitlesSaved)
            case .failed(let err):
                TVSettingsWarningFooter(.settingsSubtitlesSaveFailed(AppLanguage.string(err, locale: locale)))
            case .serverUpgradeRequired:
                TVSettingsWarningFooter(ProfilePrefsEditor.serverUpgradeMessage)
            case .held:
                // TVHeldSettingChangesRows below carries the message.
                EmptyView()
            }
        }
    }

    // MARK: - Rows

    private func pickerRow(
        _ title: LocalizedStringResource,
        options: [TVSettingsOption],
        selection: String,
        kind: PickerKind
    ) -> some View {
        TVSettingsPickerRow(
            title: title,
            value: TVSettingsOptions.label(for: selection, in: options)
        ) {
            guard appearanceEditable else { return }
            showPicker(kind)
        }
        .focused(detailFocus, equals: kind.returnFocus)
    }

    // MARK: - Pickers

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        return switch kind {
        case .language:
            TVSettingsPickerRequest(
                title: .settingsControlLanguage,
                options: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions, language: AppLanguage.language(of: locale)),
                selection: Binding(
                    get: { viewModel.prefs.subtitleLanguage },
                    set: { value in Task { await viewModel.prefs.setSubtitleLanguage(value) } }
                ),
                returnFocus: kind.returnFocus
            )
        case .mode:
            TVSettingsPickerRequest(
                title: .settingsControlBehavior,
                options: TVSettingsOptions.subtitleMode,
                selection: Binding(
                    get: { viewModel.prefs.subtitleMode },
                    set: { value in Task { await viewModel.prefs.setSubtitleMode(value) } }
                ),
                returnFocus: kind.returnFocus
            )
        case .metadataLanguage:
            TVSettingsPickerRequest(
                title: .settingsControlMetadataLanguage,
                options: TVSettingsOptions.metadataLanguage(viewModel.metadataLanguageOptions, language: AppLanguage.language(of: locale)),
                selection: Binding(
                    get: { viewModel.prefs.preferredMetadataLanguage },
                    set: { value in Task { await viewModel.prefs.setPreferredMetadataLanguage(value) } }
                ),
                returnFocus: kind.returnFocus
            )
        case .fontSize:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesFontSize,
                options: TVSettingsOptions.subtitleSize,
                selection: appearanceEnumBinding(\.fontSize, SubtitleFontSizePreset.self),
                returnFocus: kind.returnFocus
            )
        case .fontFamily:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesFontFamily,
                options: TVSettingsOptions.fontFamily,
                selection: appearanceEnumBinding(\.fontFamily, SubtitleFontFamilyPreset.self),
                subtitlePreviewAppearance: viewModel.subtitleAppearance,
                returnFocus: kind.returnFocus
            )
        case .fontColor:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesFontColor,
                options: TVSettingsOptions.fontColor,
                selection: appearanceStringBinding(\.fontColor),
                returnFocus: kind.returnFocus
            )
        case .textOpacity:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesTextOpacity,
                options: TVSettingsOptions.textOpacity(current: viewModel.subtitleAppearance.textOpacity),
                selection: textOpacityBinding,
                returnFocus: kind.returnFocus
            )
        case .outlineColor:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesOutlineColor,
                options: TVSettingsOptions.outlineColor,
                selection: outlineColorBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundStyle:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesBackgroundStyle,
                options: TVSettingsOptions.backgroundStyle,
                selection: backgroundStyleBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundOpacity:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesBackgroundOpacity,
                options: TVSettingsOptions.backgroundOpacity(current: viewModel.subtitleAppearance.backgroundOpacity),
                selection: backgroundOpacityBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundColor:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesBackgroundColor,
                options: TVSettingsOptions.backgroundColor,
                selection: backgroundColorBinding,
                returnFocus: kind.returnFocus
            )
        case .position:
            TVSettingsPickerRequest(
                title: .settingsSubtitlesPosition,
                options: TVSettingsOptions.position,
                selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self),
                returnFocus: kind.returnFocus
            )
        }
    }

    enum PickerKind {
        case language
        case mode
        case metadataLanguage
        case fontSize
        case fontFamily
        case fontColor
        case textOpacity
        case outlineColor
        case backgroundStyle
        case backgroundOpacity
        case backgroundColor
        case position

        var returnFocus: TVSettingsDetailFocus {
            switch self {
            case .language: .top
            case .mode: .subtitleBehavior
            case .metadataLanguage: .subtitleMetadataLanguage
            case .fontSize: .subtitleFontSize
            case .fontFamily: .subtitleFontFamily
            case .fontColor: .subtitleFontColor
            case .textOpacity: .subtitleTextOpacity
            case .outlineColor: .subtitleOutlineColor
            case .backgroundStyle: .subtitleBackgroundStyle
            case .backgroundOpacity: .subtitleBackgroundOpacity
            case .backgroundColor: .subtitleBackgroundColor
            case .position: .subtitlePosition
            }
        }
    }

    // MARK: - Appearance bindings

    /// Editing a setting that the current style ignores makes it take
    /// effect ("touch it and it applies"): picking an outline color turns
    /// the outline on, and picking a background color or opacity switches
    /// the style to Box. Matches the player HUD's behavior.

    private var outlineColorBinding: Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance.textOutlineColor.lowercased() },
            set: { value in
                var next = viewModel.subtitleAppearance
                next.textOutlineColor = value
                next.textOutline = true
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var backgroundStyleBinding: Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance.backgroundStyle.rawValue },
            set: { rawValue in
                guard let style = SubtitleBackgroundStylePreset(rawValue: rawValue) else { return }
                var next = viewModel.subtitleAppearance
                next.backgroundStyle = style
                if style == .box && next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var textOpacityBinding: Binding<String> {
        Binding(
            get: { String(viewModel.subtitleAppearance.textOpacity) },
            set: { value in
                guard let opacity = Int(value) else { return }
                var next = viewModel.subtitleAppearance
                next.textOpacity = opacity
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var backgroundOpacityBinding: Binding<String> {
        Binding(
            get: { String(viewModel.subtitleAppearance.backgroundOpacity) },
            set: { value in
                guard let opacity = Int(value) else { return }
                var next = viewModel.subtitleAppearance
                next.backgroundOpacity = opacity
                if opacity > 0 {
                    next.backgroundStyle = .box
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var backgroundColorBinding: Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance.backgroundColor.lowercased() },
            set: { value in
                var next = viewModel.subtitleAppearance
                next.backgroundColor = value
                next.backgroundStyle = .box
                if next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceStringBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, String>) -> Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath].lowercased() },
            set: { value in
                var next = viewModel.subtitleAppearance
                next[keyPath: keyPath] = value
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceEnumBinding<Value>(
        _ keyPath: WritableKeyPath<SubtitleAppearance, Value>,
        _ type: Value.Type
    ) -> Binding<String> where Value: RawRepresentable, Value.RawValue == String {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath].rawValue },
            set: { rawValue in
                guard let value = Value(rawValue: rawValue) else { return }
                var next = viewModel.subtitleAppearance
                next[keyPath: keyPath] = value
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }
}
#endif
