#if os(tvOS)
import SwiftUI

/// Infuse-style floating top-center HUD. A pill-tab header (Info / Video /
/// Audio / Subtitles / Chapters) selects which content pane renders below.
/// Drops on top of the video with no dimming backdrop so playback stays
/// visible, matching the "HUD over media" idiom rather than a modal sheet.
/// Menu dismisses via `onExitCommand` on the host view.
///
/// Focus model (see docs/tvos-focus.md): every interactive row is a real
/// `Button` and movement is owned entirely by the tvOS focus engine —
/// columns are `.focusSection()`s and the tab bar routes entry to the
/// active pill with `defaultFocus(priority: .userInitiated)`. `@FocusState`
/// is used only to seed focus (HUD open, dialog open) and to restore it
/// (dialog close), never to drive per-press movement. The two read-only
/// panes (Info / Stats) are single composite focusables that page their
/// scroll content, which is the sanctioned exception.
struct TVPlayerInfoHUD: View {
    let viewModel: PlayerViewModel
    @Binding var activeTab: Tab
    /// Focus target for the tab-bar pills, owned by `TVPlayerControls`.
    /// Sharing this via `@FocusState.Binding` lets the parent seed focus on
    /// a specific pill when the HUD opens, which is critical: without a
    /// deterministic initial focus the Menu button has nothing to bubble
    /// `onExitCommand` from and the user can get stuck.
    @FocusState.Binding var focusedTab: Tab?
    let onDismiss: () -> Void

    enum Tab: Hashable, CaseIterable {
        case info, stats, video, audio, subtitles, chapters

        var title: String {
            switch self {
            case .info:      return "Info"
            case .stats:     return "Stats"
            case .video:     return "Video"
            case .audio:     return "Audio"
            case .subtitles: return "Subtitles"
            case .chapters:  return "Chapters"
            }
        }
    }

    /// Tabs shown for the current session. Info + Video are always available;
    /// Audio / Subtitles / Chapters disappear when the stream has none of
    /// those — Infuse hides rather than disables, which keeps the bar tidy.
    ///
    /// Subtitles also appear when the stream has *no* tracks but the server's
    /// AI can produce them (ASR transcription, or translating an existing text
    /// track). Without this, a file with no subtitles would hide the Subtitles
    /// tab entirely — and with it the only entry point to "AI Subtitles…",
    /// which is exactly the case where transcription is most useful. Uses the
    /// same `hasActionableSource` probe the pane gates its AI row on.
    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.info, .stats, .video]
        if !viewModel.audioTracks.isEmpty { tabs.append(.audio) }
        if !viewModel.subtitleTracks.isEmpty
            || SubtitleTranslateMenu.hasActionableSource(viewModel)
            || viewModel.subtitleSearchAvailable {
            tabs.append(.subtitles)
        }
        if !viewModel.chapters.isEmpty { tabs.append(.chapters) }
        return tabs
    }

    var body: some View {
        VStack(spacing: 14) {
            tabBar
                .padding(.top, 32)
            panel
                .padding(.horizontal, 200)
            Spacer(minLength: 0)
        }
        .onAppear {
            if !availableTabs.contains(activeTab), let first = availableTabs.first {
                activeTab = first
            }
            // If the parent didn't seed focus (edge case on re-present), at
            // least make sure focus lands on the active tab so Menu has a
            // handler to bubble to.
            if focusedTab == nil {
                focusedTab = activeTab
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 12) {
            ForEach(availableTabs, id: \.self) { tab in
                TabPill(
                    title: tab.title,
                    isSelected: activeTab == tab,
                    focusedTab: $focusedTab,
                    tab: tab,
                    onSelect: { activeTab = tab }
                )
            }
        }
        .focusSection()
        // Rail: moving Up from the panel must land on the *active* pill, not
        // the geometrically nearest one — with focus-driven selection a
        // nearest-pill landing would switch panes as a side effect.
        .defaultFocus($focusedTab, activeTab, priority: .userInitiated)
    }

    // MARK: - Panel

    private var panel: some View {
        Group {
            switch activeTab {
            case .info:      InfoPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .stats:     StatsPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .video:     VideoPane(viewModel: viewModel)
            case .audio:     AudioPane(viewModel: viewModel)
            case .subtitles: SubtitlesPane(viewModel: viewModel, onCloseHUD: onDismiss)
            case .chapters:  ChaptersPane(viewModel: viewModel, onSelect: onDismiss)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // Width sits at ~60% of a 1920pt tvOS frame. Height is fixed at the
        // tallest pane's needs — content-hugging here would resize the panel
        // on every tab swap, which cascades into a SwiftUI relayout pass.
        .frame(maxWidth: 1100, minHeight: 380, maxHeight: 380)
        // Glass carries enough light that the panel lifts off the video
        // without extra dark tint; the stroke + shadow still define the
        // edge over a fully-black frame. Low-power TVs draw a flat
        // translucent fill instead (see siloPlayerGlass).
        .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .focusSection()
    }

    /// Used by the composite Info/Stats panes when Up is pressed at the top
    /// of their scroll content. Button-based panes don't need this — the
    /// tab bar's `defaultFocus` rail routes native Up movement instead.
    private func focusActiveTab() {
        guard availableTabs.contains(activeTab) else {
            focusedTab = availableTabs.first
            return
        }
        focusedTab = activeTab
    }
}

// MARK: - Tab pill

private struct TabPill: View {
    let title: String
    let isSelected: Bool
    @FocusState.Binding var focusedTab: TVPlayerInfoHUD.Tab?
    let tab: TVPlayerInfoHUD.Tab
    let onSelect: () -> Void

    private var isFocused: Bool { focusedTab == tab }

    var body: some View {
        Button(action: onSelect) {
            Text(title)
        }
        .buttonStyle(HUDTabPillStyle(isSelected: isSelected))
        .focused($focusedTab, equals: tab)
        // Focus-driven selection: moving the remote across tabs swaps
        // the pane below without requiring a Select press. Matches the
        // native Apple TV segmented-control idiom.
        .onChange(of: isFocused) { _, focused in
            if focused { onSelect() }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HUDTabPillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HUDTabPillBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct HUDTabPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).stroke(strokeColor, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isSelected)
    }

    private var foreground: Color {
        (isSelected || isFocused) ? .black : .white
    }

    private var background: Color {
        if isSelected { return .white }
        if isFocused  { return .white.opacity(0.9) }
        return .black.opacity(0.45)
    }

    private var strokeColor: Color {
        (isSelected || isFocused) ? .clear : .white.opacity(0.18)
    }
}

// MARK: - Shared column header

private struct PaneColumn<Content: View>: View {
    let header: String
    let content: () -> Content

    init(_ header: String, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(header.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HUDScrollablePane<Content: View>: View {
    let accessibilityLabel: String
    let scrollTargetIDs: [String]
    let onMoveToTabs: () -> Void
    let content: () -> Content

    @State private var scrollTargetIndex: Int = 0
    @FocusState private var isFocused: Bool

    init(
        accessibilityLabel: String,
        scrollTargetIDs: [String] = [],
        onMoveToTabs: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.scrollTargetIDs = scrollTargetIDs
        self.onMoveToTabs = onMoveToTabs
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .focusable(true)
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused ? Color.white.opacity(0.86) : Color.clear, lineWidth: 2)
                    .padding(-10)
            )
            .scaleEffect(isFocused ? 1.01 : 1)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .accessibilityLabel(accessibilityLabel)
            .onMoveCommand { direction in
                handleMove(direction, proxy: proxy)
            }
            .onChange(of: scrollTargetIDs) { _, targets in
                scrollTargetIndex = min(scrollTargetIndex, max(targets.count - 1, 0))
            }
        }
    }

    private func handleMove(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard isFocused else { return }

        let nextIndex: Int
        switch direction {
        case .up:
            guard !scrollTargetIDs.isEmpty, scrollTargetIndex > 0 else {
                onMoveToTabs()
                return
            }
            nextIndex = max(scrollTargetIndex - 1, 0)
        case .down:
            guard !scrollTargetIDs.isEmpty else { return }
            nextIndex = min(scrollTargetIndex + 1, scrollTargetIDs.count - 1)
        default:
            return
        }

        guard nextIndex != scrollTargetIndex else { return }
        scrollTargetIndex = nextIndex

        withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
            proxy.scrollTo(scrollTargetIDs[nextIndex], anchor: .top)
        }
    }
}

/// Right-aligned "label — value" row used in the Info and options columns.
private struct LabelValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Row chrome

/// Shared row chrome for every interactive HUD row: white fill when focused,
/// optional faint wash when it represents the current selection. Owns all
/// focus appearance via `@Environment(\.isFocused)` and suppresses the system
/// halo — same idiom as `TVPillButtonStyle`.
private struct HUDRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HUDRowButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            isSelected: isSelected
        )
    }
}

