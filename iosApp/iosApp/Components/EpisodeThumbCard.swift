import SwiftUI

/// Horizontal (16:9) media card for episode and resume content — used in
/// "Next Up", "Continue Watching", etc.
///
/// Shows the episode still / backdrop, the series title + episode code
/// (e.g. "S2 · E3") as an overlay, and the episode title plus runtime beneath.
/// On tvOS the image sits inside a `.card` button for focus lift/parallax and
/// a FocusState binding drives the title highlight.
struct EpisodeThumbCard: View {
    let item: SectionItem
    var showProgress: Bool = false
    let action: () -> Void
    /// tvOS-only shortcut invoked by the remote's Play/Pause button while
    /// this card owns focus. Select continues to invoke `action`.
    var playAction: (() -> Void)? = nil
    /// tvOS-only: parent row's focus tracking binding. See
    /// `MediaCard.focusedItemId` for the contract.
    var focusedItemId: FocusState<String?>.Binding? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onSetWatched: ((Bool) -> Void)? = nil

    @State private var playedOverride: Bool?
    @EnvironmentObject private var overlayStore: OverlayPrefsStore
    /// iOS 26 zoom transition namespace, shared from `MainTabView`. Lets the
    /// tapped thumbnail act as the `.matchedTransitionSource` for the zoom into
    /// the episode's item detail, keyed on `item.contentId`. `nil` (tvOS/macOS
    /// or unset) falls back to a plain push. (iOS branch only.)
    @Environment(\.zoomNamespace) private var zoomNamespace
    #if !os(tvOS)
    @Environment(AppRouter.self) private var router
    /// Unique per-placement zoom source id (see MediaCard) so the same episode
    /// in two on-screen rows doesn't collide on `contentId`.
    @State private var zoomInstanceID = UUID()
    #endif

