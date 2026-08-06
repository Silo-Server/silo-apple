#if os(tvOS)
import SwiftUI

/// Subtitles pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. Profile-wide prefs (language / behavior
/// / forced) save through the root view's `onChange` handlers; the
/// appearance block writes a per-device override directly.
struct TVSubtitleSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileSection
            if AICapabilities.shared.metadataEnabled {
                metadataLanguageSection
            }
            appearanceSection
        }
        .alert("Reset Custom Appearance?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                Task { await viewModel.resetSubtitleAppearance() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores all custom subtitle appearance options to their defaults.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var profileSection: some View {
        TVSettingsSectionHeader("PROFILE")

        if viewModel.settingsServerUpgradeRequired || viewModel.subtitleMatchesSystemAppearance {
            TVSettingsPickerRow(
                title: "Language",
                value: TVSettingsOptions.label(
                    for: viewModel.editorSubtitleLanguage,
                    in: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions)
                )
            ) { showPicker(.language) }
            .disabled(true)
        } else {
            TVSettingsPickerRow(
                title: "Language",
                value: TVSettingsOptions.label(
                    for: viewModel.editorSubtitleLanguage,
                    in: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions)
                )
            ) { showPicker(.language) }
            .focused(detailFocus, equals: .top)
        }

        TVSettingsPickerRow(
            title: "Behavior",
            value: TVSettingsOptions.label(for: viewModel.editorSubtitleMode, in: TVSettingsOptions.subtitleMode)
        ) { showPicker(.mode) }
        .focused(detailFocus, equals: .subtitleBehavior)
        .disabled(viewModel.settingsServerUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)

        TVSettingsToggleRow(
            title: "Show Forced Subtitles",
            isOn: viewModel.editorShowForcedSubtitles == "on"
        ) {
            viewModel.editorShowForcedSubtitles =
                viewModel.editorShowForcedSubtitles == "on" ? "off" : "on"
        }
        .disabled(viewModel.settingsServerUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)

        if viewModel.subtitleMatchesSystemAppearance {
            TVSettingsFooter("Language, display behavior, forced captions, and CC/SDH preference follow this Apple TV's Accessibility settings.")
        } else if viewModel.settingsServerUpgradeRequired {
            TVSettingsWarningFooter(ProfilePrefsEditor.serverUpgradeMessage)
        } else {
            TVSettingsFooter("Used to pick a matching track when one is available. Forced subtitles cover foreign-language dialogue even when subtitles are off or set to auto.")
            if let overrideMessage = viewModel.prefs.subtitleProfileOverrideMessage {
                TVSettingsFooter("Override active — \(overrideMessage)")
            }
        }
        prefSaveFooter
    }

    @ViewBuilder
    private var metadataLanguageSection: some View {
        TVSettingsSectionHeader("METADATA")

        TVSettingsPickerRow(
            title: "Metadata Language",
            value: TVSettingsOptions.label(
                for: viewModel.editorPreferredMetadataLanguage,
                in: TVSettingsOptions.metadataLanguage(viewModel.metadataLanguageOptions)
            )
        ) { showPicker(.metadataLanguage) }
        .focused(detailFocus, equals: .subtitleMetadataLanguage)
        .disabled(viewModel.settingsServerUpgradeRequired)

        TVSettingsFooter("Translates descriptions and taglines into your preferred language when available. Titles are never translated.")
    }

    @ViewBuilder
    private var appearanceSection: some View {
        TVSettingsSectionHeader("APPEARANCE")

        TVSettingsSubtitlePreview(appearance: viewModel.effectiveSubtitleAppearance)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

        if !viewModel.subtitleMatchesSystemAppearance
            && viewModel.subtitleAppearance.isLowLegibilityRisk {
            TVSettingsFooter("Low contrast — dark text without a box or outline can be hard to read.")
        }

        if viewModel.settingsServerUpgradeRequired || viewModel.subtitleMatchesSystemAppearance {
            TVSettingsToggleRow(
                title: "Use Device Settings",
                isOn: viewModel.subtitleMatchesSystemAppearance
            ) {
                let enabled = !viewModel.subtitleMatchesSystemAppearance
                Task { await viewModel.setSubtitleMatchesSystemAppearance(enabled) }
            }
            .focused(detailFocus, equals: .top)
        } else {
            TVSettingsToggleRow(
                title: "Use Device Settings",
                isOn: viewModel.subtitleMatchesSystemAppearance
            ) {
                let enabled = !viewModel.subtitleMatchesSystemAppearance
                Task { await viewModel.setSubtitleMatchesSystemAppearance(enabled) }
            }
        }

        TVSettingsToggleRow(
            title: "Custom Subtitle Appearance",
            isOn: viewModel.subtitleUsesDeviceAppearanceOverride
        ) {
            let enabled = !viewModel.subtitleUsesDeviceAppearanceOverride
            Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
        }
        .disabled(viewModel.subtitleMatchesSystemAppearance)

        TVSettingsNestedGroup(enabled: viewModel.subtitleUsesDeviceAppearanceOverride) {
            pickerRow("Font Size", options: TVSettingsOptions.subtitleSize,
                      selection: viewModel.subtitleAppearance.fontSize.rawValue, kind: .fontSize)
            pickerRow("Font Family", options: TVSettingsOptions.fontFamily,
                      selection: viewModel.subtitleAppearance.fontFamily.rawValue, kind: .fontFamily)
            pickerRow("Font Color", options: TVSettingsOptions.fontColor,
                      selection: viewModel.subtitleAppearance.fontColor.lowercased(), kind: .fontColor)

            TVSettingsToggleRow(
                title: "Text Outline",
                isOn: viewModel.subtitleAppearance.textOutline
            ) {
                guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
                var next = viewModel.subtitleAppearance
                next.textOutline.toggle()
                Task { await viewModel.setSubtitleAppearance(next) }
            }

            TVSettingsPickerRow(
                title: "Outline Color",
                value: viewModel.subtitleAppearance.textOutline
                    ? TVSettingsOptions.label(
                        for: viewModel.subtitleAppearance.textOutlineColor.lowercased(),
                        in: TVSettingsOptions.outlineColor
                    )
                    : "—"
            ) {
                guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
                showPicker(.outlineColor)
            }
            .focused(detailFocus, equals: .subtitleOutlineColor)

            pickerRow("Background Style", options: TVSettingsOptions.backgroundStyle,
                      selection: viewModel.subtitleAppearance.backgroundStyle.rawValue, kind: .backgroundStyle)

            TVSettingsPickerRow(
                title: "Background Opacity",
                value: viewModel.subtitleAppearance.backgroundStyle == .box
                    ? "\(viewModel.subtitleAppearance.backgroundOpacity)%"
                    : "—"
            ) {
                guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
                showPicker(.backgroundOpacity)
            }
            .focused(detailFocus, equals: .subtitleBackgroundOpacity)

            TVSettingsPickerRow(
                title: "Background Color",
                value: viewModel.subtitleAppearance.backgroundStyle == .box
                    ? TVSettingsOptions.label(
                        for: viewModel.subtitleAppearance.backgroundColor.lowercased(),
                        in: TVSettingsOptions.backgroundColor
                    )
                    : "—"
            ) {
                guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
                showPicker(.backgroundColor)
            }
            .focused(detailFocus, equals: .subtitleBackgroundColor)

            pickerRow("Position", options: TVSettingsOptions.position,
                      selection: viewModel.subtitleAppearance.position.rawValue, kind: .position)

            Button("Reset Custom Appearance", role: .destructive) {
                guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
                showResetConfirmation = true
            }
            .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
        }

        TVSettingsFooter(appearanceFooterText)
    }

    private var appearanceFooterText: String {
        let source: String
        if viewModel.subtitleMatchesSystemAppearance {
            source = "Following this Apple TV's caption language, display behavior, CC/SDH preference, font, colors, opacity, edges, size, and caption window from Settings → Accessibility."
        } else if viewModel.subtitleUsesDeviceAppearanceOverride {
            source = "Appearance is saved on the server for this profile on this Apple TV."
        } else {
            source = "Appearance is using the server fallback for this profile on this Apple TV."
        }
        let authoredStyleBehavior = viewModel.subtitleMatchesSystemAppearance
            ? " Subtitles with built-in styling follow each device caption option's Video Overrides Style choice."
            : " Subtitles with their own built-in styling keep their original appearance; image-based subtitles keep their authored fonts and colors but follow the size, position, and background settings."
        return source + authoredStyleBehavior
    }

    @ViewBuilder
    private var prefSaveFooter: some View {
        if let state = viewModel.prefSaveState,
           !(viewModel.settingsServerUpgradeRequired && state == .serverUpgradeRequired) {
            switch state {
            case .saving:
                TVSettingsFooter("Saving…")
            case .saved:
                TVSettingsFooter("Saved")
            case .failed(let err):
                TVSettingsWarningFooter("Couldn't save: \(err)")
            case .serverUpgradeRequired:
                TVSettingsWarningFooter(ProfilePrefsEditor.serverUpgradeMessage)
            }
        }
    }

    // MARK: - Rows

    private func pickerRow(
        _ title: String,
        options: [TVSettingsOption],
        selection: String,
        kind: PickerKind
    ) -> some View {
        TVSettingsPickerRow(
            title: title,
            value: TVSettingsOptions.label(for: selection, in: options)
        ) {
            guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
            showPicker(kind)
        }
        .focused(detailFocus, equals: kind.returnFocus)
    }

    // MARK: - Pickers

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        switch kind {
        case .language:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Language",
                options: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions),
                selection: $viewModel.editorSubtitleLanguage,
                returnFocus: kind.returnFocus
            )
        case .mode:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Behavior",
                options: TVSettingsOptions.subtitleMode,
                selection: $viewModel.editorSubtitleMode,
                returnFocus: kind.returnFocus
            )
        case .metadataLanguage:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Metadata Language",
                options: TVSettingsOptions.metadataLanguage(viewModel.metadataLanguageOptions),
                selection: $viewModel.editorPreferredMetadataLanguage,
                returnFocus: kind.returnFocus
            )
        case .fontSize:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Font Size",
                options: TVSettingsOptions.subtitleSize,
                selection: appearanceEnumBinding(\.fontSize, SubtitleFontSizePreset.self),
                returnFocus: kind.returnFocus
            )
        case .fontFamily:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Font Family",
                options: TVSettingsOptions.fontFamily,
                selection: appearanceEnumBinding(\.fontFamily, SubtitleFontFamilyPreset.self),
                subtitlePreviewAppearance: viewModel.subtitleAppearance,
                returnFocus: kind.returnFocus
            )
        case .fontColor:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Font Color",
                options: TVSettingsOptions.fontColor,
                selection: appearanceStringBinding(\.fontColor),
                returnFocus: kind.returnFocus
            )
        case .outlineColor:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Outline Color",
                options: TVSettingsOptions.outlineColor,
                selection: outlineColorBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundStyle:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Background Style",
                options: TVSettingsOptions.backgroundStyle,
                selection: backgroundStyleBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundOpacity:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Background Opacity",
                options: TVSettingsOptions.backgroundOpacity,
                selection: backgroundOpacityBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundColor:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Background Color",
                options: TVSettingsOptions.backgroundColor,
                selection: backgroundColorBinding,
                returnFocus: kind.returnFocus
            )
        case .position:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Position",
                options: TVSettingsOptions.position,
                selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self),
                returnFocus: kind.returnFocus
            )
        }
    }

    enum PickerKind: String, Identifiable {
        case language
        case mode
        case metadataLanguage
        case fontSize
        case fontFamily
        case fontColor
        case outlineColor
        case backgroundStyle
        case backgroundOpacity
        case backgroundColor
        case position

        var id: String { rawValue }

        var returnFocus: TVSettingsDetailFocus {
            switch self {
            case .language: .top
            case .mode: .subtitleBehavior
            case .metadataLanguage: .subtitleMetadataLanguage
            case .fontSize: .subtitleFontSize
            case .fontFamily: .subtitleFontFamily
            case .fontColor: .subtitleFontColor
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
