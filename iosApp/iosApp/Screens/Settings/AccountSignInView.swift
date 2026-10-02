#if !os(tvOS)
import SwiftUI

/// Settings → Sign-in: the provider identity linked to this account, and
/// connect / disconnect.
struct AccountSignInView: View {
    @Bindable var model: AccountSignInModel
    @State private var connecting: AccountSignInModel.Connectable?
    @State private var disconnecting: APIv2AccountIdentity?

    var body: some View {
        List {
            if !model.identities.isEmpty {
                Section {
                    ForEach(model.identities) { identity in
                        identityRow(identity)
                    }
                } header: {
                    Text("Connected")
                } footer: {
                    if model.canUnlink == false {
                        Text(AccountSignInModel.onlySignInMethodMessage)
                            .accessibilityIdentifier("accountSignIn.onlySignInMethod")
                    }
                }
            }

            if !model.connectable.isEmpty {
                Section {
                    ForEach(model.connectable) { item in
                        connectRow(item)
                    }
                } header: {
                    Text("Sign-in providers")
                }
            }

            if model.hasLoaded, model.identities.isEmpty, model.connectable.isEmpty, model.errorMessage == nil {
                Section {
                    Text("This server has no sign-in provider to connect.")
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }

            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                        .accessibilityIdentifier("accountSignIn.error")
                }
            } else if let message = model.resultMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.siloOnSurface)
                        .accessibilityIdentifier("accountSignIn.result")
                }
            }
        }
        .siloGroupedListStyle()
        .navigationTitle("Sign-in")
        .siloNavigationTitleDisplayMode(.inline)
        .overlay {
            if model.isLoading && !model.hasLoaded { ProgressView() }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $connecting) { item in
            ConnectProviderSheet(item: item, model: model) { connecting = nil }
        }
        .confirmationDialog(
            disconnectTitle,
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible,
            presenting: disconnecting
        ) { identity in
            Button("Disconnect", role: .destructive) {
                Task { await model.disconnect(identity) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(model.canUnlink == true ? Self.disconnectMessageWhenAllowed : Self.disconnectMessage)
        }
    }

    /// Says up front that the server keeps the account's only way to sign
    /// in: linking turns the local password off unless the account is
    /// break-glass. For servers that do not say which accounts can
    /// disconnect (`can_unlink` absent).
    static let disconnectMessage = "You'll no longer be able to sign in with this provider account. Your Silo account and its profiles stay. If this is your only way to sign in, it stays connected until an administrator sets a password for your account."

    /// The same, once the server says this account can disconnect.
    static let disconnectMessageWhenAllowed = "You'll no longer be able to sign in with this provider account. Your Silo account and its profiles stay."

    private var disconnectTitle: String {
        guard let identity = disconnecting, !identity.providerName.isEmpty else { return "Disconnect sign-in provider?" }
        return "Disconnect \(identity.providerName)?"
    }

    private func identityRow(_ identity: APIv2AccountIdentity) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(identity.providerName.isEmpty ? "Sign-in provider (turned off)" : identity.providerName)
                    .foregroundStyle(Color.siloOnSurface)
                if !identity.accountLabel.isEmpty {
                    Text(identity.accountLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                }
                Text("Connected \(identity.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer(minLength: 8)
            if model.busyID == identity.id {
                ProgressView()
            } else if model.canUnlink != false {
                Button("Disconnect", role: .destructive) { disconnecting = identity }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("accountSignIn.disconnect.\(identity.id)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func connectRow(_ item: AccountSignInModel.Connectable) -> some View {
        Button {
            model.errorMessage = nil
            model.resultMessage = nil
            connecting = item
        } label: {
            HStack(spacing: 12) {
                ProviderIconView(url: SignInOptions.iconURL(for: item.provider, serverURL: AuthService.shared.serverUrl))
                Text("Connect \(item.name)")
                    .foregroundStyle(Color.siloOnSurface)
                Spacer(minLength: 8)
                if model.busyID == item.id { ProgressView() }
            }
        }
        .disabled(model.isBusy)
        .accessibilityIdentifier("accountSignIn.connect.\(item.id)")
    }
}

/// Re-enters the Silo password, then either runs the provider sign-in that
/// links the account (OIDC), sends the directory username and password
/// (LDAP), or links who owns this device on the provider's network
/// (network identity, such as Tailscale).
private struct ConnectProviderSheet: View {
    let item: AccountSignInModel.Connectable
    @Bindable var model: AccountSignInModel
    let dismiss: () -> Void
    @State private var password = ""
    @State private var directoryUsername = ""
    @State private var directoryPassword = ""
    @FocusState private var focused: Field?

    private enum Field: Hashable { case directoryUsername, directoryPassword, password }

    private var isDirectory: Bool { item.method == .directory }
    /// Directory and network links finish in this sheet; only OIDC goes on
    /// to the browser.
    private var linksWithoutBrowser: Bool { item.method != .browser }

    private var canSubmit: Bool {
        !password.isEmpty && (!isDirectory
            || (!directoryUsername.trimmingCharacters(in: .whitespaces).isEmpty && !directoryPassword.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                if isDirectory {
                    Section {
                        TextField("Username", text: $directoryUsername)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .focused($focused, equals: .directoryUsername)
                            .onSubmit { focused = .directoryPassword }
                            .accessibilityIdentifier("accountSignIn.directoryUsername")
                        SecureField("Password", text: $directoryPassword)
                            .textContentType(.password)
                            .focused($focused, equals: .directoryPassword)
                            .onSubmit { focused = .password }
                            .accessibilityIdentifier("accountSignIn.directoryPassword")
                    } header: {
                        Text("\(item.name) account")
                    }
                }
                Section {
                    SecureField("Silo password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .onSubmit(connect)
                        .accessibilityIdentifier("accountSignIn.password")
                } header: {
                    if isDirectory { Text("Confirm it's you") }
                } footer: {
                    Text(footer)
                }
                if let message = model.errorMessage {
                    Section {
                        Text(message).foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle("Connect \(item.name)")
            .siloNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss).disabled(model.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Button(linksWithoutBrowser ? "Connect" : "Continue", action: connect)
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("accountSignIn.continue")
                    }
                }
            }
            .onAppear { focused = isDirectory ? .directoryUsername : .password }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: isDirectory ? 360 : 260)
        #endif
    }

    private var footer: String {
        if isDirectory {
            return "Enter your Silo password to confirm. After connecting, you sign in with your \(item.name) username and password instead."
        }
        if item.method == .network {
            let who = item.provider.networkIdentity?.name.map { "\($0), " } ?? ""
            return "Enter your Silo password to confirm. This connects \(who)the \(item.name) account this device belongs to. After connecting, you sign in with \(item.name) instead of your password."
        }
        return "Confirm your Silo password, then sign in with \(item.name). After connecting, you sign in with \(item.name) instead of your password."
    }

    private func connect() {
        guard canSubmit, !model.isBusy else { return }
        let entered = password
        let directory = isDirectory
            ? AccountSignInModel.DirectoryCredentials(username: directoryUsername, password: directoryPassword)
            : nil
        Task {
            if await model.connect(item.provider, password: entered, directory: directory) {
                dismiss()
            }
        }
    }
}
#endif