    private var cardWidth: CGFloat { ContinuumTheme.thumbnailCardWidth }
    private var cardHeight: CGFloat { ContinuumTheme.thumbnailCardHeight }

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 14) {
            thumbnailButton

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.continuumSubheadline)
                    .foregroundColor(isFocused ? .continuumOnSurface : .continuumOnSurface.opacity(0.85))
                    .lineLimit(1)
                    .animation(.easeOut(duration: 0.15), value: isFocused)

                if let subtitle = subtitleLine {
                    Text(subtitle)
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth)
        .focusSection()
        .onChange(of: item.userState?.played) { _, _ in
            playedOverride = nil
        }
        #else
        Group {
            if hasContextActions {
                iosButton.contextMenu {
                    contextActions
                }
            } else {
                iosButton
            }
        }
        .onChange(of: item.userState?.played) { _, _ in
            playedOverride = nil
        }
        .frame(width: cardWidth)
        #endif
    }

    #if !os(tvOS)
    private var iosButton: some View {
        Button {
            router.pendingZoomSourceID = zoomInstanceID.uuidString
            action()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                Text(displayTitle)
                    .font(.continuumSubheadline)
                    .foregroundColor(.continuumOnSurface)
                    .lineLimit(1)
                if let subtitle = subtitleLine {
                    Text(subtitle)
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }
            }
            .zoomTransitionSource(id: zoomInstanceID.uuidString, in: zoomNamespace)
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Thumbnail

    private var thumbnail: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImageView(
                url: imageUrl,
                thumbhash: item.backdropThumbhash ?? item.posterThumbhash,
                targetSize: CGSize(width: cardWidth, height: cardHeight),
                contentMode: .fill
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))

            // Scrim gradient so the episode badge reads over bright stills
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))

            // Server / user-customized overlay badges. `wide` variant
            // gives the bottom corners enough headroom that they don't
            // collide with the S/E text + progress bar.
            if overlayStore.enabled {
                CardOverlays(
                    data: OverlayData.from(item),
                    prefs: overlayStore.prefs,
                    variant: .wide
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
            }

            // Episode badge overlay (e.g. "S2 · E3")
            if let badge = episodeBadge {
                Text(badge)
                    .font(.continuumCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, badgeHPadding)
                    .padding(.vertical, badgeVPadding)
                    .background(
                        Capsule().fill(Color.black.opacity(0.65))
                    )
                    .padding(badgeInset)
            }

            // Progress bar (resume)
            if showProgress, let p = progressValue, p > 0 {
                VStack {
                    Spacer()
                    ProgressBar(value: p)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
            }

            // Watched check
            if isPlayed {
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.continuumOnSurface)
                            .frame(width: checkBadgeSize, height: checkBadgeSize)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                        Image(systemName: "checkmark")
                            .font(.system(size: checkIconSize, weight: .bold))
                            .foregroundColor(Color.continuumBackground)
                    }
                }
                .padding(badgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            #if !os(tvOS)
            DownloadedBadgeOverlay(contentId: item.contentId, padding: badgeInset)
            #endif
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    private var isPlayed: Bool {
        playedOverride ?? (item.userState?.played == true)
    }

    // MARK: - Derived data

    /// Prefer backdrop/still artwork; fall back to poster.
    private var imageUrl: String {
        if let backdrop = item.backdropUrl, !backdrop.isEmpty {
            return backdrop
        }
        return item.posterUrl ?? ""
    }

    /// Series title for episodes, otherwise the item title.
    private var displayTitle: String {
        item.seriesTitle ?? item.title
    }

    /// Secondary line — episode title for episodes, otherwise year.
    private var subtitleLine: String? {
        if item.seriesTitle != nil {
            return item.title
        }
        if let year = item.year {
            return String(year)
        }
        return nil
    }

    /// "S1 · E4" badge if we have season+episode numbers.
    private var episodeBadge: String? {
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            return "S\(season) · E\(episode)"
        }
        return nil
    }

    private var progressValue: Double? {
        // Watched items store position 0 server-side (the watched latch and
        // the resume point are independent), so a nonzero position is always
        // a live resume point — including a rewatch of a played item.
        guard let pos = item.positionSeconds,
              let dur = item.durationSeconds,
              dur > 0, pos > 0 else { return nil }
        return pos / dur
    }

    // MARK: - Metrics

    private var badgeHPadding: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 8
        #endif
    }

    private var badgeVPadding: CGFloat {
        #if os(tvOS)
        return 7
        #else
        return 4
        #endif
    }

    private var badgeInset: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 6
        #endif
    }

    private var checkBadgeSize: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 20
        #endif
    }

    private var checkIconSize: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 10
        #endif
    }

    #if os(tvOS)
    @ViewBuilder
    private var thumbnailButton: some View {
        let button = Button(action: action) {
            thumbnail
        }
        .buttonStyle(.card)
        .focused($isFocused)
        .applyRowFocus(focusedItemId, itemId: item.contentId)
        .applyEpisodePlayPauseAction(playAction)

        thumbnailButtonWithContext(button)
    }

    @ViewBuilder
    private func thumbnailButtonWithContext<ButtonContent: View>(_ button: ButtonContent) -> some View {
        if hasContextActions {
            button.contextMenu {
                contextActions
            }
        } else {
            button
        }
    }
    #endif

    private var hasContextActions: Bool {
        onSetWatched != nil || onRemoveFromContinueWatching != nil
    }

    @ViewBuilder
    private var contextActions: some View {
        if let onSetWatched {
            Button {
                let played = !isPlayed
                playedOverride = played
                onSetWatched(played)
            } label: {
                Label(
                    isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isPlayed ? "circle" : "checkmark.circle"
                )
            }
        }

        if let onRemoveFromContinueWatching {
            Button(role: .destructive) {
                onRemoveFromContinueWatching()
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }
}

#if os(tvOS)
private extension View {
    @ViewBuilder
    func applyEpisodePlayPauseAction(_ action: (() -> Void)?) -> some View {
        if let action {
            self.onPlayPauseCommand(perform: action)
        } else {
            self
        }
    }

    /// Mirrors `MediaCard.applyRowFocus` so episode thumbs participate
    /// in the row's `defaultFocus(... priority: .userInitiated)` mechanism.
    @ViewBuilder
    func applyRowFocus(
        _ binding: FocusState<String?>.Binding?,
        itemId: String?
    ) -> some View {
        if let binding, let itemId {
            self.focused(binding, equals: itemId)
        } else {
            self
        }
    }
}
#endif
