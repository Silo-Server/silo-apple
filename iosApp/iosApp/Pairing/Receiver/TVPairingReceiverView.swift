#if os(tvOS)
import SwiftUI

/// The pairing screens shown in place once a phone connects: inside
/// `TVServerSetupView` they replace the server chooser (setup), and inside
/// `TVLoginView` the code screen (sign-in). The host owns the advertiser, the
/// coordinator, and where to go once the TV is signed in; this view presents
/// `coordinator.state` in the first-run TV layout: what's happening on the
/// left with the one or two things you can do, and the phone, code, or result
/// in the card on the right. The coordinator's mode picks setup or sign-in
/// wording.
struct TVPairingReceiverView: View {
    var coordinator: ReceiverPairingCoordinator
    /// Leaves for the profiles. The host guards against moving on twice.
    var advance: () -> Void

    /// Dwell on the success screen before advancing, so it isn't a flash.
    private static let successDwell: Duration = .seconds(1.8)

    @FocusState private var focused: Control?
    private enum Control: Hashable { case primary, secondary, tertiary }

    var body: some View {
        MarqueeTVScreen {
            copy
        } card: {
            MarqueeTVCard { card }
        }
        .defaultFocus($focused, .primary, priority: .userInitiated)
        .marqueeTVSeedFocus($focused, .primary)
        // Each state draws its own buttons, so the one that had focus is gone;
        // hand focus to the new state's main action.
        .onChange(of: coordinator.state) { _, _ in focused = .primary }
    }

    private var isSignIn: Bool { coordinator.mode.isSignIn }

    // MARK: - Left column

