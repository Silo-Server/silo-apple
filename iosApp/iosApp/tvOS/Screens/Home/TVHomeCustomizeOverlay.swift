#if os(tvOS)
import SwiftUI

/// Variant 1 ("In-Place Direct") for tvOS: Skyline Grab & Slide Arrange Mode.
///
/// Built strictly as a single **Composite Focus Control** per `docs/tvos-focus.md`:
/// - One `.focusable(true)` container owns `@FocusState private var isFocused`.
/// - Rows and footer pills are 100% passive views — zero nested `Button`s or
///   per-row `.focused(...)` bindings inside the arrange list.
/// - One `.onMoveCommand`, one `.onTapGesture` (Select), one `.onPlayPauseCommand`
///   (Row Options popover), and one `.onExitCommand` (Menu/Back).
/// - When a popover (`TVActionPopoverMenu`) or modal (`TVAddRowModal`) opens,
///   the composite disables itself so native focus moves cleanly into the overlay
///   and returns immediately on close.
struct TVHomeCustomizeOverlay: View {
    @Bindable var editor: HomeSectionsEditorModel
    let loadedSections: [ResolvedSection]
    let onDone: () -> Void

    enum FooterAction: Int, CaseIterable, Hashable {
        case retry
        case addRow
        case hiddenRows
        case options
        case done
    }

    enum Target: Hashable {
        case row(String)
        case hiddenRow(String)
        case footer(FooterAction)
    }

