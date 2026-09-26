#if os(iOS) || os(tvOS)
import SwiftUI

/// The Watch Party route. Shows the create/join entry when nobody is engaged
/// and the room lobby while a party is active. The film is the room: its
/// artwork fills the screen and the lobby's members sit over it as seats.
struct WatchPartyHubView: View {
    var session: WatchPartySession = .shared
    @State private var openedDebugInvitation = false
    @State private var isCheckingSupport = false
    @State private var roomSheet: WatchPartyRoomSheet?
    @State private var confirmsEnd = false

    var body: some View {
        Group {
            if session.isEngaged {
                WatchPartyLobbyView(session: session, sheet: $roomSheet, confirmsEnd: $confirmsEnd)
            } else if let preview = session.selectionPreview, session.isBusy {
                // Starting from a title: hold on its artwork, which the lobby
                // keeps, rather than flashing the create-or-join page.
                ZStack {
                    WatchPartyBackdrop(url: preview.backdropUrl ?? preview.posterUrl,
                                       thumbhash: preview.backdropUrl != nil ? preview.backdropThumbhash : preview.posterThumbhash,
                                       isPoster: preview.backdropUrl == nil)
                    #if os(tvOS)
                    // Nothing else here can hold focus while the party starts;
                    // without an owner Menu cannot leave a slow request.
                    ProgressView().tint(Color.siloSecondaryText)
                        .tvPageFocusOwner(focusRequest: 0, isTopMenuFocused: false,
                                          accessibilityLabel: "Starting your party", onMoveUp: nil)
                    #else
                    ProgressView().tint(Color.siloSecondaryText)
                        .accessibilityLabel("Starting your party")
                    #endif
                }
            } else {
                WatchPartyEntryView(session: session, isCheckingSupport: isCheckingSupport,
                    onCheckSupport: { Task { await checkSupport() } })
            }
        }
        .modifier(WatchPartyRoomSheets(session: session, sheet: $roomSheet, confirmsEnd: $confirmsEnd))
        #if os(iOS)
        .navigationTitle("Watch Party")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .onChange(of: session.isEngaged) { _, engaged in
            if !engaged, session.connection != .ended { Task { await checkSupport() } }
        }
        .task {
            if !session.isEngaged, session.connection != .ended || session.capabilities == nil { await checkSupport() }
            #if DEBUG
            guard !openedDebugInvitation else { return }
            openedDebugInvitation = true
            if let index = CommandLine.arguments.firstIndex(of: "-debugWatchPartyCode"),
               index + 1 < CommandLine.arguments.count {
                await session.join(code: CommandLine.arguments[index + 1])
            }
            #endif
        }
    }

    private func checkSupport() async {
        guard !isCheckingSupport else { return }
        isCheckingSupport = true
        await session.refreshCapabilities()
        isCheckingSupport = false
    }
}

/// Opened from Back inside party playback. The player stays mounted below.
struct WatchPartyRoomPanel: View {
    let session: WatchPartySession
    /// The player below reached the end of the title.
    var playbackEnded = false
    @Environment(\.dismiss) private var dismiss
    @State private var roomSheet: WatchPartyRoomSheet?
    @State private var confirmsEnd = false

    var body: some View {
        NavigationStack {
            Group {
                if session.isEngaged {
                    WatchPartyLobbyView(session: session, sheet: $roomSheet, confirmsEnd: $confirmsEnd,
                        onReturnToPlayback: { dismiss() }, playbackEnded: playbackEnded)
                }
            }
            .modifier(WatchPartyRoomSheets(session: session, sheet: $roomSheet, confirmsEnd: $confirmsEnd))
            #if os(iOS)
            .navigationTitle("Watch Party")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .onChange(of: session.isEngaged) { _, engaged in
                if !engaged { dismiss() }
            }
        }
    }
}

enum WatchPartyRoomSheet: String, Identifiable {
    case select, suggest, invite
    #if os(tvOS)
    case end
    #endif
    var id: String { rawValue }
}

/// Attach presentation once to the containing view; a modifier on the
/// room's section Group creates one presenter for every generated row.
private struct WatchPartyRoomSheets: ViewModifier {
    let session: WatchPartySession
    @Binding var sheet: WatchPartyRoomSheet?
    @Binding var confirmsEnd: Bool
    @Environment(AppRouter.self) private var router

    /// tvOS sheets are fixed-size cards that clip the invitation and cramp the
    /// picker grid, so everything but the End confirmation gets a full-screen
    /// cover there.
    private var cardSheet: Binding<WatchPartyRoomSheet?> {
        #if os(tvOS)
        Binding(get: { sheet == .end ? sheet : nil }, set: { sheet = $0 })
        #else
        $sheet
        #endif
    }

    #if os(tvOS)
    private var coverSheet: Binding<WatchPartyRoomSheet?> {
        Binding(get: { sheet == .end ? nil : sheet }, set: { sheet = $0 })
    }
    #endif

    func body(content: Content) -> some View {
        content
            .sheet(item: cardSheet, onDismiss: { router.watchPartySheetDidDismiss() }) { destination in
                NavigationStack {
                    switch destination {
                    case .select: WatchPartyMediaPicker(session: session, purpose: .select)
                    case .suggest: WatchPartyMediaPicker(session: session, purpose: .suggest)
                    case .invite: WatchPartyInviteView(session: session)
                    #if os(tvOS)
                    case .end: WatchPartyEndConfirmation(session: session)
                    #endif
                    }
                }
                // Choosing a title here must never start solo playback.
                .environment(\.allowsDirectPlayback, false)
            }
            #if os(tvOS)
            .fullScreenCover(item: coverSheet, onDismiss: { router.watchPartySheetDidDismiss() }) { destination in
                NavigationStack {
                    switch destination {
                    case .select: WatchPartyMediaPicker(session: session, purpose: .select)
                    case .suggest: WatchPartyMediaPicker(session: session, purpose: .suggest)
                    case .invite: WatchPartyInviteView(session: session)
                    case .end: WatchPartyEndConfirmation(session: session)
                    }
                }
                // Same hosting as the tab shell: the stack sits edge-to-edge so
                // Skyline rows inside it see no horizontal safe area. Applying
                // this inside the stack instead leaves each row's scroll view
                // with an automatic inset that shows the moment focus leaves it.
                .ignoresSafeArea(edges: [.top, .horizontal])
                .environment(\.allowsDirectPlayback, false)
            }
            #endif
            .onChange(of: session.playbackContext) { _, context in
                if context != nil, sheet != nil { sheet = nil }
            }
            .onChange(of: session.isEngaged) { _, engaged in
                if !engaged {
                    sheet = nil
                    confirmsEnd = false
                }
            }
            #if os(iOS)
            .confirmationDialog("End this party for everyone?", isPresented: $confirmsEnd, titleVisibility: .visible) {
                Button("End Party", role: .destructive) { Task { await session.endParty() } }
            }
            #endif
    }
}

