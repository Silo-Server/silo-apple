#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// The player's HUD, laid out like the web player's: the timeline across the
/// bottom, then what is playing at the start, transport on the centreline,
/// and volume, track menus and settings at the end. It sits on the picture
/// over a scrim (`MacPlayerScrims`) rather than on a panel. The menus are
/// native pop-up menus; Playback Info is a popover.
struct MacPlayerControls: View {
    let viewModel: PlayerViewModel
    let isFullScreen: Bool
    let menuAnchors: MacPlayerMenuAnchors
    @Binding var isInfoPresented: Bool
    let onOpenMenu: (MacPlayerMenu) -> Void
    let onToggleFullScreen: () -> Void
    /// Reports how far up from the window's bottom edge the HUD reaches.
    let onHeightChange: (CGFloat) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hud
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        }
    }

    private var hud: some View {
        VStack(spacing: 12) {
            MacPlayerTimeline(viewModel: viewModel)
                .mediaLayoutDirection()

            MacPlayerHUDRow(spacing: 24) {
                titleBlock
                transport
                trailingControls
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    // MARK: - What is playing

    /// The series or movie title, the episode (or the year) and the current
    /// chapter, then the time line: "38:23 / 1:42:01 · Ends 9:41 PM".
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !hudTitle.isEmpty {
                Text(verbatim: hudTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(MacPlayerHUDStyle.paper)
                    .lineLimit(1)
                    .help(hudTitle)
            }
            if !metaParts.isEmpty {
                dotted(metaParts.map { Text(verbatim: $0) })
            }
            dotted(timeParts)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var hudTitle: String {
        let metadata = viewModel.metadata
        if let series = metadata.seriesTitle, !series.isEmpty { return series }
        return metadata.primaryTitle.isEmpty ? viewModel.title : metadata.primaryTitle
    }

    /// "S1:E4 · Pilot" for an episode, the year for a movie, then the
    /// chapter when the title has more than one.
    private var metaParts: [String] {
        let metadata = viewModel.metadata
        var parts: [String] = []
        if let series = metadata.seriesTitle, !series.isEmpty {
            let episode = [metadata.episodeTag, metadata.primaryTitle]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !episode.isEmpty { parts.append(episode) }
        } else if let year = metadata.year {
            parts.append(LocaleFormat.integer(year, locale: locale))
        }
        if viewModel.chapters.count > 1,
           let chapter = viewModel.chapters.last(where: { $0.time <= viewModel.currentTime }),
           let title = chapter.title, !title.isEmpty {
            parts.append(title)
        }
        return parts
    }

    private var timeParts: [Text] {
        let elapsed = PlayerTimeFormatter.formatHMS(viewModel.currentTime)
        guard viewModel.duration > 0 else { return [Text(verbatim: elapsed)] }
        let remaining = max(0, viewModel.duration - viewModel.currentTime)
        let speed = max(viewModel.settings.playbackSpeed, 0.1)
        let endsAt = Date().addingTimeInterval(remaining / speed)
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        return [
            // Clock times read left to right in every language.
            Text(verbatim: "\u{2066}\(elapsed) / \(PlayerTimeFormatter.formatHMS(viewModel.duration))\u{2069}"),
            Text(.playerScrubberEndsAt(endsAt)),
        ]
    }

    /// Parts on one line, split by small dots as on web. The first part
    /// keeps its width; the rest truncate.
    private func dotted(_ parts: [Text]) -> some View {
        HStack(spacing: 8) {
            ForEach(parts.indices, id: \.self) { index in
                if index > 0 {
                    Circle()
                        .frame(width: 3, height: 3)
                        .opacity(0.8)
                        .accessibilityHidden(true)
                }
                parts[index]
                    .lineLimit(1)
                    .layoutPriority(index == 0 ? 1 : 0)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(MacPlayerHUDStyle.ash)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.skipBackward()
            } label: {
                Image(systemName: SeekIntervalLabel.symbolName(.backward, seconds: viewModel.skipIntervals.backward))
            }
            .buttonStyle(MacPlayerGlassDiscStyle())
            .help("\(SeekIntervalLabel.accessibilityLabel(.backward, seconds: viewModel.skipIntervals.backward)) (←)")

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(MacPlayerPlayDiscStyle())
            .help(viewModel.isPlaying ? "Pause (Space)" : "Play (Space)")

            Button {
                viewModel.skipForward()
            } label: {
                Image(systemName: SeekIntervalLabel.symbolName(.forward, seconds: viewModel.skipIntervals.forward))
            }
            .buttonStyle(MacPlayerGlassDiscStyle())
            .help("\(SeekIntervalLabel.accessibilityLabel(.forward, seconds: viewModel.skipIntervals.forward)) (→)")
        }
        // Transport reads left to right in every language, like the timeline.
        .mediaLayoutDirection()
    }

    // MARK: - Settings

    /// Volume, then the track menus, then quality, speed, Playback Info and
    /// full screen, in the web player's groups.
    private var trailingControls: some View {
        HStack(spacing: 4) {
            MacPlayerVolumeControl(viewModel: viewModel)

            groupDivider

            menuButton(.tracks, help: "Audio and Subtitles (⌘S)") {
                glyph("captions.bubble")
            }
            .disabled(!viewModel.hasTrackSelectionOptions)

            if !viewModel.chapters.isEmpty {
                menuButton(.chapters, help: "Chapters") {
                    glyph("list.bullet")
                }
            }

            groupDivider

            if viewModel.hasQualityChoice {
                qualityButton
            }

            menuButton(.speed, help: "Playback Speed") {
                Text(MacPlayerMenuContent.speedLabel(viewModel.settings.playbackSpeed))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 40, minHeight: MacPlayerHUDStyle.iconButtonSize)
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
        .buttonStyle(MacPlayerGlyphButtonStyle())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .frame(width: MacPlayerHUDStyle.iconButtonSize, height: MacPlayerHUDStyle.iconButtonSize)
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

    /// Opens the quality menu and names the active choice, like the settings
    /// button on web.
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
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: MacPlayerHUDStyle.iconButtonSize)
        }
        .accessibilityLabel("Playback Quality")
        .accessibilityValue(activeQualityLabel)
    }

    private var activeQualityLabel: String {
        viewModel.activeQualityOption?.label
            ?? ApplePlaybackQuality.displayName(for: viewModel.activeQualityId)
    }
}

/// The web HUD's fixed tokens: it always sits on a picture, never on an app
/// surface, so it does not follow the theme.
enum MacPlayerHUDStyle {
    /// Titles and glyphs.
    static let paper = Color(red: 245 / 255, green: 243 / 255, blue: 239 / 255)
    /// Secondary text.
    static let ash = Color(red: 189 / 255, green: 186 / 255, blue: 179 / 255)
    /// The play disc's glyph.
    static let ink = Color(red: 14 / 255, green: 14 / 255, blue: 17 / 255)
    /// Tooltips and other small panels on the picture.
    static let panel = Color(red: 16 / 255, green: 16 / 255, blue: 19 / 255).opacity(0.93)
    /// The skip discs, at rest and under the pointer.
    static let glass = Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.62)
    static let glassHover = Color(red: 40 / 255, green: 40 / 255, blue: 46 / 255).opacity(0.78)
    static let iconButtonSize: CGFloat = 36
}

/// The HUD's row: the first view at the start, the second on the
/// centreline, the third at the end. The two sides share the width equally
/// unless the end needs more, as in the web player's grid, so the title
/// gives up room before the controls do.
private struct MacPlayerHUDRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(spacing * 2) { $0 + $1.width }
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let middle = subviews[1].sizeThatFits(.unspecified)
        let trailingIdeal = subviews[2].sizeThatFits(.unspecified).width
        let sides = max(0, bounds.width - middle.width - spacing * 2)
        let trailingWidth = min(sides, max(sides / 2, trailingIdeal))
        let leadingWidth = sides - trailingWidth
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: leadingWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + leadingWidth + spacing, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(middle)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(width: trailingWidth, height: bounds.height)
        )
    }
}

