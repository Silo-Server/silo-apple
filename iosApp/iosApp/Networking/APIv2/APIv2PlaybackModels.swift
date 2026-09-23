import Foundation

/// `POST /api/v2/playback/start`. The server refuses unknown members, so the
/// body is exactly the v3 start plus `installation_id`, with `file_id` as the
/// opaque string the v2 schema declares.
struct APIv2PlaybackStartBody: Encodable {
    let installationId: String
    let protocolVersion: Int
    let clientFeatures: [String]
    let fileId: String
    let profileId: String
    let playbackAttemptId: String
    let qualityPreference: String
    let subtitleFidelityPreference: String
    let progressPersistence: String?
    let startPosition: Double?
    let audioTrackId: String?
    let audioTrackIndex: Int?
    let subtitleTrackId: String?
    let subtitleTrackIndex: Int?
    let metered: Bool
    let bandwidthEstimateKbps: Int?
    let bandwidthCapKbps: Int?
    let clientCapabilities: PlaybackV3CodecCapabilities
    let clientPlaybackContext: PlaybackV3ClientContext

    init(_ request: PlaybackV3StartRequest, installationID: String) {
        installationId = installationID
        protocolVersion = request.protocolVersion
        clientFeatures = request.clientFeatures
        fileId = String(request.fileId)
        profileId = request.profileId
        playbackAttemptId = request.playbackAttemptId
        qualityPreference = request.qualityPreference
        subtitleFidelityPreference = request.subtitleFidelityPreference
        progressPersistence = request.progressPersistence
        startPosition = request.startPosition
        audioTrackId = request.audioTrackId
        audioTrackIndex = request.audioTrackIndex
        subtitleTrackId = request.subtitleTrackId
        subtitleTrackIndex = request.subtitleTrackIndex
        metered = request.metered
        bandwidthEstimateKbps = request.bandwidthEstimateKbps
        bandwidthCapKbps = request.bandwidthCapKbps
        clientCapabilities = request.clientCapabilities
        clientPlaybackContext = request.clientPlaybackContext
    }
}

struct APIv2PlaybackSource: Codable {
    let mediaFileId: String
    let durationSeconds: Double?
    let container: String?
    let videoCodec: String?
    let videoProfile: String?
    let videoLevel: Int?
    let bitDepth: Int?
    let colorRange: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrateKbps: Int?
    let dynamicRange: String?
    let hdr10Plus: Bool
    let dolbyVisionProfile: Int?
    let dvBlCompatId: Int?
    let dvEnhancementLayer: String
    let audioCodec: String?
    let audioChannels: Int?
    let audioLayout: String?
    let videoCopyUnsafe: Bool?

    func legacy() throws -> PlaybackV3SourceDescriptor {
        PlaybackV3SourceDescriptor(
            mediaFileId: try APIv2PlaybackID.legacy(mediaFileId),
            durationSeconds: durationSeconds,
            container: container,
            videoCodec: videoCodec,
            videoProfile: videoProfile,
            videoLevel: videoLevel,
            bitDepth: bitDepth,
            colorRange: colorRange,
            width: width,
            height: height,
            frameRate: frameRate,
            bitrateKbps: bitrateKbps,
            dynamicRange: dynamicRange,
            hdr10Plus: hdr10Plus,
            dolbyVisionProfile: dolbyVisionProfile,
            dvBlCompatId: dvBlCompatId,
            dvEnhancementLayer: dvEnhancementLayer,
            audioCodec: audioCodec,
            audioChannels: audioChannels,
            audioLayout: audioLayout,
            videoCopyUnsafe: videoCopyUnsafe)
    }
}

struct APIv2PlaybackPlan: Codable {
    let protocolVersion: Int
    let planId: String
    let sessionId: String?
    let expiresAt: String?
    let delivery: String
    let planAttemptKey: String
    let stream: PlaybackV3Stream
    let timeline: PlaybackV3Timeline
    let selectedTracks: PlaybackV3SelectedTracks
    let effectiveRecipe: PlaybackV3EffectiveRecipe
    let claims: PlaybackV3ValidationClaims
    let subtitle: PlaybackV3SubtitleDecision
    let transformations: [PlaybackV3Transformation]
    let appliedQuirks: [PlaybackV3AppliedQuirk]
    let runtimeCorrections: [String]
    let degradationWarnings: [PlaybackV3DegradationWarning]
    let decisionReason: String
    let requestedMediaFileId: String
    let effectiveMediaFileId: String
    let source: APIv2PlaybackSource
    let subtitleFidelityPolicy: String
    let availableQualities: [PlaybackV3AvailableQuality]

