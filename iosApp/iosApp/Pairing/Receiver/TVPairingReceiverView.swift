#if os(tvOS)
import SwiftUI

/// The pairing panel rendered *in place* once a phone connects: inside
/// `TVServerSetupView` it replaces the two-card "Add your server" layout
/// (setup), and inside `TVLoginView` it replaces the code screen (sign-in),
/// on the same Aurora backdrop (no cover, so nothing bleeds through). The
/// host owns the advertiser + coordinator lifecycle and where to go once
/// the TV is signed in; this view is pure presentation of
/// `coordinator.state` plus a focusable escape hatch. The coordinator's
/// mode picks setup or sign-in wording.
struct TVPairingReceiverView: View {
    var coordinator: ReceiverPairingCoordinator
    /// Leaves for the profiles. The host guards against moving on twice.
    var advance: () -> Void

    /// Dwell on the success screen before advancing, so it isn't a flash.
    private static let successDwell: Duration = .seconds(1.8)

    @FocusState private var focused: Control?
    private enum Control: Hashable { case primary, secondary, tertiary }

    var body: some View {
        VStack(spacing: 28) {
            switch coordinator.state {
            case .idle:
                // Host renders the two-card layout for idle; nothing to show here.
                EmptyView()
            case .linked:
                linked
            case let .consentRequested(serverName):
                consent(serverName: serverName)
            case let .awaitingApproval(serverName, code, matchWords, automatic):
                awaitingApproval(serverName: serverName, code: code, matchWords: matchWords, automatic: automatic)
            case let .signedIn(count):
                signedIn(count: count)
            case let .completed(serverNames):
                completed(serverNames: serverNames)
            case let .reaching(serverName):
                reaching(serverName: serverName)
            case let .preparingCode(serverName):
                preparingCode(serverName: serverName)
            case let .unreachable(serverName, help, alternate):
                unreachable(serverName: serverName, help: help, alternate: alternate)
            case let .failed(name, code, help):
                failed(name: name, code: code, help: help)
            }
        }
        .frame(maxWidth: 880)
        .multilineTextAlignment(.center)
    }

    private var isSignIn: Bool { coordinator.mode.isSignIn }

    /// The step eyebrow: setup connects a server, sign-in is the account
    /// step. The same deck as Android TV.
    private var connectEyebrow: some View {
        AuroraEyebrow(text: isSignIn ? "Step 02 — Account" : "Step 01 — Connect", centered: true)
    }

    // MARK: - Linked (phone connected, picking servers on its end)

