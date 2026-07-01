#if os(iOS)
import Foundation
import OSLog
import UIKit
import UserNotifications

struct ApplePushRegistrationRequest: Encodable, Equatable {
    let deviceId: String
    let apnsToken: String
    let apnsEnvironment: String
    let apnsTopic: String
    let pushMode: String
}

struct ApplePushRegistrationResponse: Decodable {
    let id: String
    let serverDeviceId: String
    let enabled: Bool
    let pushMode: String
}

enum ApplePushRegistrationWire {
    static let endpoint = "/api/v1/devices/push/apple"
    static let defaultTopic = "org.siloserver.silo"
    static let privatePushMode = "private_push"

    /// The APNs environment is a *signing-time* decision (the
    /// `aps-environment` entitlement from the provisioning profile), not a
    /// compile-time one: the repo ships Release IPAs for sideloading that
    /// get re-signed with development profiles, and a `#if DEBUG` guess
    /// would register those sandbox tokens as "production" — every push
    /// would then fail with BadDeviceToken. Read the embedded profile
    /// instead; App Store installs carry no embedded profile and are
    /// production by definition.
    static var currentAPNsEnvironment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let environment = apnsEnvironment(fromProvisioningProfile: data) {
            return environment
        }
        return "production"
        #endif
    }

    /// Extracts `Entitlements.aps-environment` from a raw
    /// `embedded.mobileprovision` (a CMS blob wrapping an XML plist) and
    /// maps it to the server's wire values. Returns nil when the profile
    /// has no push entitlement or cannot be parsed.
    static func apnsEnvironment(fromProvisioningProfile data: Data) -> String? {
        guard let plistStart = data.range(of: Data("<plist".utf8)),
              let plistEnd = data.range(of: Data("</plist>".utf8), in: plistStart.upperBound..<data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: plistStart.lowerBound..<plistEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else {
            return nil
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }

    static func tokenHex(from data: Data) -> String {
        data.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }
        .joined()
    }

    static func topic(bundleIdentifier: String?) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultTopic : trimmed
    }
}

@MainActor
final class ApplePushRegistrationCoordinator {
    static let shared = ApplePushRegistrationCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePush"
    )

    private var lastDeviceToken: Data?
    private var inFlightFingerprint: String?
    private var lastSuccessfulFingerprint: String?
    private var endpointUnsupportedForContext: String?

    private init() {}

    func prepareForAuthenticatedProfile() async {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    Self.logger.info("User declined Apple push notification authorization")
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                Self.logger.error("Apple push authorization request failed: \(String(describing: error), privacy: .public)")
            }
        case .denied:
            Self.logger.info("Apple push notification authorization is denied")
        @unknown default:
            Self.logger.info("Apple push notification authorization is in an unknown state")
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        lastDeviceToken = deviceToken
        await registerCurrentDeviceTokenIfPossible()
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        Self.logger.error("APNs device-token registration failed: \(String(describing: error), privacy: .public)")
    }

    func registerCurrentDeviceTokenIfPossible() async {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile else {
            return
        }
        guard let lastDeviceToken else {
            return
        }

        let request = makeRegistrationRequest(deviceToken: lastDeviceToken)
        let fingerprint = registrationFingerprint(for: request)
        guard fingerprint != lastSuccessfulFingerprint,
              fingerprint != inFlightFingerprint,
              fingerprint != endpointUnsupportedForContext else {
            return
        }

        inFlightFingerprint = fingerprint
        defer { inFlightFingerprint = nil }

        do {
            let response: ApplePushRegistrationResponse = try await HTTPClient.shared.post(
                ApplePushRegistrationWire.endpoint,
                body: request
            )
            lastSuccessfulFingerprint = fingerprint
            endpointUnsupportedForContext = nil
            Self.logger.info("Registered APNs token with Silo server_device_id=\(response.serverDeviceId, privacy: .private) enabled=\(response.enabled, privacy: .public)")
        } catch HTTPError.http(let statusCode, _) where statusCode == 404 || statusCode == 405 {
            endpointUnsupportedForContext = fingerprint
            Self.logger.info("Apple push device endpoint is not available on this Silo server yet")
        } catch {
            Self.logger.error("Apple push device registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeRegistrationRequest(deviceToken: Data) -> ApplePushRegistrationRequest {
        ApplePushRegistrationRequest(
            deviceId: AppleDeviceIdentity.current.id,
            apnsToken: ApplePushRegistrationWire.tokenHex(from: deviceToken),
            apnsEnvironment: ApplePushRegistrationWire.currentAPNsEnvironment,
            apnsTopic: ApplePushRegistrationWire.topic(bundleIdentifier: Bundle.main.bundleIdentifier),
            pushMode: ApplePushRegistrationWire.privatePushMode
        )
    }

    private func registrationFingerprint(for request: ApplePushRegistrationRequest) -> String {
        [
            ServerRegistry.shared.activeServerId ?? "",
            AuthService.shared.profileId ?? "",
            request.deviceId,
            request.apnsToken,
            request.apnsEnvironment,
            request.apnsTopic,
            request.pushMode
        ]
        .joined(separator: "|")
    }
}
#endif
