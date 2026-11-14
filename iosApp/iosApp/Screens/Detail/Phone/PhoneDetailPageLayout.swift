#if !os(tvOS)
import SwiftUI

/// The scrolling body of a movie or series detail page. Usually one column:
/// the hero, then the sections below it. A wide, short page (see
/// `PhoneDetailHeroLayout.usesSplitLayout`) instead spreads the artwork
/// across the whole window, holds the title and actions still in a glass
/// sidebar over its leading side, and scrolls the sections beside it. The
/// sections start low enough to leave the top of the artwork clear, but
/// high enough to show all of a section marked with `splitPaneLeadEnd()`,
/// and the artwork blurs and darkens behind them as they scroll up.
///
/// Place it in a `PhoneDetailPageSurface` that keeps the side safe area: the
/// split reads those insets, and the single column extends back under them.
struct PhoneDetailPageLayout<Column: View, PaneArtwork: View, PaneSidebar: View, PaneContent: View>: View {
    let scrollState: PhoneDetailScrollState
    /// The single-column page.
    @ViewBuilder let column: () -> Column
    /// The artwork spread behind the split page.
    @ViewBuilder let paneArtwork: () -> PaneArtwork
    /// The title, facts, actions, and playback selectors for the sidebar.
    @ViewBuilder let paneSidebar: () -> PaneSidebar
    /// Everything else, for the content pane beside the sidebar.
    @ViewBuilder let paneContent: () -> PaneContent

    /// The page's size and side insets. A single column reads only the
    /// insets, so while neither the old nor the new size could split, a
    /// change of size alone is not stored: the safe area and frame settle
    /// over several passes as the detail is presented, and each store would
    /// rebuild the whole page.
    @State private var page = PageGeometry()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if PhoneDetailHeroLayout.usesSplitLayout(pageSize: page.size, verticalSizeClass: verticalSizeClass) {
                split
            } else {
                singleColumn
            }
        }
        .onGeometryChange(for: PageGeometry.self) { proxy in
            PageGeometry(
                size: proxy.size,
                leadingInset: proxy.safeAreaInsets.leading,
                trailingInset: proxy.safeAreaInsets.trailing
            )
        } action: { geometry in
            if Self.couldSplit(page.size) || Self.couldSplit(geometry.size)
                || geometry.leadingInset != page.leadingInset || geometry.trailingInset != page.trailingInset {
                page = geometry
            }
        }
    }

    /// Whether a page this size splits in any size class.
    private static func couldSplit(_ size: CGSize) -> Bool {
        PhoneDetailHeroLayout.usesSplitLayout(pageSize: size, verticalSizeClass: .regular)
    }

    private var singleColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            column()
        }
        #if os(macOS)
        // The Mac surface keeps its leading inset to stay clear of the sidebar.
        .ignoresSafeArea(edges: .top)
        #else
        // Beside the iPhone Duo's status column the page keeps clear of it,
        // and only the hero artwork reaches underneath (see PhoneDetailHero).
        .ignoresSafeArea(edges: statusColumn == nil ? [.top, .horizontal] : .top)
        .scrollClipDisabled(statusColumn != nil)
        .environment(\.statusColumn, statusColumn)
        #endif
        .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
        .detailScrollDismissal()
        .phoneDetailScrollTracking(scrollState)
    }

    #if os(iOS)
    private var statusColumn: StatusColumnLayout? {
        StatusColumnLayout(safeArea: EdgeInsets(
            top: 0,
            leading: page.leadingInset,
            bottom: 0,
            trailing: page.trailingInset
        ))
    }
    #endif

    private var split: some View {
        PhoneDetailSplitPage(
            page: page,
            paneArtwork: paneArtwork,
            paneSidebar: paneSidebar,
            paneContent: paneContent
        )
    }
}

/// `PhoneDetailPageLayout`'s split page. Its own view, so the top safe area
/// it reads does not rebuild a single-column page as the area settles.
private struct PhoneDetailSplitPage<PaneArtwork: View, PaneSidebar: View, PaneContent: View>: View {
    let page: PageGeometry
    let paneArtwork: () -> PaneArtwork
    let paneSidebar: () -> PaneSidebar
    let paneContent: () -> PaneContent

