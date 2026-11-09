#if os(macOS)
import SwiftUI

/// Hero for a Home section the server marks as featured, laid out like the
/// web app's `HeroBanner`.
///
/// The current title fills the backdrop with its metadata, synopsis, and
/// primary actions. A counter and progress rail in the trailing corner show
/// where the slideshow is; arrows at the edges appear while the pointer is
/// over the hero. The hero advances on its own and pauses under the pointer
/// or from its pause button.
struct MacFeaturedHero: View {
    let section: ResolvedSection

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var index = 0
    @State private var isHovering = false
    /// The viewer paused the slideshow with its pause button.
    @State private var isUserPaused = false
    /// How long the current title has been on show while the slideshow ran.
    @State private var clock = SlideClock()
    /// The logo that has finished loading. Until a title's logo is in, its
    /// name is shown as text, so the hero is never untitled.
    @State private var loadedLogoURL: String?
    private var translation: CardDescriptionTranslation { .shared }

    private struct TranslationTrigger: Hashable {
        let contentId: String
        let language: String?
        let mode: MetadataAIStatus.OnViewMode
    }

    private var item: SectionItem? {
        guard !section.items.isEmpty else { return nil }
        return section.items[min(index, section.items.count - 1)]
    }

    private var hasSeveralTitles: Bool { section.items.count > 1 }

    var body: some View {
        if let item {
            ZStack(alignment: .bottomLeading) {
                backdrop(for: item)
                scrim
                details(for: item)
                    .padding(.bottom, SiloTheme.macHeroContentBottomPadding)
            }
            .overlay(alignment: .bottomTrailing) {
                if hasSeveralTitles {
                    slideIndicator
                        .padding(.trailing, SiloTheme.macHeroIndicatorInset)
                        .padding(.bottom, SiloTheme.macHeroIndicatorBottomInset)
                }
            }
            .overlay {
                if hasSeveralTitles {
                    pagingArrows
                }
            }
            .frame(maxWidth: .infinity)
            // A share of the window, so the rows below stay in view.
            .containerRelativeFrame(.vertical) { length, _ in
                SiloTheme.macHeroHeight(forWindowHeight: length)
            }
            .clipped()
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: SiloTheme.normalDuration), value: isHovering)
            .task(id: AdvanceTrigger(index: index, isPaused: isPaused, ids: section.items.map(\.contentId))) {
                await runSlideTimer()
            }
            // Back on Home, the title on show gets its full time again. The
            // pointer may have left while the page was covered.
            .onDisappear {
                clock.restart(at: .now, running: false)
                isHovering = false
            }
            // Only the slide on show translates on view; the others wait
            // until they come up.
            .task(id: TranslationTrigger(
                contentId: item.contentId,
                language: translatablePresentation(for: item)?.pendingLanguage,
                mode: AICapabilities.shared.metadataOnView
            )) {
                translation.cardDidAppear(
                    contentId: item.contentId,
                    pendingLanguage: translatablePresentation(for: item)?.pendingLanguage,
                    libraryId: nil
                )
            }
            .onChange(of: section.items.map(\.contentId)) { _, ids in
                // A reload can shorten the section; keep the counter on a
                // title that still exists.
                if index >= ids.count { show(max(0, ids.count - 1)) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Featured")
        }
    }

    // MARK: - Layers

    /// The current title's artwork. A new title cross-fades in over the old
    /// one, as on web; the text beside it changes at once.
    private func backdrop(for item: SectionItem) -> some View {
        ZStack {
            Color.siloSurfaceElevated
            artwork(for: item)
                // Web dims the backdrop to 90% brightness.
                .overlay(Color.black.opacity(0.1))
                .id(item.contentId)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: SiloTheme.macHeroCrossFadeSeconds), value: item.contentId)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artwork(for item: SectionItem) -> some View {
        if let seriesBackdrop = item.episodeSeriesBackdrop {
            // An episode's own backdrop is usually a small still; its series
            // backdrop fills the hero and is never a spoiler.
            AsyncImageView(url: seriesBackdrop.url, thumbhash: seriesBackdrop.thumbhash, contentMode: .fill)
        } else if let url = item.backdropUrl?.nonEmpty ?? item.posterUrl?.nonEmpty {
            // An empty URL is no artwork: fall back as for a missing one.
            let backdropURL = item.backdropUrl?.nonEmpty
            AsyncImageView(
                url: url,
                thumbhash: backdropURL == nil ? item.posterThumbhash : item.backdropThumbhash,
                contentMode: .fill
            )
            .episodeSpoilerBlur(EpisodeSpoilerPreferences.shared.settings.hidesImage(for: item))
        } else {
            Color.siloSurfaceElevated
        }
    }

