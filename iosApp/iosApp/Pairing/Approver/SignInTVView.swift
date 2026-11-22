#if os(iOS)
import SwiftUI

/// "Sign in a TV" (Settings): type the eight-character code a TV shows, pick the
/// server it belongs to, then approve it on the card.
///
/// A code only means something on the server that issued it. With one
/// signed-in server that server is used; with several, the active one is
/// preselected and the user can switch. If the code isn't found, the card
/// offers the other servers, one explicit choice at a time. The code is
/// never looked up on every saved server.
struct SignInTVView: View {
    var initialCode: String = ""
    var initialServerId: String? = nil
    /// "Not you?" › "Sign in with another account" on the card: the caller
    /// closes this view and adds an account on the server, keeping the TV's
    /// code and every account already saved. The flag is the card's
    /// `offersAccountChoice`: whether the provider is asked to let the person
    /// choose an account.
    var onAddAccount: ((ServerEntry, DeviceApprovalLink, Bool) -> Void)? = nil
    var onClose: () -> Void

    @State private var code = ""
    @State private var servers: [ServerEntry] = []
    @State private var selectedServerId: String?
    @State private var model: TVApprovalModel?
    @State private var loadedServers = false
    /// The account each server's requests use, which approves unless the
    /// person picks another one under "Not you?".
    @State private var accountInUse: [String: String] = [:]
    @State private var directory = AccountDirectory.shared
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ScrollView {
                        TVApprovalCard(
                            model: model,
                            otherServers: servers.filter { $0.id != model.server.id },
                            onChooseServer: { server in
                                selectedServerId = server.id
                                lookUp(on: server)
                            },
                            onEnterAnotherCode: {
                                model.stop()
                                self.model = nil
                                code = ""
                                codeFocused = true
                            },
                            otherAccounts: otherAccounts(than: model),
                            onUseAccount: { account in
                                lookUp(on: model.server, account: account.localAccountId)
                            },
                            onAddAccount: onAddAccount.map { addAccount in
                                {
                                    model.stop()
                                    addAccount(model.server, DeviceApprovalLink(server: model.server, code: model.code),
                                               model.offersAccountChoice)
                                }
                            },
                            onClose: onClose
                        )
                        .padding(20)
                    }
                } else {
                    entryForm
                }
            }
            .navigationTitle(.signInTvTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel) {
                        model?.stop()
                        onClose()
                    }
                }
            }
        }
        .task { await loadServers() }
        .onDisappear { model?.stop() }
    }

    private var entryForm: some View {
        Form {
            Section {
                TextField("0000 0000", text: codeBinding)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($codeFocused)
                    .accessibilityLabel(.tvPairEntryCodeLabel)
            } header: {
                Text(.tvPairDetailCode)
            } footer: {
                Text(.signInTvSubtitle)
            }

            if servers.count > 1 {
                Section {
                    Picker(.signInTvServerLabel, selection: $selectedServerId) {
                        ForEach(servers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                } footer: {
                    Text(.tvPairEntryServerFooter)
                }
            } else if loadedServers && servers.isEmpty {
                Section {
                    Text(.tvPairEntryNoServers).foregroundStyle(.secondary)
                }
            }

            Section {
                Button(.signInTvContinue) {
                    guard let server = servers.first(where: { $0.id == selectedServerId }) else { return }
                    lookUp(on: server)
                }
                .disabled(!DeviceUserCode.isComplete(code) || selectedServerId == nil)
            }
        }
    }

    /// Letters and digits, shown grouped 4+4 as the TV shows them.
    private var codeBinding: Binding<String> {
        Binding(get: { code }, set: { code = DeviceUserCode.entryText($0) })
    }

    private func loadServers() async {
        guard !loadedServers else { return }
        servers = await CompanionPairingCoordinator.serversWithTokens()
        directory.reload()
        for server in servers {
            accountInUse[server.id] = await TokenStore.shared.requestAccountId(onServer: server.id)
        }
        loadedServers = true
        let preferred = initialServerId.flatMap { id in servers.first { $0.id == id } }
        selectedServerId = preferred?.id ?? servers.first?.id
        if !initialCode.isEmpty { codeBinding.wrappedValue = initialCode }
        if let preferred, !initialCode.isEmpty {
            lookUp(on: preferred)
        } else {
            codeFocused = true
        }
    }

    /// `account` approves; nil is the account the server's requests use.
    private func lookUp(on server: ServerEntry, account: String? = nil) {
        model?.stop()
        let next = TVApprovalModel(server: server, code: code.isEmpty ? initialCode : code,
                                   localAccountId: account ?? accountInUse[server.id])
        model = next
        Task { await next.lookUp() }
    }

    /// The signed-in accounts on the card's server besides the one approving.
    private func otherAccounts(than model: TVApprovalModel) -> [SavedAccountSummary] {
        directory.accounts(onServer: model.server.id).filter {
            !$0.needsSignIn && $0.localAccountId != model.localAccountId
        }
    }
}

/// Handles `silo://device?server=&url=&code=` from the web approval page:
/// finds the saved server with that verified identity, or offers to add it
/// from the link's address, then shows the approval card.
struct DeviceLinkApprovalView: View {
    @Environment(\.locale) private var locale
    let link: DeviceApprovalLink
    /// Add the server (prefilled) and come back to the link after signing in.
    var onAddServer: (String) -> Void
    /// Sign in to a saved server this device is signed out of, and come back
    /// to the link after signing in.
    var onSignIn: (ServerEntry, DeviceApprovalLink) -> Void
    /// "Not you?" on the card (see `SignInTVView.onAddAccount`).
    var onAddAccount: (ServerEntry, DeviceApprovalLink, Bool) -> Void
    var onClose: () -> Void

    private enum Resolution: Equatable {
        case resolving
        case saved(ServerEntry)
        case signedOut(ServerEntry)
        case addServer(url: String)
        case failed(String)
    }

    @State private var resolution: Resolution = .resolving

    var body: some View {
        Group {
            switch resolution {
            case .resolving:
                NavigationStack {
                    ProgressView(.tvPairLinkResolving)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(.commonCancel, action: onClose) } }
                }
            case .saved(let server):
                SignInTVView(initialCode: link.code, initialServerId: server.id, onAddAccount: onAddAccount,
                             onClose: onClose)
            case .signedOut(let server):
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(.tvSignInTitle(server.displayName)).font(.siloTitle)
                        Text(.tvPairLinkSignedOutBody(server.displayName))
                            .font(.siloBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            onSignIn(server, DeviceApprovalLink(server: server, code: link.code))
                        } label: {
                            Text(.signInTvSignInFirst).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.siloOnSurface)
                        .foregroundStyle(Color.siloBackground)
                        Spacer()
                    }
                    .padding(20)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(.commonCancel, action: onClose) } }
                }
            case .addServer(let url):
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(.tvPairLinkAddServerTitle).font(.siloTitle)
                        Text(.tvPairLinkAddServerBody(TVSignInPresentation.host(of: url)))
                            .font(.siloBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            onAddServer(url)
                        } label: {
                            Text(.companionUnknownServerAdd).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.siloOnSurface)
                        .foregroundStyle(Color.siloBackground)
                        Spacer()
                    }
                    .padding(20)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(.commonCancel, action: onClose) } }
                }
            case .failed(let message):
                NavigationStack {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.yellow)
                        Text(message).font(.siloBody).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(.companionClose, action: onClose) } }
                }
            }
        }
        .task { resolution = await resolve() }
    }

    private func resolve() async -> Resolution {
        let signedIn = await CompanionPairingCoordinator.serversWithTokens()
        let signedInIds = Set(signedIn.map(\.id))
        let signedOut = ServerRegistry.shared.sortedEntries.filter { !signedInIds.contains($0.id) }
        switch await DeviceLinkServerMatch.resolve(link, signedIn: signedIn, signedOut: signedOut, probe: { url in
            await ServerIdentityResolver().probeIdentity(serverURL: url)
        }) {
        case .saved(let server, let learnedIdentity):
            if let learnedIdentity {
                ServerRegistry.shared.updateVerifiedServerId(for: server.id, verifiedServerId: learnedIdentity)
            }
            return .saved(Self.saved(server, identity: learnedIdentity))
        case .savedSignedOut(let server, let learnedIdentity):
            if let learnedIdentity {
                ServerRegistry.shared.updateVerifiedServerId(for: server.id, verifiedServerId: learnedIdentity)
            }
            return .signedOut(Self.saved(server, identity: learnedIdentity))
        case .addServer(let url):
            return .addServer(url: url)
        case .unreachable(let url):
            return .failed(AppLanguage.string(.tvPairLinkUnreachable(TVSignInPresentation.host(of: url))))
        case .mismatch:
            return .failed(AppLanguage.string(.tvPairLinkMismatch))
        }
    }

    /// `server` as saved now: learning its identity can merge it into
    /// another saved address of the same server (`ServerRegistry.mergeDuplicateServers`).
    private static func saved(_ server: ServerEntry, identity: String?) -> ServerEntry {
        ServerRegistry.shared.entry(with: server.id) ?? ServerRegistry.shared.entry(verifiedServerId: identity) ?? server
    }
}
#endif

