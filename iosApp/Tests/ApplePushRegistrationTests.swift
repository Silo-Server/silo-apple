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

        XCTAssertEqual(url.absoluteString, "https://silo.example.test/api/v2/notifications/push/apple/display/delivery-1")
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

    func testDisplayFetchReadsV2AndRetriesARejectedDisplayTokenWithTheAccessToken() async throws {
        let displayPath = "/api/v2/notifications/push/apple/display/01JZ8T7QK3VX2W4M5N6P7R8S9T"
        let stub = StubURLProtocol.Handler()
        stub.route({ $0.path == displayPath && $0.headers["authorization"] == "Bearer display-token" }) { _ in
            .json(
                #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"Invalid token","status":401}"#,
                status: 401,
                headers: ["Content-Type": "application/problem+json"]
            )
        }
        let display = APIv2FixtureTestSupport.text(named: "notification_apple_push_display", bundleClass: Self.self)
        stub.route({ $0.path == displayPath && $0.headers["authorization"] == "Bearer access" }) { _ in
            .json(display)
        }
        let state = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "access",
            profileToken: "pvt-1",
            displayToken: "display-token"
        )

        let response = try await ApplePushDisplayClient(session: stub.makeSession())
            .fetchDisplay(deliveryID: "01JZ8T7QK3VX2W4M5N6P7R8S9T", state: state)

        XCTAssertEqual(response.title, "Your request was approved")
        XCTAssertEqual(response.category, "request_approved")
        XCTAssertEqual(response.url, "/notifications")
        let requests = stub.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests.map(\.path), [displayPath, displayPath])
        XCTAssertEqual(requests.map { $0.headers["authorization"] }, ["Bearer display-token", "Bearer access"])
        for request in requests {
            XCTAssertEqual(request.headers["x-profile-id"], "profile-1")
            XCTAssertEqual(request.headers["x-profile-token"], "pvt-1")
            XCTAssertEqual(request.headers["accept"], "application/json")
        }
        XCTAssertTrue(stub.unmatched.isEmpty)
    }

    func testDisplayFetchSurfacesANotFoundProblemWithoutRetrying() async {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/notifications/push/apple/display/delivery-1")) { _ in
            .json(
                #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404}"#,
                status: 404,
                headers: ["Content-Type": "application/problem+json"]
            )
        }
        let state = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "access",
            profileToken: "",
            displayToken: "display-token"
        )

        do {
            _ = try await ApplePushDisplayClient(session: stub.makeSession())
                .fetchDisplay(deliveryID: "delivery-1", state: state)
            XCTFail("A 404 must not produce display content")
        } catch {
            XCTAssertEqual(error as? ApplePushDisplayClientError, .badStatus(404))
        }
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertNil(stub.requests.first?.headers["x-profile-token"])
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
