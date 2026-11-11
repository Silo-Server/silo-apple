#if os(tvOS)
import SwiftUI

/// Infuse-style floating top-center HUD. A pill-tab header (Subtitles /
/// Audio / Chapters / Settings / Info) selects which content pane renders
/// below, in one panel sized to that pane (`panelSize`).
/// Drops on top of the video with no dimming backdrop so playback stays
/// visible, matching the "HUD over media" idiom rather than a modal sheet.
/// Menu dismisses via `onExitCommand` on the host view.
///
/// Focus model (see docs/tvos-focus.md): every interactive row is a real
/// `Button` and movement is owned entirely by the tvOS focus engine —
/// columns are `.focusSection()`s and the tab bar routes entry to the
/// active pill with `defaultFocus(priority: .userInitiated)`. `@FocusState`
/// is used only to seed focus (HUD open, dialog open) and to restore it
/// (dialog close), never to drive per-press movement. Info's technical
/// details are a single composite focusable that pages its scroll content,
/// which is the sanctioned exception.
struct TVPlayerInfoHUD: View {
    let viewModel: PlayerViewModel
    @Binding var activeTab: Tab
    @State private var readOnlyPaneIsAtTop = true
    @State private var subtitleOverlayActive = false
    /// Options in the Settings pane's open picker (nil when none is open), so
    /// the panel grows to show them all and shrinks back after.
    @State private var settingsPickerRows: Int?
    /// Info's technical details are open (the panel is taller then).
    @State private var showsTechnicalDetails = false
    @State private var showSubtitleSearchMenu = false
    @State private var showAITranslateMenu = false

    private var subtitleMenuPresented: Bool {
        showSubtitleSearchMenu || showAITranslateMenu
    }
    /// Focus target for the tab-bar pills, owned by `TVPlayerControls`.
    /// Sharing this via `@FocusState.Binding` lets the parent seed focus on
    /// a specific pill when the HUD opens, which is critical: without a
    /// deterministic initial focus the Menu button has nothing to bubble
    /// `onExitCommand` from and the user can get stuck.
    @FocusState.Binding var focusedTab: Tab?
    let onDismiss: () -> Void

    enum Tab: Hashable, CaseIterable {
        case subtitles, audio, chapters, video, info

        var title: LocalizedStringResource {
            switch self {
            case .subtitles: return .optionsTabSubtitles
            case .audio:     return .optionsTabAudio
            case .chapters:  return .optionsTabChapters
            // Picture and playback settings; "Video" read as picture-only.
            case .video:     return .settingsTitle
            case .info:      return .optionsTabInfo
            }
        }
    }

    /// Tabs shown for the current session, the ones viewers use most first.
    /// Settings and Info are always available; Subtitles / Audio / Chapters
    /// are hidden (not disabled) when the stream has none of those.
    ///
    /// Subtitles also appears when the stream has no tracks but the server can
    /// still produce them (AI transcription or translation, or a provider
    /// search), because the tab is the only entry point to those actions. The
    /// search term uses the *enabled* predicate, not the visible one, so a
    /// greyed-out row is never the sole reason the tab exists.
    private var availableTabs: [Tab] {
        var tabs: [Tab] = []
        if !viewModel.subtitleTracks.isEmpty
            || SubtitleTranslateMenu.hasActionableSource(viewModel)
            || viewModel.subtitleSearchEnabled {
            tabs.append(.subtitles)
        }
        if !viewModel.audioTracks.isEmpty { tabs.append(.audio) }
        if !viewModel.chapters.isEmpty { tabs.append(.chapters) }
        tabs.append(contentsOf: [.video, .info])
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
        // Re-check on change: the provider probe can remove the Subtitles tab
        // mid-session; if it was active, move to the first available tab so
        // focus always has a target.
        .onChange(of: availableTabs) { _, _ in
            repairActiveTabIfUnavailable()
        }
        .onChange(of: activeTab) { _, _ in
            readOnlyPaneIsAtTop = true
        }
        .onExitCommand(perform: onDismiss)
        .disabled(subtitleMenuPresented)
        // Keep the HUD mounted for focus restoration, but show only the
        // search dialog over a backdrop that spans the whole player.
        .opacity(subtitleMenuPresented ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if showAITranslateMenu {
                SubtitleTranslateMenu(
                    viewModel: viewModel,
                    onDismiss: { showAITranslateMenu = false },
                    onJobStarted: {
                        showAITranslateMenu = false
                        onDismiss()
                    }
                )
            } else if showSubtitleSearchMenu {
                SubtitleSearchMenu(
                    viewModel: viewModel,
                    onDismiss: { showSubtitleSearchMenu = false },
                    onDownloaded: {
                        showSubtitleSearchMenu = false
                        onDismiss()
                    }
                )
            }
        }
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
        // Info's technical details are a single composite focus owner. Once
        // they have paged below their top anchor, remove the rail from the
        // focus graph so an Up press cannot both page the pane and escape to
        // the active tab. The pane re-enables the rail at the top again.
        .disabled(isReadOnlyPaneScrolled || subtitleOverlayActive)
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
                    showsTechnicalDetails: $showsTechnicalDetails,
                    isAtTop: $readOnlyPaneIsAtTop,
                    onMoveToTabs: focusActiveTab
                )
            case .video:
                VideoPane(viewModel: viewModel)
                    .onPreferenceChange(HUDPickerRowsKey.self) { settingsPickerRows = $0 }
            case .audio:     AudioPane(viewModel: viewModel)
            case .subtitles:
                SubtitlesPane(
                    viewModel: viewModel,
                    overlayActive: $subtitleOverlayActive,
                    showSubtitleSearchMenu: $showSubtitleSearchMenu,
                    showAITranslateMenu: $showAITranslateMenu
                )
            case .chapters:  ChaptersPane(viewModel: viewModel, onSelect: onDismiss)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // Sized to the active pane, under the same tabs: a short pane gets a
        // short panel rather than an empty slab, and long lists scroll
        // inside the tallest one. Top-aligned so column headers stay put.
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: panelSize)
        // A neutral dark fill, not glass: glass took on the picture's colour
        // and never looked the same twice.
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(white: 0.06).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .focusSection()
    }

    /// Room for the active pane: Settings' few rows (or every option of its
    /// open picker), the audio tracks, the synopsis or the technical details;
    /// the long lists get the full height and scroll.
    private var panelSize: CGSize {
        switch activeTab {
        case .subtitles:
            return CGSize(width: 1240, height: 620)
        case .audio:
            return CGSize(width: 900, height: min(620, max(300, 170 + CGFloat(viewModel.audioTracks.count) * 84)))
        case .chapters:
            return CGSize(width: 1100, height: 620)
        case .video:
            let rows = settingsPickerRows.map { 130 + CGFloat($0) * 62 } ?? 300
            return CGSize(width: 1000, height: min(620, rows))
        case .info:
            return CGSize(width: 1320, height: showsTechnicalDetails ? 560 : 470)
        }
    }

    private var isReadOnlyPaneScrolled: Bool {
        activeTab == .info && !readOnlyPaneIsAtTop
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
    /// `availableTabs` always contains Settings and Info, so `first` is effectively
    /// non-nil; it stays optional to keep this honest if that ever changes.
    private func repairActiveTabIfUnavailable() {
        guard !availableTabs.contains(activeTab),
              let first = availableTabs.first else { return }
        activeTab = first
        focusedTab = first
    }

    /// Used by Info when Up is pressed at the top
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
    let title: LocalizedStringResource
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
        .accessibilityLabel(Text(title))
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
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            // 12pt keeps the pill above the 48pt TV focus-target floor.
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).stroke(strokeColor, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isSelected)
    }

    // Focus is the one solid white treatment across the player; the
    // selected tab, when focus is elsewhere, is a quieter lit pill.
    private var foreground: Color {
        isFocused ? .black : .white
    }

    private var background: Color {
        if isFocused  { return .white }
        if isSelected { return .white.opacity(0.24) }
        return .black.opacity(0.45)
    }

    private var strokeColor: Color {
        if isFocused { return .clear }
        return isSelected ? .white.opacity(0.55) : .white.opacity(0.18)
    }
}