#if os(tvOS)
private struct WatchPartyEndConfirmation: View {
    let session: WatchPartySession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 32) {
            Text("End this party for everyone?").font(.title2)
            HStack(spacing: 24) {
                Button { dismiss() } label: { Text("Cancel") }
                    .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                Button(role: .destructive) {
                    dismiss()
                    Task { await session.endParty() }
                } label: { Text("End Party") }
                    .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
            }
        }
        .padding(64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { dismiss() }
    }
}
#endif

// MARK: - Entry (not engaged)

private struct WatchPartyEntryView: View {
    let session: WatchPartySession
    let isCheckingSupport: Bool
    let onCheckSupport: () -> Void
    @State private var invitation = ""
    @State private var selectionMode: WatchPartySelectionMode = .hostPick
    #if os(tvOS)
    @FocusState private var focused: EntryFocus?
    private enum EntryFocus: Hashable { case create, vote, rejoin, code, join, retry }
    #endif

    private var canEnter: Bool {
        session.capabilities?.supportsSocket == true
            && session.capabilities?.connectionReplaced == true && session.supportsPlayback
    }

    var body: some View {
        ZStack {
            WatchPartyBackdrop(url: nil)
            #if os(tvOS)
            tvLayout
            #else
            phoneLayout
            #endif
        }
    }

    private var headline: some View {
        VStack(alignment: leadingAlignment, spacing: WatchPartyMetrics.body * 0.6) {
            WatchPartyEyebrow(text: "Watch Party")
            Text("Watch something\ntogether")
                .font(.system(size: WatchPartyMetrics.heroTitle, weight: .bold))
                .tracking(-WatchPartyMetrics.heroTitle * 0.02)
                .lineSpacing(-WatchPartyMetrics.heroTitle * 0.05)
                .foregroundStyle(Color.siloOnSurface)
            Text("Pick a title, share the code, and everyone's playback stays in step.")
                .font(.system(size: WatchPartyMetrics.body))
                .foregroundStyle(Color.siloSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(textAlignment)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = session.errorMessage {
            WatchPartyBanner(message: message, tone: .warning)
        } else if !canEnter {
            WatchPartyBanner(message: isCheckingSupport
                ? "Checking Watch Party support…"
                : "Watch Party is not available for this profile on this server.")
        }
    }

    @ViewBuilder
    private var recentRow: some View {
        if let recent = session.recentRoom {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await session.rejoinRecent() }
                } label: {
                    Label(session.wasReplaced ? "Continue here" : "Rejoin \(recent.selectedTitle ?? "recent party")",
                          systemImage: "arrow.clockwise")
                        .lineLimit(1)
                }
                .buttonStyle(WatchPartyButtonStyle(kind: .outlined))
                .disabled(session.locksControls || !canEnter)
                #if os(tvOS)
                .focused($focused, equals: .rejoin)
                #endif
                if session.wasReplaced {
                    Text("Rejoining here disconnects this profile's other device from the party.")
                        .font(.system(size: WatchPartyMetrics.caption))
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
        }
    }

    private var createButtons: some View {
        Group {
            Button {
                Task { await session.create(mode: .hostPick) }
            } label: {
                Label("Start a party", systemImage: "plus")
            }
            .buttonStyle(WatchPartyButtonStyle(kind: .primary))
            .accessibilityIdentifier("watchParty.create")
            #if os(tvOS)
            .focused($focused, equals: .create)
            #endif
            Button {
                Task { await session.create(mode: .vote) }
            } label: {
                Text("Start a party and let everyone vote")
            }
            .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
            #if os(tvOS)
            .focused($focused, equals: .vote)
            #endif
        }
        .disabled(session.locksControls || !canEnter)
    }

    private var joinField: some View {
        HStack(spacing: 10) {
            TextField("Party code or invite link", text: $invitation)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.siloChromeRestingFill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.siloChromeRestingBorder, lineWidth: 1))
                #endif
                .accessibilityIdentifier("watchParty.invitation")
                #if os(tvOS)
                .focused($focused, equals: .code)
                #endif
            #if os(iOS)
            PasteButton(payloadType: String.self) { values in
                if let value = values.first { invitation = value }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(Color.siloChromeRestingFill)
            #endif
        }
    }

    private var joinButton: some View {
        Button {
            Task { await session.join(invitation: invitation) }
        } label: {
            Text("Join party")
        }
        .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
        .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.locksControls || !canEnter)
        .accessibilityIdentifier("watchParty.join")
        #if os(tvOS)
        .focused($focused, equals: .join)
        #endif
    }

    @ViewBuilder
    private var retryButton: some View {
        if !canEnter {
            Button(action: onCheckSupport) { Text("Check again") }
                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                .disabled(isCheckingSupport)
                #if os(tvOS)
                .focused($focused, equals: .retry)
                #endif
        }
    }

    #if os(tvOS)
    private var leadingAlignment: HorizontalAlignment { .leading }
    private var textAlignment: TextAlignment { .leading }

    private var tvLayout: some View {
        HStack(alignment: .top, spacing: 120) {
            VStack(alignment: .leading, spacing: 40) {
                headline
                statusBanner
            }
            .frame(width: 760, alignment: .topLeading)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    WatchPartyEyebrow(text: "Host")
                    createButtons
                    recentRow
                }
                .focusSection()
                VStack(alignment: .leading, spacing: 16) {
                    WatchPartyEyebrow(text: "Join")
                    joinField
                    joinButton
                    retryButton
                }
                .focusSection()
            }
            .frame(width: 640, alignment: .topLeading)
        }
        .padding(.horizontal, WatchPartyMetrics.pageInset)
        .padding(.top, 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focused, session.recentRoom != nil ? .rejoin : .create, priority: .userInitiated)
    }
    #else
    private var leadingAlignment: HorizontalAlignment { .leading }
    private var textAlignment: TextAlignment { .leading }

    private var phoneLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headline
                    .padding(.top, 24)
                statusBanner
                VStack(spacing: 10) {
                    createButtons
                    recentRow
                }
                VStack(alignment: .leading, spacing: 10) {
                    WatchPartyEyebrow(text: "Have a code?")
                    joinField
                    joinButton
                    retryButton
                }
            }
            .padding(.horizontal, WatchPartyMetrics.pageInset)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }
    #endif
}

