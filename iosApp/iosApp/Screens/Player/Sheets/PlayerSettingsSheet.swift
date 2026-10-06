import SwiftUI

#if os(iOS)
/// `Stepper` with a trailing value label that commits on every step.
private struct RangeSpinner<Value: Strideable>: View {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let display: (Value) -> String

    var body: some View {
        Stepper(
            value: $value,
            in: range,
            step: step
        ) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// iOS in-player settings sheet, presented from `MobilePlayerControls`.
/// Changes apply immediately: each row writes one setting through the view
/// model. Quality and subtitle appearance open sub-pages; route diagnostics
/// sit on an Advanced page. tvOS uses `TVPlayerInfoHUD` and macOS uses
/// `MacPlayerOptionsPanel` instead.
struct PlayerSettingsSheet: View {
    let viewModel: PlayerViewModel
    let sleepTimer: SleepTimer
    /// Visibility of the stats annotation. A binding rather than a one-shot
    /// action because the overlay itself has no dismiss affordance — this row
    /// is both the on and the off switch. Nil hides the row.
    var statsOverlayVisible: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                videoSection
                subtitlesSection
                sessionSection
                advancedSection
            }
            .navigationTitle("Playback Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // The sheet floats over an always-dark player; pin dark so the
        // grouped list renders dark regardless of the app's scheme.
        .preferredColorScheme(.dark)
    }

    private var videoSection: some View {
        Section {
            NavigationLink {
                qualityPage
            } label: {
                LabeledContent("Quality", value: activeQualityLabel)
            }

            Picker("Aspect", selection: Binding(
                get: { viewModel.settings.videoGravity },
                set: { newValue in
                    viewModel.setVideoGravity(newValue)
                }
            )) {
                ForEach(VideoGravity.allCases, id: \.self) { gravity in
                    Text(gravity.label).tag(gravity)
                }
            }
        } header: {
            Text("Video")
        }
    }

    private var activeQualityLabel: String {
        viewModel.qualityOptions.first(where: { $0.id == viewModel.activeQualityId })?.label
            ?? ApplePlaybackQuality.displayName(for: viewModel.activeQualityId)
    }

    private var qualityPage: some View {
        List {
            Section {
                ForEach(viewModel.qualityOptions) { option in
                    Button {
                        viewModel.switchQuality(option.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                if let subtitle = option.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if option.id == viewModel.activeQualityId {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                if viewModel.isQualitySwitching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Switching quality…")
                    }
                } else if let error = viewModel.qualitySwitchError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Quality")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var subtitlesSection: some View {
        if viewModel.backendCapabilities.supportsSubtitleStyling
            || viewModel.backendCapabilities.supportsSubtitleDelay {
            Section("Subtitles") {
                if viewModel.backendCapabilities.supportsSubtitleStyling {
                    NavigationLink {
                        subtitleAppearancePage
                    } label: {
                        LabeledContent("Appearance", value: appearanceSummary)
                    }
                }

                if viewModel.backendCapabilities.supportsSubtitleDelay {
                    RangeSpinner(
                        title: "Subtitle Delay",
                        value: Binding(
                            get: { viewModel.settings.subtitleSyncMs },
                            set: { viewModel.setSubtitleSyncMilliseconds($0) }
                        ),
                        range: -10000...10000,
                        step: 100,
                        display: { formatMs($0) }
                    )
                }
            }
        }
    }

    /// "Large · Box · Bottom"-style value label for the Appearance row.
    private var appearanceSummary: String {
        if viewModel.settings.subtitleMatchesSystemAppearance {
            return "Using Device"
        }
        let appearance = viewModel.settings.subtitleAppearance
        return [
            appearance.fontSize.label,
            appearance.styleDescription,
            appearance.position.label,
        ].joined(separator: " · ")
    }

    private var subtitleAppearancePage: some View {
        let matchesSystem = viewModel.settings.subtitleMatchesSystemAppearance
        return List {
            Section {
                SubtitleAppearancePreview(appearance: viewModel.settings.effectiveSubtitleAppearance)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if !matchesSystem && viewModel.settings.subtitleAppearance.isLowLegibilityRisk {
                    Text("Low legibility — very transparent or dark text without a box or outline can be hard to read.")
                }
            }

            Section {
                Toggle("Use device settings", isOn: Binding(
                    get: { viewModel.settings.subtitleMatchesSystemAppearance },
                    set: { enabled in
                        viewModel.setSubtitleMatchesSystemAppearance(enabled)
                    }
                ))
                .tint(.siloSwitchOn)

                Toggle("Save for this device and profile", isOn: Binding(
                    get: { viewModel.settings.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                ))
                .tint(.siloSwitchOn)
                .disabled(matchesSystem)
            } footer: {
                Text(matchesSystem
                     ? "Following this device's caption language, behavior, CC/SDH preference, and complete style from Accessibility settings."
                     : "Subtitles with their own built-in styling keep their original appearance; image-based subtitles keep their authored fonts and colors but follow the size, position, and background settings.")
            }

            Section("Text") {
                Picker("Font size", selection: appearanceEnumBinding(\.fontSize, SubtitleFontSizePreset.self)) {
                    ForEach(SubtitleFontSizePreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }

                Picker("Font family", selection: appearanceEnumBinding(\.fontFamily, SubtitleFontFamilyPreset.self)) {
                    ForEach(SubtitleFontFamilyPreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }

                Picker("Font color", selection: appearanceStringBinding(\.fontColor)) {
                    ForEach(SubtitleAppearance.fontColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                }

                if viewModel.settings.offersSubtitleTextOpacity {
                    textOpacityRow
                }

                Toggle("Text outline", isOn: appearanceBoolBinding(\.textOutline))
                    .tint(.siloSwitchOn)

                Picker("Outline color", selection: appearanceStringBinding(\.textOutlineColor)) {
                    ForEach(SubtitleAppearance.outlineColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                }
                .disabled(!viewModel.settings.subtitleAppearance.textOutline)
            }
            .disabled(matchesSystem)

            Section("Background") {
                Picker("Style", selection: appearanceBackgroundStyleBinding) {
                    ForEach(SubtitleBackgroundStylePreset.selectableCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }

                appearanceOpacityRow
                    .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)

                Picker("Color", selection: appearanceStringBinding(\.backgroundColor)) {
                    ForEach(SubtitleAppearance.backgroundColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                }
                .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)
            }
            .disabled(matchesSystem)

            Section("Layout") {
                Picker("Position", selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self)) {
                    ForEach(SubtitlePositionPreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            }
            .disabled(matchesSystem)
        }
        .navigationTitle("Subtitle Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceOpacityRow: some View {
        PercentField(
            label: "Opacity",
            accessibilityLabelText: "Background Opacity",
            min: 0,
            value: viewModel.settings.subtitleAppearance.backgroundOpacity
        ) { newValue in
            guard viewModel.settings.subtitleAppearance.backgroundOpacity != newValue else { return }
            viewModel.updateSubtitleAppearance { $0.backgroundOpacity = newValue }
        }
    }

    private var textOpacityRow: some View {
        PercentField(
            label: "Opacity",
            accessibilityLabelText: "Text Opacity",
            min: 1,
            value: viewModel.settings.subtitleAppearance.textOpacity
        ) { newValue in
            guard viewModel.settings.subtitleAppearance.textOpacity != newValue else { return }
            viewModel.updateSubtitleAppearance { $0.textOpacity = newValue }
        }
    }

    private static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    private var sessionSection: some View {
        Section("Session") {
            if !viewModel.isWatchPartyPlayback {
                Picker("Speed", selection: Binding(
                    get: { Self.speedOptions.min(by: {
                        abs($0 - viewModel.settings.playbackSpeed) < abs($1 - viewModel.settings.playbackSpeed)
                    }) ?? 1.0 },
                    set: { viewModel.setPlaybackSpeed($0) }
                )) {
                    ForEach(Self.speedOptions, id: \.self) { speed in
                        Text(speed == 1.0 ? "1×" : String(format: "%g×", speed)).tag(speed)
                    }
                }
            }
            sleepTimerPicker

            if sleepTimer.isActive {
                LabeledContent("Remaining") {
                    Text(PlayerTimeFormatter.formatHMS(Double(sleepTimer.remainingSeconds)))
                        .monospacedDigit()
                }
            }

            if !viewModel.isWatchPartyPlayback {
                Toggle("Auto-Play Next Episode", isOn: Binding(
                    get: { viewModel.settings.autoPlayNextEpisode },
                    set: { viewModel.settings.setAutoPlayNextEpisode($0) }
                ))
                .tint(.siloSwitchOn)
            }
        }
    }

    private var advancedSection: some View {
        Section {
            if let statsOverlayVisible {
                Toggle(isOn: statsOverlayVisible) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stats")
                        Text("Live overlay on the player")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.siloSwitchOn)
            }

            NavigationLink {
                advancedPage
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced")
                    Text("Route & playback diagnostics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var advancedPage: some View {
        List {
            Section("Route") {
                ForEach(viewModel.routeStatusRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                        Spacer()
                        Text(row.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            if viewModel.routeDecisionSummary != nil || !viewModel.routeWarnings.isEmpty {
                Section("Diagnostics") {
                    if let summary = viewModel.routeDecisionSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(viewModel.routeWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sleep timer

    private var sleepTimerPicker: some View {
        Picker("Sleep Timer", selection: Binding<Int>(
            get: { sleepTimer.isActive ? sleepTimerMinutesOption(remaining: sleepTimer.remainingSeconds) : 0 },
            set: { newValue in
                if newValue == 0 {
                    sleepTimer.cancel()
                } else {
                    sleepTimer.start(minutes: newValue)
                }
            }
        )) {
            Text("Off").tag(0)
            Text("5 min").tag(5)
            Text("15 min").tag(15)
            Text("30 min").tag(30)
            Text("45 min").tag(45)
            Text("1 hour").tag(60)
            Text("2 hours").tag(120)
        }
    }

    // MARK: - Appearance bindings

    /// Choosing Box with a fully transparent background would render
    /// nothing; give it the default opacity so the choice takes effect.
    private var appearanceBackgroundStyleBinding: Binding<String> {
        Binding(
            get: { viewModel.settings.subtitleAppearance.backgroundStyle.rawValue },
            set: { rawValue in
                guard let style = SubtitleBackgroundStylePreset(rawValue: rawValue),
                      viewModel.settings.subtitleAppearance.backgroundStyle != style else { return }
                viewModel.updateSubtitleAppearance { next in
                    next.backgroundStyle = style
                    if style == .box && next.backgroundOpacity == 0 {
                        next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                    }
                }
            }
        )
    }

    private func appearanceStringBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, String>) -> Binding<String> {
        Binding(
            get: { viewModel.settings.subtitleAppearance[keyPath: keyPath] },
            set: { value in
                viewModel.updateSubtitleAppearance { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func appearanceBoolBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.settings.subtitleAppearance[keyPath: keyPath] },
            set: { value in
                viewModel.updateSubtitleAppearance { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func appearanceEnumBinding<Value>(
        _ keyPath: WritableKeyPath<SubtitleAppearance, Value>,
        _ type: Value.Type
    ) -> Binding<String> where Value: RawRepresentable, Value.RawValue == String {
        Binding(
            get: { viewModel.settings.subtitleAppearance[keyPath: keyPath].rawValue },
            set: { rawValue in
                guard let value = Value(rawValue: rawValue) else { return }
                viewModel.updateSubtitleAppearance { $0[keyPath: keyPath] = value }
            }
        )
    }

    // MARK: - Helpers

    private func formatMs(_ ms: Int) -> String {
        if ms == 0 { return "0 ms" }
        let sign = ms > 0 ? "+" : ""
        return "\(sign)\(ms) ms"
    }

    /// Map the timer's remaining seconds back to the nearest whole-minute
    /// option tag for the picker. Picker values are the initial minute count,
    /// so this snaps the selection back to whichever preset the user picked.
    private func sleepTimerMinutesOption(remaining seconds: Int) -> Int {
        let minutes = (seconds + 59) / 60
        for candidate in [5, 15, 30, 45, 60, 120] {
            if minutes <= candidate { return candidate }
        }
        return 120
    }
}
#endif
