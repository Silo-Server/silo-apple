import Foundation

/// Pure entry policy for temporary-identity teardown. Kept outside the tvOS
/// conditional so the generation rules can be regression-tested without a
/// simulator-only test target.
enum RemotePlaybackIdentityEndPolicy {
    static func endingGenerationID(
        activeIdentityGenerationID: UUID?,
        scopeGenerationID: UUID?,
        expectedGenerationID: UUID?
    ) -> UUID? {
        if let expectedGenerationID {
            guard activeIdentityGenerationID == expectedGenerationID,
                  scopeGenerationID == nil || scopeGenerationID == expectedGenerationID else {
                return nil
            }
            return expectedGenerationID
        }

        guard let currentGenerationID = activeIdentityGenerationID ?? scopeGenerationID,
              activeIdentityGenerationID == nil || activeIdentityGenerationID == currentGenerationID,
              scopeGenerationID == nil || scopeGenerationID == currentGenerationID else {
            return nil
        }
        return currentGenerationID
    }
}

/// Pure candidate-address policy for a handoff that carries a deployment
/// identity. Kept outside the tvOS conditional so it can be regression-tested
/// from the iOS test bundle.
enum RemotePlaybackCandidatePolicy {
    /// The addresses to try, in order, de-duplicated on the normalized URL:
    /// the TV's own saved address for the same deployment (already known to
    /// work from here), the phone's address, then the deployment's public
    /// address and connected providers in the server's order.
    static func candidateURLs(
        savedURL: String?,
        offeredURL: String,
        endpoints: [ServerEndpoint]?
    ) -> [String] {
        var ordered: [String] = []
        if let savedURL { ordered.append(savedURL) }
        ordered.append(offeredURL)
        ordered.append(contentsOf: (endpoints ?? []).map(\.url))
        var seen = Set<String>()
        return ordered
            .map { ServerRegistry.normalize(url: $0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

#if os(tvOS)
@MainActor
final class RemotePlaybackIdentityManager {
    static let shared = RemotePlaybackIdentityManager()

    struct ActiveIdentity: Equatable {
        let generationID: UUID
        let serverId: String
        /// The address this TV reached the server at. May differ from the
        /// phone's when the handoff carried a deployment identity.
        let serverURL: String
        let serverName: String?
        let serverIdentity: String?
        let profileId: String
        let profileName: String?
        let controllerDeviceId: String
        let controllerDeviceName: String?
        let usesDifferentServer: Bool
        let sessionExpiresAt: Date
    }

    enum HandoffError: LocalizedError {
        case invalidOffer
        case unsupportedServer
        case denied
        case expired
        case invalidResponse
        /// No candidate address answered from this TV.
        case serverUnreachable(serverName: String?, help: String?)
        /// A candidate answered with a different deployment identity.
        case identityMismatch

        /// Wire reason for `handoff_cancel`, mirrored by Android.
        var cancelReason: String {
            switch self {
            case .serverUnreachable: return "server_unreachable"
            case .identityMismatch: return "identity_mismatch"
            default: return "handoff_failed"
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidOffer:
                return "The phone sent an invalid server or profile."
            case .unsupportedServer:
                return "Update the phone's Silo server to use profile handoff."
            case .denied:
                return "Profile handoff was denied."
            case .expired:
                return "Profile handoff expired."
            case .invalidResponse:
                return "The server returned an invalid profile handoff."
            case .serverUnreachable(let serverName, let help):
                if let help { return help }
                return "This Apple TV can't reach \(serverName ?? "the phone's server")."
            case .identityMismatch:
                return "The address the phone offered belongs to a different Silo server."
            }
        }
    }

    private(set) var activeIdentity: ActiveIdentity?
    private let api = PairingDeviceAPI()
    private let identityResolver = ServerIdentityResolver()
    /// Set synchronously before a replacement begins global request
    /// cancellation. An older re-entrant `end` must not cancel or remove work
    /// after this generation has claimed the transition.
    private var activationGenerationPending: UUID?

    private init() {}

    var effectiveServerId: String? {
        activeIdentity?.serverId ?? ServerRegistry.shared.activeServerId
    }

    var effectiveServerName: String? {
        activeIdentity?.serverName ?? ServerRegistry.shared.activeServer?.displayName
    }

    /// The deployment identity behind the effective server, when known.
    var effectiveServerIdentity: String? {
        activeIdentity?.serverIdentity ?? ServerRegistry.shared.activeServer?.verifiedServerId
    }

    /// Whether a controller that names `serverId` / `serverIdentity` is on the
    /// same deployment as this TV's effective server.
    func controllerMatchesEffectiveServer(serverId: String?, serverIdentity: String?) -> Bool {
        ServerRegistry.serversMatch(
            serverId: serverId, verifiedServerId: serverIdentity,
            serverId: effectiveServerId, verifiedServerId: effectiveServerIdentity
        )
    }

    func matches(_ offer: SiloControlHandoffOffer, controllerDeviceId: String) -> Bool {
        guard let activeIdentity else { return false }
        return ServerRegistry.serversMatch(
            serverId: activeIdentity.serverId, verifiedServerId: activeIdentity.serverIdentity,
            serverId: offer.serverId, verifiedServerId: offer.serverIdentity
        )
            && activeIdentity.profileId == offer.profileId
            && activeIdentity.controllerDeviceId == controllerDeviceId
    }

    func prepare(
        offer: SiloControlHandoffOffer,
        controllerDeviceId: String,
        controllerDeviceName: String?,
        onChallenge: @escaping (SiloControlHandoffChallenge) async throws -> Void
    ) async throws -> SiloControlHandoffReady {
        let offeredURL = ServerRegistry.normalize(url: offer.serverURL)
        guard !offeredURL.isEmpty,
              !offer.profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ServerRegistry.serverId(for: offeredURL) == offer.serverId else {
            throw HandoffError.invalidOffer
        }

        if matches(offer, controllerDeviceId: controllerDeviceId),
           let activeIdentity {
            return SiloControlHandoffReady(
                requestId: offer.requestId,
                serverId: activeIdentity.serverId,
                profileId: activeIdentity.profileId,
                sessionExpiresAt: Self.iso8601(activeIdentity.sessionExpiresAt),
                reused: true
            )
        }

        // With a deployment identity the phone's URL is one candidate among
        // the deployment's addresses; the first that answers with the same
        // identity from here is the one this TV can actually use. Without
        // one (older phone) the offered URL is used exactly, as before.
        let normalizedURL = try await resolveReachableURL(offer: offer, offeredURL: offeredURL)

        let capability = try await api.remotePlaybackCapability(serverURL: normalizedURL)
        guard capability.offersRemotePlaybackHandoff(protocolVersion: SiloControlProtocol.version) else {
            throw HandoffError.unsupportedServer
        }

        let device = AppleDeviceIdentity.current
        let started = try await api.startRemotePlayback(
            serverURL: normalizedURL,
            deviceName: device.name,
            devicePlatform: device.platform
        )
        guard started.clientPurpose == "remote_playback", started.temporary == true else {
            throw HandoffError.unsupportedServer
        }

        try await onChallenge(SiloControlHandoffChallenge(
            requestId: offer.requestId,
            userCode: started.userCode,
            matchCode: started.matchCode,
            expiresAt: Self.iso8601(started.expiresAt)
        ))

        let poll = try await Self.awaitApproval(of: started) { [api] in
            try await api.poll(serverURL: normalizedURL, deviceCode: started.deviceCode)
        }
        try Task.checkCancellation()
        // `validated()` guarantees tokens, profile proof and expiry
        // for an approved temporary session.
        guard poll.temporary,
              poll.profileId == offer.profileId,
              let tokens = poll.tokens,
              let expiresAt = poll.sessionExpiresAt else {
            throw HandoffError.invalidResponse
        }
        guard await activate(TemporaryAuthScope(
            serverId: offer.serverId,
            serverURL: normalizedURL,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            profileId: offer.profileId,
            profileToken: poll.profileToken,
            controllerDeviceId: controllerDeviceId,
            expiresAt: expiresAt
        ),
            serverName: offer.serverName,
            serverIdentity: offer.serverIdentity,
            profileName: offer.profileName,
            controllerDeviceName: controllerDeviceName
        ) else {
            throw CancellationError()
        }
        return SiloControlHandoffReady(
            requestId: offer.requestId,
            serverId: offer.serverId,
            profileId: offer.profileId,
            sessionExpiresAt: Self.iso8601(expiresAt),
            reused: false
        )
    }

    /// Waits for the phone to approve the handoff request, on the shared
    /// device-code poll policy: a network blip or a 5xx while the phone
    /// approves is polled again rather than ending the handoff. Returns the
    /// approved poll; otherwise throws the `HandoffError` the phone is told,
    /// or an update requirement's error unchanged.
    static func awaitApproval(
        of started: DeviceLoginStartResponse,
        poll: () async throws -> APIv2DevicePoll
    ) async throws -> APIv2DevicePoll {
        do {
            return try await DeviceLoginPoller.waitForApproval(
                interval: started.interval,
                expiresIn: started.expiresIn,
                poll: poll
            )
        } catch DeviceLoginPoller.Failure.denied {
            throw HandoffError.denied
        } catch is DeviceLoginPoller.Failure {
            // Expired, already used, or removed by the server.
            throw HandoffError.expired
        } catch APIv2Error.incompleteAuthResponse {
            throw HandoffError.invalidResponse
        }
    }

    /// Picks the address this TV will use for the handoff. Only candidates
    /// that report `offer.serverIdentity` qualify: an address that answers
    /// with another identity is refused rather than skipped, because the
    /// phone believes it belongs to this server. Reachability is decided
    /// here, never by the server.
    private func resolveReachableURL(
        offer: SiloControlHandoffOffer,
        offeredURL: String
    ) async throws -> String {
        guard let expectedIdentity = ServerIdentity.usable(offer.serverIdentity) else {
            return offeredURL
        }
        let candidates = RemotePlaybackCandidatePolicy.candidateURLs(
            savedURL: ServerRegistry.shared.entry(verifiedServerId: expectedIdentity)?.url,
            offeredURL: offeredURL,
            endpoints: offer.serverEndpoints
        )
        for candidate in candidates {
            try Task.checkCancellation()
            switch await identityResolver.probeIdentity(serverURL: candidate) {
            case .identity(let id) where id == expectedIdentity:
                return candidate
            case .identity:
                throw HandoffError.identityMismatch
            case .unsupportedServer:
                // Reachable, but it cannot prove who it is; the phone's own
                // address is still trusted the legacy way.
                if candidate == offeredURL { return candidate }
            case .unreachable:
                continue
            }
        }
        // The phone's address was unreachable: name the provider behind it
        // when the deployment lists it, so the help says what to set up.
        let help = offer.serverEndpoints?
            .first { $0.kind == .provider && $0.url == offeredURL }?
            .unreachableHelp(serverName: offer.serverName ?? "the phone's server")
        throw HandoffError.serverUnreachable(serverName: offer.serverName, help: help)
    }

    @discardableResult
    func end(
        expectedGenerationID: UUID? = nil,
        notifyServer: Bool = true
    ) async -> Bool {
        let scope = await TokenStore.shared.getTemporaryScope()
        guard activationGenerationPending == nil,
              let endingGenerationID = RemotePlaybackIdentityEndPolicy.endingGenerationID(
                  activeIdentityGenerationID: activeIdentity?.generationID,
                  scopeGenerationID: scope?.credentialGenerationID,
                  expectedGenerationID: expectedGenerationID
              ) else { return false }
        if let scope, notifyServer {
            // Best effort: the temporary session expires server-side when the
            // revoke is refused, fails, or is skipped for a v1-only server.
            try? await SiloAPI.shared.apiV2Client.logout(
                expectedAccount: RefreshAccountIdentity(
                    serverId: scope.serverId,
                    serverURL: scope.serverURL,
                    credentialGenerationID: scope.credentialGenerationID
                )
            )
        }
        // A replacement can start while logout is suspended. It sets the
        // pending marker before its own queued cancellation pass, so the old
        // generation must stop here without globally cancelling new work.
        guard activationGenerationPending == nil,
              activeIdentity == nil || activeIdentity?.generationID == endingGenerationID,
              !Task.isCancelled else {
            return false
        }
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            return false
        }
        guard activationGenerationPending == nil,
              activeIdentity == nil || activeIdentity?.generationID == endingGenerationID,
              !Task.isCancelled else {
            return await releaseIdentityTransition(transitionLease, returning: false)
        }
        await HTTPClient.shared.cancelInFlightRequests()
        // Every await above can admit a replacement handoff. Re-check both
        // owners, then make scope removal itself generation-conditional.
        guard activationGenerationPending == nil,
              activeIdentity == nil || activeIdentity?.generationID == endingGenerationID else {
            return await releaseIdentityTransition(transitionLease, returning: false)
        }
        switch await TokenStore.shared.endTemporaryScope(
            expectedGenerationID: endingGenerationID
        ) {
        case .ended, .alreadyAbsent:
            break
        case .differentGeneration:
            // A replacement generation owns the credential slot. Its
            // activation will publish the matching identity after this
            // transition lease is released, so preserve manager state.
            return await releaseIdentityTransition(transitionLease, returning: false)
        }
        activeIdentity = nil
        AuthService.shared.clearCachesForTemporaryIdentityChange()
        let ended = await releaseIdentityTransition(transitionLease, returning: true)
        // The persistent scope owns the credential slot again and the gate is
        // open, so this probes the restored identity. See the helper for why
        // it can't be folded into `clearCachesForTemporaryIdentityChange()`.
        refreshSubtitleProvidersAfterIdentityChange()
        return ended
    }

    private func activate(
        _ scope: TemporaryAuthScope,
        serverName: String?,
        serverIdentity: String?,
        profileName: String?,
        controllerDeviceName: String?
    ) async -> Bool {
        let generationID = scope.credentialGenerationID
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            return false
        }
        guard !Task.isCancelled,
              activationGenerationPending == nil else {
            return await releaseIdentityTransition(transitionLease, returning: false)
        }
        activationGenerationPending = generationID
        let previousIdentity = activeIdentity
        let usesDifferentServer = !ServerRegistry.serversMatch(
            serverId: scope.serverId, verifiedServerId: serverIdentity,
            serverId: ServerRegistry.shared.activeServerId,
            verifiedServerId: ServerRegistry.shared.activeServer?.verifiedServerId
        )
        await HTTPClient.shared.cancelInFlightRequests()
        guard activationGenerationPending == generationID,
              !Task.isCancelled else {
            if activationGenerationPending == generationID {
                activationGenerationPending = nil
            }
            return await releaseIdentityTransition(transitionLease, returning: false)
        }
        AuthService.shared.clearCachesForTemporaryIdentityChange()
        let previousScope = await TokenStore.shared.beginTemporaryScope(scope)
        let previousOwnersAligned = previousIdentity?.generationID
            == previousScope.scope?.credentialGenerationID
        guard activationGenerationPending == generationID,
              !Task.isCancelled,
              previousOwnersAligned else {
            let restored = await TokenStore.shared.restoreTemporaryScope(
                previousScope,
                replacingGenerationID: generationID
            )
            if restored {
                activeIdentity = previousIdentity
            } else {
                let currentScope = await TokenStore.shared.getTemporaryScope()
                if activeIdentity?.generationID != currentScope?.credentialGenerationID {
                    activeIdentity = nil
                }
            }
            if activationGenerationPending == generationID {
                activationGenerationPending = nil
            }
            AuthService.shared.clearCachesForTemporaryIdentityChange()
            let rolledBack = await releaseIdentityTransition(transitionLease, returning: false)
            // Rollback restored (or cleared) the previous scope above, so the
            // identity that is live now is whatever `activeIdentity` reflects.
            refreshSubtitleProvidersAfterIdentityChange()
            return rolledBack
        }
        activeIdentity = ActiveIdentity(
            generationID: generationID,
            serverId: scope.serverId,
            serverURL: scope.serverURL,
            serverName: serverName,
            serverIdentity: serverIdentity,
            profileId: scope.profileId,
            profileName: profileName,
            controllerDeviceId: scope.controllerDeviceId,
            controllerDeviceName: controllerDeviceName,
            usesDifferentServer: usesDifferentServer,
            sessionExpiresAt: scope.expiresAt
        )
        activationGenerationPending = nil
        let activated = await releaseIdentityTransition(transitionLease, returning: true)
        // Only now — identity published, pending marker cleared, gate open —
        // does a request carry the temporary scope's credentials. Probing any
        // earlier (e.g. at the `clearCachesForTemporaryIdentityChange()` call
        // above, which runs *before* `beginTemporaryScope`) would answer for
        // the outgoing identity and cache that answer against the new one.
        refreshSubtitleProvidersAfterIdentityChange()
        return activated
    }

    /// Re-probe the subtitle-provider capability after a temporary-identity
    /// transition settles.
    ///
    /// Needed because `clearCachesForTemporaryIdentityChange()` calls
    /// `SubtitleProvidersStore.reset()`, and that store fails *open*: reset
    /// restores `isAvailable = true`. So an affirmative "no providers here"
    /// learned about the current server is thrown away on every handoff, and
    /// — unlike sign-in — a temporary-identity swap changes no auth state, so
    /// no other probe fires. Without this the "Search Subtitles…" row silently
    /// re-enables and can run the empty 20–30s search this gate exists to
    /// prevent.
    ///
    /// Same shape as `ServerRegistry.refreshFeaturesAfterServerSwitch()`,
    /// which re-probes after a switch between already-signed-in servers for
    /// exactly this reason.
    ///
    /// Deliberately *not* called from every
    /// `clearCachesForTemporaryIdentityChange()` site: two of the three run
    /// while the scope is mid-swap (before `beginTemporaryScope`), where a
    /// probe would be answered by the outgoing identity. Each call site below
    /// instead fires this once its scope is fully installed or restored and
    /// the HTTP identity-transition lease has been released, so the request
    /// isn't gated shut either. Fire-and-forget: any failure leaves the
    /// optimistic `true` in place, which is the fail-open contract — including
    /// the case where a queued transition takes the lease first and blocks
    /// this probe, since that transition fires its own once it settles.
    private func refreshSubtitleProvidersAfterIdentityChange() {
        Task { await SubtitleProvidersStore.shared.refresh() }
    }

    private func releaseIdentityTransition(
        _ lease: HTTPIdentityTransitionLease,
        returning result: Bool
    ) async -> Bool {
        await HTTPClient.shared.endIdentityTransition(lease)
        return result
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
#endif