// MARK: - Lobby (engaged)

struct WatchPartyLobbyView: View {
    let session: WatchPartySession
    @Binding var sheet: WatchPartyRoomSheet?
    @Binding var confirmsEnd: Bool
    var onReturnToPlayback: (() -> Void)? = nil
    var playbackEnded = false
    @Environment(AppRouter.self) private var router
    #if os(tvOS)
    @FocusState private var focused: LobbyFocus?
    private enum LobbyFocus: Hashable { case code, primary, secondary, returnToLobby, more, suggest }
    @State private var showsHostControls = false
    #endif

    var body: some View {
        if let room = displayRoom {
            ZStack {
                WatchPartyBackdrop(
                    url: displayedItem?.backdropUrl ?? displayedItem?.posterUrl ?? leadingSuggestionPoster,
                    thumbhash: displayedItem?.backdropUrl != nil ? displayedItem?.backdropThumbhash : displayedItem?.posterThumbhash,
                    isPoster: displayedItem?.backdropUrl == nil)
                #if os(tvOS)
                // The options overlay is the only focus owner while it is up;
                // closing it returns focus to the Options button that opened it.
                tvLobby(room)
                    .disabled(showsHostControls)
                if showsHostControls {
                    WatchPartyHostControlsOverlay(session: session, room: room, onEnd: { openSheet(.end) },
                        dismiss: { showsHostControls = false; focused = .more })
                        .transition(.opacity)
                        .zIndex(1)
                }
                #else
                phoneLobby(room)
                #endif
            }
            .animation(.easeOut(duration: SiloTheme.normalDuration), value: room.selectedContentId)
        }
    }

    /// The room as laid out. A host pick still in flight counts as chosen, so
    /// a party started from a title doesn't pass through the empty lobby.
    private var displayRoom: WatchPartyRoom? {
        guard var room = session.room else { return nil }
        if room.selectedContentId?.isEmpty ?? true, room.selectionMode == .hostPick,
           let preview = session.selectionPreview {
            room.selectedContentId = preview.contentId
        }
        return room
    }

    /// The loaded title, or the caller's preview of it until the catalog read lands.
    private var displayedItem: WatchPartySelectedItem? {
        if let item = session.selectedItem { return item }
        guard let preview = session.selectionPreview, preview.contentId == displayRoom?.selectedContentId else { return nil }
        return preview
    }

    private var leadingSuggestionPoster: String? {
        guard session.room?.selectionMode == .vote else { return nil }
        let poster = (session.voteWinner ?? session.votes.rows.first)?.posterUrl
        return poster?.isEmpty == false ? poster : nil
    }

    private func openSheet(_ destination: WatchPartyRoomSheet) {
        router.watchPartySheetWillPresent()
        sheet = destination
    }

    private var primaryAction: WatchPartyPrimaryAction {
        guard let room = displayRoom else { return .none }
        // A pending pick lays out as Start; the button stays disabled until the room confirms it.
        let pendingPick = session.room?.selectedContentId != room.selectedContentId
        return WatchPartyLobbyPolicy.primaryAction(room: room, capabilities: session.capabilities,
            canStart: session.canStartPlayback || pendingPick, winnerTitle: session.voteWinner?.title,
            selectionUnavailable: session.selectedItemUnavailable, playbackEnded: playbackEnded)
    }

    private var isConnected: Bool { session.connection == .connected }

    // MARK: Shared pieces

