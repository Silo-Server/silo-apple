#if !os(tvOS)
import SwiftUI

/// Variant 1 ("In-Place Direct"): Zoom-Out Shelf Mode rendered directly inside
/// `HomeView` (or `LibraryRecommendedView`, or pushed from Settings).
///
/// Each visible row collapses into a compact glass/surface card with a live
/// 3-4 thumbnail mini-poster filmstrip pulled from the already-loaded
/// `ResolvedSection`s, row title, `Server`/`Yours` capsule pill, item count,
/// eye toggle, and native drag reorder handle.
struct IOSHomeCustomizeView: View {
    @Bindable var editor: HomeSectionsEditorModel
    let loadedSections: [ResolvedSection]
    /// Clearance for a floating host header (e.g. `HomeView`'s top bar).
    var topInset: CGFloat = 0
    /// True when presented as a standalone screen from Settings rather than
    /// embedded in-place inside Home/Library.
    var isStandaloneScreen = false
    /// Optional page title (e.g. library name) shown in the header banner.
    var pageTitle: String? = nil
    /// Optional hook awaited after this editor settles (e.g. to drain pending
    /// saves on sibling library editors in Settings before dismissing).
    var beforeDone: (() async -> Bool)? = nil
    let onDone: () -> Void

    @State private var isHiddenExpanded = false
    @State private var isShowingAddRow = false
    @State private var isShowingOptions = false
    @State private var isFinishingDone = false
    @State private var hapticCount = 0
    @State private var dragStartHaptic = 0
    @State private var preferences = HomePreferencesModel()

    private struct ShelfScrollMetrics: Equatable {
        var offsetY: CGFloat = 0
        var maxOffsetY: CGFloat = 0
        var containerHeight: CGFloat = 0
        var topContentInset: CGFloat = 0
        var bottomContentInset: CGFloat = 0
    }

    // Pure SwiftUI live drag state — lifts the actual rounded card with zero
    // UIKit List rectangular snapshot artifact, and auto-scrolls near edges.
    @State private var draggingRowId: String?
    @State private var dragAnchorContentY: CGFloat = 0
    @State private var dragFingerViewportY: CGFloat = 0
    @State private var dragOffsetY: CGFloat = 0
    @State private var measuredCardHeight: CGFloat = 68
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollMetrics = ShelfScrollMetrics()
    @State private var autoScrollTask: Task<Void, Never>?

    @Environment(\.locale) private var locale

    private let cardSpacing: CGFloat = 10

