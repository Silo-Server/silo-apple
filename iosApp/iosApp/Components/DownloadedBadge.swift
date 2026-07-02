#if !os(tvOS)
import SwiftUI

/// Corner indicator marking catalog cards whose media is fully on device.
/// Completed downloads only — in-flight state lives on the detail screens,
/// so cards never re-render on transfer progress. Green to match the
/// download button's completed state; the arrow glyph (Downloads tab
/// iconography) keeps it distinct from the white watched check that owns
/// the opposite corner.
struct DownloadedBadge: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .shadow(color: .black.opacity(0.3), radius: 4)
    }
}
#endif
