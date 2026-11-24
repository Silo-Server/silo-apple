#if os(iOS)
import SwiftUI

/// The bar for an engaged TV control session: the title and "Playing on
/// <TV>" while the TV plays, "Connected to <TV>" while it has nothing on, and
/// "Reconnecting… to <TV>" while the link is down. Tapping it opens the full
/// remote.
struct SiloControlMiniBar: View {
    let controller: SiloControlClient
    var style: NowPlayingBarStyle = .card
    @State private var artwork = SiloControlArtworkResolver()
    /// `.inline` is the minimized-tab-bar slot — collapse to a single line so the
    /// bar fits the compact pill without truncating.
    @Environment(\.nowPlayingAccessoryIsInline) private var isInline

    private var targetName: String {
        controller.engagedTargetName ?? "Silo TV"
    }

    /// The TV is reachable and playing: only then is there a title to show
    /// and a player for Play/Pause to reach.
    private var isPlayingTitle: Bool {
        !controller.isReconnecting && controller.hasRemotePlayback
    }

    var body: some View {
        Button { controller.showRemoteControl() } label: {
            HStack(spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if controller.isReconnecting {
                            Text(.castReconnecting)
                        } else if isPlayingTitle, let title = controller.state?.title, !title.isEmpty {
                            Text(title)
                        } else if isInline {
                            // The one-line slot has no second line to name the TV.
                            Text(.castRemoteConnectedTo(targetName))
                        } else {
                            Text(.castMiniBarConnected)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    if !isInline {
                        (isPlayingTitle
                         ? Text(.castPlayingOn(targetName))
                         : Text(.castMiniBarToTv(targetName)))
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
                    .accessibilityLabel(Text(.remoteMiniBarStopReconnecting))
                } else if isPlayingTitle {
                    Button {
                        controller.togglePlayPauseOptimistic()
                    } label: {
                        Image(systemName: controller.clock.isPlaying() ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.clock.isPlaying() ? Text(.playerAudioPause) : Text(.playerAudioPlay))
                } else {
                    // Nothing to pause on an idle TV; the glyph says the bar
                    // opens the remote.
                    Image(systemName: "appletvremote.gen4.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, style == .accessory ? 4 : 8)
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

    /// 2:3 poster sized to sit inside the bar. The system accessory has a fixed
    /// height (about 48pt expanded, less when inline) and clips anything taller,
    /// so only the self-sizing card gets the full-size poster.
    private var thumbSize: CGSize {
        if isInline { return CGSize(width: 22, height: 33) }
        if style == .accessory { return CGSize(width: 24, height: 36) }
        return CGSize(width: 34, height: 50)
    }

    @ViewBuilder
    private var thumb: some View {
        let shape = RoundedRectangle(cornerRadius: style == .accessory ? 4 : 6, style: .continuous)
        if let url = artwork.tilePosterURL, !url.isEmpty {
            AsyncImageView(url: url, contentMode: .fill)
                .frame(width: thumbSize.width, height: thumbSize.height)
                .clipShape(shape)
        } else {
            shape
                .fill(Color.siloSurfaceElevated)
                .frame(width: thumbSize.width, height: thumbSize.height)
                .overlay {
                    Image(systemName: "tv")
                        .font(isInline ? .caption2 : .body)
                        .foregroundStyle(Color.siloSecondaryText)
                }
        }
    }
}
#endif
