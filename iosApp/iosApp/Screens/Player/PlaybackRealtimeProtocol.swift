import Foundation

enum PlaybackRealtimeMessageType: String, Codable {
    case command
    case event
    case hello
    case ack
    case result
}

enum PlaybackRealtimeCommandName: String, Codable, CaseIterable {
    case pause
    case unpause
    case playPause = "play_pause"
    case seek
    case setVolume = "set_volume"
    case stop
    case terminate
    case displayMessage = "display_message"
    case serverRestarting = "server_restarting"
    case serverShuttingDown = "server_shutting_down"
    case playMedia = "play_media"
    case setAudioTrack = "set_audio_track"
    case setSubtitleTrack = "set_subtitle_track"
}

let supportedApplePlaybackRealtimeCommands: [PlaybackRealtimeCommandName] = [
    .pause,
    .unpause,
    .playPause,
    .seek,
    .stop,
    .terminate,
    .displayMessage,
    .serverRestarting,
    .serverShuttingDown,
]

/// Names of `type:"event"` envelopes the server pushes over the playback
/// control websocket.
///
/// Tolerant by design: the raw enum used to be strict (`String`-backed), so
/// an unrecognized event name failed to decode the whole envelope and the
/// event was silently dropped — a future server event would simply vanish.
/// This is now a custom-decoded enum with an ``unknown(_:)`` fallback, so
/// every well-formed `event` envelope decodes; consumers switch on the known
/// cases and ignore ``unknown(_:)``. New cases can be added here without
/// changing the parser.
enum PlaybackRealtimeEventName: Codable, Equatable {
    case chapterThumbnailReady
    case markersUpdated
    // AI subtitle live-streaming events (Milestone 4). These ride the same
    // socket; payloads are decoded by `PlaybackRealtimeSubtitleEvent`.
    case subtitleTranslationStarted
    case subtitleTranslationCues
    case subtitleTranslationCompleted
    case subtitleTranslationFailed
    case subtitleReady
    /// Any event name not recognized above. Carries the raw wire string so
    /// nothing is lost; current consumers ignore it.
    case unknown(String)

