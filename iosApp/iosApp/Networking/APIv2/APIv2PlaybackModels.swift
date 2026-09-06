import Foundation

struct APIv2PlaybackStartBody: Codable {
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

struct APIv2PlaybackCapabilities: Decodable {
    let installationId: String?
    let revision: String
    let state: String
    let allowed: Bool
    let protocolVersions: [Int]
    let features: [String]
    let deliveries: [String]

    func requireAvailable() throws -> String {
        guard state == "available", allowed, protocolVersions.contains(3),
              features.contains(PlaybackSequencedContract.feature),
              let installationId, !installationId.isEmpty else {
            throw PlaybackV3TerminalFailure(reason: "playback_unavailable",
                message: "Playback is not available for this profile.", retryable: false)
        }
        return installationId
    }
}
