import SwiftUI

#if !os(tvOS)
/// Shown when the chosen server has no account yet (`/api/v2/system/setup`
/// reports `needsSetup`). Account provisioning is intentionally unavailable
/// in the Apple clients, so this screen only lets the user re-probe the server
/// after its administrator finishes setup elsewhere.
struct ServerNeedsSetupView: View {
    var router: AppRouter
    @State private var retryModel = ServerNeedsSetupRetryModel()

    private var serverURL: String { AuthService.shared.serverUrl }

    var body: some View {
        MarqueeStage(scrim: .bottom, frostStart: 0.45, onBack: changeServer) {
            MarqueeTopBar {
                MarqueeIconButton(systemImage: "chevron.left", accessibilityLabel: "Change server", action: changeServer)
            } trailing: { EmptyView() }
        } content: {
            MarqueeServerCard(
                name: ServerBranding.hostLabel(serverURL),
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

            if let error = retryModel.error {
                MarqueeErrorText(error)
                    .padding(.top, 14)
            }

            Button(action: retry) {
                Text(retryModel.isChecking ? "Checking…" : "Check again")
            }
            .buttonStyle(.marquee(.primary, isLoading: retryModel.isChecking))
            .disabled(retryModel.isChecking)
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
        .animation(.easeInOut(duration: 0.2), value: retryModel.error)
        .navigationBarBackButtonHidden()
        .marqueeTransparentNavigation()
        .onDisappear { retryModel.cancel() }
    }

    /// Re-probe the current server. If it's now set up, pop back to the login
    /// screen (this view sits on top of `LoginView` in the `.needsLogin`
    /// stack). Otherwise surface a gentle nudge.
    private func retry() {
        retryModel.retry { router.goBack() }
    }

    private func changeServer() {
        retryModel.cancel()
        router.resetToServerSetup()
    }
}
#endif
