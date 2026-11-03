#if !os(tvOS)
import SwiftUI

/// Change Account on iPhone, iPad and Mac (spec §4.1): every saved account
/// under its server's mark and name, the active server first. Each server
/// ends in Add an account (or Sign in, when no account is left on it), and
/// Add a server comes last. A grouped list, so its section headers show
/// which account is on which server and that there is more to scroll.
struct ChangeAccountView: View {
    @Environment(AppRouter.self) private var router
    @State private var model = ChangeAccountModel()
    @State private var directory = AccountDirectory.shared

    var body: some View {
        List {
            ForEach(model.servers) { server in
                serverSection(server)
            }

            Section {
                Button {
                    model.addServer(router: router)
                } label: {
                    ChangeAccountActionLabel(
                        title: AddChoice.server.title,
                        detail: AddChoice.server.detail,
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .disabled(model.isBusy)
        .navigationTitle("Change Account")
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
            }

            Button {
                model.addAccount(on: server, router: router)
            } label: {
                if server.offersSignIn {
                    ChangeAccountActionLabel(title: "Sign in", detail: server.signInDetail,
                                             systemImage: "person.crop.circle.badge.plus")
                } else {
                    ChangeAccountActionLabel(title: AddChoice.account.title, detail: server.addAccountDetail,
                                             systemImage: "plus")
                }
            }
            .buttonStyle(.plain)
        } header: {
            ChangeAccountServerHeader(server: server.server)
        }
        .listRowBackground(Color.siloGroupedCell)
    }
}

/// A server's mark and name above its accounts.
private struct ChangeAccountServerHeader: View {
    let server: ServerEntry

    var body: some View {
        HStack(spacing: 10) {
            MarqueeServerMark(server: server, size: 24)
            Text(server.displayName)
                .font(.siloSubheadline.weight(.semibold))
                .foregroundColor(.siloOnSurface)
                .lineLimit(1)
        }
        .textCase(nil)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One account: its initial, username and profile count, and its badge.
private struct ChangeAccountRowLabel: View {
    let row: ChangeAccountRow
    let isOpening: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(row.initial)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.siloOnSurface)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .opacity(row.needsSignIn ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.username)
                    .font(.siloSubheadline)
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                if let count = row.profileCount {
                    Text(count)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isOpening {
                ProgressView()
                    .controlSize(.small)
            } else if let badge = row.badge {
                MarqueeBadge(
                    text: badge.title,
                    systemImage: badge.systemImage,
                    warning: badge == .signInAgain
                )
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.accessibilityHint)
    }
}

/// Add an account, Sign in, or Add a server: an icon, its title and a line.
private struct ChangeAccountActionLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.siloOnSurface)
                .frame(width: 40, height: 40)
                .background(Circle().strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.siloSubheadline)
                    .foregroundColor(.siloOnSurface)
                Text(detail)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