    @FocusState private var isCompositeFocused: Bool
    @State private var highlighted: Target = .footer(.done)
    @State private var grabbedRowId: String?
    @State private var isHiddenExpanded = false
    @State private var rowOptionsRowId: String?
    @State private var isShowingOptions = false
    @State private var isShowingAddRow = false
    @State private var isFinishingDone = false
    @State private var preferences = HomePreferencesModel()
    @State private var focusClaimTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private var sectionLookup: [String: ResolvedSection] {
        Dictionary(loadedSections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var isOverlayOpen: Bool {
        rowOptionsRowId != nil || isShowingOptions || isShowingAddRow
    }

    private var grabbedRowTitle: String? {
        guard let grabbedRowId,
              let row = editor.rows.first(where: { $0.id == grabbedRowId }) else { return nil }
        if let resolved = sectionLookup[row.id] {
            let title = resolved.displayTitle(in: locale).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return row.displayTitle
    }

    private var activeFooterActions: [FooterAction] {
        if case .failed = editor.phase {
            return [.retry, .done]
        }
        if editor.hiddenRows.isEmpty {
            return [.addRow, .options, .done]
        }
        return [.addRow, .hiddenRows, .options, .done]
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Calm darkened backdrop veil so the compact poster-strip rows read
            // clearly while keeping Skyline's ambient color washes alive.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.76),
                    Color.black.opacity(0.86),
                    Color.black.opacity(0.92),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            compositeContent
                .disabled(isOverlayOpen)

            // Side-anchored Row Options popover
            if let optionsRowId = rowOptionsRowId,
               let row = editor.rows.first(where: { $0.id == optionsRowId }) {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                HStack {
                    Spacer()
                    TVActionPopoverMenu(
                        title: row.displayTitle,
                        items: rowOptionsItems(for: row),
                        onSelect: { item in
                            handleRowOptionSelect(item, row: row)
                        },
                        onClose: {
                            closeRowOptions()
                        }
                    )
                    .padding(.trailing, 96)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
            }

            // Home Options popover
            if isShowingOptions {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                HStack {
                    Spacer()
                    TVActionPopoverMenu(
                        title: "Home Options",
                        items: homeOptionsItems(),
                        onSelect: { item in
                            handleHomeOptionSelect(item)
                        },
                        onClose: {
                            closeHomeOptions()
                        }
                    )
                    .padding(.trailing, 96)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $isShowingAddRow, onDismiss: {
            reclaimCompositeFocus()
        }) {
            TVAddRowModal(editor: editor) {
                isShowingAddRow = false
            }
        }
        .task {
            async let layoutLoad = editor.load()
            async let prefsLoad: Void = preferences.load()
            _ = await (layoutLoad, prefsLoad)
            seedInitialHighlightIfNeeded()
            reclaimCompositeFocus()
        }
        .onChange(of: editor.phase) { _, phase in
            switch phase {
            case .loaded:
                seedInitialHighlightIfNeeded()
                normalizeHighlight()
                reclaimCompositeFocus()
            case .failed:
                highlighted = .footer(.retry)
                reclaimCompositeFocus()
            case .loading:
                break
            }
        }
        .onChange(of: editor.rows) { _, _ in
            normalizeHighlight()
        }
        .onDisappear {
            focusClaimTask?.cancel()
            focusClaimTask = nil
        }
    }

    // MARK: - Composite Focus Content

    private var compositeContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            compressedStatusBanner

            if let error = editor.saveError ?? preferences.errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(verbatim: error)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }

            switch editor.phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading your Home layout…")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(message)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                rowStackView
            }

            footerBar
        }
        .padding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .padding(.top, 52)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .focusable(!isOverlayOpen)
        .focused($isCompositeFocused)
        .focusEffectDisabled()
        .onMoveCommand(perform: handleMove)
        .onTapGesture(perform: handleSelect)
        .onPlayPauseCommand(perform: handlePlayPause)
        .onExitCommand(perform: handleExit)
        .background(
            TVWindowMenuPressCatcher(isActive: !isOverlayOpen, onExit: handleExit)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: - Top Compressed Banner

    private var compressedStatusBanner: some View {
        HStack(spacing: 18) {
            Image(systemName: grabbedRowId != nil ? "arrow.up.and.down.circle.fill" : "slider.horizontal.3")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(grabbedRowId != nil ? Color.white : Color.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(grabbedRowId != nil ? "Moving Row" : "Customize Home")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)

                    if let title = grabbedRowTitle {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white))
                    }
                }

                Text(
                    grabbedRowId != nil
                        ? "Up / Down to slide live · Click to place · Menu to cancel"
                        : "Click a row to pick up & slide · Play/Pause or Right for options · Menu when done"
                )
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
            }

            Spacer(minLength: 0)

            if editor.isSaving {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Saving")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .siloGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: Color.white.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    grabbedRowId != nil ? Color.white.opacity(0.55) : Color.white.opacity(0.12),
                    lineWidth: grabbedRowId != nil ? 1.5 : 1
                )
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: grabbedRowId)
    }

    // MARK: - Compact Live Poster-Strip Stack (5-6 rows visible at once)

    private var rowStackView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(editor.visibleRows.enumerated()), id: \.element.id) { index, row in
                        let isSelected = highlighted == .row(row.id)
                        let isGrabbed = grabbedRowId == row.id
                        TVArrangeRowCard(
                            row: row,
                            index: index,
                            totalVisible: editor.visibleRows.count,
                            resolved: sectionLookup[row.id],
                            isHighlighted: isSelected,
                            isGrabbed: isGrabbed,
                            isHidden: false
                        )
                        .id(Target.row(row.id))
                    }

                    if isHiddenExpanded && !editor.hiddenRows.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 18, weight: .semibold))
                            Text("HIDDEN ROWS (\(editor.hiddenRows.count)) · CLICK TO SHOW")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                        }
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.top, 14)
                        .padding(.leading, 10)

                        ForEach(editor.hiddenRows) { row in
                            TVArrangeRowCard(
                                row: row,
                                index: nil,
                                totalVisible: editor.visibleRows.count,
                                resolved: sectionLookup[row.id],
                                isHighlighted: highlighted == .hiddenRow(row.id),
                                isGrabbed: false,
                                isHidden: true
                            )
                            .id(Target.hiddenRow(row.id))
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .onChange(of: highlighted) { _, target in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: editor.visibleRows.map(\.id)) { _, _ in
                if let grabbedRowId {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85)) {
                        proxy.scrollTo(Target.row(grabbedRowId), anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Glass Action Pills

    private var footerBar: some View {
        HStack(spacing: 18) {
            ForEach(activeFooterActions, id: \.self) { action in
                let isSelected = highlighted == .footer(action)
                HStack(spacing: 10) {
                    Image(systemName: footerIcon(for: action))
                        .font(.system(size: 20, weight: .semibold))
                    Text(footerTitle(for: action))
                        .font(.system(size: 22, weight: .semibold))
                }
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 26)
                .padding(.vertical, 15)
                .background(
                    Capsule().fill(
                        isSelected
                            ? Color.white
                            : (action == .done ? Color.white.opacity(0.18) : Color.white.opacity(0.10))
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.white : Color.white.opacity(0.16),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
                .scaleEffect(isSelected ? 1.04 : 1.0)
                .animation(reduceMotion ? nil : SiloTheme.springAnimation, value: isSelected)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .opacity(grabbedRowId == nil ? 1.0 : 0.35)
    }

    private func footerTitle(for action: FooterAction) -> String {
        switch action {
        case .retry: return AppLanguage.string(.commonRetry, locale: locale)
        case .addRow: return "Add Row"
        case .hiddenRows:
            return isHiddenExpanded
                ? "Hide Hidden (\(editor.hiddenRows.count))"
                : "Hidden Rows (\(editor.hiddenRows.count))"
        case .options: return "Home Options"
        case .done: return "Done"
        }
    }

    private func footerIcon(for action: FooterAction) -> String {
        switch action {
        case .retry: return "arrow.clockwise"
        case .addRow: return "plus"
        case .hiddenRows: return isHiddenExpanded ? "eye.slash.fill" : "eye.slash"
        case .options: return "ellipsis.circle"
        case .done: return "checkmark"
        }
    }

    // MARK: - Composite Remote Input Handlers

    private var verticalTargets: [Target] {
        var targets = editor.visibleRows.map { Target.row($0.id) }
        if isHiddenExpanded {
            targets.append(contentsOf: editor.hiddenRows.map { Target.hiddenRow($0.id) })
        }
        return targets
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        guard !isOverlayOpen, !isFinishingDone else { return }

        // Grabbed state: Up / Down slides the grabbed row in the draft without saving per step.
        if let grabbedId = grabbedRowId {
            guard !editor.isResetting else { return }
            switch direction {
            case .up:
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
                    _ = editor.swapVisibleDuringDrag(id: grabbedId, by: -1)
                }
            case .down:
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
                    _ = editor.swapVisibleDuringDrag(id: grabbedId, by: 1)
                }
            case .left, .right:
                break
            @unknown default:
                break
            }
            return
        }

        let list = verticalTargets

        switch direction {
        case .up:
            switch highlighted {
            case .footer:
                if let last = list.last {
                    highlighted = last
                }
            case .row, .hiddenRow:
                if let idx = list.firstIndex(of: highlighted), idx > 0 {
                    highlighted = list[idx - 1]
                }
            }

        case .down:
            switch highlighted {
            case .footer:
                break
            case .row, .hiddenRow:
                if let idx = list.firstIndex(of: highlighted), idx + 1 < list.count {
                    highlighted = list[idx + 1]
                } else {
                    highlighted = .footer(activeFooterActions.first ?? .done)
                }
            }

        case .left:
            if case .footer(let current) = highlighted,
               let idx = activeFooterActions.firstIndex(of: current),
               idx > 0 {
                highlighted = .footer(activeFooterActions[idx - 1])
            }

        case .right:
            switch highlighted {
            case .footer(let current):
                if let idx = activeFooterActions.firstIndex(of: current),
                   idx + 1 < activeFooterActions.count {
                    highlighted = .footer(activeFooterActions[idx + 1])
                }
            case .row(let id), .hiddenRow(let id):
                openRowOptions(for: id)
            }

        @unknown default:
            break
        }
    }

    private func handleSelect() {
        guard !isOverlayOpen, !isFinishingDone else { return }

        if let grabbedId = grabbedRowId {
            // Drop row in place and persist the final reordered draft once.
            editor.commitDraggedOrder()
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
                grabbedRowId = nil
                highlighted = .row(grabbedId)
            }
            return
        }

        switch highlighted {
        case .row(let id):
            guard editor.phase == .loaded, !editor.isResetting else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                grabbedRowId = id
            }
        case .hiddenRow(let id):
            guard editor.phase == .loaded, !editor.isResetting else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) {
                editor.setHidden(false, id: id)
                highlighted = .row(id)
            }
        case .footer(let action):
            switch action {
            case .retry:
                guard !editor.isRefreshing else { return }
                Task { await editor.load() }
            case .addRow:
                guard editor.phase == .loaded, !editor.isResetting else { return }
                isShowingAddRow = true
            case .hiddenRows:
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isHiddenExpanded.toggle()
                }
                if isHiddenExpanded, let firstHidden = editor.hiddenRows.first {
                    highlighted = .hiddenRow(firstHidden.id)
                }
            case .options:
                guard !editor.isResetting else { return }
                isShowingOptions = true
            case .done:
                finishAndClose()
            }
        }
    }

    private func finishAndClose() {
        guard !editor.isResetting, !isFinishingDone else { return }
        isFinishingDone = true
        Task {
            let rowsSettled = await editor.waitForPendingSaves()
            let prefsSettled = editor.scope == .home ? await preferences.waitForPendingWrites() : true
            isFinishingDone = false
            if rowsSettled && prefsSettled {
                editor.triggerFeedRefresh()
                onDone()
            }
        }
    }

    private func handlePlayPause() {
        guard !isOverlayOpen, !isFinishingDone, grabbedRowId == nil, editor.phase == .loaded, !editor.isResetting else { return }
        switch highlighted {
        case .row(let id), .hiddenRow(let id):
            openRowOptions(for: id)
        case .footer:
            break
        }
    }

    private func handleExit() {
        guard !isOverlayOpen, !isFinishingDone else { return }
        if grabbedRowId != nil {
            withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84)) {
                editor.cancelDraggedOrder()
                grabbedRowId = nil
            }
            return
        }
        finishAndClose()
    }

    // MARK: - Row Options Popover

    private func openRowOptions(for rowId: String) {
        rowOptionsRowId = rowId
    }

    private func closeRowOptions() {
        rowOptionsRowId = nil
        reclaimCompositeFocus()
    }

    private func rowOptionsItems(for row: APIv2ProfileSectionSetting) -> [TVActionPopoverItem] {
        var items: [TVActionPopoverItem] = [
            TVActionPopoverItem(
                id: "toggle-visibility",
                title: row.hidden ? "Show Row" : "Hide Row",
                systemImage: row.hidden ? "eye" : "eye.slash"
            ),
        ]
        if !row.hidden {
            items.append(TVActionPopoverItem(
                id: "move-top",
                title: "Move to Top",
                systemImage: "arrow.up.to.line",
                isEnabled: editor.visibleRows.first?.id != row.id
            ))
            items.append(TVActionPopoverItem(
                id: "move-bottom",
                title: "Move to Bottom",
                systemImage: "arrow.down.to.line",
                isEnabled: editor.visibleRows.last?.id != row.id
            ))
        }
        if row.isCustom {
            items.append(TVActionPopoverItem(
                id: "remove",
                title: "Remove Row",
                systemImage: "trash",
                startsSection: true
            ))
        }
        return items
    }

    private func handleRowOptionSelect(_ item: TVActionPopoverItem, row: APIv2ProfileSectionSetting) {
        switch item.id {
        case "toggle-visibility":
            let nextHidden = !row.hidden
            editor.setHidden(nextHidden, id: row.id)
            if nextHidden {
                if let nextRow = editor.visibleRows.first(where: { $0.id != row.id }) {
                    highlighted = .row(nextRow.id)
                } else {
                    highlighted = .footer(.done)
                }
            } else {
                highlighted = .row(row.id)
            }
        case "move-top":
            editor.moveToTop(id: row.id)
            highlighted = .row(row.id)
        case "move-bottom":
            editor.moveToBottom(id: row.id)
            highlighted = .row(row.id)
        case "remove":
            editor.removeCustomRow(id: row.id)
            if let first = editor.visibleRows.first(where: { $0.id != row.id }) {
                highlighted = .row(first.id)
            } else {
                highlighted = .footer(.done)
            }
        default:
            break
        }
        closeRowOptions()
    }

    // MARK: - Home Options Popover

    private func closeHomeOptions() {
        isShowingOptions = false
        reclaimCompositeFocus()
    }

    private func homeOptionsItems() -> [TVActionPopoverItem] {
        var items: [TVActionPopoverItem] = []
        if editor.scope == .home {
            items.append(TVActionPopoverItem(
                id: "next-up-mode",
                title: "Next Up Mode",
                detail: preferences.nextUpMode.title,
                systemImage: "forward.end.fill",
                isEnabled: preferences.canEdit(.uiNextUpMode),
                children: HomePreferencesModel.NextUpMode.allCases.map { mode in
                    TVActionPopoverItem(
                        id: "nextup:\(mode.rawValue)",
                        title: mode.title,
                        detail: mode.subtitle,
                        isSelected: preferences.nextUpMode == mode,
                        isEnabled: preferences.canEdit(.uiNextUpMode)
                    )
                }
            ))
            items.append(TVActionPopoverItem(
                id: "new-releases-first",
                title: "New Releases First",
                detail: preferences.newReleasesFirst ? "On" : "Off",
                systemImage: "sparkles",
                isSelected: preferences.newReleasesFirst,
                isEnabled: preferences.canEdit(.uiNextUpNewReleasesFirst)
            ))
            items.append(TVActionPopoverItem(
                id: "hide-watched",
                title: "Hide Watched Items",
                detail: preferences.hideWatchedItems ? "On" : "Off",
                systemImage: "eye.slash",
                isSelected: preferences.hideWatchedItems,
                isEnabled: preferences.canEdit(.homeHideWatchedItems)
            ))
        }
        items.append(TVActionPopoverItem(
            id: "reset-submenu",
            title: "Reset to Server Default",
            detail: "Restore default rows and order",
            systemImage: "arrow.counterclockwise",
            isEnabled: !editor.isResetting,
            startsSection: !items.isEmpty,
            children: [
                TVActionPopoverItem(
                    id: "confirm-reset",
                    title: "Confirm Reset Layout",
                    detail: "Removes custom order and added rows",
                    systemImage: "trash",
                    isEnabled: !editor.isResetting
                ),
            ]
        ))
        return items
    }

    private func handleHomeOptionSelect(_ item: TVActionPopoverItem) {
        if item.id.hasPrefix("nextup:"),
           let mode = HomePreferencesModel.NextUpMode(rawValue: String(item.id.dropFirst(7))) {
            preferences.setNextUpMode(mode)
            closeHomeOptions()
        } else if item.id == "new-releases-first" {
            preferences.setNewReleasesFirst(!preferences.newReleasesFirst)
        } else if item.id == "hide-watched" {
            preferences.setHideWatchedItems(!preferences.hideWatchedItems)
        } else if item.id == "confirm-reset" {
            closeHomeOptions()
            Task { await editor.resetToServerDefault() }
        }
    }

    // MARK: - Focus Helpers

    private func seedInitialHighlightIfNeeded() {
        if let first = editor.visibleRows.first {
            if case .footer = highlighted {
                highlighted = .row(first.id)
            }
        }
    }

    private func normalizeHighlight() {
        switch highlighted {
        case .row(let id):
            if !editor.visibleRows.contains(where: { $0.id == id }) {
                if let first = editor.visibleRows.first {
                    highlighted = .row(first.id)
                } else {
                    highlighted = .footer(.done)
                }
            }
        case .hiddenRow(let id):
            if !editor.hiddenRows.contains(where: { $0.id == id }) {
                if let firstHidden = editor.hiddenRows.first, isHiddenExpanded {
                    highlighted = .hiddenRow(firstHidden.id)
                } else if let first = editor.visibleRows.first {
                    highlighted = .row(first.id)
                } else {
                    highlighted = .footer(.done)
                }
            }
        case .footer(let action):
            if !activeFooterActions.contains(action) {
                highlighted = .footer(.done)
            }
        }
    }

    private func reclaimCompositeFocus() {
        focusClaimTask?.cancel()
        focusClaimTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, !isOverlayOpen else { return }
            isCompositeFocused = true
        }
    }
}