    @State private var contentScroll = ContentPaneScroll()
    @State private var leadEnd: CGFloat?
    @Environment(\.detailPageTopSafeArea) private var topSafeArea

    /// Clears the floating Close and Remote buttons, which sit 9pt below the
    /// top edge and are 44pt tall. The content pane scrolls beneath this inset
    /// rather than under the buttons, so it needs no backing strip.
    static var contentPaneTopInset: CGFloat { 9 + SiloTheme.topBarIconHitSize + 12 }
    /// Room left below the lead section when it pulls the sections up.
    static var contentPaneBottomInset: CGFloat { 20 }

    var body: some View {
        let artworkHeight = page.artworkHeight
        // The sections begin where the artwork starts fading out, or higher
        // when the marked lead section would otherwise end below the window.
        let fadeTop = artworkHeight * 0.66
        let leadTop = leadEnd.map { page.size.height - Self.contentPaneBottomInset - $0 } ?? fadeTop
        let contentTop = max(topSafeArea + Self.contentPaneTopInset, min(fadeTop, leadTop))
        return HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                paneSidebar()
                    .padding(.horizontal, 18)
                    // Clears the Close button, which moves into the sidebar.
                    .padding(.top, topSafeArea + Self.contentPaneTopInset)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: page.sidebarWidth)
            .clipShape(.rect(cornerRadius: 32, style: .continuous))
            .siloGlass(in: .rect(cornerRadius: 32, style: .continuous), tint: .black.opacity(0.32))
            .padding(PhoneDetailHeroLayout.splitSidebarMargin)

            ScrollView(.vertical, showsIndicators: false) {
                paneContent()
                    .coordinateSpace(name: SplitPaneLeadEndKey.space)
                    .padding(.top, contentTop)
            }
            .onPreferenceChange(SplitPaneLeadEndKey.self) { end in
                leadEnd = end
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                contentScroll.update(offset: offset, fadeDistance: contentTop)
            }
            // Unclipped, so the rails inside draw past the pane too; text
            // keeps to the pane's padding.
            .scrollClipDisabled()
            .detailScrollDismissal()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Rails stop at the sidebar but run on under the status column
            // to the window's trailing edge.
            .mask(alignment: .leading) {
                Rectangle().padding(.trailing, -page.trailingInset)
            }
        }
        // Wider than the page, so it sits in the background where it can't
        // widen the layout.
        .background(alignment: .topLeading) {
            SplitPageArtwork(
                scroll: contentScroll,
                size: CGSize(width: page.windowWidth, height: artworkHeight),
                shift: page.artworkShift,
                contentStart: contentTop / max(artworkHeight, 1),
                artwork: paneArtwork
            )
            .offset(x: -page.leadingInset)
        }
    }
}

/// How far the content pane has scrolled over the artwork, from 0 at rest to
/// 1 once the sections cover where they started. Only `SplitPageArtwork`
/// reads it, so scrolling redraws the artwork's effects and nothing else.
@Observable
@MainActor
private final class ContentPaneScroll {
    private(set) var progress: CGFloat = 0

    func update(offset: CGFloat, fadeDistance: CGFloat) {
        let progress = min(max(offset / max(fadeDistance, 1), 0), 1)
        // Small steps are invisible; the endpoints always land exactly.
        guard progress != self.progress,
              abs(progress - self.progress) >= 0.01 || progress == 0 || progress == 1 else { return }
        self.progress = progress
    }
}

