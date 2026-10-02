#if os(tvOS)
import SwiftUI
import UIKit

/// The Apple TV sign-in screen: every way in is visible at once. Scan the
/// QR code, or type `<host>/activate` and the code, or open Silo on a
/// nearby phone (the screen advertises `st=login` on the LAN, behind the
/// `PairingProtocol.advertisesSignInTVs` rollout gate). A password
/// is one click away. The code renews itself while the screen is visible;
/// nothing counts down. See `QRLoginViewModel` for the lifecycle.
///
/// When this TV reached the server through a network identity provider's
/// network (Tailscale: the saved address is the server's tailnet name),
/// discovery lists that provider and "Continue as <owner>" leads the screen:
/// one press signs the TV's owner in, with no code and no password.
struct TVLoginView: View {
    var router: AppRouter
    /// The route this screen was built for. Nearby advertising stops once the
    /// app leaves it (see `TVPairingAdvertiser.advertise`).
    private let route: AppRouter.AuthState

    init(router: AppRouter) {
        self.router = router
        route = router.authState
    }

    @State private var loginVM = LoginViewModel()
    @State private var qrVM = QRLoginViewModel()
    @State private var advertiser = TVPairingAdvertiser()
    @State private var receiver = ReceiverPairingCoordinator()
    @State private var showPassword: Bool = false
    @State private var showPasswordForm: Bool = false
    @State private var isSubmittingPassword = false
    @State private var isSubmittingNetwork = false
    /// Whether the person moved focus since the screen seeded it. Discovery
    /// answers after the screen appears; "Continue as …" takes focus then
    /// only while it is still where the screen put it.
    @State private var personMovedFocus = false
    /// The field the screen itself last focused, so that move is not taken
    /// for the person's.
    @State private var seededFocus: Field?
    /// Set by `goToProfiles()`, the one place this screen moves on after a
    /// device sign-in (the QR approval and the nearby panel both land there).
    @State private var navigatedAfterApproval = false

    @FocusState private var focusedField: Field?
    @Environment(\.scenePhase) private var scenePhase

    private enum Field: Hashable {
        case networkSignIn
        case usePassword
        case stateAction
        case changeServer
        case username
        case password
        case togglePassword
        case signIn
        case backToPhone
    }

