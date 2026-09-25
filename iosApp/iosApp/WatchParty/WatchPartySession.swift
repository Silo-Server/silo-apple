import Foundation
import Observation

@MainActor @Observable
final class WatchPartySession {
    static let shared = WatchPartySession()

    enum Connection: Equatable { case idle, connecting, connected, reconnecting, ended, failed }
    private(set) var connection: Connection = .idle
    private(set) var capabilities: WatchPartyCapabilities?
    private(set) var supportsPlayback = false
    private(set) var supportsFallback = false
    private(set) var state = WatchPartyRoomState()
    private(set) var votes = WatchPartyVotes()
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    private(set) var recentRoom: WatchPartyRecentRoom?
    private(set) var wasReplaced = false
    private(set) var selectedItem: WatchPartySelectedItem?
    /// Caller-supplied details for a host pick. The lobby shows it while the
    /// selection request and catalog read run, so it lays out once.
    private(set) var selectionPreview: WatchPartySelectedItem?
    /// The room's selected title is hidden from this profile (library or
    /// rating restriction). The member cannot ready up or play it.
    private(set) var selectedItemUnavailable = false
    private(set) var picker: WatchPartyPicker?
    private(set) var memberState: WatchPartyMemberState?
    private(set) var isLoadingPicker = false
    private(set) var isLoadingMemberState = false
    private(set) var playbackContext: WatchPartyPlaybackContext?
    var room: WatchPartyRoom? { state.room }
    var isEngaged: Bool { room != nil && !state.terminal }
    var voteWinner: WatchPartySuggestion? { WatchPartyLobbyPolicy.voteWinner(votes.rows) }
    /// Independent of `isBusy` so the lobby's button layout does not change
    /// while an unrelated request runs; `mutate` still refuses a second call.
    var canStartPlayback: Bool {
        guard room?.selfCanManageRoom == true, room?.phase == .lobby else { return false }
        if room?.selectionMode == .vote { return voteWinner != nil }
        return capabilities?.stagedSelection == true && !(room?.selectedContentId?.isEmpty ?? true)
    }
    var inviteURL: URL? {
        guard isEngaged, let path = room?.invitePath, let auth else { return nil }
        return WatchPartyLobbyPolicy.inviteURL(path: path, serverURL: auth.account.serverURL)
    }

    @ObservationIgnored private let api: APIv2Client
    @ObservationIgnored private let tokenStore: TokenStore
    @ObservationIgnored private let recentStore: WatchPartyRecentStore
    @ObservationIgnored private var recentPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var lastPersistedRecent: WatchPartyRecentRoom?
    @ObservationIgnored private var lastRecentPersistence: Date = .distantPast
    @ObservationIgnored private var auth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var recentAuth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var roomToken = ""
    @ObservationIgnored private var engagement = UUID()
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private var socket: WatchPartySocket?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionsTaskID = UUID()
    @ObservationIgnored private var selectedItemTask: Task<Void, Never>?
    @ObservationIgnored private var pickerRequestID = UUID()
    @ObservationIgnored private var memberStateRequestID = UUID()
    @ObservationIgnored private weak var adapter: WatchPartyPlaybackAdapter?
    @ObservationIgnored private var commands = WatchPartyCommandState()
    @ObservationIgnored private var applyingCommand: String?
    @ObservationIgnored private var attachmentConfirmed = false
    @ObservationIgnored private var issuedAttachSession: String?
    @ObservationIgnored private var lastAttach: Date = .distantPast
    @ObservationIgnored private var lastReport: Date = .distantPast
    @ObservationIgnored private var lastPing: Date = .distantPast
    @ObservationIgnored private var lastReady: Date = .distantPast
    /// The playback session whose media has been playable at least once. Its
    /// position is real from then on, including while it rebuffers.
    @ObservationIgnored private var playableSession: String?
    @ObservationIgnored private var bufferBegan: Date?
    @ObservationIgnored private var reportedBuffering = false
    @ObservationIgnored private var serverOffset: TimeInterval = 0
    /// Local receipt time of the current room snapshot. Its anchor position is
    /// already projected to the server's build time, so only this age remains.
    @ObservationIgnored private var roomReceivedAt: Date = .distantPast
    @ObservationIgnored private var lastCommandCompleted: Date = .distantPast
    @ObservationIgnored private var mutationSequence: UInt64 = 0

    init(api: APIv2Client = SiloAPI.shared.apiV2Client, tokenStore: TokenStore = .shared,
         recentStore: WatchPartyRecentStore = WatchPartyRecentStore()) {
        self.api = api
        self.tokenStore = tokenStore
        self.recentStore = recentStore
    }

    func refreshCapabilities() async {
        let owner = engagement
        guard let captured = await tokenStore.captureOrdinaryRequestAuth(), captured.profileId != nil,
              owner == engagement else { return }
        if let recentAuth, !recentAuth.sameCredentialIdentity(as: captured) { forgetRecentRoomInMemory() }
        if isEngaged, let auth, !auth.sameCredentialIdentity(as: captured) { leave(forgetRecent: true); return }
        await restoreRecentRoom(auth: captured, owner: owner)
        _ = await loadCapabilities(auth: captured, owner: owner)
    }