    private func connectionDot(_ room: WatchPartyRoom) -> some View {
        let hostAway = !room.hostConnected && room.selfRole != .host
        let (color, text): (Color, String) = {
            switch session.connection {
            case .connected where hostAway: return (.requestAmber, "Host away")
            case .connected:
                let here = room.members.filter(\.connected).count
                return (.requestEmerald, here <= 1 ? "Open" : "\(here) here")
            case .connecting: return (.siloSecondaryText, "Connecting")
            case .reconnecting: return (.requestAmber, "Reconnecting")
            case .ended, .failed, .idle: return (.requestRose, "Disconnected")
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: WatchPartyMetrics.caption * 0.55, height: WatchPartyMetrics.caption * 0.55)
            Text(text).font(.system(size: WatchPartyMetrics.caption)).foregroundStyle(Color.siloSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusBanner(_ room: WatchPartyRoom) -> some View {
        if let message = session.errorMessage {
            WatchPartyBanner(message: message, tone: .warning)
        } else if session.selectedItemUnavailable {
            WatchPartyBanner(message: room.selfCanManageRoom
                ? "This title isn't available to your profile. Choose something else so everyone can watch."
                : "This title isn't available to your profile. \(hostName(room)) will need to pick something else.", tone: .warning)
        } else if !room.hostConnected && room.selfRole != .host {
            WatchPartyBanner(message: "\(hostName(room)) lost connection. The party holds for two minutes while they come back.", tone: .warning)
        } else if session.connection == .reconnecting {
            WatchPartyBanner(message: "Reconnecting to the party…")
        }
    }

    private func hostName(_ room: WatchPartyRoom) -> String {
        room.members.first(where: \.isHost)?.displayName ?? "The host"
    }

    /// Eyebrow + title + facts. In vote mode before a winner, the question is the title.
    private func heroText(_ room: WatchPartyRoom, titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: titleSize * 0.28) {
            if room.selectionMode == .vote && room.phase == .lobby {
                WatchPartyEyebrow(text: "Voting · \(session.votes.rows.count) \(session.votes.rows.count == 1 ? "title" : "titles")")
                Text("What are we watching?")
                    .font(.system(size: titleSize, weight: .bold))
                    .tracking(-titleSize * 0.02)
                    .foregroundStyle(Color.siloOnSurface)
                Text(room.selfCanManageRoom ? "Everyone votes. You start the leader." : "Tap a title to vote. \(hostName(room)) starts the winner.")
                    .font(.system(size: WatchPartyMetrics.body))
                    .foregroundStyle(Color.siloSecondaryText)
            } else if let item = displayedItem {
                WatchPartyEyebrow(text: room.phase == .playing ? "Now watching · together" : "Up next · together")
                Text(item.title)
                    .font(.system(size: titleSize, weight: .bold))
                    .tracking(-titleSize * 0.02)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                factsLine(item)
                Text(room.selfRole == .host ? "You chose this" : "\(hostName(room)) chose this")
                    .font(.system(size: WatchPartyMetrics.caption))
                    .foregroundStyle(Color.siloSecondaryText.opacity(0.7))
            } else if room.selectedContentId != nil {
                WatchPartyEyebrow(text: room.phase == .playing ? "Now watching · together" : "Up next · together")
                Text(session.selectedItemUnavailable ? "A title you can't see" : "Loading title…")
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(Color.siloSecondaryText)
                Text(room.selfRole == .host ? "You chose this" : "\(hostName(room)) chose this")
                    .font(.system(size: WatchPartyMetrics.caption))
                    .foregroundStyle(Color.siloSecondaryText.opacity(0.7))
            } else {
                WatchPartyEyebrow(text: "Your party is open")
                Text(room.selfCanManageRoom ? "Pick something\nto watch" : "Waiting for\n\(hostName(room))")
                    .font(.system(size: titleSize, weight: .bold))
                    .tracking(-titleSize * 0.02)
                    .foregroundStyle(Color.siloOnSurface)
                Text(room.selfCanManageRoom
                     ? "Friends can join now with the code. They'll see your pick the moment you choose."
                     : "\(hostName(room)) is choosing what to watch. You'll see it here the moment they do.")
                    .font(.system(size: WatchPartyMetrics.body))
                    .foregroundStyle(Color.siloSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func factsLine(_ item: WatchPartySelectedItem) -> some View {
        HStack(spacing: 8) {
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
            }
            ForEach(Array(item.factsLine.enumerated()), id: \.offset) { index, fact in
                if index > 0 || item.subtitle?.isEmpty == false { Text("·").foregroundStyle(Color.siloSecondaryText.opacity(0.5)) }
                Text(fact)
            }
            ForEach(item.qualityChips, id: \.self) { chip in
                Text(chip)
                    .font(.system(size: WatchPartyMetrics.caption * 0.85, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.siloSecondaryText.opacity(0.5), lineWidth: 1))
            }
        }
        .font(.system(size: WatchPartyMetrics.body - 1))
        .foregroundStyle(Color.siloSecondaryText)
        .lineLimit(1)
    }

    @ViewBuilder
    private func primaryButton(_ room: WatchPartyRoom) -> some View {
        switch primaryAction {
        case .chooseTitle:
            Button { openSheet(.select) } label: { Text(room.selectedContentId == nil ? "Choose a title" : "Change title") }
                .buttonStyle(WatchPartyButtonStyle(kind: .primary))
                .disabled(session.locksControls)
                .accessibilityIdentifier("watchParty.choose")
        case .start(let title):
            Button {
                Task { await session.startPlayback() }
            } label: {
                Label(title.map { "Start \($0)" } ?? "Start for everyone", systemImage: "play.fill")
                    .lineLimit(1)
            }
            .buttonStyle(WatchPartyButtonStyle(kind: .primary))
            .disabled(!session.canStartPlayback || session.locksControls || !isConnected)
            .accessibilityIdentifier("watchParty.start")
        case .waitingForVotes:
            Button { openSheet(.suggest) } label: { Label("Suggest a title", systemImage: "plus") }
                .buttonStyle(WatchPartyButtonStyle(kind: .primary))
                .disabled(session.locksControls)
                .accessibilityIdentifier("watchParty.suggest")
        case .ready(let isReady):
            Button {
                session.setLobbyReady(!isReady)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isReady ? "checkmark" : "checkmark.circle")
                    Text(isReady ? "You're ready" : "I'm ready")
                    if isReady {
                        Text("tap to undo").font(.system(size: WatchPartyMetrics.caption)).opacity(0.6)
                    }
                }
            }
            .buttonStyle(WatchPartyButtonStyle(kind: isReady ? .outlined : .primary))
            .disabled(!isConnected)
            .accessibilityIdentifier("watchParty.ready")
        case .returnToPlayback:
            Button {
                if let onReturnToPlayback { onReturnToPlayback() }
                else if let context = session.playbackContext { router.presentWatchParty(context) }
            } label: {
                Label("Return to playback", systemImage: "play.fill")
            }
            .buttonStyle(WatchPartyButtonStyle(kind: .primary))
        case .returnToLobby:
            returnToLobbyButton(kind: .primary)
        case .none:
            EmptyView()
        }
    }

    /// Shown beside the primary action while it is not itself this button.
    @ViewBuilder
    private func stopPlaybackButton(_ room: WatchPartyRoom) -> some View {
        if room.phase == .playing, room.selfCanManageRoom, session.capabilities?.stopPlayback == true,
           primaryAction != .returnToLobby {
            returnToLobbyButton(kind: .secondary)
        }
    }

    private func returnToLobbyButton(kind: WatchPartyButtonKind) -> some View {
        Button { Task { await session.stopPlayback() } } label: {
            Label("Return everyone to lobby", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(WatchPartyButtonStyle(kind: kind))
        .disabled(session.locksControls)
        .accessibilityIdentifier("watchParty.returnToLobby")
    }

    @ViewBuilder
    private func secondaryButton(_ room: WatchPartyRoom) -> some View {
        if room.phase == .lobby, room.selfCanManageRoom, room.selectionMode == .hostPick, room.selectedContentId != nil,
           case .start = primaryAction {
            Button { openSheet(.select) } label: { Text("Change title") }
                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                .disabled(session.locksControls)
                .accessibilityIdentifier("watchParty.choose")
        } else if room.phase == .lobby, room.selectionMode == .vote, case .start = primaryAction {
            Button { openSheet(.suggest) } label: { Label("Suggest", systemImage: "plus") }
                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                .disabled(session.locksControls)
                .accessibilityIdentifier("watchParty.suggest")
        } else if room.phase == .lobby, room.selectionMode == .vote, !room.selfCanManageRoom {
            Button { openSheet(.suggest) } label: { Label("Suggest a title", systemImage: "plus") }
                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                .disabled(session.locksControls)
                .accessibilityIdentifier("watchParty.suggest")
        } else if room.phase == .playing, room.selfCanManageRoom, room.selectionMode == .hostPick {
            // A new selection starts for everyone at once.
            Button { openSheet(.select) } label: { Text("Choose something else") }
                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                .disabled(session.locksControls)
                .accessibilityIdentifier("watchParty.choose")
        }
    }

    @ViewBuilder
    private func hint(_ room: WatchPartyRoom) -> some View {
        let text: String? = {
            guard room.phase == .lobby else { return nil }
            if room.selfCanManageRoom {
                let waiting = WatchPartyLobbyPolicy.waitingNames(members: room.members)
                if room.selectionMode == .vote, session.voteWinner == nil {
                    return session.votes.rows.isEmpty ? "Suggest a title to get the vote going." : "Nobody has voted yet."
                }
                if room.selectedContentId == nil, room.selectionMode == .hostPick { return nil }
                if waiting.isEmpty { return room.members.filter(\.connected).count > 1 ? "Everyone's ready." : nil }
                return "\(waiting.prefix(2).joined(separator: " and "))\(waiting.count > 2 ? " and others" : "") \(waiting.count == 1 ? "hasn't" : "haven't") marked ready. You can still start."
            }
            if room.selectionMode == .vote {
                return "\(hostName(room)) starts \(session.voteWinner?.title ?? "the winner") when voting settles."
            }
            return room.selectedContentId == nil ? nil : "\(hostName(room)) starts the movie when everyone's set."
        }()
        if let text {
            Text(text)
                .font(.system(size: WatchPartyMetrics.caption))
                .foregroundStyle(Color.siloSecondaryText.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Phone

    #if os(iOS)
    private func phoneLobby(_ room: WatchPartyRoom) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Button { openSheet(.invite) } label: { WatchPartyCodePill(code: room.code) }
                            .buttonStyle(.siloFlat)
                        connectionDot(room)
                        Spacer()
                        hostMenu(room)
                    }
                    .padding(.top, 8)
                    phoneHero(room)
                    statusBanner(room)
                    if room.phase == .lobby, room.selectionMode == .vote {
                        WatchPartyBallot(session: session, room: room, onSuggest: { openSheet(.suggest) })
                    } else if room.phase == .lobby, !session.votes.rows.isEmpty {
                        WatchPartyLobbySuggestions(session: session, room: room)
                    }
                    WatchPartySeatsRow(members: room.members, phase: room.phase, onInvite: { openSheet(.invite) })
                }
                .padding(.horizontal, WatchPartyMetrics.pageInset)
                .padding(.bottom, 16)
            }
            VStack(spacing: 10) {
                primaryButton(room)
                stopPlaybackButton(room)
                secondaryButton(room)
                hint(room)
            }
            .padding(.horizontal, WatchPartyMetrics.pageInset)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.9), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        }
    }

    private func phoneHero(_ room: WatchPartyRoom) -> some View {
        // Keyed to the selection, not the loaded item, so the hero keeps its
        // shape while the title loads.
        let showsPoster = !(room.selectedContentId?.isEmpty ?? true) && !(room.selectionMode == .vote && room.phase == .lobby)
        return HStack(alignment: .bottom, spacing: 14) {
            if showsPoster {
                WatchPartyPoster(url: displayedItem?.posterUrl, thumbhash: displayedItem?.posterThumbhash, width: 112)
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 10)
            }
            heroText(room, titleSize: WatchPartyMetrics.heroTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, showsPoster ? 120 : 40)
    }

    private func hostMenu(_ room: WatchPartyRoom) -> some View {
        Menu {
            if room.selfCanManageRoom {
                // Settings are submenus that show their current value, so
                // the top level reads as one aligned list.
                if room.phase == .lobby, session.capabilities?.selectionModeSwitch == true {
                    Picker(selection: Binding(get: { room.selectionMode }, set: { mode in
                        Task { await session.setMode(mode) }
                    })) {
                        Label("Host", systemImage: "person.fill").tag(WatchPartySelectionMode.hostPick)
                        Label("Everyone votes", systemImage: "hand.thumbsup").tag(WatchPartySelectionMode.vote)
                    } label: {
                        Label("Who chooses", systemImage: "hand.point.up.left")
                        Text(room.selectionMode == .vote ? "Everyone votes" : "Host")
                    }
                    .pickerStyle(.menu)
                }
                Picker(selection: Binding(get: { room.guestControlPolicy }, set: { policy in
                    Task { await session.setPolicy(policy) }
                })) {
                    Label("Host only", systemImage: "person.fill").tag(WatchPartyGuestControlPolicy.hostOnly)
                    Label("Host and guests", systemImage: "person.2.fill").tag(WatchPartyGuestControlPolicy.guestPlayPause)
                } label: {
                    Label("Play & pause", systemImage: "playpause")
                    Text(room.guestControlPolicy == .guestPlayPause ? "Host and guests" : "Host only")
                }
                .pickerStyle(.menu)
                if room.phase == .playing, session.capabilities?.stopPlayback == true {
                    Button { Task { await session.stopPlayback() } } label: {
                        Label("Return everyone to lobby", systemImage: "arrow.uturn.backward")
                    }
                }
                Divider()
            }
            Button { session.leaveRoom() } label: {
                Label("Leave party", systemImage: "rectangle.portrait.and.arrow.right")
            }
            if room.selfCanManageRoom {
                Button(role: .destructive) { confirmsEnd = true } label: {
                    Label("End party", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.siloChromeRestingFill))
                .overlay(Circle().stroke(Color.siloChromeRestingBorder, lineWidth: 1))
        }
        .disabled(session.locksControls)
        .accessibilityLabel("Party options")
        .accessibilityIdentifier("watchParty.options")
    }
    #endif

    // MARK: TV

    #if os(tvOS)
    private func tvLobby(_ room: WatchPartyRoom) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 18) {
                    Text("Watch Party")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface)
                    connectionDot(room)
                }
                Spacer()
                HStack(spacing: 22) {
                    Button { openSheet(.invite) } label: { WatchPartyCodePill(code: room.code) }
                        .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                        .focused($focused, equals: .code)
                    TVCircleActionButton(
                        icon: "ellipsis",
                        title: "Options",
                        accessibilityLabel: "Party options",
                        stabilizesFocusMotion: true
                    ) {
                        showsHostControls = true
                    }
                    .focused($focused, equals: .more)
                    .accessibilityIdentifier("watchParty.options")
                }
            }
            .padding(.top, 56)
            .focusSection()

