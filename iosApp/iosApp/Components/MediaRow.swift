import SwiftUI
#if os(tvOS)
import os
#endif

/// Layout mode for a horizontal media row.
/// Poster rows use tall (2:3) poster cards; thumbnail rows use wide 16:9
/// episode stills — pick thumbnail for episode-centric sections like
/// "Next Up" and resume rows like Continue Watching. Square
/// rows use 1:1 tiles for audiobook covers.
enum MediaRowLayout {
    case poster
    case landscape
    case thumbnail
    case square
}

enum LandscapeRowArtwork {
    static func imageUrl(cardUrl: String?, backdropUrl: String?) -> String {
        if let cardUrl, !cardUrl.isEmpty {
            return cardUrl
        }
        if let backdropUrl, !backdropUrl.isEmpty {
            return backdropUrl
        }
        return ""
    }

    static func thumbhash(cardThumbhash: String?, backdropThumbhash: String?) -> String? {
        if let cardThumbhash, !cardThumbhash.isEmpty {
            return cardThumbhash
        }
        if let backdropThumbhash, !backdropThumbhash.isEmpty {
            return backdropThumbhash
        }
        return nil
    }

    static func showsTitleOverlay(cardUrl: String?) -> Bool {
        !(cardUrl?.isEmpty == false)
    }
}

/// A horizontal scrolling row of media cards with a title header.
/// Plezy style: section title with optional icon, safe-area leading padding.
struct MediaRow: View {
    let title: String
    let items: [SectionItem]
    let onItemTap: (String) -> Void
    /// tvOS-only direct-play action for focused leaf items. Container items
    /// intentionally receive no Play/Pause command and retain normal focus.
    var onItemPlay: ((SectionItem) -> Void)? = nil
    var onSeeAll: (() -> Void)? = nil
    var showProgress: Bool = false
    var icon: String? = nil
    var layout: MediaRowLayout = .poster
    /// When true (and there are items), the row's first card becomes the
    /// default focus target — on initial appearance AND on user-driven
    /// d-pad entry into the row's focus section. Implemented via
    /// `.defaultFocus($focusedItemId, firstId, priority: .userInitiated)`;
    /// see CLAUDE.md's "tvOS default focus on d-pad entry" pattern.
    var prefersDefaultFocusOnFirstItem: Bool = false
    /// Priority for the first-item default focus. `.userInitiated` (the
    /// default) also snaps d-pad entry into the row onto the first card;
    /// pass `.automatic` when only the engine's own resolutions (initial
    /// focus on cold launch) should use the preference, keeping directional
    /// entry geometric.
    var defaultFocusPriority: DefaultFocusEvaluationPriority = .userInitiated
    /// Programmatic kick: when this value changes to non-zero, focus
    /// jumps to the first item. Used by callers (e.g. PlayerView) that
    /// shift focus from an unrelated view rather than via d-pad entry —
    /// where `.userInitiated` defaultFocus alone doesn't fire because the
    /// focus engine isn't doing the moving.
    var focusRequest: Int = 0
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    var onMoveUp: (() -> Void)? = nil
    /// tvOS-only: reports which of the row's items holds card focus —
    /// the Skyline focus marquee mirrors it. Fires on focus gain only;
    /// focus leaving the row (nil) is deliberately not reported so the
    /// marquee retains the last previewed item while focus is in chrome.
    var onItemFocus: ((SectionItem) -> Void)? = nil
    /// Optional width for poster/square cards — Skyline's dense landing
    /// rows (§5.6) pass a compact width. Wide cards are unaffected.
    var cardWidth: CGFloat? = nil
    /// Optional tvOS-only vertical padding override for the card strip.
    /// Standard rows keep the default breathing room for focus lift.
    var cardVerticalPadding: CGFloat? = nil
    /// Down at the row's boundary — used by the Skyline section pager to
    /// page to the next section (there is no row geometrically below).
    var onMoveDown: (() -> Void)? = nil