    private func loadCapabilities(auth captured: CapturedOrdinaryRequestAuth, owner: UUID) async -> Bool {
        do {
            async let rooms = api.watchPartyCapabilities(auth: captured)
            async let playback = api.playbackCapabilities(auth: captured)
            let (roomCaps, playbackCaps) = try await (rooms, playback)
            guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: captured) != nil,
                  owner == engagement, !Task.isCancelled else { return false }
            capabilities = roomCaps
            supportsPlayback = playbackCaps.state == "available" && playbackCaps.allowed
                && playbackCaps.features.contains("watch_party_coordinator_v1") && playbackCaps.features.contains("fixed_media_file_v1")
            supportsFallback = playbackCaps.features.contains("watch_party_source_fallback_v1")
            auth = captured
            errorMessage = nil
            return true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: captured) != nil,
                  owner == engagement else { return false }
            if auth?.sameCredentialIdentity(as: captured) != true {
                capabilities = nil
                supportsPlayback = false
                supportsFallback = false
            }
            errorMessage = "Could not check Watch Party support. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func create(selection: WatchPartySelection? = nil, mode: WatchPartySelectionMode = .hostPick,
                preview: WatchPartySelectedItem? = nil) async -> Bool {
        // `enter` refuses, with its own message, when a party is already open.
        let ownsPreview = !isEngaged && !isBusy && selection != nil && mode == .hostPick
        if ownsPreview { selectionPreview = preview }
        let entered = await enter(keepsSelectionPreview: ownsPreview) {
            try await self.api.createWatchPartyRoom(selectionMode: mode, auth: $0)
        }
        guard entered else {
            if ownsPreview { selectionPreview = nil }
            return false
        }
        if let selection, mode == .hostPick { return await select(selection) }
        return true
    }

    @discardableResult
    func join(code: String) async -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { errorMessage = "Enter a party code or invitation link."; return false }
        return await enter { try await self.api.joinWatchPartyRoom(code: code, auth: $0) }
    }

    @discardableResult
    func join(invitation: String) async -> Bool {
        let value = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("://") else { return await join(code: value) }
        guard let url = URL(string: value), let parsed = WatchPartyInvitation(url: url) else {
            errorMessage = "This Watch Party invitation is invalid."
            return false
        }
        return await join(joinToken: parsed.joinToken, serverURL: parsed.serverURL)
    }

    @discardableResult
    func join(joinToken: String, serverURL: String) async -> Bool {
        await enter(invitationServer: serverURL) { try await self.api.joinWatchPartyRoom(joinToken: joinToken, auth: $0) }
    }

    @discardableResult
    func rejoinRecent() async -> Bool {
        guard let recentRoom, let recentAuth,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: recentAuth) != nil else {
            forgetRecentRoomInMemory()
            errorMessage = "This recent party belongs to a different server, account, or profile."
            return false
        }
        return await enter(expectedRoomID: recentRoom.roomId, expectedAuth: recentAuth) {
            try await self.api.joinWatchPartyRoom(code: recentRoom.code, auth: $0)
        }
    }

    private func enter(invitationServer: String? = nil, expectedRoomID: String? = nil,
                       expectedAuth: CapturedOrdinaryRequestAuth? = nil, keepsSelectionPreview: Bool = false,
                       _ operation: (CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse) async -> Bool {
        guard !isBusy else { return false }
        guard !isEngaged else {
            errorMessage = "You're already in a party. Leave it to join a different one."
            return false
        }
        let owner = engagement
        isBusy = true
        // Only the create that set it may carry a preview into the new room.
        if !keepsSelectionPreview { selectionPreview = nil }
        errorMessage = nil
        defer { if owner == engagement { isBusy = false } }
        guard let captured = await tokenStore.captureOrdinaryRequestAuth(), captured.profileId != nil,
              owner == engagement else {
            if owner == engagement { errorMessage = "Select a server and profile before joining a party." }
            return false
        }
        if let expectedAuth, !expectedAuth.sameCredentialIdentity(as: captured) {
            forgetRecentRoomInMemory()
            errorMessage = "This recent party belongs to a different server, account, or profile."
            return false
        }
        if let invitationServer, !WatchPartyLobbyPolicy.sameServer(invitationServer, captured.account.serverURL) {
            errorMessage = "This invitation is for another server. Select that server and open the invitation again."
            return false
        }
        if let recentAuth, !recentAuth.sameCredentialIdentity(as: captured) { forgetRecentRoomInMemory() }
        guard await loadCapabilities(auth: captured, owner: owner), owner == engagement else { return false }
        guard capabilities?.supportsSocket == true, capabilities?.connectionReplaced == true, supportsPlayback else {
            errorMessage = "This server needs an update to support synchronized Watch Party playback safely on this profile."
            return false
        }
        do {
            let response = try await operation(captured)
            guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: captured) != nil,
                  owner == engagement, !Task.isCancelled else { return false }
            if let expectedRoomID, response.room.roomId != expectedRoomID { throw WatchPartyAPIError.invalidResponse }
            cancelConnection()
            state = WatchPartyRoomState()
            votes = WatchPartyVotes()
            selectedItem = nil
            selectedItemUnavailable = false
            picker = nil
            memberState = nil
            wasReplaced = false
            roomToken = response.roomAccessToken
            accept(response.room)
            guard !state.terminal else { return false }
            startConnection()
            return true
        } catch {
            if owner == engagement {
                // A rejoin that the server refuses as gone or closed (409 after
                // the host's grace expired) must not keep offering the room.
                if expectedRoomID != nil, isTerminalError(error) || Self.isConflict(error) { clearRecentRoom() }
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func leave(forgetRecent: Bool = false) {
        if forgetRecent { clearRecentRoom() }
        engagement = UUID()
        cancelConnection()
        adapter?.stop()
        adapter = nil
        commands = WatchPartyCommandState()
        state = WatchPartyRoomState()
        votes = WatchPartyVotes()
        selectedItem = nil
        selectionPreview = nil
        selectedItemUnavailable = false
        picker = nil
        memberState = nil
        roomToken = ""
        auth = nil
        capabilities = nil
        supportsPlayback = false
        supportsFallback = false
        serverOffset = 0
        playbackContext = nil
        connection = .idle
        errorMessage = nil
        wasReplaced = false
        isBusy = false
    }

    /// Leave the room without crossing an identity boundary. Support was read
    /// for this same identity, so the Watch Party entry points stay offered.
    func leaveRoom() {
        let support = (capabilities, supportsPlayback, supportsFallback)
        leave()
        (capabilities, supportsPlayback, supportsFallback) = support
    }

    /// The saved entry is scoped to its durable owner, so an identity mismatch
    /// drops only this copy. A PIN profile that unlocks again has a new proof
    /// but the same owner, and `restoreRecentRoom` reloads its entry.
    private func forgetRecentRoomInMemory() {
        recentPersistenceTask?.cancel()
        recentPersistenceTask = nil
        recentRoom = nil
        recentAuth = nil
        lastPersistedRecent = nil
        lastRecentPersistence = .distantPast
    }

    private func clearRecentRoom() {
        forgetRecentRoomInMemory()
        recentStore.clear()
    }

    private func restoreRecentRoom(auth: CapturedOrdinaryRequestAuth, owner: UUID) async {
        guard recentRoom == nil, let durable = await tokenStore.captureDurableAccountAuth(),
              durable.request.sameCredentialIdentity(as: auth), let storedOwner = WatchPartyRecentOwner(auth: durable),
              owner == engagement else { return }
        guard let saved = recentStore.load(owner: storedOwner),
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil, owner == engagement else { return }
        recentRoom = saved
        recentAuth = auth
        lastPersistedRecent = saved
        lastRecentPersistence = Date()
    }

    private func persistRecentRoom() {
        guard let recentRoom, let auth else { return }
        // Roster/readiness snapshots are frequent. Persist changed display data
        // immediately and renew an unchanged active room at most once an hour.
        guard recentRoom != lastPersistedRecent || Date().timeIntervalSince(lastRecentPersistence) >= 60 * 60 else { return }
        let owner = engagement
        recentPersistenceTask?.cancel()
        let store = recentStore
        let writeGeneration = store.writeGeneration
        recentPersistenceTask = Task { [weak self] in
            guard let self, let durable = await self.tokenStore.captureDurableAccountAuth(),
                  durable.request.sameCredentialIdentity(as: auth), let storedOwner = WatchPartyRecentOwner(auth: durable),
                  self.recentRoom == recentRoom, !Task.isCancelled else { return }
            do {
                try await self.tokenStore.withCurrentDurableAuthority(durable) {
                    guard store.save(recentRoom, owner: storedOwner, expectedGeneration: writeGeneration) else {
                        throw CancellationError()
                    }
                }
                guard owner == self.engagement, !Task.isCancelled else { return }
                self.lastPersistedRecent = recentRoom
                self.lastRecentPersistence = Date()
            } catch { /* Recent-room storage does not prevent joining or playback. */ }
        }
    }

    /// Catalog continuations retain this owner even if the user switches profiles.
    func catalogAuth() async throws -> CapturedOrdinaryRequestAuth {
        let owner = engagement
        guard let auth, await ownsCurrentIdentity(), owner == engagement, isEngaged else {
            throw HTTPError.requestIdentityChanged
        }
        return auth
    }

    /// Called before account/profile/server replacement and before any room I/O.
    @discardableResult
    func validateIdentity() async -> Bool {
        guard isEngaged else { return true }
        let owner = engagement
        let valid = await ownsCurrentIdentity()
        guard owner == engagement else { return false }
        guard valid else { leave(); forgetRecentRoomInMemory(); return false }
        return true
    }

    private func ownsCurrentIdentity() async -> Bool {
        guard let auth else { return false }
        return await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
    }

    private func terminate(_ message: String, replaced: Bool = false, canRejoin: Bool = true) {
        engagement = UUID()
        state.end()
        selectionPreview = nil
        wasReplaced = replaced
        isBusy = false
        if !canRejoin { clearRecentRoom() }
        cancelConnection()
        adapter?.stop()
        adapter = nil
        playbackContext = nil
        commands = WatchPartyCommandState()
        connection = .ended
        errorMessage = message
        roomToken = ""
    }

    private func cancelConnection() {
        connectionID = UUID()
        connectionTask?.cancel(); connectionTask = nil
        reportTask?.cancel(); reportTask = nil
        commandTask?.cancel(); commandTask = nil
        suggestionsTask?.cancel(); suggestionsTask = nil
        suggestionsTaskID = UUID()
        selectedItemTask?.cancel(); selectedItemTask = nil
        pickerRequestID = UUID()
        memberStateRequestID = UUID()
        isLoadingPicker = false
        isLoadingMemberState = false
        socket?.close(); socket = nil
        adapter?.cancelCorrection()
        attachmentConfirmed = false
        applyingCommand = nil
    }

    private func startConnection() {
        connectionTask?.cancel()
        let owner = engagement
        connectionTask = Task { [weak self] in
            var failures = 0
            while let self, !Task.isCancelled, self.engagement == owner, self.isEngaged {
                guard await self.validateIdentity(), let auth = self.auth, let room = self.room else { return }
                self.connection = failures == 0 ? .connecting : .reconnecting
                self.connectionID = UUID()
                let socketID = self.connectionID
                let socket = WatchPartySocket()
                self.socket = socket
                self.attachmentConfirmed = false
                self.issuedAttachSession = nil
                self.bufferBegan = nil
                self.reportedBuffering = false
                self.commandTask?.cancel()
                self.commandTask = nil
                self.applyingCommand = nil
                self.commands = WatchPartyCommandState()
                var openedAt: Date?
                do {
                    let receipt = self.state.receipt
                    let response = try await self.api.watchPartyRoom(id: room.roomId, token: self.roomToken, auth: auth)
                    guard await self.ownsCurrentIdentity(), owner == self.engagement, socketID == self.connectionID else { return }
                    self.roomToken = response.roomAccessToken
                    self.accept(response.room, requestReceipt: receipt)
                    guard self.isEngaged else { return }
                    let ticket = try await self.api.watchPartySocketTicket(roomId: room.roomId, token: self.roomToken, auth: auth)
                    guard await self.ownsCurrentIdentity(), owner == self.engagement, socketID == self.connectionID else { return }
                    let events = try socket.connect(serverURL: auth.account.serverURL, roomId: room.roomId, ticket: ticket)
                    for try await event in events {
                        guard await self.validateIdentity(), !Task.isCancelled, owner == self.engagement, socketID == self.connectionID else { return }
                        switch event {
                        case .opened:
                            openedAt = Date()
                            self.connection = .connected
                            self.trace("socket connected")
                            self.errorMessage = nil
                            self.startReporting(owner: owner, socketID: socketID)
                            self.refreshSuggestions()
                        case .message(let message): self.receive(message)
                        }
                        if self.state.terminal { return }
                    }
                } catch {
                    guard owner == self.engagement, socketID == self.connectionID, !Task.isCancelled else { return }
                    // The room read and ticket refuse an ended room with 409.
                    // Only members with a live socket receive room_closed.
                    if Self.isConflict(error) {
                        self.terminate("This party has ended.", canRejoin: false)
                        return
                    }
                    if self.isTerminalError(error) {
                        self.terminate("The party connection expired or is no longer available. Join again to continue.")
                        return
                    }
                }
                socket.close()
                // leave() and terminate() finish the stream without an error.
                guard owner == self.engagement, socketID == self.connectionID, !Task.isCancelled else { return }
                self.reportTask?.cancel()
                self.commandTask?.cancel()
                self.attachmentConfirmed = false
                // The server ends every room socket at its connection deadline
                // (five minutes, or sooner when the bearer expires). A socket
                // that stayed up reconnects at once, without backing off or
                // showing the party as reconnecting. One that closes soon after
                // opening keeps backing off.
                if let openedAt, Date().timeIntervalSince(openedAt) >= 30 {
                    failures = 0
                    continue
                }
                failures += 1
                self.connection = .reconnecting
                do { try await Task.sleep(for: .seconds(min(15, pow(2, Double(min(failures - 1, 4)))))) }
                catch { return }
            }
        }
    }

    private func isTerminalError(_ error: Error) -> Bool {
        if let error = error as? HTTPError {
            switch error {
            case .authorityChanged, .requestIdentityChanged: return true
            default: break
            }
        }
        if let error = error as? APIv2Error {
            switch error {
            case .httpStatus(let status): return [401, 403, 404, 410].contains(status)
            case .problem(let problem): return [401, 403, 404, 410].contains(problem.status)
            default: break
            }
        }
        if let error = error as? WatchPartySocketError, case .unsupportedProtocol = error { return true }
        return error is DecodingError || error is WatchPartyAPIError
    }

    private func receive(_ message: WatchPartyServerMessage) {
        switch message {
        case .snapshot(let room): accept(room)
        case .transport(let command):
            guard let room, commands.receive(command, room: room, sessionId: adapter?.snapshot.sessionId) else { return }
            trace("command \(command.action.wireValue) state=\(command.playbackState.wireValue) revision=\(command.selectionRevision)")
            commandTask?.cancel()
            adapter?.cancelCorrection()
            commandTask = nil
            applyingCommand = nil
            applyPendingCommand()
        case .suggestions(let suggestions):
            guard let room, suggestions.allSatisfy({ $0.roomId == room.roomId }) else { return }
            votes.receive(suggestions)
            refreshSuggestions()
        case .pong(let client, let received, let sent):
            let now = Date()
            let roundTrip = now.timeIntervalSince(client) - sent.timeIntervalSince(received)
            guard roundTrip >= 0, roundTrip < 5 else { return }
            serverOffset = (received.timeIntervalSince(client) + sent.timeIntervalSince(now)) / 2
        case .closed: terminate("This party has ended.", canRejoin: false)
        case .connectionReplaced:
            terminate("This profile joined the party on another device. Rejoin here to take over playback.", replaced: true)
        case .error(let code, let message):
            if code == "connection_replaced" {
                terminate("This profile joined the party on another device. Rejoin here to take over playback.", replaced: true)
            }
            else { errorMessage = message }
        case .unknown: break
        }
    }

    private func accept(_ incoming: WatchPartyRoom, requestReceipt: UInt64? = nil) {
        let old = room
        guard state.accept(incoming, requestReceipt: requestReceipt) else { return }
        roomReceivedAt = Date()
        trace("snapshot phase=\(incoming.phase.wireValue) state=\(incoming.playbackState.wireValue) revision=\(incoming.selectionRevision)")
        if incoming.phase == .ended { terminate("This party has ended.", canRejoin: false); return }
        if let auth {
            recentAuth = auth
            recentRoom = WatchPartyRecentRoom(roomId: incoming.roomId, code: incoming.code,
                selectedTitle: selectedItem?.contentId == incoming.selectedContentId ? selectedItem?.title : nil)
            persistRecentRoom()
        }
        if old?.selectedContentId != incoming.selectedContentId || old?.selectedLibraryId != incoming.selectedLibraryId {
            refreshSelectedItem(incoming)
        }
        let newEpoch = old?.selectionRevision != incoming.selectionRevision || old?.phase != incoming.phase
        if newEpoch {
            commandTask?.cancel(); commandTask = nil
            applyingCommand = nil
            commands = WatchPartyCommandState()
            attachmentConfirmed = false
            issuedAttachSession = nil
            bufferBegan = nil
            reportedBuffering = false
            adapter?.stop()
            adapter = nil
            playbackContext = Self.playbackContext(for: incoming)
        }
        if let adapter {
            adapter.canPlayPause = incoming.selfCanControlTransport
            adapter.canSeek = incoming.selfRole == .host
            attachmentConfirmed = incoming.attachedSessionId == adapter.snapshot.sessionId
                && issuedAttachSession == adapter.snapshot.sessionId && adapter.snapshot.sessionId != nil
            applyPendingCommand()
        }
    }

    /// Snapshots report the anchor already projected to when the server built
    /// them; `anchorUpdatedAt` is the last re-anchor, so projecting from it
    /// would count that playback twice. Only the snapshot's local age remains.
    static func playbackContext(for room: WatchPartyRoom, elapsedSinceSnapshot: TimeInterval = 0) -> WatchPartyPlaybackContext? {
        guard room.phase == .playing, let contentId = room.selectedContentId,
              let file = room.selectedFileId.flatMap(Int.init), file > 0 else { return nil }
        let position = room.anchorPositionSeconds + (room.playbackState == .playing && !room.isPaused
            ? max(0, elapsedSinceSnapshot) : 0)
        return WatchPartyPlaybackContext(roomId: room.roomId, selectionRevision: room.selectionRevision,
            contentId: contentId, fileId: file, libraryId: room.selectedLibraryId.flatMap(Int.init), startPosition: position)
    }

    func bind(_ adapter: WatchPartyPlaybackAdapter, context: WatchPartyPlaybackContext) {
        guard isEngaged, playbackContext == context else { return }
        self.adapter = adapter
        adapter.canPlayPause = room?.selfCanControlTransport == true
        adapter.canSeek = room?.selfRole == .host
        adapter.onSnapshot = { [weak self, weak adapter] _ in
            guard let self, self.adapter === adapter else { return }
            self.applyPendingCommand()
        }
        adapter.onSessionCommitted = { [weak self, weak adapter] _ in
            guard let self, self.adapter === adapter else { return }
            self.attachmentConfirmed = false
            self.issuedAttachSession = nil
            self.bufferBegan = nil
            self.reportedBuffering = false
            self.lastAttach = .distantPast
        }
        adapter.onResyncRequired = { [weak self, weak adapter] in
            guard let self, self.adapter === adapter else { return }
            self.commandTask?.cancel()
            self.commandTask = nil
            self.applyingCommand = nil
            self.commands = WatchPartyCommandState()
            self.attachmentConfirmed = false
            self.issuedAttachSession = nil
            self.lastAttach = .distantPast
            if let room = self.room {
                let position = Self.playbackContext(for: room, elapsedSinceSnapshot: Date().timeIntervalSince(self.roomReceivedAt))?
                    .startPosition ?? room.anchorPositionSeconds
                adapter?.restoreIfNeeded(at: position)
            }
        }
        adapter.onUserTransport = { [weak self, weak adapter] action, position, paused in
            guard let self, self.adapter === adapter else { return }
            self.requestTransport(action, position: position, paused: paused)
        }
        adapter.onLocalExit = { [weak self, weak adapter] in
            guard let self, self.adapter === adapter else { return }
            self.leaveRoom()
        }
        adapter.onFailure = { [weak self, weak adapter] reason, message in
            guard let self, self.adapter === adapter else { return }
            self.handlePlaybackFailure(reason: reason, message: message, context: context)
        }
        adapter.prepare(context)
    }

    private func requestTransport(_ action: WatchPartyPlaybackAction, position: Double, paused: Bool) {
        guard connection == .connected, attachmentConfirmed, let room,
              action.isPermitted(canPlayPause: room.selfCanControlTransport, canSeek: room.selfRole == .host) else { return }
        // A session now attaches while its media is still loading. Play and
        // pause carry the local position, which the room adopts as its
        // anchor; before the media has first become playable that is not a
        // real position. Such a press is dropped, as it was when the session
        // could not attach before then (#410 tracks queueing it). A seek
        // carries its own target.
        switch action {
        case .seek: break
        case .play, .pause:
            guard let snapshot = adapter?.snapshot, let session = snapshot.sessionId,
                  snapshot.isReady || playableSession == session else { return }
        }
        let wire: WatchPartyTransportAction
        let target: Double
        switch action {
        case .play: wire = .play; target = position
        case .pause: wire = .pause; target = position
        case .seek(let value): wire = .seek; target = value
        }
        send(WatchPartyClientMessage(type: "transport_request", action: wire, positionSeconds: target, isPaused: paused))
    }

    private func applyPendingCommand() {
        guard commandTask == nil, connection == .connected, attachmentConfirmed,
              let adapter, adapter.snapshot.isReady, let command = commands.pending,
              let context = playbackContext, command.selectionRevision == context.selectionRevision else { return }
        let owner = engagement
        let socketID = connectionID
        let sessionID = adapter.snapshot.sessionId
        applyingCommand = command.commandId
        commandTask = Task { [weak self, weak adapter] in
            guard let self, let adapter else { return }
            defer {
                if self.applyingCommand == command.commandId {
                    self.applyingCommand = nil
                    self.commandTask = nil
                }
            }
            do {
                let delay = command.executeAt.timeIntervalSince(Date().addingTimeInterval(self.serverOffset))
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                guard await self.validateIdentity(), !Task.isCancelled, owner == self.engagement, socketID == self.connectionID,
                      self.commands.pending?.commandId == command.commandId, self.playbackContext == context,
                      adapter.snapshot.sessionId == sessionID else { return }
                let target = WatchPartyCommandState.projectedPosition(command, serverNow: Date().addingTimeInterval(self.serverOffset))
                if command.playbackState != .playing { _ = try await adapter.apply(.pause) }
                // Server drift corrections use play/pause. An explicit seek
                // enters the waiting barrier and must always land on its target.
                if command.action == .play, command.playbackState == .playing, adapter.snapshot.isPlaying {
                    _ = try await adapter.correct(to: target)
                } else if command.action == .seek || abs(adapter.snapshot.sourceTime - target) > 1 {
                    let smallPausedCorrection = command.action == .pause
                        && abs(adapter.snapshot.sourceTime - target) <= 2 && !adapter.canSeekLocally(to: target)
                    if !smallPausedCorrection { _ = try await adapter.apply(.seek(target)) }
                }
                try Task.checkCancellation()
                guard owner == self.engagement, socketID == self.connectionID,
                      self.commands.pending?.commandId == command.commandId else { return }
                _ = try await adapter.apply(command.playbackState == .playing ? .play : .pause)
                try Task.checkCancellation()
                guard owner == self.engagement, socketID == self.connectionID,
                      self.commands.pending?.commandId == command.commandId else { return }
                self.commands.complete(command.commandId)
                self.lastCommandCompleted = Date()
            } catch is CancellationError {
            } catch {
                if owner == self.engagement { self.errorMessage = "Waiting for the player to synchronize." }
            }
        }
    }

    private func startReporting(owner: UUID, socketID: UUID) {
        reportTask?.cancel()
        lastAttach = .distantPast; lastPing = .distantPast; lastReady = .distantPast
        reportTask = Task { [weak self] in
            while let self, !Task.isCancelled, owner == self.engagement, socketID == self.connectionID {
                guard await self.validateIdentity() else { return }
                await self.report()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func report() async {
        guard connection == .connected, let socket else { return }
        let owner = engagement
        let socketID = connectionID
        let context = playbackContext
        let now = Date()
        do {
            if now.timeIntervalSince(lastPing) >= 15 {
                lastPing = now
                try await socket.send(WatchPartyClientMessage(type: "ping", clientSentAt: now))
            }
            guard owner == engagement, socketID == connectionID, context == playbackContext,
                  let adapter, let room, let session = adapter.snapshot.sessionId,
                  adapter.context == playbackContext else { return }
            let snapshot = adapter.snapshot
            if snapshot.isReady { playableSession = session }
            if !attachmentConfirmed {
                // Attach as soon as the stream has a committed session, as the
                // web client does. The start barrier only waits for attached
                // members, so waiting for playable media here let a member that
                // loaded faster release the room without this one. Commands
                // that arrive before the media is ready stay pending until it is.
                if now.timeIntervalSince(lastAttach) >= 1.5 {
                    lastAttach = now
                    issuedAttachSession = session
                    trace("attach ready=\(snapshot.isReady) file=\(snapshot.fileId ?? 0)")
                    try await socket.send(WatchPartyClientMessage(type: "attach_session", sessionId: session))
                }
                return
            }
            applyPendingCommand()
            guard !snapshot.isSeeking, commands.pending == nil,
                  now.timeIntervalSince(lastCommandCompleted) >= 0.25,
                  snapshot.fileId == playbackContext?.fileId else { return }
            if snapshot.isBuffering {
                if bufferBegan == nil { bufferBegan = now }
                if !reportedBuffering, now.timeIntervalSince(bufferBegan!) >= 0.5 {
                    reportedBuffering = true
                    try await socket.send(WatchPartyClientMessage(type: "buffering", sessionId: session,
                        positionSeconds: snapshot.sourceTime, isPaused: !snapshot.isPlaying))
                }
                return
            }
            bufferBegan = nil
            reportedBuffering = false
            guard snapshot.isReady else { return }
            let completed = commands.completed
            let ready = WatchPartyCommandState.canAcknowledge(completed, roomPlaybackState: room.playbackState,
                sourceTime: snapshot.sourceTime, isHost: room.selfRole == .host)
            if ready, WatchPartyCommandState.awaitsReadiness(room), now.timeIntervalSince(lastReady) >= 0.5 {
                lastReady = now
                try await socket.send(WatchPartyClientMessage(type: "ready", sessionId: session, commandId: completed?.commandId,
                    positionSeconds: snapshot.sourceTime, isPaused: !snapshot.isPlaying))
            }
            guard owner == engagement, socketID == connectionID, context == playbackContext,
                  adapter.snapshot.sessionId == session else { return }
            if ready, now.timeIntervalSince(lastReport) >= 1.5 {
                lastReport = now
                trace("report time=\(String(format: "%.2f", snapshot.sourceTime)) playing=\(snapshot.isPlaying) ready=\(snapshot.isReady) file=\(snapshot.fileId ?? 0)")
                try await socket.send(WatchPartyClientMessage(type: "state_report", sessionId: session, commandId: completed?.commandId,
                    positionSeconds: snapshot.sourceTime, isPaused: !snapshot.isPlaying, isReady: true))
            }
        } catch { socket.close() }
    }

    private func send(_ message: WatchPartyClientMessage) {
        let owner = engagement
        let socketID = connectionID
        guard let socket, let room else { return }
        let sessionId = adapter?.snapshot.sessionId
        Task { [weak self] in
            guard let self, await self.validateIdentity(), owner == self.engagement, socketID == self.connectionID,
                  self.room?.roomId == room.roomId, self.room?.selectionRevision == room.selectionRevision,
                  self.room?.phase == room.phase else { return }
            if message.type == "transport_request" {
                guard self.attachmentConfirmed, self.adapter?.snapshot.sessionId == sessionId else { return }
            }
            do { try await socket.send(message) } catch { socket.close() }
        }
    }

    func setLobbyReady(_ ready: Bool) {
        guard room?.phase == .lobby, capabilities?.lobbyReady == true else { return }
        send(WatchPartyClientMessage(type: "lobby_ready", ready: ready))
    }

    @discardableResult
    func select(_ selection: WatchPartySelection, preview: WatchPartySelectedItem? = nil) async -> Bool {
        guard isEngaged, room?.selectionMode == .hostPick else {
            if selectionPreview?.contentId == selection.contentId { selectionPreview = nil }
            return false
        }
        if let preview, preview.contentId == selection.contentId { selectionPreview = preview }
        let selected: Bool
        if room?.phase == .lobby, capabilities?.stagedSelection == true {
            selected = await stage(selection)
        } else {
            selected = await mutate { try await self.api.setWatchPartySelection(roomId: $0, token: $1, selection: selection, auth: $2) }
        }
        if !selected, selectionPreview?.contentId == selection.contentId { selectionPreview = nil }
        return selected
    }

    @discardableResult
    func stage(_ selection: WatchPartySelection) async -> Bool {
        guard capabilities?.stagedSelection == true, room?.phase == .lobby, room?.selectionMode == .hostPick else { return false }
        return await mutate { try await self.api.stageWatchPartySelection(roomId: $0, token: $1, selection: selection, auth: $2) }
    }

    @discardableResult
    func startPlayback() async -> Bool {
        guard canStartPlayback else { return false }
        if room?.selectionMode == .vote, let winner = voteWinner { return await promoteSuggestion(id: winner.id) }
        return await mutate { try await self.api.startWatchPartyPlayback(roomId: $0, token: $1, auth: $2) }
    }

    @discardableResult
    func stopPlayback() async -> Bool {
        guard capabilities?.stopPlayback == true, room?.phase == .playing else { return false }
        return await mutate { try await self.api.stopWatchPartyPlayback(roomId: $0, token: $1, auth: $2) }
    }

    @discardableResult
    func setMode(_ mode: WatchPartySelectionMode) async -> Bool {
        guard capabilities?.selectionModeSwitch == true, room?.phase == .lobby else { return false }
        return await mutate { try await self.api.setWatchPartySelectionMode(roomId: $0, token: $1, mode: mode, auth: $2) }
    }

    @discardableResult
    func setPolicy(_ policy: WatchPartyGuestControlPolicy) async -> Bool {
        await mutate { try await self.api.setWatchPartyPolicy(roomId: $0, token: $1, policy: policy, auth: $2) }
    }

    func endParty() async {
        guard await validateIdentity(), !isBusy, isEngaged, room?.selfCanManageRoom == true, let room, let auth else { return }
        let owner = engagement
        isBusy = true
        errorMessage = nil
        defer { if owner == engagement { isBusy = false } }
        do {
            try await api.closeWatchPartyRoom(roomId: room.roomId, token: roomToken, auth: auth)
            guard await ownsCurrentIdentity(), owner == engagement else { return }
            terminate("This party has ended.", canRejoin: false)
        } catch { if owner == engagement { errorMessage = error.localizedDescription } }
    }

    private func mutate(_ operation: (String, String, CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse) async -> Bool {
        guard await validateIdentity(), !isBusy, isEngaged, room?.selfCanManageRoom == true, let room, let auth else { return false }
        let owner = engagement
        let receipt = state.receipt
        mutationSequence &+= 1
        let sequence = mutationSequence
        isBusy = true
        errorMessage = nil
        defer { if owner == engagement { isBusy = false } }
        do {
            let response = try await operation(room.roomId, roomToken, auth)
            guard await validateIdentity(), owner == engagement, isEngaged, sequence == mutationSequence else { return false }
            roomToken = response.roomAccessToken
            accept(response.room, requestReceipt: receipt)
            errorMessage = nil
            return true
        } catch {
            if owner == engagement { errorMessage = error.localizedDescription }
            return false
        }
    }

    func canRemoveSuggestion(_ suggestion: WatchPartySuggestion) -> Bool {
        isEngaged && WatchPartyLobbyPolicy.canRemove(suggestion, room: room)
    }

    @discardableResult
    func addSuggestion(_ suggestion: WatchPartyNewSuggestion) async -> Bool {
        await mutateSuggestions { room, token, auth in
            _ = try await self.api.addWatchPartySuggestion(roomId: room, token: token, suggestion: suggestion, auth: auth)
        }
    }

    @discardableResult
    func deleteSuggestion(id: String) async -> Bool {
        guard let suggestion = votes.rows.first(where: { $0.id == id }), canRemoveSuggestion(suggestion) else { return false }
        return await mutateSuggestions { try await self.api.deleteWatchPartySuggestion(roomId: $0, token: $1, suggestionId: id, auth: $2) }
    }

    @discardableResult
    func setVote(suggestionId: String, voted: Bool) async -> Bool {
        guard votes.rows.contains(where: { $0.id == suggestionId }) else { return false }
        return await mutateSuggestions { try await self.api.voteWatchPartySuggestion(roomId: $0, token: $1, suggestionId: suggestionId, voted: voted, auth: $2) }
    }

    @discardableResult
    func promoteSuggestion(id: String) async -> Bool {
        guard room?.phase == .lobby, votes.rows.contains(where: { $0.id == id }) else { return false }
        if room?.selectionMode == .vote, capabilities?.voteHostOverride != true, voteWinner?.id != id { return false }
        return await mutate { try await self.api.promoteWatchPartySuggestion(roomId: $0, token: $1, suggestionId: id, auth: $2) }
    }

    private func mutateSuggestions(_ operation: (String, String, CapturedOrdinaryRequestAuth) async throws -> Void) async -> Bool {
        guard await validateIdentity(), !isBusy, isEngaged, room?.phase == .lobby, let room, let auth else { return false }
        let owner = engagement
        isBusy = true
        errorMessage = nil
        suggestionsTask?.cancel()
        suggestionsTask = nil
        suggestionsTaskID = UUID()
        votes.invalidatePersonalReads()
        defer { if owner == engagement { isBusy = false } }
        do {
            try await operation(room.roomId, roomToken, auth)
            guard await validateIdentity(), owner == engagement, isEngaged else { return false }
        } catch {
            // A lost mutation response does not prove the server rejected the
            // change. Read personal votes again without replaying the mutation.
            if owner == engagement, !Task.isCancelled {
                try? await loadSuggestions(roomId: room.roomId, auth: auth, owner: owner)
                if owner == engagement { errorMessage = error.localizedDescription }
            }
            return false
        }
        do {
            try await loadSuggestions(roomId: room.roomId, auth: auth, owner: owner)
        } catch {
            if owner == engagement { errorMessage = "Your change was saved, but the suggestions could not be refreshed. \(error.localizedDescription)" }
        }
        return owner == engagement && isEngaged
    }

    func refreshSuggestions() {
        guard suggestionsTask == nil, !isBusy, isEngaged, let room, let auth else { return }
        let owner = engagement
        let requestID = UUID()
        suggestionsTaskID = requestID
        suggestionsTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.suggestionsTaskID == requestID { self.suggestionsTask = nil } }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try await self.loadSuggestions(roomId: room.roomId, auth: auth, owner: owner)
            } catch is CancellationError {
            } catch {
                if owner == self.engagement { self.errorMessage = "Could not refresh suggestions. \(error.localizedDescription)" }
            }
        }
    }

    private func loadSuggestions(roomId: String, auth: CapturedOrdinaryRequestAuth, owner: UUID) async throws {
        for _ in 0..<3 {
            let revision = votes.revision
            var rows: [WatchPartySuggestion] = []
            var cursor: String?
            var cursors = Set<String>()
            repeat {
                try Task.checkCancellation()
                let page = try await api.watchPartySuggestions(roomId: roomId, token: roomToken, cursor: cursor, auth: auth)
                guard await validateIdentity(), owner == engagement, isEngaged else { throw CancellationError() }
                try Task.checkCancellation()
                rows += page.items
                cursor = page.page.hasMore ? page.page.nextCursor : nil
                if let cursor, !cursors.insert(cursor).inserted { throw WatchPartyAPIError.invalidResponse }
            } while cursor != nil
            if votes.reconcile(rows, requestedAt: revision) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw WatchPartyAPIError.invalidResponse
    }

    func refreshPicker() async {
        guard await validateIdentity(), capabilities?.picker == true, !isLoadingPicker, isEngaged,
              let room, let auth else { return }
        let owner = engagement
        let requestID = UUID()
        pickerRequestID = requestID
        isLoadingPicker = true
        defer { if pickerRequestID == requestID { isLoadingPicker = false } }
        do {
            let result = try await api.watchPartyPicker(roomId: room.roomId, token: roomToken, auth: auth)
            guard await validateIdentity(), owner == engagement, pickerRequestID == requestID, isEngaged else { return }
            picker = result
        } catch is CancellationError {
        } catch {
            if owner == engagement, pickerRequestID == requestID, !Task.isCancelled {
                errorMessage = "Could not load party picks. \(error.localizedDescription)"
            }
        }
    }

    func refreshMemberState(contentIds: [String]) async {
        guard capabilities?.memberState == true, await validateIdentity(), isEngaged, let room, let auth else { return }
        let maximum = capabilities?.maxMemberStateIds ?? 200
        let ids = WatchPartyLobbyPolicy.memberStateIDs(contentIds, maximum: maximum > 0 ? maximum : 200)
        let owner = engagement
        let requestID = UUID()
        memberStateRequestID = requestID
        memberState = nil
        guard !ids.isEmpty else { isLoadingMemberState = false; return }
        isLoadingMemberState = true
        defer { if memberStateRequestID == requestID { isLoadingMemberState = false } }
        do {
            let result = try await api.watchPartyMemberState(roomId: room.roomId, token: roomToken, contentIds: ids, auth: auth)
            guard await validateIdentity(), owner == engagement, memberStateRequestID == requestID, isEngaged else { return }
            memberState = result
        } catch is CancellationError {
        } catch {
            if owner == engagement, memberStateRequestID == requestID, !Task.isCancelled {
                errorMessage = "Could not load member watch history. \(error.localizedDescription)"
            }
        }
    }

    private func refreshSelectedItem(_ room: WatchPartyRoom) {
        selectedItemTask?.cancel()
        selectedItem = nil
        selectedItemUnavailable = false
        if let preview = selectionPreview, let contentId = room.selectedContentId, contentId != preview.contentId {
            selectionPreview = nil
        }
        guard let contentId = room.selectedContentId, !contentId.isEmpty, let auth else { return }
        let owner = engagement
        selectedItemTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await self.api.catalogItem(id: contentId, libraryId: room.selectedLibraryId, imageSize: nil, auth: auth)
                var item = WatchPartySelectedItem(detail)
                if detail.type == "episode", let seriesId = detail.seriesId, !seriesId.isEmpty,
                   let poster = await self.showPoster(seriesId: seriesId, seasonNumber: detail.seasonNumber,
                                                      libraryId: room.selectedLibraryId, auth: auth) {
                    item.posterUrl = poster.url
                    item.posterThumbhash = poster.thumbhash
                }
                guard await self.validateIdentity(), owner == self.engagement, self.isEngaged, !Task.isCancelled,
                      self.room?.selectedContentId == contentId, self.room?.selectedLibraryId == room.selectedLibraryId else { return }
                self.selectedItem = item
                if self.selectionPreview?.contentId == contentId { self.selectionPreview = nil }
                self.recentRoom?.selectedTitle = detail.title
                self.persistRecentRoom()
            } catch {
                // Metadata is optional, but a refusal means this profile cannot
                // see the title at all and playback will be refused the same way.
                guard !Task.isCancelled, owner == self.engagement, self.isEngaged,
                      self.room?.selectedContentId == contentId, Self.isAccessRefusal(error) else { return }
                self.selectedItemUnavailable = true
                if self.selectionPreview?.contentId == contentId { self.selectionPreview = nil }
            }
        }
    }

    /// Portrait art for an episode: its season's poster, else the series'.
    /// Both reads are best effort; nil keeps the episode's own artwork.
    private func showPoster(seriesId: String, seasonNumber: Int64?, libraryId: String?,
                            auth: CapturedOrdinaryRequestAuth) async -> (url: String, thumbhash: String?)? {
        if let seasonNumber,
           let seasons = try? await api.catalogSeasons(seriesId: seriesId, libraryId: libraryId, imageSize: nil, auth: auth),
           let season = seasons.first(where: { $0.seasonNumber == seasonNumber }),
           let url = season.posterUrl, !url.isEmpty {
            return (url, season.posterThumbhash)
        }
        guard !Task.isCancelled,
              let series = try? await api.catalogItem(id: seriesId, libraryId: libraryId, imageSize: nil, auth: auth),
              let url = series.posterUrl, !url.isEmpty else { return nil }
        return (url, series.posterThumbhash)
    }

    nonisolated static func isConflict(_ error: Error) -> Bool {
        guard let error = error as? APIv2Error else { return false }
        switch error {
        case .httpStatus(let status): return status == 409
        case .problem(let problem): return problem.status == 409
        default: return false
        }
    }

    nonisolated static func isAccessRefusal(_ error: Error) -> Bool {
        guard let error = error as? APIv2Error else { return false }
        switch error {
        case .httpStatus(let status): return [403, 404].contains(status)
        case .problem(let problem): return [403, 404].contains(problem.status)
        default: return false
        }
    }

    static let unavailableMessage = "This title isn't available to your profile, so it can't play on this device."

    private func handlePlaybackFailure(reason: String?, message: String, context: WatchPartyPlaybackContext) {
        errorMessage = selectedItemUnavailable ? Self.unavailableMessage : message
        guard supportsFallback, let reason, let fallback = WatchPartySourceFallbackReason(rawValue: reason),
              let auth, let room, room.selectionRevision == context.selectionRevision else { return }
        let owner = engagement
        let receipt = state.receipt
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.api.watchPartySourceFallback(roomId: room.roomId, token: self.roomToken,
                    selectionRevision: context.selectionRevision, failedFileId: String(context.fileId), reason: fallback, auth: auth)
                guard await self.validateIdentity(), owner == self.engagement, self.playbackContext == context else { return }
                self.roomToken = response.roomAccessToken
                self.accept(response.room, requestReceipt: receipt)
            } catch { /* Retain the original playback refusal when no fallback exists. */ }
        }
    }
    private func trace(_ event: @autoclosure () -> String) {
        #if DEBUG
        if CommandLine.arguments.contains("-debugWatchPartyTrace") {
            print("[WatchParty] \(event())")
            fflush(stdout)
        }
        #endif
    }

}
