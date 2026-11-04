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
///
/// Drawn as Roku draws it (`AccountsScreen`, `ServerCard`), at the same
/// sizes, since Roku's pixels and Apple TV's points are both 1920 wide: the
/// first-run column under the Silo wordmark and an 88 pt headline, rail
/// rows 520 wide and 88 tall, and account cards 760 wide and 128 tall, each
/// a warm initial tile, the username over its profile count, and a badge.
struct TVChangeAccountView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.isStartupSplashVisible) private var isStartupSplashVisible
    @State private var model = ChangeAccountModel.shared
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
                .padding(.bottom, Layout.formGap)

            HStack(alignment: .top, spacing: Layout.paneGap) {
                rail
                    .frame(width: Layout.railWidth)
                    .defaultFocus($railFocus, railEntry, priority: .userInitiated)
                    .focusSection()

                pane
                    .frame(width: Layout.cardWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .defaultFocus($paneFocus, paneEntry, priority: .userInitiated)
                    .focusSection()
                    .onExitCommand(perform: returnToRail)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The first-run screens' margins (MarqueeTVScreen).
        .padding(.horizontal, 90)
        .padding(.top, 60)
        .padding(.bottom, 44)
        .ignoresSafeArea()
        .background {
            MarqueeBackdrop()
            MarqueeScrim(style: .leading)
        }
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
        VStack(alignment: .leading, spacing: 0) {
            SiloWordmarkView(width: 150)
                .frame(height: 64)
                .padding(.bottom, 30)
            Text("Change account")
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 22)
            MarqueeTVBody("Choose a server, then the account to use on it.")
        }
    }

    // MARK: - Rail

    private var rail: some View {
        TVOverflowColumn {
            VStack(spacing: Layout.railGap) {
                ForEach(model.servers) { server in
                    serverRow(server)
                }
                addServerRow
                    .padding(.top, Layout.addServerGap - Layout.railGap)
            }
        }
    }

    private var addServerRow: some View {
        Button {
            model.addServer(router: router)
        } label: {
            railRowLabel("Add server") {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .regular))
                    .frame(width: Layout.railMark, height: Layout.railMark)
            }
        }
        .buttonStyle(TVChangeAccountRailRowStyle())
        .focused($railFocus, equals: .addServer)
    }

    private func serverRow(_ server: ChangeAccountServer) -> some View {
        Button {
            enterPane()
        } label: {
            railRowLabel(server.name) {
                MarqueeServerMark(server: server.server, size: Layout.railMark)
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(TVChangeAccountRailRowStyle(isSelected: server.id == selectedServerId))
        .focused($railFocus, equals: .server(server.id))
        .accessibilityAddTraits(server.id == selectedServerId ? .isSelected : [])
    }

    private func railRowLabel(_ title: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: Layout.railTextGap) {
            mark()
            Text(title)
                .font(.system(size: 25, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Accounts pane

    @ViewBuilder
    private var pane: some View {
        if let server = selectedServer {
            TVOverflowColumn {
                VStack(spacing: Layout.cardGap) {
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
            TVAccountCardLabel(
                initial: row.initial,
                title: row.username,
                detail: row.profileCount,
                dimsMark: row.needsSignIn
            ) {
                if model.openingAccountId == row.id {
                    ProgressView()
                } else if let badge = row.badge {
                    TVChangeAccountBadge(badge: badge)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(row.accessibilityHint)
        }
        .buttonStyle(TVAccountCardStyle())
        .focused($paneFocus, equals: .account(row.id))
    }

    private func addAccountCard(_ server: ChangeAccountServer) -> some View {
        Button {
            model.addAccount(on: server, router: router)
        } label: {
            TVAccountCardLabel(
                initial: "+",
                title: AddChoice.account.title,
                detail: server.addAccountDetail
            ) {
                EmptyView()
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(TVAccountCardStyle())
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

    /// Starts on the open account's card on the active server.
    private func seedFocus() {
        select(model.servers.first)
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

/// Roku's `AccountsScreen` and `ServerCard` sizes, in points.
private enum Layout {
    static let formGap: CGFloat = 48
    static let railWidth: CGFloat = 520
    static let railRow: CGFloat = 88
    static let railGap: CGFloat = 8
    static let railMark: CGFloat = 56
    static let railInset: CGFloat = 16
    static let railTextGap: CGFloat = 18
    static let addServerGap: CGFloat = 16
    static let paneGap: CGFloat = 40
    static let cardWidth: CGFloat = 760
    static let cardGap: CGFloat = 16
    static let cardPadding: CGFloat = 24
    static let cardMark: CGFloat = 80
    static let cardTextGap: CGFloat = 22
    static let cardCorner: CGFloat = 30
    static let cardFocusScale: CGFloat = 1.03
}

/// A server on the rail, or Add server: #EDEDED with black ink when
/// focused, a dim fill while its accounts are shown.
private struct TVChangeAccountRailRowStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isSelected: isSelected)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, Layout.railInset)
                .frame(maxWidth: .infinity, minHeight: Layout.railRow, alignment: .leading)
                .foregroundStyle(isFocused ? Color.black : Color.siloOnSurface)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .focusEffectDisabled()
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        }

        private var fill: Color {
            if isFocused { return .siloOnSurface }
            return isSelected ? .siloChromeSelectedFill : .clear
        }
    }
}

/// Roku's `ServerCard` (itself the first-run `MarqueeServerCard`): white 7%
/// under a white 14% outline at rest; focused, #EDEDED, grown 3%.
private struct TVAccountCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
            configuration.label
                .padding(Layout.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isFocused {
                        shape.fill(Color.siloOnSurface)
                    } else {
                        shape.fill(Color.white.opacity(0.07))
                            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                            .siloGlass(in: shape)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? Layout.cardFocusScale : 1))
                .shadow(color: isFocused ? Color.black.opacity(0.45) : .clear, radius: 24, y: 12)
                .focusEffectDisabled()
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        }
    }
}

/// A card's content: the warm initial tile, a bold title over a faint
/// line, and what trails it.
private struct TVAccountCardLabel<Trailing: View>: View {
    let initial: String
    let title: String
    let detail: String?
    var dimsMark = false
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.isFocused) private var isFocused

    private var ink: Color { isFocused ? .black : .siloOnSurface }

    var body: some View {
        HStack(spacing: Layout.cardTextGap) {
            MarqueeServerMark(name: initial, size: Layout.cardMark, serifInitial: false)
                .opacity(dimsMark ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 23))
                        .foregroundStyle(ink.opacity(0.4))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }
}

/// CURRENT or SIGN IN AGAIN beside an account (Roku's `ServerCard` badge):
/// neutral on black 45% under the hairline, or the warning colour with its
/// open-lock glyph. On the focused card its fill turns near-opaque black so
/// the text keeps its contrast.
private struct TVChangeAccountBadge: View {
    let badge: ChangeAccountBadge
    @Environment(\.isFocused) private var isFocused

    private var warning: Bool { badge == .signInAgain }

    var body: some View {
        HStack(spacing: 6) {
            if warning {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 17, weight: .bold))
            }
            Text(badge.title.uppercased())
        }
        .font(.system(size: 18, weight: .semibold))
        .kerning(0.8)
        .foregroundStyle(warning ? Color.siloStatusWarning : Color.siloOnSurface)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(fill).overlay(Capsule().strokeBorder(line, lineWidth: 1)))
        .fixedSize()
    }

    private var fill: Color {
        if isFocused { return .black.opacity(0.85) }
        return warning ? Color.siloStatusWarning.opacity(0.08) : .black.opacity(0.45)
    }

    private var line: Color {
        warning ? Color.siloStatusWarning.opacity(0.35) : Color.white.opacity(0.14)
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
                    // Room for the focused row's growth and shadow.
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
            // The rows line up with the header, their room outside it.
            .padding(.horizontal, -12)
            .padding(.top, -16)

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
