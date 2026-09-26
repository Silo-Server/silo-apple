#if os(tvOS)
import SwiftUI

/// Recovery screen for a server that still needs administrator provisioning.
/// Account creation stays outside the Apple client while viewers retain a way
/// to retry the current server or choose another one.
struct TVServerNeedsSetupView: View {
    var router: AppRouter

    @State private var retryModel = ServerNeedsSetupRetryModel()
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case retry
        case changeServer
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: .server, scrim: .soft)

            VStack(spacing: 0) {
                HStack {
                    SiloWordmarkView(width: 132)
                    Spacer(minLength: 0)
                    AuroraJourneyProgress(currentStep: 1)
                        .frame(width: 430)
                }

                Spacer(minLength: 48)

                VStack(spacing: 28) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(Color.auroraAccent)

                    VStack(spacing: 14) {
                        AuroraEyebrow(text: "Server setup", centered: true)
                        Text("Server setup required")
                            .font(.siloTitle)
                            .foregroundStyle(Color.auroraInk)
                        Text("Ask the server administrator to finish setup. When it is ready, check again.")
                            .font(.siloBody)
                            .foregroundStyle(Color.auroraInkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = retryModel.error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.siloCaption)
                            .foregroundStyle(Color.requestRose)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Error: \(error)")
                    }

                    HStack(spacing: 24) {
                        Button(action: retry) {
                            Label(
                                retryModel.isChecking ? "Checking…" : "Check again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: retryModel.isChecking))
                        .focused($focusedAction, equals: .retry)
                        .disabled(retryModel.isChecking)

                        Button("Change server", action: changeServer)
                        .buttonStyle(AuroraGhostButtonStyle())
                        .focused($focusedAction, equals: .changeServer)
                    }
                    .focusSection()
                }
                .padding(56)
                .frame(width: 820)
                .auroraGlass(cornerRadius: 30, emphasized: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden()
        .defaultFocus($focusedAction, .retry, priority: .userInitiated)
        .animation(.easeInOut(duration: 0.2), value: retryModel.error)
        .onDisappear { retryModel.cancel() }
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
