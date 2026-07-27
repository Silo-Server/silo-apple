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
                await activate(TemporaryAuthScope(
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
                )
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

    func end() async {
        let hasTemporaryScope = await TokenStore.shared.hasTemporaryScope()
        guard activeIdentity != nil || hasTemporaryScope else { return }
        if hasTemporaryScope {
            try? await HTTPClient.shared.postVoid("/api/v1/auth/logout")
        }
        await HTTPClient.shared.cancelInFlightRequests()
        _ = await TokenStore.shared.endTemporaryScope()
        activeIdentity = nil
        AuthService.shared.clearCachesForTemporaryIdentityChange()
    }

    private func activate(
        _ scope: TemporaryAuthScope,
        serverName: String?,
        profileName: String?,
        controllerDeviceName: String?
    ) async {
        let usesDifferentServer = scope.serverId != ServerRegistry.shared.activeServerId
        await HTTPClient.shared.cancelInFlightRequests()
        AuthService.shared.clearCachesForTemporaryIdentityChange()
        await TokenStore.shared.beginTemporaryScope(scope)
        activeIdentity = ActiveIdentity(
            generationID: UUID(),
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
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
#endif
