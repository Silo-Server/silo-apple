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

/// Card ZStack layer pinning the downloaded indicator bottom-trailing —
/// clear of the watched check (top-trailing) and episode badges
/// (bottom-leading). Gated by the manager's capability-aware lookup so
/// nothing renders on servers without downloads.
struct DownloadedBadgeOverlay: View {
    let contentId: String?
    let padding: CGFloat

    var body: some View {
        if let contentId, DownloadManager.shared.isDownloaded(contentId: contentId) {
            DownloadedBadge()
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}
#endif
