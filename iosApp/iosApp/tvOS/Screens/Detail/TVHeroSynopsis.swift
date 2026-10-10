#if os(tvOS)
import SwiftUI

/// The hero's overview, clamped to three lines. Deliberately not focusable:
/// as a focus stop it caught Up presses from the season row and action row,
/// and expanding it was rarely used.
///
/// An on-view translation status ("Translating…" / "Translated by AI") is
/// drawn as the last line of the same block, in place of the third line of
/// text, so it fits the Series hero's fixed synopsis slot and moves nothing
/// below it. The original text dims while a translation runs.
struct TVHeroSynopsis: View {
    let overview: String
    var status: DescriptionTranslationStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overview)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(4)
                .lineLimit(status == nil ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(status == .translating ? 0.5 : 1)
            if let status {
                DescriptionTranslationStatusLabel(status: status, fontSize: 21)
            }
        }
        .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: status)
    }
}
#endif
