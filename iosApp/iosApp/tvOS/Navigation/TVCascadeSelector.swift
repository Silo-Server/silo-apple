#if os(tvOS)
import SwiftUI

/// The Skyline cascading library selector (§5.3, mockups `a3`/`a6`).
///
/// Replaces the old full-screen library picker with an **anchored overlay
/// over the page** (never a pushed route, never a full-screen modal): a
/// glass panel below the tab, over a `scrim.dropdown`. One component, two
/// levels:
///
/// - **Level 1 — libraries.** A row per real library of the type (Rev 3
///   removed the merged `All <Type>` row). The current scope shows a `✓`;
///   the others a `›`. Single-library tabs collapse this away and show the
///   sections panel directly.
/// - **Level 2 — sections flyout.** Anchored to the focused library row's
///   right, listing that type's pill set (§3 / `TVLibraryPill.set`). It
///   follows focus up/down the library list after a 150 ms rest debounce
///   and never steals focus. Its first section row aligns with the highlighted
///   library row so the two-column selector reads as one continuous menu.
///
/// Focus contract (the hard part — see §5.3/§7):
/// - The host (`TVMainTabView`) keeps focus on the *tab* while dwell only
///   previews the panel. D-pad **down** flips `entersPanel` true and bumps
///   `focusEntryGeneration`, landing on the current-scope library row.
/// - **Up/down** rolls libraries; the flyout follows. **Right** enters the
///   flyout (first section); **left** returns to the library row.
/// - **Press** on a library row commits that scope → Browse landing.
///   **Press** on a flyout row commits the scope + that section.
/// - **Menu/Back** closes without changing anything (`onClose`).
///
/// The component itself owns no scope state; every outcome is a callback so
/// persistence and the page swap stay in the host.
struct TVCascadeSelector: View {
    let type: TVLibraryTabType
    /// Libraries of `type`, already ordered by sort order.
    let libraries: [Library]
    /// The library currently scoped for this tab (gets the `✓`, and the
    /// row focus lands here on entry).
    let currentScopeId: Int?
    /// Whether focus has entered the panel.
    let entersPanel: Bool
    /// Bumped by the host the moment focus should enter the panel — lands
    /// on the current-scope library row.
    let focusEntryGeneration: Int
    /// Commit a library scope → its Browse landing.
    let onCommitLibrary: (Library) -> Void
    /// Commit a library scope + land on a specific section (pill).
    let onCommitSection: (Library, TVLibraryPill) -> Void
    /// Warm the library landing after its row rests under focus. The host
    /// joins this same request when the scope is committed, so a deliberate
    /// menu selection can arrive with sections and artwork already cached.
    var onPreviewLibrary: (Library) -> Void = { _ in }
    /// Close without changing scope (Menu/Back, or focus left the bar).
    let onClose: () -> Void
    /// Reports whether any panel row currently holds focus, so the host can
    /// drop the tab's focused look once focus descends (§5.1).
    var onPanelFocusChanged: (Bool) -> Void = { _ in }
    /// Leave the panel for the page content — d-pad **down** past the last row
    /// of a column dismisses the menu and hands focus to the content below.
    var onExitToContent: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Highlighted row inside the panel. The cascade is one composite tvOS
    /// focus item; rows are passive labels so the native engine cannot race
    /// this internal selection.
    @State private var focus: Focus?
    /// The single real focus target for the entered cascade.
    @FocusState private var panelFocused: Bool

    /// Library row the flyout is currently anchored to. Tracks `focus`
    /// after the rest debounce so rolling the list doesn't thrash it.
    @State private var flyoutAnchorId: Int?
    /// Debounce task for the flyout follow (§5.3).
    @State private var flyoutFollowTask: Task<Void, Never>?
    @State private var lastAppliedEntryGeneration = 0
    /// Each library row's vertical center in the level-1 HStack's coordinate
    /// space. The flyout offsets to align its first section with the anchored
    /// row, so the composite highlight does not visually jump on Right.
    @State private var libraryRowCenters: [Int: CGFloat] = [:]
    /// The first flyout section row's vertical center in the flyout's own
    /// coordinate space. Measured rather than estimated so font/padding changes
    /// do not break directional focus geometry.
    @State private var flyoutFirstSectionCenter: CGFloat?

    /// Focus target inside the panel: a level-1 library row, or a level-2
    /// section row, scoped to its library so the same pill in two libraries
    /// stays distinct.
    private enum Focus: Hashable {
        case library(Int)
        case section(Int, TVLibraryPill)
    }