    @FocusState private var focusedItemId: String?
    #if os(tvOS)
    /// Each focus token is applied once. Tracked so the claim works on a
    /// freshly-mounted row too (the Skyline section pager swaps the row's
    /// identity per page, so the kick has to land on `onAppear`, not only
    /// on a `focusRequest` change).
    @State private var lastAppliedFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let focusLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "TVFocus"
    )
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: rowVerticalSpacing) {
            header
            scrollContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .focusSection()
        .modifier(TVRowMoveHandler(onMoveUp: onMoveUp, onMoveDown: onMoveDown))
        .onChange(of: focusedItemId) { _, newValue in
            guard let newValue,
                  let item = items.first(where: { $0.contentId == newValue }) else { return }
            Self.focusLogger.debug("mediaRow.focus changed")
            onItemFocus?(item)
        }
        #endif
    }

    #if os(tvOS)
    private func applyFocusRequest(_ request: Int, proxy: ScrollViewProxy) {
        guard request > 0, request != lastAppliedFocusRequest,
              let firstItem = items.first else { return }
        lastAppliedFocusRequest = request
        // Scroll home first, claim a turn later: a row parked deep in its
        // strip keeps the first card unmounted (LazyHStack) or clipped, and
        // the focus engine silently drops @FocusState writes to views it
        // can't focus. The instant scroll mounts/unclips the card; the
        // deferred write then lands on a focusable target.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.slowDuration)) {
            proxy.scrollTo(firstItem.id, anchor: .leading)
        }
        DispatchQueue.main.async {
            Self.focusLogger.debug("mediaRow.applyFocus request=\(request, privacy: .public)")
            claimFirstItemFocus(firstItem)
        }
    }

    /// Write the claim, then verify it actually stuck and re-assert if not.
    /// A single write races two things that both win by coming later: the
    /// engine's remembered-focus repair after the top bar resigns, and the
    /// geometric re-repairs it makes while the feed's scroll-to-top slides
    /// rows (and their cards) under whatever it had focused. @FocusState
    /// reflects *actual* focus, so a rejected/overridden write reads back as
    /// a different value — retry until the scroll settles and ours is last.
    private func claimFirstItemFocus(_ firstItem: SectionItem, attempt: Int = 0) {
        focusedItemId = firstItem.contentId
        onItemFocus?(firstItem)
        // Window must outlast the ~300ms animated ride home plus the engine's
        // settling repairs, or the last mid-flight repair wins after all.
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard focusedItemId != firstItem.contentId else { return }
            Self.focusLogger.debug("mediaRow.reclaimFocus attempt=\(attempt + 1, privacy: .public)")
            claimFirstItemFocus(firstItem, attempt: attempt + 1)
        }
    }
    #endif

    // MARK: - Header

    private var header: some View {
        HStack(spacing: headerIconSpacing) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: headerIconSize, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
            }

            Text(title)
                .font(.continuumHeadline)
                .foregroundColor(.continuumOnSurface)

            Spacer()

            if let onSeeAll {
                Button("See All") {
                    onSeeAll()
                }
                .font(.continuumCaption)
                .foregroundColor(.continuumOnSurface.opacity(0.6))
            }
        }
        .padding(.horizontal, ContinuumTheme.safePadding)
    }

    // MARK: - Content

    private var scrollContent: some View {
        ScrollViewReader { rowProxy in
            scrollStrip(rowProxy)
        }
    }

    private func scrollStrip(_ rowProxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(items) { item in
                    switch layout {
                    case .poster, .square:
                        MediaCard(
                            title: posterTitle(for: item),
                            posterUrl: item.posterUrl ?? "",
                            thumbhash: item.posterThumbhash,
                            year: item.year,
                            progress: progressValue(for: item),
                            userState: item.userState,
                            overlayData: OverlayData.from(item),
                            action: { onItemTap(item.contentId) },
                            playAction: playAction(for: item),
                            focusedItemId: rowFocusBinding,
                            contentId: item.contentId,
                            onRemoveFromContinueWatching: continueWatchingRemovalAction(for: item),
                            onSetWatched: watchedToggleAction(for: item),
                            aspect: layout == .square ? .square : .poster,
                            cardWidthOverride: cardWidth,
                            episodeBadge: episodeBadge(for: item)
                        )
                    case .landscape:
                        MediaCard(
                            title: posterTitle(for: item),
                            posterUrl: landscapeImageUrl(for: item),
                            thumbhash: landscapeThumbhash(for: item),
                            year: item.year,
                            progress: progressValue(for: item),
                            userState: item.userState,
                            overlayData: OverlayData.from(item),
                            landscapeLogoUrl: item.logoUrl,
                            showLandscapeTitleOverlay: shouldShowLandscapeTitleOverlay(for: item),
                            action: { onItemTap(item.contentId) },
                            focusedItemId: rowFocusBinding,
                            contentId: item.contentId,
                            onRemoveFromContinueWatching: continueWatchingRemovalAction(for: item),
                            onSetWatched: watchedToggleAction(for: item),
                            aspect: .landscape,
                            cardWidthOverride: ContinuumTheme.thumbnailCardWidth,
                            episodeBadge: episodeBadge(for: item)
                        )
                    case .thumbnail:
                        EpisodeThumbCard(
                            item: item,
                            showProgress: showProgress,
                            action: { onItemTap(item.contentId) },
                            playAction: playAction(for: item),
                            focusedItemId: rowFocusBinding,
                            onRemoveFromContinueWatching: continueWatchingRemovalAction(for: item),
                            onSetWatched: watchedToggleAction(for: item)
                        )
                    }
                }
            }
            #if !os(tvOS)
            .padding(.horizontal, ContinuumTheme.safePadding)
            #endif
            .padding(.vertical, verticalCardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        // The leading gutter must be a content *margin*, not padding inside
        // the scroll content: programmatic `scrollTo(anchor: .leading)` and
        // the engine's scroll-to-focused both align to the margin-inset
        // viewport, so with inner padding they overshoot left by the gutter
        // width and then visibly drift back to the rest position.
        .contentMargins(.horizontal, ContinuumTheme.safePadding, for: .scrollContent)
        // tvOS focus lift expands cards on focus — give them breathing room
        // so they don't clip against the row above/below.
        .scrollClipDisabled()
        .applyDefaultFirstItemFocus(
            enabled: prefersDefaultFocusOnFirstItem,
            binding: $focusedItemId,
            firstItemId: items.first?.contentId,
            priority: defaultFocusPriority
        )
        // The programmatic focus kick needs the scroll proxy (it scrolls the
        // strip home before claiming), so it hangs off the strip rather than
        // the row's outer stack.
        .onAppear { applyFocusRequest(focusRequest, proxy: rowProxy) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request, proxy: rowProxy) }
        #endif
    }

    /// tvOS: bind every card to the row's @FocusState so the row can
    /// drive focus to a specific item via `defaultFocus(..)` or by
    /// setting `focusedItemId` directly (from the `focusRequest` kick).
    /// iOS doesn't have focus targets, so cards skip the binding.
    private var rowFocusBinding: FocusState<String?>.Binding? {
        #if os(tvOS)
        return $focusedItemId
        #else
        return nil
        #endif
    }

    private func progressValue(for item: SectionItem) -> Double? {
        // Watched items store position 0 server-side (the watched latch and
        // the resume point are independent), so a nonzero position is always
        // a live resume point — including a rewatch of a played item.
        guard showProgress,
              let pos = item.positionSeconds,
              let dur = item.durationSeconds,
              dur > 0, pos > 0 else { return nil }
        return pos / dur
    }

    private func playAction(for item: SectionItem) -> (() -> Void)? {
        #if os(tvOS)
        guard SiloMediaType.isDirectlyPlayable(item.type), let onItemPlay else { return nil }
        return { onItemPlay(item) }
        #else
        return nil
        #endif
    }

    private func continueWatchingRemovalAction(for item: SectionItem) -> (() -> Void)? {
        guard let onRemoveFromContinueWatching else { return nil }
        return { onRemoveFromContinueWatching(item) }
    }

    private func watchedToggleAction(for item: SectionItem) -> ((Bool) async -> Bool)? {
        guard let onSetWatched else { return nil }
        return { played in await onSetWatched(item, played) }
    }

    /// Caption for a poster card. Episodes are captioned with the series name
    /// — the bare `title` is the episode title (often "TBA" when unannounced).
    private func posterTitle(for item: SectionItem) -> String {
        item.type.lowercased() == "episode" ? (item.seriesTitle ?? item.title) : item.title
    }

    private func landscapeImageUrl(for item: SectionItem) -> String {
        LandscapeRowArtwork.imageUrl(
            cardUrl: item.landscapeCardUrl,
            backdropUrl: item.backdropUrl
        )
    }

    private func landscapeThumbhash(for item: SectionItem) -> String? {
        LandscapeRowArtwork.thumbhash(
            cardThumbhash: item.landscapeCardThumbhash,
            backdropThumbhash: item.backdropThumbhash
        )
    }

    private func shouldShowLandscapeTitleOverlay(for item: SectionItem) -> Bool {
        LandscapeRowArtwork.showsTitleOverlay(cardUrl: item.landscapeCardUrl)
    }

    /// "S2 · E10" badge for an episode rendered as a poster, so new episodes
    /// of the same series stay distinguishable. `nil` for non-episodes.
    private func episodeBadge(for item: SectionItem) -> String? {
        guard item.type.lowercased() == "episode",
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return "S\(season) · E\(episode)"
    }

    // MARK: - Metrics

    private var rowVerticalSpacing: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return ContinuumTheme.smallPadding
        #endif
    }

    private var headerIconSize: CGFloat {
        #if os(tvOS)
        return 32
        #else
        return 16
        #endif
    }

    private var headerIconSpacing: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 6
        #endif
    }

    private var cardSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return ContinuumTheme.spacing
        #endif
    }

    /// Vertical padding on the row content so focus lift doesn't clip.
    private var verticalCardPadding: CGFloat {
        #if os(tvOS)
        if let cardVerticalPadding {
            return cardVerticalPadding
        }

        return 24
        #else
        return 0
        #endif
    }
}

