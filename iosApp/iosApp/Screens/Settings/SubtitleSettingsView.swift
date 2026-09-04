#if !os(tvOS)
import SwiftUI

/// Subtitle preferences sub-screen — a native grouped list. The
/// language / behavior / forced trio is profile-wide on the server;
/// the appearance block is a per-device override with a server
/// fallback.
struct SubtitleSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    /// Slider position while the user is dragging; committed (and saved
    /// to the server) once the drag ends.
    @State private var draftOpacity: Double?

    var body: some View {
        List {
            SettingsPageHeader(
                title: "Subtitles",
                subtitle: "Language, behavior, and on-screen appearance.",
                systemImage: "captions.bubble.fill",
                tint: .pink
            )
            .settingsPageHeaderRow()

            profileBackedSection
            if AICapabilities.shared.metadataEnabled {
                metadataLanguageSection
            }
            appearanceSection
        }
        .settingsListChrome()
        .navigationTitle("")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
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
                Text(
                    SettingPresentationMetadata.definitions[.catalogMetadataLanguage]?.unsetLabel
                        ?? "Library default"
                ).tag(PlaybackPrefSentinel.none)
                ForEach(viewModel.metadataLanguageOptions) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Metadata")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text("Translates descriptions and taglines into your preferred language when available. Titles are never translated.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .disabled(viewModel.settingsServerUpgradeRequired)
        .listRowBackground(Color.siloSurfaceElevated)
    }

    // MARK: - Profile prefs (server-backed)

    @ViewBuilder
    private var profileBackedSection: some View {
        Section {
            Picker("Language", selection: $viewModel.editorSubtitleLanguage) {
                Text(
                    SettingPresentationMetadata.definitions[.playbackSubtitleLanguage]?.unsetLabel
                        ?? "None"
                ).tag(PlaybackPrefSentinel.none)
                ForEach(viewModel.subtitleLanguageOptions) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
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
            .foregroundStyle(Color.siloOnSurface)
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
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloAccent)
        } header: {
            Text("Profile")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.subtitleMatchesSystemAppearance {
                    Text("Language, display behavior, forced captions, and CC/SDH preference follow this device's Accessibility settings.")
                } else if viewModel.settingsServerUpgradeRequired {
                    Text(ProfilePrefsEditor.serverUpgradeMessage)
                        .foregroundStyle(Color.siloError)
                } else {
                    Text("Used to pick a matching track when one is available. Forced subtitles cover foreign-language dialogue even when subtitles are off or set to auto.")
                    if let overrideMessage = viewModel.prefs.subtitleProfileOverrideMessage {
                        Text("Override active — \(overrideMessage)")
                            .foregroundStyle(Color.siloWarning)
                    }
                }
                if let state = viewModel.prefSaveState,
                   !(viewModel.settingsServerUpgradeRequired && state == .serverUpgradeRequired) {
                    saveStateView(state)
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .disabled(viewModel.settingsServerUpgradeRequired || viewModel.subtitleMatchesSystemAppearance)
        .listRowBackground(Color.siloSurfaceElevated)
    }

    // MARK: - Appearance (per-device override)

    private var manualEditingDisabled: Bool {
        viewModel.subtitleMatchesSystemAppearance
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            SubtitleAppearancePreview(appearance: viewModel.effectiveSubtitleAppearance)
                .listRowInsets(EdgeInsets())
        } header: {
            Text("Appearance")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            if !manualEditingDisabled && viewModel.subtitleAppearance.isLowLegibilityRisk {
                Text("Low contrast — dark text without a box or outline can be hard to read.")
                    .foregroundStyle(Color.siloError)
            }
        }
        .listRowBackground(Color.siloSurfaceElevated)

        Section {
            Toggle(
                "Use Device Settings",
                isOn: Binding(
                    get: { viewModel.subtitleMatchesSystemAppearance },
                    set: { enabled in
                        Task { await viewModel.setSubtitleMatchesSystemAppearance(enabled) }
                    }
                )
            )
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloAccent)

            Toggle(
                "Custom Appearance",
                isOn: Binding(
                    get: { viewModel.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                )
            )
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloAccent)
            .disabled(manualEditingDisabled)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.subtitleMatchesSystemAppearance {
                    Text("Following this device's caption language, display behavior, CC/SDH preference, font, colors, opacity, edges, size, and caption window from Accessibility → Subtitles & Captioning.")
                } else if viewModel.subtitleUsesDeviceAppearanceOverride {
                    Text("Saved on the server for this profile on this device. An admin can reset it.")
                } else {
                    Text("Using the server fallback for this profile on this device. Turn on Custom Appearance to save your own here.")
                }
                if viewModel.subtitleMatchesSystemAppearance {
                    Text("Subtitles with built-in styling follow each device caption option's Video Overrides Style choice.")
                } else {
                    Text("Subtitles with their own built-in styling keep their original appearance; image-based subtitles keep their authored fonts and colors but follow the size, position, and background settings.")
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)

        Section {
            Picker("Font Size", selection: appearanceBinding(\.fontSize)) {
                ForEach(SubtitleFontSizePreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
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
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            ColorChoicePicker(
                title: "Font Color",
                colors: SubtitleAppearance.fontColors,
                selection: appearanceBinding(\.fontColor)
            )

            Toggle("Text Outline", isOn: appearanceBinding(\.textOutline))
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloAccent)

            ColorChoicePicker(
                title: "Outline Color",
                colors: SubtitleAppearance.outlineColors,
                selection: appearanceBinding(\.textOutlineColor)
            )
            .disabled(!viewModel.subtitleAppearance.textOutline)
            .opacity(viewModel.subtitleAppearance.textOutline ? 1 : 0.45)
        } header: {
            Text("Text")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)
        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)

        Section {
            Picker("Style", selection: backgroundStyleBinding) {
                ForEach(SubtitleBackgroundStylePreset.selectableCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            opacityRow
                .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
                .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)

            ColorChoicePicker(
                title: "Color",
                colors: SubtitleAppearance.backgroundColors,
                selection: appearanceBinding(\.backgroundColor)
            )
            .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
            .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)
        } header: {
            Text("Background")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)
        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)

        Section {
            Picker("Position", selection: appearanceBinding(\.position)) {
                ForEach(SubtitlePositionPreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Layout")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)
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
        let committed = Double(viewModel.subtitleAppearance.backgroundOpacity)
        return HStack(spacing: 12) {
            Text("Opacity")
                .foregroundStyle(Color.siloOnSurface)
            Slider(
                value: Binding(
                    get: { draftOpacity ?? committed },
                    set: { draftOpacity = $0 }
                ),
                in: 0...100,
                step: 5
            ) { editing in
                guard !editing, let value = draftOpacity else { return }
                draftOpacity = nil
                var next = viewModel.subtitleAppearance
                let percent = Int(value)
                if next.backgroundOpacity == percent { return }
                next.backgroundOpacity = percent
                Task { await viewModel.setSubtitleAppearance(next) }
            }
            .tint(.siloAccent)
            Text("\(Int(draftOpacity ?? committed))%")
                .monospacedDigit()
                .foregroundStyle(Color.siloSecondaryText)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Background Opacity")
        .accessibilityValue("\(Int(draftOpacity ?? committed)) percent")
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
                .foregroundStyle(Color.siloError)
        case .serverUpgradeRequired:
            Text(ProfilePrefsEditor.serverUpgradeMessage)
                .foregroundStyle(Color.siloError)
        }
    }
}

// MARK: - Color choice row

/// A named-color picker rendered as a standard row (navigation link on
/// iOS, menu on macOS) so every option gets a full-size tap target,
/// unlike the previous row of 24pt swatches.
private struct ColorChoicePicker: View {
    let title: String
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
                    Text(color.label)
                }
                .tag(color.hex)
            }
        } label: {
            Text(title)
                .foregroundStyle(Color.siloOnSurface)
        }
        #if os(macOS)
        .pickerStyle(.menu)
        #else
        .pickerStyle(.navigationLink)
        #endif
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