// MARK: - Shared column header

private struct PaneColumn<Content: View>: View {
    let header: LocalizedStringResource
    let content: () -> Content

    init(_ header: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(header)
                .font(.system(size: 18, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fades the last rows of a pane's scroll content into the panel instead of
/// cutting them at its edge, so a list that continues reads as continuing.
/// The bottom margin lets the last row scroll clear of the fade.
private struct HUDScrollEdgeFade: ViewModifier {
    /// Room reserved under the list for the "More" cue, so it never sits on
    /// a row.
    static let footerHeight: CGFloat = 40

    /// What the cue calls the content below.
    var label: LocalizedStringResource = .playerHudMore

    @State private var continuesBelow = false
    /// Where the viewport sits in the list: its top and height as fractions
    /// of the content. Nil when everything fits.
    @State private var position: ClosedRange<CGFloat>?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    < geometry.contentSize.height - 1
            } action: { _, below in
                continuesBelow = below
            }
            .onScrollGeometryChange(for: ClosedRange<CGFloat>?.self) { geometry in
                let total = geometry.contentSize.height
                let visible = geometry.containerSize.height
                guard total > visible + 1 else { return nil }
                let top = max(0, geometry.contentOffset.y) / total
                return top...min(1, top + visible / total)
            } action: { _, range in
                position = range
            }
            // The list scrolls under the cue's strip. Draw none of it there,
            // so content that isn't hidden row by row never runs under "More".
            .mask {
                GeometryReader { proxy in
                    Rectangle()
                        .frame(height: max(0, proxy.size.height - Self.footerHeight))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .ignoresSafeArea()
            }
            // A slim bar at the list's right edge: how much of the list shows
            // and where, so earlier rows read as there as much as later ones.
            .overlay(alignment: .topTrailing) {
                if let position {
                    GeometryReader { proxy in
                        let track = proxy.size.height - Self.footerHeight
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 4, height: track)
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(Color.white.opacity(0.7))
                                    .frame(width: 4, height: max(24, track * (position.upperBound - position.lowerBound)))
                                    .offset(y: track * position.lowerBound)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZStack {
                    if continuesBelow {
                        Label { Text(label) } icon: { Image(systemName: "chevron.down") }
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.footerHeight, maxHeight: Self.footerHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: continuesBelow)
    }
}

/// Shows a list row only when the whole row is inside its list's viewport:
/// the list never ends on half a row (the "More" cue says it continues).
/// Focus moving onto a hidden row scrolls it fully into view first.
private struct HUDWholeRow: ViewModifier {
    func body(content: Content) -> some View {
        content.visualEffect { effect, proxy in
            let viewport = proxy.bounds(of: .scrollView(axis: .vertical))
            let whole = viewport.map { $0.minY <= 0.5 && $0.maxY >= proxy.size.height - 0.5 } ?? true
            return effect.opacity(whole ? 1 : 0)
        }
    }
}

private extension View {
    func hudScrollEdgeFade(label: LocalizedStringResource = .playerHudMore) -> some View {
        modifier(HUDScrollEdgeFade(label: label))
    }
    func hudWholeRow() -> some View { modifier(HUDWholeRow()) }

    /// The opaque plate of a dialog over the panel (a picker card, subtitle
    /// appearance): nothing behind it reads through.
    func hudDialogPlate() -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return background(shape.fill(Color(white: 0.07).opacity(0.97)))
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

/// How many options a pane's open picker shows, so the panel can size to it.
private struct HUDPickerRowsKey: PreferenceKey {
    static let defaultValue: Int? = nil
    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        value = nextValue() ?? value
    }
}

/// Lays short content out as is and scrolls only content taller than the
/// room it is given, so a short list lets the panel hug it.
private struct HUDFittingScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView(showsIndicators: false) {
                content()
            }
            .hudScrollEdgeFade()
        }
    }
}

private struct HUDScrollablePane<Content: View>: View {
    let accessibilityLabel: LocalizedStringResource
    let scrollTargetIDs: [String]
    let moreLabel: LocalizedStringResource
    @Binding var isAtTop: Bool
    let onMoveToTabs: () -> Void
    let content: () -> Content

    @State private var scrollTargetIndex: Int = 0
    /// The scroll position, to tell a Down that moved nothing.
    @State private var contentOffsetY: CGFloat = 0
    @FocusState private var isFocused: Bool

    init(
        accessibilityLabel: LocalizedStringResource,
        scrollTargetIDs: [String] = [],
        moreLabel: LocalizedStringResource = .playerHudMore,
        isAtTop: Binding<Bool>,
        onMoveToTabs: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.scrollTargetIDs = scrollTargetIDs
        self.moreLabel = moreLabel
        self._isAtTop = isAtTop
        self.onMoveToTabs = onMoveToTabs
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .padding(.trailing, 8)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                contentOffsetY = offset
            }
            .hudScrollEdgeFade(label: moreLabel)
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
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .accessibilityLabel(Text(accessibilityLabel))
            .onMoveCommand { direction in
                handleMove(direction, proxy: proxy)
            }
            .onChange(of: scrollTargetIDs) { _, targets in
                scrollTargetIndex = min(scrollTargetIndex, max(targets.count - 1, 0))
            }
            .onChange(of: scrollTargetIndex) { _, index in
                isAtTop = index == 0
            }
            .onAppear {
                isAtTop = scrollTargetIndex == 0
            }
            .onDisappear {
                isAtTop = true
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
        let previousIndex = scrollTargetIndex
        let offsetBefore = contentOffsetY
        scrollTargetIndex = nextIndex

        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            proxy.scrollTo(scrollTargetIDs[nextIndex], anchor: .top)
        }

        // The last targets can sit closer to the end than a page and all
        // land at the end. A Down that moved nothing takes its step back, so
        // the next Up pages instead of stepping back to where the list is.
        if direction == .down {
            DispatchQueue.main.asyncAfter(deadline: .now() + SiloTheme.fastDuration + 0.15) {
                if scrollTargetIndex == nextIndex, abs(contentOffsetY - offsetBefore) < 1 {
                    scrollTargetIndex = previousIndex
                }
            }
        }
    }
}

/// Right-aligned "label — value" row used in the Info and options columns.
private struct LabelValueRow: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.82))
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
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
    let label: LocalizedStringResource
    let value: String
    /// Optional secondary line under the label. Used to explain a disabled
    /// row — the trailing `value` slot is only ~165pt wide at 22pt semibold,
    /// which truncates any real sentence.
    var detail: String? = nil
    var colorHex: String? = nil
    var systemImage: String? = nil
    /// Off for rows that act in place rather than open a picker or menu.
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDSettingRowLabel(
                label: label,
                value: value,
                detail: detail,
                colorHex: colorHex,
                systemImage: systemImage,
                showsChevron: showsChevron
            )
        }
        .buttonStyle(HUDRowButtonStyle())
        .hudWholeRow()
        .accessibilityLabel(Text(label))
        .accessibilityValue(value.isEmpty ? (detail ?? "") : value)
    }
}

