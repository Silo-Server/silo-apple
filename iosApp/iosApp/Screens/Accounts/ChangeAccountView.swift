#if !os(tvOS)
import SwiftUI

/// Change Account on iPhone, iPad and Mac (spec §4.1): an inset grouped
/// list with one section per server, the active server first. A checkmark
/// marks the open account; swiping an account, or holding it, offers Sign
/// Out. Each server ends in Add Account, and Add Server comes last.
struct ChangeAccountView: View {
    @Environment(AppRouter.self) private var router
    @State private var model = ChangeAccountModel.shared
    @State private var directory = AccountDirectory.shared
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            ForEach(model.servers) { server in
                serverSection(server)
            }

            Section {
                Button {
                    model.addServer(router: router)
                } label: {
                    ChangeAccountActionLabel(title: .serversAddServer)
                }
            } footer: {
                Text(.accountsChangeAccountAddServerFooter(AppLanguage.string(AddChoice.server.detail, locale: locale)))
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        // The app's tint, whichever screen opened this one.
        .tint(.siloOnSurface)
        .disabled(model.isBusy)
        .navigationTitle(Text(.accountsChangeAccountNavigationTitle))
        .siloNavigationTitleDisplayMode(.inline)
        .task { model.reload() }
        .onChange(of: directory.accounts) { _, _ in
            model.reload(refreshingDirectory: false)
        }
    }

    private func serverSection(_ server: ChangeAccountServer) -> some View {
        Section {
            ForEach(server.rows) { row in
                Button {
                    model.choose(row, router: router)
                } label: {
                    ChangeAccountRowLabel(row: row, isOpening: model.openingAccountId == row.id)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Not `.destructive`: that removes the row at once, and it
                    // would stay gone after Cancel in the confirmation.
                    Button(.settingsAccountsSignOut) { signOut(row) }
                        .tint(.red)
                }
                .contextMenu {
                    if row.needsSignIn {
                        Button(.settingsAccountsSignInAgain, systemImage: "person.crop.circle.badge.exclamationmark") {
                            model.choose(row, router: router)
                        }
                    }
                    Button(.settingsAccountsSignOut, systemImage: "rectangle.portrait.and.arrow.forward", role: .destructive) {
                        signOut(row)
                    }
                }
            }

            Button {
                model.addAccount(on: server, router: router)
            } label: {
                ChangeAccountActionLabel(title: .accountsChangeAccountAddAccountShort)
            }
        } header: {
            ChangeAccountServerHeader(server: server.server)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    /// Asks first, through the app's shared sign-out confirmation.
    private func signOut(_ row: ChangeAccountRow) {
        Task { await router.confirmSignOut(account: row.id, onServer: row.serverId) }
    }
}

/// A server's mark and name, as the section header above its accounts.
private struct ChangeAccountServerHeader: View {
    let server: ServerEntry
    @ScaledMetric(relativeTo: .footnote) private var markSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            MarqueeServerMark(server: server, size: markSize)
                .accessibilityHidden(true)
            Text(server.displayName)
                .lineLimit(1)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One account: its initial, username and a line under it (its profile
/// count, or that it needs to sign in again), with a checkmark when open.
private struct ChangeAccountRowLabel: View {
    let row: ChangeAccountRow
    let isOpening: Bool
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = ChangeAccountMetrics.leadingWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let identityLayout = ChangeAccountMetrics.leadingLayout(dynamicTypeSize)
        HStack(spacing: ChangeAccountMetrics.spacing) {
            identityLayout {
                Text(row.initial)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.siloOnSurface)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Circle().fill(Color.siloIconTile))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.username)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundColor(row.needsSignIn ? .siloWarning : .siloSecondaryText)
                    }
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            Spacer(minLength: 8)
            if isOpening {
                ProgressView()
            } else if row.isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityHint(Text(row.accessibilityHint))
    }

    private var detail: LocalizedStringResource? {
        row.needsSignIn ? ChangeAccountBadge.signInAgain.title : row.profileCount
    }
}

/// Add Account or Add Server: a plus in the avatar's column, so the
/// title lines up with the usernames above it.
private struct ChangeAccountActionLabel: View {
    let title: LocalizedStringResource
    @ScaledMetric(relativeTo: .body) private var leadingWidth: CGFloat = ChangeAccountMetrics.leadingWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = ChangeAccountMetrics.leadingLayout(dynamicTypeSize)
        layout {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: leadingWidth)
                .accessibilityHidden(true)
            Text(title)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .foregroundStyle(.tint)
    }
}

/// The leading column shared by account rows and the add rows.
private enum ChangeAccountMetrics {
    static let leadingWidth: CGFloat = 32
    static let spacing: CGFloat = 12

    /// The leading column beside the text, or above it at accessibility
    /// sizes, where a row is too narrow for both.
    static func leadingLayout(_ size: DynamicTypeSize) -> AnyLayout {
        size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: spacing))
    }
}
#endif
