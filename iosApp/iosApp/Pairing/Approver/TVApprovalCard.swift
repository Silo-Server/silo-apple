#if os(iOS)
import SwiftUI

/// The approval card for one TV sign-in request. Same content model as the
/// web `/activate` card and the Android app: which TV, the code to check,
/// which server and account, what approving grants, and a warning to only
/// approve a TV in front of you.
struct TVApprovalCard: View {
    @Bindable var model: TVApprovalModel
    /// "Try another server" when the code isn't found; nil hides it.
    var otherServers: [ServerEntry] = []
    var onChooseServer: (ServerEntry) -> Void = { _ in }
    /// Back to code entry when the code isn't found (a mistyped digit is the
    /// usual cause); nil hides it.
    var onEnterAnotherCode: (() -> Void)? = nil
    /// "Not you?": sign out of this server in Silo only, then sign in again,
    /// keeping the TV's code. The wording follows `model.accountSwitch`:
    /// "Switch account" when the provider is asked for an account choice or
    /// the server only takes passwords, "Sign out" when a provider could
    /// sign the same person straight back in. Nil hides the link.
    var onSwitchAccount: (() -> Void)? = nil
    var onClose: () -> Void

    @State private var confirmsSwitchAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.phase {
            case .idle, .lookingUp:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking up the code…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            case .review(let request), .approving(let request), .declining(let request):
                review(request, busy: model.phase != .review(request), declining: model.phase == .declining(request))
            case .approved(let request, let signedIn):
                result(
                    symbol: "checkmark.circle.fill", tint: .green,
                    title: signedIn ? "Your TV is signed in." : "Done. Your TV is signing in.",
                    detail: signedIn ? "\(request.deviceName) can choose a profile now." : nil
                )
                closeButton("Done")
            case .unconfirmed:
                result(symbol: "questionmark.circle", tint: .orange,
                       title: "Couldn't confirm the approval yet.",
                       detail: "Check the TV. This updates when \(model.server.displayName) confirms it.")
                closeButton("Close")
            case .declined:
                result(symbol: "xmark.circle", tint: .secondary, title: "Sign-in declined.",
                       detail: "The TV shows that you declined.")
                closeButton("Done")
            case .declinedElsewhere:
                result(symbol: "xmark.circle", tint: .secondary, title: "This sign-in was declined.", detail: nil)
                closeButton("Close")
            case .canceled:
                result(symbol: "tv.slash", tint: .orange, title: "This TV stopped waiting.",
                       detail: "Start again on the TV.")
                closeButton("Close")
            case .notFound(let serverName):
                notFound(serverName: serverName)
            case .expired:
                result(symbol: "clock.badge.exclamationmark", tint: .orange,
                       title: "This code expired.",
                       detail: "Your TV is showing a new one; scan it again.")
                closeButton("Close")
            case .alreadyUsed:
                result(symbol: "checkmark.circle", tint: .secondary, title: "That TV is already signed in.", detail: nil)
                closeButton("Close")
            case .needsSignIn(let serverName):
                result(symbol: "person.crop.circle.badge.exclamationmark", tint: .orange,
                       title: "Sign in to \(serverName) again",
                       detail: "This device's sign-in for \(serverName) has ended. Sign in to it again, then approve the TV.")
                closeButton("Close")
            case .failed(let message):
                result(symbol: "exclamationmark.triangle.fill", tint: .yellow, title: message, detail: nil)
                closeButton("Close")
            }
        }
        .confirmationDialog(model.offersAccountChoice ? "Switch account?" : "Sign out?",
                            isPresented: $confirmsSwitchAccount, titleVisibility: .visible) {
            Button(model.offersAccountChoice ? "Sign Out and Switch" : "Sign Out") { onSwitchAccount?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.switchAccountMessage(serverName: model.server.displayName,
                                           choosingAccount: model.offersAccountChoice))
        }
    }

    static func switchAccountLink(_ accountSwitch: TVApprovalAccountSwitch) -> String {
        accountSwitch == .signOut ? "Not you? Sign out" : "Not you? Switch account"
    }

    /// The confirmation. Without `select_account` the provider may sign the
    /// same person straight back in, so the copy promises no account choice.
    static func switchAccountMessage(serverName: String, choosingAccount: Bool) -> String {
        if choosingAccount {
            return "You'll be signed out of \(serverName) on this device, then asked which account to sign in with. The TV's code stays ready to approve."
        }
        return "You'll be signed out of \(serverName) on this device. Sign in with the account the TV should use, then approve it. The TV's code stays ready to approve."
    }

    private func review(_ request: TVApprovalRequest, busy: Bool, declining: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in \(request.deviceName)?")
                    .font(.siloTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let platform = request.platformLabel {
                    Text(platform).font(.siloCaption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Check that your TV shows").font(.siloCaption).foregroundStyle(.secondary)
                Text(request.code)
                    .font(.siloPIN)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(Text(DeviceUserCode.spokenCharacters(request.code)).speechSpellsOutCharacters())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(signInLine(request)).font(.siloBody).fixedSize(horizontal: false, vertical: true)
                if onSwitchAccount != nil {
                    Button(Self.switchAccountLink(model.accountSwitch)) { confirmsSwitchAccount = true }
                        .font(.siloCaption)
                        .disabled(busy)
                }
            }

            Label(Self.profilesLine, systemImage: "person.2")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(Self.onlyApproveInFrontLine, systemImage: "exclamationmark.shield")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let line = requestedLine(request) {
                Text(line).font(.siloCaption).foregroundStyle(.secondary)
            }

            Button {
                Task { await model.approve() }
            } label: {
                HStack {
                    if busy && !declining { ProgressView().tint(Color.siloBackground) }
                    Text("Sign in TV").font(.siloHeadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .pairingPrimaryButton()
            .disabled(busy)

            Button {
                Task { await model.decline() }
            } label: {
                HStack {
                    if declining { ProgressView() }
                    Text("Not now")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.siloSecondaryText)
            .disabled(busy)
        }
    }

    /// "Requested 2 min ago from 192.168.1.x", with whichever parts the
    /// server sent.
    private func requestedLine(_ request: TVApprovalRequest) -> String? {
        let when = request.requestedAt.map { Self.relative.localizedString(for: $0, relativeTo: Date()) }
        switch (when, request.networkHint) {
        case let (when?, hint?): return "Requested \(when) from \(hint)"
        case let (when?, nil): return "Requested \(when)"
        case let (nil, hint?): return "Requested from \(hint)"
        case (nil, nil): return nil
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func signInLine(_ request: TVApprovalRequest) -> String {
        Self.signInLine(serverName: request.serverName, serverHost: request.serverHost, accountName: request.accountName)
    }

    /// Which server and account approving signs the TV in to. Shared with
    /// the nearby-TV confirm card.
    static func signInLine(serverName: String, serverHost: String, accountName: String?) -> String {
        let server = "\(serverName) (\(serverHost))"
        if let accountName {
            return "You'll sign it in to \(server) as \(accountName)."
        }
        return "You'll sign it in to \(server) with your account."
    }

    static let profilesLine = "Anyone using this TV can pick from your profiles. Profiles with a PIN stay locked."
    static let onlyApproveInFrontLine = "Only approve a TV that's in front of you right now."

    private func notFound(serverName: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            result(symbol: "questionmark.circle", tint: .orange,
                   title: "We couldn't find that code on \(serverName).",
                   detail: "Check the code on your TV. The TV shows its server's name at the top of its screen.")
            if !otherServers.isEmpty {
                Text("Try another server").font(.siloCaption).foregroundStyle(.secondary)
                ForEach(otherServers) { server in
                    Button {
                        onChooseServer(server)
                    } label: {
                        Label(server.displayName, systemImage: "server.rack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let onEnterAnotherCode {
                Button(action: onEnterAnotherCode) {
                    Text("Enter another code").font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .pairingPrimaryButton()
            }
            closeButton("Close")
        }
    }

    private func result(symbol: String, tint: Color, title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(.siloHeadline).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.siloCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func closeButton(_ title: String) -> some View {
        Button(action: onClose) {
            Text(title).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
#endif
