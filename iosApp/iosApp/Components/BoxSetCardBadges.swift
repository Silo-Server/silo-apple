import SwiftUI

/// What sets a box set card apart from a single movie: a BOX SET label in the
/// poster's top-leading corner and the film count in its bottom-trailing
/// corner. Drawn over the poster by `MediaCard` and `TVMediaCard`, which also
/// draw the watched-progress bar.
struct BoxSetCardBadges: View {
    let boxSet: CatalogBoxSet

    var body: some View {
        ZStack {
            Text("Box set")
                .textCase(.uppercase)
                .font(.system(size: labelSize, weight: .semibold))
                .tracking(labelSize * 0.14)
                .foregroundStyle(Color.white)
                .padding(.horizontal, labelSize * 0.9)
                .padding(.vertical, labelSize * 0.45)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text(boxSet.filmCountText)
                .font(.system(size: countSize, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, countSize * 0.6)
                .padding(.vertical, countSize * 0.2)
                .background(RoundedRectangle(cornerRadius: countSize * 0.45).fill(Color.black.opacity(0.6)))
                .padding(.trailing, inset)
                // Clear of the progress bar along the bottom edge.
                .padding(.bottom, inset + 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .lineLimit(1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var labelSize: CGFloat {
        #if os(tvOS)
        15
        #else
        9
        #endif
    }

    private var countSize: CGFloat {
        #if os(tvOS)
        18
        #else
        11
        #endif
    }

    private var inset: CGFloat {
        #if os(tvOS)
        12
        #else
        6
        #endif
    }
}

/// Two sleeves peeking above a box set's poster, so the card reads as a stack
/// of films (the web card's look). Drawn behind the poster and above its top
/// edge, so the poster stays level with the movie cards beside it.
struct BoxSetCardSleeves: View {
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            sleeve(inset: 0.10, fill: Color(white: 0.17))
            sleeve(inset: 0.05, fill: Color(white: 0.24))
                .offset(y: step)
        }
        .frame(width: width, height: sleeveHeight, alignment: .top)
        .offset(y: -2 * step)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sleeve(inset: CGFloat, fill: Color) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
        return shape
            .fill(fill)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
            .frame(width: width * (1 - 2 * inset), height: sleeveHeight)
    }

    /// How far each sleeve shows above the one in front of it.
    private var step: CGFloat {
        #if os(tvOS)
        6
        #else
        3
        #endif
    }

    private var sleeveHeight: CGFloat { step * 8 }

    private var radius: CGFloat { SiloTheme.cornerRadius }
}

/// Marks the movie whose page shows its box set row: an outline around the
/// poster and a THIS FILM label in its bottom-leading corner, like the
/// episode rail's current episode. Size it to the poster.
struct BoxSetCurrentFilmMarker: View {
    /// tvOS hides the outline while the card is focused; the focus ring
    /// takes its place.
    var showsOutline = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                .strokeBorder(Color.white.opacity(showsOutline ? 0.8 : 0), lineWidth: lineWidth)
            Text("This film")
                .textCase(.uppercase)
                .font(.system(size: labelSize, weight: .heavy))
                .tracking(labelSize * 0.08)
                .foregroundStyle(Color.black)
                .padding(.horizontal, labelSize * 0.55)
                .padding(.vertical, labelSize * 0.25)
                .background(Capsule().fill(Color.white))
                .padding(inset)
        }
        .lineLimit(1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var labelSize: CGFloat {
        #if os(tvOS)
        16
        #else
        10
        #endif
    }

    private var lineWidth: CGFloat {
        #if os(tvOS)
        4
        #else
        2
        #endif
    }

    private var inset: CGFloat {
        #if os(tvOS)
        12
        #else
        7
        #endif
    }
}
