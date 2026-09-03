#if os(tvOS)
import SwiftUI

/// Editorial section header used below the detail hero. No underline or
/// chrome — just a display title, with an optional small tracked all-caps
/// "eyebrow" above it, used only when the eyebrow carries context the
/// title doesn't (e.g. "This Season" over "Episodes").
struct TVSectionHeader: View {
    var label: String? = nil
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label, !label.isEmpty {
                Text(label.uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .tracking(3.0)
                    .foregroundColor(.continuumOnSurface.opacity(0.55))
            }

            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.continuumOnSurface)
        }
    }
}
#endif
