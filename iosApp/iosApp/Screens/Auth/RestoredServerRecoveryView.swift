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
                error = AppLanguage.string(.setupRecoveryErrorForgetFailed)
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
    @Environment(\.locale) private var locale
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
                        Label(isChecking ? LocalizedStringResource.notReadyChecking : .commonTryAgain, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: isChecking))
                    .focused($focusedAction, equals: .retry)

                    Button(.setupRecoveryManageServers, action: manageServers)
                        .buttonStyle(.marquee(.glass, fullWidth: false))
                        .focused($focusedAction, equals: .manageServers)

                    Button(.setupRecoveryForget, action: requestForget)
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
                    title: .setupRecoveryForgetTitle,
                    message: .verbatim(forgetMessage),
                    confirmTitle: .setupRecoveryForgetConfirm,
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
                    Text(isChecking ? LocalizedStringResource.notReadyChecking : .commonTryAgain)
                }
                .buttonStyle(.marquee(.primary, isLoading: isChecking))

                Button(.setupRecoveryManageServers, action: manageServers)
                    .buttonStyle(.marqueeGlass)

                Button(.setupRecoveryForget, role: .destructive, action: requestForget)
                    .buttonStyle(.marqueePlain)
            }
            .disabled(isChecking || coordinator.isForgetting)
            .padding(.top, 26)
        }
        .animation(.easeInOut(duration: 0.2), value: error)
        .onAppear { MarqueeScene.shared.showActiveServer() }
        .navigationBarBackButtonHidden()
        .marqueeTransparentNavigation()
        .alert(.setupRecoveryForgetTitle, isPresented: $showForgetConfirmation) {
            Button(.setupRecoveryForgetConfirm, role: .destructive, action: confirmForget)
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(forgetMessage)
        }
        .onDisappear(perform: cancelWork)
    }
    #endif

    private var serverCard: some View {
        MarqueeServerCard(
            name: activeServer?.displayName ?? AppLanguage.string(.setupRecoveryServerFallback),
            address: activeServer.map { ServerBranding.hostLabel($0.url) } ?? "",
            markURL: activeServer.flatMap { ServerBrandingCache.branding(for: $0.url)?.markURL },
            badge: .init(text: badgeText, systemImage: "exclamationmark.triangle", tone: .warning)
        )
        .accessibilityLabel(.setupRecoveryServerAddress(activeServer?.url ?? ""))
    }

    private var badgeText: String {
        switch reason {
        case .needsSetup: return AppLanguage.string(.notReadyBadge)
        case .serverNotRecognized: return AppLanguage.string(.setupRecoveryBadgeNotRecognized)
        case .serverUpdateRequired, .appUpdateRequired: return AppLanguage.string(.firstRunBadgeUpdate)
        }
    }

    private var activeServer: ServerEntry? {
        registry.activeServer
    }

    private var title: String {
        switch reason {
        case .needsSetup: return AppLanguage.string(.setupNotReadyTitle)
        case .serverNotRecognized: return AppLanguage.string(.setupRecoveryTitleNotRecognized)
        case .serverUpdateRequired: return AppLanguage.string(.updateHeadline)
        case .appUpdateRequired: return AppLanguage.string(.setupRecoveryTitleAppUpdate)
        }
    }

    private var message: String {
        switch reason {
        case .needsSetup:
            return AppLanguage.string(.setupRecoveryLeadNeedsSetup)
        case .serverNotRecognized:
            return AppLanguage.string(.setupRecoveryLeadNotRecognized)
        case .serverUpdateRequired:
            return AppLanguage.string(.setupRecoveryLeadUpdate(UpdateRequirement.serverMessage))
        case .appUpdateRequired:
            return AppLanguage.string(.setupRecoveryLeadUpdate(UpdateRequirement.appMessage))
        }
    }

    private var forgetMessage: String {
        guard let name = activeServer?.displayName else { return AppLanguage.string(.setupRecoveryForgetBodyUnnamed) }
        return AppLanguage.string(.setupRecoveryForgetBody(name))
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
            return AppLanguage.string(.notReadyStill)
        case .serverRecovery(.serverNotRecognized):
            return AppLanguage.string(.setupRecoveryStillNotRecognized)
        case .serverRecovery(.serverUpdateRequired):
            return AppLanguage.string(.setupRecoveryStillServerUpdate)
        case .serverRecovery(.appUpdateRequired):
            return AppLanguage.string(.setupRecoveryStillAppUpdate)
        case .indeterminate:
            return AppLanguage.string(.setupRecoveryStillUnreachable)
        case .valid, .needsLogin, .identityChanged:
            return AppLanguage.string(.setupRecoveryServerChanged)
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
