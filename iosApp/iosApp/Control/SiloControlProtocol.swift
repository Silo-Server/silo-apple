import Foundation

enum SiloControlProtocol {
    static let version = 2
    static let supportedVersions = [1, 2]
    static let serviceType = "_silocast._tcp"

    static func negotiatedVersion(with peer: [Int]) -> Int? {
        supportedVersions.filter(peer.contains).max()
    }
}

enum SiloControlPeerRole: String, Codable, Equatable, Sendable {
    case phone
    case tv
}

struct SiloControlHello: Codable, Equatable, Sendable {
    let role: SiloControlPeerRole
    let deviceName: String
    let deviceId: String
    let serverId: String?
    let serverName: String?
    let supportedVersions: [Int]
}

struct SiloControlPlaybackRequest: Codable, Equatable, Sendable {
    let contentId: String
    let fileId: Int?
    let audioTrackIndex: Int?
    let subtitleTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePosition: Double?
}

struct SiloControlLaunchRequest: Codable, Equatable, Sendable {
    let serverId: String
    let playback: SiloControlPlaybackRequest
}

struct SiloControlHandoffOffer: Codable, Equatable, Sendable {
    let requestId: String
    let serverId: String
    let serverURL: String
    let serverName: String?
    let profileId: String
    /// Display-only label for the verified profile ID. Older peers omit it.
    let profileName: String?
}

struct SiloControlHandoffChallenge: Codable, Equatable, Sendable {
    let requestId: String
    let userCode: String
    let matchCode: String
    let expiresAt: String
}

struct SiloControlHandoffReady: Codable, Equatable, Sendable {
    let requestId: String
    let serverId: String
    let profileId: String
    let sessionExpiresAt: String
    let reused: Bool
}

struct SiloControlHandoffCancel: Codable, Equatable, Sendable {
    let requestId: String
    let reason: String
    let message: String?
}

struct SiloControlTrack: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let trackId: Int64
    let title: String
    let detail: String?

    var id: String { "\(kind)-\(trackId)" }
}

struct SiloControlOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String?
}

struct SiloControlPlaybackState: Codable, Equatable, Sendable {
    let contentId: String?
    let sessionId: String?
    let title: String
    let subtitle: String?
    let isPlaying: Bool
    let isLoading: Bool
    let isBuffering: Bool
    let currentTime: Double
    let duration: Double
    let audioTracks: [SiloControlTrack]
    let subtitleTracks: [SiloControlTrack]
    let selectedAudioTrackId: Int64?
    let selectedSubtitleTrackId: Int64?
    let qualityOptions: [SiloControlOption]
    let activeQualityId: String
    let isQualitySwitching: Bool
    let playbackSpeed: Double
    let videoGravity: String
    let hdrEnabled: Bool
    let supportsVideoGravity: Bool
    /// v2 WIRE COMPATIBILITY — do not remove without bumping
    /// `SiloControlProtocol.version`.
    ///
    /// This build dropped the HDR toggle, but v2 peers that predate the removal
    /// still require the key: Android's `SiloCastPlaybackState.supportsHDRToggle`
    /// is a non-null `Boolean` with no kotlinx default, and older Apple builds
    /// declared it non-optional too, so omitting it makes their whole state
    /// frame fail to decode — which tears the session down, not just the field.
    /// Always encoded as `false`, which is also the truth: this build has no
    /// toggle to offer, so old peers correctly hide the control. Declared
    /// `Optional` so an inbound frame that omits it still decodes. Nothing on
    /// this side reads it.
    var supportsHDRToggle: Bool? = false
    var subtitleSyncMs: Int? = nil
    var subtitlePosition: String? = nil
    var supportsSubtitleDelay: Bool? = nil
    var supportsSubtitlePosition: Bool? = nil
    // `var` so the iOS remote can apply optimistic volume/mute updates between
    // TV state acknowledgements.
    var volume: Double
    var isMuted: Bool
    let hasNextEpisode: Bool
    let nextEpisodeTitle: String?
    let error: String?
}

/// Thrown by `SiloControlCommand.init(from:)` for a command name this build
/// doesn't implement. `SiloControlMessage`'s decoder catches it and yields
/// `.unsupportedControl`, so an unknown name degrades to one ignored command
/// instead of a fatal frame decode error.
struct SiloControlUnsupportedCommand: Error, Equatable, Sendable {
    let name: String
}