    private var pills: [TVLibraryPill] { TVLibraryPill.set(for: type) }

    /// A single-library tab skips the library list and shows just that
    /// library's sections (§5.3 single-level panel).
    private var isSingleLibrary: Bool { libraries.count <= 1 }

    var body: some View {
        Group {
            if isSingleLibrary, let library = libraries.first {
                singleLevelPanel(for: library)
            } else {
                twoLevelPanel
            }
        }
        // The cascade is a composite tvOS control. Rows are rendered labels in
        // both preview and entered modes; only the panel container itself is
        // focusable, and D-pad movement updates the internal highlighted row.
        .onChange(of: focusEntryGeneration) { _, generation in
            applyEntryGeneration(generation)
        }
        .onChange(of: focus) { _, newValue in handleFocusChange(newValue) }
        .onChange(of: panelFocused) { _, isFocused in handlePanelFocusedChange(isFocused) }
        .onChange(of: entersPanel) { _, entered in
            if !entered {
                panelFocused = false
                focus = nil
            }
        }
        .onAppear {
            flyoutAnchorId = currentScopeId ?? libraries.first?.id
            if entersPanel { applyEntryGeneration(focusEntryGeneration) }
        }
        .onDisappear { flyoutFollowTask?.cancel() }
        .contentShape(Rectangle())
        .focusable(entersPanel)
        .focused($panelFocused)
        .onTapGesture(perform: commitFocusedSelection)
        .onMoveCommand(perform: handleMoveCommand)
    }

    // MARK: - Two-level (multi-library)

