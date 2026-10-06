#if os(iOS)
import SwiftUI

/// "Playing on <TV>" bar for an engaged TV control session. Tapping it opens
/// the full remote.
struct SiloControlMiniBar: View {
    let controller: SiloControlClient
    var style: NowPlayingBarStyle = .card
    @State private var artwork = SiloControlArtworkResolver()
    /// `.inline` is the minimized-tab-bar slot — collapse to a single line so the
    /// bar fits the compact pill without truncating.
    @Environment(\.nowPlayingAccessoryIsInline) private var isInline

    private var targetName: String {
        controller.activeTarget?.name ?? controller.lastTarget?.name ?? "Silo TV"
    }

    var body: some View {
        Button { controller.showRemoteControl() } label: {
            HStack(spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.isReconnecting
                         ? "Reconnecting…"
                         : (controller.state?.title ?? "Connected"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !isInline {
                        Text(controller.isReconnecting
                             ? "to \(targetName)"
                             : "Playing on \(targetName)")
                            .font(.caption)
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if controller.isReconnecting {
                    ProgressView()
                        .frame(width: 24, height: 24)
                    Button {
                        controller.cancelReconnect()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop reconnecting")
                } else {
                    Button {
                        controller.togglePlayPauseOptimistic()
                    } label: {
                        Image(systemName: controller.clock.isPlaying() ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.clock.isPlaying() ? "Pause" : "Play")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, isInline ? 4 : 8)
            .modifier(NowPlayingBarChrome(style: style))
            .foregroundStyle(Color.siloOnSurface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, style == .card ? 12 : 0)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: controller.state?.contentId) {
            await artwork.resolve(contentId: controller.state?.contentId)
        }
    }

    @ViewBuilder
    private var thumb: some View {
        if let url = artwork.posterURL, !url.isEmpty {
            AsyncImageView(url: url, contentMode: .fill)
                .frame(width: 34, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.siloSurfaceElevated)
                .frame(width: 34, height: 50)
                .overlay { Image(systemName: "tv").foregroundStyle(Color.siloSecondaryText) }
        }
    }
}
#endif
