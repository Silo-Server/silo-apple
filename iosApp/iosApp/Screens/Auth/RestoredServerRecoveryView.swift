import SwiftUI

/// Owns confirmed account removal above the auth subtree. Removing the
/// active account changes the subtree identity before Keychain cleanup
/// completes, so this operation must not be tied to the recovery view's
/// lifetime.
@MainActor
@Observable
final class RestoredServerRecoveryCoordinator {
    /// Removes the current account and routes on (the launch rules, spec
    /// §6.2). Returns whether it is gone.
    typealias RemoveAccount = (AppRouter) async -> Bool

    private let removeAccount: RemoveAccount
    @ObservationIgnored private var forgetTask: Task<Void, Never>?

    private(set) var isForgetting = false
    private(set) var error: String?

    init(
        removeAccount: @escaping RemoveAccount = { router in
            await router.accounts.removeCurrentAccount(router: router)
        }
    ) {
        self.removeAccount = removeAccount
    }

    /// Removes the current account once confirmed, and routes on, even if
    /// changing the active account tears down the recovery screen meanwhile.
    @discardableResult
    func forget(router: AppRouter) -> Task<Void, Never>? {
        guard !isForgetting else { return nil }
        isForgetting = true
        error = nil

        let task = Task { [self] in
            if !(await removeAccount(router)) {
                error = "Silo couldn't remove this account. Try again."
            }
            isForgetting = false
            forgetTask = nil
        }
        forgetTask = task
        return task
    }
}

/// Recovery surface for a remembered server that responded authoritatively but
/// can no longer accept the restored session. Merely reaching this screen is
/// non-destructive: the server entry and its Keychain slot stay intact.
struct RestoredServerRecoveryView: View {
    var router: AppRouter
    let reason: ServerRecoveryReason
    let coordinator: RestoredServerRecoveryCoordinator

    @State private var registry = ServerRegistry.shared
    @State private var isChecking = false
    @State private var error: String?
    @State private var retryTask: Task<Void, Never>?
    @State private var showForgetConfirmation = false
    #if os(tvOS)
    @FocusState private var focusedAction: RecoveryAction?

