import SwiftUI

/// Full-screen startup treatment shown while the app resolves its initial auth
/// route. It replays the brand splash (mark drops in, bars stack, the wordmark
/// slides out from behind) as a native SwiftUI `Canvas` driven by the baked
/// keyframes in `StartupSplashAnimation`. No AVPlayer is involved: AetherEngine
/// remains the only production media engine constructed by Silo.
struct StartupSplashView: View {
    private static let maximumDisplayDuration: Duration = .seconds(4)

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionTask: Task<Void, Never>?
    @State private var didFinish = false
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
        .onAppear {
            startDate = Date()
            scheduleCompletion()
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
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

    private func scheduleCompletion() {
        guard completionTask == nil else { return }
        let duration: Duration = reduceMotion ? .seconds(1) : Self.maximumDisplayDuration
        completionTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        completionTask?.cancel()
        completionTask = nil
        onFinished()
    }
}

/// Paints one frame of the splash. Layers are drawn in the generated order
/// so the mark occludes the wordmark while it slides out from behind it.
private struct StartupSplashCanvas: View {
    let frame: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let composition = StartupSplashAnimation.compositionSize
            let scale = size.width / composition.width
            context.scaleBy(x: scale, y: scale)

            for layer in StartupSplashAnimation.layers where frame >= layer.inPoint {
                let position = Self.interpolate(layer.position, at: frame)
                let layerScale = Self.interpolate(layer.scale, at: frame)

                var transform = CGAffineTransform.identity
                transform = transform.translatedBy(x: position[0], y: position[1])
                transform = transform.scaledBy(x: layerScale[0] / 100, y: layerScale[1] / 100)
                transform = transform.translatedBy(x: -layer.anchor.x, y: -layer.anchor.y)

                var path = Path()
                for shape in layer.paths {
                    path.move(to: CGPoint(x: shape.start.0, y: shape.start.1))
                    for segment in shape.segments {
                        path.addCurve(to: segment.end, control1: segment.c1, control2: segment.c2)
                    }
                    path.closeSubpath()
                }

                let color = Color(red: layer.color.r, green: layer.color.g, blue: layer.color.b)
                context.fill(path.applying(transform), with: .color(color), style: FillStyle(eoFill: true))
            }
        }
    }

    /// Linear interpolation between neighbouring keyframes; the source
    /// animation bakes its easing into dense keyframes.
    private static func interpolate(_ keyframes: [StartupSplashAnimation.K], at frame: Double) -> [Double] {
        guard let first = keyframes.first else { return [0, 0] }
        if frame <= first.t || keyframes.count == 1 { return first.v }
        for index in 1..<keyframes.count {
            let next = keyframes[index]
            guard frame <= next.t else { continue }
            let previous = keyframes[index - 1]
            let span = next.t - previous.t
            let progress = span > 0 ? (frame - previous.t) / span : 1
            return zip(previous.v, next.v).map { $0 + ($1 - $0) * progress }
        }
        return keyframes[keyframes.count - 1].v
    }
}