    private var sectionLookup: [String: ResolvedSection] {
        Dictionary(loadedSections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            contentBody

            floatingGlassBar
        }
        .onAppear {
            editor.seedPreviewRowsIfEmpty(from: loadedSections, locale: locale)
        }
        .onDisappear {
            stopAutoScrollLoop()
        }
        .task(id: ObjectIdentifier(editor)) {
            stopAutoScrollLoop()
            draggingRowId = nil
            dragOffsetY = 0
            isHiddenExpanded = false
            editor.seedPreviewRowsIfEmpty(from: loadedSections, locale: locale)
            async let layoutLoad = editor.load()
            async let catalogPrewarm: Void = editor.loadPickerCatalogIfNeeded(force: true)
            _ = await (layoutLoad, catalogPrewarm)
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: hapticCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: dragStartHaptic)
        #endif
        .sheet(isPresented: $isShowingAddRow) {
            IOSAddRowSheet(editor: editor, pageTitle: pageTitle)
                #if os(iOS)
                .statusColumnSheetWidth()
                #endif
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingOptions) {
            IOSHomeOptionsSheet(editor: editor, preferences: preferences)
                #if os(iOS)
                .statusColumnSheetWidth()
                #endif
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if !editor.rows.isEmpty || editor.phase == .loaded {
            shelfScrollView
        } else if case .failed(let message) = editor.phase {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(Color.siloSecondaryText)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.center)
                Button(.commonRetry) {
                    Task { await editor.load() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, topInset)
        } else {
            loadingSkeletonView
        }
    }

    private var loadingSkeletonView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: cardSpacing) {
                customizeHeaderBanner
                    .padding(.top, topInset + 4)
                    .padding(.bottom, 4)

                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                        .frame(height: 68)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, isStandaloneScreen ? 110 : 172)
        }
        .scrollDisabled(true)
    }

    private var shelfScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                customizeHeaderBanner
                    .padding(.top, topInset + 4)
                    .padding(.bottom, 12)

                if let error = editor.saveError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(verbatim: error)
                            .font(.footnote)
                            .foregroundStyle(Color.siloOnSurface)
                        Spacer(minLength: 8)
                        if editor.phase != .loaded {
                            Button(.commonRetry) {
                                Task { await editor.load() }
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.siloSurfaceVariant.opacity(0.9))
                    )
                    .padding(.bottom, 12)
                }

                let canEditRows = editor.phase == .loaded && !editor.isResetting

                // Visible shelves — pure SwiftUI live drag-to-reorder (zero black drag square)
                if editor.visibleRows.isEmpty {
                    emptyVisibleCard
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: cardSpacing) {
                        ForEach(editor.visibleRows) { row in
                            let isDragging = draggingRowId == row.id
                            ShelfStripCard(
                                row: row,
                                resolved: sectionLookup[row.id],
                                isHidden: false,
                                isDragging: isDragging,
                                showsDragHandle: canEditRows && editor.visibleRows.count > 1,
                                isInteractive: canEditRows,
                                onToggleVisibility: {
                                    guard canEditRows else { return }
                                    hapticCount += 1
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        editor.setHidden(true, id: row.id)
                                    }
                                },
                                onDragChanged: { value in
                                    handleDragChanged(value, for: row)
                                },
                                onDragEnded: {
                                    handleDragEnded()
                                },
                                onDragCancelled: {
                                    handleDragCancelled()
                                }
                            )
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                if height > 40, draggingRowId == nil {
                                    measuredCardHeight = height
                                }
                            }
                            .scaleEffect(isDragging ? 1.03 : 1.0)
                            .offset(y: isDragging ? dragOffsetY : 0)
                            .zIndex(isDragging ? 100 : 0)
                            .shadow(
                                color: Color.black.opacity(isDragging ? 0.55 : 0),
                                radius: isDragging ? 22 : 0,
                                y: isDragging ? 12 : 0
                            )
                            .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isDragging)
                            .contextMenu {
                                if canEditRows {
                                    Button {
                                        hapticCount += 1
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            editor.moveToTop(id: row.id)
                                        }
                                    } label: {
                                        Label(.homeCustomizeMoveToTop, systemImage: "arrow.up.to.line")
                                    }

                                    Button {
                                        hapticCount += 1
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            editor.moveToBottom(id: row.id)
                                        }
                                    } label: {
                                        Label(.homeCustomizeMoveToBottom, systemImage: "arrow.down.to.line")
                                    }

                                    Button {
                                        hapticCount += 1
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            editor.setHidden(true, id: row.id)
                                        }
                                    } label: {
                                        Label(.homeCustomizeHideRow, systemImage: "eye.slash")
                                    }

                                    if row.isCustom {
                                        Divider()
                                        Button(role: .destructive) {
                                            hapticCount += 1
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                                editor.removeCustomRow(id: row.id)
                                            }
                                        } label: {
                                            Label(.homeCustomizeDeleteRow, systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .animation(.spring(response: 0.26, dampingFraction: 0.84), value: editor.visibleRows.map(\.id))
                }

                // Collapsible dimmed Hidden Rows section
                if !editor.hiddenRows.isEmpty {
                    VStack(spacing: 8) {
                        Button {
                            hapticCount += 1
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                isHiddenExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "eye.slash")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.siloSecondaryText)
                                Text(.homeCustomizeHiddenRows(LocaleFormat.integer(editor.hiddenRows.count, locale: locale)))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.siloSecondaryText)
                                Spacer()
                                Image(systemName: isHiddenExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isHiddenExpanded {
                            ForEach(editor.hiddenRows) { row in
                                ShelfStripCard(
                                    row: row,
                                    resolved: sectionLookup[row.id],
                                    isHidden: true,
                                    isDragging: false,
                                    showsDragHandle: false,
                                    isInteractive: canEditRows,
                                    onToggleVisibility: {
                                        guard canEditRows else { return }
                                        hapticCount += 1
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            editor.setHidden(false, id: row.id)
                                        }
                                    }
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .onTapGesture {
                                    guard canEditRows else { return }
                                    hapticCount += 1
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        editor.setHidden(false, id: row.id)
                                    }
                                }
                                .contextMenu {
                                    if canEditRows {
                                        Button {
                                            hapticCount += 1
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                                editor.setHidden(false, id: row.id)
                                            }
                                        } label: {
                                            Label(.homeCustomizeShowRow, systemImage: "eye")
                                        }
                                        if row.isCustom {
                                            Divider()
                                            Button(role: .destructive) {
                                                hapticCount += 1
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                                    editor.removeCustomRow(id: row.id)
                                                }
                                            } label: {
                                                Label(.homeCustomizeDeleteRow, systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 18)
                }

                // Bottom breathing room for the floating glass pill bar + tab bar.
                Color.clear
                    .frame(height: isStandaloneScreen ? 110 : 172)
            }
            .padding(.horizontal, 16)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ShelfScrollMetrics.self) { geo in
            let offsetY = max(0, geo.contentOffset.y + geo.contentInsets.top)
            let maxOffsetY = max(
                0,
                geo.contentSize.height - geo.containerSize.height + geo.contentInsets.top + geo.contentInsets.bottom
            )
            return ShelfScrollMetrics(
                offsetY: offsetY,
                maxOffsetY: maxOffsetY,
                containerHeight: geo.containerSize.height,
                topContentInset: geo.contentInsets.top,
                bottomContentInset: geo.contentInsets.bottom
            )
        } action: { _, next in
            scrollMetrics = next
            if draggingRowId != nil {
                reconcileDraggedRowPosition()
            }
        }
        .coordinateSpace(name: "shelfViewportSpace")
    }

    private func handleDragChanged(_ value: DragGesture.Value, for row: APIv2ProfileSectionSetting) {
        guard editor.phase == .loaded else { return }
        if draggingRowId != row.id {
            draggingRowId = row.id
            dragAnchorContentY = value.startLocation.y + scrollMetrics.offsetY
            dragStartHaptic += 1
        }
        dragFingerViewportY = value.location.y
        reconcileDraggedRowPosition()
        startAutoScrollLoopIfNeeded()
    }

    private func reconcileDraggedRowPosition() {
        guard let rowId = draggingRowId else { return }
        let pitch = max(measuredCardHeight, 56) + cardSpacing
        let fingerContentY = dragFingerViewportY + scrollMetrics.offsetY
        var deltaY = fingerContentY - dragAnchorContentY

        while deltaY > pitch * 0.55 {
            var swapped = false
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                swapped = editor.swapVisibleDuringDrag(id: rowId, by: 1)
            }
            guard swapped else { break }
            dragAnchorContentY += pitch
            deltaY = fingerContentY - dragAnchorContentY
            hapticCount += 1
        }

        while deltaY < -pitch * 0.55 {
            var swapped = false
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                swapped = editor.swapVisibleDuringDrag(id: rowId, by: -1)
            }
            guard swapped else { break }
            dragAnchorContentY -= pitch
            deltaY = fingerContentY - dragAnchorContentY
            hapticCount += 1
        }

        dragOffsetY = deltaY
    }

    private func startAutoScrollLoopIfNeeded() {
        guard autoScrollTask == nil, draggingRowId != nil else { return }
        autoScrollTask = Task { @MainActor in
            let clock = ContinuousClock()
            var lastTick = clock.now
            while !Task.isCancelled, draggingRowId != nil {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, draggingRowId != nil else { break }
                let now = clock.now
                let elapsed = lastTick.duration(to: now)
                lastTick = now
                let dt = min(
                    max(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, 0.004),
                    0.05
                )

                let velocity = autoScrollVelocity()
                guard velocity != 0 else { continue }

                let currentY = scrollMetrics.offsetY
                let nextY = min(max(currentY + velocity * dt, 0), scrollMetrics.maxOffsetY)
                guard abs(nextY - currentY) > 0.25 else { continue }

                scrollPosition.scrollTo(y: nextY)
                scrollMetrics.offsetY = nextY
                reconcileDraggedRowPosition()
            }
            autoScrollTask = nil
        }
    }

    private func stopAutoScrollLoop() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    /// Computes vertical auto-scroll velocity (pt/sec) when the dragged handle
    /// enters the top or bottom edge zones of the viewport.
    private func autoScrollVelocity() -> CGFloat {
        guard let rowId = draggingRowId,
              scrollMetrics.containerHeight > 0,
              scrollMetrics.maxOffsetY > 0 else {
            return 0
        }

        let visible = editor.visibleRows
        guard let index = visible.firstIndex(where: { $0.id == rowId }) else { return 0 }

        let topTrigger = scrollMetrics.topContentInset + topInset + 88
        let bottomClearance: CGFloat = scrollMetrics.bottomContentInset + (isStandaloneScreen ? 110 : 145)
        let bottomTrigger = max(topTrigger + 40, scrollMetrics.containerHeight - bottomClearance)
        let minSpeed: CGFloat = 140
        let maxSpeed: CGFloat = 680

        if dragFingerViewportY < topTrigger, scrollMetrics.offsetY > 0 {
            // Stop scrolling up once the row is already first and well above its slot.
            if index == 0 && dragOffsetY < -24 { return 0 }
            let depth = min(max((topTrigger - dragFingerViewportY) / max(topTrigger, 1), 0), 1)
            let eased = depth * depth
            return -(minSpeed + (maxSpeed - minSpeed) * eased)
        }

        if dragFingerViewportY > bottomTrigger, scrollMetrics.offsetY < scrollMetrics.maxOffsetY {
            // Stop scrolling down once the row is already last and well past its slot.
            if index == visible.count - 1 && dragOffsetY > 24 { return 0 }
            let zoneHeight = max(scrollMetrics.containerHeight - bottomTrigger, 1)
            let depth = min(max((dragFingerViewportY - bottomTrigger) / zoneHeight, 0), 1)
            let eased = depth * depth
            return minSpeed + (maxSpeed - minSpeed) * eased
        }

        return 0
    }

    private func handleDragEnded() {
        stopAutoScrollLoop()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            draggingRowId = nil
            dragOffsetY = 0
        }
        editor.commitDraggedOrder()
    }

    private func handleDragCancelled() {
        stopAutoScrollLoop()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            draggingRowId = nil
            dragOffsetY = 0
        }
        editor.cancelDraggedOrder()
    }

    private var customizeHeaderBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(.homeCustomizeSubtitle)
                    .font(.caption)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer(minLength: 8)
            if editor.isSaving || editor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .padding(.vertical, 4)
    }

    private var headerTitle: String {
        if let pageTitle, !pageTitle.isEmpty {
            return AppLanguage.string(.homeCustomizeTitleNamed(pageTitle), locale: locale)
        }
        return AppLanguage.string(editor.scope == .home ? .homeCustomizeTitleHome : .homeCustomizeTitleLibrary, locale: locale)
    }

    private var emptyVisibleCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.siloSecondaryText)
            Text(editor.hiddenRows.isEmpty ? .homeCustomizeEmptyNoRowsTitle : .homeCustomizeEmptyAllHiddenTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
            Text(editor.hiddenRows.isEmpty ? .homeCustomizeEmptyNoRowsBody : .homeCustomizeEmptyAllHiddenBody)
                .font(.caption)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    /// Floating bottom glass pill bar matching iPhone's `LibraryDock` aesthetic.
    private var floatingGlassBar: some View {
        HStack(spacing: 10) {
            Button {
                hapticCount += 1
                isShowingAddRow = true
            } label: {
                Label(.homeCustomizeAddRow, systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(editor.phase != .loaded || editor.isResetting)
            .opacity(editor.phase == .loaded && !editor.isResetting ? 1 : 0.45)

            Button {
                hapticCount += 1
                isShowingOptions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(.homeCustomizeOptions)

            Button {
                guard !isFinishingDone else { return }
                hapticCount += 1
                isFinishingDone = true
                Task {
                    let settled = await editor.waitForPendingSaves()
                    let othersSettled = settled ? (await beforeDone?() ?? true) : true
                    isFinishingDone = false
                    if settled && othersSettled {
                        editor.triggerFeedRefresh()
                        onDone()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isFinishingDone {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.black)
                    }
                    Text(.commonDone)
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isFinishingDone)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .siloGlass(in: Capsule(), tint: Color.black.opacity(0.45), interactive: true)
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .padding(.bottom, isStandaloneScreen ? 20 : 28)
    }
}

// MARK: - Live Mini-Poster Filmstrip Card

private struct ShelfStripCard: View {
    private struct PreviewArtwork {
        let url: String
        let thumbhash: String?
        let hidesSpoiler: Bool
    }

    let row: APIv2ProfileSectionSetting
    let resolved: ResolvedSection?
    let isHidden: Bool
    let isDragging: Bool
    let showsDragHandle: Bool
    var isInteractive: Bool = true
    let onToggleVisibility: () -> Void
    var onDragChanged: ((DragGesture.Value) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    var onDragCancelled: (() -> Void)? = nil

    @GestureState private var isDragGestureActive = false
    @State private var dragEndedNormally = false
    @Environment(\.locale) private var locale

    private var effectiveTitle: String {
        if let resolved {
            let resolvedTitle = resolved.displayTitle(in: locale).trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolvedTitle.isEmpty {
                return resolvedTitle
            }
        }
        return row.displayTitle
    }

    private var previewArtworks: [PreviewArtwork] {
        guard let resolved else { return [] }
        if resolved.holdsCollections {
            return Array(resolved.collections.prefix(3)).compactMap { col in
                guard let url = col.posterUrl, !url.isEmpty else { return nil }
                return PreviewArtwork(url: url, thumbhash: col.posterThumbhash, hidesSpoiler: false)
            }
        }
        let spoilers = EpisodeSpoilerPreferences.shared.settings
        return Array(resolved.items.prefix(3)).compactMap { item in
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
        return AppLanguage.string(
            .collectionsItemCount(count: count, LocaleFormat.groupedCount(count, locale: locale)),
            locale: locale
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            filmstripPreview

            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: effectiveTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(row.isCustom ? .homeCustomizeBadgeYours : .accountServer)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(row.isCustom ? Color.white : Color.siloSecondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                row.isCustom
                                    ? Color.accentColor.opacity(0.32)
                                    : Color.white.opacity(0.09)
                            )
                        )

                    if let count = itemCountText {
                        Text(verbatim: count)
                            .font(.caption2)
                            .foregroundStyle(Color.siloSecondaryText)
                            .monospacedDigit()
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            Button(action: onToggleVisibility) {
                Image(systemName: isHidden ? "eye.slash" : "eye.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isHidden ? Color.siloSecondaryText : Color.white.opacity(0.88))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(Color.white.opacity(isHidden ? 0.06 : 0.12))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isInteractive)
            .accessibilityLabel(isHidden ? .homeCustomizeA11YShowRow(effectiveTitle) : .homeCustomizeA11YHideRow(effectiveTitle))

            if showsDragHandle, let onDragChanged, let onDragEnded {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isDragging ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("shelfViewportSpace"))
                            .updating($isDragGestureActive) { _, state, _ in
                                state = true
                            }
                            .onChanged { value in
                                dragEndedNormally = false
                                onDragChanged(value)
                            }
                            .onEnded { _ in
                                dragEndedNormally = true
                                onDragEnded()
                            }
                    )
                    .onChange(of: isDragGestureActive) { wasActive, active in
                        if wasActive && !active && !dragEndedNormally {
                            onDragCancelled?()
                        }
                    }
                    .accessibilityLabel(.homeCustomizeA11YReorderRow(effectiveTitle))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, showsDragHandle ? 8 : 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    isDragging
                        ? Color.siloSurfaceVariant
                        : Color.white.opacity(isHidden ? 0.035 : 0.075)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isDragging
                                ? Color.white.opacity(0.34)
                                : Color.white.opacity(isHidden ? 0.06 : 0.12),
                            lineWidth: isDragging ? 1.25 : 0.75
                        )
                )
        )
        .opacity(isHidden ? 0.62 : 1.0)
    }

    @ViewBuilder
    private var filmstripPreview: some View {
        let art = previewArtworks
        if art.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                Image(systemName: SectionRecipePresentation.symbol(for: row.sectionType))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .frame(width: 76, height: 46)
        } else {
            // 3 posters × 30pt with -8pt overlap = 74pt total inside a clipped 76pt slot,
            // keeping clear separation from the row title at every screen width.
            HStack(spacing: -8) {
                ForEach(Array(art.prefix(3).enumerated()), id: \.offset) { index, entry in
                    AsyncImageView(
                        url: entry.url,
                        thumbhash: entry.thumbhash,
                        targetSize: CGSize(width: 30, height: 44),
                        contentMode: .fill,
                        placeholderStyle: .artwork
                    )
                    .episodeSpoilerBlur(entry.hidesSpoiler)
                    .frame(width: 30, height: 44)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.65), lineWidth: 1)
                    )
                    .zIndex(Double(3 - index))
                }
            }
            .frame(width: 76, height: 46, alignment: .leading)
            .clipped()
        }
    }
}

// MARK: - Home Options Sheet

struct IOSHomeOptionsSheet: View {
    @Bindable var editor: HomeSectionsEditorModel
    @Bindable var preferences: HomePreferencesModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false
    @State private var isFinishingDone = false

    var body: some View {
        NavigationStack {
            List {
                if editor.scope == .home {
                    Section {
                        Picker(.homeCustomizeNextUpMode, selection: Binding(
                            get: { preferences.nextUpMode },
                            set: { preferences.setNextUpMode($0) }
                        )) {
                            ForEach(HomePreferencesModel.NextUpMode.allCases) { mode in
                                Text(mode.titleResource).tag(mode)
                            }
                        }
                        .disabled(isFinishingDone || !preferences.canEdit(.uiNextUpMode))

                        Toggle(isOn: Binding(
                            get: { preferences.newReleasesFirst },
                            set: { preferences.setNewReleasesFirst($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(.homeCustomizeNewReleasesFirst)
                                Text(.homeCustomizeNewReleasesFirstBody)
                                    .font(.caption)
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                        }
                        .disabled(isFinishingDone || !preferences.canEdit(.uiNextUpNewReleasesFirst))

                        Toggle(isOn: Binding(
                            get: { preferences.hideWatchedItems },
                            set: { preferences.setHideWatchedItems($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(.homeCustomizeHideWatchedItems)
                                Text(.homeCustomizeHideWatchedItemsBody)
                                    .font(.caption)
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                        }
                        .disabled(isFinishingDone || !preferences.canEdit(.homeHideWatchedItems))
                    } header: {
                        Text(.homeCustomizeSectionDisplay)
                    }

                    if let error = preferences.errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(Color.siloSecondaryText)
                                if !preferences.isAuthorized || preferences.hasReconcilingKeys {
                                    Button(.commonRetry) {
                                        Task { await preferences.load() }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        HStack {
                            Label(.homeCustomizeResetToDefault, systemImage: "arrow.counterclockwise")
                            Spacer()
                            if editor.isResetting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isFinishingDone || editor.isResetting || editor.isRefreshing || editor.phase != .loaded)
                } footer: {
                    Text(.homeCustomizeResetFooter)
                }
            }
            #if os(macOS)
            .settingsListChrome()
            #else
            .siloGroupedListStyle()
            #endif
            .navigationTitle(Text(.homeCustomizeOptionsTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isFinishingDone, !editor.isResetting else { return }
                        if editor.scope != .home {
                            dismiss()
                            return
                        }
                        isFinishingDone = true
                        Task {
                            let settled = await preferences.waitForPendingWrites()
                            isFinishingDone = false
                            if settled {
                                dismiss()
                            }
                        }
                    } label: {
                        if isFinishingDone {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(.commonDone)
                        }
                    }
                    .disabled(editor.isResetting || isFinishingDone)
                }
            }
            .interactiveDismissDisabled(editor.isResetting || isFinishingDone || (editor.scope == .home && preferences.hasPendingWrites))
            .confirmationDialog(
                Text(.homeCustomizeResetConfirmTitle),
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button(.homeCustomizeResetConfirmAction, role: .destructive) {
                    Task {
                        await editor.resetToServerDefault()
                        dismiss()
                    }
                }
                Button(.commonCancel, role: .cancel) {}
            } message: {
                Text(.homeCustomizeResetConfirmBody)
            }
        }
        .task {
            if editor.scope == .home {
                await preferences.load()
            }
        }
    }
}

// MARK: - Standalone Settings Wrapper

/// Pushed from `InterfaceCustomizationView` ("Home Screen") to open the
/// same Zoom-Out Shelf Mode experience with a Home + Library page switcher
/// so every page can be curated cleanly from Settings without leaving it.
struct IOSHomeSectionsSettingsView: View {
    @State private var selectedScope: ProfileSectionsScope = .home
    @State private var scopeSelectionGeneration = 0
    @State private var editors: [ProfileSectionsScope: HomeSectionsEditorModel] = [
        .home: HomeSectionsEditorModel(scope: .home),
    ]
    @State private var libraries: [Library] = []
    @State private var librariesError: String?
    @State private var loadedSectionsByScope: [ProfileSectionsScope: [ResolvedSection]] = [:]
    @State private var librariesLoadGeneration = 0
    @State private var artworkLoadGeneration: [ProfileSectionsScope: Int] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var activeEditor: HomeSectionsEditorModel? {
        editors[selectedScope]
    }

    private var activePageTitle: String? {
        guard case .library(let id) = selectedScope else { return nil }
        return libraries.first(where: { $0.id == id })?.name
    }

    private var activeLoadedSections: [ResolvedSection] {
        if let sections = loadedSectionsByScope[selectedScope] {
            return sections
        }
        if case .home = selectedScope {
            return (ResponseCache.shared.get(CacheKey.homeSections) as SectionsResponse?)?.sections ?? []
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !libraries.isEmpty {
                pageSwitcherBar
            } else if let librariesError {
                HStack(spacing: 10) {
                    Label(librariesError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(.commonRetry) {
                        Task { await loadLibrariesAndCurrentArtwork() }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if let editor = activeEditor {
                IOSHomeCustomizeView(
                    editor: editor,
                    loadedSections: activeLoadedSections,
                    topInset: 0,
                    isStandaloneScreen: true,
                    pageTitle: activePageTitle,
                    beforeDone: {
                        await settleOtherEditors(excluding: selectedScope)
                    },
                    onDone: { dismiss() }
                )
            }
        }
        .siloPageBackground()
        .navigationTitle(Text(.homeCustomizeHomeScreen))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadLibrariesAndCurrentArtwork()
        }
    }

    private func selectScope(_ scope: ProfileSectionsScope) {
        if editors[scope] == nil {
            editors[scope] = HomeSectionsEditorModel(scope: scope)
        }
        scopeSelectionGeneration += 1
        selectedScope = scope
        Task { await loadArtwork(for: scope) }
    }

    private func settleOtherEditors(excluding currentScope: ProfileSectionsScope) async -> Bool {
        let startScopeGen = scopeSelectionGeneration
        for (scope, otherEditor) in editors where scope != currentScope {
            let settled = await otherEditor.waitForPendingSaves(
                acknowledgeFailureIf: { scopeSelectionGeneration == startScopeGen }
            )
            if !settled {
                if scopeSelectionGeneration == startScopeGen {
                    selectedScope = scope
                }
                return false
            }
        }
        return scopeSelectionGeneration == startScopeGen
    }

    private var pageSwitcherBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pagePill(
                    title: AppLanguage.string(.tabHome, locale: locale),
                    systemImage: "house.fill",
                    isSelected: selectedScope == .home
                ) {
                    selectScope(.home)
                }

                ForEach(libraries) { library in
                    let scope = ProfileSectionsScope.library(library.id)
                    pagePill(
                        title: library.name,
                        systemImage: librarySymbol(for: library),
                        isSelected: selectedScope == scope
                    ) {
                        selectScope(scope)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func pagePill(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : Color.siloOnSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.10))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func librarySymbol(for library: Library) -> String {
        if library.isAudiobookLibrary { return "book.closed.fill" }
        if library.isSeriesLibrary { return "tv.fill" }
        return "film.stack.fill"
    }

    private func loadLibrariesAndCurrentArtwork() async {
        librariesLoadGeneration += 1
        let myGen = librariesLoadGeneration
        let startIdentity = SeekIntervalPreferences.activeRequestIdentity()
        let startToken = ResponseCache.shared.writeToken
        librariesError = nil
        async let homeArtwork: Void = loadArtwork(for: .home)
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: false)
            if !Task.isCancelled,
               librariesLoadGeneration == myGen,
               SeekIntervalPreferences.activeRequestIdentity() == startIdentity,
               !ResponseCache.shared.wasInvalidated(CacheKey.userLibraries, after: startToken) {
                libraries = response.libraries
                librariesError = nil
            }
        } catch {
            if !(error is CancellationError),
               !Task.isCancelled,
               librariesLoadGeneration == myGen,
               SeekIntervalPreferences.activeRequestIdentity() == startIdentity,
               !ResponseCache.shared.wasInvalidated(CacheKey.userLibraries, after: startToken) {
                librariesError = ErrorState(error).message
            }
        }
        await homeArtwork
    }

    private func loadArtwork(for scope: ProfileSectionsScope) async {
        if loadedSectionsByScope[scope] != nil { return }
        let myGen = (artworkLoadGeneration[scope] ?? 0) + 1
        artworkLoadGeneration[scope] = myGen
        let startIdentity = SeekIntervalPreferences.activeRequestIdentity()
        let cacheKey: String = switch scope {
        case .home: CacheKey.homeSections
        case .library(let libraryId): CacheKey.librarySections(libraryId)
        }
        for _ in 0..<2 {
            let startToken = ResponseCache.shared.writeToken
            let sections: [ResolvedSection]?
            switch scope {
            case .home:
                if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
                    sections = cached.sections
                } else {
                    sections = (try? await SiloAPI.shared.homeSections())?.response.sections
                }
            case .library(let libraryId):
                if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.librarySections(libraryId)) {
                    sections = cached.sections
                } else {
                    sections = (try? await SiloAPI.shared.librarySections(libraryId: libraryId))?.response.sections
                }
            }
            guard !Task.isCancelled,
                  artworkLoadGeneration[scope] == myGen,
                  SeekIntervalPreferences.activeRequestIdentity() == startIdentity else { return }
            guard let sections else { return }
            if !ResponseCache.shared.wasInvalidated(cacheKey, after: startToken) {
                loadedSectionsByScope[scope] = sections
                return
            }
        }
    }
}
#endif