/// The web HUD's scrims: eased ramps that darken only where the controls
/// sit, so text stays legible on a white frame without dimming the middle
/// of the picture.
struct MacPlayerScrims: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.66), location: 0),
                        .init(color: .black.opacity(0.42), location: 0.35),
                        .init(color: .black.opacity(0.16), location: 0.7),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(128, proxy.size.height * 0.18))
                Spacer(minLength: 0)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.92), location: 0),
                        .init(color: .black.opacity(0.86), location: 0.16),
                        .init(color: .black.opacity(0.74), location: 0.32),
                        .init(color: .black.opacity(0.54), location: 0.48),
                        .init(color: .black.opacity(0.3), location: 0.64),
                        .init(color: .black.opacity(0.13), location: 0.8),
                        .init(color: .black.opacity(0.04), location: 0.92),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: max(272, proxy.size.height * 0.46))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: MacPlayerHUDStyle.iconButtonSize, height: MacPlayerHUDStyle.iconButtonSize)
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

/// A bare glyph that takes a soft round highlight under the pointer and
/// dims while pressed or disabled, like the web HUD's icon buttons.
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
                .foregroundStyle(MacPlayerHUDStyle.paper.opacity(isEnabled ? 1 : 0.42))
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isHovering && isEnabled ? 0.1 : 0))
                }
                .contentShape(Capsule(style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isHovering)
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
        }
    }
}

/// The web HUD's glass discs for the skip buttons: legible on any frame.
private struct MacPlayerGlassDiscStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Disc(configuration: configuration)
    }

    private struct Disc: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(MacPlayerHUDStyle.paper)
                .frame(width: 48, height: 48)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle().fill(isHovering ? MacPlayerHUDStyle.glassHover : MacPlayerHUDStyle.glass)
                        }
                        .overlay { Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isHovering)
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
        }
    }
}

/// The web HUD's play button: the one solid disc, so it reads first.
private struct MacPlayerPlayDiscStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Disc(configuration: configuration)
    }

    private struct Disc: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(MacPlayerHUDStyle.ink)
                .frame(width: 60, height: 60)
                .background {
                    Circle()
                        .fill(MacPlayerHUDStyle.paper)
                        .shadow(color: .black.opacity(0.7), radius: 16, y: 12)
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.96 : isHovering ? 1.04 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isHovering)
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
        }
    }
}
#endif
