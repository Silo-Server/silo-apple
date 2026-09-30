import SwiftUI

/// Poster card for the requests UI: TMDB artwork with title and a second
/// caption line, in the same grammar as `MediaCard`. A sibling of
/// `MediaCard` rather than a reuse of it — request results have no
/// `contentId`, no watched state, no overlays, and their tap routes by
/// request state, so forcing them through `MediaCard` would bolt unrelated
/// branches onto a heavily-used component.
///
/// Two sources render through the same card: TMDB search/discover results
/// (`RequestMediaResult`) and the user's own request records
/// (`MediaRequest`). A record's second caption line is its status (dot +
/// label); a discovery result keeps its year there and shows a small corner
/// badge only when the title is already requested or in the library. Tap
/// routing is owned by the caller via `onTap`; use
/// `AppRouter.openRequestResult(_:)` / `openRequestRecord(_:)` for the
/// standard in-library-vs-request-detail behavior.
struct RequestMediaCard: View {
    let title: String
    let year: Int?
    let posterPath: String?
    let progress: RequestProgress?
    /// Whether the status is the caption (own requests) or a poster badge
    /// (discovery).
    let showsStatusInCaption: Bool
    let onTap: () -> Void
    #if os(tvOS)
    /// Page-level focus state, when a Skyline page seeds and observes focus
    /// (entry, marquee preview). Movement stays with the focus engine.
    private var focusBinding: FocusState<String?>.Binding?
    private var focusId: String?
    #endif
    /// Overrides `RequestsUI.cardWidth` (Skyline rows use dense posters).
    private var widthOverride: CGFloat?
    @State private var uiCustomization = UICustomizationPreferences.shared

    init(result: RequestMediaResult, onTap: @escaping () -> Void) {
        self.title = result.title
        self.year = result.year
        self.posterPath = result.posterPath
        self.progress = RequestProgress(availability: result.availability, request: result.request)
        self.showsStatusInCaption = false
        self.onTap = onTap
    }

    init(record: MediaRequest, onTap: @escaping () -> Void) {
        self.title = record.title
        self.year = record.year
        self.posterPath = record.posterPath
        self.progress = RequestProgress(record: record)
        self.showsStatusInCaption = true
        self.onTap = onTap
    }

    #if os(tvOS)
    func focused(_ binding: FocusState<String?>.Binding, id: String) -> RequestMediaCard {
        var copy = self
        copy.focusBinding = binding
        copy.focusId = id
        return copy
    }
    #endif

    func cardWidth(_ width: CGFloat) -> RequestMediaCard {
        var copy = self
        copy.widthOverride = width
        return copy
    }

    private var accessibilityTitle: String {
        var label = title
        if let year, year > 0 { label += ", \(year)" }
        if let progress { label += ", \(progress.shortLabel)" }
        return label
    }

    private var width: CGFloat {
        widthOverride ?? RequestsUI.cardWidth * uiCustomization.cardPresentation.posterSize.scale
    }

    private var height: CGFloat {
        width * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 22) {
            Button(action: onTap) {
                posterImage
            }
            .buttonStyle(.card)
            .modifier(OptionalCardFocus(binding: focusBinding, id: focusId))
            // The caption lives outside the button (so the .card style
            // lifts only the poster) — without an explicit label VoiceOver
            // would announce an image-only "Button".
            .accessibilityLabel(accessibilityTitle)

            if uiCustomization.cardPresentation.caption.showsTitle {
                caption
            }
        }
        .frame(width: width)
        #else
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                posterImage
                if uiCustomization.cardPresentation.caption.showsTitle {
                    caption
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        #endif
    }

    private var posterImage: some View {
        ZStack(alignment: .topTrailing) {
            if let url = RequestImageURL.build(posterPath, size: .poster) {
                AsyncImageView(
                    url: url,
                    targetSize: CGSize(width: width, height: height),
                    contentMode: .fill
                )
                .frame(width: width, height: height)
                .clipped()
            } else {
                posterPlaceholder
            }

        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            if !showsStatusInCaption, let progress {
                RequestPosterBadge(state: progress.display)
                    .padding(badgeInset)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
    }

    private var posterPlaceholder: some View {
        ZStack {
            Rectangle().fill(Color.siloSurfaceElevated)
            Text(title)
                .font(.siloCaption)
                .fontWeight(.semibold)
                .foregroundColor(.siloSecondaryText)
                .multilineTextAlignment(.center)
                .padding(12)
        }
        .frame(width: width, height: height)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.siloSubheadline)
                .foregroundColor(.siloOnSurface)
                #if os(tvOS)
                .lineLimit(1)
                .truncationMode(.tail)
                #else
                .lineLimit(2, reservesSpace: true)
                #endif

            if showsStatusInCaption, let progress {
                RequestStatusLabel(progress: progress)
            } else if uiCustomization.cardPresentation.caption.showsMetadata, let year, year > 0 {
                Text(String(year))
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var badgeInset: CGFloat {
        #if os(tvOS)
        14
        #else
        6
        #endif
    }
}

#if os(tvOS)
private struct OptionalCardFocus: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding, let id {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}
#endif

// MARK: - Standard tap routing

extension Route {
    /// The one routing rule for request cards: a card whose chip reads "In
    /// library" opens the real item detail; everything else opens the
    /// request detail, so the user can always see state and reason. That
    /// includes a title in the library with an active request, such as a
    /// series with a request for its missing seasons.
    static func requestDestination(for result: RequestMediaResult) -> Route {
        let state = RequestDisplayState(availability: result.availability, request: result.request)
        if let contentId = state?.libraryItemToOpen(contentId: result.libraryContentId) {
            return .itemDetail(contentId: contentId)
        }
        return .requestDetail(mediaType: result.mediaType, tmdbId: result.tmdbId)
    }

    /// Same rule for the user's own request records.
    static func requestDestination(for record: MediaRequest) -> Route {
        if let contentId = RequestDisplayState(record: record).libraryItemToOpen(contentId: record.libraryContentId) {
            return .itemDetail(contentId: contentId)
        }
        return .requestDetail(mediaType: record.mediaType, tmdbId: record.tmdbId)
    }
}

extension AppRouter {
    @MainActor
    func openRequestResult(_ result: RequestMediaResult) {
        // The card already knows the title and its status: seed the page.
        RequestDetailCache.shared.seed(result)
        RequestDetailCache.shared.unpinModeration(.init(mediaType: result.mediaType, tmdbId: result.tmdbId))
        navigate(to: .requestDestination(for: result))
    }

    /// Opens someone else's request from an approval queue: the detail page
    /// decides on that exact request, not another one for the same title.
    @MainActor
    func openModerationRecord(_ record: MediaRequest) {
        RequestDetailCache.shared.pinModeration(record)
        navigate(to: .requestDestination(for: record))
    }

    @MainActor
    func openRequestRecord(_ record: MediaRequest) {
        RequestDetailCache.shared.unpinModeration(.init(mediaType: record.mediaType, tmdbId: record.tmdbId))
        navigate(to: .requestDestination(for: record))
    }
}