/// Which saved server a device link means. Pure apart from the identity
/// probe, so the rules can be tested:
///
/// 1. A saved server whose verified identity is the link's wins, a signed-in
///    one before one this device is signed out of.
/// 2. Saved servers without a recorded identity are probed (one identity
///    read each, never a code lookup) and matched the same way.
/// 3. Otherwise the link's address must answer with the link's identity to
///    be offered for adding. A link without an identity matches a saved
///    server only by its exact address.
///
/// A signed-out match is never offered for adding: the entry is kept on
/// sign-out and session expiry, and adding it again from another address
/// would save the same deployment twice.
enum DeviceLinkServerMatch: Equatable {
    case saved(ServerEntry, learnedIdentity: String?)
    /// Saved, but this device has no session for it: sign in to it first.
    case savedSignedOut(ServerEntry, learnedIdentity: String?)
    case addServer(url: String)
    case unreachable(url: String)
    case mismatch

    static func resolve(
        _ link: DeviceApprovalLink,
        signedIn: [ServerEntry],
        signedOut: [ServerEntry] = [],
        probe: (String) async -> ServerIdentityProbeResult
    ) async -> DeviceLinkServerMatch {
        let saved = signedIn + signedOut
        func match(_ server: ServerEntry, learnedIdentity: String?) -> DeviceLinkServerMatch {
            signedIn.contains { $0.id == server.id }
                ? .saved(server, learnedIdentity: learnedIdentity)
                : .savedSignedOut(server, learnedIdentity: learnedIdentity)
        }
        if let identity = link.serverId {
            if let server = saved.first(where: { $0.verifiedServerId == identity }) {
                return match(server, learnedIdentity: nil)
            }
            for server in saved where server.verifiedServerId == nil {
                if case .identity(let probed) = await probe(server.url), probed == identity {
                    return match(server, learnedIdentity: probed)
                }
            }
            guard let url = link.serverURL else { return .mismatch }
            switch await probe(url) {
            case .identity(let probed) where probed == identity: return .addServer(url: url)
            case .unreachable: return .unreachable(url: url)
            default: return .mismatch
            }
        }
        guard let url = link.serverURL else { return .mismatch }
        if let server = saved.first(where: { $0.url == url }) { return match(server, learnedIdentity: nil) }
        return .addServer(url: url)
    }
}
