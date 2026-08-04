#if os(tvOS)
import Foundation

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
        return activeIdentity.serverId == offer.serverId
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
        guard activationGenerationPending == nil else { return false }
        let endingGenerationID: UUID
        if let expectedGenerationID {
            guard activeIdentity?.generationID == expectedGenerationID,
                  scope?.credentialGenerationID == expectedGenerationID else {
                return false
            }
            endingGenerationID = expectedGenerationID
        } else {
            guard let currentGenerationID = activeIdentity?.generationID
                    ?? scope?.credentialGenerationID,
                  activeIdentity == nil || activeIdentity?.generationID == currentGenerationID,
                  scope == nil || scope?.credentialGenerationID == currentGenerationID else {
                return false
            }
            endingGenerationID = currentGenerationID
        }
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
        if scope != nil {
            guard await TokenStore.shared.endTemporaryScope(
                expectedGenerationID: endingGenerationID
            ) != nil else {
                return await releaseIdentityTransition(transitionLease, returning: false)
            }
        }
        activeIdentity = nil
        AuthService.shared.clearCachesForTemporaryIdentityChange()
        return await releaseIdentityTransition(transitionLease, returning: true)
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
        let usesDifferentServer = scope.serverId != ServerRegistry.shared.activeServerId
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
            return await releaseIdentityTransition(transitionLease, returning: false)
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
        return await releaseIdentityTransition(transitionLease, returning: true)
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