    /// Web's two scrims: the artwork fades into the page canvas from the
    /// bottom, under the rows, and from the leading edge, under the text.
    private var scrim: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .siloPageCanvas, location: 0),
                    .init(color: Color.siloPageCanvas.opacity(0.88), location: 0.12),
                    .init(color: Color.siloPageCanvas.opacity(0.48), location: 0.30),
                    .init(color: Color.siloPageCanvas.opacity(0.12), location: 0.50),
                    .init(color: .clear, location: 0.66),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            LinearGradient(
                stops: [
                    .init(color: Color.siloPageCanvas.opacity(0.88), location: 0),
                    .init(color: Color.siloPageCanvas.opacity(0.58), location: 0.16),
                    .init(color: Color.siloPageCanvas.opacity(0.22), location: 0.34),
                    .init(color: .clear, location: 0.50),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func details(for item: SectionItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
                .padding(.bottom, SiloTheme.padding)

            title(for: item)
                .padding(.bottom, SiloTheme.padding)

            if let metadata = Self.metadata(for: item) {
                // On a slide change the old and new lines crossfade in place,
                // so the rating doesn't slide sideways, and the ZStack keeps
                // the line moving with the title and overview around it.
                ZStack(alignment: .leading) {
                    metadataLine(metadata)
                        .id(item.contentId)
                        .transition(.opacity)
                }
                .padding(.bottom, SiloTheme.largePadding)
            }

            overview(for: item)

            HStack(spacing: SiloTheme.spacing) {
                // A series has nothing to play directly; More Info opens it.
                if SiloMediaType.isDirectlyPlayable(item.type) {
                    Button { play(item) } label: {
                        MacHeroPill(title: "Play", systemImage: "play.fill", isProminent: true)
                    }
                }
                Button { openDetail(item) } label: {
                    MacHeroPill(title: "More Info", systemImage: "info.circle", isProminent: false)
                }
            }
            .buttonStyle(.siloFlat)
        }
        .frame(maxWidth: SiloTheme.macHeroTextWidth, alignment: .leading)
        .padding(.leading, HomeFeedMetrics.gutter)
        .padding(.trailing, SiloTheme.macHeroIndicatorInset)
    }

    /// "FEATURED — NO. 03"
    private var eyebrow: some View {
        Text("\(Text("Featured").foregroundStyle(Color.white.opacity(0.92)))\(Text("  —  ").foregroundStyle(Color.white.opacity(0.45)))No. \(Self.twoDigit(index + 1))")
            .font(.system(size: 11.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(2.5)
            .foregroundStyle(Color.white.opacity(0.62))
            .accessibilityLabel("Featured, \(index + 1) of \(section.items.count)")
    }

    /// The synopsis, with its on-view translation status and, in the
    /// server's `button` mode, a Translate chip.
    @ViewBuilder
    private func overview(for item: SectionItem) -> some View {
        if let presentation = translatablePresentation(for: item),
           let overview = presentation.overview, !overview.isEmpty {
            let offersTranslation = translation.offersTranslation(
                contentId: item.contentId,
                pendingLanguage: presentation.pendingLanguage
            )
            VStack(alignment: .leading, spacing: SiloTheme.smallPadding) {
                Text(overview)
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.72))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: SiloTheme.macHeroOverviewWidth, alignment: .leading)
                    .opacity(presentation.status == .translating ? 0.5 : 1)
                if presentation.status != nil || offersTranslation {
                    HStack(spacing: SiloTheme.spacing) {
                        if let status = presentation.status {
                            DescriptionTranslationStatusLabel(status: status)
                        }
                        if offersTranslation {
                            Button {
                                translation.translate(
                                    contentId: item.contentId,
                                    pendingLanguage: presentation.pendingLanguage,
                                    libraryId: nil
                                )
                            } label: {
                                Label("Translate", systemImage: MachineTranslation.symbol)
                                    .font(.siloCaption)
                                    .foregroundStyle(Color.siloSecondaryText)
                                    .padding(.horizontal, SiloTheme.spacing)
                                    .padding(.vertical, 2)
                                    .overlay(Capsule().stroke(Color.siloChromeSelectedBorder))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.siloFlat)
                        }
                    }
                }
            }
            .padding(.bottom, SiloTheme.macHeroOverviewBottomPadding)
        }
    }

    /// The slide's description and its translation state, or nil while
    /// spoiler protection hides an unwatched episode's description: a
    /// translation must neither show it nor start for it.
    private func translatablePresentation(for item: SectionItem) -> CardDescriptionTranslation.Presentation? {
        guard !EpisodeSpoilerPreferences.shared.settings.hidesOverview(for: item) else { return nil }
        return translation.presentation(for: item)
    }

    /// The title's logo artwork where the server has one and the profile shows
    /// title art, otherwise its name.
    @ViewBuilder
    private func title(for item: SectionItem) -> some View {
        let name = Text(item.title)
            .font(.system(size: SiloTheme.macHeroTitleSize, weight: .heavy))
            .tracking(-1.5)
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.45), radius: 25, y: 18)

        // A profile that turned title art off (`ui.title_art`) gets the name.
        if TitleArtPreferences.shared.showsTitleArt,
           let logoURL = item.logoUrl, !logoURL.isEmpty {
            let isLoaded = loadedLogoURL == logoURL
            ZStack(alignment: .bottomLeading) {
                name.opacity(isLoaded ? 0 : 1)
                MacTitleLogo(url: logoURL, size: Self.logoSize) {
                    loadedLogoURL = logoURL
                }
                .opacity(isLoaded ? 1 : 0)
                .id(logoURL)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isHeader)
        } else {
            name.accessibilityAddTraits(.isHeader)
        }
    }

    private static var logoSize: CGSize {
        CGSize(width: SiloTheme.macHeroLogoWidth, height: SiloTheme.macHeroLogoHeight)
    }

    // MARK: - Slideshow controls

    /// "01 ──── 05", the progress rail, and the pause button.
    private var slideIndicator: some View {
        HStack(spacing: SiloTheme.spacing) {
            HStack(spacing: SiloTheme.spacing) {
                Text(Self.twoDigit(index + 1))
                    .foregroundStyle(Color.white)
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 40, height: 1)
                Text(Self.twoDigit(section.items.count))
                    .foregroundStyle(Color.white.opacity(0.68))
            }
            .font(.system(size: 11, design: .monospaced))
            .tracking(1.3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Title \(index + 1) of \(section.items.count)")

            if advancesAutomatically {
                progressRail
                MacHeroIconButton(
                    systemImage: isUserPaused ? "play.fill" : "pause.fill",
                    help: isUserPaused ? "Resume slideshow" : "Pause slideshow",
                    size: SiloTheme.macHeroPauseButtonSize
                ) {
                    isUserPaused.toggle()
                }
            }
        }
    }

    /// Fills over the time a title stays up, and holds while paused.
    private var progressRail: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            let progress = min(1, clock.elapsed(at: context.date) / SiloTheme.macHeroAdvanceSeconds)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: SiloTheme.macHeroProgressRailWidth * progress)
            }
        }
        .frame(width: SiloTheme.macHeroProgressRailWidth, height: 2)
        .accessibilityHidden(true)
    }

    /// Previous and next, at the hero's edges, shown while the pointer is
    /// over it.
    private var pagingArrows: some View {
        HStack {
            MacHeroIconButton(
                systemImage: "chevron.left",
                help: "Previous featured title",
                size: SiloTheme.macHeroArrowSize,
                isGlass: true
            ) { step(-1) }
            Spacer()
            MacHeroIconButton(
                systemImage: "chevron.right",
                help: "Next featured title",
                size: SiloTheme.macHeroArrowSize,
                isGlass: true
            ) { step(1) }
        }
        .padding(.horizontal, SiloTheme.largePadding)
        .opacity(isHovering ? 0.9 : 0)
        .allowsHitTesting(isHovering)
    }

    // MARK: - Behaviour

    private struct AdvanceTrigger: Equatable {
        let index: Int
        let isPaused: Bool
        /// Any change to the section's titles restarts the timer, so a
        /// pending advance never acts on titles that have been replaced,
        /// and a section that grows from one title starts advancing.
        let ids: [String]
    }

    /// Reduce Motion and VoiceOver turn the slideshow off: the title must
    /// not change under someone reading it.
    private var advancesAutomatically: Bool {
        hasSeveralTitles && !reduceMotion && !voiceOverEnabled
    }

    /// The slideshow holds under the pointer and from the pause button.
    private var isPaused: Bool {
        !advancesAutomatically || isHovering || isUserPaused
    }

    private func runSlideTimer() async {
        let now = Date.now
        guard !isPaused else {
            clock.pause(at: now)
            return
        }
        clock.resume(at: now)
        let remaining = max(0, SiloTheme.macHeroAdvanceSeconds - clock.elapsed(at: now))
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        step(1)
    }

    private func step(_ delta: Int) {
        let count = section.items.count
        guard count > 1 else { return }
        show((index + delta + count) % count)
    }

    /// Brings a title up and starts its time on show from zero.
    private func show(_ newIndex: Int) {
        index = newIndex
        clock.restart(at: .now, running: !isPaused)
    }

    private func play(_ item: SectionItem) {
        router.presentPlayer(
            contentId: item.contentId,
            resumePosition: item.positionSeconds,
            // Resume sections reopen the version last watched, as their
            // cards do when the section is drawn as a row.
            prefersLastUsedVersion: HomeFeed.isResume(section),
            posterURL: item.posterUrl,
            backdropURL: item.backdropUrl
        )
    }

    /// The facts line, separated by dimmed middle dots as on web. The rating
    /// is drawn as its source's mark and score and keeps its full width; the
    /// text truncates.
    private func metadataLine(_ metadata: Metadata) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let rating = metadata.rating {
                if !metadata.lead.isEmpty {
                    Text("\(Self.factsText(metadata.lead))\(Self.factSeparator)") // i18n-ignore: joins two Text values
                }
                RatingEntryView(rating: rating, size: 13)
                if !metadata.trailing.isEmpty {
                    Text("\(Self.factSeparator)\(Self.factsText(metadata.trailing))") // i18n-ignore: joins two Text values
                }
            } else {
                Self.factsText(metadata.lead + metadata.trailing)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .tracking(0.25)
        .foregroundStyle(Color.white.opacity(0.85))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private static let factSeparator = Text(verbatim: "  ·  ").foregroundStyle(Color.white.opacity(0.55))

    private static func factsText(_ parts: [String]) -> Text {
        parts.dropFirst().reduce(Text(verbatim: parts.first ?? "")) { text, part in
            Text("\(text)\(factSeparator)\(Text(verbatim: part))") // i18n-ignore: joins Text values
        }
    }

    private func openDetail(_ item: SectionItem) {
        let route = Route.itemDetail(destinationContentId: item.contentId, sectionItem: item)
        if case .itemDetail(let contentId, _, _, _) = route {
            DetailSeedStore.offer(.section(item), opening: contentId)
        }
        router.navigate(to: route)
    }

    // MARK: - Formatting

    static func twoDigit(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// "2015 · 2h 1m · IMDb 8.1 · Action · Adventure · R", split around the
    /// rating so it can be drawn as its source's mark and score.
    private struct Metadata {
        let lead: [String]
        let rating: DisplayRating?
        let trailing: [String]
    }

    /// The facts line's parts, skipping whatever the item does not carry.
    /// Episodes show no rating.
    private static func metadata(for item: SectionItem) -> Metadata? {
        var lead: [String] = []
        if let year = item.year { lead.append(LocaleFormat.integer(year)) }
        if let runtime = MediaTextFormatting.runtime(minutes: item.runtime) { lead.append(runtime) }
        let rating = item.isEpisodeItem
            ? nil
            : DisplayRating.primaryCard(imdb: item.ratingImdb, tmdb: item.ratingTmdb)
        var trailing = Array((item.genres ?? []).prefix(2))
        if let contentRating = item.contentRating, !contentRating.isEmpty {
            trailing.append(contentRating.uppercased())
        }
        guard !lead.isEmpty || rating != nil || !trailing.isEmpty else { return nil }
        return Metadata(lead: lead, rating: rating, trailing: trailing)
    }
}

/// Time a slide has been on show, counting only while the slideshow runs.
private struct SlideClock {
    private var banked: TimeInterval = 0
    private var runningSince: Date?

    func elapsed(at date: Date) -> TimeInterval {
        banked + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    mutating func pause(at date: Date) {
        banked = elapsed(at: date)
        runningSince = nil
    }

    mutating func resume(at date: Date) {
        if runningSince == nil { runningSince = date }
    }

    mutating func restart(at date: Date, running: Bool) {
        banked = 0
        runningSince = running ? date : nil
    }
}

/// Web's hero pills: a solid Play and a glass More Info.
private struct MacHeroPill: View {
    let title: String
    let systemImage: String
    let isProminent: Bool

    @State private var isHovering = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13.5, weight: .bold))
            .tracking(0.15)
            .foregroundStyle(isProminent ? Color.siloBackground : Color.siloOnSurface)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background {
                if isProminent {
                    Capsule()
                        .fill(Color.siloPrimary)
                        .brightness(isHovering ? -0.04 : 0)
                        .shadow(color: Color.siloPrimary.opacity(0.25), radius: 14, y: 10)
                } else {
                    Capsule()
                        .fill(Color.white.opacity(isHovering ? 0.18 : 0.12))
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14)))
                }
            }
            .offset(y: isProminent && isHovering ? -1 : 0)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isHovering)
    }
}

/// A round icon button for the slideshow: the pause button and, with
/// `isGlass`, the paging arrows.
private struct MacHeroIconButton: View {
    let systemImage: String
    let help: String
    let size: CGFloat
    var isGlass = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * (isGlass ? 0.44 : 0.5), weight: .semibold))
                .foregroundStyle(Color.white.opacity(isGlass || isHovering ? 1 : 0.7))
                .frame(width: size, height: size)
                .background {
                    if isGlass {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().stroke(Color.white.opacity(0.18)))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.siloFlat)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
