import Foundation
@testable import Silo

/// Scripted stand-in for `SiloAPI` on the `PlaybackTransport` seam.
///
/// Every method either returns the next scripted response for that endpoint or
/// throws `Exhausted`, and every call is appended to `calls` in the order the
/// bridge made it. Nothing here touches the network, a timer or the clock, so a
/// test can drive the real `PlaybackSessionBridge` deterministically.
actor FakePlaybackTransport: PlaybackTransport {

    /// One recorded server call, carrying the request the bridge actually sent
    /// so the wire contract can be asserted on.
    enum Call {
        case playbackV3Capability
        case watchDetail(contentId: String)
        case startPlaybackV3(PlaybackV3StartRequest)
        case replanPlaybackV3(sessionId: String, request: PlaybackV3ReplanRequest)
        case reportPlaybackRouteEventV3(PlaybackV3RouteEvent)
        case reportPlaybackProgress(sessionId: String, report: ProgressReport)
        case syncProgress(mediaItemId: String, position: Double, duration: Double, forceOverwrite: Bool)
        case stopPlayback(sessionId: String)
    }

    struct Exhausted: Error {
        let method: String
    }

    private(set) var calls: [Call] = []

    private var capabilityResponses: [PlaybackV3CapabilityResponse]
    private var watchDetailResponses: [WatchDetail]
    private var startResponses: [PlaybackV3DecisionResponse] = []
    private var replanResponses: [PlaybackV3DecisionResponse] = []

    /// The capability and watch-detail responses repeat, because neither is a
    /// per-attempt decision; start and replan responses are queued per call.
    init(capability: PlaybackV3CapabilityResponse, watchDetail: WatchDetail) {
        capabilityResponses = [capability]
        watchDetailResponses = [watchDetail]
    }

    func enqueueStart(_ response: PlaybackV3DecisionResponse) {
        startResponses.append(response)
    }

    func enqueueReplan(_ response: PlaybackV3DecisionResponse) {
        replanResponses.append(response)
    }

    // MARK: - Recorded calls

    func recordedCalls() -> [Call] { calls }

    func stopPlaybackSessionIds() -> [String] {
        calls.compactMap { call in
            if case .stopPlayback(let sessionId) = call { return sessionId }
            return nil
        }
    }

    func replanRequests() -> [PlaybackV3ReplanRequest] {
        calls.compactMap { call in
            if case .replanPlaybackV3(_, let request) = call { return request }
            return nil
        }
    }

    func startRequests() -> [PlaybackV3StartRequest] {
        calls.compactMap { call in
            if case .startPlaybackV3(let request) = call { return request }
            return nil
        }
    }

    func routeEvents() -> [PlaybackV3RouteEvent] {
        calls.compactMap { call in
            if case .reportPlaybackRouteEventV3(let event) = call { return event }
            return nil
        }
    }

    func progressReports() -> [(sessionId: String, report: ProgressReport)] {
        calls.compactMap { call in
            if case .reportPlaybackProgress(let sessionId, let report) = call {
                return (sessionId, report)
            }
            return nil
        }
    }

    // MARK: - PlaybackTransport

    func playbackV3Capability() async throws -> PlaybackV3CapabilityResponse {
        calls.append(.playbackV3Capability)
        return try next(&capabilityResponses, repeatingLast: true, method: "playbackV3Capability")
    }

    func watchDetail(contentId: String) async throws -> WatchDetail {
        calls.append(.watchDetail(contentId: contentId))
        return try next(&watchDetailResponses, repeatingLast: true, method: "watchDetail")
    }

    func startPlaybackV3(request: PlaybackV3StartRequest) async throws -> PlaybackV3DecisionResponse {
        calls.append(.startPlaybackV3(request))
        return try next(&startResponses, repeatingLast: false, method: "startPlaybackV3")
    }

    func replanPlaybackV3(
        sessionId: String,
        request: PlaybackV3ReplanRequest
    ) async throws -> PlaybackV3DecisionResponse {
        calls.append(.replanPlaybackV3(sessionId: sessionId, request: request))
        return try next(&replanResponses, repeatingLast: false, method: "replanPlaybackV3")
    }

    func reportPlaybackRouteEventV3(_ event: PlaybackV3RouteEvent) async throws {
        calls.append(.reportPlaybackRouteEventV3(event))
    }

    func reportPlaybackProgress(sessionId: String, report: ProgressReport) async throws {
        calls.append(.reportPlaybackProgress(sessionId: sessionId, report: report))
    }

    func syncProgress(
        mediaItemId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool
    ) async throws {
        calls.append(
            .syncProgress(
                mediaItemId: mediaItemId,
                position: position,
                duration: duration,
                forceOverwrite: forceOverwrite
            )
        )
    }

    func stopPlayback(sessionId: String) async throws {
        calls.append(.stopPlayback(sessionId: sessionId))
    }

    // MARK: - Helpers

    private func next<Response>(
        _ queue: inout [Response],
        repeatingLast: Bool,
        method: String
    ) throws -> Response {
        guard let head = queue.first else { throw Exhausted(method: method) }
        if !repeatingLast || queue.count > 1 { queue.removeFirst() }
        return head
    }
}
