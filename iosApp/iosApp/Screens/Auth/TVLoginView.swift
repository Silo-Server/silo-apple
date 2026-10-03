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
    @State private var server = SignInServerModel()
    @State private var advertiser = TVPairingAdvertiser()
    @State private var receiver = ReceiverPairingCoordinator()
    @State private var showPassword: Bool = false
    @State private var showPasswordForm: Bool = false
    @State private var isSubmittingPassword = false
    @State private var isSubmittingNetwork = false
    /// Counts failed password attempts so the fields shake on each one.
    @State private var passwordFailures = 0
    /// Set by `goToProfiles()`, the one place this screen moves on after a
    /// device sign-in (the QR approval and the nearby panel both land there).
    @State private var navigatedAfterApproval = false

    @FocusState private var focusedField: Field?
    /// Where focus goes once the system keyboard closes after Done.
    @State private var focusAfterKeyboard: Field?
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

    private var showsPasswordScreen: Bool { showPasswordForm || qrVM.status == .noDeviceSignIn }

    var body: some View {
        ZStack {
            if isPairing {
                TVPairingReceiverView(coordinator: receiver, advance: goToProfiles)
                    .transition(.opacity)
            } else if offersOnlyNetworkSignIn {
                networkOnlyScreen
                    .transition(.opacity)
            } else if showsPasswordScreen {
                passwordScreen
                    .transition(.opacity)
            } else {
                codeScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.32), value: isPairing)
        .animation(.easeOut(duration: 0.32), value: showsPasswordScreen)
        .animation(.easeOut(duration: 0.32), value: offersOnlyNetworkSignIn)
        .task {
            MarqueeScene.shared.focus = .account
            MarqueeScene.shared.personalTint = nil
            await server.load()
        }
        .task {
            await qrVM.begin(deviceName: Self.deviceName, devicePlatform: AppleDeviceIdentity.current.platform)
        }
        .task { await startNearbyAdvertising() }
        .task { await loginVM.loadSignInOptions() }
        .onChange(of: qrVM.status, initial: true) { _, status in
            loginVM.offersPhoneRoute = status != .noDeviceSignIn
        }
        .onChange(of: offersOnlyNetworkSignIn) { _, networkOnly in
            // The screen focus was on gave way to "Continue as …" alone.
            // Otherwise discovery answering leaves focus where it is: the
            // person may be pressing it.
            if networkOnly { focusedField = .networkSignIn }
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
                focusedField = networkProvider == nil ? .username : .networkSignIn
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
    }

    // MARK: - Code screen

    private var codeScreen: some View {
        MarqueeTVScreen {
            sessionExpiredChip
            serverCard
            headline("Sign in to \(server.serverName)")
                .padding(.top, 44)
            if let provider = networkProvider {
                networkSignInButton(provider)
                    .padding(.top, 32)
                Text("Or sign in with your phone")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                    .padding(.top, 30)
            }
            MarqueeTVBody(codeLead)
                .padding(.top, networkProvider == nil ? 26 : 12)
            Label(TVSignInPresentation.nearbyHint, systemImage: "iphone.gen3")
                .font(.system(size: 22))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            codeActions
                .padding(.top, 48)
        } card: {
            MarqueeTVCard { codeCard }
        }
        .defaultFocus($focusedField, defaultCodeScreenFocus, priority: .userInitiated)
        .marqueeTVSeedFocus($focusedField, defaultCodeScreenFocus)
    }

    /// Where focus enters the code screen: "Continue as …" when this TV can
    /// sign in through its network provider, else the password button.
    /// Discovery answering after focus landed does not move it.
    private var defaultCodeScreenFocus: Field {
        if networkProvider != nil { return .networkSignIn }
        return offersPassword ? .usePassword : .changeServer
    }

    private var codeLead: String {
        let page = typedURL ?? "your server's /activate page"
        return "Scan the code with your phone's camera, or go to \(page) and enter it. Approve on your phone and this Apple TV signs in by itself."
    }

    private var codeActions: some View {
        HStack(spacing: 22) {
            if let action = TVSignInPresentation.stateAction(for: qrVM.status) {
                Button {
                    Task { await qrVM.retry() }
                } label: {
                    Label(action == .tryAgain ? "Try again" : "Show a new code", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.marquee(.primary, fullWidth: false))
                .focused($focusedField, equals: .stateAction)
            }

            if !isUpdateRequired && offersPassword {
                Button {
                    showPasswordForm = true
                    focusedField = .username
                } label: {
                    Label("Sign in with a password", systemImage: "key")
                }
                .buttonStyle(.marquee(.glass, fullWidth: false))
                .focused($focusedField, equals: .usePassword)
            }

            Button("Change server") { changeServer() }
                .buttonStyle(.marquee(.plain, fullWidth: false))
                .focused($focusedField, equals: .changeServer)
        }
        .focusSection()
    }

    /// Whether "Sign in with a password" is offered: not on a server whose
    /// only sign-in is a browser provider (device sign-in covers those).
    /// Unknown discovery (loading or failed) keeps the password button.
    private var offersPassword: Bool { TVSignInPresentation.offersPassword(loginVM.signInOptions) }

    private var isUpdateRequired: Bool {
        if case .updateRequired = qrVM.status { return true }
        return false
    }

    // MARK: - Code card (right)

    @ViewBuilder
    private var codeCard: some View {
        if qrVM.showsCode, let session = qrVM.session {
            qrFrame {
                QRCodeView(content: session.verificationUriComplete, size: Self.qrSize)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("\(TVSignInPresentation.qrAccessibilityPrefix(typedURL: typedURL ?? ""))\(Self.spelledOut(session.userCode))")
            )
            MarqueeCodeTiles(code: DeviceUserCode.display(session.userCode))
                .padding(.top, 34)
                .accessibilityLabel(Text("Code: \(Self.spelledOut(session.userCode))"))
            // A long host wraps rather than shrinking past legibility.
            Text(typedURL ?? "")
                .font(.system(size: 24))
                .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 18)
        } else if case .approved = qrVM.status {
            MarqueeTVCardSymbol(systemImage: "checkmark", tint: Color(hex: "#30D158"), size: 140)
        } else if qrVM.status.isTerminal {
            MarqueeTVCardSymbol(systemImage: terminalSymbol, tint: Color(hex: "#F4C869"))
        } else {
            qrFrame {
                ProgressView().tint(.black.opacity(0.5)).scaleEffect(1.4)
            }
            .accessibilityHidden(true)
        }
        statusLine
            .padding(.top, 24)
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
            HStack(alignment: .center, spacing: 14) {
                if qrVM.status == .waiting || qrVM.status == .opened || qrVM.status == .gettingCode {
                    ProgressView()
                        .scaleEffect(0.8)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func qrFrame<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack { Color.white; content() }
            .frame(width: Self.qrSize, height: Self.qrSize)
            .padding(Self.qrQuietZone)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
    }

    // MARK: - Password screen

    private var passwordScreen: some View {
        MarqueeTVScreen {
            sessionExpiredChip
            serverCard
            headline("Sign in with\na password")
                .padding(.top, 44)
            MarqueeTVBody(qrVM.status == .noDeviceSignIn && networkProvider == nil
                ? "This server only supports password sign-in."
                : "Use your \(server.serverName) username and password.")
                .padding(.top, 22)

            // A server without device sign-in lands here directly, so the
            // one-press sign-in is offered above the fields too.
            if qrVM.status == .noDeviceSignIn, let provider = networkProvider {
                networkSignInButton(provider)
                    .padding(.top, 30)
            }

            VStack(spacing: 20) {
                MarqueeTVField(
                    systemImage: "person",
                    placeholder: "Username",
                    text: $loginVM.username,
                    focus: $focusedField,
                    equals: .username,
                    content: .username
                )
                // Advance to the password field once the username is entered.
                .submitLabel(.next)
                .onSubmit { focusAfterKeyboard = .password }
                HStack(spacing: 16) {
                    MarqueeTVField(
                        systemImage: "lock",
                        placeholder: "Password",
                        text: $loginVM.password,
                        focus: $focusedField,
                        equals: .password,
                        content: .password,
                        isSecure: !showPassword,
                        isError: loginVM.error != nil
                    )
                    // Hand focus to the Sign In button once the password is entered.
                    .submitLabel(.done)
                    .onSubmit { focusAfterKeyboard = .signIn }

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.marquee(.glass, fullWidth: false))
                    .focused($focusedField, equals: .togglePassword)
                    .disabled(!canFocusPasswordToggle)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
            }
            .frame(width: 760)
            .padding(.top, 40)
            .modifier(MarqueeShake(trigger: passwordFailures))
            .focusSection()

            if let error = loginVM.error?.message {
                MarqueeErrorText(error)
                    .frame(width: 760, alignment: .leading)
                    .padding(.top, 16)
                    .transition(.opacity)
            }

            // Single sign-on accounts have no Silo password.
            if let hint = loginVM.phoneHintLine {
                Text(hint)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                    .frame(width: 760, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }

            HStack(spacing: 22) {
                Button {
                    submitPassword()
                } label: {
                    Text(isSigningIn ? "Signing in…" : "Sign in")
                }
                .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: isSigningIn))
                .focused($focusedField, equals: .signIn)

                if qrVM.status != .noDeviceSignIn {
                    Button {
                        returnToCodeScreen()
                    } label: {
                        Label("Use your phone instead", systemImage: "qrcode")
                    }
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focusedField, equals: .backToPhone)
                    // A phone approval must not race a sign-in in flight.
                    .disabled(isSubmittingPassword || isSubmittingNetwork)
                }

                Button("Change server") { changeServer() }
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focusedField, equals: .changeServer)
                    // A password sign-in in flight would pull the app back.
                    .disabled(isSubmittingPassword)
            }
            // Full width, so Down from the show-password button reaches the
            // row; entering it lands on Sign in.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 40)
            .focusSection()
            .defaultFocus($focusedField, .signIn, priority: .userInitiated)
        } card: {
            MarqueeTVCard {
                MarqueeTVCardSymbol(systemImage: "iphone")
                Text("Type on your phone")
                    .font(.system(size: 40, weight: .bold))
                    .padding(.top, 34)
                Text("When you select a field, a keyboard notification appears on nearby iPhones and iPads. Type there instead of with the remote.")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .padding(.top, 14)
            }
        }
        .defaultFocus($focusedField, passwordScreenFocus, priority: .userInitiated)
        .marqueeTVSeedFocus($focusedField, passwordScreenFocus)
        .marqueeTVFocusAfterKeyboard($focusedField, pending: $focusAfterKeyboard)
        // Menu returns to the code screen; on a password-only server there is
        // none, so Menu keeps its system meaning.
        .onExitCommand(perform: qrVM.status == .noDeviceSignIn ? nil : returnToCodeScreen)
        .animation(.easeInOut(duration: 0.2), value: loginVM.error)
    }

    private var isSigningIn: Bool { loginVM.isLoading || isSubmittingPassword }

    /// A server without device sign-in opens here; "Continue as …" leads
    /// when it is offered. Choosing a password from the code screen focuses
    /// the username itself.
    private var passwordScreenFocus: Field {
        qrVM.status == .noDeviceSignIn && networkProvider != nil ? .networkSignIn : .username
    }

    // MARK: - Network sign-in

    /// The network provider discovery lists for this TV (at most one is
    /// enabled on a server), when the request came through its network.
    private var networkProvider: APIv2AuthProvider? { loginVM.networkProviders.first }

    /// No code and no password on this server: "Continue as …" stands alone.
    private var offersOnlyNetworkSignIn: Bool {
        TVSignInPresentation.offersOnlyNetworkSignIn(loginVM.signInOptions,
                                                     deviceSignIn: qrVM.status != .noDeviceSignIn)
    }

    /// "Continue as <owner>" over "via <provider>", and the refusal under it.
    /// Not disabled while it runs: on TV a disabled button loses focus.
    private func networkSignInButton(_ provider: APIv2AuthProvider) -> some View {
        let inFlight = isSubmittingNetwork || loginVM.providerInFlight == provider.id
        return VStack(alignment: .leading, spacing: 14) {
            Button {
                continueWithNetworkIdentity(provider)
            } label: {
                if inFlight {
                    Text("Signing in…")
                } else {
                    MarqueeNetworkSignInLabel(provider: provider, serverURL: server.serverURL)
                }
            }
            .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: inFlight))
            .focused($focusedField, equals: .networkSignIn)
            .accessibilityLabel(inFlight ? "Signing in…" : NetworkSignIn.accessibilityLabel(for: provider))

            if let error = loginVM.networkSignInError?.message {
                MarqueeErrorText(error)
                    .frame(maxWidth: 760, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: loginVM.networkSignInError)
    }

    /// A server that offers this TV neither a code nor a password:
    /// "Continue as …" is the one way in.
    private var networkOnlyScreen: some View {
        MarqueeTVScreen {
            sessionExpiredChip
            serverCard
            headline("Sign in to \(server.serverName)")
                .padding(.top, 44)
            if let provider = networkProvider {
                networkSignInButton(provider)
                    .padding(.top, 40)
            }
            Button("Change server") { changeServer() }
                .buttonStyle(.marquee(.plain, fullWidth: false))
                .focused($focusedField, equals: .changeServer)
                .padding(.top, 30)
        } card: {
            MarqueeTVCard {
                MarqueeTVCardSymbol(systemImage: "network")
                Text("No code needed")
                    .font(.system(size: 40, weight: .bold))
                    .padding(.top, 34)
                Text("This Apple TV reached \(server.serverName) through \(networkProvider.map { SignInOptions.providerName(for: $0) } ?? "its network"), which knows who it belongs to.")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .padding(.top, 14)
            }
        }
        .defaultFocus($focusedField, .networkSignIn, priority: .userInitiated)
        .marqueeTVSeedFocus($focusedField, .networkSignIn)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var sessionExpiredChip: some View {
        if router.loginNotice == .sessionExpired {
            MarqueeTVStatusChip(
                text: String(format: TVSignInPresentation.sessionExpiredBanner, server.serverName),
                systemImage: "exclamationmark.circle"
            )
            .padding(.bottom, 30)
        }
    }

    private var serverCard: some View {
        MarqueeServerCard(
            name: server.serverName,
            address: server.hostLabel,
            markURL: server.branding?.markURL,
            badge: server.isSecure ? .init(text: "Secure", systemImage: "lock") : .init(text: "HTTP", systemImage: "lock.open", tone: .warning)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
            .kerning(-2)
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Computed helpers

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

    // MARK: - Actions

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
            if !succeeded {
                passwordFailures += 1
                focusedField = .password
            }
        }
    }

    /// Leave for the profiles once, however the sign-in finished.
    private func goToProfiles() {
        // "Change server" during the approval pause has already left this
        // screen; don't pull the app back to profiles.
        guard !navigatedAfterApproval, router.authState == route else { return }
        navigatedAfterApproval = true
        router.skipsSingleProfilePicker = true
        router.showProfileSelection()
    }

    private func changeServer() {
        qrVM.stop()
        router.resetToServerSetup()
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

    private func returnToCodeScreen() {
        guard !isSubmittingPassword, !isSubmittingNetwork else { return }
        showPasswordForm = false
        focusedField = .usePassword
        if qrVM.status.isTerminal {
            Task { await qrVM.retry() }
        }
    }

    /// Status changes are announced politely; the code itself is read on
    /// focus of the QR code. "Only password sign-in" is not announced while
    /// "Continue as …" is offered too.
    private func announce(_ status: QRLoginViewModel.Status) {
        guard UIAccessibility.isVoiceOverRunning, status != .noDeviceSignIn || networkProvider == nil,
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

    /// The code as one element VoiceOver reads character by character.
    private static func spelledOut(_ code: String) -> Text {
        Text(DeviceUserCode.spokenCharacters(code)).speechSpellsOutCharacters()
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

#endif
