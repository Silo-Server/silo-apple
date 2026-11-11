import SwiftUI

/// The poster's top-right corner: a check on a watched title, or the number
/// of episodes a started series or season has left. Nothing on anything else,
/// so a library of untouched shows is not covered in numbers.
///
/// No badge is ever placed in this corner (see `CardOverlays`), and it shows
/// whether or not badges are on. It is sized from the card width the same way
/// the badges are. Mirrors `web/src/components/overlays/CardWatchStatus.tsx`.
/// Wide cards do not draw it.
struct CardWatchStatus: View {
    /// The indicator's diameter at the reference card width. The top badge
    /// row stops short of it so a badge never runs under the indicator.
    static let size: CGFloat = 22

    /// Tailwind's `emerald-500`, the web check's fill.
    private static let watchedFill = Color(.sRGB, red: 0, green: 0.737, blue: 0.49)

    /// Whether the card shows the title as watched.
    let played: Bool
    /// `MediaCardPersonalState.episodesLeft`, ignored on a watched title.
    let episodesLeft: Int?
    /// The width of the artwork this sits on, in points.
    let cardWidth: CGFloat

    @Environment(\.locale) private var locale

    var body: some View {
        let scale = cardWidth / CardOverlays.posterReferenceWidth
        let size = Self.size * scale
        Group {
            if played {
                WatchedCheckMark()
                    .stroke(
                        .white,
                        style: StrokeStyle(lineWidth: size * 0.62 * 3.25 / 24, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: size * 0.62, height: size * 0.62)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Self.watchedFill))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            } else if let episodesLeft {
                let fontSize = 11 * scale
                Text(verbatim: LocaleFormat.integer(episodesLeft, locale: locale))
                    .font(.system(size: fontSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, fontSize * 0.4)
                    .frame(minWidth: size)
                    .frame(height: size)
                    .background(Capsule().fill(.black.opacity(0.65)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
        .padding(CardOverlays.edgeInset * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // The corner is a place on the artwork, which doesn't mirror.
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        // The host card's own accessibility label says "Watched".
        .accessibilityHidden(true)
    }
}

/// The web's check (Lucide's, in a 24-unit box), so the mark is the same
/// shape on every client.
private struct WatchedCheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.move(to: point(20, 6))
        path.addLine(to: point(9, 17))
        path.addLine(to: point(4, 12))
        return path
    }
}