    func legacy() throws -> PlaybackV3Plan {
        PlaybackV3Plan(
            protocolVersion: protocolVersion,
            planId: planId,
            sessionId: sessionId,
            expiresAt: expiresAt,
            delivery: delivery,
            planAttemptKey: planAttemptKey,
            stream: stream,
            timeline: timeline,
            selectedTracks: selectedTracks,
            effectiveRecipe: effectiveRecipe,
            claims: claims,
            subtitle: subtitle,
            transformations: transformations,
            appliedQuirks: appliedQuirks,
            runtimeCorrections: runtimeCorrections,
            degradationWarnings: degradationWarnings,
            decisionReason: decisionReason,
            requestedMediaFileId: try APIv2PlaybackID.legacy(requestedMediaFileId),
            effectiveMediaFileId: try APIv2PlaybackID.legacy(effectiveMediaFileId),
            source: try source.legacy(),
            subtitleFidelityPolicy: subtitleFidelityPolicy,
            availableQualities: availableQualities)
    }
}

struct APIv2PlaybackDecision: Codable {
    let protocolVersion: Int?
    let serverFeatures: [String]
    let outcome: String?
    let sessionId: String?
    let playbackPlan: APIv2PlaybackPlan?
    let terminal: PlaybackV3Terminal?

    /// The player's decision shape.
    func legacy() throws -> PlaybackV3DecisionResponse {
        PlaybackV3DecisionResponse(
            protocolVersion: protocolVersion,
            serverFeatures: serverFeatures,
            outcome: outcome,
            sessionId: sessionId,
            playbackPlan: try playbackPlan?.legacy(),
            terminal: terminal)
    }
}

/// The current player owns integer file handles. Keep the wire opaque and
/// refuse an unrepresentable handle rather than truncating or rounding it.
private enum APIv2PlaybackID {
    static func legacy(_ value: String) throws -> Int {
        guard let id = Int(value), id > 0, String(id) == value else { throw PlaybackSequencedError.invalidResponse }
        return id
    }
}

/// `GET /api/v2/playback/capabilities`. `installation_id` is optional in the
/// schema, but every playback mutation requires it, so an available document
/// without one cannot start playback.
struct APIv2PlaybackCapabilities: Decodable {
    let installationId: String?
    let revision: String
    let state: String
    let allowed: Bool
    let protocolVersions: [Int]
    let features: [String]
    let deliveries: [String]

    static let notConfigured = PlaybackV3TerminalFailure(reason: "playback_not_configured",
        message: "API v2 playback is not configured on this server. Ask the server administrator to finish playback setup.",
        retryable: false)

    /// The installation id every mutation must echo, once the server offers
    /// the whole contract this client plays through: protocol 3, the neutral
    /// plan, header-authenticated media and sequenced progress.
    func requireAvailable() throws -> String {
        if state == "not_configured" { throw Self.notConfigured }
        if state == "unsupported" {
            throw PlaybackV3TerminalFailure(reason: "playback_unsupported",
                message: "This server does not support API v2 playback. Update the server to start watching.",
                retryable: false)
        }
        guard state == "available", allowed else {
            throw PlaybackV3TerminalFailure(reason: "playback_unavailable",
                message: "Playback is not available for this profile.", retryable: false)
        }
        let required = [PlaybackProtocolV3.planFeature, PlaybackProtocolV3.neutralContractFeature,
                        PlaybackProtocolV3.headerAuthenticatedMediaFeature, PlaybackSequencedContract.feature]
        guard protocolVersions.contains(PlaybackProtocolV3.version), required.allSatisfy(features.contains) else {
            throw PlaybackV3TerminalFailure(reason: "server_upgrade_required",
                message: UpdateRequirement.serverMessage, retryable: false)
        }
        guard let installationId, !installationId.isEmpty else { throw Self.notConfigured }
        return installationId
    }
}

/// Delegated credential for one owner-bound control handshake; never persisted.
struct APIv2PlaybackControlTicket: Decodable {
    let ticket: String
    let expiresIn: Int
    let maxConnectionSeconds: Int
    let `protocol`: String

