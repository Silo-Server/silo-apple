import SwiftUI

/// Owns confirmed server removal above the auth subtree. Removing an active
/// server changes the subtree identity before Keychain cleanup completes, so
/// this operation must not be tied to the recovery view's lifetime.
@MainActor
@Observable
final class RestoredServerRecoveryCoordinator {
    typealias RemoveServer = (String) async -> Bool
    typealias ResolveDestination = () async -> AppRouter.AuthState

    private let removeServer: RemoveServer
    private let resolveDestination: ResolveDestination
    @ObservationIgnored private var forgetTask: Task<Void, Never>?

    private(set) var isForgetting = false
    private(set) var error: String?

    init(
        removeServer: @escaping RemoveServer = { serverID in
            await ServerRegistry.shared.remove(serverId: serverID)
        },
        resolveDestination: @escaping ResolveDestination = {
            await RestoredSessionAuthResolver.resolveValidated()
        }
    ) {
        self.removeServer = removeServer
        self.resolveDestination = resolveDestination
    }

    /// Removes the confirmed server and commits the fallback route even if
    /// changing the active server tears down the recovery screen meanwhile.
    @discardableResult
    func forget(serverID: String, router: AppRouter) -> Task<Void, Never>? {
        guard !isForgetting else { return nil }
        isForgetting = true
        error = nil

        let task = Task { [self] in
            let removed = await removeServer(serverID)
            if removed {
                let destination = await resolveDestination()
                router.resetAfterServerResolution(to: destination)
            } else {
                error = "Silo couldn't forget this server. Try again."
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
        case manageServers
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

                    Button("Manage servers", action: manageServers)
                        .buttonStyle(.marquee(.glass, fullWidth: false))
                        .focused($focusedAction, equals: .manageServers)

                    Button("Forget this server", action: requestForget)
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
                    title: "Forget this server?",
                    message: forgetMessage,
                    confirmTitle: "Forget Server",
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

                Button("Manage servers", action: manageServers)
                    .buttonStyle(.marqueeGlass)

                Button("Forget this server", role: .destructive, action: requestForget)
                    .buttonStyle(.marqueePlain)
            }
            .disabled(isChecking || coordinator.isForgetting)
            .padding(.top, 26)
        }
        .animation(.easeInOut(duration: 0.2), value: error)
        .onAppear { MarqueeScene.shared.showActiveServer() }
        .navigationBarBackButtonHidden()
        .marqueeTransparentNavigation()
        .alert("Forget this server?", isPresented: $showForgetConfirmation) {
            Button("Forget Server", role: .destructive, action: confirmForget)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(forgetMessage)
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

    private var forgetMessage: String {
        let name = activeServer?.displayName ?? "this server"
        return "This removes the saved connection and sign-in credentials for \(name) from this device. This can't be undone."
    }

    private func retry() {
        guard !isChecking, !coordinator.isForgetting else { return }
        isChecking = true
        error = nil
        let expectedServerID = registry.activeServerId

        retryTask = Task {
            let local = await RestoredSessionAuthResolver.resolveLocal()
            let validation: RestoredSessionValidationResult
            if let expected = local.restoredAccount {
                validation = await AuthService.shared.validateRestoredSession(expected: expected)
            } else {
                validation = .identityChanged
            }

            let destination: AppRouter.AuthState?
            switch validation {
            case .valid:
                destination = local.state
            case .needsLogin:
                destination = .needsLogin
            case .serverRecovery(let newReason):
                destination = newReason == reason ? nil : .serverRecovery(newReason)
            case .identityChanged:
                destination = await RestoredSessionAuthResolver.resolveValidated()
            case .indeterminate:
                destination = nil
            }

            isChecking = false
            guard !Task.isCancelled,
                  registry.activeServerId == expectedServerID else { return }
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

    private func manageServers() {
        guard !coordinator.isForgetting else { return }
        cancelWork()
        router.navigate(to: .serverList)
    }

    private func requestForget() {
        guard !isChecking, !coordinator.isForgetting else { return }
        showForgetConfirmation = true
    }

    private func confirmForget() {
        guard !coordinator.isForgetting, let serverID = registry.activeServerId else { return }
        showForgetConfirmation = false
        error = nil
        coordinator.forget(serverID: serverID, router: router)
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
