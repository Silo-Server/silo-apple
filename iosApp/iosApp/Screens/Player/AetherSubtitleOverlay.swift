import AetherEngine
import SwiftUI

/// Presentation-only overlay for Aether's decoded public cue model.
/// It never fetches, parses, demuxes, or selects subtitle media.
struct AetherSubtitleOverlay: View {
    let engine: AetherEngine
    let assSubtitles: ASSSubtitleSession
    /// Read when a publication arrives; see ``SubtitleCueHold``.
    let cueHold: SubtitleCueHold
    let sourceTime: Double
    let primaryUsesMovieTimeline: Bool
    let secondaryUsesMovieTimeline: Bool
    let livePrimaryCues: [LiveSubtitleCue]
    let liveSecondaryCues: [LiveSubtitleCue]
    let appearance: SubtitleAppearance
    let subtitleSyncMs: Int

    @State private var primary: [SubtitleCue] = []
    @State private var secondary: [SubtitleCue] = []
    @State private var aetherSourceTime: Double = 0
    @State private var primaryCursor = SubtitleCueCursor<SubtitleCue>()
    @State private var secondaryCursor = SubtitleCueCursor<SubtitleCue>()
    @State private var livePrimaryCursor = SubtitleCueCursor<LiveSubtitleCue>()
    @State private var liveSecondaryCursor = SubtitleCueCursor<LiveSubtitleCue>()
    @State private var primaryTrack = LTRAuthoredSubtitles.Track()
    @State private var secondaryTrack = LTRAuthoredSubtitles.Track()

    /// Positive delay means captions appear later, so the cue clock is moved
    /// backwards. This preserves Silo's existing subtitle-sync sign contract.
    private var subtitleDelaySeconds: Double {
        Double(subtitleSyncMs) / 1_000
    }

    /// Only embedded cues read the engine clock. Without them, its ticks
    /// would rewrite state that nothing reads.
    private var needsEngineClock: Bool {
        (!primary.isEmpty && !primaryUsesMovieTimeline)
            || (!secondary.isEmpty && !secondaryUsesMovieTimeline)
    }

