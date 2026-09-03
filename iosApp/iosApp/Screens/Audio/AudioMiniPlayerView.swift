import SwiftUI

/// Persistent bottom mini player shown while an audiobook session is
/// active. Tapping the metadata reopens the full player; the accent
/// progress hairline along the bottom edge tracks book position.
struct AudioMiniPlayerView: View {
    @Environment(AudioPlaybackStore.self) private var audioStore
    var style: NowPlayingBarStyle = .card
    @Environment(\.nowPlayingAccessoryIsInline) private var isInline

    /// `.inline` is the minimized-tab-bar slot — collapse to a single line so the
    /// bar fits the compact pill without truncating.
    var body: some View {
        let player = audioStore.player
        if player.hasActiveSession {
            HStack(spacing: 12) {
                Button {
                    audioStore.showFullPlayer()
                } label: {
                    HStack(spacing: 12) {
                        AudioCoverArtView(urlString: player.posterUrl, cornerRadius: 8)
                            .frame(width: isInline ? 34 : 46, height: isInline ? 34 : 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if !isInline {
                                Text(subtitleLine(player: player))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now Playing: \(player.title)")
                .accessibilityHint("Opens the full player")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isInline ? 4 : 8)
            .modifier(NowPlayingBarChrome(style: style))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(player.palette.accent)
                        .frame(
                            width: proxy.size.width * progressFraction(player: player),
                            height: 2
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                // Inset so the hairline stays inside the card's rounded
                // corners; the GeometryReader reads the inset width.
                .padding(.horizontal, 12)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, style == .card ? 16 : 0)
            .padding(.bottom, style == .card ? 8 : 0)
        }
    }

    private func progressFraction(player: AudioPlayerViewModel) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(player.currentTime / player.duration, 0), 1))
    }

    private func subtitleLine(player: AudioPlayerViewModel) -> String {
        if let chapter = player.currentChapter {
            return chapter.title ?? "Chapter \(chapter.index + 1)"
        }
        return player.subtitle ?? PlayerTimeFormatter.formatHMS(player.currentTime)
    }
}