            if room.phase == .lobby, room.selectionMode == .vote {
                VStack(alignment: .leading, spacing: 20) {
                    heroText(room, titleSize: 60)
                        .padding(.top, 36)
                    WatchPartyBallot(session: session, room: room, onSuggest: { openSheet(.suggest) })
                    statusBanner(room)
                }
            } else {
                // Suggestions take the empty side of the screen so the hero
                // keeps its height and the seats stay put.
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 30) {
                        heroText(room, titleSize: WatchPartyMetrics.heroTitle)
                        if let overview = displayedItem?.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 24))
                                .lineSpacing(6)
                                .foregroundStyle(Color.siloSecondaryText)
                                .lineLimit(3)
                        }
                        statusBanner(room)
                    }
                    .frame(width: 760, alignment: .leading)
                    if hostPickSuggestionsShown(room) {
                        Spacer(minLength: 0)
                        WatchPartyLobbySuggestions(session: session, room: room)
                            .frame(maxWidth: 820, alignment: .leading)
                    }
                }
                .padding(.top, 90)
            }

            Spacer(minLength: 24)

            HStack(alignment: .bottom) {
                WatchPartySeatsRow(members: room.members, phase: room.phase, onInvite: { openSheet(.invite) },
                                   seatSize: room.phase == .lobby && room.selectionMode == .vote ? 80 : WatchPartyMetrics.seat)
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 16) {
                    HStack(spacing: 18) {
                        secondaryButton(room).focused($focused, equals: .secondary)
                        stopPlaybackButton(room).focused($focused, equals: .returnToLobby)
                        primaryButton(room).focused($focused, equals: .primary)
                    }
                    .focusSection()
                    hint(room)
                }
            }
            .padding(.bottom, 96)
        }
        .padding(.horizontal, WatchPartyMetrics.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focused, .primary, priority: .userInitiated)
        .onPlayPauseCommand {
            // Same predicate as the Start button, so the remote cannot start
            // playback the focused button refuses.
            if case .start = primaryAction, session.canStartPlayback, !session.locksControls, isConnected {
                Task { await session.startPlayback() }
            }
        }
    }

    private func hostPickSuggestionsShown(_ room: WatchPartyRoom) -> Bool {
        room.phase == .lobby && room.selectionMode == .hostPick && !session.votes.rows.isEmpty
    }
    #endif
}

