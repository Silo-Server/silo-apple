#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// The player's control bar: the timeline, then transport in the middle,
/// track, chapter and quality menus on the leading side, and speed, Playback
/// Info and full screen on the trailing side. The menus are native pop-up
/// menus; Playback Info is a popover.
struct MacPlayerControls: View {
    let viewModel: PlayerViewModel
    let isFullScreen: Bool
    let menuAnchors: MacPlayerMenuAnchors
    @Binding var isInfoPresented: Bool
    let onOpenMenu: (MacPlayerMenu) -> Void
    let onToggleFullScreen: () -> Void
    /// Reports how far up from the window's bottom edge the bar reaches.
    let onHeightChange: (CGFloat) -> Void

    private static let edgeInset: CGFloat = 20

    // The title and format line live in the window's title bar, beside the
    // back button, so the picture carries only the transport controls.
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            bar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onHeightChange(height + Self.edgeInset)
                }
        }
        .padding(Self.edgeInset)
    }

    private var bar: some View {
        VStack(spacing: 10) {
            MacPlayerTimeline(viewModel: viewModel)
                .mediaLayoutDirection()

            ZStack {
                HStack(spacing: 2) {
                    menuButton(.tracks, help: "Audio and Subtitles (⌘S)") {
                        glyph("captions.bubble")
                    }
                    .disabled(!viewModel.hasTrackSelectionOptions)

                    if !viewModel.chapters.isEmpty {
                        menuButton(.chapters, help: "Chapters") {
                            glyph("list.bullet")
                        }
                    }

                    if viewModel.hasQualityChoice {
                        qualityButton
                    }

                    Spacer(minLength: 8)

                    menuButton(.speed, help: "Playback Speed") {
                        Text(MacPlayerMenuContent.speedLabel(viewModel.settings.playbackSpeed))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .frame(minWidth: 40, minHeight: 30)
                    }

                    Button {
                        isInfoPresented.toggle()
                    } label: {
                        glyph("info.circle")
                    }
                    .help("Playback Info (⌘I)")
                    .popover(isPresented: $isInfoPresented, arrowEdge: .top) {
                        MacPlaybackInfoView(viewModel: viewModel)
                    }

                    Button(action: onToggleFullScreen) {
                        glyph(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)")
                }

                HStack(spacing: 14) {
                    Button {
                        viewModel.skipBackward()
                    } label: {
                        glyph(SeekIntervalLabel.symbolName(.backward, seconds: viewModel.skipIntervals.backward), size: 17)
                    }
                    .help("\(SeekIntervalLabel.accessibilityLabel(.backward, seconds: viewModel.skipIntervals.backward)) (←)")

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 36)
                    }
                    .help(viewModel.isPlaying ? "Pause (Space)" : "Play (Space)")

                    Button {
                        viewModel.skipForward()
                    } label: {
                        glyph(SeekIntervalLabel.symbolName(.forward, seconds: viewModel.skipIntervals.forward), size: 17)
                    }
                    .help("\(SeekIntervalLabel.accessibilityLabel(.forward, seconds: viewModel.skipIntervals.forward)) (→)")
                }
                .mediaLayoutDirection()
            }
            .buttonStyle(MacPlayerGlyphButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        }
    }

    private func glyph(_ systemName: String, size: CGFloat = 15) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .frame(width: 32, height: 30)
    }

    private func menuButton<Label: View>(
        _ menu: MacPlayerMenu,
        help: String,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            onOpenMenu(menu)
        } label: {
            label()
        }
        .macMenuAnchor(menuAnchors[menu])
        .help(help)
    }

    /// Opens the quality menu and names the active choice, like the quality
    /// pill on iOS.
    private var qualityButton: some View {
        menuButton(.quality, help: "Quality") {
            HStack(spacing: 6) {
                if viewModel.isQualitySwitching {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "slider.horizontal.3")
                }
                Text(activeQualityLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .accessibilityLabel("Playback Quality")
        .accessibilityValue(activeQualityLabel)
    }

    private var activeQualityLabel: String {
        viewModel.activeQualityOption?.label
            ?? ApplePlaybackQuality.displayName(for: viewModel.activeQualityId)
    }
}

/// A bare glyph that takes a soft highlight under the pointer and dims
/// while pressed or disabled, like the controls in QuickTime Player.
private struct MacPlayerGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlyphButton(configuration: configuration)
    }

    private struct GlyphButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.white.opacity(foregroundOpacity))
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHovering && isEnabled ? 0.12 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isHovering)
        }

        private var foregroundOpacity: Double {
            guard isEnabled else { return 0.3 }
            return configuration.isPressed ? 0.6 : 0.95
        }
    }
}
#endif