/// Boolean row that flips on Select — one press instead of the previous
/// open-dialog → pick → close round-trip.
private struct HUDToggleRow: View {
    let label: LocalizedStringResource
    var detail: String? = nil
    let isOn: Bool
    let onToggle: (Bool) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Button { onToggle(!isOn) } label: {
            HUDSettingRowLabel(
                label: label,
                value: AppLanguage.string(HUDPickerOptions.boolLabel(isOn), locale: locale),
                detail: detail,
                showsChevron: false,
                switchOn: isOn
            )
        }
        .buttonStyle(HUDRowButtonStyle())
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(HUDPickerOptions.boolLabel(isOn)))
        .accessibilityAddTraits(.isToggle)
    }
}

private struct HUDSettingRowLabel: View {
    let label: LocalizedStringResource
    let value: String
    var detail: String? = nil
    var colorHex: String? = nil
    var systemImage: String? = nil
    let showsChevron: Bool
    /// A switch in place of the value text, for on/off rows.
    var switchOn: Bool? = nil

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
            }
            // Second line mirrors `HUDTrackRowLabel`'s attributes line: 17pt,
            // dimmed, focus-inverted. Only rendered when a `detail` is given,
            // so ordinary rows keep their exact single-line metrics.
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 25, weight: .medium))
                    .lineLimit(1)
                if let detail {
                    // Two lines: an explanation cut to "…" explains nothing.
                    Text(detail)
                        .font(.system(size: 22))
                        .foregroundStyle(isFocused ? .black.opacity(0.72) : .white.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 18)
            HStack(spacing: 10) {
                if let colorHex {
                    ColorSwatch(hex: colorHex)
                }
                if let switchOn {
                    HUDSwitch(isOn: switchOn, isFocused: isFocused)
                } else {
                    Text(value)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isFocused ? .black.opacity(0.78) : .white.opacity(0.8))
                }
                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : .white.opacity(0.6))
                }
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

/// On/off state drawn as a switch, inverted on a focused (white) row.
private struct HUDSwitch: View {
    let isOn: Bool
    let isFocused: Bool

    var body: some View {
        // Ink on the row's ground; an "on" track is filled with ink and its
        // knob takes the ground colour.
        let ink: Color = isFocused ? .black : .white
        let ground: Color = isFocused ? .white : .black
        Capsule()
            .fill(isOn ? ink : ink.opacity(0.22))
            .frame(width: 58, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? ground : ink)
                    .frame(width: 24, height: 24)
                    .padding(4)
            }
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isOn)
            .accessibilityHidden(true)
    }
}

// MARK: - Info pane

private struct InfoPane: View {
    let viewModel: PlayerViewModel
    /// Technical details (what Stats was) open in this panel, in place of
    /// About and Now playing. The HUD owns it: the panel is taller then.
    @Binding var showsTechnicalDetails: Bool
    @Binding var isAtTop: Bool
    let onMoveToTabs: () -> Void
    @FocusState private var toggleFocused: Bool

    @Environment(\.locale) private var locale

    private static let topAnchor = "info.details.top"
    private static let detailsAnchor = "info.details.rows"
    private static let bottomAnchor = "info.details.bottom"
    /// The first page of the details: the health line and the readings.
    private static let summaryPageHeight: CGFloat = 300

    var body: some View {
        Group {
            if showsTechnicalDetails {
                technicalDetails
            } else {
                about
            }
        }
        // Down from the tabs lands on the toggle, the pane's one control
        // until the details open.
        .defaultFocus($toggleFocused, true, priority: .userInitiated)
    }

    /// "Technical details" / "Hide technical details", top right in both
    /// states so focus stays put when it flips.
    private var technicalDetailsToggle: some View {
        Button {
            showsTechnicalDetails.toggle()
            // Next turn, once the other state's button is in the focus graph.
            DispatchQueue.main.async { toggleFocused = true }
        } label: {
            Label {
                Text(showsTechnicalDetails
                     ? LocalizedStringResource.playerHudHideTechnicalDetails
                     : .playerHudTechnicalDetails)
            } icon: {
                Image(systemName: showsTechnicalDetails ? "chevron.up" : "waveform.path.ecg")
            }
            .font(.system(size: 21, weight: .semibold))
            // Dark on the focused row's white, as the setting rows are.
            .foregroundStyle(toggleFocused ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .buttonStyle(HUDRowButtonStyle(cornerRadius: 22))
        .focused($toggleFocused)
        // Paged below the details' top, the rail is out of the focus graph
        // and Up must reach the pane to page back. A focusable toggle above
        // would take that press instead, and from it Up leads nowhere.
        .disabled(showsTechnicalDetails && !isAtTop)
    }

    private var about: some View {
        HStack(alignment: .top, spacing: 40) {
            PaneColumn(.playerHudAbout) {
                if let series = viewModel.metadata.seriesTitle, !series.isEmpty {
                    Text(series.uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(displayTitle)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let episode = viewModel.metadata.episodeTag {
                    Text(episode)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if !metaBits.isEmpty {
                    Text(metaBits.joined(separator: "  ·  "))
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
                if let overview = viewModel.metadata.overview, !overview.isEmpty {
                    // The height the lines above leave in the panel, ending
                    // on an ellipsis rather than under its edge. Laid out
                    // last, so the title and facts keep their lines.
                    Text(overview)
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(6)
                        .padding(.top, 4)
                        .layoutPriority(-1)
                }
            }
            // The synopsis takes the width; the facts beside it are short.
            .frame(width: 640, alignment: .topLeading)

            // A hairline between the story and the playback facts.
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(.playerHudNowPlayingHeading)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.68))
                        .textCase(.uppercase)
                    Spacer()
                    technicalDetailsToggle
                }
                ForEach(streamRows, id: \.id) { row in
                    LabelValueRow(label: row.label, value: row.value)
                }
                InfoCurrentChapterRow(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .focusSection()
        }
    }

    /// What the Stats tab was: the health summary first, then every row,
    /// paged with Down. Up at the top returns to the toggle.
    private var technicalDetails: some View {
        let stats = viewModel.playbackStats
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(.playerHudTechnicalDetails)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.68))
                    .textCase(.uppercase)
                Spacer()
                technicalDetailsToggle
            }
            HUDScrollablePane(
                accessibilityLabel: .playerStatsTitle,
                scrollTargetIDs: detailsScrollTargets,
                moreLabel: isAtTop ? .playerStatsAllDetails : .playerHudMore,
                isAtTop: $isAtTop,
                onMoveToTabs: { toggleFocused = true }
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    PlaybackStatsSummaryView(summary: stats.summary, scale: .tv)
                        .frame(maxWidth: .infinity, minHeight: Self.summaryPageHeight, alignment: .topLeading)
                    Color.clear.frame(height: 0).id(Self.detailsAnchor)
                    PlaybackStatsPanel(stats: stats, usesTVTypography: true, usesTwoColumnLayout: true)
                        // Hidden on the summary page, where only its first
                        // rows would show under the cue; shown once paged to.
                        .visualEffect { effect, proxy in
                            let viewport = proxy.bounds(of: .scrollView(axis: .vertical))
                            let pagedTo = viewport.map { $0.minY > -$0.height / 2 } ?? true
                            return effect.opacity(pagedTo ? 1 : 0)
                        }
                    Color.clear.frame(height: 0).id(Self.bottomAnchor)
                }
            }
        }
    }

    /// Paging targets: the summary, the rows, the later sections, the end.
    private var detailsScrollTargets: [String] {
        var ids = [Self.topAnchor, Self.detailsAnchor]
        if !viewModel.playbackStats.networkRows.isEmpty { ids.append(PlaybackStatsPanel.networkSectionID) }
        if !viewModel.playbackStats.engineRows.isEmpty { ids.append(PlaybackStatsPanel.engineSectionID) }
        ids.append(Self.bottomAnchor)
        return ids
    }

    private var displayTitle: String {
        viewModel.metadata.primaryTitle.isEmpty
            ? viewModel.title
            : viewModel.metadata.primaryTitle
    }

    private var metaBits: [String] {
        var bits: [String] = []
        if let year = viewModel.metadata.year { bits.append(LocaleFormat.integer(year, locale: locale)) }
        if viewModel.duration > 0 {
            bits.append(PlayerTimeFormatter.formatRuntime(viewModel.duration, locale: locale))
        }
        return bits
    }

    private var streamRows: [(id: String, label: LocalizedStringResource, value: String)] {
        // What is playing, in viewer terms. The route (engine · delivery)
        // and the rest of the diagnostics live in Technical details — this
        // view is the casual "what am I watching" surface.
        var rows: [(id: String, label: LocalizedStringResource, value: String)] = []
        // The picture as the Stats summary names it ("1080p"), in place of
        // the badges that repeated the Audio row.
        if let picture = viewModel.playbackStats.video.label, !picture.isEmpty {
            rows.append((id: "video", label: .playerHudVideo, value: picture))
        }
        if let audio = viewModel.audioTracks.first(where: { $0.trackId == viewModel.selectedAudioId }) {
            var bits: [String] = []
            if let codec = TrackLabels.audioCodec(audio.codec) { bits.append(codec) }
            if let channels = audio.channelCountLabel { bits.append(channels) }
            if !bits.isEmpty { rows.append((id: "audio", label: .playerHudAudio, value: bits.joined(separator: " · "))) }
        }
        if let sub = viewModel.subtitleTracks.first(where: { $0.trackId == viewModel.selectedSubtitleId }) {
            rows.append((id: "subtitles", label: .playerHudSubtitles, value: sub.singleLineLabel))
        } else {
            rows.append((
                id: "subtitles",
                label: .playerHudSubtitles,
                value: AppLanguage.string(.playerTracksSubtitlesOff, locale: locale)
            ))
        }
        return rows
    }
}

