import Foundation

/// The server calls the playback control plane makes, as a seam.
///
/// Exactly the set of ``SiloAPI`` endpoints ``PlaybackSessionBridge`` (and its
/// capability gate) reaches for — no more, no less — so a test can drive a real
/// bridge over scripted fixture responses instead of the network. Every
/// requirement is `async throws` because the production witness is an actor: an
/// actor-isolated method can only satisfy an asynchronous requirement.
protocol PlaybackTransport: Sendable {
    func playbackV3Capability() async throws -> PlaybackV3CapabilityResponse

    func startPlaybackV3(request: PlaybackV3StartRequest) async throws -> PlaybackV3DecisionResponse

    func replanPlaybackV3(
        sessionId: String,
        request: PlaybackV3ReplanRequest
    ) async throws -> PlaybackV3DecisionResponse

    func reportPlaybackRouteEventV3(_ event: PlaybackV3RouteEvent) async throws

    func reportPlaybackProgress(sessionId: String, report: ProgressReport) async throws

    func syncProgress(
        mediaItemId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool
    ) async throws

    func stopPlayback(sessionId: String) async throws

    func watchDetail(contentId: String) async throws -> WatchDetail
}

/// The production transport. The conformance lives here rather than in
/// `SiloAPI.swift` so the networking layer stays unaware of the player; the
/// signatures already match, so it is empty.
extension SiloAPI: PlaybackTransport {}
