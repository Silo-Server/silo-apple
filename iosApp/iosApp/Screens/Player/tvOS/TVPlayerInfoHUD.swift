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
    @State private var readOnlyPaneIsAtTop = true
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
    /// Subtitles also appear when the stream has *no* tracks but the server
    /// can still produce them: AI (ASR transcription, or translating an
    /// existing text track), or a provider search. Without this, a file with
    /// no subtitles would hide the Subtitles tab entirely — and with it the
    /// only entry point to "AI Subtitles…" / "Search Subtitles…", which is
    /// exactly the case where they are most useful. Uses the same
    /// `hasActionableSource` probe the pane gates its AI row on.
    ///
    /// The search term is deliberately the **enabled** predicate, not the
    /// visible one: a row that can't be acted on must never be the sole
    /// reason its tab exists, or a track-less file on a server with no
    /// providers would open a Subtitles tab containing one greyed-out row.
    /// When the tab is present for another reason, the disabled row still
    /// renders inside it and explains itself.
    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.info, .stats, .video]
        if !viewModel.audioTracks.isEmpty { tabs.append(.audio) }
        if !viewModel.subtitleTracks.isEmpty
            || SubtitleTranslateMenu.hasActionableSource(viewModel)
            || viewModel.subtitleSearchEnabled {
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
            repairActiveTabIfUnavailable()
            // If the parent didn't seed focus (edge case on re-present), at
            // least make sure focus lands on the active tab so Menu has a
            // handler to bubble to.
            if focusedTab == nil {
                focusedTab = activeTab
            }
        }
        // The tab set is not static for the lifetime of the HUD: the subtitle
        // provider probe is async and fails open, so on a track-less,
        // non-AI session the Subtitles tab starts present (optimistic
        // `isAvailable`) and can drop out mid-session when the server answers
        // "no providers". If that happens while Subtitles is the active tab,
        // repairing only in `onAppear` would leave the panel rendering a pane
        // whose pill — and whose focus owner — no longer exists, which on
        // tvOS means focus can land nowhere at all (docs/tvos-focus.md).
        //
        // Repair-on-change rather than pinning `activeTab` into
        // `availableTabs`: keeping the active tab mounted unconditionally
        // would make the tab set depend on state this handler writes (a
        // derived-state feedback loop, the hazard this codebase has been
        // bitten by), it would defeat the `onAppear` repair entirely, and
        // because `TVPlayerControls` remembers `activeHUDTab` across HUD
        // presentations it would strand a Subtitles pill holding nothing but
        // a greyed-out row for the rest of the session.
        .onChange(of: availableTabs) { _, _ in
            repairActiveTabIfUnavailable()
        }
        .onChange(of: activeTab) { _, _ in
            readOnlyPaneIsAtTop = true
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
        // Info and Stats are single composite focus owners. Once either has
        // paged below its top anchor, remove the rail from the focus graph so
        // an Up press cannot both page the pane and escape to the active tab.
        // The pane re-enables the rail when it reaches the top again.
        .disabled(isReadOnlyPaneScrolled)
        // Rail: moving Up from the panel must land on the *active* pill, not
        // the geometrically nearest one — with focus-driven selection a
        // nearest-pill landing would switch panes as a side effect.
        .defaultFocus($focusedTab, activeTab, priority: .userInitiated)
    }

    // MARK: - Panel

    private var panel: some View {
        Group {
            switch activeTab {
            case .info:
                InfoPane(
                    viewModel: viewModel,
                    isAtTop: $readOnlyPaneIsAtTop,
                    onMoveToTabs: focusActiveTab
                )
            case .stats:
                StatsPane(
                    viewModel: viewModel,
                    isAtTop: $readOnlyPaneIsAtTop,
                    onMoveToTabs: focusActiveTab
                )
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
        // Top-aligned so short panes (Video with few rows) keep their column
        // headers pinned to the top instead of floating mid-panel.
        .frame(maxWidth: 1100, minHeight: 380, maxHeight: 380, alignment: .top)
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

    private var isReadOnlyPaneScrolled: Bool {
        (activeTab == .info || activeTab == .stats) && !readOnlyPaneIsAtTop
    }

    /// Move off a tab that is no longer in `availableTabs`, taking focus with
    /// it. Run on appear (a remembered `activeHUDTab` may not apply to this
    /// stream) and whenever the tab set changes underneath us.
    ///
    /// Focus is reseeded, not just the selection: whatever owned focus — the
    /// vanished pill, or a row inside the pane it selected — is leaving the
    /// hierarchy in this same update, and a tvOS view with no reachable focus
    /// target also has nothing for Menu to bubble `onExitCommand` from, which
    /// strands the user in the HUD. `.defaultFocus` only seeds on first
    /// appearance of the focus scope, so it cannot cover this.
    ///
    /// `availableTabs` always contains `.info`, so `first` is effectively
    /// non-nil; it stays optional to keep this honest if that ever changes.
    private func repairActiveTabIfUnavailable() {
        guard !availableTabs.contains(activeTab),
              let first = availableTabs.first else { return }
        activeTab = first
        focusedTab = first
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

// MARK: - Info pane

private struct InfoPane: View {
    let viewModel: PlayerViewModel
    @Binding var isAtTop: Bool
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
            isAtTop: $isAtTop,
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
        guard let index = viewModel.currentChapterIndex else { return nil }
        let current = viewModel.chapters[index]
        return current.title ?? "Chapter \(current.index + 1)"
    }
}

// MARK: - Stats pane

private struct StatsPane: View {
    let viewModel: PlayerViewModel
    @Binding var isAtTop: Bool
    let onMoveToTabs: () -> Void

    private static let topAnchor = "stats.top"
    private static let bottomAnchor = "stats.bottom"

    var body: some View {
        HUDScrollablePane(
            accessibilityLabel: "Playback stats",
            scrollTargetIDs: scrollTargetIDs,
            isAtTop: $isAtTop,
            onMoveToTabs: onMoveToTabs
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0).id(Self.topAnchor)
                PlaybackStatsPanel(
                    stats: viewModel.playbackStats,
                    usesTVTypography: true,
                    usesTwoColumnLayout: true
                )
                Color.clear.frame(height: 0).id(Self.bottomAnchor)
            }
        }
    }

    /// Paging targets. The pane opens scrolled to the top (Source/Media),
    /// so the target list must start with a top anchor — without it the
    /// index nominally sits on the first section while the view shows the
    /// top, making the first Down skip a section and, worse, Up exit to
    /// the tab bar while Source/Media are still scrolled off above. The
    /// bottom anchor makes the tail of the last section reachable when it
    /// is taller than the viewport.
    private var scrollTargetIDs: [String] {
        var ids: [String] = [Self.topAnchor]
        if !viewModel.playbackStats.bufferRows.isEmpty {
            ids.append(PlaybackStatsPanel.bufferSectionID)
        }
        if !viewModel.playbackStats.networkRows.isEmpty {
            ids.append(PlaybackStatsPanel.networkSectionID)
        }
        if !viewModel.playbackStats.deviceRows.isEmpty {
            ids.append(PlaybackStatsPanel.deviceSectionID)
        }
        ids.append(Self.bottomAnchor)
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
                                    selection: viewModel.activeQualityId,
                                    onSelect: { viewModel.switchQuality($0) }
                                )
                            )
                        }
                        .focused($focusedField, equals: .quality)

                        HUDSettingRow(label: "Speed", value: Self.speedLabel(viewModel.settings.playbackSpeed)) {
                            presentPicker(
                                for: .speed,
                                HUDPickerPresentation(
                                    title: "Playback Speed",
                                    options: Self.speedOptions,
                                    selection: Self.speedID(viewModel.settings.playbackSpeed),
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

                    }
                }
                .focusSection()

                PaneColumn("Sync") {
                    VStack(spacing: 2) {
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
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: activePicker?.id)
    }

    private var qualityValue: String {
        if viewModel.isQualitySwitching {
            return "Switching..."
        }
        if let error = viewModel.qualitySwitchError, !error.isEmpty {
            return error
        }
        return viewModel.qualityOptions.first(where: { $0.id == viewModel.activeQualityId })?.labelWithBitrate
            ?? ApplePlaybackQuality.displayNameWithBitrate(for: viewModel.activeQualityId)
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

    private static func speedID(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func speedLabel(_ value: Double) -> String {
        value == 1.0 ? "1.0×" : String(format: "%.2f×", value)
    }

    private static let speedValues: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private static let speedOptions: [HUDDropdownOption] = speedValues.map { value in
        HUDDropdownOption(id: speedID(value), label: speedLabel(value))
    }

    private static let aspectOptions: [HUDDropdownOption] =
        VideoGravity.allCases.map { .init(id: $0.rawValue, label: $0.label) }
}

// MARK: - Audio pane

private struct AudioPane: View {
    let viewModel: PlayerViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            PaneColumn("Tracks") {
                ScrollView(showsIndicators: false) {
                    // Keep the complete focus graph mounted so native tvOS
                    // movement and keep-visible scrolling share one owner.
                    VStack(spacing: 2) {
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
    @FocusState private var entryTrackFocused: Bool

    /// Identity for the options-column rows, used only to restore focus when
    /// a picker dialog, the appearance dialog, or the AI/search menu closes.
    private enum Option: Hashable {
        case translate
        case search
        case delay
        case save
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
            // The Subtitles pill is geometrically closest to the Options
            // column. Explicitly route Down into the leftmost Tracks column
            // so entering this pane is consistent with the other track panes.
            .defaultFocus($entryTrackFocused, true, priority: .userInitiated)
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
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showAppearanceDialog)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: activePicker?.id)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showAITranslateMenu)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showSubtitleSearchMenu)
    }

    private func closeAITranslateMenu() {
        showAITranslateMenu = false
        focusedOption = .translate
    }

    /// Restore focus to the "Search Subtitles…" row — unless the provider
    /// probe answered "unavailable" while the menu was open, which swaps that
    /// row for the disabled variant that carries no `.focused(...)` binding.
    /// Returning focus to an unreachable target would leave the pane with
    /// nothing focused, so fall back to the Tracks column's "Off" row, which
    /// is always present (docs/tvos-focus.md).
    private func closeSubtitleSearchMenu() {
        showSubtitleSearchMenu = false
        if viewModel.subtitleSearchEnabled {
            focusedOption = .search
        } else {
            entryTrackFocused = true
        }
    }

    /// Whether the server's AI capabilities + the current track list offer any
    /// AI subtitle action (translate an existing text track, or transcribe
    /// audio). Gates the "Translate with AI…" row so it never opens an empty
    /// menu. Shared with the iOS `MobilePlayerControls` via the same helper.
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

    @ViewBuilder
    private var trackRows: some View {
        ScrollView(showsIndicators: false) {
            // Eager by design: every native Button stays in one stable focus
            // graph, and the ScrollView performs its own keep-visible motion.
            VStack(alignment: .leading, spacing: 2) {
                HUDTrackRow(
                    name: "Off",
                    attributes: nil,
                    isSelected: viewModel.selectedSubtitleId == nil
                ) {
                    viewModel.disableSubtitles()
                }
                .focused($entryTrackFocused)
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
        // Scrollable: with every capability present (AI, Search, Delay,
        // Save, Size, Position, Appearance) the column outgrows the fixed
        // panel height; without a ScrollView the last row clips at the
        // panel edge and focus can't bring it fully into view.
        ScrollView(showsIndicators: false) {
            optionRowsContent
        }
    }

    @ViewBuilder
    private var optionRowsContent: some View {
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
                .id(Option.translate)
            }
            if viewModel.subtitleSearchVisible {
                // Two mutually-exclusive variants rather than one row with
                // modifiers applied conditionally: a non-focusable row must
                // not carry a `.focused(...)` binding (same idiom as
                // `TVGeneralSettingsView.presetRow`), or the focus engine
                // holds a binding for a target it can never reach.
                //
                // The disabled variant also needs the explicit `.opacity`:
                // `HUDSettingRowLabel` derives every color from
                // `@Environment(\.isFocused)`, so `.disabled(true)` alone
                // would render pixel-identical to an enabled unfocused row.
                // Same treatment `HUDTrackRow` uses for its disabled rows.
                if let reason = viewModel.subtitleSearchUnavailableReason {
                    HUDSettingRow(
                        label: "Search Subtitles…",
                        value: "",
                        detail: reason,
                        systemImage: "magnifyingglass",
                        action: {}
                    )
                    .disabled(true)
                    .opacity(0.35)
                    .accessibilityHint(reason)
                    .id(Option.search)
                } else {
                    HUDSettingRow(
                        label: "Search Subtitles…",
                        value: "",
                        systemImage: "magnifyingglass"
                    ) {
                        showSubtitleSearchMenu = true
                    }
                    .focused($focusedOption, equals: .search)
                    .id(Option.search)
                }
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
                .id(Option.delay)
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
                .focused($focusedOption, equals: .save)
                .id(Option.save)
                HUDSettingRow(
                    label: "Size",
                    value: viewModel.settings.subtitleAppearance.fontSize.label
                ) {
                    presentPicker(
                        for: .size,
                        HUDPickerPresentation(
                            title: "Subtitle Size",
                            options: SubtitleAppearanceDialog.sizeOptions,
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
                .id(Option.size)
                HUDSettingRow(
                    label: "Position",
                    value: viewModel.settings.subtitleAppearance.position.label
                ) {
                    presentPicker(
                        for: .position,
                        HUDPickerPresentation(
                            title: "Subtitle Position",
                            options: SubtitleAppearanceDialog.positionOptions,
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
                .id(Option.position)
                HUDSettingRow(
                    label: "Appearance",
                    value: appearanceSummary,
                    systemImage: "textformat"
                ) {
                    showAppearanceDialog = true
                }
                .focused($focusedOption, equals: .appearance)
                .id(Option.appearance)
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

    var body: some View {
        PaneColumn("Chapters") {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { index, chapter in
                        HUDChapterRow(
                            number: index + 1,
                            title: chapter.title ?? "Chapter \(index + 1)",
                            time: PlayerTimeFormatter.formatHMS(chapter.time),
                            isCurrent: viewModel.currentChapterIndex == index
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
#endif
