import SwiftUI

/// Full-screen startup treatment shown while the app resolves its initial auth
/// route. This is deliberately a native SwiftUI animation: AetherEngine remains
/// the only production media engine constructed by Silo.
struct StartupSplashView: View {
    private static let maximumDisplayDuration: Duration = .seconds(4)

    let onFinished: () -> Void

    @State private var completionTask: Task<Void, Never>?
    @State private var isAnimating = false
    @State private var didFinish = false

    var body: some View {
        ZStack {
            Color.continuumBackground.ignoresSafeArea()

            VStack(spacing: 22) {
                SiloWordmarkView(width: wordmarkWidth)
                    .scaleEffect(isAnimating ? 1 : 0.94)
                    .opacity(isAnimating ? 1 : 0.45)

                ProgressView()
                    .tint(.continuumOnSurface)
                    .scaleEffect(1.15)
                    .opacity(isAnimating ? 1 : 0.55)
            }
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isAnimating
            )
        }
        .accessibilityLabel("Loading Silo")
        .onAppear {
            isAnimating = true
            scheduleCompletion()
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
        }
    }

    private var wordmarkWidth: CGFloat {
        #if os(tvOS)
        220
        #elseif os(macOS)
        170
        #else
        150
        #endif
    }

    private func scheduleCompletion() {
        guard completionTask == nil else { return }
        completionTask = Task {
            try? await Task.sleep(for: Self.maximumDisplayDuration)
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
