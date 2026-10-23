#if os(tvOS)
import SwiftUI

/// A focusable row of Settings › Account and Server.
enum TVAccountsSettingsRow: Hashable {
    /// Sign Out of the account, or Sign In Again once it expired.
    case account(SiloAccountRef)
    case remove(SiloAccountRef)
    case addAccount
}

/// The account rows of Settings › Account and Server: each account with
/// Sign Out (or Sign In Again) and Remove from This Apple TV; then Add
/// Account.
///
/// Focus: native settings rows in one column; the owner seeds and restores
/// focus through `focus` with `TVSettingsDetailFocus.accounts`.
struct TVAccountsSettingsSection: View {
    struct Actions {
        /// Sign Out of an account, from its row.
        var signOut: (SiloAccountRef, TVAccountsSettingsRow) -> Void
        /// Sign In Again to an expired account, from its row.
        var signInAgain: (SiloAccountRef) -> Void
        var remove: (SiloAccountRef, TVAccountsSettingsRow) -> Void
        var addAccount: () -> Void
    }

    static let footer = "Accounts are shared by everyone on this Apple TV. Profiles and watch history stay on the servers."

    let model: AccountsSettingsViewModel
    var phase: TVUserListPhase = .ready
    /// Server addresses by account, for each account's server mark.
    var addresses: [SiloAccountRef: String] = [:]
    let focus: FocusState<TVSettingsDetailFocus?>.Binding
    let actions: Actions
    /// Each server's logo, by address.
    @State private var marks: [String: URL] = [:]

    /// Every focusable row, top to bottom.
    static func rows(in model: AccountsSettingsViewModel) -> [TVAccountsSettingsRow] {
        model.rows.flatMap { row in
            (row.canSignOut || row.needsSignInAgain ? [TVAccountsSettingsRow.account(row.id)] : [])
                + [.remove(row.id)]
        } + [.addAccount]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .loading where model.rows.isEmpty:
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Loading accounts…")
                }
                .font(.system(size: 22))
                .foregroundStyle(Color.siloSecondaryText)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            case .unavailable:
                TVSettingsFooter("Accounts appear here once Silo finishes updating the sign-ins saved on this Apple TV.")
            case .loading, .ready:
                ForEach(model.rows) { row in
                    accountRows(row)
                }
                Button(action: actions.addAccount) {
                    HStack(spacing: 16) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 34)
                        Text(AccountsSettingsViewModel.addAccountTitle)
                            .font(.system(size: 26))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused(focus, equals: .accounts(.addAccount))
                .padding(.top, model.rows.isEmpty ? 0 : 26)
                TVSettingsFooter(Self.footer)
            }
        }
        // Restarted, and the earlier load cancelled, when the servers change.
        .task(id: serverAddresses) {
            marks = ServerBrandingLoader.cachedMarks(for: serverAddresses)
            await ServerBrandingLoader.loadCurrentMarks(for: serverAddresses) { marks[$0] = $1 }
        }
    }

    /// Each account's server, once.
    private var serverAddresses: [String] {
        Array(Set(addresses.values.filter { !$0.isEmpty })).sorted()
    }

    @ViewBuilder
    private func accountRows(_ row: AccountsSettingsViewModel.Row) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            TVSettingsSectionHeader(row.name.uppercased())
            if row.isCurrent {
                TVUserStatusBadge(kind: .current)
                    .padding(.bottom, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)

        accountRow(row)

        Button {
            actions.remove(row.id, .remove(row.id))
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34)
                Text(model.removeTitle)
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
        .focused(focus, equals: .accounts(.remove(row.id)))
        .accessibilityLabel("\(model.removeTitle): \(row.name)")
    }

    /// The account's server and details, with Sign Out, or Sign In Again
    /// once it expired. A pending legacy account has no saved sign-in to act
    /// on yet, so its row is information only.
    @ViewBuilder
    private func accountRow(_ row: AccountsSettingsViewModel.Row) -> some View {
        let address = addresses[row.id] ?? ""
        let title = row.detailLines.last ?? row.name
        let detail = row.detailLines.dropLast().first
        let label = HStack(spacing: 16) {
            MarqueeServerMark(imageURL: marks[address], size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 19))
                        .opacity(0.62)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if row.isCurrent, LocalRouteController.shared.isOnLocalNetwork {
                    LocalRouteStatusLine()
                        .font(.system(size: 19))
                        .opacity(0.62)
                }
            }
            Spacer(minLength: 16)
            if row.needsSignInAgain {
                TVUserStatusBadge(kind: .signInAgain)
            }
            if row.canSignOut || row.needsSignInAgain {
                Text(row.needsSignInAgain ? AccountsSettingsViewModel.signInAgainTitle
                                          : AccountsSettingsViewModel.signOutTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(0.72)
            }
        }

        if row.canSignOut || row.needsSignInAgain {
            Button {
                if row.needsSignInAgain {
                    actions.signInAgain(row.id)
                } else {
                    actions.signOut(row.id, .account(row.id))
                }
            } label: {
                label
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused(focus, equals: .accounts(.account(row.id)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.needsSignInAgain
                ? "\(AccountsSettingsViewModel.signInAgainTitle): \(row.name)"
                : "\(AccountsSettingsViewModel.signOutTitle): \(row.name)")
            .accessibilityValue(row.detailLines.joined(separator: ", "))
        } else {
            // Waiting for the server to confirm its account: only Remove
            // reaches it, so the row is information, not a focus target.
            label
                .padding(.horizontal, 24)
                .padding(.vertical, 17)
                .foregroundStyle(Color.siloOnSurface)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.siloSurfaceElevated.opacity(0.84))
                )
                .accessibilityElement(children: .combine)
        }
    }
}
#endif
