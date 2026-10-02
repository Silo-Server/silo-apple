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
    /// "Not you?" on the card: the caller closes this view, signs out of the
    /// server and signs in again with the TV's code kept. The flag is the
    /// card's `offersAccountChoice`: whether the provider is asked to let
    /// the person choose an account.
    var onSwitchAccount: ((ServerEntry, DeviceApprovalLink, Bool) -> Void)? = nil
    var onClose: () -> Void

    @State private var code = ""
    @State private var servers: [ServerEntry] = []
    @State private var selectedServerId: String?
    @State private var model: TVApprovalModel?
    @State private var loadedServers = false
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
                            onSwitchAccount: onSwitchAccount.map { switchAccount in
                                {
                                    model.stop()
                                    switchAccount(model.server, DeviceApprovalLink(server: model.server, code: model.code),
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
            .navigationTitle("Sign in a TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
                    .accessibilityLabel("TV code")
            } header: {
                Text("Code")
            } footer: {
                Text("Enter the code on your TV's sign-in screen.")
            }

            if servers.count > 1 {
                Section {
                    Picker("Server", selection: $selectedServerId) {
                        ForEach(servers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                } footer: {
                    Text("Choose the server named at the top of the TV's screen.")
                }
            } else if loadedServers && servers.isEmpty {
                Section {
                    Text("Sign in to a server on this device first.").foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Continue") {
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

    private func lookUp(on server: ServerEntry) {
        model?.stop()
        let next = TVApprovalModel(server: server, code: code.isEmpty ? initialCode : code)
        model = next
        Task { await next.lookUp() }
    }
}

/// Handles `silo://device?server=&url=&code=` from the web approval page:
/// finds the saved server with that verified identity, or offers to add it
/// from the link's address, then shows the approval card.
struct DeviceLinkApprovalView: View {
    let link: DeviceApprovalLink
    /// Add the server (prefilled) and come back to the link after signing in.
    var onAddServer: (String) -> Void
    /// Sign in to a saved server this device is signed out of, and come back
    /// to the link after signing in.
    var onSignIn: (ServerEntry, DeviceApprovalLink) -> Void
    /// "Not you?" on the card (see `SignInTVView.onSwitchAccount`).
    var onSwitchAccount: (ServerEntry, DeviceApprovalLink, Bool) -> Void
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
                    ProgressView("Finding the TV's server…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
                }
            case .saved(let server):
                SignInTVView(initialCode: link.code, initialServerId: server.id, onSwitchAccount: onSwitchAccount,
                             onClose: onClose)
            case .signedOut(let server):
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Sign in to \(server.displayName)").font(.siloTitle)
                        Text("The TV's code belongs to \(server.displayName), and this device isn't signed in to it. Sign in, then approve the TV.")
                            .font(.siloBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            onSignIn(server, DeviceApprovalLink(server: server, code: link.code))
                        } label: {
                            Text("Sign in").font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.siloOnSurface)
                        .foregroundStyle(Color.siloBackground)
                        Spacer()
                    }
                    .padding(20)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
                }
            case .addServer(let url):
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Add this server?").font(.siloTitle)
                        Text("The TV's code belongs to \(TVSignInPresentation.host(of: url)), which isn't on this device yet. Add it and sign in, then approve the TV.")
                            .font(.siloBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            onAddServer(url)
                        } label: {
                            Text("Add server").font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.siloOnSurface)
                        .foregroundStyle(Color.siloBackground)
                        Spacer()
                    }
                    .padding(20)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
                }
            case .failed(let message):
                NavigationStack {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.yellow)
                        Text(message).font(.siloBody).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
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
            return .saved(server)
        case .savedSignedOut(let server, let learnedIdentity):
            if let learnedIdentity {
                ServerRegistry.shared.updateVerifiedServerId(for: server.id, verifiedServerId: learnedIdentity)
            }
            return .signedOut(server)
        case .addServer(let url):
            return .addServer(url: url)
        case .unreachable(let url):
            return .failed("Couldn't reach \(TVSignInPresentation.host(of: url)). Check this device's connection and open the link again.")
        case .mismatch:
            return .failed("That link names a server this device can't confirm. Enter the TV's code in Settings > Sign in a TV instead.")
        }
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
