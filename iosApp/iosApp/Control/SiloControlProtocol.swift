import Foundation

enum SiloControlProtocol {
    static let version = 2
    static let supportedVersions = [1, 2]
    static let serviceType = "_silocast._tcp"
    /// The Roku receiver's own advertisement. A separate type, because a
    /// Roku can't speak TLS and phones that only do aren't to list it.
    static let rokuServiceType = "_silocast-roku._tcp"

    static func negotiatedVersion(with peer: [Int]) -> Int? {
        supportedVersions.filter(peer.contains).max()
    }
}

/// Optional behaviors a peer lists in its hello. Each side uses one only when
/// the other side listed it too, so new fields, payloads and reasons never
/// reach a build that would misread them. Peers ignore names they don't know.
enum SiloControlFeature {
    /// The receiver keeps other controllers connected. A `close` from it
    /// concerns this controller alone, never a takeover.
    static let multiController = "multi_controller"
    /// `close` may carry a reason (`SiloControlCloseReason`).
    static let closeReason = "close_reason"
    /// The receiver issues `resumeToken` in `handoff_ready`; the controller
    /// sends it back to reuse that identity from a later connection.
    static let resumeToken = "resume_token"
    /// The receiver refuses a handoff that would replace another profile's
    /// title with `handoff_cancel` reason `replace_confirmation_required`,
    /// and the controller resends with `replaceConfirmed` after asking.
    static let replaceConfirmation = "replace_confirmation"
    /// The receiver accepts `presence`, so a controller can change its
    /// `passive` flag without reconnecting.
    static let presence = "presence"
    /// The receiver can only mute, not set a level (Roku), so the
    /// controller offers a mute toggle instead of a volume slider.
    static let volumeMuteOnly = "volume_mute_only"
    /// The receiver can't change playback speed (Roku), so the controller
    /// hides its speed menu.
    static let noPlaybackSpeed = "no_playback_speed"

    static let receiverFeatures = [multiController, closeReason, resumeToken, replaceConfirmation, presence]
    static let phoneFeatures = [closeReason, resumeToken, replaceConfirmation]
}

/// Why a peer closed the session. Sent only to peers that list
/// `SiloControlFeature.closeReason`.
enum SiloControlCloseReason {
    /// A newer connection from the same device took this one's place.
    static let replaced = "replaced"
    /// Someone disconnected remote control on the TV.
    static let tvDisconnected = "tv_disconnected"
    /// The receiver is at its controller limit.
    static let tooManyControllers = "too_many_controllers"
    /// The peer never sent hello, or stopped answering pings.
    static let timeout = "timeout"
    /// The peer can't be authorized (version or server mismatch).
    static let unauthorized = "unauthorized"
    /// A borrowed profile was never used and has been handed back.
    static let launchTimeout = "launch_timeout"
}

/// Values for `SiloControlHello.clientKind`. Absent means a Silo app.
enum SiloControlClientKind {
    /// A home-automation or other third-party integration.
    static let integration = "integration"
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
    /// The deployment identity behind `serverId` when the peer has learned
    /// it. Lets a phone and a TV on different addresses of one server
    /// recognise each other. Optional on the wire: older peers omit it.
    var serverIdentity: String? = nil
    /// `SiloControlFeature` names this peer supports. Absent from older
    /// peers, which support none of them.
    var features: [String]? = nil
    /// A controller that only watches state: a phone's silent auto-resume or
    /// an integration. It never puts up the TV's standby screen.
    var passive: Bool? = nil
    /// `SiloControlClientKind`. `role` stays `phone` for integrations,
    /// because shipped receivers fail to decode any other role.
    var clientKind: String? = nil

    func supports(_ feature: String) -> Bool {
        features?.contains(feature) == true
    }
}

struct SiloControlPlaybackRequest: Codable, Equatable, Sendable {
    let contentId: String
    let fileId: Int?
    let audioTrackIndex: Int?
    let subtitleTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePosition: Double?
    /// The viewer picked `fileId` in a version picker: the TV keeps that
    /// version. Older phones, and Android phones, omit it.
    var pinsVersion: Bool? = nil
}

struct SiloControlLaunchRequest: Codable, Equatable, Sendable {
    let serverId: String
    let playback: SiloControlPlaybackRequest
}

struct SiloControlHandoffOffer: Codable, Equatable, Sendable {
    let requestId: String
    /// The phone's registry key for the server. Echoed back in
    /// `handoff_ready` and used for the launch request.
    let serverId: String
    /// The phone's own address for the server. The TV treats it as one
    /// candidate among `serverEndpoints` when `serverIdentity` is present.
    let serverURL: String
    let serverName: String?
    let profileId: String
    /// Display-only label for the verified profile ID. Older peers omit it.
    let profileName: String?
    /// Display-only: what the phone is about to launch, for a TV that shows
    /// it while the handoff runs. Older peers omit and ignore it.
    var title: String? = nil
    /// The deployment identity the phone verified at `serverURL`. When
    /// present the TV may reach the server through any candidate address
    /// that reports the same identity. Absent from older phones, in which
    /// case the TV must use `serverURL` exactly.
    var serverIdentity: String? = nil
    /// Other addresses the deployment offers, from its connections document.
    /// Public first, then providers. Reachability is the TV's to test.
    var serverEndpoints: [ServerEndpoint]? = nil
    /// The token from an earlier `handoff_ready`, to reuse that identity
    /// from a new connection without another approval.
    var resumeToken: String? = nil
    /// The user agreed to replace a title another profile started, after the
    /// TV answered `replace_confirmation_required`.
    var replaceConfirmed: Bool? = nil
    /// With `replaceConfirmed`: the `contentId` of the title the user agreed
    /// to replace. The TV honors the confirmation only while that title is
    /// still the one on screen.
    var replacingContentId: String? = nil

