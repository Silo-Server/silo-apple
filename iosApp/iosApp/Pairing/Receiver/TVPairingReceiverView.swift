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

    @Environment(\.locale) private var locale
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
            chip(.tvPairingChipConnected, spinner: true)
            headline(Text(isSignIn ? LocalizedStringResource.tvPairingConnectedTitleSignin : .companionLinkedHeadlineSetup))
            MarqueeTVBody(AppLanguage.string(isSignIn
                ? LocalizedStringResource.tvPairingConnectedDetailSignin
                : .tvPairingConnectedDetailServersAppleTv))
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .consentRequested(serverName, accountName):
            chip(isSignIn ? LocalizedStringResource.tvPairingChipConsentSigninAppleTv : .tvPairingChipConsentAppleTv,
                 systemImage: "iphone")
            headline(Text(isSignIn ? LocalizedStringResource.tvPairingConsentTitleSignin : .tvPairingConsentTitle))
            MarqueeTVBody(Self.consentDetail(serverName: serverName, accountName: accountName))
                .padding(.top, 28)
            actions {
                Button { coordinator.allowPendingServer() } label: { Text(.tvPairingAllow) }
                    .buttonStyle(.marquee(.primary, fullWidth: false))
                    .focused($focused, equals: .primary)
                Button { Task { await coordinator.denyPendingServer() } } label: { Text(.companionDeny) }
                    .buttonStyle(.marquee(.glass, fullWidth: false))
                    .focused($focused, equals: .secondary)
            }
            Text(isSignIn
                ? LocalizedStringResource.tvPairingConsentNoteSignin
                : .tvPairingConsentNote)
                .font(.system(size: 22))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .padding(.top, 30)
        case let .awaitingApproval(serverName, accountName, _, _, automatic):
            chip(Self.signingInText(serverName: serverName, accountName: accountName), spinner: true)
            headline(Text(automatic ? LocalizedStringResource.tvPairingConfirmTitleAutomatic : .tvPairingConfirmTitle))
            // A bound request after a bound sign-in is approved without a
            // comparison (the phone checks the session binding), so don't ask
            // the user to compare a code their phone never shows.
            MarqueeTVBody(AppLanguage.string(automatic
                ? LocalizedStringResource.tvPairingConfirmDetailAutomatic
                : .tvPairingConfirmDetail))
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .signedIn(count):
            headline(Text(count <= 1 ? LocalizedStringResource.tvPairingSignedIn : .tvPairingSignedInAccounts(count)))
            MarqueeTVBody(AppLanguage.string(.tvPairingFinishing))
                .padding(.top, 28)
            // No Cancel here: this server's sign-in is already committed, so a
            // cancel button would promise an undo that doesn't exist.
        case let .completed(serverNames):
            headline(Text(.companionCompletedHeadline))
            MarqueeTVBody(completedSummary(serverNames))
                .padding(.top, 28)
            actions {
                Button { advance() } label: { Text(.tvPairingContinue) }
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
            chip(.companionReachingChip, spinner: true)
            headline(Text(.companionReachingHeadline(serverName)))
            MarqueeTVBody(AppLanguage.string(.tvPairingReachingDetailAppleTv))
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .preparingCode(serverName):
            chip(.tvPairingChipWorking, spinner: true)
            headline(Text(.tvPairingWorkingTitle(serverName)))
            MarqueeTVBody(AppLanguage.string(.tvPairingWorkingDetailAppleTv))
                .padding(.top, 28)
            actions { cancelButton(.primary) }
        case let .unreachable(serverName, help, alternate):
            headline(Text(.companionUnreachableHeadline(serverName)))
            MarqueeTVBody(help)
                .padding(.top, 28)
            actions {
                if let alternate {
                    Button { coordinator.useAlternateAddress() } label: {
                        Text(.tvPairingUseAlternate(Self.hostLabel(alternate.url)))
                    }
                    .buttonStyle(.marquee(.primary, fullWidth: false))
                    .focused($focused, equals: .primary)
                    Button { coordinator.retryPushedAddress() } label: { Text(.commonTryAgain) }
                        .buttonStyle(.marquee(.glass, fullWidth: false))
                        .focused($focused, equals: .secondary)
                } else {
                    Button { coordinator.retryPushedAddress() } label: { Text(.commonTryAgain) }
                        .buttonStyle(.marquee(.primary, fullWidth: false))
                        .focused($focused, equals: .primary)
                }
                Button { cancel() } label: { Text(.commonCancel) }
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focused, equals: .tertiary)
            }
        case let .failed(name, code, help):
            headline(Text(isSignIn ? LocalizedStringResource.companionFailedHeadline : .companionFailedHeadlineSetup))
            MarqueeTVBody(Self.failureText(name: name, code: code, help: help, signIn: isSignIn))
                .padding(.top, 28)
            actions {
                Button { cancel() } label: { Text(.commonTryAgain) }
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
            cardTitle(Text(.tvPairingCardOnPhone))
            cardNote(Text(isSignIn ? LocalizedStringResource.tvPairingCardOnPhoneNoteSignin : .companionLinkedCardNoteSetup))
        case let .consentRequested(serverName, _):
            HStack(spacing: 26) {
                MarqueeTVCardSymbol(systemImage: "iphone", size: 96)
                MarqueeWaitingDots(count: 5, size: 10)
                MarqueeServerMark(name: serverName, imageURL: nil, size: 96)
            }
            cardTitle(Text(verbatim: serverName))
            cardNote(Text(.tvPairingCardConsentNote))
        case let .awaitingApproval(serverName, accountName, code, matchWords, automatic):
            cardTitle(Text(.companionCodeCardTitle)).padding(.top, 0)
            MarqueeCodeTiles(code: DeviceUserCode.display(code))
                .padding(.top, 26)
                .accessibilityLabel(DeviceUserCode.spokenLabel(code) { AppLanguage.string(.shellMarqueeCodeSpoken($0)) })
            // Rollout fallback: phones released before user codes compare
            // the match words. Remove together with the phone's "Older TV
            // apps show ..." line once the iOS and Android apps that compare
            // user codes have shipped.
            if !automatic, let matchWords {
                cardNote(Text(.tvPairingConfirmOlderPhones(matchWords.uppercased())))
            }
            Divider().overlay(Color.white.opacity(0.1)).padding(.vertical, 30)
            HStack(spacing: 18) {
                MarqueeServerMark(name: serverName, imageURL: nil, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(serverName)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let accountName {
                        Text(accountName)
                            .font(.system(size: 22))
                            .foregroundStyle(Color.siloOnSurface.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
        case .signedIn, .completed:
            MarqueeTVCardSymbol(systemImage: "checkmark", tint: Color.siloStatusLive, size: 140)
            cardTitle(Text(.tvPairingSignedIn))
        case let .reaching(serverName):
            ProgressView().scaleEffect(1.6).frame(height: 112)
            cardTitle(Text(verbatim: serverName))
            cardNote(Text(.companionReachingCardNote))
        case let .preparingCode(serverName):
            ProgressView().scaleEffect(1.6).frame(height: 112)
            cardTitle(Text(verbatim: serverName))
        case .unreachable:
            MarqueeTVCardSymbol(systemImage: "wifi.exclamationmark", tint: Color.siloStatusWarning)
            cardTitle(Text(.tvPairingCardNoAnswer))
            cardNote(Text(.tvPairingCardNoAnswerNoteAppleTv))
        case let .failed(name, _, _):
            MarqueeTVCardSymbol(systemImage: "exclamationmark.triangle", tint: Color.siloStatusWarning)
            cardTitle(Text(.tvPairingCardNotFinished))
            // Earlier servers in the same session may have signed in.
            cardNote(Text(.tvPairingCardNotFinishedNote(name)))
        }
    }

    // MARK: - Pieces

    private func chip(_ text: LocalizedStringResource, spinner: Bool = false, systemImage: String? = nil) -> some View {
        MarqueeTVStatusChip(text: AppLanguage.string(text), showsSpinner: spinner, systemImage: systemImage)
            .padding(.bottom, 36)
    }

    private func headline(_ text: Text) -> some View {
        text
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

    private func cardTitle(_ text: Text) -> some View {
        text
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(2)
            .padding(.top, 34)
    }

    private func cardNote(_ text: Text) -> some View {
        text
            .font(.system(size: 22))
            .foregroundStyle(Color.siloOnSurface.opacity(0.4))
            .padding(.top, 10)
    }

    private func cancelButton(_ control: Control) -> some View {
        Button { cancel() } label: { Text(.commonCancel) }
            .buttonStyle(.marquee(.glass, fullWidth: false))
            .focused($focused, equals: control)
    }

    /// Each server once, however many of its accounts signed in.
    private func completedSummary(_ names: [String]) -> String {
        var seen = Set<String>()
        let servers = names.filter { seen.insert($0).inserted }
        return servers.isEmpty
            ? AppLanguage.string(.tvPairingCompletedNone)
            : AppLanguage.string(.tvPairingCompletedNamed(servers.joined(separator: ", ")))
    }

    /// "Signing in sam on Home", or "Signing in to Home" when the phone
    /// named no account. The name is the phone's claim, for display only.
    static func signingInText(serverName: String, accountName: String?) -> LocalizedStringResource {
        guard let accountName else { return .tvPairingChipSigningIn(serverName) }
        return .tvPairingChipSigningInAccount(accountName, serverName)
    }

    /// "… to Home as sam.", or "… to Home." when the phone named no account.
    private static func consentDetail(serverName: String, accountName: String?) -> String {
        guard let accountName else { return AppLanguage.string(.tvPairingConsentDetailAppleTv(serverName)) }
        return AppLanguage.string(.tvPairingConsentDetailAppleTvAccount(serverName, accountName))
    }

    /// The host of an address, for a button label. Falls back to the
    /// address itself when it does not parse.
    private static func hostLabel(_ url: String) -> String {
        URLComponents(string: url)?.host ?? url
    }

    private static func failureText(name: String, code: PairingFailureCode, help: String?, signIn: Bool) -> String {
        switch code {
        case .unreachable:
            guard let help else { return AppLanguage.string(.tvPairingFailedUnreachableAppleTv(name)) }
            return AppLanguage.string(.tvPairingFailedUnreachableHelp(help))
        case .identityMismatch where signIn:
            return AppLanguage.string(.tvPairingFailedIdentitySigninAppleTv(name))
        case .identityMismatch:
            return AppLanguage.string(.tvPairingFailedIdentity(name))
        case .denied:
            return AppLanguage.string(.tvPairingFailedDenied(name))
        case .expired:
            return AppLanguage.string(.tvPairingFailedExpired(name))
        case .updateRequired:
            return help ?? UpdateRequirement.serverMessage
        case .saveFailed:
            return AppLanguage.string(.tvPairingFailedSaveAppleTv(name))
        case .limitReached:
            return AppLanguage.string(.tvPairingFailedLimitAppleTv(name))
        case .authFailed:
            return AppLanguage.string(.tvPairingFailedGeneric(name))
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