    private enum RecoveryAction: Hashable {
        case retry
        case switchAccount
        case forget
    }
    #endif

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
    }

    #if os(tvOS)
    private var tvOSBody: some View {
        ZStack {
            MarqueeTVScreen {
                serverCard
                    .fixedSize(horizontal: true, vertical: false)
                Text(title)
                    .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                    .kerning(-2)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 52)
                    .accessibilityAddTraits(.isHeader)
                MarqueeTVBody(message)
                    .padding(.top, 26)

                if let visibleError {
                    MarqueeErrorText(visibleError)
                        .padding(.top, 20)
                }

                HStack(spacing: 22) {
                    Button(action: retry) {
                        Label(isChecking ? "Checking…" : "Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: isChecking))
                    .focused($focusedAction, equals: .retry)

                    Button("Switch Account", action: switchAccount)
                        .buttonStyle(.marquee(.glass, fullWidth: false))
                        .focused($focusedAction, equals: .switchAccount)

                    Button(SignOutConfirmationCopy.removeAccountTitle, action: requestForget)
                        .buttonStyle(.marquee(.plain, fullWidth: false))
                        .focused($focusedAction, equals: .forget)
                }
                // Not disabled while checking: disabling every button leaves
                // the page with nothing to focus, so the remote stops
                // responding. The actions ignore presses while busy.
                .padding(.top, 56)
                .focusSection()
            } card: {
                EmptyView()
            }
            .disabled(showForgetConfirmation)

            if showForgetConfirmation {
                TVSettingsConfirmationOverlay(
                    title: forgetCopy.title,
                    message: forgetCopy.message,
                    confirmTitle: forgetCopy.confirmTitle,
                    cancel: cancelForget,
                    confirm: confirmForget
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .onAppear { MarqueeScene.shared.showActiveServer() }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden()
        .defaultFocus($focusedAction, .retry, priority: .userInitiated)
        .marqueeTVSeedFocus($focusedAction, .retry)
        .animation(.easeInOut(duration: 0.2), value: error)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showForgetConfirmation)
        .onDisappear(perform: cancelWork)
    }
    #endif

    #if !os(tvOS)
    private var standardBody: some View {
        MarqueeStage(scrim: .bottom, frostStart: 0.45) {
            MarqueeTopBar {
                SiloWordmarkView(width: 92)
            } trailing: { EmptyView() }
        } content: {
            serverCard
            MarqueeHeadline(title: title, lead: message)
                .padding(.top, 26)

            if let visibleError {
                MarqueeErrorText(visibleError)
                    .padding(.top, 14)
            }

            VStack(spacing: 10) {
                Button(action: retry) {
                    Text(isChecking ? "Checking…" : "Try again")
                }
                .buttonStyle(.marquee(.primary, isLoading: isChecking))

                Button("Switch Account", action: switchAccount)
                    .buttonStyle(.marqueeGlass)

                Button(SignOutConfirmationCopy.removeAccountTitle, role: .destructive, action: requestForget)
                    .buttonStyle(.marqueePlain)
            }
            .disabled(isChecking || coordinator.isForgetting)
            .padding(.top, 26)
        }
        .animation(.easeInOut(duration: 0.2), value: error)
        .onAppear { MarqueeScene.shared.showActiveServer() }
        .navigationBarBackButtonHidden()
        .marqueeTransparentNavigation()
        .alert(forgetCopy.title, isPresented: $showForgetConfirmation) {
            Button(forgetCopy.confirmTitle, role: .destructive, action: confirmForget)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(forgetCopy.message)
        }
        .onDisappear(perform: cancelWork)
    }
    #endif

    private var serverCard: some View {
        MarqueeServerCard(
            name: activeServer?.displayName ?? "Your server",
            address: activeServer.map { ServerBranding.hostLabel($0.url) } ?? "",
            markURL: activeServer.flatMap { ServerBrandingCache.branding(for: $0.url)?.markURL },
            badge: .init(text: badgeText, systemImage: "exclamationmark.triangle", tone: .warning)
        )
        .accessibilityLabel("Server address: \(activeServer?.url ?? "")")
    }

    private var badgeText: String {
        switch reason {
        case .needsSetup: return "Setup needed"
        case .serverNotRecognized: return "Not recognized"
        case .serverUpdateRequired, .appUpdateRequired: return "Update needed"
        }
    }

    private var activeServer: ServerEntry? {
        registry.activeServer
    }

    private var title: String {
        switch reason {
        case .needsSetup: return "This server isn't ready"
        case .serverNotRecognized: return "Can't open this server"
        case .serverUpdateRequired: return "Server update required"
        case .appUpdateRequired: return "Update Silo"
        }
    }

    private var message: String {
        let keptSignIn = "Your saved sign-in information has not been removed."
        switch reason {
        case .needsSetup:
            return "Ask the server administrator to finish setup, then try again. \(keptSignIn)"
        case .serverNotRecognized:
            return "The server may have moved, been reset, or this address may no longer point to Silo. \(keptSignIn)"
        case .serverUpdateRequired:
            return "\(UpdateRequirement.serverMessage) \(keptSignIn)"
        case .appUpdateRequired:
            return "\(UpdateRequirement.appMessage) \(keptSignIn)"
        }
    }

    /// Remove Account's confirmation: the current account, through the
    /// same copy as Settings › Accounts.
    private var forgetCopy: ConfirmationCopy {
        let accounts = router.accounts
        guard let current = accounts.directory.currentAccountID else {
            let name = activeServer?.displayName ?? "this server"
            return SignOutConfirmationCopy.removeAccount(accountName: "Your account", serverName: name,
                                                         device: accounts.device)
        }
        return accounts.confirmation(for: .remove(current))
    }

    private func retry() {
        guard !isChecking, !coordinator.isForgetting else { return }
        isChecking = true
        error = nil
        let expectedServerID = registry.activeServerId

        retryTask = Task {
            // The same user and server again: Try again never asks who's
            // watching or opens another user, as a cold launch might.
            let local = await RestoredSessionAuthResolver.resolveCurrent()
            let validation: RestoredSessionValidationResult
            if let expected = local.restoredAccount {
                validation = await AuthService.shared.validateRestoredSession(expected: expected)
            } else {
                validation = .identityChanged
            }

            let destination: RestoredSessionAuthResolver.LocalResolution?
            switch validation {
            case .valid:
                destination = local
            case .needsLogin:
                destination = RestoredSessionAuthResolver.LocalResolution(
                    state: .needsLogin, restoredAccount: nil, loginNotice: .sessionExpired)
            case .serverRecovery(let newReason):
                destination = newReason == reason
                    ? nil
                    : RestoredSessionAuthResolver.LocalResolution(state: .serverRecovery(newReason), restoredAccount: nil)
            case .identityChanged:
                // Nothing to validate (a sign-in screen, which keeps its
                // sign-in) or another account meanwhile.
                destination = local.restoredAccount == nil
                    ? local
                    : await RestoredSessionAuthResolver.resolveCurrentValidated()
            case .indeterminate:
                destination = nil
            }

            isChecking = false
            guard !Task.isCancelled,
                  registry.activeServerId == expectedServerID else { return }
            // A rejected saved sign-in keeps its own sign-in screen, with
            // Switch Account.
            if validation == .needsLogin, await router.accounts.signInAgainForCurrentSession(router: router) { return }
            if let destination {
                router.resetAfterServerResolution(to: destination)
            } else {
                error = retryMessage(for: validation)
            }
        }
    }

    private func retryMessage(for validation: RestoredSessionValidationResult) -> String {
        switch validation {
        case .serverRecovery(.needsSetup):
            return "This server still needs administrator setup."
        case .serverRecovery(.serverNotRecognized):
            return "This address still doesn't look like a Silo server."
        case .serverRecovery(.serverUpdateRequired):
            return "This server still needs to be updated."
        case .serverRecovery(.appUpdateRequired):
            return "This server still requires a newer version of Silo."
        case .indeterminate:
            return "We still can't reach this server. Your saved sign-in information is unchanged."
        case .valid, .needsLogin, .identityChanged:
            return "The server changed while it was being checked. Try again."
        }
    }

    private func switchAccount() {
        guard !coordinator.isForgetting else { return }
        cancelWork()
        Task { await router.accounts.beginSwitchAccount(router: router) }
    }

    private func requestForget() {
        guard !isChecking, !coordinator.isForgetting else { return }
        showForgetConfirmation = true
    }

    private func confirmForget() {
        guard !coordinator.isForgetting else { return }
        showForgetConfirmation = false
        error = nil
        coordinator.forget(router: router)
    }

    #if os(tvOS)
    private func cancelForget() {
        showForgetConfirmation = false
        Task {
            await Task.yield()
            focusedAction = .forget
        }
    }
    #endif

    private func cancelWork() {
        retryTask?.cancel()
        retryTask = nil
        isChecking = false
    }

    private var visibleError: String? {
        error ?? coordinator.error
    }
}
