#if os(tvOS)
import SwiftUI

/// Which rows a `TVRequestsPage` shows.
enum TVRequestsPageMode {
    /// The top-bar Requests tab: approvals (admins), the user's requests,
    /// then the discover carousels.
    case hub
    /// The user's requests grouped In progress / Needs you / Available.
    case mine
    /// Everyone's requests awaiting a decision, and failed ones.
    case approvals
}

/// The Requests page in the Skyline layout Home and the library tabs use:
/// an ambient backdrop and a passive focus marquee that preview the focused
/// card — including its request status and stage track — over native
/// vertically scrolling rows in the bottom band.
///
/// Focus follows `docs/tvos-focus.md`: the focus engine owns movement
/// through stable card buttons; the page's `@FocusState` only seeds entry
/// and restores the last card, and the sole directional interception is Up
/// from the first row to the top bar.
struct TVRequestsPage: View {
    let mode: TVRequestsPageMode
    /// Shell hand-down token: claims the first card on tab entry.
    var focusRequest: Int = 0
    var isTopMenuFocused: Bool = false
    /// Up from the first row. Nil on pushed pages, which have no top bar.
    var onTopMenuFocusRequest: (() -> Void)? = nil

    /// The page reads the approval queue itself, so the hub doesn't count it.
    @State private var hub = RequestsHubViewModel(countsPendingApprovals: false)
    @State private var mine = MyRequestsViewModel()
    @State private var approvals = RequestApprovalsViewModel()
    @State private var marquee = TVFocusMarqueeModel()
    @State private var hasLoaded = false
    @FocusState private var focusedKey: String?
    /// Last focused card, restored when the page returns from a detail push.
    @State private var lastFocusedKey: String?
    @State private var pendingEntryRequest: Int?
    @State private var appliedEntryRequest = 0
    @State private var pendingDecline: MediaRequest?
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if rows.isEmpty {
                placeholder
            } else {
                feed
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            guard let update else { return }
            // Only the model this page shows; the others stay unread.
            switch mode {
            case .hub: hub.applyRequestUpdate(update)
            case .mine: mine.applyRequestUpdate(update)
            case .approvals: break
            }
        }
        .onChange(of: RequestsEventBus.shared.lastModeration) { _, record in
            guard let record else { return }
            approvals.applyModeration(record)
        }
        .onChange(of: RequestsFeatureStore.shared.canModerate) { _, canModerate in
            // Moderation can be confirmed after the page's first load.
            guard canModerate, hasLoaded, mode != .mine else { return }
            Task { await approvals.load() }
        }
        .overlay(alignment: .bottomLeading) {
            if let message = actionMessage {
                Text(message)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.siloGlassStrong))
                    .padding(.leading, SiloTheme.Skyline.safeAreaX)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: rows.map(\.id)) { _, _ in
            seedMarquee()
            if let pending = pendingEntryRequest { requestEntryFocus(pending) }
        }
        .alert(
            "Decline this request?",
            isPresented: Binding(get: { pendingDecline != nil }, set: { if !$0 { pendingDecline = nil } }),
            presenting: pendingDecline
        ) { request in
            Button("Decline", role: .destructive) {
                Task { await approvals.perform(.decline, on: request) }
            }
            Button("Keep", role: .cancel) {}
        } message: { request in
            Text("\(request.title) will show as declined to the person who asked for it.")
        }
    }

    // MARK: - Placeholder states

    @ViewBuilder
    private var placeholder: some View {
        if !hasLoaded {
            TVRequestsLoadingView()
                .tvPageFocusOwner(
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: "Loading requests",
                    onMoveUp: onTopMenuFocusRequest
                )
        } else if let error = loadError {
            ErrorView(state: error, onRetry: { Task { await retry() } })
                // Boundary only: Up from the error reaches the top bar.
                .onMoveCommand { direction in
                    if direction == .up { onTopMenuFocusRequest?() }
                }
        } else {
            EmptyStateView(icon: emptyIcon, title: emptyTitle, subtitle: emptySubtitle)
                .tvPageFocusOwner(
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: emptyTitle,
                    onMoveUp: onTopMenuFocusRequest
                )
        }
    }

    private var loadError: ErrorState? {
        switch mode {
        case .hub: hub.error
        case .mine: mine.error
        case .approvals: approvals.error
        }
    }

    /// A failed action's message (cancel, approve, decline, retry).
    private var actionMessage: String? {
        approvals.actionErrorMessage ?? mine.actionErrorMessage
    }

    private var emptyIcon: String {
        mode == .approvals ? "checkmark.circle" : "tray"
    }

    private var emptyTitle: String {
        switch mode {
        case .hub: "Nothing here yet"
        case .mine: "No requests yet"
        case .approvals: "Nothing waiting on you"
        }
    }

    private var emptySubtitle: String {
        switch mode {
        case .hub: "Use Search to find a movie or series to request"
        case .mine: "Movies and series you request will show up here"
        case .approvals: "New requests that need approval will show up here"
        }
    }

    // MARK: - Rows

    /// Rows appear together once every read for the page has answered, so
    /// the first row never changes under a focused card.
    private var rows: [TVRequestRow] {
        guard hasLoaded else { return [] }
        switch mode {
        case .hub:
            var rows: [TVRequestRow] = []
            if RequestsFeatureStore.shared.canModerate, !approvals.awaitingApproval.isEmpty {
                rows.append(TVRequestRow(
                    id: "approvals",
                    title: "Waiting for your approval",
                    items: approvals.awaitingApproval.map { .approval($0) }
                ))
            }
            if !hub.myRequests.isEmpty {
                rows.append(TVRequestRow(
                    id: "mine",
                    title: "Your requests",
                    items: hub.myRequests.map { .record($0) }
                ))
            }
            if RequestsFeatureStore.shared.canModerate, !approvals.failed.isEmpty {
                rows.append(TVRequestRow(
                    id: "failed",
                    title: "Failed requests",
                    items: approvals.failed.map { .approval($0) }
                ))
            }
            for (index, carousel) in hub.carousels.enumerated() {
                rows.append(TVRequestRow(
                    id: "discover:\(carousel.id)",
                    label: index == 0 ? "Discover" : nil,
                    title: carousel.title,
                    items: carousel.results.map { .result($0) }
                ))
            }
            return rows
        case .mine:
            return mine.buckets.map { entry in
                TVRequestRow(
                    id: "bucket:\(entry.bucket.title)",
                    title: entry.bucket.title,
                    items: entry.requests.map { .record($0) }
                )
            }
        case .approvals:
            var rows: [TVRequestRow] = []
            if !approvals.awaitingApproval.isEmpty {
                rows.append(TVRequestRow(
                    id: "approvals",
                    title: "Waiting for approval",
                    items: approvals.awaitingApproval.map { .approval($0) }
                ))
            }
            if !approvals.failed.isEmpty {
                rows.append(TVRequestRow(
                    id: "failed",
                    title: "Failed",
                    items: approvals.failed.map { .approval($0) }
                ))
            }
            return rows
        }
    }

    private func load() async {
        switch mode {
        case .hub:
            async let discover = hub.load()
            async let moderation: Void = loadApprovalsIfModerating()
            _ = await (discover, moderation)
        case .mine:
            await mine.load()
        case .approvals:
            await approvals.load()
        }
        hasLoaded = true
    }

    private func retry() async {
        hasLoaded = false
        await load()
    }

    private func loadApprovalsIfModerating() async {
        if RequestsFeatureStore.shared.canModerate {
            await approvals.load()
        }
    }

    // MARK: - Feed

    private var feed: some View {
        ZStack(alignment: .top) {
            TVRequestsBackdrop(model: marquee)

            rowBand
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)

            TVRequestsMarquee(model: marquee)
                .offset(y: SiloTheme.Skyline.landingContentVerticalOffset)
        }
        .onAppear {
            marquee.resume()
            seedMarquee()
            requestEntryFocus(focusRequest)
            restoreLastFocus()
        }
        .onDisappear { marquee.suspend() }
        .onChange(of: focusedKey) { _, key in
            guard let key else { return }
            lastFocusedKey = key
            preview(key)
        }
    }

    /// The Skyline row band: native vertical scrolling clipped to the lower
    /// half, so rows appear from the same bottom area as Home.
    private var rowBand: some View {
        GeometryReader { proxy in
            let bandHeight = proxy.size.height * SiloTheme.Skyline.rowBandHeightFraction
            let bandTop = min(
                proxy.size.height,
                max(0, proxy.size.height - bandHeight + SiloTheme.Skyline.landingContentVerticalOffset)
            )
            let visibleBandHeight = max(0, proxy.size.height - bandTop)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: SiloTheme.Skyline.rowBandPreviewSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, isFirstRow: index == 0)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(row.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, max(0, visibleBandHeight - SiloTheme.Skyline.rowBandBottomInset))
            }
            .scrollTargetBehavior(.viewAligned)
            // Initial resolution lands on the first card; `.automatic`
            // keeps row-to-row movement geometric once inside.
            .defaultFocus(
                $focusedKey,
                rows.first.flatMap { row in row.items.first.map { row.key(for: $0) } },
                priority: isTopMenuFocused || onTopMenuFocusRequest == nil ? .userInitiated : .automatic
            )
            .onScrollPhaseChange { _, phase in
                marquee.setBackdropDeferred(phase != .idle)
            }
            .modifier(TVMenuEntryScroll(
                request: appliedEntryRequest,
                isTopMenuFocused: isTopMenuFocused,
                onReady: claimEntryFocus
            ))
            .frame(width: proxy.size.width, height: visibleBandHeight, alignment: .topLeading)
            .clipped()
            .padding(.top, bandTop)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func rowView(_ row: TVRequestRow, isFirstRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RequestsSectionHeader(label: row.label, title: row.title)
                .padding(.horizontal, SiloTheme.Skyline.safeAreaX)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(row.items) { item in
                        card(item, key: row.key(for: item))
                    }
                }
                .padding(.horizontal, SiloTheme.Skyline.safeAreaX)
                .padding(.vertical, SiloTheme.Skyline.rowBandCardVerticalPadding + 12)
            }
            .scrollClipDisabled()
        }
        .focusSection()
        // The page's single directional interception: Up from the first
        // row crosses to the top bar. Attached to every row so a row
        // becoming first never changes the focused subtree's structure.
        .onMoveCommand { direction in
            if direction == .up, isFirstRow { onTopMenuFocusRequest?() }
        }
    }

    @ViewBuilder
    private func card(_ item: TVRequestItem, key: String) -> some View {
        switch item {
        case .record(let record):
            RequestMediaCard(record: record, onTap: { router.openRequestRecord(record) })
                .cardWidth(SiloTheme.Skyline.densePosterCardWidth)
                .focused($focusedKey, id: key)
                .contextMenu {
                    if RequestDisplayState(record: record).isCancelable, !mine.isCancelUnconfirmed(record) {
                        Button(role: .destructive) {
                            Task {
                                if mode == .mine {
                                    await mine.cancel(record)
                                } else {
                                    await mine.cancel(record, refresh: { await hub.load() })
                                }
                            }
                        } label: {
                            Label("Cancel Request", systemImage: "xmark.circle")
                        }
                    }
                }
        case .approval(let record):
            RequestMediaCard(record: record, onTap: { router.openModerationRecord(record) })
                .cardWidth(SiloTheme.Skyline.densePosterCardWidth)
                .focused($focusedKey, id: key)
                .contextMenu {
                    if !approvals.canAct(on: record) {
                        EmptyView()
                    } else if RequestDisplayState(record: record) == .pending {
                        Button {
                            Task { await approvals.perform(.approve, on: record) }
                        } label: {
                            Label("Approve", systemImage: "checkmark")
                        }
                        Button(role: .destructive) {
                            pendingDecline = record
                        } label: {
                            Label("Decline", systemImage: "xmark")
                        }
                    } else if case .needsAttention(.failed, _) = RequestDisplayState(record: record) {
                        Button {
                            Task { await approvals.perform(.retry, on: record) }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                }
        case .result(let result):
            RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                .cardWidth(SiloTheme.Skyline.densePosterCardWidth)
                .focused($focusedKey, id: key)
        }
    }

    // MARK: - Focus

    /// Entry focus → the first row's first card, after the band scrolls to
    /// the top. A token that arrives before rows exist waits; one that
    /// arrives while the top menu holds focus is dropped.
    private func requestEntryFocus(_ request: Int) {
        guard request > 0 else { return }
        guard !rows.isEmpty else {
            pendingEntryRequest = request
            return
        }
        pendingEntryRequest = nil
        if isTopMenuFocused { return }
        guard request != appliedEntryRequest else { return }
        appliedEntryRequest = request
    }

    private func claimEntryFocus(_ request: Int) {
        guard !isTopMenuFocused,
              appliedEntryRequest == request,
              let row = rows.first,
              let item = row.items.first else { return }
        focusedKey = row.key(for: item)
    }

    /// Returning from a pushed detail: put focus back on the launching card
    /// when the engine didn't already.
    private func restoreLastFocus() {
        guard let lastFocusedKey, focusedKey == nil, !isTopMenuFocused else { return }
        DispatchQueue.main.async {
            if focusedKey == nil, rows.contains(where: { $0.contains(key: lastFocusedKey) }) {
                focusedKey = lastFocusedKey
            }
        }
    }

    // MARK: - Marquee

    private func preview(_ key: String) {
        guard let (row, item) = locate(key) else { return }
        marquee.preview(Self.marqueeContent(item, row: row), neighborBackdropURLs: neighborBackdrops(of: item, in: row))
    }

    private func seedMarquee() {
        guard marquee.content == nil, let row = rows.first, let item = row.items.first else { return }
        marquee.seed(Self.marqueeContent(item, row: row))
    }

    private func locate(_ key: String) -> (TVRequestRow, TVRequestItem)? {
        for row in rows {
            if let item = row.items.first(where: { row.key(for: $0) == key }) {
                return (row, item)
            }
        }
        return nil
    }

    private func neighborBackdrops(of item: TVRequestItem, in row: TVRequestRow) -> [String] {
        guard let index = row.items.firstIndex(where: { $0.id == item.id }) else { return [] }
        let radius = SiloTheme.Skyline.marqueeNeighborBackdropPrefetchRadius
        return row.items.indices
            .clamped(to: (index - radius)..<(index + radius + 1))
            .filter { $0 != index }
            .compactMap { RequestImageURL.build(row.items[$0].backdropPath, size: .backdrop) }
    }

    static func marqueeContent(_ item: TVRequestItem, row: TVRequestRow) -> TVMarqueeContent {
        var meta: [String] = []
        if let year = item.year, year > 0 { meta.append(String(year)) }
        meta.append(item.mediaType.displayName)
        let progress: RequestProgress?
        let statusText: String?
        switch item {
        case .record(let record), .approval(let record):
            meta.append("Requested \(record.createdAt.formatted(.dateTime.month(.abbreviated).day()))")
            let recordProgress = RequestProgress(record: record)
            progress = recordProgress
            statusText = RequestRowCopy.status(record, progress: recordProgress)
        case .result(let result):
            // Like the detail page: a title that can't be requested has no
            // track to show.
            progress = RequestProgress(availability: result.availability, request: result.request)
                .flatMap { progress in
                    if case .unavailable = progress.display { return nil }
                    return progress
                }
            statusText = progress?.longLabel
            if let rating = result.voteAverage, rating > 0 {
                meta.append(String(format: "TMDB %.1f", rating))
            }
        }
        return TVMarqueeContent(
            id: "\(row.id)#\(item.id)",
            contentId: nil,
            rowId: row.id,
            eyebrow: row.title,
            title: item.title,
            logoUrl: nil,
            badges: [],
            metaParts: meta,
            runtimeMetaIndex: meta.count,
            runtimeText: nil,
            synopsis: item.overview,
            backdropUrl: RequestImageURL.build(item.backdropPath, size: .backdrop),
            backdropThumbhash: nil,
            fallbackArtworkUrl: RequestImageURL.build(item.posterPath, size: .poster),
            fallbackArtworkThumbhash: nil,
            baseOverlayData: nil,
            contentRatingBadge: nil,
            progressUpdatedAt: nil,
            prefersLastUsedPlaybackMetadata: false,
            isEpisode: false,
            seriesContextId: nil,
            seriesContextSeasonNumber: nil,
            requestProgress: progress,
            requestStatusText: statusText
        )
    }
}

// MARK: - Row model

struct TVRequestRow: Identifiable {
    let id: String
    var label: String? = nil
    let title: String
    let items: [TVRequestItem]

    /// Page-unique focus key: the same title can sit in two rows.
    func key(for item: TVRequestItem) -> String { "\(id)|\(item.id)" }

    func contains(key: String) -> Bool {
        items.contains { self.key(for: $0) == key }
    }
}

enum TVRequestItem: Identifiable {
    case record(MediaRequest)
    /// Someone's request, shown to an admin who can decide on it.
    case approval(MediaRequest)
    case result(RequestMediaResult)

    var id: String {
        switch self {
        case .record(let record): "request:\(record.id)"
        case .approval(let record): "approval:\(record.id)"
        case .result(let result): "tmdb:\(result.id)"
        }
    }

    var title: String {
        switch self {
        case .record(let r), .approval(let r): r.title
        case .result(let r): r.title
        }
    }

    var year: Int? {
        switch self {
        case .record(let r), .approval(let r): r.year
        case .result(let r): r.year
        }
    }

    var mediaType: RequestMediaType {
        switch self {
        case .record(let r), .approval(let r): r.mediaType
        case .result(let r): r.mediaType
        }
    }

    var overview: String? {
        switch self {
        case .record(let r), .approval(let r): r.overview
        case .result(let r): r.overview
        }
    }

    var posterPath: String? {
        switch self {
        case .record(let r), .approval(let r): r.posterPath
        case .result(let r): r.posterPath
        }
    }

    var backdropPath: String? {
        switch self {
        case .record(let r), .approval(let r): r.backdropPath
        case .result(let r): r.backdropPath
        }
    }
}

// MARK: - Leaves

/// Backdrop and marquee read the model at the leaves, so preview updates
/// never rebuild the rows and their focusable cards.
private struct TVRequestsBackdrop: View {
    let model: TVFocusMarqueeModel

    var body: some View {
        TVRootHeroBackdrop(
            tintColor: model.tintColor,
            artworkURL: model.backdropURL,
            artworkThumbhash: model.backdropThumbhash,
            isVisible: model.backdropURL != nil,
            crossfadeDuration: SiloTheme.Skyline.marqueeCrossfadeDuration
        )
    }
}

private struct TVRequestsMarquee: View {
    let model: TVFocusMarqueeModel

    var body: some View {
        TVFocusMarquee(content: model.content, enrichment: nil, scale: .home)
    }
}

// MARK: - Loading

/// First frame of the Requests page while rows load: the same passive
/// marquee-and-row geometry as `TVLibraryBrowseLoadingView`, so the real
/// feed replaces it in place instead of the page building itself from a
/// black canvas. The caller makes it the page's focus owner.
struct TVRequestsLoadingView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.siloBackground

            LinearGradient(
                colors: [
                    Color.siloSurfaceElevated.opacity(0.72),
                    Color.siloBackground.opacity(0.88),
                    Color.siloBackground,
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            VStack(alignment: .leading, spacing: 0) {
                marqueePlaceholder
                Spacer(minLength: 24)
                RequestRailSkeleton(cardCount: 8, cardWidth: SiloTheme.Skyline.densePosterCardWidth)
            }
            .padding(.horizontal, SiloTheme.Skyline.safeAreaX)
            .padding(.top, 188)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .ignore)
    }

    private var marqueePlaceholder: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 520, height: 72)

            HStack(spacing: 14) {
                RequestsSkeleton.bar(width: 118, height: 22)
                RequestsSkeleton.bar(width: 82, height: 22)
                RequestsSkeleton.bar(width: 150, height: 22)
            }

            VStack(alignment: .leading, spacing: 13) {
                RequestsSkeleton.bar(width: 720, height: 18)
                RequestsSkeleton.bar(width: 610, height: 18)
            }

            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                Text("Loading Requests")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.72))
            }
            .padding(.top, 4)
        }
    }
}
#endif
