import SwiftUI

#if !os(tvOS)
/// Sign-in on iPhone, iPad and Mac: the server's browser providers from
/// discovery and, when the server takes passwords, username and password.
/// iOS/macOS only — tvOS uses `TVLoginView`, which leads with device sign-in.
/// `LoginViewModel` owns the sign-in rules; this view lays them out.
struct LoginView: View {
    var router: AppRouter
    @State private var viewModel = LoginViewModel()
    @State private var server = SignInServerModel()
    @State private var choosesProviderForAccountSwitch = false
    /// Several providers fold the password form behind a button until asked.
    @State private var expandsPasswordForm = false
    /// Counts failed password attempts so the fields shake on each one.
    @State private var passwordFailures = 0
    @State private var showsForgotPassword = false
    @FocusState private var focusedField: Field?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    private enum Field: Hashable { case username, password }

    var body: some View {
        // Leaving mid-sign-in would let the finished sign-in pull the app
        // back from server setup, so going back waits until it settles.
        MarqueeStage(scrim: .bottomDeep, frostStart: 0.40, onBack: viewModel.isBusy ? nil : { leave() }) {
            MarqueeTopBar {
                MarqueeIconButton(systemImage: "chevron.backward",
                                  accessibilityLabel: backLabel) {
                    leave()
                }
                .disabled(viewModel.isBusy)
            } trailing: {
                serverMenu
            }
        } content: {
            MarqueeHeadline(
                title: AppLanguage.string(.signInTitle),
                // An expired session says why sign-in is back on screen.
                lead: router.loginNotice?.message(serverName: server.serverName)
                    ?? addingLead
                    ?? server.branding?.loginSubtitle ?? AppLanguage.string(.signInLead(server.serverName))
            )
            options
                .padding(.top, 24)
                .animation(.easeInOut(duration: 0.2), value: viewModel.error)
                .animation(.easeInOut(duration: 0.2), value: viewModel.networkSignInError)
                .animation(.easeInOut(duration: 0.2), value: viewModel.discovery)
                .sensoryFeedback(.error, trigger: viewModel.error) { _, error in error != nil }
                .sensoryFeedback(.error, trigger: viewModel.networkSignInError) { _, error in error != nil }
        }
        .task {
            MarqueeScene.shared.focus = .account
            MarqueeScene.shared.personalTint = nil
            // An account signing in again starts with its username.
            if viewModel.username.isEmpty, let prefill = router.signInPrefill {
                viewModel.username = prefill
            }
            await server.load()
        }
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
        .confirmationDialog(.signInDifferentAccount, isPresented: $choosesProviderForAccountSwitch,
                            titleVisibility: .visible) {
            ForEach(viewModel.browserProviders, id: \.id) { provider in
                Button(SignInOptions.buttonTitle(for: provider)) { signIn(with: provider, choosingAccount: true) }
            }
            Button(.commonCancel, role: .cancel) {}
        }
        .navigationDestination(isPresented: $showsForgotPassword) {
            ForgotPasswordView(login: viewModel.username)
        }
        .marqueeTransparentNavigation()
    }

    static var noSignInText: String { AppLanguage.string(.signInErrorNoUsableMethod) }

    /// Back to the picker while another saved account can be chosen, else to
    /// Change Account while other accounts or servers are saved; otherwise to
    /// server setup, as on a first sign-in (`AppRouter.leaveSignIn`).
    private func leave() {
        router.leaveSignIn()
    }

    private var backLabel: String {
        if router.canReturnToPicker { return AppLanguage.string(.commonBack) }
        return AppLanguage.string(router.signInLeavesForChangeAccount ? LocalizedStringResource.signInChangeAccount : .commonChangeServer)
    }

    /// Adding an account beside the ones already saved on this server.
    private var addingLead: String? {
        guard let request = router.accountSignIn, request.renewingAccountId == nil else { return nil }
        return AppLanguage.string(.signInAddingLead(server.serverName))
    }

