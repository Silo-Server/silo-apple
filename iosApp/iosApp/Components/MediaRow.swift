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
    case thumbnail
    case square
}

/// A horizontal scrolling row of media cards with a title header.
/// Plezy style: section title with optional icon, safe-area leading padding.
struct MediaRow: View {
    let title: String
    let items: [SectionItem]
    let onItemTap: (String) -> Void
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
    /// Programmatic kick: when this value changes to non-zero, focus
    /// jumps to the first item. Used by callers (e.g. PlayerView) that
    /// shift focus from an unrelated view rather than via d-pad entry —
    /// where `.userInitiated` defaultFocus alone doesn't fire because the
    /// focus engine isn't doing the moving.
    var focusRequest: Int = 0
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    /// tvOS-only: reports which of the row's items holds card focus —
    /// the Skyline focus marquee mirrors it. Fires on focus gain only;
    /// focus leaving the row (nil) is deliberately not reported so the
    /// marquee retains the last previewed item while focus is in chrome.
    var onItemFocus: ((SectionItem) -> Void)? = nil
    /// Optional width for poster/square cards — Skyline's dense landing
    /// rows (§5.6) pass a compact width. Episode thumbs are unaffected.
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
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: focusedItemId) { _, newValue in
            guard let newValue,
                  let item = items.first(where: { $0.contentId == newValue }) else { return }
            Self.focusLogger.debug("mediaRow.focus item=\(newValue, privacy: .public)")
            onItemFocus?(item)
        }
        #endif
    }

    #if os(tvOS)
    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest,
              let firstItem = items.first else { return }
        lastAppliedFocusRequest = request
        focusedItemId = firstItem.contentId
        Self.focusLogger.debug("mediaRow.applyFocus request=\(request, privacy: .public) first=\(firstItem.contentId, privacy: .public)")
        onItemFocus?(firstItem)
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
                            focusedItemId: rowFocusBinding,
                            contentId: item.contentId,
                            onRemoveFromContinueWatching: continueWatchingRemovalAction(for: item),
                            onSetWatched: watchedToggleAction(for: item),
                            aspect: layout == .square ? .square : .poster,
                            cardWidthOverride: cardWidth,
                            episodeBadge: episodeBadge(for: item)
                        )
                    case .thumbnail:
                        EpisodeThumbCard(
                            item: item,
                            showProgress: showProgress,
                            action: { onItemTap(item.contentId) },
                            focusedItemId: rowFocusBinding,
                            onRemoveFromContinueWatching: continueWatchingRemovalAction(for: item),
                            onSetWatched: watchedToggleAction(for: item)
                        )
                    }
                }
            }
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.vertical, verticalCardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        // tvOS focus lift expands cards on focus — give them breathing room
        // so they don't clip against the row above/below.
        .scrollClipDisabled()
        .applyDefaultFirstItemFocus(
            enabled: prefersDefaultFocusOnFirstItem,
            binding: $focusedItemId,
            firstItemId: items.first?.contentId
        )
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

    private func continueWatchingRemovalAction(for item: SectionItem) -> (() -> Void)? {
        guard item.progressUpdatedAt != nil, let onRemoveFromContinueWatching else { return nil }
        return { onRemoveFromContinueWatching(item) }
    }

    private func watchedToggleAction(for item: SectionItem) -> ((Bool) -> Void)? {
        guard let onSetWatched else { return nil }
        return { played in onSetWatched(item, played) }
    }

    /// Caption for a poster card. Episodes are captioned with the series name
    /// — the bare `title` is the episode title (often "TBA" when unannounced).
    private func posterTitle(for item: SectionItem) -> String {
        item.type.lowercased() == "episode" ? (item.seriesTitle ?? item.title) : item.title
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
        firstItemId: String?
    ) -> some View {
        if enabled, let firstItemId {
            self.defaultFocus(binding, firstItemId, priority: .userInitiated)
        } else {
            self
        }
    }
}
#endif