    private var twoLevelPanel: some View {
        // The flyout's first section aligns with the highlighted library row.
        // Aligning the flyout panel's top to the library row leaves the flyout
        // header/padding between the two active rows, which reads as a visual
        // jump when Right enters the section column.
        //
        // This MUST be layout padding, not `.offset(y:)`. `.offset` is a
        // render-only transform: it moves the flyout visually but leaves its
        // focus frame at the top of the HStack. tvOS resolves directional moves
        // from layout frames, so padding keeps the visible and focus geometry
        // in the same place.
        HStack(alignment: .top, spacing: ContinuumTheme.Skyline.flyoutGap) {
            librariesPanel

            flyout
                .frame(width: ContinuumTheme.Skyline.flyoutWidth, alignment: .top)
                .opacity(flyoutAnchorId != nil ? 1 : 0)
                .padding(.top, flyoutTopPadding)
                // Animate the follow on the *discrete* anchor change, never on
                // `flyoutTopPadding` itself. `flyoutTopPadding` is derived from
                // live GeometryReader→preference measurements; animating on it
                // makes sub-pixel re-measure jitter re-arm the animation every
                // layout pass, so `AnimatorState.combine` accumulates without
                // bound and the CA transaction never commits (hard UI freeze).
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.Skyline.flyoutOpenDuration),
                    value: flyoutAnchorId
                )
        }
        .coordinateSpace(name: Self.cascadeSpace)
        .onPreferenceChange(TVCascadeLibraryRowCenterKey.self) { centers in
            // Cache every row center; the offset is derived so it updates both
            // when rows move (re-layout) and when the anchor changes.
            libraryRowCenters = centers
        }
        .onPreferenceChange(TVCascadeFlyoutFirstSectionCenterKey.self) { center in
            flyoutFirstSectionCenter = center
        }
        .fixedSize()
    }

    /// Vertical padding that aligns the first flyout section with the anchored
    /// library row. The cascade is one composite focus target; this keeps the
    /// visual highlight continuous when Right enters the section column.
    private var flyoutTopPadding: CGFloat {
        guard let anchorId = flyoutAnchorId,
              let rowCenter = libraryRowCenters[anchorId],
              let sectionCenter = flyoutFirstSectionCenter
        else { return 0 }
        return max(0, rowCenter - sectionCenter)
    }

    private static let cascadeSpace = "cascade"
    private static let flyoutSpace = "cascadeFlyout"

    private var librariesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(type.librariesHeader)

            libraryRows

            panelFooter
        }
        .padding(ContinuumTheme.Skyline.dropdownPadding)
        .frame(width: ContinuumTheme.Skyline.dropdownWidth, alignment: .leading)
        .modifier(TVSkylinePanelChrome(
            cornerRadius: ContinuumTheme.Skyline.dropdownCornerRadius
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(type.title) libraries")
    }

    @ViewBuilder
    private var libraryRows: some View {
        let rows = ForEach(libraries) { library in
            libraryRow(library)
        }

        if libraries.count > ContinuumTheme.Skyline.cascadeMaxVisibleRows {
            // Cap the visible height at the spec's 6 rows, then scroll
            // internally as the composite cascade focus rolls the list.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) { rows }
                }
                .onAppear { scrollFocusedLibrary(with: proxy) }
                .onChange(of: focus) { _, _ in scrollFocusedLibrary(with: proxy) }
            }
            .frame(maxHeight: estimatedRowHeight * CGFloat(ContinuumTheme.Skyline.cascadeMaxVisibleRows))
        } else {
            VStack(alignment: .leading, spacing: 0) { rows }
        }
    }

    @ViewBuilder
    private func libraryRow(_ library: Library) -> some View {
        let isFocused = focus == .library(library.id)
        let isCurrent = library.id == currentScopeId
        // Mixed libraries appear under both video tabs; a distinct layers
        // glyph signals "Movies & Series" so the dual listing doesn't read
        // as two different libraries.
        let label = TVCascadeLibraryRowLabel(
            title: library.name,
            systemImage: library.isMixedLibrary ? "square.stack.3d.up" : type.systemImage,
            trailingGlyph: isCurrent ? "checkmark" : "chevron.right",
            isFocused: isFocused
        )

        label
            .id(Focus.library(library.id))
            // Report this row's center in the level-1 HStack's coordinate
            // space so the flyout can align its first section row with it.
            // This survives the panel's ScrollView / nested stacks, which a
            // custom VerticalAlignment guide would not.
            .background(libraryRowCenterReporter(for: library))
            .accessibilityLabel(accessibilityLabel(for: library, isCurrent: isCurrent))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func libraryRowCenterReporter(for library: Library) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TVCascadeLibraryRowCenterKey.self,
                value: [library.id: geo.frame(in: .named(Self.cascadeSpace)).midY]
            )
        }
    }

    // MARK: - Single-level (single library)

    private func singleLevelPanel(for library: Library) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(library.name.uppercased())

            VStack(alignment: .leading, spacing: 0) {
                ForEach(pills, id: \.self) { pill in
                    sectionRow(pill, in: library)
                }
            }

            panelFooter
        }
        .padding(ContinuumTheme.Skyline.dropdownPadding)
        .frame(width: ContinuumTheme.Skyline.dropdownWidth, alignment: .leading)
        .modifier(TVSkylinePanelChrome(
            cornerRadius: ContinuumTheme.Skyline.dropdownCornerRadius
        ))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(library.name) sections")
    }

    // MARK: - Flyout (level 2)

    @ViewBuilder
    private var flyout: some View {
        if let anchorId = flyoutAnchorId,
           let library = libraries.first(where: { $0.id == anchorId }) {
            VStack(alignment: .leading, spacing: 0) {
                flyoutHeader(library.name)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pills, id: \.self) { pill in
                        sectionRow(pill, in: library)
                            .background {
                                if pill == pills.first {
                                    firstFlyoutSectionCenterReporter()
                                }
                            }
                    }
                }
            }
            .padding(ContinuumTheme.Skyline.flyoutPadding)
            .frame(width: ContinuumTheme.Skyline.flyoutWidth, alignment: .leading)
            .modifier(TVSkylinePanelChrome(
                cornerRadius: ContinuumTheme.Skyline.flyoutCornerRadius
            ))
            .fixedSize()
            .coordinateSpace(name: Self.flyoutSpace)
            // Crossfade the section list as the flyout follows focus to a
            // new library; the vertical alignment is handled by
            // `flyoutTopPadding`, so a scale here would compound with it.
            .id(anchorId)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(library.name) sections")
        }
    }

    private func firstFlyoutSectionCenterReporter() -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TVCascadeFlyoutFirstSectionCenterKey.self,
                value: geo.frame(in: .named(Self.flyoutSpace)).midY
            )
        }
    }

    @ViewBuilder
    private func sectionRow(_ pill: TVLibraryPill, in library: Library) -> some View {
        let isFocused = focus == .section(library.id, pill)
        let label = TVCascadeSectionRowLabel(
            title: pill.title,
            systemImage: pill.systemImage,
            isFocused: isFocused
        )

        label
            .accessibilityLabel("\(pill.title), section")
    }

    // MARK: - Shared chrome

    private func panelHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
            .tracking(ContinuumTheme.Skyline.dropdownHeaderSize * 0.26)
            .foregroundStyle(Color.white.opacity(0.38))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .accessibilityHidden(true)
    }

    private func flyoutHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: ContinuumTheme.Skyline.flyoutHeaderSize, design: .monospaced))
            .tracking(ContinuumTheme.Skyline.flyoutHeaderSize * 0.26)
            .foregroundStyle(Color.white.opacity(0.38))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }

    private var panelFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.continuumDivider)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            Text(footerCaption)
                .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.34))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
        .accessibilityHidden(true)
    }

    private var footerCaption: String {
        isSingleLibrary
            ? "Press opens the section · Menu closes"
            : "Press opens the library · → jumps to a section · Menu closes"
    }

    // MARK: - Focus plumbing

    private func applyEntryGeneration(_ generation: Int) {
        guard entersPanel,
              generation > 0,
              generation != lastAppliedEntryGeneration else { return }
        lastAppliedEntryGeneration = generation
        if isSingleLibrary, let library = libraries.first {
            // Single-level: land on the first section (§5.3).
            onPreviewLibrary(library)
            focus = .section(library.id, pills.first ?? .recommended)
            claimPanelFocus()
        } else {
            // Two-level: land on the current-scope row, else the first.
            let target = currentScopeId ?? libraries.first?.id
            if let target {
                focus = .library(target)
                flyoutAnchorId = target
                claimPanelFocus()
            }
        }
    }

    private func handleFocusChange(_ newValue: Focus?) {
        if newValue != nil, entersPanel {
            onPanelFocusChanged(true)
        }
        guard let newValue else { return }
        switch newValue {
        case .library(let id):
            scheduleFlyoutFollow(to: id)
        case .section(let id, _):
            // Focus is in the flyout — keep it anchored to that library and
            // cancel any pending follow so it doesn't snap away.
            flyoutFollowTask?.cancel()
            flyoutAnchorId = id
        }
    }

    private func handlePanelFocusedChange(_ isFocused: Bool) {
        onPanelFocusChanged(isFocused && focus != nil)
    }

    /// Move the flyout to a newly focused library row after a rest
    /// debounce (§5.3) so rolling the list never thrashes the flyout.
    private func scheduleFlyoutFollow(to id: Int) {
        flyoutFollowTask?.cancel()
        flyoutFollowTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: ContinuumTheme.Skyline.flyoutFollowDebounceMilliseconds * 1_000_000
            )
            guard !Task.isCancelled else { return }
            // Only follow if focus is still on this library row.
            guard focus == .library(id) else { return }
            if let library = libraries.first(where: { $0.id == id }) {
                onPreviewLibrary(library)
            }
            if flyoutAnchorId != id {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.Skyline.flyoutOpenDuration)) {
                    flyoutAnchorId = id
                }
            }
        }
    }

    private var estimatedRowHeight: CGFloat {
        ContinuumTheme.Skyline.cascadeRowTextSize
            + ContinuumTheme.Skyline.cascadeRowPaddingVertical * 2
            + 6 // row spacing slack so the 6th row isn't clipped mid-glyph
    }

    private func scrollFocusedLibrary(with proxy: ScrollViewProxy) {
        guard case .library(let libraryId) = focus else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.Skyline.flyoutOpenDuration)) {
            proxy.scrollTo(Focus.library(libraryId), anchor: .center)
        }
    }

    private func accessibilityLabel(for library: Library, isCurrent: Bool) -> String {
        var label = library.name
        if isCurrent { label += ", current library" }
        return label
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard entersPanel, panelFocused, let focus else { return }

        switch (focus, direction) {
        case (.library(let libraryId), .up):
            moveLibrary(from: libraryId, by: -1)
        case (.library(let libraryId), .down):
            moveLibrary(from: libraryId, by: 1)
        case (.library(let libraryId), .right):
            moveToSection(libraryId: libraryId, pill: pills.first ?? .recommended)
        case (.section(let libraryId, let pill), .up):
            moveSection(libraryId: libraryId, from: pill, by: -1)
        case (.section(let libraryId, let pill), .down):
            moveSection(libraryId: libraryId, from: pill, by: 1)
        case (.section(let libraryId, _), .left) where !isSingleLibrary:
            moveToLibrary(libraryId)
        default:
            break
        }
    }

    private func moveLibrary(from libraryId: Int, by delta: Int) {
        guard let index = libraries.firstIndex(where: { $0.id == libraryId }) else { return }
        let nextIndex = index + delta
        guard libraries.indices.contains(nextIndex) else {
            if delta < 0 {
                onClose()
            } else {
                onExitToContent()
            }
            return
        }
        moveToLibrary(libraries[nextIndex].id)
    }

    private func moveSection(libraryId: Int, from pill: TVLibraryPill, by delta: Int) {
        guard let index = pills.firstIndex(of: pill) else { return }
        let nextIndex = index + delta
        guard pills.indices.contains(nextIndex) else {
            if delta < 0 {
                onClose()
            } else {
                onExitToContent()
            }
            return
        }
        moveToSection(libraryId: libraryId, pill: pills[nextIndex])
    }

    private func moveToLibrary(_ libraryId: Int) {
        flyoutFollowTask?.cancel()
        flyoutAnchorId = libraryId
        onPanelFocusChanged(true)
        focus = .library(libraryId)
        claimPanelFocus()
    }

    private func moveToSection(libraryId: Int, pill: TVLibraryPill) {
        flyoutFollowTask?.cancel()
        flyoutAnchorId = libraryId
        onPanelFocusChanged(true)
        focus = .section(libraryId, pill)
        claimPanelFocus()
    }

    private func commitFocusedSelection() {
        guard entersPanel, let focus else { return }
        switch focus {
        case .library(let libraryId):
            if let library = libraries.first(where: { $0.id == libraryId }) {
                onCommitLibrary(library)
            }
        case .section(let libraryId, let pill):
            if let library = libraries.first(where: { $0.id == libraryId }) {
                onCommitSection(library, pill)
            }
        }
    }

    private func claimPanelFocus() {
        onPanelFocusChanged(true)
        panelFocused = true
        Task { @MainActor in
            await Task.yield()
            guard entersPanel, focus != nil else { return }
            panelFocused = true
        }
    }
}