    private var serverMenu: some View {
        Menu {
            Section(server.hostLabel) {
                Button {
                    router.leaveSignInForServerSetup()
                } label: {
                    Label(.signInUseDifferentServer, systemImage: "server.rack")
                }
            }
        } label: {
            MarqueeServerChipLabel(name: server.serverName, markURL: server.branding?.markURL)
        }
        .menuStyle(.button)
        .buttonStyle(.marqueePressable)
        .disabled(viewModel.isBusy)
        .accessibilityLabel(.shellMarqueeServerChip(server.serverName))
    }

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
        if viewModel.discovery == .loading {
            loadingSkeleton
        } else {
            VStack(spacing: 0) {
                if !viewModel.networkProviders.isEmpty {
                    networkButtons
                    if let error = viewModel.networkSignInError {
                        MarqueeErrorText(error.message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                            .accessibilityIdentifier("login.networkError")
                    }
                    if !viewModel.browserProviders.isEmpty || viewModel.showsPasswordForm {
                        MarqueeLabeledDivider(text: AppLanguage.string(.signInDividerOr))
                            .padding(.vertical, 18)
                    }
                }

                if !viewModel.browserProviders.isEmpty {
                    providerButtons
                    if viewModel.offersAccountChoice {
                        differentAccountButton
                            .padding(.top, 6)
                    }
                }

                if viewModel.offersNoSignIn {
                    MarqueeErrorText(Self.noSignInText)
                }

                if viewModel.discovery == .failed {
                    discoveryFailedRow
                        .padding(.bottom, 14)
                }

                if viewModel.showsPasswordForm {
                    if !viewModel.browserProviders.isEmpty {
                        MarqueeLabeledDivider(text: AppLanguage.string(foldsPasswordForm ? LocalizedStringResource.signInDividerOr : .signInDividerOrPassword))
                            .padding(.vertical, 18)
                    }
                    if foldsPasswordForm {
                        Button {
                            withAnimation(SiloTheme.springAnimation) { expandsPasswordForm = true }
                            focusedField = .username
                        } label: {
                            Label(.tvSignInActionPassword, systemImage: "key")
                        }
                        .buttonStyle(.marqueePlain)
                        .disabled(viewModel.isBusy)
                        // A provider's failure has no form to show it in.
                        if let error = viewModel.error {
                            MarqueeErrorText(error.message)
                                .padding(.top, 14)
                        }
                    } else {
                        passwordForm
                    }
                } else if let error = viewModel.error {
                    MarqueeErrorText(error.message)
                        .padding(.top, 14)
                }

                footnote
            }
        }
    }

