#if !os(tvOS)
import SwiftUI

/// Editorial section header used below the phone hero — the same
/// pattern as `TVSectionHeader`, scaled to phones.
struct PhoneSectionHeader: View {
    let title: String
    var trailingText: String? = nil

    var body: some View {
        if let trailingText, !trailingText.isEmpty {
            // Side by side while both fit on one line; otherwise the count
            // moves under the title so neither breaks inside a word.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer(minLength: 8)
                    trailing(trailingText)
                }

                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    trailing(trailingText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                titleText
                Spacer(minLength: 8)
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .siloScaledFont(size: 22, weight: .semibold, relativeTo: .title2)
            .foregroundColor(.siloOnSurface)
    }

    private func trailing(_ text: String) -> some View {
        Text(text)
            .siloScaledFont(size: 13, weight: .medium, relativeTo: .footnote)
            .foregroundColor(.siloSecondaryText)
    }
}
#endif