    /// The wire string for this event name.
    var rawValue: String {
        switch self {
        case .chapterThumbnailReady: return "chapter_thumbnail_ready"
        case .markersUpdated: return "markers_updated"
        case .subtitleTranslationStarted: return "subtitle_translation_started"
        case .subtitleTranslationCues: return "subtitle_translation_cues"
        case .subtitleTranslationCompleted: return "subtitle_translation_completed"
        case .subtitleTranslationFailed: return "subtitle_translation_failed"
        case .subtitleReady: return "subtitle_ready"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "chapter_thumbnail_ready": self = .chapterThumbnailReady
        case "markers_updated": self = .markersUpdated
        case "subtitle_translation_started": self = .subtitleTranslationStarted
        case "subtitle_translation_cues": self = .subtitleTranslationCues
        case "subtitle_translation_completed": self = .subtitleTranslationCompleted
        case "subtitle_translation_failed": self = .subtitleTranslationFailed
        case "subtitle_ready": self = .subtitleReady
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlaybackRealtimeEventName(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum PlaybackRealtimeAckStatus: String, Codable {
    case accepted
}

enum PlaybackRealtimeResultStatus: String, Codable {
    case completed
    case rejected
}

enum PlaybackRealtimeCommandExecutionError: Error {
    case unsupportedCommand
    case playerNotReady
    case missingSeekPosition
    case commandFailed

    var rejectionReason: String {
        switch self {
        case .unsupportedCommand:
            return "unsupported_command"
        case .playerNotReady:
            return "player_not_ready"
        case .missingSeekPosition:
            return "missing_seek_position"
        case .commandFailed:
            return "command_failed"
        }
    }
}

enum PlaybackRealtimeValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PlaybackRealtimeValue])
    case array([PlaybackRealtimeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: PlaybackRealtimeValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([PlaybackRealtimeValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                PlaybackRealtimeValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported realtime JSON payload value"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

typealias PlaybackRealtimePayload = [String: PlaybackRealtimeValue]

extension Dictionary where Key == String, Value == PlaybackRealtimeValue {
    func string(forKeys keys: String...) -> String? {
        for key in keys {
            if case .string(let value)? = self[key] {
                return value
            }
        }
        return nil
    }

    func number(forKeys keys: String...) -> Double? {
        for key in keys {
            if case .number(let value)? = self[key] {
                return value
            }
        }
        return nil
    }

    func int(forKeys keys: String...) -> Int? {
        for key in keys {
            if case .number(let value)? = self[key], value.isFinite {
                return Int(value)
            }
        }
        return nil
    }

    func timeRange(forKey key: String) -> TimeRange? {
        guard case .object(let object)? = self[key],
              case .number(let start)? = object["start"],
              case .number(let end)? = object["end"],
              start.isFinite,
              end.isFinite,
              end > start else {
            return nil
        }
        return TimeRange(start: start, end: end)
    }

    func markerRangeUpdate(forKey key: String) -> PlaybackRealtimeMarkerRangeUpdate {
        guard let value = self[key] else {
            return .unchanged
        }
        if case .null = value {
            return .clear
        }
        guard let range = timeRange(forKey: key) else {
            return .unchanged
        }
        return .set(range)
    }
}

struct PlaybackRealtimeCommandEnvelope: Decodable, Equatable {
    let type: PlaybackRealtimeMessageType
    let commandId: String
    let sessionId: String
    let name: PlaybackRealtimeCommandName
    let reason: String?
    let issuedBy: PlaybackRealtimeIssuedBy?
    let deadlineMS: Int?
    let payload: PlaybackRealtimePayload

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case sessionId = "session_id"
        case name
        case reason
        case issuedBy = "issued_by"
        case deadlineMS = "deadline_ms"
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(PlaybackRealtimeMessageType.self, forKey: .type)
        commandId = try container.decode(String.self, forKey: .commandId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decode(PlaybackRealtimeCommandName.self, forKey: .name)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        issuedBy = try container.decodeIfPresent(PlaybackRealtimeIssuedBy.self, forKey: .issuedBy)
        deadlineMS = try container.decodeIfPresent(Int.self, forKey: .deadlineMS)
        payload = try container.decodeIfPresent(PlaybackRealtimePayload.self, forKey: .payload) ?? [:]
    }
}

struct PlaybackRealtimeIssuedBy: Decodable, Equatable {
    let kind: String
}

struct PlaybackRealtimeEventEnvelope: Decodable, Equatable {
    let type: PlaybackRealtimeMessageType
    let sessionId: String
    let name: PlaybackRealtimeEventName
    let payload: PlaybackRealtimePayload

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case name
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(PlaybackRealtimeMessageType.self, forKey: .type)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decode(PlaybackRealtimeEventName.self, forKey: .name)
        payload = try container.decodeIfPresent(PlaybackRealtimePayload.self, forKey: .payload) ?? [:]
    }
}

struct PlaybackRealtimeMarkersUpdatedPayload: Equatable {
    let sessionId: String?
    let fileId: Int
    let intro: TimeRange?
    let credits: TimeRange?
    let introUpdate: PlaybackRealtimeMarkerRangeUpdate
    let creditsUpdate: PlaybackRealtimeMarkerRangeUpdate

    init?(payload: PlaybackRealtimePayload) {
        guard let fileId = payload.int(forKeys: "file_id", "fileId") else {
            return nil
        }
        self.sessionId = payload.string(forKeys: "session_id", "sessionId")
        self.fileId = fileId
        introUpdate = payload.markerRangeUpdate(forKey: "intro")
        creditsUpdate = payload.markerRangeUpdate(forKey: "credits")
        self.intro = introUpdate.range
        self.credits = creditsUpdate.range
    }
}

enum PlaybackRealtimeMarkerRangeUpdate: Equatable {
    case unchanged
    case clear
    case set(TimeRange)

    var range: TimeRange? {
        guard case .set(let range) = self else {
            return nil
        }
        return range
    }

    func resolving(current: TimeRange?) -> TimeRange? {
        switch self {
        case .unchanged:
            return current
        case .clear:
            return nil
        case .set(let range):
            return range
        }
    }
}

enum PlaybackRealtimeInboundMessage: Equatable {
    case command(PlaybackRealtimeCommandEnvelope)
    case event(PlaybackRealtimeEventEnvelope)
}

struct PlaybackRealtimeHelloEnvelope: Encodable {
    let type: PlaybackRealtimeMessageType = .hello
    let sessionId: String
    let client: PlaybackRealtimeClientInfo
    let capabilities: PlaybackRealtimeCapabilities

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case client
        case capabilities
    }
}

struct PlaybackRealtimeClientInfo: Encodable {
    let name: String
    let version: String
}

struct PlaybackRealtimeCapabilities: Encodable {
    let commands: [PlaybackRealtimeCommandName]
}

struct PlaybackRealtimeAckEnvelope: Encodable {
    let type: PlaybackRealtimeMessageType = .ack
    let commandId: String
    let sessionId: String
    let status: PlaybackRealtimeAckStatus = .accepted

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case sessionId = "session_id"
        case status
    }
}

struct PlaybackRealtimeResultEnvelope: Encodable {
    let type: PlaybackRealtimeMessageType = .result
    let commandId: String
    let sessionId: String
    let status: PlaybackRealtimeResultStatus
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case sessionId = "session_id"
        case status
        case error
    }
}

func parsePlaybackRealtimeInboundMessage(_ data: Data) -> PlaybackRealtimeInboundMessage? {
    do {
        let decoder = JSONDecoder()
        let base = try decoder.decode(PlaybackRealtimeBaseEnvelope.self, from: data)
        switch base.type {
        case .command:
            return .command(try decoder.decode(PlaybackRealtimeCommandEnvelope.self, from: data))
        case .event:
            return .event(try decoder.decode(PlaybackRealtimeEventEnvelope.self, from: data))
        default:
            return nil
        }
    } catch {
        return nil
    }
}

func makePlaybackRealtimeHello(sessionId: String) -> PlaybackRealtimeHelloEnvelope {
    PlaybackRealtimeHelloEnvelope(
        sessionId: sessionId,
        client: PlaybackRealtimeClientInfo(
            name: applePlaybackRealtimeClientName,
            version: "1"
        ),
        capabilities: PlaybackRealtimeCapabilities(commands: supportedApplePlaybackRealtimeCommands)
    )
}

func makePlaybackRealtimeAck(sessionId: String, commandId: String) -> PlaybackRealtimeAckEnvelope {
    PlaybackRealtimeAckEnvelope(commandId: commandId, sessionId: sessionId)
}

func makePlaybackRealtimeResult(
    sessionId: String,
    commandId: String,
    status: PlaybackRealtimeResultStatus,
    error: String? = nil
) -> PlaybackRealtimeResultEnvelope {
    PlaybackRealtimeResultEnvelope(
        commandId: commandId,
        sessionId: sessionId,
        status: status,
        error: error
    )
}

private struct PlaybackRealtimeBaseEnvelope: Decodable {
    let type: PlaybackRealtimeMessageType
}

// Stable protocol-level client ids, deliberately NOT the human-facing
// `X-Silo-Client` product names: the server has stored these since Continuum
// and only checks that they are non-empty. macOS previously fell through to
// the iOS id, so a Mac session announced itself as iOS on the realtime socket
// while its HTTP headers said `Silo Mac` — the same session named two
// contradictory ways.
#if os(tvOS)
private let applePlaybackRealtimeClientName = "continuum-tvos"
#elseif os(macOS)
private let applePlaybackRealtimeClientName = "continuum-macos"
#else
private let applePlaybackRealtimeClientName = "continuum-ios"
#endif
