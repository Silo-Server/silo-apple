#if os(tvOS)
import SwiftUI

/// The "Lounge" audiobook detail. The first screen is the hero — cover,
/// identity, listening state and the action row — with the top of the About
/// section showing beneath it so the page reads as scrollable. Below come
/// About, alternate narrations and the discovery rails
/// (`TVAudiobookDetailSections`). The **Chapters** picker stays behind a
/// full-screen cover.
///
/// Focus: the action row is a flat set of sibling `Button`s so the tvOS focus
/// engine owns movement (native-graph model, per `docs/tvos-focus.md`). Focus
/// opens on the primary action; coming back up from below returns to the
/// action the viewer left. Each section below is one native focus stop or
/// rail, so Down visits them in order and never skips About.
///
/// Scrolling: the page pins the hero to the top while the action row has
/// focus and centers the focused section otherwise (`detailFocusScroll`), so
/// a section's heading is always on screen with its content.
struct TVAudiobookDetailView: View {
    let detail: ItemDetail
    let libraryId: Int?
    let isFavorite: Bool
    let isFinished: Bool
    let onToggleFavorite: () -> Void
    let onToggleFinished: () -> Void
    let onNavigateToItem: (String) -> Void

    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.locale) private var locale

    @Namespace private var pageFocusNamespace
    @FocusState private var focusedAction: Action?
    @FocusState private var focusedSection: TVAudiobookDetailSections.Section?
    /// The action focus returns to when the viewer comes back up from the
    /// sections.
    @State private var lastFocusedAction: Action = .primary
    @State private var showChapters = false
    @State private var didClaimInitialActionFocus = false

    private let heroScrollId = "audiobook-hero"
    /// Tall enough to center the hero's content like a first screen, short
    /// enough that the About heading and its first lines show beneath it.
    /// The loading frame uses it too, so the loaded page does not jump.
    static let heroHeight: CGFloat = 860

    private enum Action: Hashable { case primary, chapters, startOver, favorite, finished }

    /// Stored, not computed: the model stitches the whole part/chapter
    /// timeline in its init, so building it per access would redo that work
    /// for every `model.` read in `body`.
    private let model: TVAudiobookViewModel

    init(
        detail: ItemDetail,
        libraryId: Int? = nil,
        isFavorite: Bool,
        isFinished: Bool,
        onToggleFavorite: @escaping () -> Void,
        onToggleFinished: @escaping () -> Void,
        onNavigateToItem: @escaping (String) -> Void
    ) {
        self.detail = detail
        self.libraryId = libraryId
        self.isFavorite = isFavorite
        self.isFinished = isFinished
        self.onToggleFavorite = onToggleFavorite
        self.onToggleFinished = onToggleFinished
        self.onNavigateToItem = onNavigateToItem
        self.model = TVAudiobookViewModel(detail: detail)
    }

    var body: some View {
        ZStack {
            background
            scrollBody
        }
        .siloBackground()
        .fullScreenCover(isPresented: $showChapters) {
            TVAudiobookChaptersView(detail: detail, libraryId: libraryId)
        }
    }

    private var scrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // The hero is one focus section: its only focusable
                    // content (the action row) sits right of the cover, so
                    // without the section, Up from a far-left rail card finds
                    // no candidate in its horizontal band and the press dies.
                    content
                        .frame(height: Self.heroHeight)
                        .focusSection()
                        // Re-entry from below lands on the action the viewer
                        // left, or on the primary action when that one is
                        // gone (Chapters and Start Over come and go with the
                        // book's state).
                        .defaultFocus($focusedAction, reentryAction, priority: .userInitiated)
                        .id(heroScrollId)

                    if TVAudiobookDetailSections.hasContent(detail) {
                        TVAudiobookDetailSections(
                            detail: detail,
                            focusedSection: $focusedSection,
                            onNavigateToItem: onNavigateToItem
                        )
                        .padding(.horizontal, SiloTheme.safePadding)
                        .padding(.bottom, TVDetailLayout.pageBottomPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { sectionsBackdrop }
                    }
                }
            }
            .ignoresSafeArea()
            // The page opens on the primary action. Without this the engine
            // can pick the About block, which also shows on the first screen.
            .focusScope(pageFocusNamespace)
            .defaultFocus($focusedAction, .primary, priority: .userInitiated)
            .detailFocusScroll(
                proxy: proxy,
                actionRowFocused: focusedAction != nil,
                heroId: heroScrollId,
                focusedPosterRailId: focusedSection?.rawValue
            )
        }
    }

    /// Scrolls with the sections: a short clear→black ramp above them, then
    /// solid near-black extended well past the bottom edge so overscroll
    /// never exposes the brighter wash. Keeps the below-fold body legible the
    /// same way the other detail pages read over the near-black app
    /// background, without touching the hero's first-viewport look.
    private var sectionsBackdrop: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)
            Color.black.opacity(0.88)
        }
        .padding(.top, -220)
        .padding(.bottom, -600)
    }

    // MARK: - Background

    private var background: some View {
        TVAudiobookBackdrop(posterUrl: detail.posterUrl, thumbhash: detail.posterThumbhash)
            .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        HStack(spacing: 84) {
            cover
            identity
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SiloTheme.safePadding)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cover: some View {
        AsyncImageView(
            url: detail.posterUrl ?? "",
            thumbhash: detail.posterThumbhash,
            targetSize: CGSize(width: 460, height: 460),
            contentMode: .fill,
            placeholderStyle: .artwork,
            placeholderSymbol: ArtworkPlaceholderSymbol.audiobook
        )
        .frame(width: 460, height: 460)
        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 40, x: 0, y: 24)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow

            Text(model.title)
                .font(.system(size: 84, weight: .bold))
                .tracking(-1.0)
                .lineLimit(2)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            if let series = model.seriesLine {
                Text(series.uppercased())
                    .font(.system(size: 22, weight: .bold))
                    .tracking(4)
                    .foregroundColor(TVAudiobookStyle.gold)
                    .padding(.top, 14)
            }

            if let credits = model.credits {
                creditsText(credits)
                    .padding(.top, 18)
            }

            stateCluster
                .padding(.top, 50)

            actionRow
                .padding(.top, 50)
        }
        .frame(maxWidth: 1040, alignment: .leading)
    }

    private var eyebrow: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 34, height: 4)
                .cornerRadius(2)
            Text(model.eyebrow)
                .font(.system(size: 19, weight: .bold))
                .tracking(3)
                .foregroundColor(.white.opacity(0.8))
        }
    }

    /// "by **Author** · read by **Narrator**" — names semibold white,
    /// connectives quiet. One catalog message, with the names restyled in
    /// place, so it wraps as one paragraph and translations can reorder it.
    private func creditsText(_ credits: TVAudiobookViewModel.Credits) -> Text {
        let message: LocalizedStringResource
        switch (credits.author, credits.narrator) {
        case let (.some(author), .some(narrator)):
            message = .detailAudiobookByAuthorReadBy(author, narrator)
        case let (.some(author), .none):
            message = .detailAudiobookByAuthor(author)
        case let (.none, .some(narrator)):
            message = .detailAudiobookReadBy(narrator)
        case (.none, .none):
            return Text(verbatim: "")
        }
        var line = AttributedString(AppLanguage.string(message, locale: locale))
        line.font = .system(size: 29)
        line.foregroundColor = Color.white.opacity(0.72)
        // Every occurrence: an author who narrates appears twice.
        for name in Set([credits.author, credits.narrator].compactMap({ $0 })) where !name.isEmpty {
            var start = line.startIndex
            while let range = line[start...].range(of: name) {
                line[range].font = .system(size: 29, weight: .semibold)
                line[range].foregroundColor = .white
                start = range.upperBound
            }
        }
        return Text(line)
    }

    // MARK: - State cluster

    @ViewBuilder
    private var stateCluster: some View {
        switch model.state {
        case let .inProgress(fraction, percent, line1, line2):
            HStack(spacing: 22) {
                progressRing(fraction: fraction, label: LocaleFormat.percent(percent))
                stateLines(line1, line2)
            }
        case let .notStarted(line1, line2):
            stateLines(line1, line2)
        case let .finished(line1, line2):
            HStack(spacing: 22) {
                progressRing(fraction: 1, label: "100%")
                stateLines(line1, line2)
            }
        }
    }

    private func stateLines(_ line1: String, _ line2: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(line1)
                .font(.system(size: 29, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let line2 {
                Text(line2)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private func progressRing(fraction: Double, label: String) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 88, height: 88)
    }

    // MARK: - Actions

    private var actionRow: some View {
        // Every control keeps its size on focus, as on the movie and series
        // pages: Play stays labeled and no pill scales, so moving along the
        // row never reflows it under the pill gaining focus.
        HStack(spacing: 18) {
            TVPrimaryPillButton(
                icon: model.primaryIcon,
                title: AppLanguage.string(model.primaryLabel, locale: locale),
                stabilizesFocusMotion: true
            ) {
                model.performPrimary(audioStore, libraryId: libraryId)
            }
            .focused($focusedAction, equals: .primary)
            .onAppear(perform: claimInitialActionFocus)

            if model.showsChapters {
                TVSecondaryPillButton(
                    icon: "list.bullet",
                    title: AppLanguage.string(.detailAudiobookChapters, locale: locale),
                    stabilizesFocusMotion: true
                ) {
                    showChapters = true
                }
                .focused($focusedAction, equals: .chapters)
            }

            // Only with progress to discard: before the first listen Play
            // starts at the beginning, and after the last Play Again does.
            if model.resumePosition != nil {
                TVSecondaryPillButton(
                    icon: "arrow.counterclockwise",
                    title: AppLanguage.string(.detailStartOver, locale: locale),
                    stabilizesFocusMotion: true
                ) {
                    audioStore.play(contentId: detail.contentId, restart: true, libraryId: libraryId)
                }
                .focused($focusedAction, equals: .startOver)
            }

            // Same circle toggles as the movie/series action rows, with the
            // iOS audiobook labels; the filled icon carries the state. The
            // page's view model sends the change and the detail host shows
            // its failure alert.
            TVCircleActionButton(
                icon: "heart",
                iconActive: "heart.fill",
                isActive: isFavorite,
                title: AppLanguage.string(.detailFavorite, locale: locale),
                accessibilityLabel: AppLanguage.string(
                    isFavorite ? .detailMoreRemoveFavorite : .detailMoreAddFavorite,
                    locale: locale
                ),
                stabilizesFocusMotion: true,
                action: onToggleFavorite
            )
            .focused($focusedAction, equals: .favorite)

            TVCircleActionButton(
                icon: "checkmark.circle",
                iconActive: "checkmark.circle.fill",
                isActive: isFinished,
                title: AppLanguage.string(.detailAudiobookFinished, locale: locale),
                accessibilityLabel: AppLanguage.string(
                    isFinished ? .detailAudiobookMarkNotFinished : .detailAudiobookMarkFinished,
                    locale: locale
                ),
                stabilizesFocusMotion: true,
                action: onToggleFinished
            )
            .focused($focusedAction, equals: .finished)
        }
        .onChange(of: focusedAction) { _, action in
            if let action { lastFocusedAction = action }
        }
    }

    private var reentryAction: Action {
        switch lastFocusedAction {
        case .chapters where !model.showsChapters: .primary
        case .startOver where model.resumePosition == nil: .primary
        default: lastFocusedAction
        }
    }

    private func claimInitialActionFocus() {
        guard !didClaimInitialActionFocus else { return }
        didClaimInitialActionFocus = true
        focusedAction = .primary
    }
}

/// Quiet cover-tinted wash: the square art blurred and dimmed under a dark
/// teal radial glow and a fade to near-black (mockup `.oc-bd`). Shared with
/// the loading frame so the loaded page replaces it without a jump.
struct TVAudiobookBackdrop: View {
    let posterUrl: String?
    let thumbhash: String?

    var body: some View {
        ZStack {
            if let posterUrl, !posterUrl.isEmpty {
                // The square art fills the space it is offered and no more.
                // A flexible frame around it grew to the art's square (1760pt
                // tall on a 1080pt screen) and stretched the whole page with it.
                Color.clear
                    .overlay {
                        AsyncImageView(
                            url: posterUrl,
                            thumbhash: thumbhash,
                            targetSize: CGSize(width: 600, height: 600),
                            contentMode: .fill
                        )
                    }
                    .clipped()
                    .blur(radius: 70)
                    .opacity(0.35)
            }
            RadialGradient(
                colors: [Color(red: 0.07, green: 0.25, blue: 0.235).opacity(0.9), .clear],
                center: UnitPoint(x: 0.22, y: 0.4),
                startRadius: 0,
                endRadius: 1200
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.96),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
#endif