// MARK: - Passive tvOS Arrange Row Card

private struct TVArrangeRowCard: View {
    let row: APIv2ProfileSectionSetting
    let index: Int?
    let totalVisible: Int
    let resolved: ResolvedSection?
    let isHighlighted: Bool
    let isGrabbed: Bool
    let isHidden: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private var effectiveTitle: String {
        if let resolved {
            let title = resolved.displayTitle(in: locale).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return row.displayTitle
    }

    private struct PreviewArtwork {
        let url: String
        let thumbhash: String?
        let hidesSpoiler: Bool
    }

    private var previewArtworks: [PreviewArtwork] {
        guard let resolved else { return [] }
        if resolved.holdsCollections {
            return Array(resolved.collections.prefix(4)).compactMap { col in
                guard let url = col.posterUrl, !url.isEmpty else { return nil }
                return PreviewArtwork(url: url, thumbhash: col.posterThumbhash, hidesSpoiler: false)
            }
        }
        let spoilers = EpisodeSpoilerPreferences.shared.settings
        return Array(resolved.items.prefix(4)).compactMap { item in
            let watchState = EpisodeWatchState(sectionItem: item)
            if let poster = item.posterUrl, !poster.isEmpty {
                let hides = item.isEpisodeItem && spoilers.hidesImage(for: watchState, isEpisodeStill: item.posterIsEpisodeStill)
                return PreviewArtwork(
                    url: poster,
                    thumbhash: hides ? nil : item.posterThumbhash,
                    hidesSpoiler: hides
                )
            }
            if let backdrop = item.backdropUrl, !backdrop.isEmpty {
                let hides = item.isEpisodeItem && spoilers.hidesImage(for: watchState, isEpisodeStill: item.backdropIsEpisodeStill)
                return PreviewArtwork(
                    url: backdrop,
                    thumbhash: hides ? nil : item.backdropThumbhash,
                    hidesSpoiler: hides
                )
            }
            return nil
        }
    }

    private var itemCountText: String? {
        guard let resolved else { return nil }
        let count = resolved.holdsCollections
            ? resolved.collections.count
            : (resolved.totalCount ?? resolved.items.count)
        guard count > 0 else { return nil }
        return count == 1 ? "1 item" : "\(count) items"
    }

    var body: some View {
        HStack(spacing: 22) {
            // Grab / position indicator
            Group {
                if isGrabbed {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.up")
                            .opacity((index ?? 0) > 0 ? 1 : 0.25)
                        Image(systemName: "chevron.down")
                            .opacity((index ?? 0) + 1 < totalVisible ? 1 : 0.25)
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                } else {
                    Image(systemName: isHidden ? "eye.slash" : "line.3.horizontal")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isHighlighted ? Color.black.opacity(0.8) : Color.white.opacity(0.45))
                }
            }
            .frame(width: 34)

            // Live 3-4 mini-poster filmstrip
            filmstrip

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(effectiveTitle)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)

                    Text(row.isCustom ? "Yours" : "Server")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(badgeTextColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(badgeFillColor))

                    if let count = itemCountText {
                        Text(count)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(secondaryTextColor)
                            .monospacedDigit()
                    }
                }

