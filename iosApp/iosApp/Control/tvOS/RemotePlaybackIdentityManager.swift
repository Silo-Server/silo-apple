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

#if os(tvOS)
@MainActor
final class RemotePlaybackIdentityManager {
    static let shared = RemotePlaybackIdentityManager()

    struct ActiveIdentity: Equatable {
        let generationID: UUID
        let serverId: String
        let serverURL: String
        let serverName: String?
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
            }
        }
    }

    private(set) var activeIdentity: ActiveIdentity?
    private let api = PairingDeviceAPI()
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

    func matches(_ offer: SiloControlHandoffOffer, controllerDeviceId: String) -> Bool {
        guard let activeIdentity else { return false }
        return ServerRegistry.serverIdsMatch(activeIdentity.serverId, offer.serverId)
            && activeIdentity.profileId == offer.profileId
            && activeIdentity.controllerDeviceId == controllerDeviceId
    }

    func prepare(
        offer: SiloControlHandoffOffer,
        controllerDeviceId: String,
        controllerDeviceName: String?,
        onChallenge: @escaping (SiloControlHandoffChallenge) async throws -> Void
    ) async throws -> SiloControlHandoffReady {
        let normalizedURL = ServerRegistry.normalize(url: offer.serverURL)
        guard !normalizedURL.isEmpty,
              !offer.profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ServerRegistry.serverId(for: normalizedURL) == offer.serverId else {
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

        let capability = try await api.remotePlaybackCapability(serverURL: normalizedURL)
        guard capability.remotePlaybackHandoff,
              capability.protocolVersions.contains(SiloControlProtocol.version) else {
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

        let deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn))
        while Date() < deadline {
            try Task.checkCancellation()
            let poll = try await api.poll(serverURL: normalizedURL, deviceCode: started.deviceCode)
            try Task.checkCancellation()
            switch DeviceLoginStatus(raw: poll.status) {
            case .approved:
                guard poll.temporary == true,
                      poll.profileId == offer.profileId,
                      let accessToken = poll.accessToken, !accessToken.isEmpty,
                      let refreshToken = poll.refreshToken, !refreshToken.isEmpty,
                      let profileToken = poll.profileToken, !profileToken.isEmpty else {
                    throw HandoffError.invalidResponse
                }
                let expiresAt = poll.sessionExpiresAt.flatMap(Self.parseISO8601)
                    ?? Date().addingTimeInterval(24 * 60 * 60)
                guard await activate(TemporaryAuthScope(
                    serverId: offer.serverId,
                    serverURL: normalizedURL,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    profileId: offer.profileId,
                    profileToken: profileToken,
                    controllerDeviceId: controllerDeviceId,
                    expiresAt: expiresAt
                ),
                    serverName: offer.serverName,
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
            case .denied:
                throw HandoffError.denied
            case .expired, .consumed:
                throw HandoffError.expired
            case .pending, .unknown:
                try await Task.sleep(for: .seconds(max(1, poll.pollAfter ?? started.interval)))
            }
        }
        throw HandoffError.expired
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
            try? await HTTPClient.shared.postVoid(
                "/api/v1/auth/logout",
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
        let usesDifferentServer = !ServerRegistry.serverIdsMatch(
            scope.serverId,
            ServerRegistry.shared.activeServerId
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

    private static func parseISO8601(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
#endif
