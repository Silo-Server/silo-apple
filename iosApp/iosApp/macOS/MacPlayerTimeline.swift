#if os(macOS)
import SwiftUI

struct MacPlayerTimeline: View {
    let viewModel: PlayerViewModel

    @State private var hoverFraction: Double?
    @State private var isDragging = false

    private var displayTime: Double {
        if isDragging {
            return viewModel.scrubPreviewTime
        }
        if let hoverFraction, viewModel.duration > 0 {
            return hoverFraction * viewModel.duration
        }
        return viewModel.currentTime
    }

    private var progressFraction: Double {
        guard viewModel.duration > 0 else { return 0 }
        let time = viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
        return min(max(time / viewModel.duration, 0), 1)
    }

    private var bufferedFraction: Double {
        viewModel.bufferedFraction
    }

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.24))
                        .frame(height: 5)

                    let bufferedAhead = max(0, bufferedFraction - progressFraction)
                    if bufferedAhead > 0 {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.30))
                            .frame(width: width * bufferedAhead, height: 5)
                            .offset(x: width * progressFraction)
                    }

                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .frame(width: width * progressFraction, height: 5)

                    chapterTicks(width: width)

                    Circle()
                        .fill(Color.white)
                        .frame(width: isHoveringOrDragging ? 14 : 10, height: isHoveringOrDragging ? 14 : 10)
                        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                        .offset(x: width * progressFraction - (isHoveringOrDragging ? 7 : 5))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverFraction = fraction(for: point.x, width: width)
                    case .ended:
                        hoverFraction = nil
                    }
                }
            }
            .frame(height: 24)

            HStack {
                Text(PlayerTimeFormatter.formatHMS(displayTime))
                    .foregroundStyle(.white)
                Spacer()
                if viewModel.duration > 0 {
                    Text("-\(PlayerTimeFormatter.formatHMS(max(0, viewModel.duration - displayTime)))")
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    Text("--:--")
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
        }
    }

    private var isHoveringOrDragging: Bool {
        hoverFraction != nil || isDragging || viewModel.isScrubbing
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard viewModel.duration > 0 else { return }
                let nextFraction = fraction(for: value.location.x, width: width)
                if !isDragging {
                    isDragging = true
                    viewModel.beginScrub(fraction: nextFraction)
                } else {
                    viewModel.updateScrub(fraction: nextFraction)
                }
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                viewModel.endScrub()
            }
    }

    private func fraction(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    @ViewBuilder
    private func chapterTicks(width: CGFloat) -> some View {
        if viewModel.duration > 0 {
            ForEach(viewModel.chapters) { chapter in
                let fraction = min(max(chapter.time / viewModel.duration, 0), 1)
                if fraction > 0.001 {
                    Rectangle()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: 1.5, height: 13)
                        .offset(x: width * fraction - 0.75)
                }
            }
        }
    }
}
#endif
