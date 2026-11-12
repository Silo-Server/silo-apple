#if os(tvOS)
import SwiftUI

/// Recovery screen for a server that still needs administrator provisioning.
/// Account creation stays outside the Apple client while viewers retain a way
/// to retry the current server or choose another one.
struct TVServerNeedsSetupView: View {
    var router: AppRouter

    @State private var retryModel = ServerNeedsSetupRetryModel()
    @Environment(\.locale) private var locale
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
                badge: .init(text: AppLanguage.string(.notReadyBadge), systemImage: "clock", tone: .warning)
            )
            .fixedSize(horizontal: true, vertical: false)
            Text(.notReadyHeadline)
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-2)
                .foregroundStyle(Color.siloOnSurface)
                .padding(.top, 52)
                .accessibilityAddTraits(.isHeader)
            MarqueeTVBody(AppLanguage.string(.notReadyBody))
                .padding(.top, 26)

            if let error = retryModel.error {
                MarqueeErrorText(error)
                    .padding(.top, 20)
            }

            HStack(spacing: 22) {
                Button(action: retry) {
                    Label(retryModel.isChecking ? LocalizedStringResource.notReadyChecking : .notReadyCheck, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: retryModel.isChecking))
                .focused($focusedAction, equals: .retry)
                // Not disabled while checking: a disabled button loses focus,
                // so it would land on Change server. `retry` ignores repeats.

                Button(.commonChangeServer, action: changeServer)
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
        .animation(.easeInOut(duration: 0.2), value: retryModel.error)
        .onDisappear { retryModel.cancel() }
    }

    private var hostLabel: String {
        let serverURL = AuthService.shared.serverUrl
        guard let url = URL(string: serverURL), let host = url.host else { return serverURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private func retry() {
        retryModel.retry { router.goBack() }
    }

    private func changeServer() {
        retryModel.cancel()
        router.resetToServerSetup()
    }
}
#endif
