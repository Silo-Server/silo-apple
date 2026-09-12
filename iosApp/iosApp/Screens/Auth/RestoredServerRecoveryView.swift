import SwiftUI

/// Recovery surface for a remembered server that responded authoritatively but
/// can no longer accept the restored session. Merely reaching this screen is
/// non-destructive: the server entry and its Keychain slot stay intact.
struct RestoredServerRecoveryView: View {
    var router: AppRouter
    let reason: ServerRecoveryReason

    @State private var registry = ServerRegistry.shared
    @State private var isChecking = false
    @State private var isForgetting = false
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
            AuroraBackdrop(variant: .server, scrim: .soft)

            VStack(spacing: 0) {
                HStack {
                    SiloWordmarkView(width: 132)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 48)

                VStack(spacing: 28) {
                    recoveryIcon(size: 58)

                    recoveryCopy

                    if let error {
                        recoveryError(error)
                    }

                    HStack(spacing: 24) {
                        Button(action: retry) {
                            Label(
                                isChecking ? "Checking…" : "Try Again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))
                        .focused($focusedAction, equals: .retry)

                        Button("Manage Servers", action: manageServers)
                            .buttonStyle(AuroraGhostButtonStyle())
                            .focused($focusedAction, equals: .manageServers)

                        Button("Forget This Server", action: requestForget)
                            .buttonStyle(AuroraGhostButtonStyle())
                            .foregroundStyle(Color.siloError)
                            .focused($focusedAction, equals: .forget)
                    }
                    .disabled(isChecking || isForgetting)
                    .focusSection()
                }
                .padding(56)
                .frame(width: 980)
                .auroraGlass(cornerRadius: 30, emphasized: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 64)
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
        .ignoresSafeArea()
        .navigationBarBackButtonHidden()
        .defaultFocus($focusedAction, .retry, priority: .userInitiated)
        .animation(.easeInOut(duration: 0.2), value: error)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showForgetConfirmation)
        .onDisappear(perform: cancelWork)
    }
    #endif

    #if !os(tvOS)
    private var standardBody: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            SiloWordmarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)

            recoveryIcon(size: 36)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 18)

            recoveryCopy
                .padding(.bottom, 22)

            VStack(spacing: 16) {
                if let error {
                    AuroraErrorLabel(error)
                }

                Button(action: retry) {
                    Text(isChecking ? "Checking…" : "Try Again")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))

                Button("Manage Servers", action: manageServers)
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)

                Button("Forget This Server", role: .destructive, action: requestForget)
                    .buttonStyle(AuroraGhostButtonStyle())
                    .foregroundStyle(Color.siloError)
                    .frame(maxWidth: .infinity)
            }
            .disabled(isChecking || isForgetting)
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: error)
        }
        .navigationBarBackButtonHidden()
        .alert("Forget this server?", isPresented: $showForgetConfirmation) {
            Button("Forget Server", role: .destructive, action: confirmForget)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(forgetMessage)
        }
        .onDisappear(perform: cancelWork)
    }
    #endif

    @ViewBuilder
    private func recoveryIcon(size: CGFloat) -> some View {
        let symbol = reason == .needsSetup ? "gearshape.2" : "server.rack"
        ZStack {
            Circle().fill(Color.auroraAccent.opacity(0.14))
            Circle().stroke(Color.auroraAccent.opacity(0.34), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color.auroraAccent)
        }
        #if os(tvOS)
        .frame(width: 116, height: 116)
        #else
        .frame(width: 82, height: 82)
        #endif
    }

    private var recoveryCopy: some View {
        VStack(spacing: 14) {
            AuroraEyebrow(text: eyebrow, centered: true)
            Text(title)
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let serverURL = activeServer?.url {
                Text(serverURL)
                    .font(.siloCaption.monospaced())
                    .foregroundStyle(Color.auroraInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Server address: \(serverURL)")
            }
        }
    }

    #if os(tvOS)
    private func recoveryError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.siloCaption)
            .foregroundStyle(Color.requestRose)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(message)")
    }
    #endif

    private var activeServer: ServerEntry? {
        registry.activeServer
    }

    private var eyebrow: String {
        reason == .needsSetup ? "SERVER SETUP" : "CONNECTION RECOVERY"
    }

    private var title: String {
        reason == .needsSetup ? "This server isn't ready" : "We can't verify this server"
    }

    private var message: String {
        switch reason {
        case .needsSetup:
            return "Ask the server administrator to finish setup, then try again. Your saved sign-in information has not been removed."
        case .serverNotRecognized:
            return "The server may have moved, been reset, or this address may no longer point to Silo. Your saved sign-in information has not been removed."
        }
    }

    private var forgetMessage: String {
        let name = activeServer?.displayName ?? "this server"
        return "This removes the saved connection and sign-in credentials for \(name) from this device. This can't be undone."
    }

    private func retry() {
        guard !isChecking, !isForgetting else { return }
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

            await MainActor.run {
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
    }

    private func retryMessage(for validation: RestoredSessionValidationResult) -> String {
        switch validation {
        case .serverRecovery(.needsSetup):
            return "This server still needs administrator setup."
        case .serverRecovery(.serverNotRecognized):
            return "This address still doesn't look like a Silo server."
        case .indeterminate:
            return "We still can't reach this server. Your saved sign-in information is unchanged."
        case .valid, .needsLogin, .identityChanged:
            return "The server changed while it was being checked. Try again."
        }
    }

    private func manageServers() {
        cancelWork()
        router.navigate(to: .serverList)
    }

    private func requestForget() {
        guard !isChecking, !isForgetting else { return }
        showForgetConfirmation = true
    }

    private func confirmForget() {
        guard !isForgetting, let serverID = registry.activeServerId else { return }
        showForgetConfirmation = false
        isForgetting = true
        error = nil

        retryTask = Task {
            let removed = await registry.remove(serverId: serverID)
            let destination: AppRouter.AuthState?
            if removed {
                destination = await RestoredSessionAuthResolver.resolveValidated()
            } else {
                destination = nil
            }
            await MainActor.run {
                isForgetting = false
                guard !Task.isCancelled else { return }
                if let destination {
                    router.resetAfterServerResolution(to: destination)
                } else {
                    error = "Silo couldn't forget this server. Try again."
                }
            }
        }
    }

    #if os(tvOS)
    private func cancelForget() {
        showForgetConfirmation = false
        Task { @MainActor in
            await Task.yield()
            focusedAction = .forget
        }
    }
    #endif

    private func cancelWork() {
        retryTask?.cancel()
        retryTask = nil
        isChecking = false
        isForgetting = false
    }
}
