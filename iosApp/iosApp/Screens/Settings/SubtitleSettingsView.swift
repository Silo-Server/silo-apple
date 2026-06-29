#if !os(tvOS)
import SwiftUI

/// Subtitle preferences sub-screen — a native grouped list. The
/// language / behavior / forced trio is profile-wide on the server;
/// the appearance block is a per-device override with a server
/// fallback.
struct SubtitleSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            profileBackedSection
            if AICapabilities.shared.metadataEnabled {
                metadataLanguageSection
            }
            appearanceSection
        }
        .continuumGroupedListStyle()
        .continuumScrollContentBackgroundHidden()
        .background(Color.continuumBackground.ignoresSafeArea())
        .navigationTitle("Subtitles")
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumToolbarColorSchemeDark()
        .onChange(of: viewModel.editorSubtitleLanguage) { _, _ in
            Task { await viewModel.saveProfilePrefs() }
        }
        .onChange(of: viewModel.editorSubtitleMode) { _, _ in
            Task { await viewModel.saveProfilePrefs() }
        }
        .onChange(of: viewModel.editorShowForcedSubtitles) { _, _ in
            Task { await viewModel.saveProfilePrefs() }
        }
        .onChange(of: viewModel.editorPreferredMetadataLanguage) { _, _ in
            Task { await viewModel.saveMetadataLanguage() }
        }
    }

    // MARK: - Metadata language (server-backed, AI-gated)

    @ViewBuilder
    private var metadataLanguageSection: some View {
        Section {
            Picker("Metadata Language", selection: $viewModel.editorPreferredMetadataLanguage) {
                Text("Library Default").tag(PlaybackPrefSentinel.none)
                ForEach(PlaybackLanguageOption.all) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Metadata")
                .foregroundStyle(Color.continuumSecondaryText)
        } footer: {
            Text("Translates descriptions and taglines into your preferred language when available. Titles are never translated.")
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }

    // MARK: - Profile prefs (server-backed)

    @ViewBuilder
    private var profileBackedSection: some View {
        Section {
            Picker("Language", selection: $viewModel.editorSubtitleLanguage) {
                Text("None").tag(PlaybackPrefSentinel.none)
                ForEach(PlaybackLanguageOption.all) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Behavior", selection: $viewModel.editorSubtitleMode) {
                ForEach(SubtitleMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayLabel).tag(mode.rawValue)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle(
                "Show Forced Subtitles",
                isOn: Binding(
                    get: { viewModel.editorShowForcedSubtitles == "on" },
                    set: { viewModel.editorShowForcedSubtitles = $0 ? "on" : "off" }
                )
            )
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumOnSurface)
        } header: {
            Text("Profile")
                .foregroundStyle(Color.continuumSecondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Used to pick a matching track when one is available. Forced subtitles cover foreign-language dialogue even when subtitles are off or set to auto.")
                if let state = viewModel.prefSaveState {
                    saveStateView(state)
                }
            }
            .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }

    // MARK: - Appearance (per-device override)

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Toggle(
                "Custom Appearance",
                isOn: Binding(
                    get: { viewModel.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                )
            )
            .foregroundStyle(Color.continuumOnSurface)
            .tint(.continuumOnSurface)

            Picker("Font Size", selection: appearanceBinding(\.fontSize)) {
                ForEach(SubtitleFontSizePreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Font Family", selection: appearanceBinding(\.fontFamily)) {
                ForEach(SubtitleFontFamilyPreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            ColorSwatchPicker(
                title: "Font Color",
                colors: SubtitleAppearance.fontColors,
                selection: appearanceBinding(\.fontColor)
            )

            Toggle("Text Outline", isOn: appearanceBinding(\.textOutline))
                .foregroundStyle(Color.continuumOnSurface)
                .tint(.continuumOnSurface)

            ColorSwatchPicker(
                title: "Outline Color",
                colors: SubtitleAppearance.outlineColors,
                selection: appearanceBinding(\.textOutlineColor)
            )
            .disabled(!viewModel.subtitleAppearance.textOutline && viewModel.subtitleAppearance.backgroundStyle != .outline)
            .opacity(viewModel.subtitleAppearance.textOutline || viewModel.subtitleAppearance.backgroundStyle == .outline ? 1 : 0.45)

            Picker("Background Style", selection: appearanceBinding(\.backgroundStyle)) {
                ForEach(SubtitleBackgroundStylePreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Background Opacity", selection: appearanceBinding(\.backgroundOpacity)) {
                ForEach(Array(stride(from: 0, through: 100, by: 5)), id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            ColorSwatchPicker(
                title: "Background Color",
                colors: SubtitleAppearance.backgroundColors,
                selection: appearanceBinding(\.backgroundColor)
            )
            .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
            .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)

            Picker("Position", selection: appearanceBinding(\.position)) {
                ForEach(SubtitlePositionPreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Appearance")
                .foregroundStyle(Color.continuumSecondaryText)
        } footer: {
            Text(viewModel.subtitleUsesDeviceAppearanceOverride
                 ? "Saved on the server for this profile on this device. An admin can reset it."
                 : "Using the server fallback for this profile on this device. Turn on Custom Appearance to save your own here.")
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
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
    private func saveStateView(_ state: SettingsViewModel.PrefSaveState) -> some View {
        switch state {
        case .saving:
            Text("Saving…")
        case .saved:
            Text("Saved")
        case .failed(let message):
            Text("Couldn't save: \(message)")
                .foregroundStyle(Color.continuumError)
        }
    }
}

// MARK: - Color swatch row

private struct ColorSwatchPicker: View {
    let title: String
    let colors: [(hex: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.continuumOnSurface)
            Spacer()
            HStack(spacing: 10) {
                ForEach(colors, id: \.hex) { color in
                    Button {
                        selection = color.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: color.hex))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(
                                        isSelected(color.hex)
                                            ? Color.continuumOnSurface
                                            : Color.continuumSecondaryText.opacity(0.35),
                                        lineWidth: isSelected(color.hex) ? 3 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.label)
                    .accessibilityAddTraits(isSelected(color.hex) ? .isSelected : [])
                }
            }
        }
    }

    private func isSelected(_ hex: String) -> Bool {
        selection.caseInsensitiveCompare(hex) == .orderedSame
    }
}
#endif
