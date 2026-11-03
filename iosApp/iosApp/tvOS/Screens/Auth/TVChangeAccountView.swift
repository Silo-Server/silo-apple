#if os(tvOS)
import SwiftUI

/// Change Account on Apple TV (spec §4.1, §4.6), drawn from the shared
/// `ChangeAccountModel`: a rail of the saved servers (mark and name, the
/// active one first, then by last use, with Add server under them) and,
/// beside it, the selected server's accounts as cards, then Add an account
/// on that server, or its Sign in card when no account is left on it.
///
/// Focus: two native focus sections, the rail and the accounts pane.
/// Left and Right cross between them, Up and Down move within each, and
/// moving along the rail selects that server, so the pane follows it. Each
/// section names its entry target with user-initiated `defaultFocus`: Left
/// returns to the selected server, Right enters on the card last focused
/// there (the open account's card for a newly selected server). Focus is
/// written only to seed the screen, to cross on Select on a server, and on
/// Menu from the pane, which returns to the rail as Settings does; Menu on
/// the rail leaves the screen (see docs/tvos-focus.md).
struct TVChangeAccountView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.isStartupSplashVisible) private var isStartupSplashVisible
    @State private var model = ChangeAccountModel()
    @State private var directory = AccountDirectory.shared
    /// The server whose accounts the pane shows.
    @State private var selectedServerId: String?
    /// Where focus enters the pane.
    @State private var paneEntry: PaneItem?
    @FocusState private var railFocus: RailItem?
    @FocusState private var paneFocus: PaneItem?

    private enum RailItem: Hashable {
        case server(String)
        case addServer
    }

    private enum PaneItem: Hashable {
        case account(String)
        /// A server's Add an account card, or its Sign in card.
        case addAccount(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 36)

            HStack(alignment: .top, spacing: 52) {
                rail
                    .frame(width: 520)
                    .defaultFocus($railFocus, railEntry, priority: .userInitiated)
                    .focusSection()

                pane
                    .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
                    .defaultFocus($paneFocus, paneEntry, priority: .userInitiated)
                    .focusSection()
                    .onExitCommand(perform: returnToRail)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 56)
        .safeAreaPadding(.bottom, 44)
        .background(SettingsBackdrop())
        .onAppear(perform: seedFocus)
        .task { model.reload() }
        .onChange(of: directory.accounts) { _, _ in
            model.reload(refreshingDirectory: false)
        }
        .onChange(of: model.servers) { _, servers in
            // The selected server was removed: show the first one.
            guard !servers.contains(where: { $0.id == selectedServerId }) else { return }
            select(servers.first)
        }
        .onChange(of: railFocus) { _, focus in
            guard case .server(let id)? = focus, id != selectedServerId else { return }
            select(model.servers.first { $0.id == id })
        }
        .onChange(of: paneFocus) { _, focus in
            if let focus { paneEntry = focus }
        }
        .onChange(of: isStartupSplashVisible) { _, isVisible in
            // Launched straight into this screen: nothing below the splash
            // could take focus, so place it once the splash lifts.
            guard !isVisible else { return }
            focusEntry()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change Account")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityAddTraits(.isHeader)
            Text("Choose a server, then the account to use on it.")
                .font(.system(size: 22))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVOverflowColumn {
                VStack(spacing: 8) {
                    ForEach(model.servers) { server in
                        serverRow(server)
                    }
                }
            }

            Button {
                model.addServer(router: router)
            } label: {
                HStack(spacing: 18) {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 56, height: 56)
                    Text("Add server")
                        .font(.system(size: 26, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(TVSettingsRailRowStyle())
            .focused($railFocus, equals: .addServer)
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func serverRow(_ server: ChangeAccountServer) -> some View {
        Button {
            enterPane()
        } label: {
            HStack(spacing: 18) {
                MarqueeServerMark(server: server.server, size: 56)
                Text(server.name)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(TVSettingsRailRowStyle(isSelected: server.id == selectedServerId))
        .focused($railFocus, equals: .server(server.id))
        .accessibilityAddTraits(server.id == selectedServerId ? .isSelected : [])
    }

    // MARK: - Accounts pane

    @ViewBuilder
    private var pane: some View {
        if let server = selectedServer {
            TVOverflowColumn {
                VStack(spacing: 16) {
                    ForEach(server.rows) { row in
                        accountCard(row)
                    }
                    addAccountCard(server)
                }
            }
            // A new server starts at the top of its own list.
            .id(server.id)
        }
    }

    private func accountCard(_ row: ChangeAccountRow) -> some View {
        Button {
            model.choose(row, router: router)
        } label: {
            HStack(spacing: 24) {
                Text(row.initial)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.quaternary))
                    .opacity(row.needsSignIn ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.username)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                    if let count = row.profileCount {
                        Text(count)
                            .font(.system(size: 21))
                            .opacity(0.62)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                if model.openingAccountId == row.id {
                    ProgressView()
                } else if let badge = row.badge {
                    TVChangeAccountBadge(badge: badge)
                }
            }
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityHint(row.accessibilityHint)
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .focused($paneFocus, equals: .account(row.id))
    }

    private func addAccountCard(_ server: ChangeAccountServer) -> some View {
        Button {
            model.addAccount(on: server, router: router)
        } label: {
            HStack(spacing: 24) {
                Image(systemName: server.offersSignIn ? "person.crop.circle.badge.plus" : "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .background(
                        Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.offersSignIn ? "Sign in" : AddChoice.account.title)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                    Text(server.offersSignIn ? server.signInDetail : server.addAccountDetail)
                        .font(.system(size: 21))
                        .opacity(0.62)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .focused($paneFocus, equals: .addAccount(server.id))
    }

    // MARK: - Selection and focus

    private var selectedServer: ChangeAccountServer? {
        model.servers.first { $0.id == selectedServerId }
    }

    private var railEntry: RailItem {
        selectedServerId.map(RailItem.server) ?? .addServer
    }

    private func select(_ server: ChangeAccountServer?) {
        selectedServerId = server?.id
        paneEntry = server.map(entryCard)
    }

    /// The open account's card, else the server's first card.
    private func entryCard(for server: ChangeAccountServer) -> PaneItem {
        if let row = server.rows.first(where: \.isCurrent) ?? server.rows.first {
            return .account(row.id)
        }
        return .addAccount(server.id)
    }

    /// Starts on the open account's card on the active server. From Add ›
    /// Add an account, on that server's Add an account card instead.
    private func seedFocus() {
        let requested = router.changeAccountFocusServerId
        router.changeAccountFocusServerId = nil
        let server = model.servers.first(where: { $0.id == requested }) ?? model.servers.first
        select(server)
        if let server, server.id == requested {
            paneEntry = .addAccount(server.id)
        }
        focusEntry()
    }

    /// Places focus on the pane's entry card, or on Add server when no
    /// server is saved. Re-asserted once the screen has mounted.
    private func focusEntry() {
        let entry = paneEntry
        apply(entry)
        Task { @MainActor in
            await Task.yield()
            apply(entry)
        }
    }

    private func apply(_ entry: PaneItem?) {
        if let entry {
            paneFocus = entry
        } else {
            railFocus = .addServer
        }
    }

    /// Select on a server moves to its accounts, like Right.
    private func enterPane() {
        guard let paneEntry else { return }
        paneFocus = paneEntry
    }

    /// Menu in the pane returns to the selected server; Menu on the rail
    /// leaves the screen.
    private func returnToRail() {
        railFocus = railEntry
    }
}

/// "Current" or "Sign in again" beside an account. Drawn in the card's
/// ink, so it stays legible on the white focus platter.
private struct TVChangeAccountBadge: View {
    let badge: ChangeAccountBadge
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.systemImage)
                .font(.system(size: 17, weight: .bold))
            Text(badge.title.uppercased())
        }
        .font(.system(size: 18, weight: .semibold))
        .kerning(0.8)
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1.5))
        .fixedSize()
    }

    private var tint: Color {
        if isFocused { return .siloBackground }
        return badge == .signInAgain ? .siloStatusWarning : .siloOnSurface
    }
}

/// A scrolling column that shows when it has more rows above or below: its
/// edges fade and a chevron under it points the way (spec §4.1).
private struct TVOverflowColumn<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var overflow = Overflow()

    private struct Overflow: Equatable {
        var above = false
        var below = false
    }

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.vertical, showsIndicators: false) {
                content()
                    // Room for the focused row's lift and shadow.
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
            }
            .onScrollGeometryChange(for: Overflow.self) { geometry in
                Overflow(
                    above: geometry.visibleRect.minY > 1,
                    below: geometry.visibleRect.maxY < geometry.contentSize.height - 1
                )
            } action: { _, value in
                overflow = value
            }
            .mask(edgeFade)

            HStack(spacing: 10) {
                Image(systemName: "chevron.up").opacity(overflow.above ? 1 : 0)
                Image(systemName: "chevron.down").opacity(overflow.below ? 1 : 0)
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.siloOnSurface.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: overflow)
    }

    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [overflow.above ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 48)
            Rectangle()
            LinearGradient(colors: [.black, overflow.below ? .clear : .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 48)
        }
    }
}
#endif
