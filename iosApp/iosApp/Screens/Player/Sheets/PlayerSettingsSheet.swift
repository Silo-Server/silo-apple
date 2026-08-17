#if os(iOS)
import SwiftUI

/// Player configuration sheet. Apply-on-change — the VM's
/// `applySettingsToPlayer()` is already called on file-loaded; live mutation
/// re-applies one property at a time through the binding helpers below.
///
/// iOS-only: a real settings hierarchy (Video / Audio / Subtitles / Session
/// groups with disclosure sub-pages, diagnostics demoted to an Advanced
/// page; speed lives in the Session group — the overlay's quick pill hosts
/// Quality). tvOS uses `TVPlayerInfoHUD` and macOS uses
/// `MacPlayerOptionsPanel` instead.
struct PlayerSettingsSheet: View {
    let viewModel: PlayerViewModel
    let sleepTimer: SleepTimer
    /// Visibility of the iOS stats annotation. A binding rather than a
    /// one-shot action because the overlay itself has no dismiss affordance
    /// — this row is both the on and the off switch. Nil on platforms with
    /// no such overlay, which hides the row.
    var statsOverlayVisible: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss
    /// Slider position while the user is dragging the background-opacity
    /// slider; committed (and saved) once the drag ends.
    @State private var draftOpacity: Double?

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

            if viewModel.backendCapabilities.supportsVideoGravity {
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
                    Stepper(
                        value: Binding(
                            get: { viewModel.settings.subtitleSyncMs },
                            set: { newValue in
                                viewModel.settings.subtitleSyncMs = newValue
                                viewModel.setSubtitleSyncMilliseconds(newValue)
                            }
                        ),
                        in: -10000...10000,
                        step: 100
                    ) {
                        HStack {
                            Text("Subtitle Delay")
                            Spacer()
                            Text(formatMs(viewModel.settings.subtitleSyncMs))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
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
                    Text("Low contrast — dark text without a box or outline can be hard to read.")
                }
            }

            Section {
                Toggle("Use device settings", isOn: Binding(
                    get: { viewModel.settings.subtitleMatchesSystemAppearance },
                    set: { enabled in
                        viewModel.setSubtitleMatchesSystemAppearance(enabled)
                    }
                ))
                .tint(.continuumAccent)

                Toggle("Save for this device and profile", isOn: Binding(
                    get: { viewModel.settings.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                ))
                .tint(.continuumAccent)
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

                Toggle("Text outline", isOn: appearanceBoolBinding(\.textOutline))
                    .tint(.continuumAccent)

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
        let committed = Double(viewModel.settings.subtitleAppearance.backgroundOpacity)
        return HStack(spacing: 12) {
            Text("Opacity")
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
                var next = viewModel.settings.subtitleAppearance
                let percent = Int(value)
                if next.backgroundOpacity == percent { return }
                next.backgroundOpacity = percent
                Task { await viewModel.setSubtitleAppearance(next) }
            }
            .tint(.continuumAccent)
            Text("\(Int(draftOpacity ?? committed))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Background Opacity")
        .accessibilityValue("\(Int(draftOpacity ?? committed)) percent")
    }

    /// Speed ladder for the sheet's picker. Mirrors the ladder the old
    /// overlay quick menu offered (the overlay pill now hosts Quality).
    private static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    private var sessionSection: some View {
        Section("Session") {
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

            sleepTimerPicker

            if sleepTimer.isActive {
                LabeledContent("Remaining") {
                    Text(PlayerTimeFormatter.formatHMS(Double(sleepTimer.remainingSeconds)))
                        .monospacedDigit()
                }
            }

            Toggle("Auto-Play Next Episode", isOn: Binding(
                get: { viewModel.settings.autoPlayNextEpisode },
                set: { viewModel.settings.setAutoPlayNextEpisode($0) }
            ))
            .tint(.continuumAccent)
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
                .tint(.continuumAccent)
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

    // MARK: - Shared rows

    /// "Stop after" preset picker for the Session group.
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
                guard let style = SubtitleBackgroundStylePreset(rawValue: rawValue) else { return }
                var next = viewModel.settings.subtitleAppearance
                if next.backgroundStyle == style { return }
                next.backgroundStyle = style
                if style == .box && next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceStringBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, String>) -> Binding<String> {
        Binding(
            get: { viewModel.settings.subtitleAppearance[keyPath: keyPath] },
            set: { value in
                var next = viewModel.settings.subtitleAppearance
                next[keyPath: keyPath] = value
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceBoolBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.settings.subtitleAppearance[keyPath: keyPath] },
            set: { value in
                var next = viewModel.settings.subtitleAppearance
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
            get: { viewModel.settings.subtitleAppearance[keyPath: keyPath].rawValue },
            set: { rawValue in
                guard let value = Value(rawValue: rawValue) else { return }
                var next = viewModel.settings.subtitleAppearance
                next[keyPath: keyPath] = value
                Task { await viewModel.setSubtitleAppearance(next) }
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
