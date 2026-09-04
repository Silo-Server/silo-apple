#if os(iOS)
import SwiftUI

/// Persistent "Playing on <TV>" bar shown above the tab content whenever a TV control
/// session is active and the full remote is dismissed. Tapping reopens the remote.
struct SiloControlMiniBar: View {
    @Bindable var controller: SiloControlClient
    var style: NowPlayingBarStyle = .card
    @State private var artwork = SiloControlArtworkResolver()
    @Environment(\.nowPlayingAccessoryIsInline) private var isInline

    /// `.inline` is the minimized-tab-bar slot — collapse to a single line so the
    /// bar fits the compact pill without truncating.
    /// Whether the bar has anything to show: a live session (that isn't a
    /// still-unconfirmed auto-resume probe) or an in-flight reconnect. Keeping
    /// the bar up through a reconnect (with a spinner) beats having it vanish
    /// and pop back. Stays visible under the full remote sheet so dismissing
    /// the sheet doesn't re-insert the accessory with a second animation.
    private var isVisible: Bool {
        (controller.hasActiveSession && !controller.isAutoResuming) || controller.isReconnecting
    }

    private var targetName: String {
        controller.activeTarget?.name ?? controller.lastTarget?.name ?? "Silo TV"
    }

    var body: some View {
        if isVisible {
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
                                .foregroundStyle(Color.continuumSecondaryText)
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
                .foregroundStyle(Color.continuumOnSurface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, style == .card ? 12 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: controller.state?.contentId) {
                await artwork.resolve(contentId: controller.state?.contentId)
            }
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
                .fill(Color.continuumSurfaceElevated)
                .frame(width: 34, height: 50)
                .overlay { Image(systemName: "tv").foregroundStyle(Color.continuumSecondaryText) }
        }
    }
}
#endif