    /// With two or more providers the password form waits behind a button,
    /// so the providers stay the first thing on screen.
    private var foldsPasswordForm: Bool {
        viewModel.browserProviders.count >= 2 && !expandsPasswordForm
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 14) {
            SkeletonCapsule().frame(height: MarqueeMetrics.buttonHeight)
            SkeletonCapsule().frame(width: 140, height: 10)
            SkeletonCapsule(cornerRadius: MarqueeMetrics.fieldCorner).frame(height: MarqueeMetrics.fieldHeight * 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(.signInLoadingOptions)
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
                    if inFlight {
                        Text(.tvSignInFormSubmitting)
                    } else {
                        MarqueeNetworkSignInLabel(provider: provider, serverURL: server.serverURL)
                    }
                }
                .buttonStyle(.marquee(.primary, isLoading: inFlight))
                .disabled(viewModel.isBusy)
                .accessibilityLabel(inFlight ? AppLanguage.string(.tvSignInFormSubmitting) : NetworkSignIn.accessibilityLabel(for: provider))
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
                    if inFlight {
                        Text(.signInProviderWaiting)
                    } else {
                        MarqueeProviderLabel(
                            title: SignInOptions.buttonTitle(for: provider),
                            name: SignInOptions.providerName(for: provider),
                            iconURL: SignInOptions.iconURL(for: provider, serverURL: server.serverURL)
                        )
                    }
                }
                .buttonStyle(.marquee(isPrimary ? .primary : .glass, isLoading: inFlight))
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("login.provider.\(provider.id)")
            }
        }
    }

    /// "Use a different account": the provider is asked to let the person
    /// pick another provider account instead of reusing the one the system
    /// browser is signed in with.
    private var differentAccountButton: some View {
        Button(.signInDifferentAccount) {
            if viewModel.browserProviders.count == 1, let provider = viewModel.browserProviders.first {
                signIn(with: provider, choosingAccount: true)
            } else {
                choosesProviderForAccountSwitch = true
            }
        }
        .buttonStyle(.marqueePlain)
        .disabled(viewModel.isBusy)
        .accessibilityIdentifier("login.differentAccount")
    }

    /// Discovery failed: the password form still shows, and this row says
    /// the providers may be missing and retries.
    private var discoveryFailedRow: some View {
        HStack(spacing: 10) {
            MarqueeErrorText(AppLanguage.string(.signInErrorOptionsUnavailable))
            Spacer(minLength: 8)
            Button(.commonRetry) {
                Task { await viewModel.loadSignInOptions() }
            }
            .buttonStyle(.marqueePressable)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.siloOnSurface)
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("login.retryDiscovery")
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 0) {
            MarqueeFieldGroup(isError: viewModel.error != nil) {
                MarqueeTextField(
                    systemImage: "person",
                    placeholder: AppLanguage.string(.tvSignInFormUsernamePlaceholder),
                    text: $viewModel.username,
                    focus: $focusedField,
                    equals: .username,
                    content: .username,
                    submitLabel: .next,
                    onSubmit: { focusedField = .password }
                )
                MarqueeTextField(
                    systemImage: "lock",
                    placeholder: AppLanguage.string(.tvSignInFormPasswordPlaceholder),
                    text: $viewModel.password,
                    focus: $focusedField,
                    equals: .password,
                    content: .password,
                    isSecure: true,
                    isError: viewModel.error != nil,
                    submitLabel: .go,
                    onSubmit: signIn
                )
            }
            .modifier(MarqueeShake(trigger: passwordFailures))

            if let error = viewModel.error {
                MarqueeErrorText(error.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.leading, 4)
            }

            if viewModel.offersPasswordReset {
                Button(.signInForgotLink) {
                    focusedField = nil
                    showsForgotPassword = true
                }
                .buttonStyle(.marqueePressable)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)
                .padding(.trailing, 4)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("login.forgotPassword")
            }

            Button(action: signIn) {
                Text(viewModel.isLoading ? LocalizedStringResource.tvSignInFormSubmitting : .tvSignInFormSubmit)
            }
            .buttonStyle(.marquee(.primary, isLoading: viewModel.isLoading))
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.isBusy)
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if let options = viewModel.signInOptions {
            if options.browserProviders.isEmpty && options.showsPasswordForm && !viewModel.offersPasswordReset {
                footnoteText(.signInForgotPassword)
            } else if !options.browserProviders.isEmpty && !options.showsPasswordForm {
                footnoteText(.signInErrorPasswordOff)
            }
        }
    }

    private func footnoteText(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.siloOnSurface.opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }

    // MARK: - Actions

    private func signIn() {
        guard !viewModel.isBusy else { return }
        focusedField = nil
        Task {
            if await !viewModel.login(router: router) { passwordFailures += 1 }
        }
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
}

// MARK: - Small pieces

/// A loading placeholder with a soft shimmer.
struct SkeletonCapsule: View {
    var cornerRadius: CGFloat = 999
    @State private var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width)
                        .offset(x: shimmer ? geo.size.width : -geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { shimmer = true }
            }
    }
}
#endif
