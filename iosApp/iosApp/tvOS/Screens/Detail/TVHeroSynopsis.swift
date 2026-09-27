#if os(tvOS)
import SwiftUI

/// The hero's overview, clamped to three lines. Deliberately not focusable:
/// as a focus stop it caught Up presses from the season row and action row,
/// and expanding it was rarely used.
struct TVHeroSynopsis: View {
    let overview: String

    var body: some View {
        Text(overview)
            .font(.system(size: 26, weight: .regular))
            .foregroundColor(.white.opacity(0.92))
            .lineSpacing(4)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .leading)
    }
}
#endif
