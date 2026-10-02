import SwiftUI

#if !os(tvOS)
/// Password-first sign-in. iOS/macOS only — tvOS uses `TVLoginView`,
/// which leads with QR device-login. Here the phone *is* the device, so we go
/// straight to username/password.
struct LoginView: View {
    var router: AppRouter
    @State private var viewModel = LoginViewModel()
    @State private var choosesProviderForAccountSwitch = false
    @FocusState private var focusedField: Field?
    @Environment(\.scenePhase) private var scenePhase

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
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
                if let host = hostLabel {
                    Label(host, systemImage: "server.rack")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.auroraInkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .overlay(Capsule().stroke(Color.siloOutline, lineWidth: 1))
                }
                Text("Sign in to choose a profile and start watching.")
                    .font(.siloBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                if viewModel.discovery == .loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading sign-in options…")
                            .font(.siloBody)
                            .foregroundStyle(Color.auroraInkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                if !viewModel.networkProviders.isEmpty {
                    networkButtons
                    if let error = viewModel.networkSignInError {
                        AuroraErrorLabel(error.message)
                            .accessibilityIdentifier("login.networkError")
                    }
                    if !viewModel.browserProviders.isEmpty || viewModel.showsPasswordForm {
                        orDivider
                    }
                }

                if !viewModel.browserProviders.isEmpty {
                    providerButtons
                    if viewModel.offersAccountChoice {
                        differentAccountButton
                    }
                    if viewModel.showsPasswordForm {
                        orDivider
                    }
                }

                if viewModel.offersNoSignIn {
                    AuroraErrorLabel(Self.noSignInText)
                }

                if viewModel.discovery == .failed {
                    discoveryFailedRow
                }

                if viewModel.showsPasswordForm {
                    passwordFields
                } else if let error = viewModel.error {
                    AuroraErrorLabel(error.message)
                }

                Button("Use a different server") { router.resetToServerSetup() }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)
                .disabled(viewModel.isBusy)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
            .animation(.easeInOut(duration: 0.2), value: viewModel.networkSignInError)
            .animation(.easeInOut(duration: 0.2), value: viewModel.discovery)
            .sensoryFeedback(.error, trigger: viewModel.error) { _, error in error != nil }
            .sensoryFeedback(.error, trigger: viewModel.networkSignInError) { _, error in error != nil }
        }
        .navigationBarBackButtonHidden()
        .task {
            await viewModel.loadSignInOptions()
            await viewModel.startRequestedSignIn(router: router)
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings or another app: read discovery again without
            // blanking the screen, so a failed first read recovers by itself.
            guard phase == .active, !viewModel.isBusy, viewModel.discovery != .loading else { return }
            Task { await viewModel.loadSignInOptions(showsLoading: false) }
        }
        .confirmationDialog("Use a different account", isPresented: $choosesProviderForAccountSwitch,
                            titleVisibility: .visible) {
            ForEach(viewModel.browserProviders, id: \.id) { provider in
                Button(SignInOptions.buttonTitle(for: provider)) { signIn(with: provider, choosingAccount: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    static let noSignInText = "This server doesn't offer a sign-in this app can use. Sign in on the web, or ask the server's admin."

    /// "Use a different account": the provider is asked to let the person
    /// pick another provider account instead of reusing the one the system
    /// browser is signed in with.
    private var differentAccountButton: some View {
        Button("Use a different account") {
            if viewModel.browserProviders.count == 1, let provider = viewModel.browserProviders.first {
                signIn(with: provider, choosingAccount: true)
            } else {
                choosesProviderForAccountSwitch = true
            }
        }
        .buttonStyle(AuroraGhostButtonStyle())
        .frame(maxWidth: .infinity)
        .disabled(viewModel.isBusy)
        .accessibilityIdentifier("login.differentAccount")
    }

    /// Discovery failed: the password form still shows, and this row says
    /// the providers may be missing and retries.
    private var discoveryFailedRow: some View {
        HStack(spacing: 10) {
            Text("Couldn't load sign-in options.")
                .font(.siloCaption)
                .foregroundStyle(Color.auroraInkSecondary)
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await viewModel.loadSignInOptions() }
            }
            .font(.siloCaption)
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("login.retryDiscovery")
        }
    }

    /// "Continue as <name>" per network provider: this device's owner signs
    /// in with no password and no browser. Discovery lists one only when the
    /// app reached the server through that provider's network, so when it
    /// shows it is the quickest way in and leads the screen.
    private var networkButtons: some View {
        VStack(spacing: 12) {
            ForEach(viewModel.networkProviders, id: \.id) { provider in
                let inFlight = viewModel.providerInFlight == provider.id
                Button {
                    signInWithNetworkIdentity(provider)
                } label: {
                    HStack(spacing: 10) {
                        if !inFlight {
                            ProviderIconView(url: SignInOptions.iconURL(for: provider, serverURL: AuthService.shared.serverUrl))
                        }
                        VStack(spacing: 2) {
                            Text(inFlight ? "Signing in…" : NetworkSignIn.buttonTitle(for: provider))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if !inFlight, let via = NetworkSignIn.viaLine(for: provider) {
                                Text(via)
                                    .font(.siloCaption)
                                    .opacity(0.75)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: inFlight))
                .disabled(viewModel.isBusy)
                .accessibilityLabel(inFlight ? "Signing in…" : NetworkSignIn.accessibilityLabel(for: provider))
                .accessibilityIdentifier("login.network.\(provider.id)")
            }
        }
    }

    /// One button per browser provider. Without a password form or a
    /// network sign-in the first is the screen's primary action.
    private var providerButtons: some View {
        VStack(spacing: 12) {
            ForEach(Array(viewModel.browserProviders.enumerated()), id: \.element.id) { index, provider in
                let isPrimary = index == 0 && !viewModel.showsPasswordForm && viewModel.networkProviders.isEmpty
                let inFlight = viewModel.providerInFlight == provider.id
                Button {
                    signIn(with: provider)
                } label: {
                    HStack(spacing: 10) {
                        if !inFlight || !isPrimary {
                            ProviderIconView(url: SignInOptions.iconURL(for: provider, serverURL: AuthService.shared.serverUrl))
                        }
                        Text(inFlight ? "Waiting for sign-in…" : SignInOptions.buttonTitle(for: provider))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .modifier(ProviderButtonStyle(isPrimary: isPrimary, isLoading: inFlight))
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("login.provider.\(provider.id)")
            }
        }
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.siloOutline).frame(height: 1)
            Text("or")
                .font(.siloCaption)
                .foregroundStyle(Color.auroraInkSecondary)
            Rectangle().fill(Color.siloOutline).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var passwordFields: some View {
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
            AuroraErrorLabel(error.message)
        }

        Button {
            signIn()
        } label: {
            Text(viewModel.isLoading ? "Signing in…" : "Sign in")
        }
        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
        .disabled(viewModel.isBusy)
        .padding(.top, 4)
    }

    private func signIn() {
        guard !viewModel.isBusy else { return }
        Task { await viewModel.login(router: router) }
    }

    private func signInWithNetworkIdentity(_ provider: APIv2AuthProvider) {
        guard !viewModel.isBusy else { return }
        focusedField = nil
        Task { await viewModel.signInWithNetworkIdentity(provider, router: router) }
    }

    private func signIn(with provider: APIv2AuthProvider, choosingAccount: Bool = false) {
        guard !viewModel.isBusy else { return }
        focusedField = nil
        Task { await viewModel.signIn(with: provider, router: router, choosingAccount: choosingAccount) }
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

/// Primary (filled) when the provider is the screen's only way in,
/// otherwise the quieter full-width secondary button.
private struct ProviderButtonStyle: ViewModifier {
    let isPrimary: Bool
    let isLoading: Bool

    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(AuroraPrimaryButtonStyle(isLoading: isLoading))
        } else {
            content.buttonStyle(AuroraGhostButtonStyle())
        }
    }
}
#endif