struct SiloControlCommand: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable {
        case play
        case pause
        case playPause = "play_pause"
        case seek
        case stop
        case selectAudioTrack = "select_audio_track"
        case selectSubtitleTrack = "select_subtitle_track"
        case setPlaybackSpeed = "set_playback_speed"
        case setQuality = "set_quality"
        case setVideoGravity = "set_video_gravity"
        case setSubtitleSyncMs = "set_subtitle_sync_ms"
        case setSubtitlePosition = "set_subtitle_position"
        case setVolume = "set_volume"
        case setMuted = "set_muted"
        case playNext = "play_next"
    }

    let name: Name
    let seconds: Double?
    let trackId: Int64?
    let speed: Double?
    let volume: Double?
    let value: String?
    let enabled: Bool?
    let milliseconds: Int?

    init(
        name: Name,
        seconds: Double? = nil,
        trackId: Int64? = nil,
        speed: Double? = nil,
        volume: Double? = nil,
        value: String? = nil,
        enabled: Bool? = nil,
        milliseconds: Int? = nil
    ) {
        self.name = name
        self.seconds = seconds
        self.trackId = trackId
        self.speed = speed
        self.volume = volume
        self.value = value
        self.enabled = enabled
        self.milliseconds = milliseconds
    }

    // Explicit keys matching the previously synthesized ones, so the wire
    // format is unchanged. `encode(to:)` stays synthesized against them.
    fileprivate enum CodingKeys: String, CodingKey {
        case name, seconds, trackId, speed, volume, value, enabled, milliseconds
    }

    /// Decodes `name` as a raw string rather than letting the `Name` enum
    /// reject it. A v2 peer built before a command was retired (e.g. the
    /// removed `set_hdr_enabled`) still sends it after a successful v2
    /// handshake; the synthesized enum decoder would throw a
    /// `DecodingError`, and `FramedJSONSession` tears the whole connection
    /// down on any decode error. Surfacing a typed error instead lets the
    /// message decoder downgrade it to an ignorable command.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try c.decode(String.self, forKey: .name)
        guard let name = Name(rawValue: rawName) else {
            throw SiloControlUnsupportedCommand(name: rawName)
        }
        self.name = name
        self.seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        self.trackId = try c.decodeIfPresent(Int64.self, forKey: .trackId)
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed)
        self.volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        self.value = try c.decodeIfPresent(String.self, forKey: .value)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        self.milliseconds = try c.decodeIfPresent(Int.self, forKey: .milliseconds)
    }

    static let play = SiloControlCommand(name: .play)
    static let pause = SiloControlCommand(name: .pause)
    static let playPause = SiloControlCommand(name: .playPause)
    static let stop = SiloControlCommand(name: .stop)

    static func seek(seconds: Double) -> SiloControlCommand {
        SiloControlCommand(name: .seek, seconds: seconds)
    }

    static func selectAudioTrack(_ trackId: Int64) -> SiloControlCommand {
        SiloControlCommand(name: .selectAudioTrack, trackId: trackId)
    }

    static func selectSubtitleTrack(_ trackId: Int64?) -> SiloControlCommand {
        SiloControlCommand(name: .selectSubtitleTrack, trackId: trackId)
    }

    static func setPlaybackSpeed(_ speed: Double) -> SiloControlCommand {
        SiloControlCommand(name: .setPlaybackSpeed, speed: speed)
    }

    static func setQuality(_ qualityId: String) -> SiloControlCommand {
        SiloControlCommand(name: .setQuality, value: qualityId)
    }

    static func setVideoGravity(_ value: String) -> SiloControlCommand {
        SiloControlCommand(name: .setVideoGravity, value: value)
    }

    static func setSubtitleSyncMs(_ milliseconds: Int) -> SiloControlCommand {
        SiloControlCommand(name: .setSubtitleSyncMs, milliseconds: milliseconds)
    }

    static func setSubtitlePosition(_ value: String) -> SiloControlCommand {
        SiloControlCommand(name: .setSubtitlePosition, value: value)
    }

    static let playNext = SiloControlCommand(name: .playNext)

    static func setVolume(_ volume: Double) -> SiloControlCommand {
        SiloControlCommand(name: .setVolume, volume: volume)
    }

    static func setMuted(_ muted: Bool) -> SiloControlCommand {
        SiloControlCommand(name: .setMuted, enabled: muted)
    }
}

