import SwiftUI

#if !os(tvOS)
/// Password-first sign-in. iOS/macOS only — tvOS uses `TVLoginView`,
/// which leads with QR device-login. Here the phone *is* the device, so we go
/// straight to username/password.
struct LoginView: View {
    var router: AppRouter
    @State private var viewModel = LoginViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password }

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            SiloWordmarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

            AuroraJourneyProgress(currentStep: 2)
                .frame(maxWidth: 330)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)

            VStack(spacing: 10) {
                AuroraEyebrow(text: "Account", centered: true)
                Text("Welcome back")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
                if let host = hostLabel {
                    Label(host, systemImage: "server.rack")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.auroraInkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .overlay(Capsule().stroke(Color.continuumOutline, lineWidth: 1))
                }
                Text("Sign in to choose a profile and start watching.")
                    .font(.continuumBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                AuroraTextField(
                    label: "Username",
                    text: $viewModel.username,
                    placeholder: "yourname",
                    focus: $focusedField,
                    equals: .username,
                    contentType: .username,
                    submitLabel: .next,
                    onSubmit: { focusedField = .password }
                )

                AuroraTextField(
                    label: "Password",
                    text: $viewModel.password,
                    placeholder: "••••••",
                    focus: $focusedField,
                    equals: .password,
                    isSecure: true,
                    showsRevealToggle: true,
                    contentType: .password,
                    submitLabel: .go,
                    onSubmit: { signIn() }
                )

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    signIn()
                } label: {
                    Text(viewModel.isLoading ? "Signing in…" : "Sign in")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
                .disabled(viewModel.isLoading)
                .padding(.top, 4)

                Button("Use a different server") { router.resetToServerSetup() }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)
                .disabled(viewModel.isLoading)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
        .navigationBarBackButtonHidden()
    }

    private func signIn() {
        guard !viewModel.isLoading else { return }
        Task { await viewModel.login(router: router) }
    }

    /// Host pulled out of the active server URL so the user sees which server
    /// they're signing into. Mirrors `TVLoginView.hostLabel`.
    private var hostLabel: String? {
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            return host
        }
        return url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}
#endif