// MARK: - Suggestions (host-pick mode)

/// Guests' suggestions in a host-pick lobby. The host still decides, so the
/// action stages a suggestion as the pick rather than starting it; everyone
/// else sees what has been put forward and can pull their own. (Promote
/// would start playback, so queueing goes through the selection instead.)
struct WatchPartyLobbySuggestions: View {
    let session: WatchPartySession
    let room: WatchPartyRoom

    private var canQueue: Bool {
        room.selfCanManageRoom && !session.locksControls && session.connection == .connected
    }

    /// Without staged selection the server starts whatever the host selects.
    private var queueLabel: String { session.capabilities?.stagedSelection == true ? "Queue" : "Play" }

    private func isQueued(_ suggestion: WatchPartySuggestion) -> Bool {
        suggestion.contentId == room.selectedContentId
    }

    private func queue(_ suggestion: WatchPartySuggestion) {
        Task { await session.select(WatchPartySelection(contentId: suggestion.contentId)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WatchPartyMetrics.caption * 0.6) {
            HStack(alignment: .firstTextBaseline) {
                WatchPartyEyebrow(text: "Suggestions · \(session.votes.rows.count)")
                Spacer(minLength: 12)
                Text(room.selfCanManageRoom ? "Queue one to put it up next." : "The host decides what plays.")
                    .font(.system(size: WatchPartyMetrics.caption))
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(session.votes.rows) { suggestion in
                        WatchPartySuggestionCard(session: session, suggestion: suggestion,
                                                 canQueue: canQueue && !isQueued(suggestion),
                                                 queueLabel: queueLabel, onQueue: queue)
                    }
                }
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .focusSection()
            #else
            VStack(spacing: 8) {
                ForEach(session.votes.rows) { suggestion in
                    WatchPartySuggestionRow(session: session, suggestion: suggestion, canQueue: canQueue,
                                            isQueued: isQueued(suggestion), queueLabel: queueLabel, onQueue: queue)
                }
            }
            #endif
        }
    }
}

#if os(iOS)
private struct WatchPartySuggestionRow: View {
    let session: WatchPartySession
    let suggestion: WatchPartySuggestion
    let canQueue: Bool
    let isQueued: Bool
    let queueLabel: String
    let onQueue: (WatchPartySuggestion) -> Void

