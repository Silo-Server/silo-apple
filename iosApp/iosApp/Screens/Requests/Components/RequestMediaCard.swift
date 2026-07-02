import SwiftUI

/// Poster card for the requests UI: TMDB artwork, an optional status
/// ribbon, title + year below. A sibling of `MediaCard` rather than a reuse
/// of it — request results have no `contentId`, no watched state, no
/// overlays, and their tap routes by availability, so forcing them through
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
        self.state = RequestDisplayState(
            status: record.status,
            outcome: record.outcome,
            reason: record.lastError
        )
        self.onTap = onTap
    }

    private var width: CGFloat { RequestsUI.cardWidth }

    private var height: CGFloat {
        width * (ContinuumTheme.posterCardHeight / ContinuumTheme.posterCardWidth)
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 22) {
            Button(action: onTap) {
                posterImage
            }
            .buttonStyle(.card)

            caption
        }
        .frame(width: width)
        #else
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                posterImage
                caption
            }
        }
        .buttonStyle(.plain)
        .frame(width: width)
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
        .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
    }

    private var posterPlaceholder: some View {
        ZStack {
            Rectangle().fill(Color.continuumSurfaceElevated)
            Text(title)
                .font(.continuumCaption)
                .fontWeight(.semibold)
                .foregroundColor(.continuumSecondaryText)
                .multilineTextAlignment(.center)
                .padding(12)
        }
        .frame(width: width, height: height)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.continuumSubheadline)
                .foregroundColor(.continuumOnSurface)
                #if os(tvOS)
                .lineLimit(1)
                .truncationMode(.tail)
                #else
                .lineLimit(2, reservesSpace: true)
                #endif

            if let year, year > 0 {
                Text(String(year))
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)
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

extension AppRouter {
    /// The one routing rule for request cards: titles already in the
    /// library open the real item detail; everything else opens the
    /// request detail (including already-requested/blocked cards, so the
    /// user can always see state and reason).
    func openRequestResult(_ result: RequestMediaResult) {
        if result.availability == .available, let contentId = result.libraryContentId {
            navigate(to: .itemDetail(contentId: contentId))
        } else {
            navigate(to: .requestDetail(mediaType: result.mediaType, tmdbId: result.tmdbId))
        }
    }

    /// Same rule for the user's own request records: completed requests
    /// open the real item, everything else opens the request detail.
    func openRequestRecord(_ record: MediaRequest) {
        if let contentId = record.libraryContentId, !contentId.isEmpty {
            navigate(to: .itemDetail(contentId: contentId))
        } else {
            navigate(to: .requestDetail(mediaType: record.mediaType, tmdbId: record.tmdbId))
        }
    }
}