    /// True while a nearby phone is on the line; its panel replaces the code.
    private var isPairing: Bool {
        if case .idle = receiver.state { return false }
        return true
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: .signIn, scrim: showPasswordForm || isPairing ? .soft : .left)
            Group {
                if isPairing {
                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 20)
                        TVPairingReceiverView(coordinator: receiver, advance: goToProfiles)
                        Spacer(minLength: 0)
                    }
                } else if showPasswordForm || qrVM.status == .noDeviceSignIn {
                    passwordContent
                } else {
                    phoneFirstContent
                }
            }
            .padding(.horizontal, 108)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .task {
            await qrVM.begin(deviceName: Self.deviceName, devicePlatform: AppleDeviceIdentity.current.platform)
        }
        .task { await startNearbyAdvertising() }
        .task { await loginVM.loadSignInOptions() }
        .onChange(of: qrVM.status, initial: true) { _, status in
            loginVM.offersPhoneRoute = status != .noDeviceSignIn
        }
        .onChange(of: focusedField) { old, new in
            guard old != nil, let new, new != seededFocus else { return }
            personMovedFocus = true
        }
        .onChange(of: networkProvider?.id) { old, new in
            // Discovery answered after the screen seeded focus. "Continue as
            // …" is the quickest way in, so it takes focus once, unless the
            // person already moved it or chose the password form.
            guard old == nil, new != nil, !personMovedFocus,
                  !showPasswordForm || qrVM.status == .noDeviceSignIn else { return }
            seedFocus(.networkSignIn)
        }
        .onChange(of: loginVM.networkSignInError) { _, error in
            guard let error, UIAccessibility.isVoiceOverRunning else { return }
            AccessibilityNotification.Announcement(AttributedString(error.message)).post()
        }
        .onChange(of: qrVM.status) { _, newValue in
            if case .approved = newValue {
                StartupContentPrefetcher.prefetchProfiles()
                Task { @MainActor in
                    // Let "Signed in as …" register before moving on.
                    try? await Task.sleep(for: .seconds(1))
                    goToProfiles()
                }
                return
            }
            if newValue == .noDeviceSignIn {
                seedFocus(networkProvider == nil ? .username : .networkSignIn)
            } else if !showPasswordForm, TVSignInPresentation.actionTakesFocus(newValue) {
                focusedField = .stateAction
            }
            announce(newValue)
        }
        .onChange(of: receiver.state) { _, state in
            if case .idle = state { advertiser.release() }
        }
        .onChange(of: scenePhase) { _, phase in
            qrVM.setActive(phase == .active)
            // Back from the Home screen or another app: read discovery again
            // without blanking the screen, as the iPhone login does, so a
            // server that turned password sign-in off or on meanwhile shows
            // or hides "Sign in with a password".
            guard phase == .active, !loginVM.isBusy, loginVM.discovery != .loading else { return }
            Task { await loginVM.loadSignInOptions(showsLoading: false) }
        }
        .onDisappear {
            advertiser.stop()
            Task { await receiver.cancel() }
            qrVM.stop()
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            SiloWordmarkView(width: 132)
            if let server = serverName {
                Label(server, systemImage: "server.rack")
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
            Spacer(minLength: 0)
            AuroraJourneyProgress(currentStep: 2)
                .frame(width: 430)
        }
    }

    @ViewBuilder
    private var sessionExpiredBanner: some View {
        if router.loginNotice == .sessionExpired {
            Label(String(format: TVSignInPresentation.sessionExpiredBanner, serverName ?? "this server"),
                  systemImage: "exclamationmark.circle")
                .font(.siloBody)
                .foregroundStyle(Color.auroraInk)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .auroraGlass(cornerRadius: 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
        }
    }

    // MARK: - Code screen

    private var phoneFirstContent: some View {
        VStack(spacing: 0) {
            topBar
            sessionExpiredBanner
            Spacer(minLength: 24)
            HStack(alignment: .center, spacing: 80) {
                heroColumn
                    .frame(width: 820, alignment: .leading)
                    .focusSection()
                codePanel
            }
            .frame(maxWidth: 1700)
            Spacer(minLength: 0)
        }
        .defaultFocus($focusedField, defaultCodeScreenFocus, priority: .userInitiated)
    }

    /// Where focus enters the code screen: "Continue as …" when this TV can
    /// sign in through its network provider, else the password button.
    private var defaultCodeScreenFocus: Field {
        if networkProvider != nil { return .networkSignIn }
        return offersPassword ? .usePassword : .changeServer
    }

    /// The network provider discovery lists for this TV (at most one is
    /// enabled on a server), when the request came through its network.
    private var networkProvider: APIv2AuthProvider? { loginVM.networkProviders.first }

    /// "Continue as <owner>" over "via <provider>", and the refusal under it.
    private func networkSignInButton(_ provider: APIv2AuthProvider) -> some View {
        let inFlight = isSubmittingNetwork || loginVM.providerInFlight == provider.id
        return VStack(alignment: .leading, spacing: 14) {
            Button {
                continueWithNetworkIdentity(provider)
            } label: {
                VStack(spacing: 4) {
                    Text(inFlight ? "Signing in…" : NetworkSignIn.buttonTitle(for: provider))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !inFlight, let via = NetworkSignIn.viaLine(for: provider) {
                        Text(via)
                            .font(.system(size: 18, weight: .medium))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(AuroraPrimaryButtonStyle(isLoading: inFlight))
            .frame(width: 560)
            .focused($focusedField, equals: .networkSignIn)
            .accessibilityLabel(inFlight ? "Signing in…" : NetworkSignIn.accessibilityLabel(for: provider))

            if let error = loginVM.networkSignInError?.message {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.requestRose)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.siloCaption)
                        .foregroundStyle(Color.requestRose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 700, alignment: .leading)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: loginVM.networkSignInError)
    }

    private var heroColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuroraEyebrow(text: "Account")
            Text("Sign in to \(serverName ?? "your server")")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)

            if let provider = networkProvider {
                networkSignInButton(provider)
                    .padding(.top, 32)
                Text("Or sign in with your phone")
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .padding(.top, 30)
            }

            VStack(alignment: .leading, spacing: 20) {
                AuroraStepRow(number: 1, text: "Scan with your phone's camera")
                AuroraStepRow(number: 2, text: "Or go to \(typedURL ?? "your server's /activate page") and enter the code")
                AuroraStepRow(number: 3, text: "Approve on your phone. This TV signs in by itself.")
            }
            .padding(.top, networkProvider == nil ? 36 : 18)

            Label(TVSignInPresentation.nearbyHint, systemImage: "iphone.gen3")
                .font(.siloCaption)
                .foregroundStyle(Color.auroraInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 30)

            actionButtons
                .padding(.top, 40)
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let action = TVSignInPresentation.stateAction(for: qrVM.status) {
                Button {
                    Task { await qrVM.retry() }
                } label: {
                    Label(action == .tryAgain ? "Try again" : "Show a new code", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .frame(width: 440)
                .focused($focusedField, equals: .stateAction)
            }

            if !isUpdateRequired && offersPassword {
                Button {
                    showPasswordForm = true
                    focusedField = .username
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill").font(.system(size: 20, weight: .medium))
                        Text("Sign in with a password")
                    }
                }
                .buttonStyle(AuroraGhostButtonStyle())
                .focused($focusedField, equals: .usePassword)
            }

            Button {
                changeServer()
            } label: {
                Text("Change server")
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focusedField, equals: .changeServer)
        }
    }

    /// Whether "Sign in with a password" is offered: not on a server whose
    /// only sign-in is a browser provider (device sign-in covers those).
    /// Unknown discovery (loading or failed) keeps the password button.
    private var offersPassword: Bool { TVSignInPresentation.offersPassword(loginVM.signInOptions) }

    private var isUpdateRequired: Bool {
        if case .updateRequired = qrVM.status { return true }
        return false
    }

    // MARK: - Code panel (right)

    private var codePanel: some View {
        VStack(spacing: 22) {
            qrArea
            if qrVM.showsCode, let session = qrVM.session {
                Text(DeviceUserCode.display(session.userCode))
                    .font(.system(size: 76, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.auroraInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(Text("Code: \(Text(DeviceUserCode.spokenCharacters(session.userCode)).speechSpellsOutCharacters())"))
                // Inset like the QR tile; a long host wraps rather than
                // shrinking past legibility or running into the card edge.
                Text(typedURL ?? "")
                    .font(.siloBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: Self.qrSize + 2 * Self.qrQuietZone)
            }
            statusLine
        }
        .frame(width: Self.qrSize + 2 * Self.qrQuietZone + 88)
        .padding(.vertical, 40)
        .auroraGlass(cornerRadius: 30)
    }

    @ViewBuilder
    private var qrArea: some View {
        if qrVM.showsCode, let session = qrVM.session {
            qrCard {
                QRCodeView(content: session.verificationUriComplete, size: Self.qrSize)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("\(TVSignInPresentation.qrAccessibilityPrefix(typedURL: typedURL ?? ""))\(Text(DeviceUserCode.spokenCharacters(session.userCode)).speechSpellsOutCharacters())")
            )
        } else if case .approved = qrVM.status {
            qrCard {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 110, weight: .semibold))
                    .foregroundStyle(Color.green)
            }
            .accessibilityHidden(true)
        } else if qrVM.status.isTerminal {
            qrCard {
                Image(systemName: terminalSymbol)
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.35))
            }
            .accessibilityHidden(true)
        } else {
            qrCard {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .black.opacity(0.5)))
                    .scaleEffect(1.4)
            }
            .accessibilityHidden(true)
        }
    }

    private var terminalSymbol: String {
        switch qrVM.status {
        case .paused: return "pause.circle"
        case .denied: return "xmark.circle"
        default: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let text = TVSignInPresentation.statusLine(for: qrVM.status, codeWasRenewed: qrVM.codeWasRenewed, serverHost: serverHost) {
            HStack(alignment: .center, spacing: 12) {
                if qrVM.status == .waiting || qrVM.status == .opened || qrVM.status == .gettingCode {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color.auroraAccent))
                        .scaleEffect(0.8)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Self.qrSize + 2 * Self.qrQuietZone)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func qrCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack { content() }
            .frame(width: Self.qrSize, height: Self.qrSize)
            .padding(Self.qrQuietZone)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
    }

    // MARK: - Password fallback form

    private var passwordContent: some View {
        VStack(spacing: 0) {
            topBar
            sessionExpiredBanner
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 24) {
                AuroraEyebrow(text: "Account")
                Text("Sign in with a password")
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
                if qrVM.status == .noDeviceSignIn {
                    Text("This server only supports password sign-in.")
                        .font(.siloBody)
                        .foregroundStyle(Color.auroraInkSecondary)
                } else if let server = serverName {
                    Text("Use your account for \(server).")
                        .font(.siloBody)
                        .foregroundStyle(Color.auroraInkSecondary)
                }

                // A server without device sign-in lands here directly, so the
                // one-press sign-in is offered above the fields too.
                if qrVM.status == .noDeviceSignIn, let provider = networkProvider {
                    networkSignInButton(provider)
                }

                fieldGroup(label: "Username") {
                    AuroraInputField(
                        text: $loginVM.username,
                        placeholder: "yourname",
                        inputTitle: "Username",
                        focus: $focusedField,
                        equals: .username,
                        contentType: .username
                    )
                    // Advance to the password field once the username is entered.
                    .submitLabel(.next)
                    .onSubmit { moveFocusAfterTextEntry(to: .password) }
                }

                fieldGroup(label: "Password") {
                    HStack(spacing: 12) {
                        AuroraInputField(
                            text: $loginVM.password,
                            placeholder: "••••••",
                            inputTitle: "Password",
                            focus: $focusedField,
                            equals: .password,
                            isSecure: !showPassword,
                            contentType: .password
                        )
                        // Hand focus to the Sign In button once the password is entered.
                        .submitLabel(.done)
                        .onSubmit { moveFocusAfterTextEntry(to: .signIn) }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 22, weight: .medium))
                        }
                        .buttonStyle(TVAuthIconButtonStyle())
                        .focused($focusedField, equals: .togglePassword)
                        .disabled(!canFocusPasswordToggle)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }

                if let error = loginVM.error?.message {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.requestRose)
                        Text(error)
                            .font(.siloCaption)
                            .foregroundStyle(Color.requestRose)
                    }
                    .transition(.opacity)
                }

                Button {
                    submitPassword()
                } label: {
                    Text(loginVM.isLoading || isSubmittingPassword ? "Signing in…" : "Sign in")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: loginVM.isLoading || isSubmittingPassword))
                .focused($focusedField, equals: .signIn)
                .padding(.top, 4)

                // Single sign-on accounts have no Silo password.
                if let hint = loginVM.phoneHintLine {
                    Text(hint)
                        .font(.siloCaption)
                        .foregroundStyle(Color.auroraInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 18) {
                    if qrVM.status != .noDeviceSignIn {
                        Button {
                            returnToCodeScreen()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "qrcode").font(.system(size: 20, weight: .medium))
                                Text("Use your phone instead")
                            }
                        }
                        .buttonStyle(AuroraGhostButtonStyle())
                        .focused($focusedField, equals: .backToPhone)
                        // A phone approval must not race the password in flight.
                        .disabled(isSubmittingPassword)
                    }

                    Button {
                        changeServer()
                    } label: {
                        Text("Change server")
                    }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .focused($focusedField, equals: .changeServer)
                }
                .padding(.top, 6)
            }
            .padding(48)
            .frame(maxWidth: 780, alignment: .leading)
            .auroraGlass(cornerRadius: 30)
            .animation(.easeInOut(duration: 0.2), value: loginVM.error)
            .focusSection()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.auroraInkTertiary)
            content()
        }
    }

    // MARK: - Computed helpers

    /// The server's display name, falling back to its host.
    private var serverName: String? {
        if let entry = ServerRegistry.shared.activeServer {
            if let name = ServerIdentity.usable(entry.fetchedName) { return name }
            return TVSignInPresentation.host(of: entry.url)
        }
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : TVSignInPresentation.host(of: url)
    }

    /// The host this TV talks to, for "Can't reach <host>".
    private var serverHost: String {
        let url = ServerRegistry.shared.activeServerUrl.isEmpty ? AuthService.shared.serverUrl : ServerRegistry.shared.activeServerUrl
        return TVSignInPresentation.host(of: url)
    }

    /// `<host>/activate` from the latest code (the server's public URL when
    /// it has one). The code on screen always set `lastVerificationUris`.
    private var typedURL: String? {
        qrVM.lastVerificationUris.map { TVSignInPresentation.typedURL($0.uri, complete: $0.complete) }
    }

    /// Password sign-in and a phone approval complete once: polling pauses
    /// (a poll already in flight finishes first) and the password is only
    /// sent when the approval hasn't won. Success withdraws the code.
    private func submitPassword() {
        guard !loginVM.isLoading, !isSubmittingPassword, !isSubmittingNetwork else { return }
        isSubmittingPassword = true
        Task { @MainActor in
            defer { isSubmittingPassword = false }
            guard await qrVM.suspendForPasswordSignIn() else { return }
            let succeeded = await loginVM.login(router: router)
            qrVM.finishPasswordSignIn(succeeded: succeeded)
        }
    }

    /// "Continue as …": the same single flight as a password sign-in, so a
    /// phone approval and the network sign-in never both install a session.
    /// Success withdraws the code; a refusal shows under the button and the
    /// code keeps renewing.
    private func continueWithNetworkIdentity(_ provider: APIv2AuthProvider) {
        guard !loginVM.isBusy, !isSubmittingPassword, !isSubmittingNetwork else { return }
        isSubmittingNetwork = true
        Task { @MainActor in
            defer { isSubmittingNetwork = false }
            guard await qrVM.suspendForPasswordSignIn() else { return }
            let succeeded = await loginVM.signInWithNetworkIdentity(provider, router: router)
            qrVM.finishPasswordSignIn(succeeded: succeeded)
        }
    }

    /// Focus the screen places itself, as opposed to the person's moves.
    private func seedFocus(_ field: Field) {
        seededFocus = field
        focusedField = field
    }

    /// Leave for the profiles once, however the sign-in finished.
    private func goToProfiles() {
        // "Change server" during the approval pause has already left this
        // screen; don't pull the app back to profiles.
        guard !navigatedAfterApproval, router.authState == route else { return }
        navigatedAfterApproval = true
        router.showProfileSelection()
    }

    private func changeServer() {
        qrVM.stop()
        router.resetToServerSetup()
    }

    private func returnToCodeScreen() {
        guard !isSubmittingPassword else { return }
        showPasswordForm = false
        focusedField = .usePassword
        if qrVM.status.isTerminal {
            Task { await qrVM.retry() }
        }
    }

    /// Status changes are announced politely; the code itself is read on
    /// focus of the QR code.
    private func announce(_ status: QRLoginViewModel.Status) {
        guard UIAccessibility.isVoiceOverRunning,
              let text = TVSignInPresentation.statusLine(for: status, codeWasRenewed: qrVM.codeWasRenewed, serverHost: serverHost) else { return }
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    // MARK: - Nearby phone (LAN, st=login)

    /// Advertise this signed-out TV to nearby phones that hold its server.
    /// The identity comes from the server (`GET /api/v2/system/identity`),
    /// falling back to the one recorded for the saved server; without one,
    /// nothing is advertised because no phone could match it. Nothing is
    /// advertised while the server offers no device sign-in or needs an
    /// update either: a phone could only end on a failure.
    private func startNearbyAdvertising() async {
        let route = route
        guard PairingProtocol.advertisesSignInTVs,
              let entry = ServerRegistry.shared.activeServer else { return }
        let probed = await ServerIdentityResolver().fetchServerIdentity(serverURL: entry.url)
        guard !Task.isCancelled,
              let identity = ServerIdentity.usable(probed) ?? ServerIdentity.usable(entry.verifiedServerId) else { return }
        receiver.mode = .login(serverIdentity: identity, source: qrVM)
        await advertiser.advertise(state: .login, serverIdentity: identity,
                                   while: { router.authState == route && qrVM.offersNearbySignIn }) { session, stream in
            Task {
                await receiver.run(session: session, stream: stream)
                if case .idle = receiver.state { advertiser.release() }
            }
        }
    }

    private var canFocusPasswordToggle: Bool {
        focusedField == .password || focusedField == .togglePassword
    }

    private func moveFocusAfterTextEntry(to field: Field) {
        Task { @MainActor in
            await Task.yield()
            focusedField = field
        }
    }

    // MARK: - Constants

    /// At least a third of the 1080-point screen height.
    private static let qrSize: CGFloat = 360
    /// White margin around the modules; with the generator's own margin it
    /// gives the scanner a quiet zone of about four modules.
    private static let qrQuietZone: CGFloat = 30

    private static var deviceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "Apple TV" : name
    }
}

// MARK: - Local button styles

/// Square icon-only focus affordance for the password show/hide toggle.
struct TVAuthIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVAuthIconButtonBody(configuration: configuration)
    }
}

private struct TVAuthIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.siloBackground : Color.white.opacity(0.7))
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                    .fill(isFocused ? Color.siloOnSurface : Color.siloSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                            .stroke(
                                isFocused ? Color.clear : Color.siloOutline,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
    }
}

#endif