    var body: some View {
        HStack(spacing: 12) {
            WatchPartyPoster(url: suggestion.posterUrl, width: WatchPartyMetrics.ballotPoster.width, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color.siloOnSurface)
                Text([suggestion.subtitle, suggestion.note.isEmpty ? nil : "“\(suggestion.note)”"].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Color.siloSecondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isQueued {
                Text("Up next")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.siloSecondaryText)
                    .padding(.horizontal, 8)
            } else if canQueue {
                Button(queueLabel) { onQueue(suggestion) }
                    .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                    .fixedSize()
                    .accessibilityLabel("\(queueLabel) \(suggestion.title)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.siloChromeRestingFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.siloChromeRestingBorder, lineWidth: 1))
        .contextMenu {
            if session.canRemoveSuggestion(suggestion) {
                Button(role: .destructive) { Task { await session.deleteSuggestion(id: suggestion.id) } } label: {
                    Label("Remove suggestion", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(suggestion.title)
    }
}
#endif

#if os(tvOS)
private struct WatchPartySuggestionCard: View {
    let session: WatchPartySession
    let suggestion: WatchPartySuggestion
    let canQueue: Bool
    let queueLabel: String
    let onQueue: (WatchPartySuggestion) -> Void
    @FocusState private var isFocused: Bool

    private static let poster = CGSize(width: 120, height: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Hosts press to queue. A guest's own suggestion stays focusable
            // so the context menu can remove it; other guests' cards are
            // display-only.
            Button {
                if canQueue { onQueue(suggestion) }
            } label: {
                WatchPartyPoster(url: suggestion.posterUrl, width: Self.poster.width, cornerRadius: 10)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isFocused ? Color.siloOnSurface : Color.siloChromeRestingBorder, lineWidth: isFocused ? 5 : 1)
                        .padding(isFocused ? -8 : 0))
                    .scaleEffect(isFocused ? 1.05 : 1)
                    .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            }
            .buttonStyle(.siloFlat)
            .focused($isFocused)
            .disabled(!canQueue && !session.canRemoveSuggestion(suggestion))
            .accessibilityLabel(canQueue ? "\(queueLabel) \(suggestion.title)" : suggestion.title)
            .contextMenu {
                if session.canRemoveSuggestion(suggestion) {
                    Button(role: .destructive) { Task { await session.deleteSuggestion(id: suggestion.id) } } label: { Text("Remove suggestion") }
                }
            }
            Text(suggestion.title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Color.siloOnSurface)
                .frame(width: Self.poster.width, alignment: .leading)
        }
    }
}
#endif

// MARK: - Ballot (vote mode)

/// Candidates with the vote count as a badge and voter tallies. The leader is
/// outlined. Suggest is the dashed card at the end.
struct WatchPartyBallot: View {
    let session: WatchPartySession
    let room: WatchPartyRoom
    let onSuggest: () -> Void

    private var leaderID: String? { session.voteWinner?.id }

    var body: some View {
        #if os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(session.votes.rows) { suggestion in
                    WatchPartyCandidateCard(session: session, room: room, suggestion: suggestion, isLeader: suggestion.id == leaderID)
                }
                Button(action: onSuggest) { WatchPartySuggestCardLabel() }
                    .buttonStyle(.siloFlat)
                    .accessibilityIdentifier("watchParty.suggest")
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
        #else
        VStack(spacing: 8) {
            ForEach(session.votes.rows) { suggestion in
                WatchPartyCandidateRow(session: session, room: room, suggestion: suggestion, isLeader: suggestion.id == leaderID)
            }
            if session.votes.rows.isEmpty {
                Text("Nothing suggested yet. Anyone can add a title.")
                    .font(.system(size: WatchPartyMetrics.caption))
                    .foregroundStyle(Color.siloSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onSuggest) {
                Label("Suggest a title", systemImage: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(Color.siloSecondaryText.opacity(0.5)))
            }
            .buttonStyle(.siloFlat)
            .disabled(session.locksControls)
            .accessibilityIdentifier("watchParty.suggest")
        }
        #endif
    }
}

private struct WatchPartyVoteBadge: View {
    let count: Int
    let isLeader: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(count)")
                .font(.system(size: WatchPartyMetrics.code, weight: .bold, design: .monospaced))
            Text(count == 1 ? "VOTE" : "VOTES")
                .font(.system(size: WatchPartyMetrics.eyebrow, weight: .semibold))
                .tracking(1)
                .opacity(0.6)
        }
        .foregroundStyle(isLeader ? Color.black : Color.siloOnSurface)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(isLeader ? Color.siloOnSurface : Color.black.opacity(0.7)))
        .overlay(Capsule().stroke(isLeader ? Color.clear : Color.siloChromeRestingBorder, lineWidth: 1))
        .accessibilityLabel("\(count) \(count == 1 ? "vote" : "votes")")
    }
}

#if os(iOS)
private struct WatchPartyCandidateRow: View {
    let session: WatchPartySession
    let room: WatchPartyRoom
    let suggestion: WatchPartySuggestion
    let isLeader: Bool

    private var personalVote: Bool? { session.votes.personal[suggestion.id] }

