#if os(tvOS)
import SwiftUI

/// Subtitles sub-screen of tvOS Settings, presented as a full-screen
/// cover from the root menu. Profile-wide prefs (language / behavior /
/// forced) save through the root view's `onChange` handlers; the
/// appearance block writes a per-device override directly.
struct TVSubtitleSettingsView: View {
    @Bindable var viewModel: TVSettingsViewModel
    @State private var activePicker: PickerKind?

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                if AICapabilities.shared.metadataEnabled {
                    metadataLanguageSection
                }
                appearanceSection
            }
            .navigationTitle("Subtitles")
            .background(Color.continuumBackground.ignoresSafeArea())
        }
        .fullScreenCover(item: $activePicker) { kind in
            pickerSheet(for: kind)
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        Section {
            Button { activePicker = .language } label: {
                FocusAwareValueRow(
                    title: "Language",
                    value: TVSettingsOptions.label(for: viewModel.editorSubtitleLanguage, in: TVSettingsOptions.subtitleLanguage)
                )
            }

            Button { activePicker = .mode } label: {
                FocusAwareValueRow(
                    title: "Behavior",
                    value: TVSettingsOptions.label(for: viewModel.editorSubtitleMode, in: TVSettingsOptions.subtitleMode)
                )
            }

            Toggle(isOn: Binding(
                get: { viewModel.editorShowForcedSubtitles == "on" },
                set: { viewModel.editorShowForcedSubtitles = $0 ? "on" : "off" }
            )) {
                FocusAwareRowLabel(title: "Show Forced Subtitles")
            }
        } header: {
            Text("Profile")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Used to pick a matching track when one is available. Forced subtitles cover foreign-language dialogue even when subtitles are off or set to auto.")
                prefSaveFooter
            }
        }
    }

    private var metadataLanguageSection: some View {
        Section {
            Button { activePicker = .metadataLanguage } label: {
                FocusAwareValueRow(
                    title: "Metadata Language",
                    value: TVSettingsOptions.label(for: viewModel.editorPreferredMetadataLanguage, in: TVSettingsOptions.metadataLanguage)
                )
            }
        } header: {
            Text("Metadata")
        } footer: {
            Text("Translates descriptions and taglines into your preferred language when available. Titles are never translated.")
        }
    }

    private var appearanceSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.subtitleUsesDeviceAppearanceOverride },
                set: { enabled in
                    Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                }
            )) {
                FocusAwareRowLabel(title: "Custom Appearance")
            }

            pickerRow("Font Size", options: TVSettingsOptions.subtitleSize,
                      selection: viewModel.subtitleAppearance.fontSize.rawValue, kind: .fontSize)
            pickerRow("Font Family", options: TVSettingsOptions.fontFamily,
                      selection: viewModel.subtitleAppearance.fontFamily.rawValue, kind: .fontFamily)
            pickerRow("Font Color", options: TVSettingsOptions.fontColor,
                      selection: viewModel.subtitleAppearance.fontColor.lowercased(), kind: .fontColor)

            Toggle(isOn: appearanceBoolBinding(\.textOutline)) {
                FocusAwareRowLabel(title: "Text Outline")
            }

            pickerRow("Outline Color", options: TVSettingsOptions.outlineColor,
                      selection: viewModel.subtitleAppearance.textOutlineColor.lowercased(), kind: .outlineColor)
            pickerRow("Background Style", options: TVSettingsOptions.backgroundStyle,
                      selection: viewModel.subtitleAppearance.backgroundStyle.rawValue, kind: .backgroundStyle)
            pickerRow("Background Opacity", options: TVSettingsOptions.backgroundOpacity,
                      selection: String(viewModel.subtitleAppearance.backgroundOpacity), kind: .backgroundOpacity)
            pickerRow("Background Color", options: TVSettingsOptions.backgroundColor,
                      selection: viewModel.subtitleAppearance.backgroundColor.lowercased(), kind: .backgroundColor)
            pickerRow("Position", options: TVSettingsOptions.position,
                      selection: viewModel.subtitleAppearance.position.rawValue, kind: .position)
        } header: {
            Text("Appearance")
        } footer: {
            Text(viewModel.subtitleUsesDeviceAppearanceOverride
                 ? "Appearance is saved on the server for this profile on this Apple TV."
                 : "Appearance is using the server fallback for this profile on this Apple TV.")
        }
    }

    @ViewBuilder
    private var prefSaveFooter: some View {
        if let state = viewModel.prefSaveState {
            switch state {
            case .saving:
                Text("Saving…")
            case .saved:
                Text("Saved")
            case .failed(let err):
                Text("Couldn't save: \(err)")
                    .foregroundStyle(.red)
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
        Button { activePicker = kind } label: {
            FocusAwareValueRow(
                title: title,
                value: TVSettingsOptions.label(for: selection, in: options)
            )
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
                selection: appearanceStringBinding(\.textOutlineColor)
            )
        case .backgroundStyle:
            TVSettingsPickerSheet(
                title: "Background Style",
                options: TVSettingsOptions.backgroundStyle,
                selection: appearanceEnumBinding(\.backgroundStyle, SubtitleBackgroundStylePreset.self)
            )
        case .backgroundOpacity:
            TVSettingsPickerSheet(
                title: "Background Opacity",
                options: TVSettingsOptions.backgroundOpacity,
                selection: appearanceIntBinding(\.backgroundOpacity)
            )
        case .backgroundColor:
            TVSettingsPickerSheet(
                title: "Background Color",
                options: TVSettingsOptions.backgroundColor,
                selection: appearanceStringBinding(\.backgroundColor)
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

    private func appearanceIntBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, Int>) -> Binding<String> {
        Binding(
            get: { String(viewModel.subtitleAppearance[keyPath: keyPath]) },
            set: { value in
                guard let intValue = Int(value) else { return }
                var next = viewModel.subtitleAppearance
                next[keyPath: keyPath] = intValue
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceBoolBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath] },
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
