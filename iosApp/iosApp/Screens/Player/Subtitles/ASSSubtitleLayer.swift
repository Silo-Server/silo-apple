import SwiftUI

/// The layer's lifetime bounds the render loop. Awaiting each render prevents
/// queued frames from accumulating when a complex ASS animation is expensive.
struct ASSSubtitleLayer: View {
    @ObservedObject var session: ASSSubtitleSession
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
            if let frame = session.frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .frame(width: frame.rect.width, height: frame.rect.height)
                    .position(x: videoRect.minX + frame.rect.midX,
                              y: videoRect.minY + frame.rect.midY)
            }
            if let message = session.failureMessage {
                status(message)
            } else if session.isLoadingFonts {
                status("Loading subtitle fonts…")
            }
        }
        .task(id: RenderSize(width: videoRect.width, height: videoRect.height,
                             scale: displayScale, delay: delaySeconds)) {
            while !Task.isCancelled {
                await session.render(size: videoRect.size, scale: displayScale, delaySeconds: delaySeconds)
                do { try await Task.sleep(for: .milliseconds(16)) }
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
