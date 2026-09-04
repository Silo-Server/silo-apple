import Foundation
import UserNotifications
import XCTest
@testable import Silo

final class ApplePushRegistrationTests: XCTestCase {
    func testTokenHexEncodesToLowercasePaddedHex() {
        let data = Data([0x00, 0x01, 0x0f, 0x10, 0xab, 0xff])

        XCTAssertEqual(ApplePushRegistrationWire.tokenHex(from: data), "00010f10abff")
    }

    func testEmptyBundleIdentifiersFallBackToSiloTopic() {
        XCTAssertEqual(ApplePushRegistrationWire.topic(bundleIdentifier: nil), "org.siloserver.silo")
        XCTAssertEqual(ApplePushRegistrationWire.topic(bundleIdentifier: "   "), "org.siloserver.silo")
        XCTAssertEqual(ApplePushRegistrationWire.topic(bundleIdentifier: "org.example.app"), "org.example.app")
    }

    func testAPNsEnvironmentParsesFromProvisioningProfile() {
        XCTAssertEqual(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: "development")
            ),
            "sandbox"
        )
        XCTAssertEqual(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: "production")
            ),
            "production"
        )
    }

    func testAPNsEnvironmentIsNilWithoutPushEntitlement() {
        XCTAssertNil(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: nil)
            )
        )
        XCTAssertNil(ApplePushRegistrationWire.apnsEnvironment(fromProvisioningProfile: Data([0x30, 0x82, 0x01])))
        XCTAssertNil(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: "bogus")
            )
        )
    }

    func testNotificationSyncQueryIncludesLimitAndOptionalCursor() {
        XCTAssertEqual(ApplePushNotificationSyncWire.query(since: nil), ["limit": "50"])
        XCTAssertEqual(ApplePushNotificationSyncWire.query(since: "cursor"), [
            "limit": "50",
            "since": "cursor"
        ])
    }

    func testNotificationSyncResponseDecodesSnakeCasePayload() throws {
        let json = """
        {
          "notifications": [
            {
              "id": "delivery-1",
              "type": "new_episode",
              "profile_id": "profile-1",
              "series_title": "Example",
              "reason_flags": {"watchlist": true},
              "created_at": "2026-07-01T12:30:00Z",
              "read_at": null
            }
          ],
          "next_cursor": "cursor-1",
          "unread_count": 3
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(ApplePushNotificationSyncResponse.self, from: json)

        XCTAssertEqual(response.notifications.count, 1)
        XCTAssertEqual(response.notifications.first?.id, "delivery-1")
        XCTAssertEqual(response.notifications.first?.profileId, "profile-1")
        XCTAssertNotNil(response.notifications.first?.createdAt)
        XCTAssertNil(response.notifications.first?.readAt)
        XCTAssertEqual(response.nextCursor, "cursor-1")
        XCTAssertEqual(response.unreadCount, 3)
    }

    func testNotificationDisplayDeliveryIDParsesFromAPNsPayload() {
        XCTAssertEqual(ApplePushDisplayWire.deliveryID(from: ["silo_delivery_id": "  delivery-1  "]), "delivery-1")
        XCTAssertNil(ApplePushDisplayWire.deliveryID(from: ["silo_delivery_id": "   "]))
        XCTAssertNil(ApplePushDisplayWire.deliveryID(from: [:]))
    }

    func testNotificationDisplayEndpointURLAppendsDeliveryID() throws {
        let url = try XCTUnwrap(ApplePushDisplayWire.displayURL(
            serverURL: "https://silo.example.test/",
            deliveryID: "delivery-1"
        ))

        XCTAssertEqual(url.absoluteString, "https://silo.example.test/api/v1/notifications/push/apple/display/delivery-1")
    }

    func testNotificationDisplayResponseDecodesAndMutatesNotificationContent() throws {
        let json = """
        {
          "delivery_id": "delivery-1",
          "title": "New episode of Example",
          "body": "S1E2 - Pilot",
          "thread_id": "series:series-1",
          "category": "episode_available",
          "url": "/item/episode-1"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ApplePushDisplayResponse.self, from: json)
        let content = UNMutableNotificationContent()
        content.title = "Silo"
        content.body = "New notification available"
        content.userInfo = ["silo_delivery_id": "delivery-1"]

        response.apply(to: content)

        XCTAssertEqual(content.title, "New episode of Example")
        XCTAssertEqual(content.body, "S1E2 - Pilot")
        XCTAssertEqual(content.threadIdentifier, "series:series-1")
        XCTAssertEqual(content.categoryIdentifier, "episode_available")
        XCTAssertEqual(content.userInfo["silo_delivery_id"] as? String, "delivery-1")
        XCTAssertEqual(content.userInfo["silo_url"] as? String, "/item/episode-1")
    }

    func testDisplayAuthStatePrefersDisplayTokenOverAccessToken() {
        let withDisplay = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "expired-access",
            profileToken: "",
            displayToken: " display-token "
        )
        XCTAssertTrue(withDisplay.isUsable)
        XCTAssertEqual(withDisplay.bearerToken, "display-token")

        // Older servers return no display token: the access token still works.
        let legacy = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "access",
            profileToken: ""
        )
        XCTAssertTrue(legacy.isUsable)
        XCTAssertEqual(legacy.bearerToken, "access")

        // A display token alone is enough: the access mirror may be gone
        // after a refresh race while the registration token remains valid.
        let displayOnly = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "",
            profileToken: "",
            displayToken: "display-token"
        )
        XCTAssertTrue(displayOnly.isUsable)

        let neither = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "  ",
            profileToken: ""
        )
        XCTAssertFalse(neither.isUsable)

        // A rejected display token falls back to the access token once;
        // without a distinct access token there is nothing to retry with.
        let fallback = try? XCTUnwrap(withDisplay.accessTokenFallback)
        XCTAssertEqual(fallback?.bearerToken, "expired-access")
        XCTAssertEqual(fallback?.displayToken, "")
        XCTAssertNil(legacy.accessTokenFallback)
        XCTAssertNil(displayOnly.accessTokenFallback)
    }

    func testRegistrationResponseDecodesOptionalDisplayToken() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let modern = try decoder.decode(ApplePushRegistrationResponse.self, from: Data("""
        {"id":"push-1","server_device_id":"dev-1","enabled":true,"push_mode":"private_push","display_token":"tok","display_token_expires_at":"2026-10-03T00:00:00Z"}
        """.utf8))
        XCTAssertEqual(modern.displayToken, "tok")
        XCTAssertEqual(modern.displayTokenExpiresAt, "2026-10-03T00:00:00Z")

        let legacy = try decoder.decode(ApplePushRegistrationResponse.self, from: Data("""
        {"id":"push-1","server_device_id":"dev-1","enabled":true,"push_mode":"private_push"}
        """.utf8))
        XCTAssertNil(legacy.displayToken)
        XCTAssertNil(legacy.displayTokenExpiresAt)
    }

    func testDisplayTokenExpiryParsesWithAndWithoutFractionalSeconds() throws {
        let plain = try XCTUnwrap(ApplePushDisplayTokenStore.parseExpiry("2026-10-03T00:00:00Z"))
        let fractional = try XCTUnwrap(ApplePushDisplayTokenStore.parseExpiry("2026-10-03T00:00:00.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.25, accuracy: 0.001)
        XCTAssertNil(ApplePushDisplayTokenStore.parseExpiry("not-a-date"))
    }

    func testNotificationDisplayURLMapsToAppDeepLink() throws {
        let itemURL = try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "/item/episode-1"
        ]))
        XCTAssertEqual(itemURL.absoluteString, "continuum://item/episode-1")

        let absoluteURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "https://silo.example.test/item/movie-123?from=push")
        )
        XCTAssertEqual(absoluteURL.absoluteString, "continuum://item/movie-123")

        let existingURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "continuum://play/episode-1")
        )
        XCTAssertEqual(existingURL.absoluteString, "continuum://play/episode-1")

        // Routes are forwarded without an allowlist — ContentView's
        // handleDeepLink owns validity and ignores unknown hosts — so new
        // push destinations can't silently drift out of sync here.
        let forwardedURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "/settings/notifications")
        )
        XCTAssertEqual(forwardedURL.absoluteString, "continuum://settings/notifications")

        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "/item"))
        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "   "))
    }

    /// Builds a fake `embedded.mobileprovision`: an XML plist wrapped in
    /// leading/trailing binary junk, like the real CMS envelope.
    private static func provisioningProfileData(apsEnvironment: String?) -> Data {
        let entitlement = apsEnvironment.map {
            "<key>aps-environment</key><string>\($0)</string>"
        } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Test Profile</string>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key><string>TEAMID.org.example.app</string>
                \(entitlement)
            </dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x0a, 0x0b])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x01, 0x02]))
        return data
    }
}