    @ViewBuilder
    private var copy: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .linked:
            chip("Phone or tablet connected", spinner: true)
            headline(isSignIn ? "Continue on\nyour phone" : "Choose servers\non your phone")
            MarqueeTVBody(isSignIn
                ? "Continue on your phone or tablet."
                : "On your phone or tablet, choose which servers this Apple TV should sign in to.")
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .consentRequested(serverName):
            chip(isSignIn ? "A nearby phone is signing in this Apple TV" : "A nearby phone is setting up this Apple TV",
                 systemImage: "iphone")
            headline(isSignIn ? "Allow this\nsign-in?" : "Allow this\nsetup?")
            MarqueeTVBody("A nearby phone or tablet wants to sign this Apple TV in to \(serverName).")
                .padding(.top, 28)
            actions {
                Button { coordinator.allowPendingServer() } label: { Text("Allow") }
                    .buttonStyle(.marquee(.primary, fullWidth: false))
                    .focused($focused, equals: .primary)
                Button { Task { await coordinator.denyPendingServer() } } label: { Text("Don’t Allow") }
                    .buttonStyle(.marquee(.glass, fullWidth: false))
                    .focused($focused, equals: .secondary)
            }
            Text(isSignIn
                ? "Only allow it if you started this on your own phone or tablet."
                : "Only allow it if you started setup on your own phone or tablet.")
                .font(.system(size: 22))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .padding(.top, 30)
        case let .awaitingApproval(_, _, _, automatic):
            chip(automatic ? "Your phone is approving" : "Waiting for your phone", spinner: true)
            headline(automatic ? "Signing in" : "Confirm on\nyour phone")
            // Servers after the first are approved programmatically (the
            // phone verifies this code against the server) — don't ask the
            // user to compare a code their phone never shows.
            MarqueeTVBody(automatic
                ? "Your phone or tablet is checking this code for you."
                : "Check that your phone or tablet shows this code, then approve.")
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .signedIn(count):
            headline(count <= 1 ? "Signed in" : "Signed in to\n\(count) servers")
            MarqueeTVBody("Finishing up on your phone or tablet…")
                .padding(.top, 28)
            // No Cancel here: this server's sign-in is already committed, so a
            // cancel button would promise an undo that doesn't exist.
        case let .completed(serverNames):
            headline("You’re all set")
            MarqueeTVBody(completedSummary(serverNames))
                .padding(.top, 28)
            actions {
                Button { advance() } label: { Text("Continue") }
                    .buttonStyle(.marquee(.primary, fullWidth: false))
                    .focused($focused, equals: .primary)
            }
            .task {
                // Auto-advance after a short dwell; the button skips the wait.
                // A view torn down meanwhile (the host moved on) stays put.
                do { try await Task.sleep(for: Self.successDwell) } catch { return }
                advance()
            }
        case let .reaching(serverName):
            chip("Checking the address", spinner: true)
            headline("Connecting to\n\(serverName)")
            MarqueeTVBody("Checking which address this Apple TV can reach.")
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .preparingCode(serverName):
            chip("Getting a code", spinner: true)
            headline("Signing in to\n\(serverName)")
            MarqueeTVBody("Getting this Apple TV's sign-in code.")
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .unreachable(serverName, help, alternate):
            headline("Can’t reach\n\(serverName)")
            MarqueeTVBody(help)
                .padding(.top, 28)
            actions {
                if let alternate {
                    Button { coordinator.useAlternateAddress() } label: {
                        Text("Use \(Self.hostLabel(alternate.url))")
                    }
                    .buttonStyle(.marquee(.primary, fullWidth: false))
                    .focused($focused, equals: .primary)
                    Button { coordinator.retryPushedAddress() } label: { Text("Try again") }
                        .buttonStyle(.marquee(.glass, fullWidth: false))
                        .focused($focused, equals: .secondary)
                } else {
                    Button { coordinator.retryPushedAddress() } label: { Text("Try again") }
                        .buttonStyle(.marquee(.primary, fullWidth: false))
                        .focused($focused, equals: .primary)
                }
                Button { cancel() } label: { Text("Cancel") }
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focused, equals: .tertiary)
            }
        case let .failed(name, code, help):
            headline(isSignIn ? "Sign-in didn’t finish" : "Setup didn’t finish")
            MarqueeTVBody(Self.failureText(name: name, code: code, help: help, signIn: isSignIn))
                .padding(.top, 28)
            actions {
                Button { cancel() } label: { Text("Try again") }
                    .buttonStyle(.marquee(.primary, fullWidth: false))
                    .focused($focused, equals: .primary)
            }
        }
    }

    // MARK: - Right card

    @ViewBuilder
    private var card: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .linked:
            MarqueeTVCardSymbol(systemImage: "iphone")
            cardTitle("On your phone")
            cardNote(isSignIn ? "Approve the sign-in there." : "Pick the servers to bring over, then tap Continue.")
        case let .consentRequested(serverName):
            HStack(spacing: 26) {
                MarqueeTVCardSymbol(systemImage: "iphone", size: 96)
                MarqueeWaitingDots(count: 5, size: 10)
                MarqueeServerMark(name: serverName, imageURL: nil, size: 96)
            }
            cardTitle(serverName)
            cardNote("After you allow it, a code appears here to compare with your phone.")
        case let .awaitingApproval(serverName, code, matchWords, automatic):
            cardTitle("Sign-in code").padding(.top, 0)
            MarqueeCodeTiles(code: DeviceUserCode.display(code))
                .padding(.top, 26)
                .accessibilityLabel(Text("Code: \(Text(DeviceUserCode.spokenCharacters(code)).speechSpellsOutCharacters())"))
            // Rollout fallback: phones released before user codes compare
            // the match words. Remove together with the phone's "Older TV
            // apps show ..." line once the iOS and Android apps that compare
            // user codes have shipped.
            if !automatic, let matchWords {
                cardNote("Older phones show \(matchWords.uppercased()) instead.")
            }
            Divider().overlay(Color.white.opacity(0.1)).padding(.vertical, 30)
            HStack(spacing: 18) {
                MarqueeServerMark(name: serverName, imageURL: nil, size: 56)
                Text(serverName)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .signedIn, .completed:
            MarqueeTVCardSymbol(systemImage: "checkmark", tint: Color.siloStatusLive, size: 140)
            cardTitle("Signed in")
        case let .reaching(serverName):
            ProgressView().scaleEffect(1.6).frame(height: 112)
            cardTitle(serverName)
            cardNote("Trying the addresses your phone sent.")
        case let .preparingCode(serverName):
            ProgressView().scaleEffect(1.6).frame(height: 112)
            cardTitle(serverName)
        case .unreachable:
            MarqueeTVCardSymbol(systemImage: "wifi.exclamationmark", tint: Color.siloStatusWarning)
            cardTitle("No answer")
            cardNote("This Apple TV couldn’t reach the address your phone sent.")
        case let .failed(name, _, _):
            MarqueeTVCardSymbol(systemImage: "exclamationmark.triangle", tint: Color.siloStatusWarning)
            cardTitle("Not finished")
            // Earlier servers in the same session may have signed in.
            cardNote("\(name) wasn't signed in.")
        }
    }

    // MARK: - Pieces

    private func chip(_ text: String, spinner: Bool = false, systemImage: String? = nil) -> some View {
        MarqueeTVStatusChip(text: text, showsSpinner: spinner, systemImage: systemImage)
            .padding(.bottom, 36)
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

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 22) { content() }
            .padding(.top, 56)
            .focusSection()
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(2)
            .padding(.top, 34)
    }

    private func cardNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22))
            .foregroundStyle(Color.siloOnSurface.opacity(0.4))
            .padding(.top, 10)
    }

    private func cancelButton(_ control: Control) -> some View {
        Button { cancel() } label: { Text("Cancel") }
            .buttonStyle(.marquee(.glass, fullWidth: false))
            .focused($focused, equals: control)
    }

    private func completedSummary(_ names: [String]) -> String {
        names.isEmpty
            ? "Taking you to your profiles…"
            : "Signed in to \(names.joined(separator: ", ")). Taking you to your profiles…"
    }

    /// The host of an address, for a button label. Falls back to the
    /// address itself when it does not parse.
    private static func hostLabel(_ url: String) -> String {
        URLComponents(string: url)?.host ?? url
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

    // MARK: - Actions

    /// Tear down the session and return the host to its idle two-card layout
    /// (the advertiser keeps listening, so a fresh phone attempt just works).
    private func cancel() {
        Task { await coordinator.cancel() }
    }
}

#endif
