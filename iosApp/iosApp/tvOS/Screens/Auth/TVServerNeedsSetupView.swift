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
                            .font(.continuumTitle)
                            .foregroundStyle(Color.auroraInk)
                        Text("Ask the server administrator to finish setup. When it is ready, check again.")
                            .font(.continuumBody)
                            .foregroundStyle(Color.auroraInkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.continuumCaption)
                            .foregroundStyle(Color.requestRose)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Error: \(error)")
                    }

                    HStack(spacing: 24) {
                        Button(action: retry) {
                            Label(
                                isChecking ? "Checking…" : "Check again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))
                        .focused($focusedAction, equals: .retry)
                        .disabled(isChecking)

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
        .animation(.easeInOut(duration: 0.2), value: error)
        .onDisappear(perform: cancelRetry)
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