private struct HUDRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var background: Color {
        if isFocused { return .white }
        if isSelected { return .white.opacity(0.14) }
        return .clear
    }
}

/// Chevron row that opens a picker dialog. Label/value colors invert when
/// the row is focused; movement and Select handling are native.
private struct HUDSettingRow: View {
    let label: String
    let value: String
    var colorHex: String? = nil
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDSettingRowLabel(
                label: label,
                value: value,
                colorHex: colorHex,
                systemImage: systemImage,
                showsChevron: true
            )
        }
        .buttonStyle(HUDRowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Boolean row that flips on Select — one press instead of the previous
/// open-dialog → pick → close round-trip.
private struct HUDToggleRow: View {
    let label: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button { onToggle(!isOn) } label: {
            HUDSettingRowLabel(
                label: label,
                value: HUDPickerOptions.boolLabel(isOn),
                showsChevron: false
            )
        }
        .buttonStyle(HUDRowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(HUDPickerOptions.boolLabel(isOn))
        .accessibilityAddTraits(.isToggle)
    }
}

private struct HUDSettingRowLabel: View {
    let label: String
    let value: String
    var colorHex: String? = nil
    var systemImage: String? = nil
    let showsChevron: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 18)
            HStack(spacing: 10) {
                if let colorHex {
                    ColorSwatch(hex: colorHex)
                }
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isFocused ? .black.opacity(0.78) : .white.opacity(0.72))
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.45))
                }
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

// MARK: - Info pane

private struct InfoPane: View {
    let viewModel: PlayerViewModel
    let onMoveToTabs: () -> Void

    private static let topAnchor = "info.top"
    private static let bottomAnchor = "info.bottom"

