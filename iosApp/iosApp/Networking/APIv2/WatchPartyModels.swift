import Foundation

enum WatchPartyPhase: APIv2StringEnum {
    case lobby, playing, ended, unknown(String)
    static let known: [String: Self] = ["lobby": .lobby, "playing": .playing, "ended": .ended]
    var wireValue: String {
        switch self { case .lobby: return "lobby"; case .playing: return "playing"; case .ended: return "ended"; case .unknown(let value): return value }
    }
}

enum WatchPartyPlaybackState: APIv2StringEnum {
    case idle, waiting, paused, playing, unknown(String)
    static let known: [String: Self] = ["idle": .idle, "waiting": .waiting, "paused": .paused, "playing": .playing]
    var wireValue: String {
        switch self { case .idle: return "idle"; case .waiting: return "waiting"; case .paused: return "paused"; case .playing: return "playing"; case .unknown(let value): return value }
    }
}

enum WatchPartySelectionMode: APIv2StringEnum {
    case hostPick, vote, unknown(String)
    static let known: [String: Self] = ["host_pick": .hostPick, "vote": .vote]
    var wireValue: String {
        switch self { case .hostPick: return "host_pick"; case .vote: return "vote"; case .unknown(let value): return value }
    }
}

enum WatchPartyGuestControlPolicy: APIv2StringEnum {
    case hostOnly, guestPlayPause, unknown(String)
    static let known: [String: Self] = ["host_only": .hostOnly, "guest_play_pause": .guestPlayPause]
    var wireValue: String {
        switch self { case .hostOnly: return "host_only"; case .guestPlayPause: return "guest_play_pause"; case .unknown(let value): return value }
    }
}

enum WatchPartyMemberRole: APIv2StringEnum {
    case host, guest, unknown(String)
    static let known: [String: Self] = ["host": .host, "guest": .guest]
    var wireValue: String {
        switch self { case .host: return "host"; case .guest: return "guest"; case .unknown(let value): return value }
    }
}

enum WatchPartyTransportAction: APIv2StringEnum {
    case play, pause, seek, unknown(String)
    static let known: [String: Self] = ["play": .play, "pause": .pause, "seek": .seek]
    var wireValue: String {
        switch self { case .play: return "play"; case .pause: return "pause"; case .seek: return "seek"; case .unknown(let value): return value }
    }
}

struct WatchPartyCapabilities: Codable, Equatable, Sendable {
    var revision = ""
    var state = "unsupported"
    var allowed: Bool? = nil
    var stagedSelection = false
    var lobbyReady = false
    var connectionReplaced = false
    var selectionModeSwitch = false
    var memberState = false
    var picker = false
    var voteHostOverride = false
    var stopPlayback = false
    var maxMemberStateIds = 0
    var socketProtocol = ""

    var isAvailable: Bool { state == "available" && allowed == true }
    var supportsSocket: Bool { isAvailable && socketProtocol == "silo.room.v2" }
}

extension WatchPartyCapabilities {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        state = try c.decode(String.self, forKey: .state)
        allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed)
        stagedSelection = try c.decodeIfPresent(Bool.self, forKey: .stagedSelection) ?? false
        lobbyReady = try c.decodeIfPresent(Bool.self, forKey: .lobbyReady) ?? false
        connectionReplaced = try c.decodeIfPresent(Bool.self, forKey: .connectionReplaced) ?? false
        selectionModeSwitch = try c.decodeIfPresent(Bool.self, forKey: .selectionModeSwitch) ?? false
        memberState = try c.decodeIfPresent(Bool.self, forKey: .memberState) ?? false
        picker = try c.decodeIfPresent(Bool.self, forKey: .picker) ?? false
        voteHostOverride = try c.decodeIfPresent(Bool.self, forKey: .voteHostOverride) ?? false
        stopPlayback = try c.decodeIfPresent(Bool.self, forKey: .stopPlayback) ?? false
        maxMemberStateIds = try c.decodeIfPresent(Int.self, forKey: .maxMemberStateIds) ?? 0
        socketProtocol = try c.decodeIfPresent(String.self, forKey: .socketProtocol) ?? ""
    }
}

