import SwiftUI

/// Poster card for the requests UI: TMDB artwork, an optional status
/// ribbon, title + year below. A sibling of `MediaCard` rather than a reuse
/// of it — request results have no `contentId`, no watched state, no
/// overlays, and their tap routes by request state, so forcing them through
/// `MediaCard` would bolt unrelated branches onto a heavily-used component.
///
/// Two sources render through the same card: TMDB search/discover results
/// (`RequestMediaResult`) and the user's own request records
/// (`MediaRequest`). Tap routing is owned by the caller via `onTap`; use
/// `AppRouter.openRequestResult(_:)` / `openRequestRecord(_:)` for the
/// standard in-library-vs-request-detail behavior.
struct RequestMediaCard: View {
    let title: String
    let year: Int?
    let posterPath: String?
    let state: RequestDisplayState?
    let onTap: () -> Void
    @State private var uiCustomization = UICustomizationPreferences.shared

    init(result: RequestMediaResult, onTap: @escaping () -> Void) {
        self.title = result.title
        self.year = result.year
        self.posterPath = result.posterPath
        self.state = RequestDisplayState(availability: result.availability, request: result.request)
        self.onTap = onTap
    }

    init(record: MediaRequest, onTap: @escaping () -> Void) {
        self.title = record.title
        self.year = record.year
        self.posterPath = record.posterPath
        self.state = RequestDisplayState(record: record)
        self.onTap = onTap
    }

    private var accessibilityTitle: String {
        var label = title
        if let year, year > 0 { label += ", \(year)" }
        if let state { label += ", \(state.label)" }
        return label
    }

    private var width: CGFloat {
        RequestsUI.cardWidth * uiCustomization.cardPresentation.posterSize.scale
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

            if let state {
                RequestPosterRibbon(state: state)
                    .padding(ribbonInset)
            }
        }
        .frame(width: width, height: height)
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

            if uiCustomization.cardPresentation.caption.showsMetadata, let year, year > 0 {
                Text(String(year))
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var ribbonInset: CGFloat {
        #if os(tvOS)
        14
        #else
        6
        #endif
    }
}

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
    func openRequestResult(_ result: RequestMediaResult) {
        navigate(to: .requestDestination(for: result))
    }

    func openRequestRecord(_ record: MediaRequest) {
        navigate(to: .requestDestination(for: record))
    }
}
