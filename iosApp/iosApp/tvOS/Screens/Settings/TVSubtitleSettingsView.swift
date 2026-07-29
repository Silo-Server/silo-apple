#if os(tvOS)
import SwiftUI

/// Subtitles pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. Profile-wide prefs (language / behavior
/// / forced) save through the root view's `onChange` handlers; the
/// appearance block writes a per-device override directly.
struct TVSubtitleSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    @State private var activePicker: PickerKind?
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileSection
            if AICapabilities.shared.metadataEnabled {
                metadataLanguageSection
            }
            appearanceSection
        }
        .fullScreenCover(item: $activePicker) { kind in
            pickerSheet(for: kind)
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

        TVSettingsPickerRow(
            title: "Language",
            value: TVSettingsOptions.label(for: viewModel.editorSubtitleLanguage, in: TVSettingsOptions.subtitleLanguage)
        ) { activePicker = .language }
        .focused(detailFocus, equals: .top)

        TVSettingsPickerRow(
            title: "Behavior",
            value: TVSettingsOptions.label(for: viewModel.editorSubtitleMode, in: TVSettingsOptions.subtitleMode)
        ) { activePicker = .mode }

        TVSettingsToggleRow(
            title: "Show Forced Subtitles",
            isOn: viewModel.editorShowForcedSubtitles == "on"
        ) {
            viewModel.editorShowForcedSubtitles =
                viewModel.editorShowForcedSubtitles == "on" ? "off" : "on"
        }

        if viewModel.settingsServerUpgradeRequired {
            // The controls above stay usable: an edit is kept locally and the
            // message explains why it will not follow the profile elsewhere.
            warningFooter(ProfilePrefsEditor.serverUpgradeMessage)
        } else {
            TVSettingsFooter("Used to pick a matching track when one is available. Forced subtitles cover foreign-language dialogue even when subtitles are off or set to auto.")
        }
        prefSaveFooter
    }

    @ViewBuilder
    private var metadataLanguageSection: some View {
        TVSettingsSectionHeader("METADATA")

        TVSettingsPickerRow(
            title: "Metadata Language",
            value: TVSettingsOptions.label(for: viewModel.editorPreferredMetadataLanguage, in: TVSettingsOptions.metadataLanguage)
        ) { activePicker = .metadataLanguage }

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

        TVSettingsToggleRow(
            title: "Match Device Settings",
            isOn: viewModel.subtitleMatchesSystemAppearance
        ) {
            let enabled = !viewModel.subtitleMatchesSystemAppearance
            Task { await viewModel.setSubtitleMatchesSystemAppearance(enabled) }
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
                activePicker = .outlineColor
            }

            pickerRow("Background Style", options: TVSettingsOptions.backgroundStyle,
                      selection: viewModel.subtitleAppearance.backgroundStyle.rawValue, kind: .backgroundStyle)

            TVSettingsPickerRow(
                title: "Background Opacity",
                value: viewModel.subtitleAppearance.backgroundStyle == .box
                    ? "\(viewModel.subtitleAppearance.backgroundOpacity)%"
                    : "—"
            ) {
                guard viewModel.subtitleUsesDeviceAppearanceOverride else { return }
                activePicker = .backgroundOpacity
            }

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
                activePicker = .backgroundColor
            }

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
            source = "Following this Apple TV's caption style from Settings → Accessibility. Editing any option switches back to Silo styling."
        } else if viewModel.subtitleUsesDeviceAppearanceOverride {
            source = "Appearance is saved on the server for this profile on this Apple TV."
        } else {
            source = "Appearance is using the server fallback for this profile on this Apple TV."
        }
        return source + " Subtitles with their own built-in styling keep their original appearance; image-based subtitles keep their authored fonts and colors but follow the size, position, and background settings."
    }

    private func warningFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 19))
            .foregroundStyle(.red)
            .padding(.horizontal, 24)
            .padding(.top, 4)
    }

    @ViewBuilder
    private var prefSaveFooter: some View {
        if let state = viewModel.prefSaveState {
            switch state {
            case .saving:
                TVSettingsFooter("Saving…")
            case .saved:
                TVSettingsFooter("Saved")
            case .failed(let err):
                warningFooter("Couldn't save: \(err)")
            case .serverUpgradeRequired:
                warningFooter(ProfilePrefsEditor.serverUpgradeMessage)
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
            activePicker = kind
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private func pickerSheet(for kind: PickerKind) -> some View {
        switch kind {
        case .language:
            TVSettingsPickerSheet(
                title: "Language",
                options: TVSettingsOptions.subtitleLanguage,
                selection: $viewModel.editorSubtitleLanguage
            )
        case .mode:
            TVSettingsPickerSheet(
                title: "Behavior",
                options: TVSettingsOptions.subtitleMode,
                selection: $viewModel.editorSubtitleMode
            )
        case .metadataLanguage:
            TVSettingsPickerSheet(
                title: "Metadata Language",
                options: TVSettingsOptions.metadataLanguage,
                selection: $viewModel.editorPreferredMetadataLanguage
            )
        case .fontSize:
            TVSettingsPickerSheet(
                title: "Font Size",
                options: TVSettingsOptions.subtitleSize,
                selection: appearanceEnumBinding(\.fontSize, SubtitleFontSizePreset.self)
            )
        case .fontFamily:
            TVSettingsPickerSheet(
                title: "Font Family",
                options: TVSettingsOptions.fontFamily,
                selection: appearanceEnumBinding(\.fontFamily, SubtitleFontFamilyPreset.self),
                subtitlePreviewAppearance: viewModel.subtitleAppearance
            )
        case .fontColor:
            TVSettingsPickerSheet(
                title: "Font Color",
                options: TVSettingsOptions.fontColor,
                selection: appearanceStringBinding(\.fontColor)
            )
        case .outlineColor:
            TVSettingsPickerSheet(
                title: "Outline Color",
                options: TVSettingsOptions.outlineColor,
                selection: outlineColorBinding
            )
        case .backgroundStyle:
            TVSettingsPickerSheet(
                title: "Background Style",
                options: TVSettingsOptions.backgroundStyle,
                selection: backgroundStyleBinding
            )
        case .backgroundOpacity:
            TVSettingsPickerSheet(
                title: "Background Opacity",
                options: TVSettingsOptions.backgroundOpacity,
                selection: backgroundOpacityBinding
            )
        case .backgroundColor:
            TVSettingsPickerSheet(
                title: "Background Color",
                options: TVSettingsOptions.backgroundColor,
                selection: backgroundColorBinding
            )
        case .position:
            TVSettingsPickerSheet(
                title: "Position",
                options: TVSettingsOptions.position,
                selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self)
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