/// Reads `currentTime` in its own body so the rest of the Info pane doesn't
/// re-render on every playback clock tick.
private struct InfoCurrentChapterRow: View {
    let viewModel: PlayerViewModel

    @Environment(\.locale) private var locale

    var body: some View {
        if let chapter = currentChapterTitle {
            LabelValueRow(label: .playerHudChapter, value: chapter)
        }
    }

    private var currentChapterTitle: String? {
        guard !viewModel.chapters.isEmpty,
              let current = viewModel.chapters.last(where: { $0.time <= viewModel.currentTime })
        else { return nil }
        return current.title ?? AppLanguage.string(.optionsChapterNumbered(LocaleFormat.integer(current.index + 1, locale: locale)), locale: locale)
    }
}

// MARK: - Video pane

/// Playback / display / sync controls. Multi-option settings open the shared
/// picker dialog; booleans toggle in place. Focus movement between rows and
/// across the two columns is native.
private struct VideoPane: View {
    let viewModel: PlayerViewModel

    @Environment(\.locale) private var locale

    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Field?
    @FocusState private var focusedField: Field?

    /// Identity for the picker-backed rows, used only to restore focus after
    /// the dialog closes.
    private enum Field: Hashable {
        case quality
        case speed
        case aspect
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 40) {
                // What is shown, and how it is drawn.
                PaneColumn(.playerHudPicture) {
                    VStack(spacing: 2) {
                        if viewModel.hasQualityChoice {
                            HUDSettingRow(label: .optionsQuality, value: qualityValue) {
                                // The row stays focusable (disabling a focused
                                // row would move focus); it reads "Switching..."
                                // and opens nothing until the switch lands.
                                guard !viewModel.isQualitySwitching else { return }
                                presentPicker(
                                    for: .quality,
                                    HUDPickerPresentation(
                                        title: .optionsQuality,
                                        options: qualityOptions,
                                        // No row is checked while a fixed saved
                                        // resolution sets the quality.
                                        selection: viewModel.highlightedQualityOptionId ?? "",
                                        onSelect: { viewModel.switchQuality($0) }
                                    )
                                )
                            }
                            .focused($focusedField, equals: .quality)
                        }

                        HUDSettingRow(label: .playerHudAspect, value: viewModel.settings.videoGravity.label) {
                            presentPicker(
                                for: .aspect,
                                HUDPickerPresentation(
                                    title: .playerHudAspect,
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
                .focusSection()

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1)
                    .padding(.vertical, 4)

                // How playback runs.
                PaneColumn(.playerHudPlayback) {
                    VStack(spacing: 2) {
                        if !viewModel.isWatchPartyPlayback {
                            HUDSettingRow(label: .playerSettingsSpeed, value: Self.speedLabel(viewModel.settings.playbackSpeed)) {
                                presentPicker(
                                    for: .speed,
                                    HUDPickerPresentation(
                                        title: .playerHudPickerPlaybackSpeed,
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
                        }

                        // For an episode, or anything in a shuffle, whose
                        // next pick this decides; a movie alone has no next.
                        if !viewModel.isWatchPartyPlayback,
                           viewModel.metadata.episodeTag != nil || viewModel.shuffleState != nil {
                            HUDToggleRow(label: .optionsAutoplayNext, isOn: viewModel.settings.autoPlayNextEpisode) {
                                viewModel.settings.setAutoPlayNextEpisode($0)
                            }
                        }
                    }
                }
                .focusSection()
            }
            .disabled(activePicker != nil)
            .opacity(activePicker != nil ? 0 : 1)

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
        .preference(key: HUDPickerRowsKey.self, value: activePicker?.options.count)
    }

    private var qualityValue: String {
        if viewModel.isQualitySwitching {
            return AppLanguage.string(.playerHudQualitySwitching, locale: locale)
        }
        if let error = viewModel.qualitySwitchError, !error.isEmpty {
            return error
        }
        // A local Settings rung's bitrate is not the session's, so the
        // fallback names the preference without one.
        return viewModel.activeQualityOption?.labelWithBitrate
            ?? ApplePlaybackQuality.displayName(for: viewModel.activeQualityId)
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

    /// "1×", "1.25×", "1.5×": one format, no padded zeros, in the app's
    /// language ("1,25×").
    private static func speedLabel(_ value: Double) -> String {
        LocaleFormat.rate(value)
    }

    /// Computed on each read, so the labels follow the app's language. The
    /// ids stay "1.25" in every language.
    private static var speedOptions: [HUDDropdownOption] {
        [0.75, 1.0, 1.25, 1.5, 2.0].map { value in
            HUDDropdownOption(id: String(format: "%.2f", value), label: speedLabel(value))
        }
    }

    /// Computed on each read, so the labels follow the app's language.
    private static var aspectOptions: [HUDDropdownOption] {
        VideoGravity.allCases.map { .init(id: $0.rawValue, label: $0.label) }
    }
}

private struct HUDDropdownOption: Identifiable, Hashable {
    let id: String
    let label: String
    var colorHex: String? = nil
}

private enum HUDPickerOptions {
    // Computed on each read, so the labels follow the app's language.
    static var subtitleSizes: [HUDDropdownOption] {
        SubtitleFontSizePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }
    }

    static var subtitlePositions: [HUDDropdownOption] {
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }
    }

    static func boolLabel(_ value: Bool) -> LocalizedStringResource {
        value ? .optionsOn : .optionsOff
    }

    static func delayLabel(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return LocaleFormat.integer(0) + " ms" }
        return (milliseconds > 0 ? "+" : "") + LocaleFormat.integer(milliseconds) + " ms"
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
    let title: LocalizedStringResource
    let options: [HUDDropdownOption]
    let selection: String
    let onSelect: (String) -> Void
}

/// Option list over a `.disabled` pane — disabling the background is what
/// keeps focus contained in here. Movement and keep-visible scrolling are
/// native; focus is seeded onto the current selection when it appears.
///
/// `.page` replaces the pane inside the HUD panel (the pane hides while it
/// shows), so the options read as a step into the setting rather than a
/// card over half-visible rows. `.card` floats over another dialog.
private struct HUDPickerDialog: View {
    enum Presentation { case page, card }

    let title: LocalizedStringResource
    let options: [HUDDropdownOption]
    let selection: String
    var presentation: Presentation = .page
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focusedOptionID: String?

    var body: some View {
        Group {
            switch presentation {
            case .page:
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            case .card:
                content
                    .padding(.horizontal, 34)
                    .padding(.vertical, 28)
                    .frame(width: 620, alignment: .topLeading)
                    .hudDialogPlate()
                    .shadow(color: .black.opacity(0.62), radius: 26, y: 14)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .focusSection()
        .defaultFocus($focusedOptionID, initialFocusID)
        .onExitCommand(perform: onClose)
    }

    private var titleSize: CGFloat { presentation == .page ? 26 : 30 }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Menu steps back to the pane; the chevron says so.
                if presentation == .page {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: titleSize * 0.7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
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
                .frame(maxHeight: presentation == .card ? 520 : .infinity)
                .hudScrollEdgeFade()
                .onAppear {
                    if let initialFocusID {
                        proxy.scrollTo(initialFocusID, anchor: .center)
                        focusedOptionID = initialFocusID
                    }
                }
            }
        }
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
        .hudWholeRow()
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? Text(.playerMenuSelected) : Text(verbatim: ""))
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
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

private struct ColorSwatch: View {
    let hex: String

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
    }
}

private struct SubtitleAppearanceDialog: View {
    let viewModel: PlayerViewModel
    let onClose: () -> Void

    @Environment(\.locale) private var locale

    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Field?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case close
        case deviceOverride
        case matchSystem
        case style
        case font
        case size
        case textColor
        case textOpacity
        case outlineToggle
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
                        Text(.playerHudAppearanceEyebrow)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(.playerHudStyleAndColors)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    closeButton
                }

                ScrollView(showsIndicators: true) {
                    VStack(spacing: 2) {
                        HUDToggleRow(
                            label: .playerHudStyleThisAppleTvOnly,
                            detail: AppLanguage.string(.playerHudStyleThisAppleTvOnlyDetail, locale: locale),
                            isOn: viewModel.settings.subtitleUsesDeviceAppearanceOverride
                        ) { enabled in
                            Task {
                                await viewModel.setSubtitleDeviceOverrideEnabled(enabled)
                            }
                        }
                        .focused($focusedField, equals: .deviceOverride)
                        .id(Field.deviceOverride)

                        HUDToggleRow(
                            label: .playerSubtitlesUseDeviceSettings,
                            isOn: viewModel.settings.subtitleMatchesSystemAppearance
                        ) { enabled in
                            viewModel.setSubtitleMatchesSystemAppearance(enabled)
                        }
                        .focused($focusedField, equals: .matchSystem)
                        .id(Field.matchSystem)

                        HUDSettingRow(
                            label: .playerSubtitlesStyleBackgroundStyle,
                            value: viewModel.settings.subtitleAppearance.backgroundStyle.label
                        ) {
                            presentPicker(
                                for: .style,
                                HUDPickerPresentation(
                                    title: .playerHudPickerSubtitleStyle,
                                    options: Self.backgroundStyleOptions,
                                    selection: viewModel.settings.subtitleAppearance.backgroundStyle.rawValue,
                                    onSelect: { value in
                                        if let style = SubtitleBackgroundStylePreset(rawValue: value) {
                                            viewModel.updateSubtitleAppearance {
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
                        .id(Field.style)

                        HUDSettingRow(
                            label: .playerSubtitlesStyleFont,
                            value: viewModel.settings.subtitleAppearance.fontFamily.label
                        ) {
                            presentPicker(
                                for: .font,
                                HUDPickerPresentation(
                                    title: .playerHudPickerSubtitleFont,
                                    options: Self.fontFamilyOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontFamily.rawValue,
                                    onSelect: { value in
                                        if let font = SubtitleFontFamilyPreset(rawValue: value) {
                                            viewModel.updateSubtitleAppearance { $0.fontFamily = font }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .font)
                        .id(Field.font)

                        HUDSettingRow(
                            label: .playerSubtitlesStyleSize,
                            value: viewModel.settings.subtitleAppearance.fontSize.label
                        ) {
                            presentPicker(
                                for: .size,
                                HUDPickerPresentation(
                                    title: .playerHudPickerSubtitleSize,
                                    options: HUDPickerOptions.subtitleSizes,
                                    selection: viewModel.settings.subtitleAppearance.fontSize.rawValue,
                                    onSelect: { value in
                                        if let size = SubtitleFontSizePreset(rawValue: value) {
                                            viewModel.updateSubtitleAppearance { $0.fontSize = size }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .size)
                        .id(Field.size)

                        HUDSettingRow(
                            label: .playerHudAppearanceText,
                            value: label(for: viewModel.settings.subtitleAppearance.fontColor, in: Self.fontColorOptions),
                            colorHex: viewModel.settings.subtitleAppearance.fontColor
                        ) {
                            presentPicker(
                                for: .textColor,
                                HUDPickerPresentation(
                                    title: .playerHudPickerTextColor,
                                    options: Self.fontColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontColor,
                                    onSelect: { value in
                                        viewModel.updateSubtitleAppearance { $0.fontColor = value }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .textColor)
                        .id(Field.textColor)

                        if viewModel.settings.offersSubtitleTextOpacity {
                            HUDSettingRow(label: .playerSubtitlesStyleTextOpacityLabel, value: textOpacityLabel) {
                                presentPicker(
                                    for: .textOpacity,
                                    HUDPickerPresentation(
                                        title: .playerSubtitlesStyleTextOpacityLabel,
                                        options: Self.opacityOptions(
                                            current: viewModel.settings.subtitleAppearance.textOpacity,
                                            lowest: 25
                                        ),
                                        selection: String(viewModel.settings.subtitleAppearance.textOpacity),
                                        onSelect: { value in
                                            if let opacity = Int(value) {
                                                viewModel.updateSubtitleAppearance { $0.textOpacity = opacity }
                                            }
                                        }
                                    )
                                )
                            }
                            .focused($focusedField, equals: .textOpacity)
                            .id(Field.textOpacity)
                        }

                        HUDToggleRow(
                            label: .playerSubtitlesStyleTextOutline,
                            isOn: viewModel.settings.subtitleAppearance.textOutline
                        ) { enabled in
                            viewModel.updateSubtitleAppearance { $0.textOutline = enabled }
                        }
                        .focused($focusedField, equals: .outlineToggle)
                        .id(Field.outlineToggle)

                        HUDSettingRow(
                            label: .playerHudSubtitleOutline,
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
                                    title: .playerHudPickerOutlineColor,
                                    options: Self.outlineColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.textOutlineColor,
                                    onSelect: { value in
                                        // Picking a color turns the outline on.
                                        viewModel.updateSubtitleAppearance {
                                            $0.textOutlineColor = value
                                            $0.textOutline = true
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .outlineColor)
                        .id(Field.outlineColor)

                        HUDSettingRow(
                            label: .playerSubtitlesStyleBackground,
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
                                    title: .playerHudPickerBackgroundColor,
                                    options: Self.backgroundColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.backgroundColor,
                                    onSelect: { value in
                                        // Picking a color switches the style to Box.
                                        viewModel.updateSubtitleAppearance {
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
                        .id(Field.backgroundColor)

                        HUDSettingRow(label: .playerSubtitlesStyleOpacity, value: opacityLabel) {
                            presentPicker(
                                for: .opacity,
                                HUDPickerPresentation(
                                    title: .playerSubtitlesStyleBackgroundOpacityLabel,
                                    options: Self.opacityOptions(
                                        current: viewModel.settings.subtitleAppearance.backgroundOpacity,
                                        lowest: 0
                                    ),
                                    selection: String(viewModel.settings.subtitleAppearance.backgroundOpacity),
                                    onSelect: { value in
                                        if let opacity = Int(value) {
                                            viewModel.updateSubtitleAppearance {
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
                        .id(Field.opacity)

                        HUDSettingRow(
                            label: .playerSubtitlesStylePosition,
                            value: viewModel.settings.subtitleAppearance.position.label
                        ) {
                            presentPicker(
                                for: .position,
                                HUDPickerPresentation(
                                    title: .playerHudPickerSubtitlePosition,
                                    options: HUDPickerOptions.subtitlePositions,
                                    selection: viewModel.settings.subtitleAppearance.position.rawValue,
                                    onSelect: { value in
                                        if let position = SubtitlePositionPreset(rawValue: value) {
                                            viewModel.updateSubtitleAppearance { $0.position = position }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .position)
                        .id(Field.position)
                    }
                    .padding(.trailing, 8)
                }
                .hudScrollEdgeFade()
                .frame(maxHeight: 560)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(width: 720, alignment: .topLeading)
            // Opaque, like the picker card: the subtitle rows dimmed behind it
            // would otherwise read through the glass.
            .hudDialogPlate()
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
                    presentation: .card,
                    onSelect: activePicker.onSelect,
                    onClose: closePicker
                )
            }
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: activePicker?.id)
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
        .accessibilityLabel(Text(.playerHudCloseAppearance))
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

    private var opacityLabel: String {
        guard viewModel.settings.subtitleAppearance.backgroundStyle == .box,
              viewModel.settings.subtitleAppearance.backgroundOpacity > 0 else {
            return AppLanguage.string(.optionsOff, locale: locale)
        }
        return LocaleFormat.percent(viewModel.settings.subtitleAppearance.backgroundOpacity)
    }

    private var textOpacityLabel: String {
        LocaleFormat.percent(viewModel.settings.subtitleAppearance.textOpacity)
    }

    private func label(for id: String, in options: [HUDDropdownOption]) -> String {
        options.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.label ?? id
    }

    // The option lists are computed on each read, so their labels follow
    // the app's language.
    private static var backgroundStyleOptions: [HUDDropdownOption] {
        SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }
    }

    private static var fontFamilyOptions: [HUDDropdownOption] {
        SubtitleFontFamilyPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }
    }

    /// 25-point steps from `lowest`, plus the current value when another
    /// client stored one between them. Text opacity starts at 25 (the schema's
    /// floor is 1, which is invisible); background opacity starts at Off.
    private static func opacityOptions(current: Int, lowest: Int) -> [HUDDropdownOption] {
        SubtitleAppearance.opacityPickerValues(current: current, lowest: lowest, step: 25)
            .map { .init(id: String($0), label: $0 == 0 ? AppLanguage.string(.optionsOff) : LocaleFormat.percent($0)) }
    }

    private static var fontColorOptions: [HUDDropdownOption] {
        SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }
    }

    private static var outlineColorOptions: [HUDDropdownOption] {
        SubtitleAppearance.outlineColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }
    }

    private static var backgroundColorOptions: [HUDDropdownOption] {
        SubtitleAppearance.backgroundColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }
    }
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
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
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
            PaneColumn(.playerHudTracks) {
                HUDFittingScroll {
                    // Keep the complete focus graph mounted so native tvOS
                    // movement and keep-visible scrolling share one owner.
                    VStack(spacing: 2) {
                        ForEach(viewModel.audioTracks) { track in
                            let text = Self.rowText(track)
                            HUDTrackRow(
                                name: text.name,
                                attributes: text.attributes,
                                isSelected: viewModel.selectedAudioId == track.trackId
                            ) {
                                viewModel.selectAudio(track)
                            }
                        }
                    }
                }
            }
            .focusSection()
            // The selected track's codec and channels are on its row; no
            // column repeats them.
        }
    }

    /// A track with a title of its own ("Commentary with …") leads with it:
    /// several English tracks would otherwise all read "English", with what
    /// tells them apart cut short on the second line.
    static func rowText(_ track: PlayerTrack) -> (name: String, attributes: String?) {
        guard let detail = track.detailLabel else {
            return (track.primaryLabel, track.attributesLabel)
        }
        var pills = track.attributesLabel ?? ""
        if pills.hasPrefix(detail) {
            pills = String(pills.dropFirst(detail.count))
            if pills.hasPrefix(" · ") { pills = String(pills.dropFirst(3)) }
        }
        let attributes = [track.primaryLabel, pills].filter { !$0.isEmpty }.joined(separator: " · ")
        return (detail, attributes)
    }
}

// MARK: - Subtitles pane

private struct SubtitlesPane: View {
    let viewModel: PlayerViewModel
    @Binding var overlayActive: Bool
    @Binding var showSubtitleSearchMenu: Bool
    @Binding var showAITranslateMenu: Bool
    @State private var showAppearanceDialog = false
    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Option?
    @FocusState private var focusedOption: Option?
    @FocusState private var entryTrackFocused: Bool
    @Environment(\.locale) private var locale

    /// Identity for the options-column rows, used only to restore focus when
    /// a picker dialog, the appearance dialog, or the AI/search menu closes.
    private enum Option: Hashable {
        case translate
        case search
        case syncTiming
        case resetTiming
        case delay
        case appearance
    }

    private var hasPresentedOverlay: Bool {
        showAppearanceDialog || activePicker != nil || showAITranslateMenu || showSubtitleSearchMenu
    }

    var body: some View {
        ZStack {
            // The tracks, and beside them the style and the other actions:
            // the fixed panel has room for both.
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(.playerHudTracks)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.68))
                        .textCase(.uppercase)
                    trackRows
                }
                .frame(width: 600, alignment: .topLeading)
                .focusSection()

                if firstOptionRow != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(.playerHudStyle)
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.68))
                            .textCase(.uppercase)
                        optionRows
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .focusSection()
                }
            }
            // Down from the tab bar enters the list at its first row (Off).
            .defaultFocus($entryTrackFocused, true, priority: .userInitiated)
            .disabled(hasPresentedOverlay)
            // A picker page replaces the pane; the dialogs float over it.
            .opacity(activePicker != nil ? 0 : (hasPresentedOverlay ? 0.2 : 1))

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

        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showAppearanceDialog)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: activePicker?.id)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showAITranslateMenu)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showSubtitleSearchMenu)
        // The HUD rail selects panes on focus. Keep it out of the focus graph
        // while a dialog replaces its rows during search or other actions.
        .onChange(of: hasPresentedOverlay, initial: true) { _, presented in
            overlayActive = presented
        }
        .onDisappear { overlayActive = false }
        .onAppear { viewModel.refreshSubtitleSync() }
        // A refusal (403) swaps the Sync row for its unfocusable variant, and
        // a reset removes the Reset row; hand focus to a neighbour then.
        .onChange(of: timingFocusTargets) { _, targets in
            guard let focused = focusedOption, focused == .syncTiming || focused == .resetTiming,
                  !targets.contains(focused) else { return }
            if let neighbour = targets.first {
                focusedOption = neighbour
            } else if viewModel.backendCapabilities.supportsSubtitleDelay {
                focusedOption = .delay
            } else {
                entryTrackFocused = true
            }
        }
        .onChange(of: showSubtitleSearchMenu) { _, presented in
            if !presented {
                // Restore after the HUD becomes visible and focusable again.
                DispatchQueue.main.async {
                    guard !showSubtitleSearchMenu else { return }
                    restoreSubtitleSearchFocus()
                }
            }
        }
        .onChange(of: showAITranslateMenu) { _, presented in
            if !presented {
                DispatchQueue.main.async {
                    guard !showAITranslateMenu else { return }
                    if aiSubtitlesAvailable {
                        focusedOption = .translate
                    } else {
                        entryTrackFocused = true
                    }
                }
            }
        }
    }

    /// Restore focus to the "Search Subtitles…" row — unless the provider
    /// probe answered "unavailable" while the menu was open, which removes
    /// that row.
    /// Returning focus to an unreachable target would leave the pane with
    /// nothing focused, so fall back to the Tracks column's "Off" row, which
    /// is always present (docs/tvos-focus.md).
    private func restoreSubtitleSearchFocus() {
        if viewModel.subtitleSearchEnabled {
            focusedOption = .search
        } else {
            entryTrackFocused = true
        }
    }

    /// Whether the server's AI capabilities + the current track list offer any
    /// AI subtitle action (translate an existing text track, or transcribe
    /// audio). Gates the "Translate with AI…" row so it never opens an empty
    /// menu. Shared with the iOS `TrackSelectionSheet` via the same helper.
    private var aiSubtitlesAvailable: Bool {
        SubtitleTranslateMenu.hasActionableSource(viewModel)
    }

    /// "Large · Bottom · Box": what the appearance dialog is set to.
    private var appearanceSummary: String {
        let appearance = viewModel.settings.subtitleAppearance
        return [appearance.fontSize.label, appearance.position.label, appearance.backgroundStyle.label]
            .joined(separator: " · ")
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
                // One ordered list, one line per track (details beside the
                // name), so every row is the same height. Off leads.
                trackCell(nil, sharedLabels: [])
                let sharedLabels = sharedTrackLabels
                ForEach(viewModel.orderedSubtitleTracks) { track in
                    trackCell(track, sharedLabels: sharedLabels)
                }

                if viewModel.supportsSecondarySubtitles,
                   viewModel.selectedSubtitleId != nil,
                   !viewModel.availableSecondarySubtitleTracks.isEmpty {
                    Text(.playerHudSecondaryHeading)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 20)
                        .padding(.bottom, 4)
                        .padding(.leading, 14)
                    HUDTrackRow(
                        name: AppLanguage.string(.playerTracksSubtitlesOff, locale: locale),
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
        .hudScrollEdgeFade()
    }

    /// One row of the track list: a track, or Off for nil.
    @ViewBuilder
    private func trackCell(_ track: PlayerTrack?, sharedLabels: Set<String>) -> some View {
        if let track {
            HUDTrackRow(
                name: track.primaryLabel,
                attributes: attributes(for: track, showsFormat: sharedLabels.contains(track.singleLineLabel)),
                isSelected: viewModel.selectedSubtitleId == track.trackId,
                isDisabled: track.hasUnsupportedFormat,
                inlineAttributes: true
            ) {
                viewModel.selectSubtitle(track)
            }
        } else {
            HUDTrackRow(
                name: AppLanguage.string(.playerTracksSubtitlesOff, locale: locale),
                attributes: nil,
                isSelected: viewModel.selectedSubtitleId == nil
            ) {
                viewModel.disableSubtitles()
            }
            .focused($entryTrackFocused)
        }
    }

    /// The track's attributes, followed by its sync status when it can be
    /// synced ("Syncing… 40%", "Synced −3.0 s"). The format ("SRT") only
    /// when another track would otherwise read the same.
    private func attributes(for track: PlayerTrack, showsFormat: Bool) -> String? {
        let status = track.hasUnsupportedFormat
            ? PlayerTrack.unsupportedFormatLabel
            : viewModel.subtitleSyncStatus(for: track)
        let parts = [track.attributesLabel(includingFormat: showsFormat), status]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Labels two or more subtitle tracks share, whose rows need the format.
    private var sharedTrackLabels: Set<String> {
        let counts = Dictionary(viewModel.orderedSubtitleTracks.map { ($0.singleLineLabel, 1) }, uniquingKeysWith: +)
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// The selected track's sync entry, when timing actions apply.
    private var selectedTiming: (key: String, entry: SubtitleSyncModel.Entry, canSync: Bool)? {
        let sync = viewModel.subtitleSync
        guard let key = viewModel.selectedSubtitleSyncKey, let entry = sync.entry(for: key),
              sync.showsTimingControls(entry) else { return nil }
        return (key, entry, sync.canSync(entry))
    }

    /// The timing rows that can hold focus right now.
    private var timingFocusTargets: [Option] {
        guard let timing = selectedTiming, !timing.entry.isForbidden else { return [] }
        var targets: [Option] = []
        if timing.canSync { targets.append(.syncTiming) }
        if timing.entry.canReset { targets.append(.resetTiming) }
        return targets
    }

    /// "Sync to Audio" and "Reset Timing" for the selected track, stored or a
    /// file next to the media, with a running sync's progress and the last
    /// result. Rows stay enabled while a request runs, so focus never lands
    /// on a row that just went inert; a press during a running job does
    /// nothing. The progress and the note under the rows never take focus.
    @ViewBuilder
    private var timingRows: some View {
        if let timing = selectedTiming {
            let entry = timing.entry
            let sync = viewModel.subtitleSync
            if entry.isForbidden {
                HUDSettingRow(
                    label: .playerTracksSyncToAudioButton,
                    value: "",
                    detail: sync.forbiddenMessage,
                    systemImage: "waveform",
                    showsChevron: false,
                    action: {}
                )
                .disabled(true)
                .opacity(0.35)
                .id(Option.syncTiming)
            } else {
                // An unsupported format keeps its explanation in the note
                // below, but no action that could never run.
                if timing.canSync {
                    HUDSettingRow(
                        label: entry.isInProgress ? .playerTracksSyncing : .playerTracksSyncToAudioButton,
                        value: "",
                        systemImage: "waveform",
                        showsChevron: false
                    ) {
                        guard !entry.isBusy, !entry.isInProgress else { return }
                        Task { await sync.requestSync(key: timing.key) }
                    }
                    .focused($focusedOption, equals: .syncTiming)
                    .id(Option.syncTiming)
                }
                if let job = entry.job, job.isInProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        SubtitleSyncProgressBar(percent: SubtitleSyncLabel.percent(job) ?? 0)
                        if let phase = SubtitleSyncLabel.phase(job) {
                            Text(phase)
                                .font(.system(size: 17))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
                if entry.canReset {
                    HUDSettingRow(
                        label: .playerTracksResetTimingButton,
                        value: "",
                        systemImage: "arrow.uturn.backward",
                        showsChevron: false
                    ) {
                        guard !entry.isBusy, !entry.isInProgress else { return }
                        Task { await sync.resetTiming(key: timing.key) }
                    }
                    .focused($focusedOption, equals: .resetTiming)
                    .id(Option.resetTiming)
                }
                if let note = timingNote(entry, canSync: timing.canSync) {
                    Text(note.text)
                        .font(.system(size: 17))
                        .foregroundStyle(note.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    /// The line under the timing rows: the last action's error, the last
    /// result, or what "Sync to Audio" does.
    private func timingNote(_ entry: SubtitleSyncModel.Entry, canSync: Bool) -> (text: String, color: Color)? {
        if let error = entry.error { return (error, Color(red: 1, green: 0.55, blue: 0.55)) }
        if let result = entry.result {
            return (result.text, result.isWarning ? Color.siloWarning.opacity(0.9) : .white.opacity(0.55))
        }
        if canSync, !entry.isInProgress { return (entry.actionNote, .white.opacity(0.45)) }
        return nil
    }

    /// The Style column's first row; nil when the server offers no subtitle
    /// options at all (the column is then left out).
    private var firstOptionRow: Option? {
        if aiSubtitlesAvailable { return .translate }
        if viewModel.subtitleSearchEnabled { return .search }
        if let timing = timingFocusTargets.first { return timing }
        if viewModel.backendCapabilities.supportsSubtitleDelay { return .delay }
        if viewModel.backendCapabilities.supportsSubtitleStyling { return .appearance }
        return nil
    }

    @ViewBuilder
    private var optionRows: some View {
        // Scrollable: with every capability present (AI, Search, the timing
        // rows, Delay, Appearance) the column can outgrow the panel's
        // height; without a ScrollView the last row clips at the panel edge
        // and focus can't bring it fully into view.
        HUDFittingScroll {
            optionRowsContent
        }
    }

    @ViewBuilder
    private var optionRowsContent: some View {
        VStack(spacing: 8) {
            if aiSubtitlesAvailable {
                HUDSettingRow(
                    label: .playerAiTranslateOpenMenu,
                    value: "",
                    systemImage: "sparkles"
                ) {
                    showAITranslateMenu = true
                }
                .focused($focusedOption, equals: .translate)
                .id(Option.translate)
            }
            if viewModel.subtitleSearchEnabled {
                HUDSettingRow(
                    label: .optionsSearchSubtitles,
                    value: "",
                    systemImage: "magnifyingglass"
                ) {
                    showSubtitleSearchMenu = true
                }
                .focused($focusedOption, equals: .search)
                .id(Option.search)
            }
            timingRows
            if viewModel.backendCapabilities.supportsSubtitleDelay {
                HUDSettingRow(label: .playerHudDelay, value: delayText) {
                    presentPicker(
                        for: .delay,
                        HUDPickerPresentation(
                            title: .playerSettingsSubtitleDelayTitle,
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
                // Size, position, colors and the per-device switch live in
                // the appearance dialog; the pane keeps the track list first.
                HUDSettingRow(
                    label: .playerHudSubtitleAppearance,
                    value: "",
                    detail: appearanceSummary,
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

    @Environment(\.locale) private var locale

    /// Updated by `CurrentChapterIndexReader` only when the chapter changes,
    /// so the list doesn't re-render on every playback clock tick.
    @State private var currentIndex: Int?
    @State private var scrolledToCurrent = false
    @State private var redirectedEntry = false
    @FocusState private var focusedRow: Int?

    var body: some View {
        PaneColumn(.optionsChapters) {
            // Opens on the chapter that is playing, which is also where focus
            // enters the list, rather than at chapter 1.
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { index, chapter in
                            HUDChapterRow(
                                number: index + 1,
                                title: chapter.title ?? AppLanguage.string(.optionsChapterNumbered(LocaleFormat.integer(index + 1, locale: locale)), locale: locale),
                                time: PlayerTimeFormatter.formatHMS(chapter.time),
                                isCurrent: currentIndex == index
                            ) {
                                viewModel.seekTo(seconds: chapter.time)
                                onSelect()
                            }
                            .focused($focusedRow, equals: index)
                            .id(index)
                        }
                    }
                }
                .hudScrollEdgeFade()
                .onChange(of: currentIndex, initial: true) { _, index in
                    guard !scrolledToCurrent, let index else { return }
                    scrolledToCurrent = true
                    // Next turn: on the first pass the rows aren't laid out
                    // yet, the scroll is dropped, and the list opens at
                    // chapter 1 with the playing one out of view.
                    DispatchQueue.main.async {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
        .focusSection()
        .defaultFocus($focusedRow, currentIndex)
        // Down from the tab bar lands on the row nearest the tab, not the
        // default; the first time focus enters, move it to the chapter
        // playing, and the list scrolls it into view.
        .onChange(of: focusedRow) { old, new in
            guard old == nil, new != nil, !redirectedEntry,
                  let current = currentIndex, new != current else { return }
            redirectedEntry = true
            focusedRow = current
        }
        .background {
            CurrentChapterIndexReader(viewModel: viewModel, index: $currentIndex)
        }
    }
}

/// Non-focusable reader that observes `currentTime` in its own body and
/// forwards the current chapter index only when it changes.
private struct CurrentChapterIndexReader: View {
    let viewModel: PlayerViewModel
    @Binding var index: Int?

    var body: some View {
        let current = viewModel.chapters.lastIndex(where: { $0.time <= viewModel.currentTime })
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: current, initial: true) { _, newValue in
                index = newValue
            }
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
        .hudWholeRow()
        .accessibilityLabel(title)
        .accessibilityValue(isCurrent ? Text(.playerHudCurrentlyPlaying) : Text(verbatim: ""))
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
            Text(verbatim: LocaleFormat.localized(String(format: "%02d", number)))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Text(title)
                .font(.system(size: 25, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isFocused ? .black : .white)
                .lineLimit(1)

            Spacer(minLength: 12)

            // Named, not just an icon: the row the picture is on.
            if isCurrent {
                Label {
                    Text(.playerStatsPhasePlaying)
                } icon: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isFocused ? Color.black.opacity(0.1) : Color.white.opacity(0.16))
                    )
            }

            Text(time)
                .font(.system(size: 22, weight: .medium))
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
    /// Details on the name's line rather than under it, for lists whose
    /// details are short (subtitle flags) and whose rows should all match.
    var inlineAttributes = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDTrackRowLabel(name: name, attributes: attributes, isSelected: isSelected, inline: inlineAttributes)
        }
        .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .hudWholeRow()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isSelected ? Text(.playerMenuSelected) : Text(verbatim: ""))
    }

    /// Rows lead with the language, so the name alone reads "English" for
    /// every English track; VoiceOver hears the detail line too.
    private var accessibilityName: String {
        guard let attributes else { return name }
        return "\(name), \(attributes.replacingOccurrences(of: " · ", with: ", "))"
    }
}

private struct HUDTrackRowLabel: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var inline = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if inline {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(name)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(1)
                    if let attributes {
                        Text(attributes)
                            .font(.system(size: 22))
                            .foregroundStyle(isFocused ? .black.opacity(0.72) : .white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    // Two lines: a commentary title names its speakers.
                    Text(name)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let attributes {
                        Text(attributes)
                            .font(.system(size: 22))
                            .foregroundStyle(isFocused ? .black.opacity(0.72) : .white.opacity(0.8))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
    }
}
#endif