    /// Whether `serverId` is the registry key of `serverURL`
    /// (`ServerRegistry.serverId(for:)`). A TV refuses an offer that fails
    /// this, so a phone must keep every saved server keyed by its URL.
    var serverIdMatchesURL: Bool {
        let url = ServerRegistry.normalize(url: serverURL)
        return !url.isEmpty && ServerRegistry.serverId(for: url) == serverId
    }
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
    /// Proof for reusing this identity from a later connection. Sent only to
    /// controllers that list `SiloControlFeature.resumeToken`, over the
    /// session's TLS channel; never shared with other controllers.
    var resumeToken: String? = nil
}

struct SiloControlHandoffCancel: Codable, Equatable, Sendable {
    let requestId: String
    let reason: String
    let message: String?
    /// With reason `replace_confirmation_required`: the title the handoff
    /// would replace, so the controller can ask its user.
    var nowPlaying: SiloControlNowPlayingSummary? = nil
}

enum SiloControlHandoffCancelReason {
    /// A newer handoff from another controller replaced this one, or another
    /// controller's identity is now active.
    static let superseded = "superseded"
    /// The handoff would replace a title another profile started. Resend the
    /// offer with `replaceConfirmed` once the user agrees.
    static let replaceConfirmationRequired = "replace_confirmation_required"
}

/// What a controller needs to ask "Replace what Alex is watching?".
struct SiloControlNowPlayingSummary: Codable, Equatable, Sendable {
    let contentId: String?
    let title: String
    let subtitle: String?
    let profileName: String?
    let controllerName: String?
}

/// The user's agreement to replace one particular title on the TV, carried
/// from the prompt to the offer's `replacingContentId`.
struct SiloControlReplaceConsent: Equatable, Sendable {
    /// The title the user saw when agreeing; nil when the TV didn't say.
    let contentId: String?
}

/// A controller's `passive` flag after hello. Sent only to receivers that
/// list `SiloControlFeature.presence`; older receivers drop the connection
/// on a message type they don't know.
struct SiloControlPresence: Codable, Equatable, Sendable {
    let passive: Bool
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
    /// v2 wire compatibility; keep until `SiloControlProtocol.version` bumps.
    /// Older v2 peers (Android `SiloCastPlaybackState`, earlier Apple builds)
    /// decode this as a required Bool, so omitting it fails the whole state
    /// frame and drops the session. Always `false` (no HDR toggle here);
    /// optional so frames without it still decode. Not read here.
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
    /// Absolute, signed poster URL for the playing title (the series poster
    /// for an episode), so an integration can fetch artwork without its own
    /// Silo sign-in. The TV re-signs it before it expires. Omitted when
    /// unknown; older peers ignore it.
    var posterUrl: String? = nil
    /// Synopsis of the playing title. Omitted when unknown.
    var overview: String? = nil
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

    // Wire keys. `encode(to:)` stays synthesized; fileprivate so
    // `SiloControlMessage` can re-encode `.unsupportedControl`.
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
    /// A frame whose `type` this build doesn't know — typically a newer peer
    /// using a message added after this build shipped. Receivers ignore it;
    /// the connection survives. A known `type` with a malformed payload is
    /// still a decode error.
    case unsupported(type: String)
    case state(SiloControlPlaybackState)
    case error(SiloControlErrorMessage)
    case presence(SiloControlPresence)
    case ping
    case pong
    /// `reason` is a `SiloControlCloseReason`, sent only to peers that list
    /// `SiloControlFeature.closeReason`; older peers get a bare `close`.
    case close(reason: String?)
}

/// The optional `close` payload.
private struct SiloControlClosePayload: Codable {
    let reason: String
}

extension SiloControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, v
        case hello, launch, control, state, error, close, presence
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
        case presence
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
        case .presence(let presence):
            try c.encode(Kind.presence, forKey: .type)
            try c.encode(presence, forKey: .presence)
        case .ping:
            try c.encode(Kind.ping, forKey: .type)
        case .pong:
            try c.encode(Kind.pong, forKey: .type)
        case .close(let reason):
            try c.encode(Kind.close, forKey: .type)
            if let reason {
                try c.encode(SiloControlClosePayload(reason: reason), forKey: .close)
            }
        case .unsupported(let type):
            // Re-emit the original type so the frame round-trips back to
            // `.unsupported`. The payload is dropped: this build can't
            // interpret it.
            try c.encode(type, forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode `type` as a raw string rather than letting the `Kind` enum
        // reject it: `FramedJSONSession` tears the connection down on any
        // decode error, so one frame from a newer peer would end the session.
        let rawType = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: rawType) else {
            self = .unsupported(type: rawType)
            return
        }
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
        case .presence:
            self = .presence(try c.decode(SiloControlPresence.self, forKey: .presence))
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        case .close:
            let payload = try? c.decodeIfPresent(SiloControlClosePayload.self, forKey: .close)
            self = .close(reason: payload?.reason)
        }
    }
}