    var body: some View {
        HUDScrollablePane(
            accessibilityLabel: "Info details",
            // Top/bottom anchors so Down can page a long overview to its end
            // and Up returns to the top, then to the tabs. Without any targets
            // the pane was a dead focus stop that couldn't scroll at all.
            scrollTargetIDs: [Self.topAnchor, Self.bottomAnchor],
            onMoveToTabs: onMoveToTabs
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0).id(Self.topAnchor)
                HStack(alignment: .top, spacing: 48) {
                PaneColumn("Title") {
                    if let series = viewModel.metadata.seriesTitle, !series.isEmpty {
                        Text(series.uppercased())
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(1.8)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(displayTitle)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let episode = viewModel.metadata.episodeTag {
                        Text(episode)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if !metaBits.isEmpty {
                        Text(metaBits.joined(separator: "  ·  "))
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.65))
                            .monospacedDigit()
                    }
                    if let overview = viewModel.metadata.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }

                PaneColumn("Stream") {
                    if !viewModel.metadata.badges.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(viewModel.metadata.badges, id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: 16, weight: .semibold))
                                    .tracking(0.4)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .overlay(
                                        Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    ForEach(streamRows, id: \.0) { row in
                        LabelValueRow(label: row.0, value: row.1)
                    }
                    if let chapter = currentChapterTitle {
                        LabelValueRow(label: "Chapter", value: chapter)
                    }
                }
                }
                Color.clear.frame(height: 0).id(Self.bottomAnchor)
            }
        }
    }

    private var displayTitle: String {
        viewModel.metadata.primaryTitle.isEmpty
            ? viewModel.title
            : viewModel.metadata.primaryTitle
    }

    private var metaBits: [String] {
        var bits: [String] = []
        if let year = viewModel.metadata.year { bits.append(String(year)) }
        if viewModel.duration > 0 {
            bits.append(PlayerTimeFormatter.formatRuntime(viewModel.duration))
        }
        return bits
    }

    private var streamRows: [(String, String)] {
        // One concise route line (engine · delivery). The decision trace
        // and full route diagnostics stay in the Stats pane / settings —
        // this pane is the casual "what am I watching" surface.
        var rows: [(String, String)] = [("Route", viewModel.playbackRouteDisplay)]
        if let audio = viewModel.audioTracks.first(where: { $0.trackId == viewModel.selectedAudioId }) {
            var bits: [String] = []
            if let codec = audio.codec, !codec.isEmpty { bits.append(codec.uppercased()) }
            if let layout = audio.audioChannelsLayout, !layout.isEmpty { bits.append(layout) }
            if !bits.isEmpty { rows.append(("Audio", bits.joined(separator: " · "))) }
        }
        if let sub = viewModel.subtitleTracks.first(where: { $0.trackId == viewModel.selectedSubtitleId }) {
            let name = sub.title ?? sub.lang ?? "On"
            rows.append(("Subtitles", name))
        } else {
            rows.append(("Subtitles", "Off"))
        }
        return rows
    }

    private var currentChapterTitle: String? {
        guard !viewModel.chapters.isEmpty,
              let current = viewModel.chapters.last(where: { $0.time <= viewModel.currentTime })
        else { return nil }
        return current.title ?? "Chapter \(current.index + 1)"
    }
}

// MARK: - Stats pane

private struct StatsPane: View {
    let viewModel: PlayerViewModel
    let onMoveToTabs: () -> Void

    var body: some View {
        HUDScrollablePane(
            accessibilityLabel: "Playback stats",
            scrollTargetIDs: scrollTargetIDs,
            onMoveToTabs: onMoveToTabs
        ) {
            PlaybackStatsPanel(
                stats: viewModel.playbackStats,
                usesTVTypography: true,
                usesTwoColumnLayout: true
            )
        }
    }

    private var scrollTargetIDs: [String] {
        var ids: [String] = []
        if !viewModel.playbackStats.bufferRows.isEmpty {
            ids.append(PlaybackStatsPanel.bufferSectionID)
        }
        if !viewModel.playbackStats.networkRows.isEmpty {
            ids.append(PlaybackStatsPanel.networkSectionID)
        }
        if !viewModel.playbackStats.deviceRows.isEmpty {
            ids.append(PlaybackStatsPanel.deviceSectionID)
        }
        return ids
    }
}

// MARK: - Video pane

/// Playback / display / sync controls. Multi-option settings open the shared
/// picker dialog; booleans toggle in place. Focus movement between rows and
/// across the two columns is native.
private struct VideoPane: View {
    let viewModel: PlayerViewModel

    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Field?
    @FocusState private var focusedField: Field?