#if os(tvOS)
/// Bridges the row's boundary up/down move commands to the host. Only
/// attaches an `onMoveCommand` when at least one handler is supplied, so a
/// row that should stay out of the focus path (e.g. a non-paged row)
/// never intercepts the commands the focus engine needs for normal
/// row-to-row movement.
private struct TVRowMoveHandler: ViewModifier {
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if onMoveUp != nil || onMoveDown != nil {
            content.onMoveCommand { direction in
                switch direction {
                case .up: onMoveUp?()
                case .down: onMoveDown?()
                default: break
                }
            }
        } else {
            content
        }
    }
}

private extension View {
    /// Routes both initial and user-initiated (d-pad) focus into the
    /// row's first card. The `.userInitiated` priority is the bit that
    /// `prefersDefaultFocus(_:in:)` lacks — it makes default focus win
    /// over geometric proximity on d-pad entry. See CLAUDE.md's "tvOS
    /// default focus on d-pad entry" pattern.
    @ViewBuilder
    func applyDefaultFirstItemFocus(
        enabled: Bool,
        binding: FocusState<String?>.Binding,
        firstItemId: String?,
        priority: DefaultFocusEvaluationPriority
    ) -> some View {
        if enabled, let firstItemId {
            self.defaultFocus(binding, firstItemId, priority: priority)
        } else {
            self
        }
    }
}
#endif