/// The split page's artwork, faded into the page surface at its lower edge,
/// and blurred and darkened as the content pane scrolls over it so the
/// sections stay readable.
private struct SplitPageArtwork<Artwork: View>: View {
    let scroll: ContentPaneScroll
    let size: CGSize
    /// How far right of the window's center the artwork's center sits.
    let shift: CGFloat
    /// Where the sections start, as a fraction of the artwork's height.
    let contentStart: CGFloat
    let artwork: () -> Artwork

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let progress = scroll.progress
        // The lower shade reaches full strength just above the sections.
        let shadeStart = max(contentStart - 0.26, 0.05)
        let shadeFull = max(contentStart - 0.04, shadeStart + 0.01)
        artwork()
            .frame(width: size.width, height: size.height)
            .clipped()
            // Shifted right, the artwork leaves the window's leading edge
            // bare; it fades in from there, behind the sidebar.
            .mask {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: shift / size.width, y: 0.5)
                )
            }
            .padding(.leading, shift)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .clipped()
            .overlay {
                // Darkens the top for the time, connection status, and
                // floating buttons, and the part from just above the sections
                // down, so both read over bright artwork.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.3), location: 0),
                        .init(color: .clear, location: min(0.3, shadeStart)),
                        .init(color: .clear, location: shadeStart),
                        .init(color: .black.opacity(0.62), location: shadeFull),
                        .init(color: .black.opacity(0.8), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .blur(radius: reduceTransparency ? 0 : 28 * progress)
            .overlay(Color.black.opacity((reduceTransparency ? 0.7 : 0.45) * progress))
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.6),
                        .init(color: .black.opacity(0.55), location: 0.8),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The sections under a single-column detail page's hero. Those still
/// below the window when the page first lays out join it once that first
/// frame is committed, so the frame that opens the page builds and lays out
/// only what it shows. Sections that would show in it, under a short hero,
/// are added before it commits instead, so nothing appears late on screen.
/// The Mac builds them at once, and so does an iPhone or iPad running
/// VoiceOver or Switch Control, whose users reach sections by navigating
/// rather than by scrolling them into view.
struct PhoneDetailBelowFold<Content: View>: View {
    @ViewBuilder let content: () -> Content

    #if os(iOS)
    @State private var isShown = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    #else
    private let isShown = true
    #endif

    var body: some View {
        if isShown {
            content()
        } else {
            #if os(iOS)
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: Bool.self) { proxy in
                    // Where the scroll view's visible area is, seen from here.
                    guard let visible = proxy.bounds(of: .scrollView(axis: .vertical)) else { return true }
                    return visible.minY <= 0 && visible.maxY > 0
                } action: { isOnScreen in
                    if isOnScreen { isShown = true }
                }
                // Follows the commits of the scene this page is in.
                .background(DetailFrameCommitAnchor { isShown = true })
            #endif
        }
    }
}

#if os(iOS)
/// Asks `DetailFrameCommit` to run `action` after the first frame it is in
/// commits, in the window scene it was added to, and withdraws the request
/// if it leaves first.
private struct DetailFrameCommitAnchor: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.action = action
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.action = action
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.withdraw()
    }

    final class AnchorView: UIView {
        var action: (() -> Void)?
        private var request: DetailFrameCommit.Request?
        private var didRequest = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Once per marker: a marker that moves windows has already been
            // shown or will be by the request's fallback.
            guard let window, !didRequest else { return }
            didRequest = true
            request = DetailFrameCommit.afterNextCommit(in: window.windowScene) { [weak self] in
                self?.request = nil
                self?.action?()
            }
        }

        func withdraw() {
            if let request { DetailFrameCommit.cancel(request) }
            request = nil
        }
    }
}

/// Runs work once the frame being built has gone to the screen.
///
/// Each window scene gets its own `UIUpdateLink`, released when the scene
/// goes to the background or disconnects; anything still waiting on it then
/// runs at once. Every request also runs after `fallback` if no commit has
/// run it by then, so a scene that stops committing cannot hold work back.
/// A request runs at most once, and a cancelled one never; so the waiting
/// work never outgrows the requests made in the last `fallback`.
@MainActor
enum DetailFrameCommit {
    struct Request: Hashable {
        fileprivate let id: UUID
    }

    static var fallback: Duration = .milliseconds(100)

    private final class SceneLink {
        let link: UIUpdateLink
        /// Waiting for a UI update to begin committing.
        var pending: [Request] = []
        /// Run when the update now committing has finished.
        var armed: [Request] = []

        init(link: UIUpdateLink) { self.link = link }
    }

    private static var links: [ObjectIdentifier: SceneLink] = [:]
    private static var actions: [Request: () -> Void] = [:]
    private static var observesScenes = false

    /// Requests not yet run or cancelled.
    static var waitingCount: Int { actions.count }
    /// Scenes with a live link.
    static var linkedSceneCount: Int { links.count }

