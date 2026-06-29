#if os(tvOS)
import SwiftUI

/// Infuse-style floating top-center HUD. A pill-tab header (Info / Video /
/// Audio / Subtitles / Chapters) selects which content pane renders below.
/// Drops on top of the video with no dimming backdrop so playback stays
/// visible, matching the "HUD over media" idiom rather than a modal sheet.
/// Menu dismisses via `onExitCommand` on the host view.
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
    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.info, .stats, .video]
        if !viewModel.audioTracks.isEmpty { tabs.append(.audio) }
        if !viewModel.subtitleTracks.isEmpty { tabs.append(.subtitles) }
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
    }

    // MARK: - Panel

    private var panel: some View {
        Group {
            switch activeTab {
            case .info:      InfoPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .stats:     StatsPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .video:     VideoPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .audio:     AudioPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .subtitles: SubtitlesPane(viewModel: viewModel, onMoveToTabs: focusActiveTab)
            case .chapters:  ChaptersPane(viewModel: viewModel, onSelect: onDismiss, onMoveToTabs: focusActiveTab)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // Width sits at ~60% of a 1920pt tvOS frame. Height is fixed at the
        // tallest pane's needs — content-hugging here would resize the panel
        // on every tab swap, which cascades into a SwiftUI relayout pass.
        .frame(maxWidth: 1100, minHeight: 380, maxHeight: 380)
        .background(
            // `.regularMaterial` carries enough light that the panel lifts
            // off the video without any extra dark tint. Over a fully-black
            // frame it renders near-clear — acceptable because the stroke
            // + shadow still define the edge.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .focusSection()
        .onMoveCommand { direction in
            if direction == .up {
                focusActiveTab()
            }
        }
    }

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
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).stroke(strokeColor, lineWidth: 1))
            .contentShape(Capsule())
            .focusable(true)
            .focused($focusedTab, equals: tab)
            // Focus-driven selection: moving the remote across tabs swaps
            // the pane below without requiring a Select press. Matches the
            // native Apple TV segmented-control idiom.
            .onChange(of: isFocused) { _, focused in
                if focused { onSelect() }
            }
            // Select on an already-focused pill is a no-op under
            // focus-driven selection but stays wired for keyboard
            // accessibility + an explicit "re-pick" interaction.
            .onTapGesture(perform: onSelect)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isSelected)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        var rows: [(String, String)] = [("Route", viewModel.activeRouteLabel)]
        if let decision = viewModel.routeDecisionSummary {
            rows.append(("Decision", decision))
        }
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

/// Playback / display / sync controls use row-triggered picker dialogs so
/// every editable HUD option shares the same tvOS focus behavior.
private struct VideoPane: View {
    let viewModel: PlayerViewModel
    let onMoveToTabs: () -> Void

    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Field?
    @FocusState private var focusedVideoField: Field?

