import SwiftUI

/// A rating as its source's mark and its score: "IMDb 8.5", "RT 93%". Every
/// surface that shows an external score uses this view, so a score never
/// appears without its source.
///
/// The mark is plain text, never a source's logo artwork, except TMDB's
/// approved logo, which TMDB's terms allow (see
/// `ThirdPartyLogos.xcassets/README.md`). The entry inherits the surrounding
/// foreground style; the text mark is dimmed against it.
struct RatingEntryView: View {
    let rating: DisplayRating
    /// Point size of the score. The text mark and the TMDB logo scale from it.
    let size: CGFloat

    /// Asset name of TMDB's "alt short" logo.
    static let tmdbLogoAsset = "TMDBLogo"
    /// SF Pro's cap height as a fraction of its point size. The TMDB logo is
    /// drawn this tall so it matches the score's capitals.
    private static let capHeightRatio: CGFloat = 0.7

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: (size * 0.35).rounded()) {
            mark
            Text(rating.display)
                .font(.system(size: size, weight: .bold).monospacedDigit())
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(rating.accessibilityText))
    }

    @ViewBuilder
    private var mark: some View {
        if rating.isTMDB {
            Image(Self.tmdbLogoAsset)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: size * Self.capHeightRatio)
                // Sit the logo on the score's baseline so it spans the
                // same height as the digits.
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] }
        } else {
            Text(rating.name)
                .font(.system(size: (size * 0.87).rounded(), weight: .semibold))
                .opacity(0.72)
        }
    }
}

/// A wide title page's ratings (iPad, macOS): every entry in server order,
/// wrapping onto another line when they run out of width rather than
/// truncating a score.
struct RatingsRow: View {
    let ratings: [DisplayRating]
    /// Point size of each score.
    let size: CGFloat
    var spacing: CGFloat = 16
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: (size * 0.45).rounded(), alignment: alignment) {
            ForEach(Array(ratings.enumerated()), id: \.offset) { _, rating in
                RatingEntryView(rating: rating, size: size)
            }
        }
    }
}

/// A phone-width title page's ratings: the first `DisplayRating.phoneLimit`
/// entries in server order on one line. It never wraps; when the line is too
/// narrow, entries drop from the end.
struct PhoneRatingsRow: View {
    let ratings: [DisplayRating]
    /// Point size of each score.
    let size: CGFloat
    var spacing: CGFloat = 16

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(DisplayRating.phoneRowCandidates(ratings).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: spacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, rating in
                        RatingEntryView(rating: rating, size: size)
                    }
                }
            }
        }
    }
}
