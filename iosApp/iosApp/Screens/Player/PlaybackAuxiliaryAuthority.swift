import Foundation

/// What the mutation coordinator still guarantees about one bound session.
/// `accepts` is "this is the same durable binding and it still takes mutations";
/// `owns` adds "this captured request auth is still that binding's durable owner".
/// Both are asked again after every suspension that could invalidate them.
struct PlaybackAuxiliaryOwnership: Sendable {
    let accepts: @Sendable () async -> Bool
    let owns: @Sendable (CapturedOrdinaryRequestAuth) async -> Bool
}

/// Plan authority for one bound session: which immutable wire plan was adopted,
/// under which ephemeral request credentials, and the single delivery scope that
/// serves its header-authenticated auxiliary URLs.
///
/// `generation` is the adoption token. Every `adopt` and every `invalidate`
/// mints a new one, so an adoption that was in flight across a suspension
/// installs nothing once a newer adoption or a stop has superseded it.
actor PlaybackAuxiliaryAuthority {
    private struct Adoption {
        let plan: PlaybackV3Plan
        let auth: CapturedOrdinaryRequestAuth
        let allowsAuthorizedOrigins: Bool
        var scope: ProxyAuxiliaryScope?
    }

    private let sessionID: String
    private let tokens: TokenStore
    private let ownership: PlaybackAuxiliaryOwnership
    private var generation = UUID()
    private var adopted: Adoption?

    init(sessionID: String, tokens: TokenStore, ownership: PlaybackAuxiliaryOwnership) {
        self.sessionID = sessionID
        self.tokens = tokens
        self.ownership = ownership
    }

    /// True while a replan may reuse the negotiated origin opt-in of the plan
    /// this session is currently playing.
    var allowsAuthorizedOrigins: Bool { adopted?.allowsAuthorizedOrigins ?? false }

    /// Retire the adopted plan and its delivery scope, and supersede any
    /// adoption still in flight. The returned token is that new generation.
    @discardableResult
    func invalidate() -> UUID {
        generation = UUID()
        adopted?.scope?.invalidate()
        adopted = nil
        return generation
    }

    /// Called only with the response to the captured request that produced the
    /// plan. Durable response bytes are neither decorated nor re-encoded.
    func adopt(plan: PlaybackV3Plan?, auth: CapturedOrdinaryRequestAuth?, allowsAuthorizedOrigins: Bool) async throws {
        let mine = invalidate()
        guard let plan else { return }
        let primaryPath = URLComponents(string: plan.stream.url)?.percentEncodedPath ?? ""
        let headerPrimary = StreamRequest.isHeaderAuthenticatedAPIPrimary(plan.stream.url, sessionID: sessionID)
            || StreamRequest.isAllowedAuthorizedMediaOriginPath(primaryPath, sessionId: sessionID)
        let auxiliaryURLs = [plan.subtitle.artifact?.url] + plan.subtitle.inventory.flatMap { [$0.url, $0.fontBundleUrl] }
        guard headerPrimary || auxiliaryURLs.compactMap({ $0 }).contains(where: StreamRequest.isHeaderAuthenticatedAuxiliaryURL) else { return }
        guard let auth else { throw PlaybackSequencedError.authorityChanged }
        try ApplePlaybackV3PlanAdapter.validate(plan)
        guard plan.stream.headers.allSatisfy({ key, value in
            key.caseInsensitiveCompare("X-Profile-Id") != .orderedSame || value == auth.profileId
        }) else { throw PlaybackSequencedError.authorityChanged }
        // Each condition below the first sits after a suspension point: the
        // durable-owner capture, then the live request-identity check. The final
        // generation test is what stops a stop or a newer plan from being undone.
        guard await ownership.owns(auth),
              await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) == auth,
              await ownership.accepts(), generation == mine else {
            throw PlaybackSequencedError.authorityChanged
        }
        adopted = Adoption(plan: plan, auth: auth, allowsAuthorizedOrigins: allowsAuthorizedOrigins)
    }

    /// Resolve media for the adopted plan, or `nil` when this session has no
    /// adopted plan and the caller must fall back to its control binding.
    func resolveStreamRequest(rawURL: String, requiresHeaderAuthenticatedMedia: Bool,
                              allowsAuthorizedMediaOrigins: Bool) async throws -> StreamRequest? {
        guard let captured = adopted else { return nil }
        guard !allowsAuthorizedMediaOrigins || captured.allowsAuthorizedOrigins,
              captured.plan.stream.url == rawURL else { throw PlaybackSequencedError.invalidSession }
        let mine = generation
        guard await isCurrent(planID: captured.plan.planId, auth: captured.auth, generation: mine) else {
            captured.scope?.invalidate()
            throw PlaybackSequencedError.authorityChanged
        }
        // Join the immutable wire plan only with the original request authority.
        guard var request = StreamRequest.resolve(rawURL: rawURL,
            serverURL: captured.auth.account.serverURL,
            additionalHeaders: ["X-Profile-Id": captured.auth.profileId ?? ""],
            accessToken: captured.auth.accessToken,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            authorizedMediaOriginSessionId: allowsAuthorizedMediaOrigins ? sessionID : nil,
            apiV2SessionId: sessionID) else { throw PlaybackSequencedError.invalidSession }
        // Re-read after the authority suspension. Nothing below it suspends.
        guard generation == mine else { throw PlaybackSequencedError.authorityChanged }
        if allowsAuthorizedMediaOrigins || StreamRequest.isHeaderAuthenticatedAPIPrimary(rawURL, sessionID: sessionID) {
            if adopted?.scope == nil {
                let plan = captured.plan
                let auth = captured.auth
                adopted?.scope = try ProxyAuxiliaryScope(plan: plan, sessionID: sessionID,
                    sourceURL: request.url, auth: auth, tokens: tokens) { [weak self] in
                    await self?.isCurrent(planID: plan.planId, auth: auth, generation: mine) ?? false
                }
            }
            request.proxyAuxiliaryScope = adopted?.scope
        }
        return request
    }

    /// The adopted plan, its credentials and its owning session are all still
    /// the ones this delivery scope was issued for.
    private func isCurrent(planID: String, auth: CapturedOrdinaryRequestAuth, generation mine: UUID) async -> Bool {
        guard generation == mine, adopted?.plan.planId == planID, adopted?.auth == auth,
              await ownership.accepts(),
              await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) == auth,
              generation == mine, await ownership.accepts() else { return false }
        return true
    }
}