    private enum Field: Hashable {
        case quality
        case speed
        case aspect
        case hdr
        case audioDelay
        case subtitleDelay
        case autoPlay
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 48) {
                PaneColumn("Playback") {
                    VStack(spacing: 2) {
                        HUDFocusedSettingRow(
                            label: "Quality",
                            value: qualityValue,
                            focused: $focusedVideoField,
                            focusID: .quality,
                            onMoveUp: moveUp(from: .quality),
                            onMoveDown: moveDown(from: .quality),
                            onMoveLeft: hold(.quality),
                            onMoveRight: moveRight(from: .quality)
                        ) {
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

                        HUDFocusedSettingRow(
                            label: "Speed",
                            value: speedLabel(viewModel.settings.playbackSpeed),
                            focused: $focusedVideoField,
                            focusID: .speed,
                            onMoveUp: moveUp(from: .speed),
                            onMoveDown: moveDown(from: .speed),
                            onMoveLeft: hold(.speed),
                            onMoveRight: moveRight(from: .speed)
                        ) {
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

                        if viewModel.backendCapabilities.supportsVideoGravity {
                            HUDFocusedSettingRow(
                                label: "Aspect",
                                value: viewModel.settings.videoGravity.label,
                                focused: $focusedVideoField,
                                focusID: .aspect,
                                onMoveUp: moveUp(from: .aspect),
                                onMoveDown: moveDown(from: .aspect),
                                onMoveLeft: hold(.aspect),
                                onMoveRight: moveRight(from: .aspect)
                            ) {
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
                        }

                        if viewModel.backendCapabilities.supportsHDRToggle {
                            HUDFocusedSettingRow(
                                label: "HDR passthrough",
                                value: HUDPickerOptions.boolLabel(viewModel.settings.hdrEnabled),
                                focused: $focusedVideoField,
                                focusID: .hdr,
                                onMoveUp: moveUp(from: .hdr),
                                onMoveDown: moveDown(from: .hdr),
                                onMoveLeft: hold(.hdr),
                                onMoveRight: moveRight(from: .hdr)
                            ) {
                                presentPicker(
                                    for: .hdr,
                                    HUDPickerPresentation(
                                        title: "HDR Passthrough",
                                        options: HUDPickerOptions.onOff,
                                        selection: HUDPickerOptions.boolSelection(viewModel.settings.hdrEnabled),
                                        onSelect: { value in
                                            viewModel.setHDREnabled(HUDPickerOptions.boolValue(for: value))
                                        }
                                    )
                                )
                            }
                        }
                    }
                }

                PaneColumn("Sync") {
                    VStack(spacing: 2) {
                        if viewModel.backendCapabilities.supportsAudioDelay {
                            HUDFocusedSettingRow(
                                label: "Audio delay",
                                value: HUDPickerOptions.delayLabel(viewModel.settings.audioSyncMs),
                                focused: $focusedVideoField,
                                focusID: .audioDelay,
                                onMoveUp: moveUp(from: .audioDelay),
                                onMoveDown: moveDown(from: .audioDelay),
                                onMoveLeft: moveLeft(from: .audioDelay),
                                onMoveRight: hold(.audioDelay)
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
                        }

                        if viewModel.backendCapabilities.supportsSubtitleDelay {
                            HUDFocusedSettingRow(
                                label: "Subtitle delay",
                                value: HUDPickerOptions.delayLabel(viewModel.settings.subtitleSyncMs),
                                focused: $focusedVideoField,
                                focusID: .subtitleDelay,
                                onMoveUp: moveUp(from: .subtitleDelay),
                                onMoveDown: moveDown(from: .subtitleDelay),
                                onMoveLeft: moveLeft(from: .subtitleDelay),
                                onMoveRight: hold(.subtitleDelay)
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
                        }

                        HUDFocusedSettingRow(
                            label: "Auto-play next",
                            value: HUDPickerOptions.boolLabel(viewModel.settings.autoPlayNextEpisode),
                            focused: $focusedVideoField,
                            focusID: .autoPlay,
                            onMoveUp: moveUp(from: .autoPlay),
                            onMoveDown: moveDown(from: .autoPlay),
                            onMoveLeft: moveLeft(from: .autoPlay),
                            onMoveRight: hold(.autoPlay)
                        ) {
                            presentPicker(
                                for: .autoPlay,
                                HUDPickerPresentation(
                                    title: "Auto-play Next",
                                    options: HUDPickerOptions.onOff,
                                    selection: HUDPickerOptions.boolSelection(viewModel.settings.autoPlayNextEpisode),
                                    onSelect: { value in
                                        viewModel.settings.setAutoPlayNextEpisode(HUDPickerOptions.boolValue(for: value))
                                    }
                                )
                            )
                        }
                    }
                }
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

    private var playbackFields: [Field] {
        var fields: [Field] = [.quality, .speed]
        if viewModel.backendCapabilities.supportsVideoGravity {
            fields.append(.aspect)
        }
        if viewModel.backendCapabilities.supportsHDRToggle {
            fields.append(.hdr)
        }
        return fields
    }

    private var syncFields: [Field] {
        var fields: [Field] = []
        if viewModel.backendCapabilities.supportsAudioDelay {
            fields.append(.audioDelay)
        }
        if viewModel.backendCapabilities.supportsSubtitleDelay {
            fields.append(.subtitleDelay)
        }
        fields.append(.autoPlay)
        return fields
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

    private func hold(_ field: Field) -> () -> Void {
        { focusedVideoField = field }
    }

    private func moveUp(from field: Field) -> () -> Void {
        {
            guard let previous = neighbor(of: field, offset: -1) else {
                onMoveToTabs()
                return
            }
            focusedVideoField = previous
        }
    }

    private func moveDown(from field: Field) -> () -> Void {
        { focusedVideoField = neighbor(of: field, offset: 1) ?? field }
    }

    private func moveLeft(from field: Field) -> () -> Void {
        { focusedVideoField = matchingField(from: field, to: playbackFields) ?? field }
    }

    private func moveRight(from field: Field) -> () -> Void {
        { focusedVideoField = matchingField(from: field, to: syncFields) ?? field }
    }

    private func column(containing field: Field) -> [Field] {
        playbackFields.contains(field) ? playbackFields : syncFields
    }

    private func neighbor(of field: Field, offset: Int) -> Field? {
        let fields = column(containing: field)
        guard let index = fields.firstIndex(of: field) else { return nil }
        let nextIndex = index + offset
        guard fields.indices.contains(nextIndex) else { return nil }
        return fields[nextIndex]
    }

    private func matchingField(from field: Field, to targetFields: [Field]) -> Field? {
        guard !targetFields.isEmpty else { return nil }
        let sourceFields = column(containing: field)
        guard let sourceIndex = sourceFields.firstIndex(of: field) else {
            return targetFields.first
        }
        return targetFields[min(sourceIndex, targetFields.count - 1)]
    }

    private func presentPicker(for field: Field, _ presentation: HUDPickerPresentation) {
        pickerReturnField = field
        focusedVideoField = field
        activePicker = presentation
    }

    private func closePicker() {
        let field = pickerReturnField
        activePicker = nil
        if let field {
            focusedVideoField = field
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
                    LazyVStack(spacing: 4) {
                        ForEach(options) { option in
                            HUDPickerOptionRow(
                                option: option,
                                isSelected: option.id.caseInsensitiveCompare(selection) == .orderedSame,
                                focusedOptionID: $focusedOptionID,
                                onMove: moveFocus
                            ) {
                                onSelect(option.id)
                                onClose()
                            }
                            .id(option.id)
                        }
                    }
                }
                .frame(maxHeight: 520)
                .onAppear {
                    scrollToFocusedOption(with: proxy, animated: false)
                }
                .onChange(of: focusedOptionID) { _, _ in
                    scrollToFocusedOption(with: proxy)
                }
                .onChange(of: selection) { _, _ in
                    scrollToFocusedOption(with: proxy)
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .frame(width: 620, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.62), radius: 26, y: 14)
        .focusSection()
        .onExitCommand(perform: onClose)
        .onAppear(perform: focusSelection)
        .onChange(of: focusedOptionID) { _, value in
            if value == nil {
                focusSelection()
            }
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func focusSelection() {
        focusedOptionID = options.first { $0.id.caseInsensitiveCompare(selection) == .orderedSame }?.id
            ?? options.first?.id
    }

    private func moveFocus(from option: HUDDropdownOption, offset: Int) {
        guard let index = options.firstIndex(of: option) else {
            focusSelection()
            return
        }
        let nextIndex = max(0, min(options.count - 1, index + offset))
        focusedOptionID = options[nextIndex].id
    }

    private func scrollToFocusedOption(with proxy: ScrollViewProxy, animated: Bool = true) {
        let targetID = focusedOptionID
            ?? options.first { $0.id.caseInsensitiveCompare(selection) == .orderedSame }?.id
            ?? options.first?.id
        guard let targetID else { return }
        if animated {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        } else {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }
}

private struct HUDPickerOptionRow: View {
    let option: HUDDropdownOption
    let isSelected: Bool
    @FocusState.Binding var focusedOptionID: String?
    let onMove: (HUDDropdownOption, Int) -> Void
    let onSelect: () -> Void

    private var isFocused: Bool { focusedOptionID == option.id }

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
        .foregroundStyle((isFocused || isSelected) ? .black : .white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused || isSelected ? Color.white : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable(true)
        .focused($focusedOptionID, equals: option.id)
        .onTapGesture(perform: onSelect)
        .onMoveCommand { direction in
            switch direction {
            case .up:
                move(-1)
            case .down:
                move(1)
            default:
                focusedOptionID = option.id
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private func move(_ offset: Int) {
        onMove(option, offset)
    }
}

private struct HUDFocusedTrackRow<FocusID: Hashable>: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    @FocusState.Binding var focused: FocusID?
    let focusID: FocusID
    var onMoveUp: (() -> Void)? = nil
    var onMoveRight: (() -> Void)? = nil
    let action: () -> Void

    private var isFocused: Bool { focused == focusID }

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.white : Color.clear)
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($focused, equals: focusID)
        .onTapGesture(perform: action)
        .onMoveCommand { direction in
            switch direction {
            case .up: onMoveUp?()
            case .right: onMoveRight?()
            default: break
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct HUDFocusedSettingRow<FocusID: Hashable>: View {
    let label: String
    let value: String
    var colorHex: String? = nil
    var systemImage: String? = nil
    @FocusState.Binding var focused: FocusID?
    let focusID: FocusID
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onMoveLeft: (() -> Void)? = nil
    var onMoveRight: (() -> Void)? = nil
    let action: () -> Void

    private var isFocused: Bool { focused == focusID }

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
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.45))
            }
        }
        .foregroundStyle(isFocused ? .black : .white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? Color.white : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable(true)
        .focused($focused, equals: focusID)
        .onTapGesture(perform: action)
        .onMoveCommand { direction in
            switch direction {
            case .up: onMoveUp?()
            case .down: onMoveDown?()
            case .left: onMoveLeft?()
            case .right: onMoveRight?()
            default: break
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(value)
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
        case style
        case font
        case size
        case textColor
        case textOutline
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

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 2) {
                            HUDFocusedSettingRow(
                                label: "Style",
                                value: viewModel.settings.subtitleAppearance.backgroundStyle.label,
                                focused: $focusedField,
                                focusID: .style,
                                onMoveUp: moveUp(from: .style),
                                onMoveDown: moveDown(from: .style),
                                onMoveLeft: hold(.style),
                                onMoveRight: hold(.style)
                            ) {
                                presentPicker(
                                    for: .style,
                                    HUDPickerPresentation(
                                        title: "Subtitle Style",
                                        options: Self.backgroundStyleOptions,
                                        selection: viewModel.settings.subtitleAppearance.backgroundStyle.rawValue,
                                        onSelect: { value in
                                            if let style = SubtitleBackgroundStylePreset(rawValue: value) {
                                                updateAppearance { $0.backgroundStyle = style }
                                            }
                                        }
                                    )
                                )
                            }
                            .id(Field.style)
                            HUDFocusedSettingRow(
                                label: "Font",
                                value: viewModel.settings.subtitleAppearance.fontFamily.label,
                                focused: $focusedField,
                                focusID: .font,
                                onMoveUp: moveUp(from: .font),
                                onMoveDown: moveDown(from: .font),
                                onMoveLeft: hold(.font),
                                onMoveRight: hold(.font)
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
                            .id(Field.font)
                            HUDFocusedSettingRow(
                                label: "Size",
                                value: viewModel.settings.subtitleAppearance.fontSize.label,
                                focused: $focusedField,
                                focusID: .size,
                                onMoveUp: moveUp(from: .size),
                                onMoveDown: moveDown(from: .size),
                                onMoveLeft: hold(.size),
                                onMoveRight: hold(.size)
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
                            .id(Field.size)
                            HUDFocusedSettingRow(
                                label: "Text",
                                value: label(for: viewModel.settings.subtitleAppearance.fontColor, in: Self.fontColorOptions),
                                colorHex: viewModel.settings.subtitleAppearance.fontColor,
                                focused: $focusedField,
                                focusID: .textColor,
                                onMoveUp: moveUp(from: .textColor),
                                onMoveDown: moveDown(from: .textColor),
                                onMoveLeft: hold(.textColor),
                                onMoveRight: hold(.textColor)
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
                            .id(Field.textColor)
                            HUDFocusedSettingRow(
                                label: "Text outline",
                                value: HUDPickerOptions.boolLabel(viewModel.settings.subtitleAppearance.textOutline),
                                focused: $focusedField,
                                focusID: .textOutline,
                                onMoveUp: moveUp(from: .textOutline),
                                onMoveDown: moveDown(from: .textOutline),
                                onMoveLeft: hold(.textOutline),
                                onMoveRight: hold(.textOutline)
                            ) {
                                presentPicker(
                                    for: .textOutline,
                                    HUDPickerPresentation(
                                        title: "Text Outline",
                                        options: HUDPickerOptions.onOff,
                                        selection: HUDPickerOptions.boolSelection(viewModel.settings.subtitleAppearance.textOutline),
                                        onSelect: { value in
                                            updateAppearance { $0.textOutline = HUDPickerOptions.boolValue(for: value) }
                                        }
                                    )
                                )
                            }
                            .id(Field.textOutline)
                            HUDFocusedSettingRow(
                                label: "Outline",
                                value: label(for: viewModel.settings.subtitleAppearance.textOutlineColor, in: Self.outlineColorOptions),
                                colorHex: viewModel.settings.subtitleAppearance.textOutlineColor,
                                focused: $focusedField,
                                focusID: .outlineColor,
                                onMoveUp: moveUp(from: .outlineColor),
                                onMoveDown: moveDown(from: .outlineColor),
                                onMoveLeft: hold(.outlineColor),
                                onMoveRight: hold(.outlineColor)
                            ) {
                                presentPicker(
                                    for: .outlineColor,
                                    HUDPickerPresentation(
                                        title: "Outline Color",
                                        options: Self.outlineColorOptions,
                                        selection: viewModel.settings.subtitleAppearance.textOutlineColor,
                                        onSelect: { value in
                                            updateAppearance { $0.textOutlineColor = value }
                                        }
                                    )
                                )
                            }
                            .id(Field.outlineColor)
                            HUDFocusedSettingRow(
                                label: "Background",
                                value: label(for: viewModel.settings.subtitleAppearance.backgroundColor, in: Self.backgroundColorOptions),
                                colorHex: viewModel.settings.subtitleAppearance.backgroundColor,
                                focused: $focusedField,
                                focusID: .backgroundColor,
                                onMoveUp: moveUp(from: .backgroundColor),
                                onMoveDown: moveDown(from: .backgroundColor),
                                onMoveLeft: hold(.backgroundColor),
                                onMoveRight: hold(.backgroundColor)
                            ) {
                                presentPicker(
                                    for: .backgroundColor,
                                    HUDPickerPresentation(
                                        title: "Background Color",
                                        options: Self.backgroundColorOptions,
                                        selection: viewModel.settings.subtitleAppearance.backgroundColor,
                                        onSelect: { value in
                                            updateAppearance { $0.backgroundColor = value }
                                        }
                                    )
                                )
                            }
                            .id(Field.backgroundColor)
                            HUDFocusedSettingRow(
                                label: "Opacity",
                                value: opacityLabel,
                                focused: $focusedField,
                                focusID: .opacity,
                                onMoveUp: moveUp(from: .opacity),
                                onMoveDown: moveDown(from: .opacity),
                                onMoveLeft: hold(.opacity),
                                onMoveRight: hold(.opacity)
                            ) {
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
                            .id(Field.opacity)
                            HUDFocusedSettingRow(
                                label: "Position",
                                value: viewModel.settings.subtitleAppearance.position.label,
                                focused: $focusedField,
                                focusID: .position,
                                onMoveUp: moveUp(from: .position),
                                onMoveDown: moveDown(from: .position),
                                onMoveLeft: hold(.position),
                                onMoveRight: hold(.position)
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
                            .id(Field.position)
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(maxHeight: 560)
                    .onAppear {
                        scrollToFocusedField(with: proxy, animated: false)
                    }
                    .onChange(of: focusedField) { _, _ in
                        scrollToFocusedField(with: proxy)
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(width: 720, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 26, y: 14)
            .focusSection()
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
        .onExitCommand(perform: activePicker == nil ? onClose : closePicker)
        .onAppear(perform: ensureDialogFocus)
        .onChange(of: focusedField) { _, value in
            if value == nil, activePicker == nil {
                ensureDialogFocus()
            }
        }
        .onChange(of: activePicker?.id) { _, _ in
            if activePicker == nil {
                ensureDialogFocus()
            }
        }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(focusedField == .close ? .black : .white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(focusedField == .close ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Circle())
            .focusable(true)
            .focused($focusedField, equals: .close)
            .onTapGesture(perform: onClose)
            .onMoveCommand { direction in
                switch direction {
                case .down:
                    focusedField = .style
                default:
                    focusedField = .close
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Close subtitle appearance")
    }

    private var orderedFields: [Field] {
        [.style, .font, .size, .textColor, .textOutline, .outlineColor, .backgroundColor, .opacity, .position]
    }

    private func ensureDialogFocus() {
        if focusedField == nil {
            focusedField = .style
        }
    }

    private func scrollToFocusedField(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let field = focusedField, orderedFields.contains(field) else { return }
        if animated {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                proxy.scrollTo(field, anchor: .center)
            }
        } else {
            proxy.scrollTo(field, anchor: .center)
        }
    }

    private func presentPicker(for field: Field, _ presentation: HUDPickerPresentation) {
        pickerReturnField = field
        focusedField = field
        activePicker = presentation
    }

    private func closePicker() {
        let field = pickerReturnField
        activePicker = nil
        if let field {
            focusedField = field
        }
    }

    private func hold(_ field: Field) -> () -> Void {
        { focusedField = field }
    }

    private func moveUp(from field: Field) -> () -> Void {
        { focusedField = fieldBefore(field) }
    }

    private func moveDown(from field: Field) -> () -> Void {
        { focusedField = fieldAfter(field) }
    }

    private func fieldBefore(_ field: Field) -> Field {
        guard let index = orderedFields.firstIndex(of: field) else {
            return .style
        }
        return index == 0 ? .close : orderedFields[index - 1]
    }

    private func fieldAfter(_ field: Field) -> Field {
        if field == .close {
            return .style
        }
        guard let index = orderedFields.firstIndex(of: field) else {
            return .style
        }
        return orderedFields[min(index + 1, orderedFields.count - 1)]
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
        SubtitleBackgroundStylePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

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

// MARK: - Audio pane

private struct AudioPane: View {
    let viewModel: PlayerViewModel
    let onMoveToTabs: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            PaneColumn("Tracks") {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(viewModel.audioTracks.enumerated()), id: \.element.id) { index, track in
                            HUDTrackRow(
                                name: track.primaryLabel,
                                attributes: track.attributesLabel,
                                isSelected: viewModel.selectedAudioId == track.trackId,
                                onMoveToTabs: index == 0 ? onMoveToTabs : nil
                            ) {
                                viewModel.selectAudio(track)
                            }
                        }
                    }
                }
            }

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
        let ms = viewModel.settings.audioSyncMs
        if ms == 0 { return "0 ms" }
        return (ms > 0 ? "+" : "") + "\(ms) ms"
    }
}

// MARK: - Subtitles pane

private struct SubtitlesPane: View {
    let viewModel: PlayerViewModel
    let onMoveToTabs: () -> Void

    @State private var showAppearanceDialog = false
    @State private var showAITranslateMenu = false
    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: FocusTarget?
    @State private var appearanceReturnField: FocusTarget?
    @FocusState private var focusedSubtitleField: FocusTarget?

    private enum FocusTarget: Hashable {
        case primary(String)
        case secondary(String)
        case option(Option)
    }

    private enum Option: Hashable {
        case delay
        case save
        case size
        case position
        case appearance
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 58) {
                PaneColumn("Tracks") { trackRows }
                    .frame(width: 470, alignment: .topLeading)
                PaneColumn("Options") { optionRows }
                    .frame(width: 440, alignment: .topLeading)
            }
            .disabled(showAppearanceDialog || activePicker != nil || showAITranslateMenu)
            .opacity(showAppearanceDialog || activePicker != nil || showAITranslateMenu ? 0.28 : 1)

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
                SubtitleTranslateMenu(viewModel: viewModel) {
                    showAITranslateMenu = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showAppearanceDialog)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: activePicker?.id)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showAITranslateMenu)
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

    private var optionOrder: [Option] {
        var options: [Option] = []
        if viewModel.backendCapabilities.supportsSubtitleDelay {
            options.append(.delay)
        }
        if viewModel.backendCapabilities.supportsSubtitleStyling {
            options.append(contentsOf: [.save, .size, .position, .appearance])
        }
        return options
    }

    private func focusFirstOption() {
        if viewModel.backendCapabilities.supportsSubtitleDelay {
            focusedSubtitleField = .option(.delay)
        } else if viewModel.backendCapabilities.supportsSubtitleStyling {
            focusedSubtitleField = .option(.save)
        }
    }

    private func holdOption(_ option: Option) -> () -> Void {
        { focusedSubtitleField = .option(option) }
    }

    private func moveOptionUp(from option: Option) -> () -> Void {
        {
            guard let index = optionOrder.firstIndex(of: option), index > 0 else {
                onMoveToTabs()
                return
            }
            focusedSubtitleField = .option(optionOrder[index - 1])
        }
    }

    private func moveOptionDown(from option: Option) -> () -> Void {
        {
            guard let index = optionOrder.firstIndex(of: option),
                  index < optionOrder.count - 1 else {
                focusedSubtitleField = .option(option)
                return
            }
            focusedSubtitleField = .option(optionOrder[index + 1])
        }
    }

    private func focusSelectedTrack() {
        if let selectedSubtitleId = viewModel.selectedSubtitleId {
            focusedSubtitleField = .primary(String(describing: selectedSubtitleId))
        } else {
            focusedSubtitleField = .primary("off")
        }
    }

    private func setAppearance(_ mutate: @escaping (inout SubtitleAppearance) -> Void) {
        var next = viewModel.settings.subtitleAppearance
        mutate(&next)
        Task { await viewModel.setSubtitleAppearance(next) }
    }

    private func presentPicker(for target: FocusTarget, _ presentation: HUDPickerPresentation) {
        pickerReturnField = target
        focusedSubtitleField = target
        activePicker = presentation
    }

    private func closePicker() {
        let target = pickerReturnField
        activePicker = nil
        if let target {
            focusedSubtitleField = target
        }
    }

    private func presentAppearanceDialog(from target: FocusTarget) {
        appearanceReturnField = target
        focusedSubtitleField = target
        showAppearanceDialog = true
    }

    private func closeAppearanceDialog() {
        let target = appearanceReturnField
        showAppearanceDialog = false
        if let target {
            focusedSubtitleField = target
        }
    }

    private static let sizeOptions: [HUDDropdownOption] =
        SubtitleFontSizePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let positionOptions: [HUDDropdownOption] =
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    @ViewBuilder
    private var trackRows: some View {
        ScrollView(showsIndicators: false) {
            // LazyVStack defers off-screen `HUDTrackRow` construction. Each
            // row carries a `.focusable(true)` and a Locale lookup; for files
            // with 15+ subtitle tracks the eager VStack built (and re-built
            // on every tab swap) the entire focus subtree, which is the
            // dominant cost stalling main when the Subtitles pane appears.
            LazyVStack(alignment: .leading, spacing: 2) {
                HUDFocusedTrackRow(
                    name: "Off",
                    attributes: nil,
                    isSelected: viewModel.selectedSubtitleId == nil,
                    focused: $focusedSubtitleField,
                    focusID: .primary("off"),
                    onMoveUp: onMoveToTabs,
                    onMoveRight: focusFirstOption
                ) {
                    viewModel.disableSubtitles()
                }
                ForEach(viewModel.subtitleTracks) { track in
                    HUDFocusedTrackRow(
                        name: track.primaryLabel,
                        attributes: track.attributesLabel,
                        isSelected: viewModel.selectedSubtitleId == track.trackId,
                        focused: $focusedSubtitleField,
                        focusID: .primary(String(describing: track.trackId)),
                        onMoveRight: focusFirstOption
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
                    HUDFocusedTrackRow(
                        name: "Off",
                        attributes: nil,
                        isSelected: viewModel.selectedSecondarySubtitleId == nil,
                        focused: $focusedSubtitleField,
                        focusID: .secondary("off"),
                        onMoveRight: focusFirstOption
                    ) {
                        viewModel.disableSecondarySubtitles()
                    }
                    ForEach(viewModel.availableSecondarySubtitleTracks) { track in
                        let disabled = track.trackId == viewModel.selectedSubtitleId
                        HUDFocusedTrackRow(
                            name: track.primaryLabel,
                            attributes: track.attributesLabel,
                            isSelected: viewModel.selectedSecondarySubtitleId == track.trackId,
                            isDisabled: disabled,
                            focused: $focusedSubtitleField,
                            focusID: .secondary(String(describing: track.trackId)),
                            onMoveRight: focusFirstOption
                        ) {
                            viewModel.selectSecondarySubtitle(track)
                        }
                    }
                }

                if aiSubtitlesAvailable {
                    Text("AI SUBTITLES")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 20)
                        .padding(.bottom, 4)
                        .padding(.leading, 14)
                    HUDFocusedTrackRow(
                        name: "Translate with AI…",
                        attributes: "Translate a subtitle track or transcribe audio",
                        isSelected: false,
                        focused: $focusedSubtitleField,
                        focusID: .primary("ai-translate"),
                        onMoveRight: focusFirstOption
                    ) {
                        showAITranslateMenu = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var optionRows: some View {
        VStack(spacing: 2) {
            if viewModel.backendCapabilities.supportsSubtitleDelay {
                HUDFocusedSettingRow(
                    label: "Delay",
                    value: delayText,
                    focused: $focusedSubtitleField,
                    focusID: .option(.delay),
                    onMoveUp: moveOptionUp(from: .delay),
                    onMoveDown: moveOptionDown(from: .delay),
                    onMoveLeft: focusSelectedTrack,
                    onMoveRight: holdOption(.delay)
                ) {
                    presentPicker(
                        for: .option(.delay),
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
            }
            if viewModel.backendCapabilities.supportsSubtitleStyling {
                HUDFocusedSettingRow(
                    label: "Save for this Apple TV",
                    value: HUDPickerOptions.boolLabel(viewModel.settings.subtitleUsesDeviceAppearanceOverride),
                    focused: $focusedSubtitleField,
                    focusID: .option(.save),
                    onMoveUp: moveOptionUp(from: .save),
                    onMoveDown: moveOptionDown(from: .save),
                    onMoveLeft: focusSelectedTrack,
                    onMoveRight: holdOption(.save)
                ) {
                    presentPicker(
                        for: .option(.save),
                        HUDPickerPresentation(
                            title: "Save for this Apple TV",
                            options: HUDPickerOptions.onOff,
                            selection: HUDPickerOptions.boolSelection(viewModel.settings.subtitleUsesDeviceAppearanceOverride),
                            onSelect: { value in
                                Task {
                                    await viewModel.setSubtitleDeviceOverrideEnabled(HUDPickerOptions.boolValue(for: value))
                                }
                            }
                        )
                    )
                }
                HUDFocusedSettingRow(
                    label: "Size",
                    value: viewModel.settings.subtitleAppearance.fontSize.label,
                    focused: $focusedSubtitleField,
                    focusID: .option(.size),
                    onMoveUp: moveOptionUp(from: .size),
                    onMoveDown: moveOptionDown(from: .size),
                    onMoveLeft: focusSelectedTrack,
                    onMoveRight: holdOption(.size)
                ) {
                    presentPicker(
                        for: .option(.size),
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
                HUDFocusedSettingRow(
                    label: "Position",
                    value: viewModel.settings.subtitleAppearance.position.label,
                    focused: $focusedSubtitleField,
                    focusID: .option(.position),
                    onMoveUp: moveOptionUp(from: .position),
                    onMoveDown: moveOptionDown(from: .position),
                    onMoveLeft: focusSelectedTrack,
                    onMoveRight: holdOption(.position)
                ) {
                    presentPicker(
                        for: .option(.position),
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
                HUDFocusedSettingRow(
                    label: "Appearance",
                    value: appearanceSummary,
                    systemImage: "textformat",
                    focused: $focusedSubtitleField,
                    focusID: .option(.appearance),
                    onMoveUp: moveOptionUp(from: .appearance),
                    onMoveDown: moveOptionDown(from: .appearance),
                    onMoveLeft: focusSelectedTrack,
                    onMoveRight: holdOption(.appearance)
                ) {
                    presentAppearanceDialog(from: .option(.appearance))
                }
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
    let onMoveToTabs: () -> Void

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
                            isCurrent: currentIndex == index,
                            onMoveToTabs: index == 0 ? onMoveToTabs : nil
                        ) {
                            viewModel.seekTo(seconds: chapter.time)
                            onSelect()
                        }
                    }
                }
            }
        }
    }
}

private struct HUDChapterRow: View {
    let number: Int
    let title: String
    let time: String
    let isCurrent: Bool
    let onMoveToTabs: (() -> Void)?
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", number))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Text(title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 12)

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(time)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isFocused)
        .onTapGesture(perform: action)
        .onMoveCommand { direction in
            if direction == .up {
                onMoveToTabs?()
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }
}

// MARK: - Track row (shared by Audio + Subtitle panes)

private struct HUDTrackRow: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    var onMoveToTabs: (() -> Void)?
    let action: () -> Void

    @FocusState private var isFocused: Bool

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
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : .white.opacity(0.55))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // Invert on focus (white fill + dark text) to match the strong
                // focus grammar of the other HUD rows; the previous 18% wash
                // read as barely-focused next to them.
                .fill(isFocused ? Color.white : Color.clear)
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isFocused)
        .onTapGesture(perform: action)
        .onMoveCommand { direction in
            if direction == .up {
                onMoveToTabs?()
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

#endif