    var body: some View {
        GeometryReader { geometry in
            let videoRect = displayedVideoRect(in: geometry.size)
            // Built once per evaluation: it sanitizes the appearance and
            // parses its colors, and every cue below needs it.
            let style = AetherSubtitleRenderStyle(appearance: appearance)
            ZStack {
                if assSubtitles.handlesCurrentTrack {
                    ASSSubtitleLayer(session: assSubtitles, videoRect: videoRect, delaySeconds: subtitleDelaySeconds)
                } else {
                    cueLayer(activeCues(primaryCursor, usesMovieTimeline: primaryUsesMovieTimeline),
                             style: style, videoRect: videoRect, secondary: false)
                }
                cueLayer(activeCues(secondaryCursor, usesMovieTimeline: secondaryUsesMovieTimeline),
                         style: style, videoRect: videoRect, secondary: true)
                liveCueLayer(activeLiveCues(livePrimaryCursor, in: livePrimaryCues),
                             style: style, videoRect: videoRect, secondary: false)
                liveCueLayer(activeLiveCues(liveSecondaryCursor, in: liveSecondaryCues),
                             style: style, videoRect: videoRect, secondary: true)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Every primary track switch changes the engine's active index, and the
        // index is set before the switch publishes cues.
        .onReceive(engine.$subtitleCues) {
            // A showing track fetched again after a timing change keeps its
            // cues until the new ones arrive.
            if $0.isEmpty, cueHold.holds(.primary, trackID: engine.activeSubtitleTrackIndex) { return }
            primary = primaryTrack.laidOutAsAuthored($0, trackID: engine.activeSubtitleTrackIndex)
            primaryCursor.reset(primary)
            aetherSourceTime = engine.clock.sourceTime
        }
        // The engine publishes no secondary index. It clears the secondary
        // cues whenever it selects a secondary track, so an empty publication
        // starts over; an embedded secondary track that empties during a long
        // gap starts over too.
        .onReceive(engine.$secondarySubtitleCues) {
            if $0.isEmpty, cueHold.holds(.secondary, trackID: nil) { return }
            if $0.isEmpty { secondaryTrack = LTRAuthoredSubtitles.Track() }
            secondary = secondaryTrack.laidOutAsAuthored($0, trackID: nil)
            secondaryCursor.reset(secondary)
            aetherSourceTime = engine.clock.sourceTime
        }
        .onReceive(engine.clock.$sourceTime) { time in
            guard needsEngineClock else { return }
            aetherSourceTime = time
        }
        // A delay change or timeline switch moves every cue clock at once. A
        // switch can start reading the engine clock, whose ticks were skipped
        // while nothing needed them, so it resyncs before repositioning.
        .onChange(of: subtitleSyncMs) { _, _ in repositionCursors() }
        .onChange(of: primaryUsesMovieTimeline) { _, _ in
            aetherSourceTime = engine.clock.sourceTime
            primaryCursor.reposition()
        }
        .onChange(of: secondaryUsesMovieTimeline) { _, _ in
            aetherSourceTime = engine.clock.sourceTime
            secondaryCursor.reposition()
        }
    }

    private func repositionCursors() {
        primaryCursor.reposition()
        secondaryCursor.reposition()
        livePrimaryCursor.reposition()
        liveSecondaryCursor.reposition()
    }

    static func renderClock(movieTime: Double, engineTime: Double, usesMovieTimeline: Bool, delaySeconds: Double) -> Double {
        (usesMovieTimeline ? movieTime : engineTime) - delaySeconds
    }

    private func activeCues(_ cursor: SubtitleCueCursor<SubtitleCue>, usesMovieTimeline: Bool) -> [SubtitleCue] {
        // Complete sidecars use original movie timestamps; embedded cues use
        // the served stream's clock, which may be rebased by a server remux.
        let renderClock = Self.renderClock(movieTime: sourceTime, engineTime: aetherSourceTime,
                                          usesMovieTimeline: usesMovieTimeline, delaySeconds: subtitleDelaySeconds)
        return cursor.active(at: renderClock)
    }

    private func activeLiveCues(
        _ cursor: SubtitleCueCursor<LiveSubtitleCue>,
        in cues: [LiveSubtitleCue]
    ) -> [LiveSubtitleCue] {
        cursor.active(at: sourceTime - subtitleDelaySeconds, in: cues)
    }

    @ViewBuilder
    private func liveCueLayer(
        _ cues: [LiveSubtitleCue],
        style: AetherSubtitleRenderStyle,
        videoRect: CGRect,
        secondary: Bool
    ) -> some View {
        ForEach(cues) { cue in
            positionedText(
                styledPlainText(cue.text, style: style, videoRect: videoRect),
                placement: nil,
                style: style,
                videoRect: videoRect,
                secondary: secondary
            )
        }
    }

    @ViewBuilder
    private func cueLayer(
        _ cues: [SubtitleCue],
        style: AetherSubtitleRenderStyle,
        videoRect: CGRect,
        secondary: Bool
    ) -> some View {
        ForEach(cues) { cue in
            switch cue.body {
            case .image(let subtitleImage):
                let rect = bitmapRect(subtitleImage, videoRect: videoRect)
                Image(decorative: subtitleImage.cgImage, scale: 1)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            case .text(let value):
                positionedText(
                    styledPlainText(value, style: style, videoRect: videoRect),
                    placement: cue.placement,
                    style: style,
                    videoRect: videoRect,
                    secondary: secondary
                )
            case .richText(let runs):
                positionedText(
                    runs.reduce(Text("")) { accumulated, run in
                        Text("\(accumulated)\(styledText(run, style: style, videoRect: videoRect))")
                    },
                    placement: cue.placement,
                    style: style,
                    videoRect: videoRect,
                    secondary: secondary
                )
            }
        }
    }

    private func positionedText(
        _ text: Text,
        placement: SubtitleTextPlacement?,
        style: AetherSubtitleRenderStyle,
        videoRect: CGRect,
        secondary: Bool
    ) -> some View {
        let rendered = decoratedText(text, style: style, videoRect: videoRect)

        return Group {
            if let position = placement?.position {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: alignment(for: placement?.alignment)) {
                        rendered
                    }
                    .position(
                        x: videoRect.minX + position.x * videoRect.width,
                        y: videoRect.minY + position.y * videoRect.height
                    )
            } else {
                let resolved = defaultPlacement(
                    authoredAlignment: placement?.alignment,
                    position: style.position,
                    videoRect: videoRect,
                    secondary: secondary
                )
                Color.clear
                    .overlay(alignment: resolved.alignment) {
                        rendered
                            .padding(resolved.insets)
                            .padding(.horizontal, videoRect.width * 0.04)
                    }
                    .frame(
                        width: videoRect.width,
                        height: videoRect.height
                    )
                    .position(x: videoRect.midX, y: videoRect.midY)
            }
        }
    }

    private func decoratedText(_ text: Text, style: AetherSubtitleRenderStyle, videoRect: CGRect) -> some View {
        let scale = playfieldScale(for: videoRect)
        let edgeOffset = max(
            0.5,
            min(2, style.fontSizeAt1080Lines * 0.03) * scale
        )
        let outline = style.drawsOutline ? color(style.outlineColor) : .clear
        let raised = style.drawsRaisedEdge ? Color.white.opacity(0.8) : .clear
        let depressed = style.drawsDepressedEdge ? Color.black.opacity(0.9) : .clear
        let dropShadow = style.drawsDropShadow ? Color.black.opacity(0.85) : .clear
        let boxHorizontalPadding = style.drawsBox ? max(6, 10 * scale) : 0
        let boxVerticalPadding = style.drawsBox ? max(3, 5 * scale) : 0
        let windowHorizontalPadding = style.windowOpacity > 0 ? max(4, 6 * scale) : 0
        let windowVerticalPadding = style.windowOpacity > 0 ? max(3, 4 * scale) : 0

        return text
            .multilineTextAlignment(.center)
            .shadow(color: outline, radius: 0, x: edgeOffset, y: edgeOffset)
            .shadow(color: outline, radius: 0, x: -edgeOffset, y: edgeOffset)
            .shadow(color: outline, radius: 0, x: edgeOffset, y: -edgeOffset)
            .shadow(color: outline, radius: 0, x: -edgeOffset, y: -edgeOffset)
            .shadow(color: raised, radius: 0, x: -edgeOffset, y: -edgeOffset)
            .shadow(color: depressed, radius: 0, x: edgeOffset, y: edgeOffset)
            .shadow(
                color: dropShadow,
                radius: max(1, 3 * scale),
                x: max(0.5, 1.5 * scale),
                y: max(0.5, 2 * scale)
            )
            .padding(.horizontal, boxHorizontalPadding)
            .padding(.vertical, boxVerticalPadding)
            .background {
                if style.drawsBox {
                    RoundedRectangle(cornerRadius: max(2, 5 * scale), style: .continuous)
                        .fill(color(style.boxColor, opacity: style.boxOpacity))
                }
            }
            .padding(.horizontal, windowHorizontalPadding)
            .padding(.vertical, windowVerticalPadding)
            .background {
                if style.windowOpacity > 0 {
                    RoundedRectangle(
                        cornerRadius: style.windowCornerRadiusAt1080Lines * scale,
                        style: .continuous
                    )
                    .fill(color(style.windowColor, opacity: style.windowOpacity))
                }
            }
            .frame(maxWidth: videoRect.width * 0.86)
    }

    private struct ResolvedPlacement {
        let alignment: Alignment
        let insets: EdgeInsets
    }

    private func defaultPlacement(
        authoredAlignment: Int?,
        position: AetherSubtitleRenderStyle.Position,
        videoRect: CGRect,
        secondary: Bool
    ) -> ResolvedPlacement {
        if let authoredAlignment {
            let inset = videoRect.height * (secondary ? 0.17 : 0.08)
            switch authoredAlignment {
            case 7...9:
                return ResolvedPlacement(
                    alignment: alignment(for: authoredAlignment),
                    insets: EdgeInsets(top: inset, leading: 0, bottom: 0, trailing: 0)
                )
            case 1...3:
                return ResolvedPlacement(
                    alignment: alignment(for: authoredAlignment),
                    insets: EdgeInsets(top: 0, leading: 0, bottom: inset, trailing: 0)
                )
            default:
                return ResolvedPlacement(
                    alignment: alignment(for: authoredAlignment),
                    insets: EdgeInsets()
                )
            }
        }

        switch position {
        case .top:
            return ResolvedPlacement(
                alignment: .top,
                insets: EdgeInsets(
                    top: videoRect.height * (secondary ? 0.17 : 0.08),
                    leading: 0,
                    bottom: 0,
                    trailing: 0
                )
            )
        case .lowerThird:
            return ResolvedPlacement(
                alignment: .bottom,
                insets: EdgeInsets(
                    top: 0,
                    leading: 0,
                    bottom: videoRect.height * (secondary ? 0.36 : 0.27),
                    trailing: 0
                )
            )
        case .bottom:
            return ResolvedPlacement(
                alignment: .bottom,
                insets: EdgeInsets(
                    top: 0,
                    leading: 0,
                    bottom: videoRect.height * (secondary ? 0.17 : 0.08),
                    trailing: 0
                )
            )
        }
    }

    private func alignment(for assAlignment: Int?) -> Alignment {
        switch assAlignment {
        case 1: return .bottomLeading
        case 2: return .bottom
        case 3: return .bottomTrailing
        case 4: return .leading
        case 5: return .center
        case 6: return .trailing
        case 7: return .topLeading
        case 8: return .top
        case 9: return .topTrailing
        default: return .center
        }
    }

    private func displayedVideoRect(in surfaceSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: surfaceSize)
        if let nativeRect = engine.nativePlayerLayer?.videoRect,
           nativeRect.width > 0,
           nativeRect.height > 0 {
            return nativeRect
        }
        guard let displaySize = engine.softwareDisplaySize,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return bounds
        }
        switch engine.videoGravity {
        case .resize:
            return bounds
        case .resizeAspectFill:
            let scale = max(bounds.width / displaySize.width, bounds.height / displaySize.height)
            let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            return CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        default:
            let scale = min(bounds.width / displaySize.width, bounds.height / displaySize.height)
            let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            return CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    private func bitmapRect(_ image: SubtitleImage, videoRect: CGRect) -> CGRect {
        let canvasRect: CGRect
        if image.canvasSize.width > 0, image.canvasSize.height > 0 {
            let scale = videoRect.width / image.canvasSize.width
            let canvasHeight = image.canvasSize.height * scale
            canvasRect = CGRect(
                x: videoRect.minX,
                y: videoRect.midY - canvasHeight / 2,
                width: videoRect.width,
                height: canvasHeight
            )
        } else {
            canvasRect = videoRect
        }
        return CGRect(
            x: canvasRect.minX + image.position.minX * canvasRect.width,
            y: canvasRect.minY + image.position.minY * canvasRect.height,
            width: image.position.width * canvasRect.width,
            height: image.position.height * canvasRect.height
        )
    }

    private func styledPlainText(_ value: String, style: AetherSubtitleRenderStyle, videoRect: CGRect) -> Text {
        Text(value)
            .font(font(style.fontFamily, size: scaledFontSize(
                style.fontSizeAt1080Lines,
                videoRect: videoRect
            )))
            .foregroundColor(color(
                style.foreground,
                opacity: style.foregroundOpacity
            ))
    }

    /// Aether's rich runs are authored content. Each authored color/font/size
    /// wins unless MediaAccessibility marked that field as a required system
    /// override. Missing authored values still inherit Silo's effective style.
    private func styledText(_ run: SubtitleTextRun, style: AetherSubtitleRenderStyle, videoRect: CGRect) -> Text {
        var text = Text(run.text)

        let hasAuthoredColor = run.color != nil
        let usesAuthoredColor = hasAuthoredColor
            && !style.contentOverrides.contains(.foregroundColor)
        let resolvedColor: AetherSubtitleRenderStyle.RGB
        if usesAuthoredColor, let authored = run.color {
            resolvedColor = AetherSubtitleRenderStyle.RGB(
                red: Double(authored.r) / 255,
                green: Double(authored.g) / 255,
                blue: Double(authored.b) / 255
            )
        } else {
            resolvedColor = style.foreground
        }
        let resolvedOpacity = hasAuthoredColor
            && !style.contentOverrides.contains(.foregroundOpacity)
            ? 1
            : style.foregroundOpacity
        text = text.foregroundColor(color(resolvedColor, opacity: resolvedOpacity))

        let resolvedFamily: AetherSubtitleRenderStyle.FontFamily
        if let authored = run.fontName,
           !style.contentOverrides.contains(.font) {
            resolvedFamily = .custom(authored)
        } else {
            resolvedFamily = style.fontFamily
        }
        let resolvedSize = run.fontSize.map(Double.init).flatMap { authored -> Double? in
            style.contentOverrides.contains(.size) ? nil : authored
        } ?? style.fontSizeAt1080Lines
        text = text.font(font(
            resolvedFamily,
            size: scaledFontSize(resolvedSize, videoRect: videoRect)
        ))

        if run.isBold { text = text.bold() }
        if run.isItalic { text = text.italic() }
        if run.isUnderlined { text = text.underline() }
        if run.isStruckThrough { text = text.strikethrough() }
        return text
    }

    private func font(_ family: AetherSubtitleRenderStyle.FontFamily, size: CGFloat) -> Font {
        switch family {
        case .sansSerif:
            return .system(size: size, weight: .semibold)
        case .serif:
            return .system(size: size, weight: .semibold, design: .serif)
        case .monospace:
            return .system(size: size, weight: .semibold, design: .monospaced)
        case .custom(let name):
            return .custom(name, size: size)
        }
    }

    private func scaledFontSize(_ points: Double, videoRect: CGRect) -> CGFloat {
        max(8, CGFloat(points) * playfieldScale(for: videoRect))
    }

    private func playfieldScale(for videoRect: CGRect) -> CGFloat {
        max(0.01, videoRect.height / 1_080)
    }

    private func color(
        _ rgb: AetherSubtitleRenderStyle.RGB,
        opacity: Double = 1
    ) -> Color {
        Color(
            .sRGB,
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            opacity: max(0, min(1, opacity))
        )
    }
}