    /// Identity for the picker-backed rows, used only to restore focus after
    /// the dialog closes.
    private enum Field: Hashable {
        case quality
        case speed
        case aspect
        case audioDelay
        case subtitleDelay
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 48) {
                PaneColumn("Playback") {
                    VStack(spacing: 2) {
                        HUDSettingRow(label: "Quality", value: qualityValue) {
                            presentPicker(
                                for: .quality,
                                HUDPickerPresentation(
                                    title: "Quality",
                                    options: qualityOptions,
                                    selection: selectedQuality.id,
                                    onSelect: { viewModel.switchQuality($0) }
                                )
                            )
                        }
                        .focused($focusedField, equals: .quality)

                        HUDSettingRow(label: "Speed", value: speedLabel(viewModel.settings.playbackSpeed)) {
                            presentPicker(
                                for: .speed,
                                HUDPickerPresentation(
                                    title: "Playback Speed",
                                    options: Self.speedOptions,
                                    selection: speedID(viewModel.settings.playbackSpeed),
                                    onSelect: { value in
                                        if let speed = Double(value) {
                                            viewModel.setPlaybackSpeed(speed)
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .speed)

                        if viewModel.backendCapabilities.supportsVideoGravity {
                            HUDSettingRow(label: "Aspect", value: viewModel.settings.videoGravity.label) {
                                presentPicker(
                                    for: .aspect,
                                    HUDPickerPresentation(
                                        title: "Aspect",
                                        options: Self.aspectOptions,
                                        selection: viewModel.settings.videoGravity.rawValue,
                                        onSelect: { value in
                                            if let gravity = VideoGravity(rawValue: value) {
                                                viewModel.setVideoGravity(gravity)
                                            }
                                        }
                                    )
                                )
                            }
                            .focused($focusedField, equals: .aspect)
                        }

                        if viewModel.backendCapabilities.supportsHDRToggle {
                            HUDToggleRow(label: "HDR passthrough", isOn: viewModel.settings.hdrEnabled) {
                                viewModel.setHDREnabled($0)
                            }
                        }
                    }
                }
                .focusSection()

                PaneColumn("Sync") {
                    VStack(spacing: 2) {
                        if viewModel.backendCapabilities.supportsAudioDelay {
                            HUDSettingRow(
                                label: "Audio delay",
                                value: HUDPickerOptions.delayLabel(viewModel.settings.audioSyncMs)
                            ) {
                                presentPicker(
                                    for: .audioDelay,
                                    HUDPickerPresentation(
                                        title: "Audio Delay",
                                        options: HUDPickerOptions.delayOptions(
                                            from: -1_000,
                                            through: 1_000,
                                            by: 50,
                                            including: viewModel.settings.audioSyncMs
                                        ),
                                        selection: String(viewModel.settings.audioSyncMs),
                                        onSelect: { value in
                                            if let ms = Int(value) {
                                                viewModel.setAudioSyncMilliseconds(ms)
                                            }
                                        }
                                    )
                                )
                            }
                            .focused($focusedField, equals: .audioDelay)
                        }

                        if viewModel.backendCapabilities.supportsSubtitleDelay {
                            HUDSettingRow(
                                label: "Subtitle delay",
                                value: HUDPickerOptions.delayLabel(viewModel.settings.subtitleSyncMs)
                            ) {
                                presentPicker(
                                    for: .subtitleDelay,
                                    HUDPickerPresentation(
                                        title: "Subtitle Delay",
                                        options: HUDPickerOptions.delayOptions(
                                            from: -2_000,
                                            through: 2_000,
                                            by: 100,
                                            including: viewModel.settings.subtitleSyncMs
                                        ),
                                        selection: String(viewModel.settings.subtitleSyncMs),
                                        onSelect: { value in
                                            if let ms = Int(value) {
                                                viewModel.setSubtitleSyncMilliseconds(ms)
                                            }
                                        }
                                    )
                                )
                            }
                            .focused($focusedField, equals: .subtitleDelay)
                        }

                        HUDToggleRow(label: "Auto-play next", isOn: viewModel.settings.autoPlayNextEpisode) {
                            viewModel.settings.setAutoPlayNextEpisode($0)
                        }
                    }
                }
                .focusSection()
            }
            .disabled(activePicker != nil)
            .opacity(activePicker != nil ? 0.28 : 1)

            if let activePicker {
                HUDPickerDialog(
                    title: activePicker.title,
                    options: activePicker.options,
                    selection: activePicker.selection,
                    onSelect: activePicker.onSelect,
                    onClose: closePicker
                )
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: activePicker?.id)
    }

    private var selectedQuality: ApplePlaybackQualityOption {
        viewModel.qualityOptions.first(where: { $0.id == viewModel.activeQualityId })
            ?? ApplePlaybackQuality.auto
    }

    private var qualityValue: String {
        if viewModel.isQualitySwitching {
            return "Switching..."
        }
        if let error = viewModel.qualitySwitchError, !error.isEmpty {
            return error
        }
        return selectedQuality.labelWithBitrate
    }

    private var qualityOptions: [HUDDropdownOption] {
        viewModel.qualityOptions.map { .init(id: $0.id, label: $0.labelWithBitrate) }
    }

    private func presentPicker(for field: Field, _ presentation: HUDPickerPresentation) {
        pickerReturnField = field
        activePicker = presentation
    }

    private func closePicker() {
        let field = pickerReturnField
        activePicker = nil
        if let field {
            focusedField = field
        }
    }

    private func speedID(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func speedLabel(_ value: Double) -> String {
        value == 1.0 ? "1.0×" : String(format: "%.2f×", value)
    }

    private static let speedOptions: [HUDDropdownOption] = [0.75, 1.0, 1.25, 1.5, 2.0]
        .map { value in
            HUDDropdownOption(
                id: String(format: "%.2f", value),
                label: value == 1.0 ? "1.0×" : String(format: "%.2f×", value)
            )
        }

    private static let aspectOptions: [HUDDropdownOption] =
        VideoGravity.allCases.map { .init(id: $0.rawValue, label: $0.label) }
}

private struct HUDDropdownOption: Identifiable, Hashable {
    let id: String
    let label: String
    var colorHex: String? = nil
}

private enum HUDPickerOptions {
    static let onOff: [HUDDropdownOption] = [
        .init(id: "on", label: "On"),
        .init(id: "off", label: "Off")
    ]

    static func boolSelection(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    static func boolValue(for id: String) -> Bool {
        id.caseInsensitiveCompare("on") == .orderedSame
    }

    static func boolLabel(_ value: Bool) -> String {
        value ? "On" : "Off"
    }

    static func delayLabel(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "0 ms" }
        return (milliseconds > 0 ? "+" : "") + "\(milliseconds) ms"
    }

    static func delayOptions(
        from lowerBound: Int,
        through upperBound: Int,
        by step: Int,
        including currentValue: Int
    ) -> [HUDDropdownOption] {
        var values = Array(stride(from: lowerBound, through: upperBound, by: step))
        values.append(currentValue)
        return Set(values)
            .sorted()
            .map { .init(id: String($0), label: delayLabel($0)) }
    }
}

private struct HUDPickerPresentation: Identifiable {
    let id = UUID()
    let title: String
    let options: [HUDDropdownOption]
    let selection: String
    let onSelect: (String) -> Void
}

/// Modal option list over a dimmed, `.disabled` pane — disabling the
/// background is what keeps focus contained in here. Movement and
/// keep-visible scrolling are native; focus is seeded onto the current
/// selection when the dialog appears.
private struct HUDPickerDialog: View {
    let title: String
    let options: [HUDDropdownOption]
    let selection: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focusedOptionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: options.count > 7) {
                    VStack(spacing: 4) {
                        ForEach(options) { option in
                            HUDPickerOptionRow(
                                option: option,
                                isSelected: isSelected(option)
                            ) {
                                onSelect(option.id)
                                onClose()
                            }
                            .focused($focusedOptionID, equals: option.id)
                            .id(option.id)
                        }
                    }
                }
                .frame(maxHeight: 520)
                .onAppear {
                    if let initialFocusID {
                        proxy.scrollTo(initialFocusID, anchor: .center)
                        focusedOptionID = initialFocusID
                    }
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .frame(width: 620, alignment: .topLeading)
        .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.62), radius: 26, y: 14)
        .focusSection()
        .defaultFocus($focusedOptionID, initialFocusID)
        .onExitCommand(perform: onClose)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func isSelected(_ option: HUDDropdownOption) -> Bool {
        option.id.caseInsensitiveCompare(selection) == .orderedSame
    }

    private var initialFocusID: String? {
        options.first(where: isSelected)?.id ?? options.first?.id
    }
}

private struct HUDPickerOptionRow: View {
    let option: HUDDropdownOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HUDPickerOptionLabel(option: option, isSelected: isSelected)
        }
        .buttonStyle(HUDRowButtonStyle(isSelected: isSelected))
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct HUDPickerOptionLabel: View {
    let option: HUDDropdownOption
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            if let colorHex = option.colorHex {
                ColorSwatch(hex: colorHex)
            }
            Text(option.label)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

private struct ColorSwatch: View {
    let hex: String

    var body: some View {
        Circle()
            .fill(swiftUIColor(from: hex))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
    }

    private func swiftUIColor(from hex: String) -> Color {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            return .white
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

private struct SubtitleAppearanceDialog: View {
    let viewModel: PlayerViewModel
    let onClose: () -> Void

    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Field?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case close
        case matchSystem
        case style
        case font
        case size
        case textColor
        case outlineColor
        case backgroundColor
        case opacity
        case position
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUBTITLE APPEARANCE")
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.55))
                        Text("Style and colors")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    closeButton
                }

                ScrollView(showsIndicators: true) {
                    VStack(spacing: 2) {
                        HUDToggleRow(
                            label: "Match device style",
                            isOn: viewModel.settings.subtitleMatchesSystemAppearance
                        ) { enabled in
                            viewModel.setSubtitleMatchesSystemAppearance(enabled)
                        }
                        .focused($focusedField, equals: .matchSystem)

                        HUDSettingRow(
                            label: "Style",
                            value: viewModel.settings.subtitleAppearance.backgroundStyle.label
                        ) {
                            presentPicker(
                                for: .style,
                                HUDPickerPresentation(
                                    title: "Subtitle Style",
                                    options: Self.backgroundStyleOptions,
                                    selection: viewModel.settings.subtitleAppearance.backgroundStyle.rawValue,
                                    onSelect: { value in
                                        if let style = SubtitleBackgroundStylePreset(rawValue: value) {
                                            updateAppearance {
                                                $0.backgroundStyle = style
                                                if style == .box && $0.backgroundOpacity == 0 {
                                                    $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                                                }
                                            }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .style)

                        HUDSettingRow(
                            label: "Font",
                            value: viewModel.settings.subtitleAppearance.fontFamily.label
                        ) {
                            presentPicker(
                                for: .font,
                                HUDPickerPresentation(
                                    title: "Subtitle Font",
                                    options: Self.fontFamilyOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontFamily.rawValue,
                                    onSelect: { value in
                                        if let font = SubtitleFontFamilyPreset(rawValue: value) {
                                            updateAppearance { $0.fontFamily = font }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .font)

                        HUDSettingRow(
                            label: "Size",
                            value: viewModel.settings.subtitleAppearance.fontSize.label
                        ) {
                            presentPicker(
                                for: .size,
                                HUDPickerPresentation(
                                    title: "Subtitle Size",
                                    options: Self.sizeOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontSize.rawValue,
                                    onSelect: { value in
                                        if let size = SubtitleFontSizePreset(rawValue: value) {
                                            updateAppearance { $0.fontSize = size }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .size)

                        HUDSettingRow(
                            label: "Text",
                            value: label(for: viewModel.settings.subtitleAppearance.fontColor, in: Self.fontColorOptions),
                            colorHex: viewModel.settings.subtitleAppearance.fontColor
                        ) {
                            presentPicker(
                                for: .textColor,
                                HUDPickerPresentation(
                                    title: "Text Color",
                                    options: Self.fontColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontColor,
                                    onSelect: { value in
                                        updateAppearance { $0.fontColor = value }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .textColor)

                        HUDToggleRow(
                            label: "Text outline",
                            isOn: viewModel.settings.subtitleAppearance.textOutline
                        ) { enabled in
                            updateAppearance { $0.textOutline = enabled }
                        }

                        HUDSettingRow(
                            label: "Outline",
                            value: viewModel.settings.subtitleAppearance.textOutline
                                ? label(for: viewModel.settings.subtitleAppearance.textOutlineColor, in: Self.outlineColorOptions)
                                : "—",
                            colorHex: viewModel.settings.subtitleAppearance.textOutline
                                ? viewModel.settings.subtitleAppearance.textOutlineColor
                                : nil
                        ) {
                            presentPicker(
                                for: .outlineColor,
                                HUDPickerPresentation(
                                    title: "Outline Color",
                                    options: Self.outlineColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.textOutlineColor,
                                    onSelect: { value in
                                        // Picking a color turns the outline on.
                                        updateAppearance {
                                            $0.textOutlineColor = value
                                            $0.textOutline = true
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .outlineColor)

                        HUDSettingRow(
                            label: "Background",
                            value: viewModel.settings.subtitleAppearance.backgroundStyle == .box
                                ? label(for: viewModel.settings.subtitleAppearance.backgroundColor, in: Self.backgroundColorOptions)
                                : "—",
                            colorHex: viewModel.settings.subtitleAppearance.backgroundStyle == .box
                                ? viewModel.settings.subtitleAppearance.backgroundColor
                                : nil
                        ) {
                            presentPicker(
                                for: .backgroundColor,
                                HUDPickerPresentation(
                                    title: "Background Color",
                                    options: Self.backgroundColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.backgroundColor,
                                    onSelect: { value in
                                        // Picking a color switches the style to Box.
                                        updateAppearance {
                                            $0.backgroundColor = value
                                            $0.backgroundStyle = .box
                                            if $0.backgroundOpacity == 0 {
                                                $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                                            }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .backgroundColor)

                        HUDSettingRow(label: "Opacity", value: opacityLabel) {
                            presentPicker(
                                for: .opacity,
                                HUDPickerPresentation(
                                    title: "Background Opacity",
                                    options: Self.opacityOptions,
                                    selection: String(viewModel.settings.subtitleAppearance.backgroundOpacity),
                                    onSelect: { value in
                                        if let opacity = Int(value) {
                                            updateAppearance {
                                                $0.backgroundOpacity = opacity
                                                if opacity > 0 {
                                                    $0.backgroundStyle = .box
                                                }
                                            }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .opacity)

                        HUDSettingRow(
                            label: "Position",
                            value: viewModel.settings.subtitleAppearance.position.label
                        ) {
                            presentPicker(
                                for: .position,
                                HUDPickerPresentation(
                                    title: "Subtitle Position",
                                    options: Self.positionOptions,
                                    selection: viewModel.settings.subtitleAppearance.position.rawValue,
                                    onSelect: { value in
                                        if let position = SubtitlePositionPreset(rawValue: value) {
                                            updateAppearance { $0.position = position }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .position)
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: 560)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(width: 720, alignment: .topLeading)
            .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 26, y: 14)
            .focusSection()
            .defaultFocus($focusedField, .style)
            .disabled(activePicker != nil)
            .opacity(activePicker != nil ? 0.28 : 1)

            if let activePicker {
                HUDPickerDialog(
                    title: activePicker.title,
                    options: activePicker.options,
                    selection: activePicker.selection,
                    onSelect: activePicker.onSelect,
                    onClose: closePicker
                )
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: activePicker?.id)
        // Defensive: the picker's own exit handler consumes Menu while it has
        // focus, but if focus ever escapes it we still want Menu to close the
        // picker, not tear down the whole dialog.
        .onExitCommand(perform: activePicker == nil ? onClose : closePicker)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            HUDCloseButtonLabel()
        }
        .buttonStyle(HUDCircleButtonStyle())
        .focused($focusedField, equals: .close)
        .accessibilityLabel("Close subtitle appearance")
    }

    private func presentPicker(for field: Field, _ presentation: HUDPickerPresentation) {
        pickerReturnField = field
        activePicker = presentation
    }

    private func closePicker() {
        let field = pickerReturnField
        activePicker = nil
        if let field {
            focusedField = field
        }
    }

    private func updateAppearance(_ mutate: @escaping (inout SubtitleAppearance) -> Void) {
        var next = viewModel.settings.subtitleAppearance
        mutate(&next)
        Task { await viewModel.setSubtitleAppearance(next) }
    }

    private var opacityLabel: String {
        guard viewModel.settings.subtitleAppearance.backgroundStyle == .box,
              viewModel.settings.subtitleAppearance.backgroundOpacity > 0 else {
            return "Off"
        }
        return "\(viewModel.settings.subtitleAppearance.backgroundOpacity)%"
    }

    private func label(for id: String, in options: [HUDDropdownOption]) -> String {
        options.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.label ?? id
    }

    private static let backgroundStyleOptions: [HUDDropdownOption] =
        SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let fontFamilyOptions: [HUDDropdownOption] =
        SubtitleFontFamilyPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let sizeOptions: [HUDDropdownOption] =
        SubtitleFontSizePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let positionOptions: [HUDDropdownOption] =
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let opacityOptions: [HUDDropdownOption] =
        stride(from: 0, through: 100, by: 25).map { .init(id: String($0), label: $0 == 0 ? "Off" : "\($0)%") }

    private static let fontColorOptions: [HUDDropdownOption] =
        SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }

    private static let outlineColorOptions: [HUDDropdownOption] =
        SubtitleAppearance.outlineColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }

    private static let backgroundColorOptions: [HUDDropdownOption] =
        SubtitleAppearance.backgroundColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }
}

private struct HUDCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HUDCircleButtonBody(configuration: configuration)
    }
}

private struct HUDCircleButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .frame(width: 46, height: 46)
            .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }
}

private struct HUDCloseButtonLabel: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

// MARK: - Audio pane

private struct AudioPane: View {
    let viewModel: PlayerViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            PaneColumn("Tracks") {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.audioTracks) { track in
                            HUDTrackRow(
                                name: track.primaryLabel,
                                attributes: track.attributesLabel,
                                isSelected: viewModel.selectedAudioId == track.trackId
                            ) {
                                viewModel.selectAudio(track)
                            }
                        }
                    }
                }
            }
            .focusSection()

            PaneColumn("Options") {
                LabelValueRow(label: "Layout", value: selectedLayout ?? "—")
                LabelValueRow(label: "Codec",  value: selectedCodec ?? "—")
                if viewModel.backendCapabilities.supportsAudioDelay {
                    LabelValueRow(label: "Delay",  value: delayText)
                }
            }
        }
    }

    private var selectedTrack: PlayerTrack? {
        viewModel.audioTracks.first(where: { $0.trackId == viewModel.selectedAudioId })
    }

    private var selectedLayout: String? {
        selectedTrack?.audioChannelsLayout
    }

    private var selectedCodec: String? {
        selectedTrack?.codec?.uppercased()
    }

    private var delayText: String {
        HUDPickerOptions.delayLabel(viewModel.settings.audioSyncMs)
    }
}

// MARK: - Subtitles pane

private struct SubtitlesPane: View {
    let viewModel: PlayerViewModel
    /// Dismiss the whole HUD (back to the player). Used when an AI subtitle job
    /// is accepted so the live "Preparing subtitles" overlay is visible.
    let onCloseHUD: () -> Void

    @State private var showAppearanceDialog = false
    @State private var showAITranslateMenu = false
    @State private var showSubtitleSearchMenu = false
    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Option?
    @FocusState private var focusedOption: Option?

    /// Identity for the options-column rows, used only to restore focus when
    /// a picker dialog, the appearance dialog, or the AI/search menu closes.
    private enum Option: Hashable {
        case translate
        case search
        case delay
        case size
        case position
        case appearance
    }

    private var overlayActive: Bool {
        showAppearanceDialog || activePicker != nil || showAITranslateMenu
            || showSubtitleSearchMenu
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 58) {
                PaneColumn("Tracks") { trackRows }
                    .frame(width: 470, alignment: .topLeading)
                    .focusSection()
                PaneColumn("Options") { optionRows }
                    .frame(width: 440, alignment: .topLeading)
                    .focusSection()
            }
            .disabled(overlayActive)
            .opacity(overlayActive ? 0.28 : 1)

            if showAppearanceDialog {
                SubtitleAppearanceDialog(
                    viewModel: viewModel,
                    onClose: closeAppearanceDialog
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }

            if let activePicker {
                HUDPickerDialog(
                    title: activePicker.title,
                    options: activePicker.options,
                    selection: activePicker.selection,
                    onSelect: activePicker.onSelect,
                    onClose: closePicker
                )
            }

            // The AI translate/transcribe flow reuses the shared
            // `SubtitleTranslateMenu` as a modal overlay — same presentation
            // idiom as the appearance dialog above (columns dimmed + disabled).
            if showAITranslateMenu {
                SubtitleTranslateMenu(
                    viewModel: viewModel,
                    onDismiss: closeAITranslateMenu,
                    // Job accepted: close the menu AND the HUD so the live
                    // "Preparing subtitles" overlay is visible on the player.
                    onJobStarted: {
                        closeAITranslateMenu()
                        onCloseHUD()
                    }
                )
                .transition(.opacity)
            }

            // Provider subtitle search — same modal-overlay idiom as the AI
            // menu above.
            if showSubtitleSearchMenu {
                SubtitleSearchMenu(
                    viewModel: viewModel,
                    onDismiss: closeSubtitleSearchMenu,
                    // Download succeeded (track registered + selected): close
                    // the menu AND the HUD so the player is visible.
                    onDownloaded: {
                        closeSubtitleSearchMenu()
                        onCloseHUD()
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showAppearanceDialog)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: activePicker?.id)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showAITranslateMenu)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showSubtitleSearchMenu)
    }

    private func closeAITranslateMenu() {
        showAITranslateMenu = false
        focusedOption = .translate
    }

    private func closeSubtitleSearchMenu() {
        showSubtitleSearchMenu = false
        focusedOption = .search
    }

    /// Whether the server's AI capabilities + the current track list offer any
    /// AI subtitle action (translate an existing text track, or transcribe
    /// audio). Gates the "Translate with AI…" row so it never opens an empty
    /// menu. Shared with the iOS `TrackSelectionSheet` via the same helper.
    private var aiSubtitlesAvailable: Bool {
        SubtitleTranslateMenu.hasActionableSource(viewModel)
    }

    private var appearanceSummary: String {
        let appearance = viewModel.settings.subtitleAppearance
        return "\(appearance.backgroundStyle.label), \(appearance.fontSize.label), \(appearance.position.label)"
    }

    private func setAppearance(_ mutate: @escaping (inout SubtitleAppearance) -> Void) {
        var next = viewModel.settings.subtitleAppearance
        mutate(&next)
        Task { await viewModel.setSubtitleAppearance(next) }
    }

    private func presentPicker(for option: Option, _ presentation: HUDPickerPresentation) {
        pickerReturnField = option
        activePicker = presentation
    }

    private func closePicker() {
        let option = pickerReturnField
        activePicker = nil
        if let option {
            focusedOption = option
        }
    }

    private func closeAppearanceDialog() {
        showAppearanceDialog = false
        focusedOption = .appearance
    }

    private static let sizeOptions: [HUDDropdownOption] =
        SubtitleFontSizePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let positionOptions: [HUDDropdownOption] =
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    @ViewBuilder
    private var trackRows: some View {
        ScrollView(showsIndicators: false) {
            // LazyVStack defers off-screen `HUDTrackRow` construction. Each
            // row carries a focusable button and a Locale lookup; for files
            // with 15+ subtitle tracks the eager VStack built (and re-built
            // on every tab swap) the entire focus subtree, which is the
            // dominant cost stalling main when the Subtitles pane appears.
            LazyVStack(alignment: .leading, spacing: 2) {
                HUDTrackRow(
                    name: "Off",
                    attributes: nil,
                    isSelected: viewModel.selectedSubtitleId == nil
                ) {
                    viewModel.disableSubtitles()
                }
                ForEach(viewModel.orderedSubtitleTracks) { track in
                    HUDTrackRow(
                        name: track.primaryLabel,
                        attributes: track.attributesLabel,
                        isSelected: viewModel.selectedSubtitleId == track.trackId
                    ) {
                        viewModel.selectSubtitle(track)
                    }
                }

                if viewModel.supportsSecondarySubtitles,
                   viewModel.selectedSubtitleId != nil,
                   !viewModel.availableSecondarySubtitleTracks.isEmpty {
                    Text("SECONDARY")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 20)
                        .padding(.bottom, 4)
                        .padding(.leading, 14)
                    HUDTrackRow(
                        name: "Off",
                        attributes: nil,
                        isSelected: viewModel.selectedSecondarySubtitleId == nil
                    ) {
                        viewModel.disableSecondarySubtitles()
                    }
                    ForEach(viewModel.availableSecondarySubtitleTracks) { track in
                        HUDTrackRow(
                            name: track.primaryLabel,
                            attributes: track.attributesLabel,
                            isSelected: viewModel.selectedSecondarySubtitleId == track.trackId,
                            isDisabled: track.trackId == viewModel.selectedSubtitleId
                        ) {
                            viewModel.selectSecondarySubtitle(track)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var optionRows: some View {
        VStack(spacing: 2) {
            if aiSubtitlesAvailable {
                HUDSettingRow(
                    label: "AI Subtitles…",
                    value: "",
                    systemImage: "sparkles"
                ) {
                    showAITranslateMenu = true
                }
                .focused($focusedOption, equals: .translate)
            }
            if viewModel.subtitleSearchAvailable {
                HUDSettingRow(
                    label: "Search Subtitles…",
                    value: "",
                    systemImage: "magnifyingglass"
                ) {
                    showSubtitleSearchMenu = true
                }
                .focused($focusedOption, equals: .search)
            }
            if viewModel.backendCapabilities.supportsSubtitleDelay {
                HUDSettingRow(label: "Delay", value: delayText) {
                    presentPicker(
                        for: .delay,
                        HUDPickerPresentation(
                            title: "Subtitle Delay",
                            options: HUDPickerOptions.delayOptions(
                                from: -2_000,
                                through: 2_000,
                                by: 100,
                                including: viewModel.settings.subtitleSyncMs
                            ),
                            selection: String(viewModel.settings.subtitleSyncMs),
                            onSelect: { value in
                                if let ms = Int(value) {
                                    viewModel.setSubtitleSyncMilliseconds(ms)
                                }
                            }
                        )
                    )
                }
                .focused($focusedOption, equals: .delay)
            }
            if viewModel.backendCapabilities.supportsSubtitleStyling {
                HUDToggleRow(
                    label: "Save for this Apple TV",
                    isOn: viewModel.settings.subtitleUsesDeviceAppearanceOverride
                ) { enabled in
                    Task {
                        await viewModel.setSubtitleDeviceOverrideEnabled(enabled)
                    }
                }
                HUDSettingRow(
                    label: "Size",
                    value: viewModel.settings.subtitleAppearance.fontSize.label
                ) {
                    presentPicker(
                        for: .size,
                        HUDPickerPresentation(
                            title: "Subtitle Size",
                            options: Self.sizeOptions,
                            selection: viewModel.settings.subtitleAppearance.fontSize.rawValue,
                            onSelect: { value in
                                if let size = SubtitleFontSizePreset(rawValue: value) {
                                    setAppearance { $0.fontSize = size }
                                }
                            }
                        )
                    )
                }
                .focused($focusedOption, equals: .size)
                HUDSettingRow(
                    label: "Position",
                    value: viewModel.settings.subtitleAppearance.position.label
                ) {
                    presentPicker(
                        for: .position,
                        HUDPickerPresentation(
                            title: "Subtitle Position",
                            options: Self.positionOptions,
                            selection: viewModel.settings.subtitleAppearance.position.rawValue,
                            onSelect: { value in
                                if let position = SubtitlePositionPreset(rawValue: value) {
                                    setAppearance { $0.position = position }
                                }
                            }
                        )
                    )
                }
                .focused($focusedOption, equals: .position)
                HUDSettingRow(
                    label: "Appearance",
                    value: appearanceSummary,
                    systemImage: "textformat"
                ) {
                    showAppearanceDialog = true
                }
                .focused($focusedOption, equals: .appearance)
            }
        }
    }

    private var delayText: String {
        HUDPickerOptions.delayLabel(viewModel.settings.subtitleSyncMs)
    }
}

// MARK: - Chapters pane

private struct ChaptersPane: View {
    let viewModel: PlayerViewModel
    let onSelect: () -> Void

    private var currentIndex: Int? {
        viewModel.chapters.lastIndex(where: { $0.time <= viewModel.currentTime })
    }

    var body: some View {
        PaneColumn("Chapters") {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { index, chapter in
                        HUDChapterRow(
                            number: index + 1,
                            title: chapter.title ?? "Chapter \(index + 1)",
                            time: PlayerTimeFormatter.formatHMS(chapter.time),
                            isCurrent: currentIndex == index
                        ) {
                            viewModel.seekTo(seconds: chapter.time)
                            onSelect()
                        }
                    }
                }
            }
        }
        .focusSection()
    }
}

private struct HUDChapterRow: View {
    let number: Int
    let title: String
    let time: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDChapterRowLabel(number: number, title: title, time: time, isCurrent: isCurrent)
        }
        .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
        .accessibilityLabel(title)
        .accessibilityValue(isCurrent ? "Currently playing" : "")
    }
}

private struct HUDChapterRowLabel: View {
    let number: Int
    let title: String
    let time: String
    let isCurrent: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", number))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Text(title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? .black : .white)
                .lineLimit(1)

            Spacer(minLength: 12)

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFocused ? .black.opacity(0.8) : .white.opacity(0.8))
            }

            Text(time)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isFocused ? .black.opacity(0.65) : .white.opacity(0.65))
                .monospacedDigit()
        }
    }
}

// MARK: - Track row (shared by Audio + Subtitle panes)

private struct HUDTrackRow: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDTrackRowLabel(name: name, attributes: attributes, isSelected: isSelected)
        }
        .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct HUDTrackRowLabel: View {
    let name: String
    let attributes: String?
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(1)
                if let attributes {
                    Text(attributes)
                        .font(.system(size: 17))
                        .foregroundStyle(isFocused ? .black.opacity(0.62) : .white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
    }
}
#endif