    var body: some View {
        HStack(spacing: 12) {
            WatchPartyPoster(url: suggestion.posterUrl, width: WatchPartyMetrics.ballotPoster.width, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color.siloOnSurface)
                Text([suggestion.subtitle, suggestion.note.isEmpty ? nil : "“\(suggestion.note)”"].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Color.siloSecondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(spacing: 2) {
                Text("\(suggestion.voteCount)")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.siloOnSurface)
                Text(suggestion.voteCount == 1 ? "VOTE" : "VOTES")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .frame(minWidth: 48)
            Button {
                Task { await session.setVote(suggestionId: suggestion.id, voted: personalVote == false) }
            } label: {
                Image(systemName: personalVote == nil ? "clock" : personalVote == true ? "checkmark" : "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(personalVote == true ? Color.black : Color.siloSecondaryText)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(personalVote == true ? Color.siloOnSurface : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(personalVote == true ? Color.clear : Color.siloOutline, lineWidth: 1))
            }
            .buttonStyle(.siloFlat)
            .disabled(personalVote == nil || session.locksControls || session.connection != .connected)
            .accessibilityLabel(personalVote == nil ? "Loading your vote" : personalVote == true ? "Remove vote for \(suggestion.title)" : "Vote for \(suggestion.title)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isLeader ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isLeader ? Color.siloOnSurface.opacity(0.35) : Color.siloChromeRestingBorder, lineWidth: 1))
        .contextMenu {
            if room.selfCanManageRoom, room.selectionMode == .hostPick || session.capabilities?.voteHostOverride == true {
                Button { Task { await session.promoteSuggestion(id: suggestion.id) } } label: {
                    Label("Start this one", systemImage: "play.fill")
                }
            }
            if session.canRemoveSuggestion(suggestion) {
                Button(role: .destructive) { Task { await session.deleteSuggestion(id: suggestion.id) } } label: {
                    Label("Remove suggestion", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(suggestion.title), \(suggestion.voteCount) \(suggestion.voteCount == 1 ? "vote" : "votes")\(isLeader ? ", leading" : "")")
    }
}
#endif

#if os(tvOS)
private struct WatchPartyCandidateCard: View {
    let session: WatchPartySession
    let room: WatchPartyRoom
    let suggestion: WatchPartySuggestion
    let isLeader: Bool
    @FocusState private var isFocused: Bool

    private var personalVote: Bool? { session.votes.personal[suggestion.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                Task { await session.setVote(suggestionId: suggestion.id, voted: personalVote == false) }
            } label: {
                ZStack(alignment: .topLeading) {
                    WatchPartyPoster(url: suggestion.posterUrl, width: WatchPartyMetrics.ballotPoster.width, cornerRadius: 12)
                    WatchPartyVoteBadge(count: suggestion.voteCount, isLeader: isLeader)
                        .padding(16)
                    if personalVote == true {
                        Circle().fill(Color.siloOnSurface)
                            .overlay { Image(systemName: "checkmark").font(.system(size: 22, weight: .heavy)).foregroundStyle(.black) }
                            .frame(width: 44, height: 44)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.siloOnSurface : (isLeader ? Color.siloOnSurface.opacity(0.35) : Color.siloChromeRestingBorder),
                            lineWidth: isFocused ? 6 : 1)
                    .padding(isFocused ? -10 : 0))
                .scaleEffect(isFocused ? 1.05 : 1)
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            }
            .buttonStyle(.siloFlat)
            .focused($isFocused)
            .disabled(personalVote == nil || session.locksControls || session.connection != .connected)
            .accessibilityLabel(personalVote == nil ? "Loading your vote" : personalVote == true ? "Remove vote for \(suggestion.title)" : "Vote for \(suggestion.title)")
            .contextMenu {
                if room.selfCanManageRoom, session.capabilities?.voteHostOverride == true || room.selectionMode == .hostPick {
                    Button { Task { await session.promoteSuggestion(id: suggestion.id) } } label: { Text("Start this one") }
                }
                if session.canRemoveSuggestion(suggestion) {
                    Button(role: .destructive) { Task { await session.deleteSuggestion(id: suggestion.id) } } label: { Text("Remove suggestion") }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color.siloOnSurface)
                Text(suggestion.note.isEmpty ? (suggestion.subtitle.isEmpty ? " " : suggestion.subtitle) : "“\(suggestion.note)”")
                    .font(.system(size: 20)).foregroundStyle(Color.siloSecondaryText).lineLimit(1)
            }
            .frame(width: WatchPartyMetrics.ballotPoster.width, alignment: .leading)
        }
    }
}

private struct WatchPartySuggestCardLabel: View {
    @Environment(\.isFocused) private var isFocused
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? Color.siloChromeSelectedFill : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: isFocused ? 4 : 2, dash: isFocused ? [] : [10, 8]))
                    .foregroundStyle(isFocused ? Color.siloOnSurface : Color.siloSecondaryText.opacity(0.5)))
                .overlay { Image(systemName: "plus").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(isFocused ? Color.siloOnSurface : Color.siloSecondaryText) }
                .frame(width: WatchPartyMetrics.ballotPoster.width, height: WatchPartyMetrics.ballotPoster.height)
                .scaleEffect(isFocused ? 1.05 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggest a title").font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.siloSecondaryText)
                Text("Anyone can add one").font(.system(size: 20)).foregroundStyle(Color.siloSecondaryText.opacity(0.7))
            }
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        .focusEffectDisabled()
    }
}

/// Host settings live behind the "···" pill so they never share a row with Start.
private struct WatchPartyHostControlsOverlay: View {
    let session: WatchPartySession
    let room: WatchPartyRoom
    let onEnd: () -> Void
    let dismiss: () -> Void
    @FocusState private var focused: Row?
    private enum Row: Hashable { case mode, policy, stop, end, leave, close }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 18) {
                Text("Party options").font(.system(size: 38, weight: .semibold)).foregroundStyle(Color.siloOnSurface)
                if room.selfCanManageRoom {
                    if room.phase == .lobby, session.capabilities?.selectionModeSwitch == true {
                        row("Who chooses", value: room.selectionMode == .vote ? "Everyone votes" : "Host chooses", id: .mode) {
                            Task { await session.setMode(room.selectionMode == .vote ? .hostPick : .vote) }
                        }
                    }
                    row("Playback controls", value: room.guestControlPolicy == .guestPlayPause ? "Guests can play and pause" : "Host only", id: .policy) {
                        Task { await session.setPolicy(room.guestControlPolicy == .guestPlayPause ? .hostOnly : .guestPlayPause) }
                    }
                    if room.phase == .playing, session.capabilities?.stopPlayback == true {
                        row("Return everyone to lobby", value: nil, id: .stop) { Task { await session.stopPlayback() }; dismiss() }
                    }
                    row("End party for everyone", value: nil, id: .end, destructive: true) { dismiss(); onEnd() }
                }
                row("Leave party", value: nil, id: .leave, destructive: true) { dismiss(); session.leaveRoom() }
                row("Close", value: nil, id: .close, action: dismiss)
            }
            .padding(48)
            .frame(width: 900)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.siloSurfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.siloChromeRestingBorder, lineWidth: 1))
            .focusSection()
            .defaultFocus($focused, .close, priority: .userInitiated)
        }
        // Menu must close the overlay, not pop the route beneath it. Exit
        // commands climb the focused responder chain, so the overlay claims
        // focus the moment it appears and handles Menu itself. Rows stay
        // enabled while a change is in flight: disabling the focused row
        // would push focus out of the overlay. The session ignores a second
        // mutation until the first one returns.
        .onExitCommand(perform: dismiss)
        .onAppear { focused = .close }
    }

    private func row(_ title: String, value: String?, id: Row, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 26, weight: .medium))
                Spacer()
                if let value { Text(value).font(.system(size: 24)).opacity(0.7) }
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: destructive))
        .focused($focused, equals: id)
    }
}
#endif
#endif
