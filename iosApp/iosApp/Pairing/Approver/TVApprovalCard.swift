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
    /// "Not you?": the other accounts this device has on the server, each
    /// of which can approve instead (`onUseAccount`).
    var otherAccounts: [SavedAccountSummary] = []
    var onUseAccount: (SavedAccountSummary) -> Void = { _ in }
    /// "Not you?": sign in with another account on this server, keeping
    /// every account already saved and the TV's code. Nil hides it.
    var onAddAccount: (() -> Void)? = nil
    var onClose: () -> Void

    @State private var choosesAccount = false
    @Environment(\.locale) private var locale

    private var offersAnotherAccount: Bool { onAddAccount != nil || !otherAccounts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.phase {
            case .idle, .lookingUp:
                HStack(spacing: 12) {
                    ProgressView()
                    Text(.tvPairApprovalLookingUp).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            case .review(let request), .approving(let request), .declining(let request):
                review(request, busy: model.phase != .review(request), declining: model.phase == .declining(request))
            case .approved(let request, let signedIn):
                result(
                    symbol: "checkmark.circle.fill", tint: .green,
                    title: Text(signedIn ? LocalizedStringResource.signInTvSignedIn : .signInTvSigningIn),
                    detail: signedIn ? Text(.tvPairApprovalChooseProfile(request.deviceName)) : nil
                )
                closeButton(.commonDone)
            case .unconfirmed:
                result(symbol: "questionmark.circle", tint: .orange,
                       title: Text(.tvPairApprovalUnconfirmed),
                       detail: Text(.tvPairApprovalUnconfirmedDetail(model.server.displayName)))
                closeButton(.companionClose)
            case .declined:
                result(symbol: "xmark.circle", tint: .secondary, title: Text(.tvPairApprovalDeclined),
                       detail: Text(.tvPairApprovalDeclinedDetail))
                closeButton(.commonDone)
            case .declinedElsewhere:
                result(symbol: "xmark.circle", tint: .secondary, title: Text(.signInTvErrorDeclined), detail: nil)
                closeButton(.companionClose)
            case .canceled:
                result(symbol: "tv.slash", tint: .orange, title: Text(.tvPairApprovalCanceled),
                       detail: Text(.tvPairApprovalCanceledDetail))
                closeButton(.companionClose)
            case .notFound(let serverName):
                notFound(serverName: serverName)
            case .expired:
                result(symbol: "clock.badge.exclamationmark", tint: .orange,
                       title: Text(.tvPairApprovalExpired),
                       detail: Text(.tvPairApprovalExpiredDetail))
                closeButton(.companionClose)
            case .alreadyUsed:
                result(symbol: "checkmark.circle", tint: .secondary, title: Text(.signInTvErrorAlreadySignedIn), detail: nil)
                closeButton(.companionClose)
            case .needsSignIn(let serverName):
                result(symbol: "person.crop.circle.badge.exclamationmark", tint: .orange,
                       title: Text(.tvPairApprovalNeedsSignIn(serverName)),
                       detail: Text(.tvPairApprovalNeedsSignInDetail(serverName)))
                closeButton(.companionClose)
            case .failed(let message):
                result(symbol: "exclamationmark.triangle.fill", tint: .yellow, title: Text(message), detail: nil)
                closeButton(.companionClose)
            }
        }
        .confirmationDialog(.tvPairApprovalAnotherAccountTitle, isPresented: $choosesAccount, titleVisibility: .visible) {
            ForEach(otherAccounts) { account in
                Button(account.username.map { LocalizedStringResource.tvPairApprovalUseAccount($0) } ?? .tvPairApprovalUseAnotherAccount) {
                    onUseAccount(account)
                }
            }
            if let onAddAccount {
                Button(.tvPairApprovalSignInAnotherAccount) { onAddAccount() }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(.tvPairApprovalAnotherAccountMessage(model.server.displayName))
        }
    }

    private func review(_ request: TVApprovalRequest, busy: Bool, declining: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(.signInTvCardTitle(request.deviceName))
                    .font(.siloTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let platform = request.platformLabel {
                    Text(platform).font(.siloCaption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(.signInTvCheckCode).font(.siloCaption).foregroundStyle(.secondary)
                Text(request.code)
                    .font(.siloPIN)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(Text(DeviceUserCode.spokenCharacters(request.code)).speechSpellsOutCharacters())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(signInLine(request)).font(.siloBody).fixedSize(horizontal: false, vertical: true)
                if offersAnotherAccount {
                    Button(.tvPairApprovalNotYou) { choosesAccount = true }
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
                    Text(.signInTvApprove).font(.siloHeadline)
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
                    Text(.signInTvNotNow)
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
        let when = request.requestedAt.map { Self.relative().localizedString(for: $0, relativeTo: Date()) }
        switch (when, request.networkHint) {
        case let (when?, hint?): return AppLanguage.string(.tvPairApprovalRequestedFrom(when, hint))
        case let (when?, nil): return AppLanguage.string(.signInTvRequested(when))
        case let (nil, hint?): return AppLanguage.string(.signInTvNetwork(hint))
        case (nil, nil): return nil
        }
    }

    /// Made per use, in the app's language.
    private static func relative() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.formattingLocale
        formatter.unitsStyle = .full
        return formatter
    }

    private func signInLine(_ request: TVApprovalRequest) -> String {
        Self.signInLine(serverName: request.serverName, serverHost: request.serverHost, accountName: request.accountName)
    }

    /// Which server and account approving signs the TV in to. Shared with
    /// the nearby-TV confirm card.
    static func signInLine(serverName: String, serverHost: String, accountName: String?) -> String {
        let server = AppLanguage.string(.signInTvServerWithHost(serverName, serverHost))
        if let accountName {
            return AppLanguage.string(.signInTvServerAccount(server, accountName))
        }
        return AppLanguage.string(.signInTvServerOnly(server))
    }

    static let profilesLine: LocalizedStringResource = .signInTvProfilesNote
    static let onlyApproveInFrontLine: LocalizedStringResource = .signInTvWarning

    private func notFound(serverName: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            result(symbol: "questionmark.circle", tint: .orange,
                   title: Text(.tvPairApprovalNotFoundOn(serverName)),
                   detail: Text(.tvPairApprovalNotFoundDetail))
            if !otherServers.isEmpty {
                Text(.tvPairApprovalTryAnotherServer).font(.siloCaption).foregroundStyle(.secondary)
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
                    Text(.tvPairApprovalEnterAnotherCode).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .pairingPrimaryButton()
            }
            closeButton(.companionClose)
        }
    }

    private func result(symbol: String, tint: Color, title: Text, detail: Text?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(tint).accessibilityHidden(true)
            title.font(.siloHeadline).fixedSize(horizontal: false, vertical: true)
            if let detail {
                detail.font(.siloCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func closeButton(_ title: LocalizedStringResource) -> some View {
        Button(action: onClose) {
            Text(title).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
#endif