                if isGrabbed {
                    Text("Moving — Up/Down to slide, Click to place")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.75))
                }
            }

            Spacer(minLength: 16)

            // Visibility + affordance cue
            HStack(spacing: 12) {
                if isGrabbed {
                    Label("Moving", systemImage: "arrow.up.and.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                } else if isHighlighted {
                    Text(isHidden ? "Click to show" : "Click to move · ⏯ Options")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.65))
                }

                Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.black.opacity(0.8) : Color.white.opacity(isHidden ? 0.35 : 0.75))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isGrabbed ? 3.5 : (isHighlighted ? 2 : 1))
        )
        .shadow(
            color: isGrabbed ? Color.white.opacity(0.28) : (isHighlighted ? Color.black.opacity(0.4) : .clear),
            radius: isGrabbed ? 24 : 14,
            y: isGrabbed ? 10 : 6
        )
        .scaleEffect(isGrabbed ? 1.022 : (isHighlighted ? 1.008 : 1.0))
        .opacity(isHidden && !isHighlighted ? 0.55 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84), value: isHighlighted)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84), value: isGrabbed)
    }

    @ViewBuilder
    private var filmstrip: some View {
        let art = previewArtworks
        if art.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHighlighted ? Color.black.opacity(0.10) : Color.white.opacity(0.10))
                Image(systemName: SectionRecipePresentation.symbol(for: row.sectionType))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.black.opacity(0.8) : Color.white.opacity(0.8))
            }
            .frame(width: 194, height: 68)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(art.prefix(4).enumerated()), id: \.offset) { _, entry in
                    AsyncImageView(
                        url: entry.url,
                        thumbhash: entry.thumbhash,
                        targetSize: CGSize(width: 44, height: 66),
                        contentMode: .fill,
                        placeholderStyle: .artwork
                    )
                    .episodeSpoilerBlur(entry.hidesSpoiler)
                    .frame(width: 44, height: 66)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
                }
            }
            .frame(width: 194, height: 68, alignment: .leading)
            .clipped()
        }
    }

    private var cardBackgroundColor: Color {
        if isGrabbed { return Color.white }
        if isHighlighted { return Color.white.opacity(0.95) }
        return Color.white.opacity(isHidden ? 0.04 : 0.08)
    }

    private var borderColor: Color {
        if isGrabbed { return Color.white }
        if isHighlighted { return Color.white }
        return Color.white.opacity(0.10)
    }

    private var primaryTextColor: Color {
        (isHighlighted || isGrabbed) ? Color.black : Color.white
    }

    private var secondaryTextColor: Color {
        (isHighlighted || isGrabbed) ? Color.black.opacity(0.62) : Color.white.opacity(0.58)
    }

    private var badgeTextColor: Color {
        if isHighlighted || isGrabbed {
            return row.isCustom ? .white : Color.black.opacity(0.75)
        }
        return row.isCustom ? .white : Color.white.opacity(0.7)
    }

    private var badgeFillColor: Color {
        if isHighlighted || isGrabbed {
            return row.isCustom ? Color.accentColor : Color.black.opacity(0.10)
        }
        return row.isCustom ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.12)
    }
}