struct WatchPartyRoom: Codable, Equatable, Sendable, Identifiable {
    var roomId: String
    var phase: WatchPartyPhase = .lobby
    var playbackState: WatchPartyPlaybackState = .idle
    var selectionMode: WatchPartySelectionMode = .hostPick
    var selectionRevision: Int64 = 0
    var selectedContentId: String? = nil
    var selectedFileId: String? = nil
    var selectedLibraryId: String? = nil
    var code = ""
    var guestControlPolicy: WatchPartyGuestControlPolicy = .hostOnly
    var isPaused = true
    var anchorPositionSeconds: Double = 0
    var anchorUpdatedAt: Date = .distantPast
    var generation: Int64 = 0
    var memberCount = 0
    var hostConnected = false
    var selfRole: WatchPartyMemberRole = .guest
    var selfCanControlTransport = false
    var selfCanManageRoom = false
    var selfIgnoreWait = false
    var attachedSessionId: String? = nil
    var invitePath: String? = nil
    var members: [WatchPartyMember] = []

    var id: String { roomId }
    var isPlaying: Bool { phase == .playing && !(selectedContentId?.isEmpty ?? true) }
}

extension WatchPartyRoom {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(String.self, forKey: .roomId)
        phase = try c.decode(WatchPartyPhase.self, forKey: .phase)
        playbackState = try c.decode(WatchPartyPlaybackState.self, forKey: .playbackState)
        selectionMode = try c.decode(WatchPartySelectionMode.self, forKey: .selectionMode)
        selectionRevision = try c.decode(Int64.self, forKey: .selectionRevision)
        selectedContentId = try c.decodeIfPresent(String.self, forKey: .selectedContentId)
        selectedFileId = try c.watchPartyIDIfPresent(.selectedFileId)
        selectedLibraryId = try c.watchPartyIDIfPresent(.selectedLibraryId)
        code = try c.decode(String.self, forKey: .code)
        guestControlPolicy = try c.decode(WatchPartyGuestControlPolicy.self, forKey: .guestControlPolicy)
        isPaused = try c.decode(Bool.self, forKey: .isPaused)
        anchorPositionSeconds = try c.decode(Double.self, forKey: .anchorPositionSeconds)
        anchorUpdatedAt = try c.decode(Date.self, forKey: .anchorUpdatedAt)
        generation = try c.decode(Int64.self, forKey: .generation)
        memberCount = try c.decode(Int.self, forKey: .memberCount)
        hostConnected = try c.decode(Bool.self, forKey: .hostConnected)
        selfRole = try c.decode(WatchPartyMemberRole.self, forKey: .selfRole)
        selfCanControlTransport = try c.decode(Bool.self, forKey: .selfCanControlTransport)
        selfCanManageRoom = try c.decode(Bool.self, forKey: .selfCanManageRoom)
        selfIgnoreWait = try c.decode(Bool.self, forKey: .selfIgnoreWait)
        attachedSessionId = try c.decodeIfPresent(String.self, forKey: .attachedSessionId)
        invitePath = try c.decodeIfPresent(String.self, forKey: .invitePath)
        members = try c.decodeIfPresent([WatchPartyMember].self, forKey: .members) ?? []
        guard !roomId.isEmpty, selectionRevision >= 0, generation >= 0,
              anchorPositionSeconds.isFinite, anchorPositionSeconds >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid room identity or timeline"))
        }
    }
}

struct WatchPartyMember: Codable, Equatable, Sendable, Identifiable {
    var userId: String
    var profileId: String
    var displayName: String
    var isHost = false
    var isSelf = false
    var connected = false
    var isReady = false
    var isBuffering = false
    var isSyncing = false
    var lobbyReady = false
    var id: String { "\(userId):\(profileId)" }
}

extension WatchPartyMember {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.watchPartyID(.userId)
        profileId = try c.decode(String.self, forKey: .profileId)
        displayName = try c.decode(String.self, forKey: .displayName)
        isHost = try c.decode(Bool.self, forKey: .isHost)
        isSelf = try c.decode(Bool.self, forKey: .isSelf)
        connected = try c.decode(Bool.self, forKey: .connected)
        isReady = try c.decodeIfPresent(Bool.self, forKey: .isReady) ?? false
        isBuffering = try c.decodeIfPresent(Bool.self, forKey: .isBuffering) ?? false
        isSyncing = try c.decodeIfPresent(Bool.self, forKey: .isSyncing) ?? false
        lobbyReady = try c.decodeIfPresent(Bool.self, forKey: .lobbyReady) ?? false
    }
}

