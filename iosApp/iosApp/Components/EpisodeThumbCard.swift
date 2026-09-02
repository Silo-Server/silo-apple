import SwiftUI

/// Horizontal (16:9) media card for episode and resume content — used in
/// "Next Up", "Continue Watching", etc.
///
/// Shows the episode still / backdrop, series title, and episode metadata.
/// tvOS keeps the artwork clear except for server-configured card overlays;
/// compact S/E artwork badges remain available to the touch layouts.
/// On tvOS the image sits inside a `.card` button for focus lift/parallax and
/// a FocusState binding drives the title highlight.
struct EpisodeThumbCard: View {
    let item: SectionItem
    var showProgress: Bool = false
    let action: () -> Void
    /// Some hosts use thumbnail taps for an immediate action rather than
    /// opening detail. Player "On Deck" is the concrete case: selecting a
    /// card must start that episode. Ordinary Home and browse thumbnails keep
    /// the source-aware detail-card presentation.
    var usesProvidedTapAction: Bool = false
    /// tvOS-only shortcut invoked by the remote's Play/Pause button while
    /// this card owns focus. Select continues to invoke `action`.
    var playAction: (() -> Void)? = nil
    /// tvOS-only: parent row's focus tracking binding. See
    /// `MediaCard.focusedItemId` for the contract.
    var focusedItemId: FocusState<String?>.Binding? = nil
    var contextPlayTitle: String? = nil
    var contextDetailTitle: String? = nil
    var onOpenContextDetail: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onSetWatched: ((Bool) async -> Bool)? = nil

    @State private var playedOverride: Bool?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @EnvironmentObject private var overlayStore: OverlayPrefsStore
    #if os(tvOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var continueWatchingMetadata = TVContinueWatchingPlaybackMetadataStore.shared
    #endif
    /// iOS 26 zoom transition namespace, shared from `MainTabView`. Lets the
    /// tapped thumbnail act as the `.matchedTransitionSource` for the zoom into
    /// the episode's item detail, keyed on `item.contentId`. `nil` (tvOS/macOS
    /// or unset) falls back to a plain push. (iOS branch only.)
    @Environment(\.zoomNamespace) private var zoomNamespace
    #if !os(tvOS)
    @Environment(AppRouter.self) private var router
    @Environment(\.itemDetailBrowseSource) private var detailBrowseSource
    /// Unique per-placement zoom source id (see MediaCard) so the same episode
    /// in two on-screen rows doesn't collide on `contentId`.
    @State private var zoomInstanceID = UUID()
    #endif

    private var cardWidth: CGFloat {
        ContinuumTheme.thumbnailCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        cardWidth * (ContinuumTheme.thumbnailCardHeight / ContinuumTheme.thumbnailCardWidth)
    }

    #if os(tvOS)
    @FocusState private var standaloneFocused: Bool

    private var isFocused: Bool {
        guard let focusedItemId else { return standaloneFocused }
        return focusedItemId.wrappedValue == item.contentId
    }
    #endif

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 14) {
            thumbnailButton

            if uiCustomization.cardPresentation.caption.showsTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.continuumPosterTitle)
                        .foregroundStyle(
                            isFocused
                                ? Color.continuumOnSurface
                                : Color.continuumOnSurface.opacity(0.85)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: cardWidth, alignment: .leading)
                        .clipped()
                        .animation(.easeOut(duration: 0.15), value: isFocused)

                    if uiCustomization.cardPresentation.caption.showsMetadata,
                       let subtitle = subtitleLine {
                        Text(subtitle)
                            .font(.continuumPosterMetadata)
                            .foregroundStyle(Color.continuumSecondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: cardWidth, alignment: .leading)
                            .clipped()
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: cardWidth)
        .focusSection()
        .onChange(of: item.userState?.played) { _, _ in
            playedOverride = nil
        }
        .task(id: continueWatchingMetadataTaskId) {
            guard onRemoveFromContinueWatching != nil else { return }
            _ = await continueWatchingMetadata.load(item: item)
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
            if usesProvidedTapAction {
                action()
            } else {
                router.pendingZoomSourceID = zoomInstanceID.uuidString
                router.presentItemDetail(
                    contentId: item.contentId,
                    browseSource: detailBrowseSource
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                if uiCustomization.cardPresentation.caption.showsTitle {
                    Text(displayTitle)
                        .font(.continuumSubheadline)
                        .foregroundStyle(Color.continuumOnSurface)
                        .lineLimit(1)
                }
                if uiCustomization.cardPresentation.caption.showsMetadata,
                   let subtitle = subtitleLine {
                    Text(subtitle)
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }
            }
            .zoomTransitionSource(id: zoomInstanceID.uuidString, in: zoomNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
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
                    data: resolvedOverlayData,
                    prefs: overlayStore.prefs,
                    variant: .wide
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
            }

            #if !os(tvOS)
            // Compact touch-layout episode badge. Apple TV landing cards keep
            // this corner clear; server-configured quality/audio overlays above
            // remain unchanged.
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
            #endif

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

    private var resolvedOverlayData: OverlayData {
        #if os(tvOS)
        if onRemoveFromContinueWatching != nil,
           let presentation = continueWatchingMetadata.presentation(for: item.contentId) {
            return presentation.overlayData
        }
        #endif
        return OverlayData.from(item)
    }

    private var continueWatchingMetadataTaskId: String {
        "\(item.contentId)#\(item.progressUpdatedAt ?? "")#\(onRemoveFromContinueWatching != nil)"
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

    private var accessibilityDescription: String {
        var components = [displayTitle]
        if let episodeBadge {
            components.append(episodeBadge)
        }
        if let subtitleLine {
            components.append(subtitleLine)
        }
        if isPlayed {
            components.append("Watched")
        }
        return components.joined(separator: ", ")
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
        .applyEpisodeFocus(
            focusedItemId,
            itemId: item.contentId,
            standaloneBinding: $standaloneFocused
        )
        .scaleEffect(isFocused && !reduceMotion ? 1.025 : 1)
        .shadow(
            color: .black.opacity(isFocused ? 0.5 : 0.2),
            radius: isFocused ? 20 : 8,
            y: isFocused ? 10 : 4
        )
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .applyEpisodePlayPauseAction(playAction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)

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
        (contextPlayTitle != nil && playAction != nil)
            || onOpenContextDetail != nil
            || onSetWatched != nil
            || onRemoveFromContinueWatching != nil
    }

    @ViewBuilder
    private var contextActions: some View {
        if let contextPlayTitle, let playAction {
            Button(action: playAction) {
                Label(contextPlayTitle, systemImage: "play.fill")
            }
        }

        if let contextDetailTitle, let onOpenContextDetail {
            Button(action: onOpenContextDetail) {
                Label(contextDetailTitle, systemImage: "info.circle")
            }
        }

        if let onSetWatched {
            Button {
                let played = !isPlayed
                Task { @MainActor in
                    playedOverride = played
                    let succeeded = await onSetWatched(played)
                    if !succeeded {
                        playedOverride = nil
                    }
                }
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

    /// A card must have one focus binding. Inside a managed row, that binding
    /// is the row's item ID; standalone usage falls back to a local Boolean.
    @ViewBuilder
    func applyEpisodeFocus(
        _ binding: FocusState<String?>.Binding?,
        itemId: String,
        standaloneBinding: FocusState<Bool>.Binding
    ) -> some View {
        if let binding {
            self.focused(binding, equals: itemId)
        } else {
            self.focused(standaloneBinding)
        }
    }
}
#endif