    /// Runs `action` after Core Animation commits, in `scene`, the next UI
    /// update that begins after this call, or after `fallback` if that comes
    /// first. With no scene, or one in the background, it runs now and
    /// returns nil.
    @discardableResult
    static func afterNextCommit(in scene: UIWindowScene?, _ action: @escaping () -> Void) -> Request? {
        guard let scene, scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        else {
            action()
            return nil
        }
        observeScenes()
        let request = Request(id: UUID())
        actions[request] = action
        let entry = links[ObjectIdentifier(scene)] ?? makeLink(for: scene)
        entry.pending.append(request)
        // Asks for that update even if nothing else on screen changes.
        entry.link.requiresContinuousUpdates = true
        entry.link.isEnabled = true
        Task { @MainActor in
            try? await Task.sleep(for: fallback)
            run(request)
        }
        return request
    }

    /// Drop `request` without running it.
    static func cancel(_ request: Request) {
        actions[request] = nil
    }

    private static func run(_ request: Request) {
        actions.removeValue(forKey: request)?()
    }

    private static func makeLink(for scene: UIWindowScene) -> SceneLink {
        let entry = SceneLink(link: UIUpdateLink(windowScene: scene))
        entry.link.addAction(to: .beforeCATransactionCommit) { [weak entry] _, _ in
            guard let entry else { return }
            entry.armed.append(contentsOf: entry.pending)
            entry.pending.removeAll()
        }
        entry.link.addAction(to: .afterCATransactionCommit) { [weak entry] link, _ in
            guard let entry else { return }
            let due = entry.armed
            entry.armed.removeAll()
            if entry.pending.isEmpty {
                link.requiresContinuousUpdates = false
                link.isEnabled = false
            }
            for request in due { run(request) }
        }
        links[ObjectIdentifier(scene)] = entry
        return entry
    }

    private static func observeScenes() {
        guard !observesScenes else { return }
        observesScenes = true
        for name in [UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let key = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { release(key) }
            }
        }
    }

    /// The scene stopped drawing: run what waited on it and drop its link.
    private static func release(_ key: ObjectIdentifier?) {
        guard let key, let entry = links.removeValue(forKey: key) else { return }
        entry.link.requiresContinuousUpdates = false
        entry.link.isEnabled = false
        for request in entry.armed + entry.pending { run(request) }
    }
}
#endif

extension EnvironmentValues {
    /// The window's top safe area, set by `PhoneDetailPageSurface` for pages
    /// that extend beneath it.
    @Entry var detailPageTopSafeArea: CGFloat = 0

    /// The width a detail page is presented at, known before its views
    /// measure themselves. Zero when the presenter does not set it.
    @Entry var detailPageWidthHint: CGFloat = 0

    #if os(macOS)
    /// The detail page's height in the window, set by `PhoneDetailPageSurface`.
    /// Zero until measured.
    @Entry var detailPageVisibleHeight: CGFloat = 0
    #endif
}

extension View {
    /// Marks the end of the section a split page's content pane shows whole
    /// before any scrolling, such as a series' episode rail with its titles.
    func splitPaneLeadEnd() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SplitPaneLeadEndKey.self,
                    value: proxy.frame(in: .named(SplitPaneLeadEndKey.space)).maxY
                )
            }
        }
    }
}

/// Where the marked lead section ends, measured from the top of the content
/// pane's sections.
private struct SplitPaneLeadEndKey: PreferenceKey {
    static let space = "splitPaneContent"
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct PageGeometry: Equatable {
    var size: CGSize = .zero
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    /// The whole window, side insets included: the artwork runs under the
    /// iPhone Duo's status column too.
    var windowWidth: CGFloat { leadingInset + size.width + trailingInset }

    /// A 16:9 backdrop across the window, kept short enough that the
    /// sections below it start on screen.
    var artworkHeight: CGFloat {
        min(windowWidth * 9 / 16, size.height * 0.85)
    }

    /// Moves the artwork's center from the window's center to the middle of
    /// what the sidebar leaves uncovered, between it and the trailing edge.
    var artworkShift: CGFloat {
        let sidebarEnd = leadingInset + sidebarWidth + 2 * PhoneDetailHeroLayout.splitSidebarMargin
        // (sidebarEnd + windowWidth) / 2, less the window's own center.
        return sidebarEnd / 2
    }

    /// Wide enough for the five labelled actions in a row. On iPhone Duo the
    /// sidebar ends well before the fold.
    var sidebarWidth: CGFloat {
        min(max(size.width * 0.37, 340), 400)
    }
}
#endif
