import SwiftUI

#if !os(tvOS)
/// Emailed-invitation claim. The deep link carried the server and token, so
/// this screen asks for a password and nothing else. Mirrors SignupView's
/// Aurora treatment; the invite journey reads Server → Password → Household.
struct InviteClaimView: View {
    var router: AppRouter
    let endpoint: ServerEndpoint
    let token: String

    @State private var viewModel = InviteClaimViewModel()
    @State private var hasConfirmedServer = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case password, confirm }

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            SiloWordmarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

            AuroraJourneyProgress(
                currentStep: hasConfirmedServer ? 2 : 1,
                labels: ["Server", "Password", "Household"]
            )
                .frame(maxWidth: 330)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)

            if !hasConfirmedServer {
                serverConfirmationCard
            } else if viewModel.isLoadingInvitation {
                ProgressView()
                    .tint(Color.auroraInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else if let invitationLoadError = viewModel.invitationLoadError {
                retryCard(message: invitationLoadError)
            } else if viewModel.invitationInvalid {
                expiredCard
            } else if let invitation = viewModel.invitation {
                claimCard(invitation)
            }
        }
        .navigationBarBackButtonHidden()
        .task(id: hasConfirmedServer) {
            guard hasConfirmedServer else { return }
            await viewModel.load(endpoint: endpoint, token: token)
        }
    }

    private var serverConfirmationCard: some View {
        VStack(spacing: 14) {
            AuroraEyebrow(text: "Invitation server", centered: true)
            Text("Continue to \(endpoint.displayHost)?")
                .font(.continuumTitle)
                .foregroundStyle(Color.auroraInk)
                .multilineTextAlignment(.center)
            Text(endpoint.baseURL)
                .font(.continuumCaption.monospaced())
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("Only continue if you recognize and trust this server. It will receive the invitation token from this link.")
                .font(.continuumBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Continue") { hasConfirmedServer = true }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .padding(.top, 8)
            Button("Cancel") { router.restoreAfterCancelledInvite() }
                .buttonStyle(AuroraGhostButtonStyle())
        }
        .padding(22)
        .auroraGlass(cornerRadius: 24, emphasized: true)
    }

    private var expiredCard: some View {
        VStack(spacing: 12) {
            AuroraEyebrow(text: "Invitation", centered: true)
            Text("This invite has expired")
                .font(.continuumTitle)
                .foregroundStyle(Color.auroraInk)
                .multilineTextAlignment(.center)
            Text("The link may have been used already, revoked, or simply expired. Ask whoever invited you to send a fresh one.")
                .font(.continuumBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Back") { router.restoreAfterCancelledInvite() }
                .buttonStyle(AuroraGhostButtonStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func retryCard(message: String) -> some View {
        VStack(spacing: 12) {
            AuroraEyebrow(text: "Invitation", centered: true)
            Text("Could not load this invite")
                .font(.continuumTitle)
                .foregroundStyle(Color.auroraInk)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.continuumBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Retry") {
                Task { await viewModel.load(endpoint: endpoint, token: token) }
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .padding(.top, 12)

            Button("Back", action: router.restoreAfterCancelledInvite)
                .buttonStyle(AuroraGhostButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func claimCard(_ invitation: InvitationLookupResponse) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                if let inviter = invitation.inviterName, !inviter.isEmpty {
                    AuroraEyebrow(text: "Invited by \(inviter)", centered: true)
                }
                Text("Welcome to \(invitation.serverName)")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text(endpoint.displayHost)
                    .font(.continuumCaption.monospaced())
                    .foregroundStyle(Color.auroraInkTertiary)
                Text("Choose a password and you're in. You'll sign in with your email address.")
                    .font(.continuumBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("EMAIL")
                        .font(.continuumCaption.weight(.semibold))
                        .foregroundStyle(Color.auroraInkTertiary)
                    Text(invitation.email)
                        .font(.continuumBody)
                        .foregroundStyle(Color.auroraInkSecondary)
                }

                AuroraTextField(
                    label: "Password", text: $viewModel.password, placeholder: "••••••",
                    focus: $focusedField, equals: .password,
                    isSecure: true, showsRevealToggle: true,
                    contentType: .password, onSubmit: { focusedField = .confirm }
                )
                Text("Use at least 8 characters.")
                    .font(.continuumCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
                AuroraTextField(
                    label: "Confirm password", text: $viewModel.confirmPassword, placeholder: "••••••",
                    focus: $focusedField, equals: .confirm,
                    isSecure: true, contentType: .password,
                    submitLabel: .go, onSubmit: { createAccount() }
                )

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    createAccount()
                } label: {
                    Text(viewModel.isSubmitting ? "Creating…" : "Create account")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isSubmitting))
                .disabled(viewModel.isSubmitting)
                .padding(.top, 4)

                Button("Cancel") { router.restoreAfterCancelledInvite() }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .disabled(viewModel.isSubmitting)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
    }

    private func createAccount() {
        guard !viewModel.isSubmitting else { return }
        Task { await viewModel.claim(router: router) }
    }
}
#endif