// MARK: - tvOS Skyline-Native Visual Add Row Picker

struct TVAddRowModal: View {
    @Bindable var editor: HomeSectionsEditorModel
    let onClose: () -> Void

    enum SourceTab: String, CaseIterable, Identifiable {
        case recipes = "Recipes"
        case myCollections = "My Collections"
        case serverCollections = "Server Collections"
        var id: String { rawValue }
    }

    @State private var selectedTab: SourceTab = .recipes
    @State private var addedKeys = Set<String>()
    @FocusState private var focusedTab: SourceTab?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Row to Home")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Pick a recipe or collection to pin directly onto your Home screen.")
                        .font(.system(size: 21))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
            }

            if let error = editor.saveError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(verbatim: error)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }

            // Source selector pills (native focus section)
            HStack(spacing: 16) {
                ForEach(SourceTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTab, equals: tab)
                }
            }
            .focusSection()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    switch selectedTab {
                    case .recipes:
                        recipesGrid
                    case .myCollections:
                        myCollectionsGrid
                    case .serverCollections:
                        serverCollectionsGrid
                    }
                }
                .padding(.vertical, 8)
            }
            .focusSection()
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.siloBackground.ignoresSafeArea())
        .onExitCommand(perform: onClose)
        .task {
            await editor.loadPickerCatalogIfNeeded(force: true)
            focusedTab = .recipes
        }
    }

    @ViewBuilder
    private var recipesGrid: some View {
        let groupedOrder = ["Keep Watching", "What's New", "Popular", "For You", "Moods & Discovery"]
        let mergedByTitle: [String: [(APIv2RecipeDefinition, APIv2RecipePreset)]] = {
            var buckets: [String: [(APIv2RecipeDefinition, APIv2RecipePreset)]] = [:]
            var seenPresets = Set<String>()
            for cat in editor.recipeCatalog.categories {
                let title = SectionRecipePresentation.categoryTitle(for: cat.category)
                for def in cat.recipes where !def.adminOnly && def.type != "collection" && def.type != "collection_posters" && def.type != "custom_filter" && def.type != "next_up" {
                    for preset in def.presets where seenPresets.insert(preset.key).inserted {
                        buckets[title, default: []].append((def, preset))
                    }
                }
            }
            return buckets
        }()
        let orderedTitles = groupedOrder.filter { mergedByTitle[$0]?.isEmpty == false }
            + mergedByTitle.keys.filter { !groupedOrder.contains($0) }.sorted()
        let groups: [(String, [(APIv2RecipeDefinition, APIv2RecipePreset)])] = orderedTitles.compactMap { title in
            guard let entries = mergedByTitle[title], !entries.isEmpty else { return nil }
            return (title, entries)
        }
        let columns = [GridItem(.adaptive(minimum: 420), spacing: 24)]

        ForEach(groups, id: \.0) { categoryTitle, entries in
            VStack(alignment: .leading, spacing: 14) {
                Text(categoryTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(entries, id: \.1.key) { def, preset in
                        let isAdded = editor.isRecipePresent(sectionType: def.type, params: preset.defaultParams)
                            || addedKeys.contains(preset.key)
                        Button {
                            guard !isAdded else { return }
                            let key = preset.key
                            addedKeys.insert(key)
                            let task = editor.addRecipeRow(
                                sectionType: def.type,
                                title: preset.displayName,
                                config: preset.defaultParams
                            )
                            Task {
                                await task.value
                                if !editor.isRecipePresent(sectionType: def.type, params: preset.defaultParams) {
                                    addedKeys.remove(key)
                                }
                            }
                        } label: {
                            HStack(spacing: 18) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.12))
                                    Image(systemName: SectionRecipePresentation.symbol(for: def.type))
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 60, height: 60)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.displayName)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    if !preset.descriptionShort.isEmpty {
                                        Text(preset.descriptionShort)
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white.opacity(0.65))
                                            .lineLimit(2)
                                    }
                                }

                                Spacer(minLength: 8)

                                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(isAdded ? Color.green : Color.white)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var myCollectionsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 420), spacing: 24)]
        if let error = editor.personalCollectionsError, editor.personalCollections.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: error)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.75))
                Button(.commonRetry) {
                    Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        } else if editor.personalCollections.isEmpty {
            Text("No personal collections yet.")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 40)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(editor.personalCollections) { collection in
                    let isAdded = editor.isCollectionPresent(collectionId: collection.id, isUserCollection: true)
                        || addedKeys.contains("user:\(collection.id)")
                    collectionCard(
                        title: collection.name,
                        subtitle: collection.itemCount.map {
                            AppLanguage.string(.collectionsItemCount(count: $0, LocaleFormat.groupedCount($0, locale: locale)), locale: locale)
                        },
                        posterUrl: collection.posterUrl,
                        posterThumbhash: collection.posterThumbhash,
                        isAdded: isAdded
                    ) {
                        guard !isAdded else { return }
                        let key = "user:\(collection.id)"
                        addedKeys.insert(key)
                        let task = editor.addCollectionRow(
                            collectionId: collection.id,
                            title: collection.name,
                            isUserCollection: true
                        )
                        Task {
                            await task.value
                            if !editor.isCollectionPresent(collectionId: collection.id, isUserCollection: true) {
                                addedKeys.remove(key)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var serverCollectionsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 420), spacing: 24)]
        if let error = editor.serverCollectionsError, editor.serverCollections.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: error)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.75))
                Button(.commonRetry) {
                    Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        } else if editor.serverCollections.isEmpty {
            Text(editor.isLoadingPickerCatalog ? "Loading server collections…" : "No server collections found.")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if let error = editor.serverCollectionsError {
                    HStack(spacing: 16) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Button(.commonRetry) {
                            Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(editor.serverCollections) { collection in
                        let key = "\(collection.isUserCollection ? "user" : "lib"):\(collection.id)"
                        let isAdded = editor.isCollectionPresent(collectionId: collection.id, isUserCollection: collection.isUserCollection)
                            || addedKeys.contains(key)
                        collectionCard(
                            title: collection.title,
                            subtitle: collection.itemCount > 0
                                ? "\(collection.libraryName) · \(AppLanguage.string(.collectionsItemCount(count: collection.itemCount, LocaleFormat.groupedCount(collection.itemCount, locale: locale)), locale: locale))"
                                : collection.libraryName,
                            posterUrl: collection.posterUrl,
                            posterThumbhash: collection.posterThumbhash,
                            isAdded: isAdded
                        ) {
                            guard !isAdded else { return }
                            addedKeys.insert(key)
                            let task = editor.addCollectionRow(
                                collectionId: collection.id,
                                title: collection.title,
                                isUserCollection: collection.isUserCollection
                            )
                            Task {
                                await task.value
                                if !editor.isCollectionPresent(collectionId: collection.id, isUserCollection: collection.isUserCollection) {
                                    addedKeys.remove(key)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func collectionCard(
        title: String,
        subtitle: String?,
        posterUrl: String?,
        posterThumbhash: String?,
        isAdded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                if let posterUrl, !posterUrl.isEmpty {
                    AsyncImageView(
                        url: posterUrl,
                        thumbhash: posterThumbhash,
                        targetSize: CGSize(width: 48, height: 72),
                        contentMode: .fill,
                        placeholderStyle: .artwork
                    )
                    .frame(width: 48, height: 72)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(width: 48, height: 72)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isAdded ? Color.green : Color.white)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.card)
    }
}

// MARK: - Standalone tvOS Settings Sheet Wrapper

struct TVHomeSectionsSettingsSheet: View {
    @State private var editor = HomeSectionsEditorModel(scope: .home)
    let onDismiss: () -> Void

    private var cachedHomeSections: [ResolvedSection] {
        (ResponseCache.shared.get(CacheKey.homeSections) as SectionsResponse?)?.sections ?? []
    }

    var body: some View {
        TVHomeCustomizeOverlay(
            editor: editor,
            loadedSections: cachedHomeSections,
            onDone: onDismiss
        )
    }
}
#endif
