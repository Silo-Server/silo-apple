#if !os(tvOS)
import SwiftUI

/// Editorial section header used below the phone hero — the same
/// pattern as `TVSectionHeader`, scaled to phones.
struct PhoneSectionHeader: View {
    let title: String
    var trailingText: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.siloOnSurface)

            Spacer(minLength: 8)

            if let trailingText, !trailingText.isEmpty {
                Text(trailingText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.siloSecondaryText)
            }
        }
    }
}
#endif
