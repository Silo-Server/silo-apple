import SwiftUI

/// Hosts the ASS overlay layer over the displayed video. The layer presents
/// each canvas on the video's own clock; this view's lifetime bounds the loop
/// that keeps it rendered a fraction of a second ahead.
struct ASSSubtitleLayer: View {
    let session: ASSSubtitleSession
    let videoRect: CGRect
    let delaySeconds: Double
    @Environment(\.displayScale) private var displayScale

    private struct RenderSize: Hashable {
        let width: Double
        let height: Double
        let scale: Double
        let delay: Double
    }

    var body: some View {
        ZStack {
            if let layer = session.overlayLayer {
                ASSLayerHost(hosted: layer)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
            }
            if let message = session.failureMessage {
                status(message)
            } else if session.isLoadingFonts {
                status("Loading subtitle fonts…")
            }
        }
        .onAppear { session.overlayWillAppear() }
        .task(id: RenderSize(width: videoRect.width, height: videoRect.height,
                             scale: displayScale, delay: delaySeconds)) {
            while !Task.isCancelled {
                await session.step(size: videoRect.size, scale: displayScale, delaySeconds: delaySeconds)
                // Each step queues frames 0.3 s ahead, so a late wake-up
                // costs nothing on screen.
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
        }
    }

    private func status(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            .position(x: videoRect.midX, y: videoRect.maxY - videoRect.height * 0.1)
    }
}

#if os(macOS)
private struct ASSLayerHost: NSViewRepresentable {
    let hosted: CALayer

    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ view: HostView, context: Context) { view.host(hosted) }

    final class HostView: NSView {
        private var hostedLayer: CALayer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        func host(_ layer: CALayer) {
            guard layer !== hostedLayer else { return }
            hostedLayer?.removeFromSuperlayer()
            hostedLayer = layer
            self.layer?.addSublayer(layer)
            needsLayout = true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
private struct ASSLayerHost: UIViewRepresentable {
    let hosted: CALayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: HostView, context: Context) { view.host(hosted) }

    final class HostView: UIView {
        private var hostedLayer: CALayer?

        func host(_ layer: CALayer) {
            guard layer !== hostedLayer else { return }
            hostedLayer?.removeFromSuperlayer()
            hostedLayer = layer
            self.layer.addSublayer(layer)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
