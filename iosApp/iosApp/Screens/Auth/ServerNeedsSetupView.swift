import SwiftUI

#if !os(tvOS)
/// Shown when the chosen server has no account yet (`/api/v2/system/setup`
/// reports `needsSetup`). Account provisioning is intentionally unavailable
/// in the Apple clients, so this screen only lets the user re-probe the server
/// after its administrator finishes setup elsewhere.
struct ServerNeedsSetupView: View {
    var router: AppRouter
    @State private var retryModel = ServerNeedsSetupRetryModel()
    @Environment(\.locale) private var locale

    private var serverURL: String { AuthService.shared.serverUrl }

    var body: some View {
        MarqueeStage(scrim: .bottom, frostStart: 0.45, onBack: changeServer) {
            MarqueeTopBar {
                MarqueeIconButton(systemImage: "chevron.backward", accessibilityLabel: AppLanguage.string(.commonChangeServer), action: changeServer)
            } trailing: { EmptyView() }
        } content: {
            MarqueeServerCard(
                name: ServerBranding.hostLabel(serverURL),
                address: serverURL,
                showsInitial: false,
                badge: .init(text: AppLanguage.string(.notReadyBadge), systemImage: "clock", tone: .warning),
                status: .init(text: AppLanguage.string(.setupNotReadyStatus), tone: .warning)
            )
            MarqueeHeadline(
                title: AppLanguage.string(.setupNotReadyTitle),
                lead: AppLanguage.string(.setupNotReadyLead)
            )
            .padding(.top, 26)

            if let error = retryModel.error {
                MarqueeErrorText(error)
                    .padding(.top, 14)
            }

            Button(action: retry) {
                Text(retryModel.isChecking ? LocalizedStringResource.notReadyChecking : .notReadyCheck)
            }
            .buttonStyle(.marquee(.primary, isLoading: retryModel.isChecking))
            .disabled(retryModel.isChecking)
            .padding(.top, 26)

            if let url = URL(string: serverURL) {
                Link(destination: url) {
                    Label(.setupNotReadyOpenInBrowser, systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.marqueeGlass)
                .padding(.top, 12)
            }

            Button(.commonChangeServer, action: changeServer)
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