    /// The ticket travels in the `Sec-WebSocket-Protocol` header of the
    /// handshake. Plain-`http` servers are supported for ordinary bearer
    /// requests, but this delegated credential is only sent over TLS; a
    /// cleartext origin fails closed here rather than exposing the ticket to
    /// an on-path observer. Loopback origins are the one exception, for
    /// local development against a server on the same machine.
    func request(serverURL: String, sessionID: String) throws -> URLRequest {
        let safeTicket = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard `protocol` == "silo.playback-control.v2", expiresIn > 0, maxConnectionSeconds > 0,
              !ticket.isEmpty, ticket.unicodeScalars.allSatisfy(safeTicket.contains),
              UUID(uuidString: sessionID) != nil,
              var url = URLComponents(string: serverURL),
              ["http", "https"].contains(url.scheme), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PlaybackSequencedError.invalidResponse
        }
        guard url.scheme == "https" || Self.isLoopback(host) else {
            throw PlaybackSequencedError.controlRequiresTLS
        }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.percentEncodedPath = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map { "/" + $0 }.joined()
            + "/api/v2/playback/sessions/\(sessionID)/control/ws"
        guard let resolved = url.url else { throw PlaybackSequencedError.invalidResponse }
        var request = URLRequest(url: resolved)
        request.setValue("\(`protocol`), silo.ticket.\(ticket)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1" || lowered == "[::1]"
    }
}

/// `GET /api/v2/playback/sessions/control/capabilities`. The server sends
/// an empty `protocol` while the handshake is not served.
struct APIv2PlaybackControlCapabilities: Decodable {
    let available: Bool
    let `protocol`: String
    let revision: String
    let state: String
    let allowed: Bool

    /// Whether this owner may mint a ticket for the v2 control handshake.
    var servesControlHandshake: Bool {
        allowed && state == "available" && available && `protocol` == "silo.playback-control.v2"
    }
}

struct APIv2PlaybackReplanBody: Encodable {
    let installationID: String
    let request: PlaybackV3ReplanRequest
    private enum CodingKeys: String, CodingKey { case installationID = "installation_id" }
    func encode(to encoder: Encoder) throws {
        try request.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationID, forKey: .installationID)
    }
}

struct APIv2PlaybackRouteEventBody: Encodable {
    let installationID: String
    let eventID: String
    let event: PlaybackV3RouteEvent
    private enum CodingKeys: String, CodingKey { case installationID = "installation_id", eventID = "event_id" }
    func encode(to encoder: Encoder) throws {
        try event.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationID, forKey: .installationID)
        try values.encode(eventID, forKey: .eventID)
    }
}

struct APIv2PlaybackRouteEventReceipt: Decodable {
    let eventId: String
    let outcome: String
}

/// `POST /api/v2/playback/{session_id}/progress`: one sequenced sample.
struct APIv2PlaybackProgressBody: Encodable {
    let installationID: String
    let sample: PlaybackSequencedSample
    private enum CodingKeys: String, CodingKey { case installationID = "installation_id" }
    func encode(to encoder: Encoder) throws {
        try sample.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationID, forKey: .installationID)
    }
}

/// `DELETE /api/v2/playback/{session_id}`. The optional final sample rides on
/// the stop, so `sequence` and `position` are sent together or not at all.
struct APIv2PlaybackStopBody: Encodable {
    let installationID: String
    let stopID: String
    let finalSample: PlaybackSequencedSample?
    private enum CodingKeys: String, CodingKey { case installationID = "installation_id", stopID = "stop_id" }
    func encode(to encoder: Encoder) throws {
        try finalSample?.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationID, forKey: .installationID)
        try values.encode(stopID, forKey: .stopID)
    }
}

/// The receipt for a progress or stop mutation. `accepted` is the latest
/// sample the server committed for the attempt, when there is one.
struct APIv2PlaybackMutation: Decodable, Equatable {
    struct Accepted: Decodable, Equatable {
        let sequence: Int64
        let position: Double
        let isPaused: Bool
    }

    let outcome: String
    let accepted: Accepted?
    let stopId: String?
    let historyId: String?

    /// Progress: a newer or equal-and-identical sample was recorded, or the
    /// server already holds a newer one. Stop: this request's stop won, or an
    /// earlier stop (another client's, or the server's own expiry) did.
    enum Outcome {
        static let applied = "applied"
        static let replayed = "replayed"
        static let staleSample = "stale_sample"
        static let stopped = "stopped"
    }
}
