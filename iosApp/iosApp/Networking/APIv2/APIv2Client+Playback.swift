import Foundation

/// The v2 playback session operations. `playbackRequest` fences every call to
/// the captured owner and maps each non-2xx answer to `APIv2Error`; each
/// wrapper here then accepts only the one success status its operation
/// declares. Every mutation carries the server's playback `installation_id`;
/// a stale one is refused with 409 `installation_changed`.
extension APIv2Client {
    /// `POST /api/v2/playback/start`, answered with 201. The server replays
    /// the stored decision for the same `playback_attempt_id` and body, so
    /// the identical request may be sent again after a transport failure.
    func startPlayback(_ request: PlaybackV3StartRequest, installationID: String,
                       auth: CapturedOrdinaryRequestAuth) async throws -> PlaybackV3DecisionResponse {
        let body = try Self.playbackBody(APIv2PlaybackStartBody(request, installationID: installationID))
        // Stream probing and transcode startup can exceed the standard timeout.
        let raw = try await playbackRequest(method: "POST", suffix: "/start", body: body, auth: auth,
            timeout: .extended)
        guard raw.statusCode == 201 else { throw PlaybackSequencedError.invalidResponse }
        return try Self.playbackDecision(raw)
    }

    /// `POST /api/v2/playback/{session_id}/replan`, answered with 200. The
    /// server replays the committed decision for a repeated
    /// `replan_request_id` with the same body.
    func replanPlayback(sessionID: String, _ request: PlaybackV3ReplanRequest, installationID: String,
                        auth: CapturedOrdinaryRequestAuth) async throws -> PlaybackV3DecisionResponse {
        let suffix = try Self.playbackSessionSuffix(sessionID) + "/replan"
        let body = try Self.playbackBody(APIv2PlaybackReplanBody(installationID: installationID, request: request))
        let raw = try await playbackRequest(method: "POST", suffix: suffix, body: body, auth: auth,
            timeout: .extended)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        return try Self.playbackDecision(raw)
    }

    /// `POST /api/v2/playback/route-events`, answered with 202 and a receipt
    /// that must echo this event's id. Route events are diagnostics and
    /// `non_retryable`: the caller never sends one again, and a 429 drops it.
    func reportPlaybackRouteEvent(_ event: PlaybackV3RouteEvent, installationID: String,
                                  auth: CapturedOrdinaryRequestAuth) async throws {
        let eventID = UUID().uuidString.lowercased()
        let body = try Self.playbackBody(APIv2PlaybackRouteEventBody(installationID: installationID,
            eventID: eventID, event: event))
        let raw = try await playbackRequest(method: "POST", suffix: "/route-events", body: body, auth: auth)
        guard raw.statusCode == 202 else { throw PlaybackSequencedError.invalidResponse }
        let receipt = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackRouteEventReceipt.self, from: raw.data)
        guard receipt.eventId == eventID, receipt.outcome == "accepted" else {
            throw PlaybackSequencedError.invalidResponse
        }
    }

    /// `POST /api/v2/playback/{session_id}/progress`, answered with 200:
    /// `applied`, `replayed` (the same sample again) or `stale_sample` (the
    /// server already holds a higher sequence). A stopped or unknown session
    /// is a 404 problem.
    func updatePlaybackProgress(sessionID: String, sample: PlaybackSequencedSample, installationID: String,
                                auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackMutation {
        let suffix = try Self.playbackSessionSuffix(sessionID) + "/progress"
        let body = try Self.playbackBody(APIv2PlaybackProgressBody(installationID: installationID, sample: sample))
        let raw = try await playbackRequest(method: "POST", suffix: suffix, body: body, auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        let mutation = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackMutation.self, from: raw.data)
        let outcomes = [APIv2PlaybackMutation.Outcome.applied, APIv2PlaybackMutation.Outcome.replayed,
                        APIv2PlaybackMutation.Outcome.staleSample]
        guard outcomes.contains(mutation.outcome) else { throw PlaybackSequencedError.invalidResponse }
        return mutation
    }

    /// `DELETE /api/v2/playback/{session_id}`, answered with 200. Only
    /// `stopped` echoing this `stop_id`, or `replayed` (the stored receipt of
    /// whichever stop won first, which carries that stop's id), settles the
    /// stop. The server records one stop per session, so resending the same
    /// `stop_id` after a transport failure is safe.
    func stopPlayback(sessionID: String, stopID: String, finalSample: PlaybackSequencedSample?,
                      installationID: String, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackMutation {
        let suffix = try Self.playbackSessionSuffix(sessionID)
        let body = try Self.playbackBody(APIv2PlaybackStopBody(installationID: installationID, stopID: stopID,
            finalSample: finalSample))
        let raw = try await playbackRequest(method: "DELETE", suffix: suffix, body: body, auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        let mutation = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackMutation.self, from: raw.data)
        guard (mutation.outcome == APIv2PlaybackMutation.Outcome.stopped && mutation.stopId == stopID)
                || mutation.outcome == APIv2PlaybackMutation.Outcome.replayed else {
            throw PlaybackSequencedError.invalidResponse
        }
        return mutation
    }

    /// Mints a control ticket and builds the socket upgrade for it. Checks
    /// `GET /api/v2/playback/sessions/control/capabilities` first, then
    /// `POST /api/v2/playback/sessions/{session_id}/control/ws-ticket`,
    /// answered with 200. A ticket admits one handshake, so every connect and
    /// reconnect calls this again. Minting is `natural_idempotent`: an unused
    /// ticket simply expires.
    func playbackControlHandshake(sessionID: String, installationID: String,
                                  auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackControlHandshake {
        let suffix = try Self.playbackSessionSuffix(sessionID) + "/control/ws-ticket"
        let capabilityRaw = try await playbackRequest(method: "GET", suffix: "/sessions/control/capabilities", auth: auth)
        guard capabilityRaw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        let capability = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackControlCapabilities.self,
                                                                 from: capabilityRaw.data)
        guard capability.servesControlHandshake else { throw PlaybackSequencedError.controlUnavailable }
        struct Body: Encodable { let installationId: String }
        // `playbackRequest` fences the mint to `auth`, so the ticket is handed
        // out only while that owner is still current.
        let raw = try await playbackRequest(method: "POST", suffix: "/sessions" + suffix,
            body: Self.playbackBody(Body(installationId: installationID)), auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        let ticket = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackControlTicket.self, from: raw.data)
        return try ticket.handshake(serverURL: auth.account.serverURL, sessionID: sessionID)
    }

    private static func playbackBody<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(body)
    }

    /// The server accepts only a canonical UUID session id; anything else is
    /// refused here instead of being spliced into the path.
    private static func playbackSessionSuffix(_ sessionID: String) throws -> String {
        guard let uuid = UUID(uuidString: sessionID), uuid.uuidString.lowercased() == sessionID else {
            throw PlaybackSequencedError.invalidSession
        }
        return "/" + sessionID
    }

    private static func playbackDecision(_ raw: HTTPRawResponse) throws -> PlaybackV3DecisionResponse {
        try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: raw.data).legacy()
    }
}