    private var linked: some View {
        VStack(spacing: 26) {
            connectEyebrow
            Text("Phone or tablet connected")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            WaitingDots()
            Text(isSignIn
                ? "Continue on your phone or tablet."
                : "On your phone or tablet, choose which servers this Apple TV should sign in to.")
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 720)
            cancelButton(title: "Cancel")
                .padding(.top, 8)
        }
    }

    // MARK: - Consent (the session's one TV-side gate)

    private func consent(serverName: String) -> some View {
        VStack(spacing: 24) {
            connectEyebrow
            Image(systemName: "iphone.gen3")
                .font(.system(size: 60, weight: .ultraLight))
                .foregroundStyle(Color.auroraInk)
            Text(isSignIn ? "Allow this sign-in?" : "Allow this setup?")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            Text("A nearby phone or tablet wants to sign this Apple TV in to \(serverName).")
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 720)

            Button { coordinator.allowPendingServer() } label: { Text("Allow") }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .focused($focused, equals: .primary)
                .frame(width: 360)
                .padding(.top, 8)
            Button { Task { await coordinator.denyPendingServer() } } label: { Text("Don’t Allow") }
                .buttonStyle(AuroraGhostButtonStyle())
                .focused($focused, equals: .secondary)
        }
        .defaultFocus($focused, .primary)
    }

    // MARK: - Awaiting approval (the sign-in code)

    private func awaitingApproval(serverName: String, code: String, matchWords: String?, automatic: Bool) -> some View {
        VStack(spacing: 24) {
            AuroraEyebrow(text: "Almost there", centered: true)
            Text(automatic ? "Signing in" : "Confirm on your phone or tablet")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)

            codeCard(code)
            // Rollout fallback: phones released before user codes compare
            // the match words. Remove together with the phone's "Older TV
            // apps show ..." line once the iOS and Android apps that compare
            // user codes have shipped.
            if !automatic, let matchWords {
                Text("Older phones show \(matchWords.uppercased()) instead.")
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkTertiary)
            }

            VStack(spacing: 10) {
                Text(isSignIn ? "SIGNING IN TO" : "SETTING UP")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.auroraInkTertiary)
                Text(serverName)
                    .font(.siloSubheadline)
                    .foregroundStyle(Color.auroraInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
                WaitingDots(compact: true)
                // Servers after the first are approved programmatically (the
                // phone verifies this code against the server) — don't ask the
                // user to compare a code their phone never shows.
                Text(automatic
                    ? "Your phone or tablet is checking this code for you."
                    : "Check that your phone or tablet shows this code, then approve.")
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
            .frame(maxWidth: 720)

            cancelButton(title: "Cancel")
                .padding(.top, 6)
        }
    }

    /// The TV's sign-in code, the same one the sign-in screen shows. VoiceOver
    /// reads it character by character so it can be compared with the phone.
    private func codeCard(_ code: String) -> some View {
        Text(DeviceUserCode.display(code))
            .font(.system(size: 76, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.auroraInk)
            .padding(.horizontal, 56)
            .padding(.vertical, 28)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .fixedSize()
            .accessibilityLabel(Text("Code: \(Text(DeviceUserCode.spokenCharacters(code)).speechSpellsOutCharacters())"))
    }

    // MARK: - Signed in (interim, per server during multi-server)

    private func signedIn(count: Int) -> some View {
        VStack(spacing: 20) {
            successMark
            Text(count <= 1 ? "Signed in" : "Signed in to \(count) servers")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            HStack(spacing: 12) {
                WaitingDots(compact: true)
                Text("Finishing up on your phone or tablet…")
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
            // No Cancel here: this server's sign-in is already committed, so a
            // cancel button would promise an undo that doesn't exist.
        }
    }

    // MARK: - Completed (terminal success → advance to profiles)

    private func completed(serverNames: [String]) -> some View {
        VStack(spacing: 22) {
            AuroraEyebrow(text: "All set", centered: true)
            successMark
            Text("You’re all set")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            Text(completedSummary(serverNames))
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 720)

            Button { advance() } label: { Text("Continue") }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .focused($focused, equals: .primary)
                .frame(width: 360)
                .padding(.top, 8)
        }
        .task {
            // Auto-advance after a short dwell; the button skips the wait.
            // A view torn down meanwhile (the host moved on) stays put.
            do { try await Task.sleep(for: Self.successDwell) } catch { return }
            advance()
        }
        .defaultFocus($focused, .primary)
    }

    private func completedSummary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Taking you to your profiles…"
        case 1: return "Signed in to \(names[0]). Taking you to your profiles…"
        default: return "Signed in to \(names.joined(separator: ", ")). Taking you to your profiles…"
        }
    }

    // MARK: - Reaching (checking which address answers)

    private func reaching(serverName: String) -> some View {
        VStack(spacing: 26) {
            connectEyebrow
            Text("Connecting to \(serverName)")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            WaitingDots()
            Text("Checking which address this Apple TV can reach.")
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 720)
            cancelButton(title: "Cancel")
                .padding(.top, 8)
        }
    }

    // MARK: - Preparing the code (sign-in)

    private func preparingCode(serverName: String) -> some View {
        VStack(spacing: 26) {
            Text("Signing in to \(serverName)")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            WaitingDots()
            Text("Getting this Apple TV's sign-in code.")
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 720)
            cancelButton(title: "Cancel")
                .padding(.top, 8)
        }
    }

    // MARK: - Unreachable (provider help + explicit alternate)

    /// The pushed address did not answer. The user chooses: set the provider
    /// up and retry, or use the verified alternate address when the server
    /// offers one. Nothing switches on its own.
    private func unreachable(serverName: String, help: String, alternate: ServerEndpoint?) -> some View {
        VStack(spacing: 22) {
            connectEyebrow
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(Color.auroraAccent)
            Text("Can’t reach \(serverName)")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            Text(help)
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 760)

            if let alternate {
                Button { coordinator.useAlternateAddress() } label: {
                    Text("Use \(Self.hostLabel(alternate.url))")
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .focused($focused, equals: .primary)
                .frame(width: 520)
                .padding(.top, 8)
                Button { coordinator.retryPushedAddress() } label: { Text("Try again") }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .focused($focused, equals: .secondary)
            } else {
                Button { coordinator.retryPushedAddress() } label: { Text("Try again") }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    .focused($focused, equals: .primary)
                    .frame(width: 360)
                    .padding(.top, 8)
            }
            Button { cancel() } label: { Text("Cancel") }
                .buttonStyle(AuroraGhostButtonStyle())
                .focused($focused, equals: .tertiary)
        }
        .defaultFocus($focused, .primary)
    }

    /// The host of an address, for a button label. Falls back to the
    /// address itself when it does not parse.
    private static func hostLabel(_ url: String) -> String {
        URLComponents(string: url)?.host ?? url
    }

    // MARK: - Failed (actionable retry)

    private func failed(name: String, code: PairingFailureCode, help: String?) -> some View {
        VStack(spacing: 22) {
            connectEyebrow
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.auroraAccent)
            Text(isSignIn ? "Sign-in didn’t finish" : "Setup didn’t finish")
                .font(.siloTitle)
                .foregroundStyle(Color.auroraInk)
            Text(Self.failureText(name: name, code: code, help: help, signIn: isSignIn))
                .font(.siloBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .frame(maxWidth: 720)

            Button { cancel() } label: { Text("Try again") }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .focused($focused, equals: .primary)
                .frame(width: 360)
                .padding(.top, 8)
        }
        .defaultFocus($focused, .primary)
    }

    private static func failureText(name: String, code: PairingFailureCode, help: String?, signIn: Bool) -> String {
        switch code {
        case .unreachable:
            return (help ?? "This Apple TV can’t reach \(name).")
                + " You can also add the server manually with its public address."
        case .identityMismatch where signIn:
            return "The phone or tablet offered \(name), which isn't the server this Apple TV uses. Choose this Apple TV's server on your phone or tablet, or sign in here with a password."
        case .identityMismatch:
            return "The phone or tablet sent an address for \(name) that answered as a different server. Check the server on your phone or tablet, or add your server manually."
        case .denied:
            return "The sign-in to \(name) was declined. Try again from your phone or tablet."
        case .expired:
            return "The code for \(name) expired before it was approved. Try again from your phone or tablet."
        case .updateRequired:
            return help ?? UpdateRequirement.serverMessage
        case .saveFailed:
            return "\(name) approved the sign-in, but this Apple TV couldn't save it. Try again from your phone or tablet."
        case .authFailed:
            return "Something went wrong signing in to \(name). Try again from your phone or tablet, or add your server manually."
        }
    }

    // MARK: - Shared pieces

    private var successMark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 72))
            .foregroundStyle(Color.green)
            .shadow(color: Color.green.opacity(0.4), radius: 24)
    }

    private func cancelButton(title: String) -> some View {
        Button { cancel() } label: { Text(title) }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focused, equals: .primary)
    }

    // MARK: - Actions

    /// Tear down the session and return the host to its idle two-card layout
    /// (the advertiser keeps listening, so a fresh phone attempt just works).
    private func cancel() {
        Task { await coordinator.cancel() }
    }

}

// MARK: - Waiting indicator

/// Three softly pulsing dots for "waiting on your phone" states.
private struct WaitingDots: View {
    var compact: Bool = false
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dot: CGFloat { compact ? 8 : 12 }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.auroraAccent)
                    .frame(width: dot, height: dot)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        reduceMotion ? nil :
                            .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                        value: animating)
            }
        }
        .onAppear { animating = true }
    }
}
#endif
