#if os(tvOS)
import SwiftUI

/// The "Lounge" audiobook detail. The first viewport is the hero — cover +
/// identity + state cluster + action row, vertically centered, answering
/// "what is this and where am I" with a single golden-path press (Resume).
/// Below the fold the page scrolls into About, alternate narrations, and the
/// discovery rails (`TVAudiobookDetailSections`), like the movie/series
/// detail bodies. The **Chapters** picker stays behind a full-screen cover.
///
/// Focus: the action row is a flat set of sibling `Button`s so the tvOS focus
/// engine owns movement (native-graph model, per `docs/tvos-focus.md`). We
/// seed initial focus onto Resume with `@FocusState` + `defaultFocus` because
/// geometry would otherwise pick the (higher) first control inconsistently.
/// Below-fold rows/rails are ordinary vertical focus progression.
struct TVAudiobookDetailView: View {
    let detail: ItemDetail
    let onNavigateToItem: (String) -> Void

    @Environment(AudioPlaybackStore.self) private var audioStore

    @FocusState private var focusedAction: Action?
    @State private var showChapters = false
    @State private var didClaimInitialActionFocus = false

    private enum Action: Hashable { case primary, chapters, startOver }

    /// Stored, not computed: the model stitches the whole part/chapter
    /// timeline in its init, so building it per access would redo that work
    /// for every `model.` read in `body`.
    private let model: TVAudiobookViewModel

    init(detail: ItemDetail, onNavigateToItem: @escaping (String) -> Void) {
        self.detail = detail
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
            TVAudiobookChaptersView(detail: detail)
        }
    }

    /// Hero sized to the full viewport (so the initial screen reads exactly
    /// like the old fixed page) with the info sections below the fold. The
    /// blurred-cover background stays fixed behind the scroll; the sections
    /// carry their own near-black backdrop so they stay legible as they ride
    /// up over the brighter hero region of the wash.
    private var scrollBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // The whole hero viewport is one focus section: its only
                // focusable content (the action row) sits right of the 460pt
                // cover, so without the section, Up from a far-left rail card
                // below the fold finds no candidate in its horizontal band and
                // the press dies. The section spans full width and redirects
                // entry to the nearest button — same reachability trick as
                // TVDetailHero's full-width action cluster.
                content
                    .containerRelativeFrame(.vertical)
                    .focusSection()

                if TVAudiobookDetailSections.hasContent(detail) {
                    TVAudiobookDetailSections(
                        detail: detail,
                        onNavigateToItem: onNavigateToItem
                    )
                    .padding(.horizontal, SiloTheme.safePadding)
                    .padding(.top, 64)
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { sectionsBackdrop }
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Scrolls with the sections: a short clear→black ramp at the fold, then
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
            .frame(height: 280)
            Color.black.opacity(0.88)
        }
        .padding(.top, -280)
        .padding(.bottom, -600)
    }

    // MARK: - Background

    /// A quiet cover-tinted wash: the square art blurred hard and dimmed,
    /// under a dark teal radial glow and a fade to near-black — much calmer
    /// than the old bright 760pt blur, matching the mockup's `.oc-bd`.
    private var background: some View {
        ZStack {
            if let url = detail.posterUrl, !url.isEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: detail.posterThumbhash,
                    targetSize: CGSize(width: 600, height: 600),
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Group {
            if let url = detail.posterUrl, !url.isEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: detail.posterThumbhash,
                    targetSize: CGSize(width: 460, height: 460),
                    contentMode: .fill
                )
            } else {
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                    .fill(Color.siloSurfaceElevated)
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: 460 * 0.22, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
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
    /// connectives quiet. Built as a concatenated `Text` so it wraps as one
    /// paragraph rather than a stack.
    private func creditsText(_ credits: TVAudiobookViewModel.Credits) -> Text {
        var line = Text("")
        if let author = credits.author {
            line = line
                + Text("by ").foregroundColor(.white.opacity(0.72))
                + Text(author).fontWeight(.semibold).foregroundColor(.white)
        }
        if let narrator = credits.narrator {
            if credits.author != nil {
                line = line + Text("  ·  ").foregroundColor(.white.opacity(0.72))
            }
            line = line
                + Text("read by ").foregroundColor(.white.opacity(0.72))
                + Text(narrator).fontWeight(.semibold).foregroundColor(.white)
        }
        return line.font(.system(size: 29))
    }

    // MARK: - State cluster

    @ViewBuilder
    private var stateCluster: some View {
        switch model.state {
        case let .inProgress(fraction, percent, line1, line2):
            HStack(spacing: 22) {
                progressRing(fraction: fraction, label: "\(percent)%")
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
        HStack(spacing: 24) {
            TVPrimaryPillButton(
                icon: model.primaryIcon,
                title: model.primaryLabel
            ) {
                model.performPrimary(audioStore)
            }
            .focused($focusedAction, equals: .primary)
            .onAppear(perform: claimInitialActionFocus)

            if model.showsChapters {
                TVSecondaryPillButton(icon: "list.bullet", title: "Chapters") {
                    showChapters = true
                }
                .focused($focusedAction, equals: .chapters)
            }

            TVSecondaryPillButton(icon: "arrow.counterclockwise", title: "Start Over") {
                audioStore.play(contentId: detail.contentId, restart: true)
            }
            .focused($focusedAction, equals: .startOver)
        }
        .defaultFocus($focusedAction, .primary)
    }

    private func claimInitialActionFocus() {
        guard !didClaimInitialActionFocus else { return }
        didClaimInitialActionFocus = true
        focusedAction = .primary
    }
}
#endif
