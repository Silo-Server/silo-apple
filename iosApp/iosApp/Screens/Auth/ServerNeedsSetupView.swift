import SwiftUI

#if !os(tvOS)
/// Shown when the chosen server has no account yet (`/api/v1/auth/setup`
/// reports `needsSetup`). Account provisioning is intentionally unavailable
/// in the Apple clients, so this screen only lets the user re-probe the server
/// after its administrator finishes setup elsewhere.
struct ServerNeedsSetupView: View {
    var router: AppRouter
    @State private var isChecking = false
    @State private var error: String?
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            SiloWordmarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)

            AuroraJourneyProgress(currentStep: 1)
                .frame(maxWidth: 330)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)

            AuroraEyebrow(text: "Server setup", centered: true)
                .padding(.bottom, 16)

            ZStack {
                Circle().fill(Color.auroraAccent.opacity(0.14))
                Circle().stroke(Color.auroraAccent.opacity(0.34), lineWidth: 1)
                Image(systemName: "gearshape.2")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.auroraAccent)
            }
            .frame(width: 78, height: 78)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            VStack(spacing: 12) {
                Text("This server isn't ready")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text("Ask the server administrator to finish setup. When it's ready, return here and check again.")
                    .font(.continuumBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 22)

            VStack(spacing: 16) {
                if let error {
                    AuroraErrorLabel(error)
                }

                Button(action: retry) {
                    Text(isChecking ? "Checking…" : "Check again")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))
                .disabled(isChecking)

                Button("Change server", action: changeServer)
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: error)
        }
        .navigationBarBackButtonHidden()
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
