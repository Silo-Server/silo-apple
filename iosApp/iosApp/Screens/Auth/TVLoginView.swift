#if os(tvOS)
import SwiftUI
import UIKit

/// Phone-first sign-in for tvOS. The screen leads with the QR
/// device-login pairing so the viewer never types on the remote: a bold
/// hero + numbered steps on the left, a glass panel with the live QR and
/// match code on the right. An on-screen username/password form is one
/// focus-step away as the fallback. A device-login session is started
/// eagerly on appear so the QR is scannable the moment the screen shows.
struct TVLoginView: View {
    var router: AppRouter

    @State private var loginVM = LoginViewModel()
    @State private var qrVM = QRLoginViewModel()
    @State private var showPassword: Bool = false
    @State private var showPasswordForm: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case usePassword
        case retryPhone
        case changeServer
        case username
        case password
        case togglePassword
        case signIn
        case backToPhone
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: .signIn, scrim: showPasswordForm ? .soft : .left)
            Group {
                if showPasswordForm {
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
            await qrVM.begin(deviceName: Self.deviceName, devicePlatform: "tvOS")
        }
        .onChange(of: qrVM.state) { _, newValue in
            if case .approved = newValue {
                StartupContentPrefetcher.prefetchProfiles()
                router.showProfileSelection()
            } else if case .error = newValue {
                focusedField = .retryPhone
            }
        }
        .onDisappear { qrVM.cancel() }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            SiloWordmarkView(width: 132)
            if let host = hostLabel {
                Label(host, systemImage: "server.rack")
                    .font(.continuumCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
            Spacer(minLength: 0)
            AuroraJourneyProgress(currentStep: 2)
                .frame(width: 430)
        }
    }

    // MARK: - Phone-first layout

    private var phoneFirstContent: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 32)
            HStack(alignment: .center, spacing: 88) {
                heroColumn
                    .frame(width: 860, alignment: .leading)
                qrPanel
                    .focusSection()
            }
            .frame(maxWidth: 1680)
            Spacer(minLength: 0)
        }
        .defaultFocus($focusedField, .usePassword, priority: .userInitiated)
    }

    private var heroColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuroraEyebrow(text: "Account")
            Text("Scan. Confirm.\nStart watching.")
                .font(.continuumHeroTitle)
                .foregroundStyle(Color.auroraInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            Text("Open your phone’s Camera and point it at the code. You won’t need to type a password on your TV.")
                .font(.continuumBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .lineSpacing(4)
                .frame(maxWidth: 720, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)

            VStack(alignment: .leading, spacing: 22) {
                AuroraStepRow(number: 1, text: "Scan the QR code")
                AuroraStepRow(number: 2, text: "Confirm the code matches")
                AuroraStepRow(number: 3, text: "Approve this Apple TV")
            }
            .padding(.top, 42)

            waitingStatus
                .padding(.top, 40)
        }
    }

    @ViewBuilder
    private var waitingStatus: some View {
        if case .awaiting = qrVM.state {
            HStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color.auroraAccent))
                    .scaleEffect(0.95)
                Text(statusText)
                    .font(.continuumCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - QR glass panel (right)

    private var qrPanel: some View {
        VStack(spacing: 28) {
            Label("Scan with Camera", systemImage: "camera")
                .font(.continuumSubheadline)
                .foregroundStyle(Color.auroraInk)

            qrCodeArea

            if case .awaiting(let session) = qrVM.state {
                VStack(spacing: 14) {
                    Text("CONFIRM THIS CODE")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Color.auroraInkTertiary)
                    matchCodeTiles(session.matchCode)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 300, height: 1)

            VStack(spacing: 14) {
                if case .error = qrVM.state {
                    Button(action: restartPhoneSignIn) {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    .focused($focusedField, equals: .retryPhone)
                }

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

                Button {
                    router.resetToServerSetup()
                } label: {
                    Text("Use another server")
                }
                .buttonStyle(AuroraGhostButtonStyle())
                .focused($focusedField, equals: .changeServer)
            }
        }
        .padding(44)
        .auroraGlass(cornerRadius: 30)
    }

    @ViewBuilder
    private var qrCodeArea: some View {
        switch qrVM.state {
        case .idle, .starting:
            qrCard {
                ZStack {
                    Color.white
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black.opacity(0.5)))
                        .scaleEffect(1.3)
                }
            }
        case .awaiting(let session):
            qrCard {
                QRCodeView(content: session.verificationUriComplete, size: Self.qrSize)
            }
        case .approved:
            qrCard {
                ZStack {
                    Color.white
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 92, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
            }
        case .error(let message):
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.requestRose)
                Text("Pairing code unavailable")
                    .font(.continuumSubheadline)
                    .foregroundStyle(Color.auroraInk)
                Text(message)
                    .font(.continuumCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.qrSize, height: Self.qrSize)
        }
    }

    private func qrCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: Self.qrSize, height: Self.qrSize)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
    }

    private func matchCodeTiles(_ code: String) -> some View {
        let chars = Array(code.uppercased())
        let gap: CGFloat = 10
        // Match codes are server-generated word pairs of unbounded length.
        // Cap the row width and scale the tiles down for longer codes so the
        // row never becomes the widest element in the panel — otherwise the
        // split layout overflows its maxWidth and shoves the hero column off
        // the left edge.
        let maxRowWidth: CGFloat = 560
        let totalGaps = gap * CGFloat(max(chars.count - 1, 0))
        let tileWidth = min(60, (maxRowWidth - totalGaps) / CGFloat(max(chars.count, 1)))
        let sepWidth = tileWidth * 0.46
        let tileHeight = tileWidth * 1.23
        let fontSize = tileWidth * 0.63

        return HStack(spacing: gap) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, ch in
                let isSep = (ch == "-" || ch == " ")
                Text(isSep ? "–" : String(ch))
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSep ? Color.auroraInkTertiary : Color.auroraInk)
                    .frame(width: isSep ? sepWidth : tileWidth, height: tileHeight)
                    .background {
                        if !isSep {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.06))
                        }
                    }
                    .overlay {
                        if !isSep {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        }
                    }
            }
        }
    }

    // MARK: - Password fallback form

    private var passwordContent: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 24) {
                AuroraEyebrow(text: "Account")
                Text("Sign in with a password")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
                if let host = hostLabel {
                    Text("Use the account credentials for \(host).")
                        .font(.continuumBody)
                        .foregroundStyle(Color.auroraInkSecondary)
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
                    .onSubmit { focusedField = .password }
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
                        .onSubmit { focusedField = .signIn }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 22, weight: .medium))
                        }
                        .buttonStyle(TVAuthIconButtonStyle())
                        .focused($focusedField, equals: .togglePassword)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }

                if let error = loginVM.error {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.requestRose)
                        Text(error)
                            .font(.continuumCaption)
                            .foregroundStyle(Color.requestRose)
                    }
                    .transition(.opacity)
                }

                Button {
                    guard !loginVM.isLoading else { return }
                    Task { await loginVM.login(router: router) }
                } label: {
                    Text(loginVM.isLoading ? "Signing in…" : "Sign in")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: loginVM.isLoading))
                .focused($focusedField, equals: .signIn)
                .padding(.top, 4)

                HStack(spacing: 18) {
                    Button {
                        showPasswordForm = false
                        focusedField = .usePassword
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "qrcode").font(.system(size: 20, weight: .medium))
                            Text("Use phone sign-in")
                        }
                    }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .focused($focusedField, equals: .backToPhone)

                    Button {
                        router.resetToServerSetup()
                    } label: {
                        Text("Use another server")
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

    /// "yourserver.local" pulled out of the stored URL so the user knows
    /// which server they're signing into without a full URL on display.
    private var hostLabel: String? {
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            return host
        }
        return url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var statusText: String {
        let remaining = qrVM.secondsRemaining
        guard remaining > 0 else { return "Waiting for approval…" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "Waiting for approval · %d:%02d", minutes, seconds)
    }

    private func restartPhoneSignIn() {
        qrVM.cancel()
        Task {
            await qrVM.begin(deviceName: Self.deviceName, devicePlatform: "tvOS")
        }
    }

    // MARK: - Constants

    /// Large enough to scan comfortably while keeping the screen inside the
    /// visible tvOS safe area.
    private static let qrSize: CGFloat = 300

    private static var deviceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "Apple TV" : name
    }
}

// MARK: - Field chrome
//
// Explicit focus-aware chrome for tvOS text fields. We can't rely on
// `@Environment(\.isFocused)` inside a `TextFieldStyle._body` because it
// doesn't reliably fire for SwiftUI TextFields on tvOS — the focus platter
// paints but the style's color flip never runs, so the typed value ends up
// white-on-white. Taking focus as an explicit parameter from the owning
// view's `@FocusState` sidesteps the issue. Shared with `TVServerSetupView`.

struct TVAuthFieldChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .font(.continuumBody)
            .foregroundStyle(isFocused ? Color.continuumBackground : Color.continuumOnSurface)
            .tint(isFocused ? Color.continuumBackground : Color.continuumOnSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .continuumInputChrome(isFocused: isFocused)
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
            .foregroundStyle(isFocused ? Color.continuumBackground : Color.white.opacity(0.7))
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                    .fill(isFocused ? Color.continuumOnSurface : Color.continuumSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                            .stroke(
                                isFocused ? Color.clear : Color.continuumOutline,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .focusEffectDisabled()
            .animation(ContinuumTheme.springAnimation, value: isFocused)
    }
}

#endif