struct SiloControlErrorMessage: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

enum SiloControlMessage: Equatable, Sendable {
    case hello(SiloControlHello)
    case handoffOffer(SiloControlHandoffOffer)
    case handoffChallenge(SiloControlHandoffChallenge)
    case handoffReady(SiloControlHandoffReady)
    case handoffCancel(SiloControlHandoffCancel)
    case launch(SiloControlLaunchRequest)
    case control(SiloControlCommand)
    /// A well-formed `control` frame naming a command this build doesn't
    /// implement — typically a v2 peer that predates the command's removal.
    /// Receivers ignore it; the connection survives.
    case unsupportedControl(name: String)
    case state(SiloControlPlaybackState)
    case error(SiloControlErrorMessage)
    case ping
    case pong
    case close
}

extension SiloControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, v
        case hello, launch, control, state, error
        case handoffOffer, handoffChallenge, handoffReady, handoffCancel
    }

    private enum Kind: String, Codable {
        case hello
        case handoffOffer = "handoff_offer"
        case handoffChallenge = "handoff_challenge"
        case handoffReady = "handoff_ready"
        case handoffCancel = "handoff_cancel"
        case launch
        case control
        case state
        case error
        case ping
        case pong
        case close
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(SiloControlProtocol.version, forKey: .v)
        switch self {
        case .hello(let hello):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(hello, forKey: .hello)
        case .handoffOffer(let offer):
            try c.encode(Kind.handoffOffer, forKey: .type)
            try c.encode(offer, forKey: .handoffOffer)
        case .handoffChallenge(let challenge):
            try c.encode(Kind.handoffChallenge, forKey: .type)
            try c.encode(challenge, forKey: .handoffChallenge)
        case .handoffReady(let ready):
            try c.encode(Kind.handoffReady, forKey: .type)
            try c.encode(ready, forKey: .handoffReady)
        case .handoffCancel(let cancel):
            try c.encode(Kind.handoffCancel, forKey: .type)
            try c.encode(cancel, forKey: .handoffCancel)
        case .launch(let launch):
            try c.encode(Kind.launch, forKey: .type)
            try c.encode(launch, forKey: .launch)
        case .control(let control):
            try c.encode(Kind.control, forKey: .type)
            try c.encode(control, forKey: .control)
        case .unsupportedControl(let name):
            // Re-emit the original name so the frame stays a valid `control`
            // and round-trips back to `.unsupportedControl`. Arguments are
            // dropped: this build can't interpret them.
            try c.encode(Kind.control, forKey: .type)
            var command = c.nestedContainer(keyedBy: SiloControlCommand.CodingKeys.self,
                                            forKey: .control)
            try command.encode(name, forKey: .name)
        case .state(let state):
            try c.encode(Kind.state, forKey: .type)
            try c.encode(state, forKey: .state)
        case .error(let error):
            try c.encode(Kind.error, forKey: .type)
            try c.encode(error, forKey: .error)
        case .ping:
            try c.encode(Kind.ping, forKey: .type)
        case .pong:
            try c.encode(Kind.pong, forKey: .type)
        case .close:
            try c.encode(Kind.close, forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .hello:
            self = .hello(try c.decode(SiloControlHello.self, forKey: .hello))
        case .handoffOffer:
            self = .handoffOffer(try c.decode(SiloControlHandoffOffer.self, forKey: .handoffOffer))
        case .handoffChallenge:
            self = .handoffChallenge(try c.decode(SiloControlHandoffChallenge.self, forKey: .handoffChallenge))
        case .handoffReady:
            self = .handoffReady(try c.decode(SiloControlHandoffReady.self, forKey: .handoffReady))
        case .handoffCancel:
            self = .handoffCancel(try c.decode(SiloControlHandoffCancel.self, forKey: .handoffCancel))
        case .launch:
            self = .launch(try c.decode(SiloControlLaunchRequest.self, forKey: .launch))
        case .control:
            do {
                self = .control(try c.decode(SiloControlCommand.self, forKey: .control))
            } catch let unsupported as SiloControlUnsupportedCommand {
                self = .unsupportedControl(name: unsupported.name)
            }
        case .state:
            self = .state(try c.decode(SiloControlPlaybackState.self, forKey: .state))
        case .error:
            self = .error(try c.decode(SiloControlErrorMessage.self, forKey: .error))
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        case .close:
            self = .close
        }
    }
}
