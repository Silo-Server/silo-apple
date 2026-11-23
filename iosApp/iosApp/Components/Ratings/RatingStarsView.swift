import SwiftUI

/// Five stars showing a rating: an outline track with the accent fill
/// clipped to full, half or none per star. Display only, with no gestures,
/// and hidden from accessibility; the control around it carries the label
/// and value. Right to left, the first star is on the right and each half
/// star fills from its leading (right) side.
struct RatingStarsView: View {
    let score: RatingScore
    let starSize: CGFloat
    let spacing: CGFloat

    /// `score` is on the server's 1...10 scale (nil and 0 show no stars).
    /// `spacing` defaults to an eighth of `starSize`, the design's 32pt
    /// stars in 36pt cells.
    init(score: Int?, starSize: CGFloat, spacing: CGFloat? = nil) {
        self.init(score: RatingScore(server: score), starSize: starSize, spacing: spacing)
    }

    init(score: RatingScore, starSize: CGFloat, spacing: CGFloat? = nil) {
        self.score = score
        self.starSize = starSize
        self.spacing = spacing ?? starSize / 8
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<RatingScore.starCount, id: \.self) { index in
                RatingStarView(fill: score.fill(ofStar: index), size: starSize)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One star of `RatingStarsView`, also usable alone (the chip's star, the
/// tvOS star button).
struct RatingStarView: View {
    let fill: RatingStarFill
    let size: CGFloat
    var outline: Color = .siloRatingStarOutline
    var accent: Color = .siloRatingStar

    var body: some View {
        // The design's stroke is 1.6 of the star's 24-unit box.
        let style = StrokeStyle(lineWidth: size * 1.6 / 24, lineJoin: .round)
        ZStack(alignment: .leading) {
            RatingStarShape().stroke(outline, style: style)
            if fill != .empty {
                ZStack {
                    RatingStarShape().fill(accent)
                    RatingStarShape().stroke(accent, style: style)
                }
                .mask(alignment: .leading) {
                    Rectangle().frame(width: size * fill.fraction)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The design's ten-point star, in a square box (24 units, points at
/// 12,2.5 through 9.1,8.6). Stroke it with round joins at 1.6/24 of the
/// box for the outline.
struct RatingStarShape: Shape {
    private static let points: [CGPoint] = [
        CGPoint(x: 12, y: 2.5), CGPoint(x: 14.9, y: 8.6), CGPoint(x: 21.5, y: 9.5),
        CGPoint(x: 16.7, y: 14.1), CGPoint(x: 17.9, y: 20.7), CGPoint(x: 12, y: 17.5),
        CGPoint(x: 6.1, y: 20.7), CGPoint(x: 7.3, y: 14.1), CGPoint(x: 2.5, y: 9.5),
        CGPoint(x: 9.1, y: 8.6),
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
        path.closeSubpath()
        return path
    }
}
