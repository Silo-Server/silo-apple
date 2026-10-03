#if os(tvOS)
import SwiftUI

/// Recovery screen for a server that still needs administrator provisioning.
/// Account creation stays outside the Apple client while viewers retain a way
/// to retry the current server or choose another one.
struct TVServerNeedsSetupView: View {
    var router: AppRouter

    @State private var isChecking = false
    @State private var error: String?
    @State private var retryTask: Task<Void, Never>?
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case retry
        case changeServer
    }

    var body: some View {
        MarqueeTVScreen {
            MarqueeServerCard(
                name: hostLabel,
                address: AuthService.shared.serverUrl,
                showsInitial: false,
                badge: .init(text: "Setup needed", systemImage: "clock", tone: .warning)
            )
            .fixedSize(horizontal: true, vertical: false)
            Text("This server\nisn't ready")
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-2)
                .foregroundStyle(Color.siloOnSurface)
                .padding(.top, 52)
                .accessibilityAddTraits(.isHeader)
            MarqueeTVBody("Ask the server administrator to finish setup. When it is ready, check again.")
                .padding(.top, 26)

            if let error {
                MarqueeErrorText(error)
                    .padding(.top, 20)
            }

            HStack(spacing: 22) {
                Button(action: retry) {
                    Label(isChecking ? "Checking…" : "Check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: isChecking))
                .focused($focusedAction, equals: .retry)
                // Not disabled while checking: a disabled button loses focus,
                // so it would land on Change server. `retry` ignores repeats.

                Button("Change server", action: changeServer)
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focusedAction, equals: .changeServer)
            }
            .padding(.top, 56)
            .focusSection()
        } card: {
            EmptyView()
        }
        .navigationBarBackButtonHidden()
        .defaultFocus($focusedAction, .retry, priority: .userInitiated)
        .marqueeTVSeedFocus($focusedAction, .retry)
        .animation(.easeInOut(duration: 0.2), value: error)
        .onDisappear(perform: cancelRetry)
    }

    private var hostLabel: String {
        let serverURL = AuthService.shared.serverUrl
        guard let url = URL(string: serverURL), let host = url.host else { return serverURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private func retry() {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        let expectedServerURL = AuthService.shared.serverUrl

        retryTask = Task {
            do {
                let status = try await AuthService.shared.checkServer(
                    url: expectedServerURL
                )
                await MainActor.run {
                    isChecking = false
                    guard !Task.isCancelled,
                          AuthService.shared.serverUrl == expectedServerURL else { return }
                    if status.needsSetup {
                        error = "This server still needs administrator setup."
                    } else {
                        router.goBack()
                    }
                }
            } catch {
                await MainActor.run {
                    isChecking = false
                    guard !Task.isCancelled else { return }
                    self.error = "Could not reach the server. Check that it is running and try again."
                }
            }
        }
    }

    private func changeServer() {
        cancelRetry()
        router.resetToServerSetup()
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        isChecking = false
    }
}
#endif