struct WatchPartySuggestion: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var roomId: String
    var suggesterUserId: String
    var suggesterProfileId: String
    var contentId: String
    var contentType: String
    var title: String
    var subtitle = ""
    var posterUrl = ""
    var note = ""
    var voteCount = 0
    var votedByMe = false
    var createdAt: Date
}

extension WatchPartySuggestion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        roomId = try c.decode(String.self, forKey: .roomId)
        suggesterUserId = try c.watchPartyID(.suggesterUserId)
        suggesterProfileId = try c.decode(String.self, forKey: .suggesterProfileId)
        contentId = try c.decode(String.self, forKey: .contentId)
        contentType = try c.decode(String.self, forKey: .contentType)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        posterUrl = try c.decode(ArtworkURL.self, forKey: .posterUrl).wrappedValue ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        voteCount = try c.decode(Int.self, forKey: .voteCount)
        votedByMe = try c.decode(Bool.self, forKey: .votedByMe)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

struct WatchPartyTransportCommand: Codable, Equatable, Sendable {
    var commandId: String
    var sessionId: String? = nil
    var selectionRevision: Int64
    var action: WatchPartyTransportAction
    var positionSeconds: Double
    var executeAt: Date
    var issuedAt: Date
    var playbackState: WatchPartyPlaybackState
}

struct WatchPartyRoomResponse: Codable, Equatable, Sendable {
    var room: WatchPartyRoom
    var roomAccessToken: String
}

struct WatchPartySelection: Codable, Equatable, Sendable {
    var contentId: String
    var fileId: String? = nil
    var libraryId: String? = nil
}

struct WatchPartyNewSuggestion: Codable, Equatable, Sendable {
    var suggestionId: String = UUID().uuidString.lowercased()
    var contentId: String
    var contentType: String
    var title: String
    var subtitle: String? = nil
    var posterUrl: String? = nil
    var note: String? = nil
}

struct WatchPartySuggestionReceipt: Codable, Equatable, Sendable {
    var suggestionId: String
}

struct WatchPartySuggestionPage: Decodable, Sendable {
    var items: [WatchPartySuggestion]
    var page: APIv2Page
}

struct WatchPartySocketTicket: Codable, Equatable, Sendable {
    var ticket: String
    var expiresIn: Int
    var maxConnectionSeconds: Int
    var `protocol`: String
}

struct WatchPartyMemberState: Codable, Equatable, Sendable {
    var members: [WatchPartyMember]
    var items: [WatchPartyItemMemberState]
}

struct WatchPartyItemMemberState: Codable, Equatable, Sendable, Identifiable {
    var contentId: String
    var members: [WatchPartyMemberWatchState]
    var id: String { contentId }
}

struct WatchPartyMemberWatchState: Codable, Equatable, Sendable {
    var userId: String
    var profileId: String
    var state: String
    var positionSeconds: Double?
    var durationSeconds: Double?
    var onWatchlist: Bool
}

struct WatchPartyPicker: Codable, Sendable {
    var members: [WatchPartyMember]
    var continueTogether: [WatchPartyPickerEntry]
    var watchlistUnion: [WatchPartyPickerEntry]
}

struct WatchPartyPickerEntry: Codable, Sendable, Identifiable {
    var item: BrowseItem
    var members: [WatchPartyPickerMember]
    var nextUp: WatchPartyPickerNextUp?
    var id: String { item.contentId }
}

struct WatchPartyPickerMember: Codable, Equatable, Sendable {
    var userId: String
    var profileId: String
    var displayName: String
    var positionSeconds: Double?
    var durationSeconds: Double?
}

struct WatchPartyPickerNextUp: Codable, Equatable, Sendable {
    var contentId: String
    var seasonNumber: Int
    var episodeNumber: Int
    var title: String?
    var memberCount: Int
}

enum WatchPartySourceFallbackReason: String, Codable, Sendable {
    case noAlternateVersion = "no_alternate_version"
    case hdrTranscodeUnsupported = "hdr_transcode_unsupported"
    case subtitleConversionUnsupported = "subtitle_conversion_unsupported"
    case transcodingDisabled = "transcoding_disabled"
}

/// Only these numeric legacy socket fields accept two representations. HTTP
/// request encoding remains string-only and opaque content IDs stay strings.
private extension KeyedDecodingContainer {
    func watchPartyID(_ key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) { return string }
        return String(try decode(Int64.self, forKey: key))
    }

    func watchPartyIDIfPresent(_ key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try watchPartyID(key)
    }
}
