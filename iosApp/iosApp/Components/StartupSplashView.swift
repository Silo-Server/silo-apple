import SwiftUI

/// The brand splash (mark drops in, bars stack, the wordmark slides out from
/// behind), played in full on every launch over the app as it loads. Drawn
/// with a SwiftUI `Canvas` from the baked keyframes in `StartupSplashAnimation`.
struct StartupSplashView: View {
    private static let displayDuration: Duration = .seconds(4)

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date?

    var body: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()

            GeometryReader { proxy in
                let size = surfaceSize(in: proxy.size)
                TimelineView(.animation(paused: reduceMotion)) { context in
                    StartupSplashCanvas(frame: frame(at: context.date))
                }
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .ignoresSafeArea()
        }
        .accessibilityLabel("Loading Silo")
        .task {
            startDate = Date()
            try? await Task.sleep(for: reduceMotion ? .seconds(1) : Self.displayDuration)
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    /// Same footprint as the original 16:9 splash video on each platform.
    private func surfaceSize(in container: CGSize) -> CGSize {
        let width: CGFloat
        #if os(tvOS)
        width = min(container.width * 0.25, 440)
        #elseif os(iOS)
        width = min(container.width * 0.6, 320)
        #else
        width = container.width
        #endif
        let aspect = StartupSplashAnimation.compositionSize.height
            / StartupSplashAnimation.compositionSize.width
        return CGSize(width: width, height: width * aspect)
    }

    private func frame(at date: Date) -> Double {
        let last = Double(StartupSplashAnimation.frameCount - 1)
        if reduceMotion { return last }
        guard let startDate else { return 0 }
        let elapsed = date.timeIntervalSince(startDate)
        return min(max(elapsed * StartupSplashAnimation.framesPerSecond, 0), last)
    }
}

/// Paints one frame of the splash. Layers are drawn in the generated order
/// so the mark occludes the wordmark while it slides out from behind it.
private struct StartupSplashCanvas: View {
    let frame: Double

    /// Each layer's outline, built once; a frame only transforms it.
    private static let layerPaths: [Path] = StartupSplashAnimation.layers.map { layer in
        var path = Path()
        for shape in layer.paths {
            path.move(to: CGPoint(x: shape.start.0, y: shape.start.1))
            for segment in shape.segments {
                path.addCurve(to: segment.end, control1: segment.c1, control2: segment.c2)
            }
            path.closeSubpath()
        }
        return path
    }

    private static let layerColors: [Color] = StartupSplashAnimation.layers.map {
        Color(red: $0.color.r, green: $0.color.g, blue: $0.color.b)
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let scale = size.width / StartupSplashAnimation.compositionSize.width
            context.scaleBy(x: scale, y: scale)

            for (index, layer) in StartupSplashAnimation.layers.enumerated() where frame >= layer.inPoint {
                let position = Self.interpolate(layer.position, at: frame)
                let layerScale = Self.interpolate(layer.scale, at: frame)
                let transform = CGAffineTransform(translationX: position.x, y: position.y)
                    .scaledBy(x: layerScale.x / 100, y: layerScale.y / 100)
                    .translatedBy(x: -layer.anchor.x, y: -layer.anchor.y)
                context.fill(
                    Self.layerPaths[index].applying(transform),
                    with: .color(Self.layerColors[index]),
                    style: FillStyle(eoFill: true)
                )
            }
        }
    }

    /// Linear interpolation between neighbouring keyframes; the source
    /// animation bakes its easing into dense keyframes.
    private static func interpolate(_ keyframes: [StartupSplashAnimation.K], at frame: Double) -> CGPoint {
        guard let first = keyframes.first else { return .zero }
        if frame <= first.t || keyframes.count == 1 { return point(first) }
        for index in 1..<keyframes.count {
            let next = keyframes[index]
            guard frame <= next.t else { continue }
            let previous = keyframes[index - 1]
            let span = next.t - previous.t
            let progress = span > 0 ? (frame - previous.t) / span : 1
            return CGPoint(
                x: previous.v[0] + (next.v[0] - previous.v[0]) * progress,
                y: previous.v[1] + (next.v[1] - previous.v[1]) * progress
            )
        }
        return point(keyframes[keyframes.count - 1])
    }

    private static func point(_ keyframe: StartupSplashAnimation.K) -> CGPoint {
        CGPoint(x: keyframe.v[0], y: keyframe.v[1])
    }
}

extension EnvironmentValues {
    /// True while the startup splash covers the app being built underneath it.
    @Entry var isStartupSplashVisible = false
}
