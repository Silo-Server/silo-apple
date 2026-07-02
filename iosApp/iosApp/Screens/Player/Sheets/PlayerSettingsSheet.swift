import SwiftUI

/// Cross-platform stand-in for `Stepper`. On iOS we use Stepper; on tvOS we
/// fall back to a Picker that enumerates the full integer range by `step`
/// (tvOS omits Stepper, and a focus-driven list spinner matches Apple's
/// remote idiom better than a continuous stepper anyway).
private struct RangeSpinner<Value: Hashable & Strideable>: View
where Value.Stride: SignedInteger {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let display: (Value) -> String
    let onCommit: () -> Void

    var body: some View {
        #if os(tvOS)
        Picker(title, selection: Binding(
            get: { value },
            set: { newValue in
                value = newValue
                onCommit()
            }
        )) {
            ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { option in
                Text(display(option)).tag(option)
            }
        }
        #else
        Stepper(
            value: Binding(
                get: { value },
                set: { newValue in
                    value = newValue
                    onCommit()
                }
            ),
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
        #endif
    }
}

/// Same as `RangeSpinner` but for `Double` values — Stepper's Strideable
/// bound insists on SignedInteger so we special-case doubles.
private struct DoubleRangeSpinner: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String
    let onCommit: () -> Void

    var body: some View {
        #if os(tvOS)
        let options = Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
        Picker(title, selection: Binding(
            get: { nearest(to: value, in: options) },
            set: { newValue in
                value = newValue
                onCommit()
            }
        )) {
            ForEach(options, id: \.self) { option in
                Text(display(option)).tag(option)
            }
        }
        #else
        Stepper(
            value: Binding(
                get: { value },
                set: { newValue in
                    value = newValue
                    onCommit()
                }
            ),
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
        #endif
    }

    private func nearest(to target: Double, in options: [Double]) -> Double {
        options.min(by: { abs($0 - target) < abs($1 - target) }) ?? target
    }
}

/// Player configuration sheet. Apply-on-change — the VM's
/// `applySettingsToPlayer()` is already called on file-loaded; live mutation
/// re-applies one property at a time through the binding helpers below.
///
/// iOS renders a real settings hierarchy (Video / Audio / Subtitles /
/// Session groups with disclosure sub-pages, diagnostics demoted to an
/// Advanced page, no speed picker — speed lives in the overlay's quick
/// menu). tvOS and macOS keep the flat form the HUD / Mac sheet expect.
struct PlayerSettingsSheet: View {
    let viewModel: PlayerViewModel
    let sleepTimer: SleepTimer

    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(iOS)
        iosBody
        #else
        legacyForm
        #endif
    }

    // MARK: - iOS hierarchy

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            List {
                videoSection
                audioSection
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

            if viewModel.backendCapabilities.supportsHDRToggle {
                Toggle("HDR Passthrough", isOn: Binding(
                    get: { viewModel.settings.hdrEnabled },
                    set: { newValue in
                        viewModel.setHDREnabled(newValue)
                    }
                ))
            }
        } header: {
            Text("Video")
        } footer: {
            if viewModel.backendCapabilities.supportsHDRToggle {
                Text("Disable HDR if colors look washed out or your display tone-maps incorrectly.")
            }
        }
    }

    private var activeQualityLabel: String {
        viewModel.qualityOptions.first(where: { $0.id == viewModel.activeQualityId })?.label ?? "Auto"
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
    private var audioSection: some View {
        if viewModel.backendCapabilities.supportsAudioDelay {
            Section("Audio") {
                RangeSpinner(
                    title: "Audio Delay",
                    value: Binding(
                        get: { viewModel.settings.audioSyncMs },
                        set: { viewModel.settings.audioSyncMs = $0 }
                    ),
                    range: -5000...5000,
                    step: 50,
                    display: { formatMs($0) },
                    onCommit: {
                        viewModel.setAudioSyncMilliseconds(viewModel.settings.audioSyncMs)
                    }
                )
            }
        }
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
                            set: { viewModel.settings.subtitleSyncMs = $0 }
                        ),
                        range: -10000...10000,
                        step: 100,
                        display: { formatMs($0) },
                        onCommit: {
                            viewModel.setSubtitleSyncMilliseconds(viewModel.settings.subtitleSyncMs)
                        }
                    )
                }
            }
        }
    }

    /// "Large · Outline · Bottom"-style value label for the Appearance row.
    private var appearanceSummary: String {
        let appearance = viewModel.settings.subtitleAppearance
        return [
            appearance.fontSize.label,
            appearance.backgroundStyle.label,
            appearance.position.label,
        ].joined(separator: " · ")
    }

    private var subtitleAppearancePage: some View {
        List {
            Section {
                subtitleAppearancePreview
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle("Save for this device and profile", isOn: Binding(
                    get: { viewModel.settings.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                ))
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

                Picker("Outline color", selection: appearanceStringBinding(\.textOutlineColor)) {
                    ForEach(SubtitleAppearance.outlineColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                }
                .disabled(!viewModel.settings.subtitleAppearance.textOutline && viewModel.settings.subtitleAppearance.backgroundStyle != .outline)
            }

            Section("Background") {
                Picker("Style", selection: appearanceEnumBinding(\.backgroundStyle, SubtitleBackgroundStylePreset.self)) {
                    ForEach(SubtitleBackgroundStylePreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }

                Picker("Opacity", selection: appearanceIntBinding(\.backgroundOpacity)) {
                    ForEach(Array(stride(from: 0, through: 100, by: 5)), id: \.self) { value in
                        Text("\(value)%").tag(String(value))
                    }
                }
                .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)

                Picker("Color", selection: appearanceStringBinding(\.backgroundColor)) {
                    ForEach(SubtitleAppearance.backgroundColors, id: \.hex) { color in
                        Text(color.label).tag(color.hex)
                    }
                }
                .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)
            }

            Section("Layout") {
                Picker("Position", selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self)) {
                    ForEach(SubtitlePositionPreset.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            }
        }
        .navigationTitle("Subtitle Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Live approximation of the configured subtitle style over a dark
    /// film-frame stand-in. The real pipeline renders through libass; this
    /// mirrors the font/color/outline/background/position choices closely
    /// enough to preview a change without leaving the sheet.
    private var subtitleAppearancePreview: some View {
        let appearance = viewModel.settings.subtitleAppearance

        return ZStack(alignment: previewAlignment(for: appearance.position)) {
            LinearGradient(
                colors: [Color(white: 0.32), Color(white: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            previewSampleText(appearance)
                .padding(.vertical, appearance.position == .lowerThird ? 26 : 12)
                .padding(.horizontal, 16)
        }
        .frame(height: 118)
        .clipped()
    }

    private func previewAlignment(for position: SubtitlePositionPreset) -> Alignment {
        switch position {
        case .top: return .top
        case .lowerThird, .bottom: return .bottom
        }
    }

    @ViewBuilder
    private func previewSampleText(_ appearance: SubtitleAppearance) -> some View {
        let size = appearance.fontSize.pointSize * 0.45
        let font: Font = {
            switch appearance.fontFamily {
            case .serif: return .system(size: size, weight: .semibold, design: .serif)
            case .monospace: return .system(size: size, weight: .semibold, design: .monospaced)
            case .sansSerif: return .system(size: size, weight: .semibold)
            default: return .custom(appearance.fontFamily.assFontName, size: size)
            }
        }()
        let hasOutline = appearance.textOutline || appearance.backgroundStyle == .outline
        let outlineColor = Color(hex: appearance.textOutlineColor)

        Text("Subtitles will look like this")
            .font(font)
            .foregroundStyle(Color(hex: appearance.fontColor))
            .shadow(color: hasOutline ? outlineColor : .clear, radius: hasOutline ? 1.2 : 0)
            .shadow(color: hasOutline ? outlineColor : .clear, radius: hasOutline ? 1.2 : 0)
            .shadow(
                color: appearance.backgroundStyle == .shadow ? .black.opacity(0.85) : .clear,
                radius: 3, y: 2
            )
            .padding(.horizontal, appearance.backgroundStyle == .box ? 10 : 0)
            .padding(.vertical, appearance.backgroundStyle == .box ? 4 : 0)
            .background {
                if appearance.backgroundStyle == .box {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(hex: appearance.backgroundColor)
                            .opacity(Double(appearance.backgroundOpacity) / 100))
                }
            }
    }

    private var sessionSection: some View {
        Section("Session") {
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
        }
    }

    private var advancedSection: some View {
        Section {
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
    #endif

    // MARK: - Legacy form (tvOS + macOS)

    #if !os(iOS)
    private var legacyForm: some View {
        Form {
            routeSection
            qualitySection
            playbackSection
            hdrSection
            syncSection
            sleepSection
            subtitleStylingSection
        }
        #if !os(tvOS)
        .scrollContentBackground(.hidden)
        #else
        .background(Color.black.opacity(0.85).ignoresSafeArea())
        #endif
    }

    private var routeSection: some View {
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

            if let summary = viewModel.routeDecisionSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            ForEach(Array(viewModel.routeWarnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private var qualitySection: some View {
        Section("Quality") {
            Picker("Quality", selection: Binding(
                get: { viewModel.activeQualityId },
                set: { newValue in
                    viewModel.switchQuality(newValue)
                }
            )) {
                ForEach(viewModel.qualityOptions) { option in
                    if let subtitle = option.subtitle {
                        VStack(alignment: .leading) {
                            Text(option.label)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(option.id)
                    } else {
                        Text(option.label).tag(option.id)
                    }
                }
            }

            if viewModel.isQualitySwitching {
                HStack {
                    ProgressView()
                    Text("Switching quality...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = viewModel.qualitySwitchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            // Speed — 0.5x through 3.0x, step 0.25x. Constrained to a Picker
            // so the tvOS remote gets a spinner instead of a free slider
            // (which doesn't focus well).
            Picker("Speed", selection: Binding(
                get: { viewModel.settings.playbackSpeed },
                set: { newValue in
                    viewModel.setPlaybackSpeed(newValue)
                }
            )) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { speed in
                    Text(speed == 1.0 ? "Normal (1.0×)" : String(format: "%.2f×", speed))
                        .tag(speed)
                }
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

            Toggle("Auto-play next episode", isOn: Binding(
                get: { viewModel.settings.autoPlayNextEpisode },
                set: { viewModel.settings.setAutoPlayNextEpisode($0) }
            ))
        }
    }

    private var hdrSection: some View {
        Group {
            if viewModel.backendCapabilities.supportsHDRToggle {
                Section {
                    Toggle("HDR passthrough", isOn: Binding(
                        get: { viewModel.settings.hdrEnabled },
                        set: { newValue in
                            viewModel.setHDREnabled(newValue)
                        }
                    ))
                    Text("Disable if colors look washed out or your display tone-maps incorrectly.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } header: {
                    Text("Display")
                }
            }
        }
    }

    private var syncSection: some View {
        Group {
            if viewModel.backendCapabilities.supportsAudioDelay
                || viewModel.backendCapabilities.supportsSubtitleDelay {
                Section("Sync") {
                    if viewModel.backendCapabilities.supportsAudioDelay {
                        RangeSpinner(
                            title: "Audio delay",
                            value: Binding(
                                get: { viewModel.settings.audioSyncMs },
                                set: { viewModel.settings.audioSyncMs = $0 }
                            ),
                            range: -5000...5000,
                            step: 50,
                            display: { formatMs($0) },
                            onCommit: {
                                viewModel.setAudioSyncMilliseconds(viewModel.settings.audioSyncMs)
                            }
                        )
                    }

                    if viewModel.backendCapabilities.supportsSubtitleDelay {
                        RangeSpinner(
                            title: "Subtitle delay",
                            value: Binding(
                                get: { viewModel.settings.subtitleSyncMs },
                                set: { viewModel.settings.subtitleSyncMs = $0 }
                            ),
                            range: -10000...10000,
                            step: 100,
                            display: { formatMs($0) },
                            onCommit: {
                                viewModel.setSubtitleSyncMilliseconds(viewModel.settings.subtitleSyncMs)
                            }
                        )
                    }
                }
            }
        }
    }

    private var sleepSection: some View {
        Section("Sleep timer") {
            sleepTimerPicker

            if sleepTimer.isActive {
                HStack {
                    Text("Remaining")
                    Spacer()
                    Text(PlayerTimeFormatter.formatHMS(Double(sleepTimer.remainingSeconds)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var subtitleStylingSection: some View {
        Group {
            if viewModel.backendCapabilities.supportsSubtitleStyling {
                Section("Subtitle appearance") {
                    Toggle("Save for this device and profile", isOn: Binding(
                        get: { viewModel.settings.subtitleUsesDeviceAppearanceOverride },
                        set: { enabled in
                            Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                        }
                    ))

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

                    Picker("Outline color", selection: appearanceStringBinding(\.textOutlineColor)) {
                        ForEach(SubtitleAppearance.outlineColors, id: \.hex) { color in
                            Text(color.label).tag(color.hex)
                        }
                    }
                    .disabled(!viewModel.settings.subtitleAppearance.textOutline && viewModel.settings.subtitleAppearance.backgroundStyle != .outline)

                    Picker("Background style", selection: appearanceEnumBinding(\.backgroundStyle, SubtitleBackgroundStylePreset.self)) {
                        ForEach(SubtitleBackgroundStylePreset.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }

                    Picker("Background opacity", selection: appearanceIntBinding(\.backgroundOpacity)) {
                        ForEach(Array(stride(from: 0, through: 100, by: 5)), id: \.self) { value in
                            Text("\(value)%").tag(String(value))
                        }
                    }
                    .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)

                    Picker("Background color", selection: appearanceStringBinding(\.backgroundColor)) {
                        ForEach(SubtitleAppearance.backgroundColors, id: \.hex) { color in
                            Text(color.label).tag(color.hex)
                        }
                    }
                    .disabled(viewModel.settings.subtitleAppearance.backgroundStyle != .box)

                    Picker("Position", selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self)) {
                        ForEach(SubtitlePositionPreset.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Shared rows

    /// "Stop after" preset picker shared by both layouts.
    private var sleepTimerPicker: some View {
        Picker(sleepTimerPickerTitle, selection: Binding<Int>(
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

    private var sleepTimerPickerTitle: String {
        #if os(iOS)
        return "Sleep Timer"
        #else
        return "Stop after"
        #endif
    }

    // MARK: - Appearance bindings

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

    private func appearanceIntBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, Int>) -> Binding<String> {
        Binding(
            get: { String(viewModel.settings.subtitleAppearance[keyPath: keyPath]) },
            set: { value in
                guard let intValue = Int(value) else { return }
                var next = viewModel.settings.subtitleAppearance
                next[keyPath: keyPath] = intValue
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
