import SwiftUI

#if !os(tvOS)
/// Shown when the chosen server has no account yet (`/api/v2/system/setup`
/// reports `needsSetup`). Account provisioning is intentionally unavailable
/// in the Apple clients, so this screen only lets the user re-probe the server
/// after its administrator finishes setup elsewhere.
struct ServerNeedsSetupView: View {
    var router: AppRouter
    @State private var isChecking = false
    @State private var error: String?
    @State private var retryTask: Task<Void, Never>?

    private var serverURL: String { AuthService.shared.serverUrl }

    private var hostLabel: String {
        guard let url = URL(string: serverURL), let host = url.host else { return serverURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    var body: some View {
        MarqueeStage(scrim: .bottom, frostStart: 0.45, onBack: changeServer) {
            MarqueeTopBar {
                MarqueeIconButton(systemImage: "chevron.left", accessibilityLabel: "Change server", action: changeServer)
            } trailing: { EmptyView() }
        } content: {
            MarqueeServerCard(
                name: hostLabel,
                address: serverURL,
                showsInitial: false,
                badge: .init(text: "Setup needed", systemImage: "clock", tone: .warning),
                status: .init(text: "Reachable · not set up yet", tone: .warning)
            )
            MarqueeHeadline(
                title: "This server isn't ready",
                lead: "Ask the server administrator to finish setup. When it's ready, return here and check again."
            )
            .padding(.top, 26)

            if let error {
                MarqueeErrorText(error)
                    .padding(.top, 14)
            }

            Button(action: retry) {
                Text(isChecking ? "Checking…" : "Check again")
            }
            .buttonStyle(.marquee(.primary, isLoading: isChecking))
            .disabled(isChecking)
            .padding(.top, 26)

            if let url = URL(string: serverURL) {
                Link(destination: url) {
                    Label("Open setup in your browser", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.marqueeGlass)
                .padding(.top, 12)
            }

            Button("Change server", action: changeServer)
                .buttonStyle(.marqueePlain)
                .padding(.top, 6)
        }
        .animation(.easeInOut(duration: 0.2), value: error)
        .navigationBarBackButtonHidden()
        .marqueeTransparentNavigation()
        .onDisappear(perform: cancelRetry)
    }

    /// Re-probe the current server. If it's now set up, pop back to the login
    /// screen (this view sits on top of `LoginView` in the `.needsLogin`
    /// stack). Otherwise surface a gentle nudge.
    private func retry() {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        let expectedServerURL = AuthService.shared.serverUrl
        retryTask = Task {
            do {
                let status = try await AuthService.shared.checkServer(url: expectedServerURL)
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
                    self.error = "Couldn't reach the server. Check it's running and try again."
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
