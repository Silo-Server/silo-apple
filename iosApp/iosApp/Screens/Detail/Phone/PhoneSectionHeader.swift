#if !os(tvOS)
import SwiftUI

/// Editorial section header used below the phone hero — the same
/// pattern as `TVSectionHeader`, scaled to phones. A small tracked
/// all-caps "eyebrow" sits over the title only when it carries context
/// the title doesn't (e.g. "This Season" over "Episodes").
struct PhoneSectionHeader: View {
    var label: String? = nil
    let title: String
    var trailingText: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let label, !label.isEmpty {
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundColor(.siloOnSurface.opacity(0.55))
                }

                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
            }

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
