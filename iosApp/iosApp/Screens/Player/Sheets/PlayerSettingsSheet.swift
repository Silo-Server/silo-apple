import SwiftUI

#if os(iOS)
/// `Stepper` with a trailing value label that commits on every step.
private struct RangeSpinner<Value: Strideable>: View {
    let title: LocalizedStringResource
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
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            List {
                videoSection
                subtitlesSection
                sessionSection
                advancedSection
            }
            .navigationTitle(Text(.playerSettingsSheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(.commonDone) }
                }
            }
        }
        // The sheet floats over an always-dark player; pin dark so the
        // grouped list renders dark regardless of the app's scheme.
        .preferredColorScheme(.dark)
    }

    private var videoSection: some View {
        Section {
            if viewModel.hasQualityChoice {
                NavigationLink {
                    qualityPage
                } label: {
                    LabeledContent {
                        Text(activeQualityLabel)
                    } label: {
                        Text(.optionsQuality)
                    }
                }
            }

            Picker(selection: Binding(
                get: { viewModel.settings.videoGravity },
                set: { newValue in
                    viewModel.setVideoGravity(newValue)
                }
            )) {
                ForEach(VideoGravity.allCases, id: \.self) { gravity in
                    Text(gravity.label).tag(gravity)
                }
            } label: {
                Text(.playerHudAspect)
            }
        } header: {
            Text(.optionsTabVideo)
        }
    }

    private var activeQualityLabel: String {
        viewModel.activeQualityOption?.label
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
                            if option.id == viewModel.highlightedQualityOptionId {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(viewModel.isQualitySwitching)
                }
            } footer: {
                if viewModel.isQualitySwitching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(.playerQualitySwitching)
                    }
                } else if let error = viewModel.qualitySwitchError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(Text(.optionsQuality))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var subtitlesSection: some View {
        if viewModel.backendCapabilities.supportsSubtitleStyling
            || viewModel.backendCapabilities.supportsSubtitleDelay {
            Section {
                if viewModel.backendCapabilities.supportsSubtitleStyling {
                    NavigationLink {
                        subtitleAppearancePage
                    } label: {
                        LabeledContent {
                            Text(appearanceSummary)
                        } label: {
                            Text(.playerHudSubtitleAppearance)
                        }
                    }
                }

                if viewModel.backendCapabilities.supportsSubtitleDelay {
                    RangeSpinner(
                        title: .playerSettingsSubtitleDelayTitle,
                        value: Binding(
                            get: { viewModel.settings.subtitleSyncMs },
                            set: { viewModel.setSubtitleSyncMilliseconds($0) }
                        ),
                        range: -10000...10000,
                        step: 100,
                        display: { formatMs($0) }
                    )
                }
            } header: {
                Text(.playerTracksSubtitles)
            }
        }
    }

    /// "Large · Box · Bottom"-style value label for the Appearance row.
    private var appearanceSummary: String {
        if viewModel.settings.subtitleMatchesSystemAppearance {
            return AppLanguage.string(.playerSubtitlesUsingDevice, locale: locale)
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
                    Text(.playerSubtitlesLowLegibility)
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.settings.subtitleMatchesSystemAppearance },
                    set: { enabled in
                        viewModel.setSubtitleMatchesSystemAppearance(enabled)
                    }
                )) {
                    Text(.playerSubtitlesUseDeviceSettings)
                }
                .tint(.siloSwitchOn)

                Toggle(isOn: Binding(
                    get: { viewModel.settings.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                )) {
                    Text(.playerSubtitlesOnlyOnThisDevice)
                }
                .tint(.siloSwitchOn)
                .disabled(matchesSystem)
            } footer: {
                Text(matchesSystem
                     ? LocalizedStringResource.playerSubtitlesDeviceStyleNote
                     : .playerSubtitlesBuiltInStylingNote)
            }

            Section {
                Picker(selection: appearanceEnumBinding(\.fontSize, SubtitleFontSizePreset.self)) {
                    ForEach(SubtitleFontSizePreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    Text(.playerSubtitlesStyleFontSize)
                }

                Picker(selection: appearanceEnumBinding(\.fontFamily, SubtitleFontFamilyPreset.self)) {
                    ForEach(SubtitleFontFamilyPreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    Text(.playerSubtitlesStyleFontFamily)
                }

                Picker(selection: appearanceStringBinding(\.fontColor)) {
                    ForEach(SubtitleAppearance.fontColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                } label: {
                    Text(.playerSubtitlesStyleFontColor)
                }

                if viewModel.settings.offersSubtitleTextOpacity {
                    textOpacityRow
                }

                Toggle(isOn: appearanceBoolBinding(\.textOutline)) {
                    Text(.playerSubtitlesStyleTextOutline)
                }
                .tint(.siloSwitchOn)

                Picker(selection: appearanceStringBinding(\.textOutlineColor)) {
                    ForEach(SubtitleAppearance.outlineColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                } label: {
                    Text(.playerSubtitlesStyleOutlineColor)
                }
                .disabled(!viewModel.settings.subtitleAppearance.textOutline)
            } header: {
                Text(.playerSubtitlesStyleTextSection)
            }
            .disabled(matchesSystem)

            Section {
                Picker(selection: appearanceBackgroundStyleBinding) {
                    ForEach(SubtitleBackgroundStylePreset.selectableCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    Text(.playerSubtitlesStyleBackgroundStyle)
                }

                appearanceOpacityRow
                    .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)

                Picker(selection: appearanceStringBinding(\.backgroundColor)) {
                    ForEach(SubtitleAppearance.backgroundColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                } label: {
                    Text(.playerSubtitlesStyleBackgroundColorShort)
                }
                .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)
            } header: {
                Text(.playerSubtitlesStyleBackground)
            }
            .disabled(matchesSystem)

            Section {
                Picker(selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self)) {
                    ForEach(SubtitlePositionPreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    Text(.playerSubtitlesStylePosition)
                }
            } header: {
                Text(.playerSubtitlesStyleLayoutSection)
            }
            .disabled(matchesSystem)
        }
        .navigationTitle(Text(.playerSubtitlesAppearanceTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceOpacityRow: some View {
        PercentField(
            label: AppLanguage.string(.playerSubtitlesStyleOpacity, locale: locale),
            accessibilityLabelText: AppLanguage.string(.playerSubtitlesStyleBackgroundOpacityLabel, locale: locale),
            min: 0,
            value: viewModel.settings.subtitleAppearance.backgroundOpacity
        ) { newValue in
            guard viewModel.settings.subtitleAppearance.backgroundOpacity != newValue else { return }
            viewModel.updateSubtitleAppearance { $0.backgroundOpacity = newValue }
        }
    }

    private var textOpacityRow: some View {
        PercentField(
            label: AppLanguage.string(.playerSubtitlesStyleOpacity, locale: locale),
            accessibilityLabelText: AppLanguage.string(.playerSubtitlesStyleTextOpacityLabel, locale: locale),
            min: 1,
            value: viewModel.settings.subtitleAppearance.textOpacity
        ) { newValue in
            guard viewModel.settings.subtitleAppearance.textOpacity != newValue else { return }
            viewModel.updateSubtitleAppearance { $0.textOpacity = newValue }
        }
    }

    private static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    private var sessionSection: some View {
        Section {
            if !viewModel.isWatchPartyPlayback {
                Picker(selection: Binding(
                    get: { Self.speedOptions.min(by: {
                        abs($0 - viewModel.settings.playbackSpeed) < abs($1 - viewModel.settings.playbackSpeed)
                    }) ?? 1.0 },
                    set: { viewModel.setPlaybackSpeed($0) }
                )) {
                    ForEach(Self.speedOptions, id: \.self) { speed in
                        Text(verbatim: speed == 1.0 ? "1×" : String(format: "%g×", speed)).tag(speed)
                    }
                } label: {
                    Text(.playerSettingsSpeed)
                }
            }
            sleepTimerPicker

            if sleepTimer.isActive {
                LabeledContent {
                    Text(PlayerTimeFormatter.formatHMS(Double(sleepTimer.remainingSeconds)))
                        .monospacedDigit()
                } label: {
                    Text(.playerSleepTimerRemaining)
                }
            }

            if !viewModel.isWatchPartyPlayback {
                Toggle(isOn: Binding(
                    get: { viewModel.settings.autoPlayNextEpisode },
                    set: { viewModel.settings.setAutoPlayNextEpisode($0) }
                )) {
                    Text(.settingsControlAutoplay)
                }
                .tint(.siloSwitchOn)
            }
        } header: {
            Text(.playerSettingsSession)
        }
    }

    private var advancedSection: some View {
        Section {
            if let statsOverlayVisible {
                Toggle(isOn: statsOverlayVisible) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.optionsTabStats)
                        Text(.playerStatsOverlayNote)
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
                    Text(.playerSettingsSectionAdvanced)
                    Text(.playerSettingsAdvancedNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var advancedPage: some View {
        List {
            Section {
                ForEach(viewModel.routeStatusRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                        Spacer()
                        Text(row.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text(.playerHudRoute)
            }

            if viewModel.routeDecisionSummary != nil || !viewModel.routeWarnings.isEmpty {
                Section {
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
                } header: {
                    Text(.playerSettingsDiagnostics)
                }
            }
        }
        .navigationTitle(Text(.playerSettingsSectionAdvanced))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sleep timer

    private var sleepTimerPicker: some View {
        Picker(selection: Binding<Int>(
            get: { sleepTimer.isActive ? sleepTimerMinutesOption(remaining: sleepTimer.remainingSeconds) : 0 },
            set: { newValue in
                if newValue == 0 {
                    sleepTimer.cancel()
                } else {
                    sleepTimer.start(minutes: newValue)
                }
            }
        )) {
            Text(.playerSleepTimerOff).tag(0)
            Text(.playerSleepTimerMinutesOption(5)).tag(5)
            Text(.playerSleepTimerMinutesOption(15)).tag(15)
            Text(.playerSleepTimerMinutesOption(30)).tag(30)
            Text(.playerSleepTimerMinutesOption(45)).tag(45)
            Text(.playerSleepTimerHours(1)).tag(60)
            Text(.playerSleepTimerHours(2)).tag(120)
        } label: {
            Text(.playerSleepTimerPickerTitle)
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
