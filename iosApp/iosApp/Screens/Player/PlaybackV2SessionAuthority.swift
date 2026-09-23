import Foundation

/// Who a v2 playback session acts for. Every request of the session carries
/// the server's playback installation and runs fenced to the owner captured
/// before the start, so a profile or account switch never starts, reports
/// or stops playback for the replacement owner.
struct PlaybackV2SessionAuthority: Sendable {
    let owner: CapturedOrdinaryRequestAuth
    let installationID: String

    /// Starts `request`, and resends the identical body once after a
    /// transport failure. The server replays the stored decision for the same
    /// `playback_attempt_id` and body, so an ambiguous first response cannot
    /// allocate a second logical attempt.
    func start(_ request: PlaybackV3StartRequest,
               api: APIv2Client = SiloAPI.shared.apiV2Client) async throws -> PlaybackV3DecisionResponse {
        do {
            return try await api.startPlayback(request, installationID: installationID, auth: owner)
        } catch let error as HTTPError {
            guard case .network = error else { throw error }
            return try await api.startPlayback(request, installationID: installationID, auth: owner)
        }
    }

    /// Stops `sessionID`, carrying the final sample when there is one. One
    /// `stop_id` covers the request and its single resend after a transport
    /// failure; the server records one stop per session and replays it.
    @discardableResult
    func stop(_ sessionID: String, finalSample: PlaybackSequencedSample?,
              api: APIv2Client = SiloAPI.shared.apiV2Client) async throws -> APIv2PlaybackMutation {
        let stopID = UUID().uuidString.lowercased()
        do {
            return try await api.stopPlayback(sessionID: sessionID, stopID: stopID, finalSample: finalSample,
                installationID: installationID, auth: owner)
        } catch let error as HTTPError {
            guard case .network = error else { throw error }
            return try await api.stopPlayback(sessionID: sessionID, stopID: stopID, finalSample: finalSample,
                installationID: installationID, auth: owner)
        }
    }

    /// Route events are diagnostics and `non_retryable`: sent once, never
    /// resent, and a 429 simply drops the event.
    func reportRouteEvent(_ event: PlaybackV3RouteEvent,
                          api: APIv2Client = SiloAPI.shared.apiV2Client) async throws {
        try await api.reportPlaybackRouteEvent(event, installationID: installationID, auth: owner)
    }
}
