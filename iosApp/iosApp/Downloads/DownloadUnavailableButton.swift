#if !os(tvOS)
import SwiftUI

/// The action row's Download control for an account the server does not let
/// download (`DownloadCapability.Access.restricted`). It stays in Download's
/// place with a dimmed glyph, and a tap says who can change that, so the
/// viewer is not left wondering where Download went.
///
/// Same metrics as `SeriesDownloadButton`. The caption keeps its neighbours'
/// contrast, because the control still takes a tap.
struct DownloadUnavailableButton: View {
    @State private var showsReason = false

    var body: some View {
        Button {
            showsReason = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(Color.siloOnSurface.opacity(0.4))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.05)))
                Text(.audiobookDetailDownload)
                    .siloScaledFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundColor(Color.siloOnSurface.opacity(0.6))
                    .phoneActionCaption()
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(.audiobookDetailDownload))
        // Not disabled, so the explanation stays reachable: VoiceOver hears
        // the state as the value and the reason as the hint.
        .accessibilityValue(Text(.downloadsManagerUnavailableTitle))
        .accessibilityHint(Text(.requestsErrorPermission))
        .alert(Text(.downloadsManagerUnavailableTitle), isPresented: $showsReason) {
            Button(.shellNoticeOk, role: .cancel) {}
        } message: {
            Text(.requestsErrorPermission)
        }
    }
}
#endif
