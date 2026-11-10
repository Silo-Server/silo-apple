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

            // Transport leads; tracks, quality, speed, volume, Playback
            // Info and full screen trail, as in the TV app and on web.
            HStack(spacing: 2) {
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

                Spacer(minLength: 16)

                if !viewModel.chapters.isEmpty {
                    menuButton(.chapters, help: "Chapters") {
                        glyph("list.bullet")
                    }
                }

                if viewModel.hasQualityChoice {
                    qualityButton
                }

                menuButton(.tracks, help: "Audio and Subtitles (⌘S)") {
                    glyph("captions.bubble")
                }
                .disabled(!viewModel.hasTrackSelectionOptions)

                menuButton(.speed, help: "Playback Speed") {
                    Text(MacPlayerMenuContent.speedLabel(viewModel.settings.playbackSpeed))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 40, minHeight: 30)
                }

                MacPlayerVolumeControl(viewModel: viewModel)

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

/// A speaker button that mutes, and a slider for the player's volume. The
/// volume is the player's own gain, under the system volume.
private struct MacPlayerVolumeControl: View {
    let viewModel: PlayerViewModel

    private var level: Double { Double(viewModel.audibleVolume) }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: viewModel.toggleMuteOrRestore) {
                // One symbol whose waves fill with the level, so dragging the
                // slider doesn't swap glyphs of different widths.
                Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 30, alignment: .center)
            }
            .help(level == 0 ? "Unmute (M)" : "Mute (M)")

            Slider(value: Binding(
                get: { level },
                set: { viewModel.applyUserVolume(Float($0)) }
            ), in: 0...1)
            .controlSize(.mini)
            .tint(.white)
            .frame(width: 84)
            .help("Volume (↑ ↓, or scroll)")
            .accessibilityLabel("Volume")
        }
        // Scrolling over the speaker or the slider changes the volume.
        .background(MacVolumeScrollArea { viewModel.stepVolume(by: $0) })
    }
}

extension PlayerViewModel {
    /// The volume being heard: 0 while muted.
    var audibleVolume: Float { userMuted ? 0 : userVolume }

    /// Moves the volume by `step` from what is heard; a step up unmutes.
    func stepVolume(by step: Float) {
        applyUserVolume(audibleVolume + step)
    }

    /// Mutes, or brings back the last volume (full when it was 0).
    func toggleMuteOrRestore() {
        if audibleVolume == 0 {
            unmutePlayerGainForLocalVolume()
        } else {
            applyUserMuted(true)
        }
    }
}

/// Turns scrolls that start over it into volume steps: a trackpad or Magic
/// Mouse swipe moves the volume with the fingers, a wheel notch by 5%. Up is
/// louder whatever the scroll direction setting. The player's trackpad scrub
/// leaves these swipes alone (`claims(_:)`).
struct MacVolumeScrollArea: NSViewRepresentable {
    let adjust: (Float) -> Void

    func makeNSView(context: Context) -> AreaView { AreaView() }

    func updateNSView(_ nsView: AreaView, context: Context) {
        nsView.adjust = adjust
    }

    static func dismantleNSView(_ nsView: AreaView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    /// Whether a volume area in the event's window is under the pointer.
    @MainActor
    static func claims(_ event: NSEvent) -> Bool {
        AreaView.areas.allObjects.contains { $0.contains(event) }
    }

    final class AreaView: NSView {
        static let areas = NSHashTable<AreaView>.weakObjects()

        var adjust: (Float) -> Void = { _ in }
        private var monitor: MacLocalEventMonitor?
        /// The current swipe began over this area, so its events and the
        /// momentum after it belong here.
        private var ownsSwipe = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            Self.areas.add(self)
            monitor = MacLocalEventMonitor(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func stopMonitoring() {
            monitor?.stop()
            monitor = nil
            Self.areas.remove(self)
            ownsSwipe = false
        }

        func contains(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            return bounds.contains(convert(event.locationInWindow, from: nil))
        }

        /// True when the event changed the volume or belongs to a swipe that does.
        private func handle(_ event: NSEvent) -> Bool {
            if !event.momentumPhase.isEmpty { return ownsSwipe }
            if event.phase.contains(.began) {
                ownsSwipe = contains(event)
            } else if event.phase.isEmpty {
                // A wheel notch: no phases, acts where it lands.
                guard contains(event) else { return false }
            } else if !ownsSwipe {
                return false
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                return true
            }
            // Mostly sideways movement isn't a volume change.
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return true }
            let upward = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
            let step = event.hasPreciseScrollingDeltas ? upward * 0.005 : upward * 0.05
            if step != 0 { adjust(Float(step)) }
            return true
        }
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