// MARK: - Row labels

/// Level-1 library row (§5.3): icon — name — trailing glyph. Inverts to
/// white on focus, matching the bar/pill grammar.
private struct TVCascadeLibraryRowLabel: View {
    let title: String
    let systemImage: String
    let trailingGlyph: String
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: ContinuumTheme.Skyline.cascadeRowIconSize)

            Text(title)
                .font(.system(size: ContinuumTheme.Skyline.cascadeRowTextSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 12)

            Image(systemName: trailingGlyph)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foreground.opacity(isFocused ? 1 : 0.5))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, ContinuumTheme.Skyline.cascadeRowPaddingHorizontal)
        .padding(.vertical, ContinuumTheme.Skyline.cascadeRowPaddingVertical)
        .background(
            RoundedRectangle(cornerRadius: ContinuumTheme.Skyline.cascadeRowCornerRadius, style: .continuous)
                .fill(isFocused ? Color.white : Color.clear)
        )
        .focusEffectDisabled()
        // Reduce Motion snaps the cascade row inversion (§4.2 acceptance).
        .animation(reduceMotion ? nil : ContinuumTheme.springAnimation, value: isFocused)
    }

    private var foreground: Color {
        isFocused ? .continuumBackground : .white.opacity(0.9)
    }
}

/// Flyout / single-level section row (§5.3): icon — name, inverting to
/// white on focus.
private struct TVCascadeSectionRowLabel: View {
    let title: String
    let systemImage: String
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 26)

            Text(title)
                .font(.system(size: ContinuumTheme.Skyline.flyoutRowTextSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(isFocused ? Color.continuumBackground : .white.opacity(0.86))
        .padding(.horizontal, ContinuumTheme.Skyline.flyoutRowPaddingHorizontal)
        .padding(.vertical, ContinuumTheme.Skyline.flyoutRowPaddingVertical)
        .background(
            RoundedRectangle(cornerRadius: ContinuumTheme.Skyline.flyoutRowCornerRadius, style: .continuous)
                .fill(isFocused ? Color.white : Color.clear)
        )
        .focusEffectDisabled()
        // Reduce Motion snaps the flyout row inversion (§4.2 acceptance).
        .animation(reduceMotion ? nil : ContinuumTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Flyout focus alignment (§5.3)

/// Each library row's vertical center, keyed by library id, in the level-1
/// panel HStack's coordinate space. The flyout reads the anchored row's value
/// to align its first section with the row.
private struct TVCascadeLibraryRowCenterKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// First flyout section row center, measured in the flyout's own coordinate
/// space. This captures the flyout header/padding without hardcoding them into
/// the focus math.
private struct TVCascadeFlyoutFirstSectionCenterKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

#endif
