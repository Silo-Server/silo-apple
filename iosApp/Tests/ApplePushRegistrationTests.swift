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

    /// A refused display token falls back to the access token, and a later
    /// transient failure retries with the access token rather than the
    /// refused one. Each request is reported as it goes out, so an expiring
    /// extension can say how far the fetch got.
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
        stub.expect({ $0.path == displayPath && $0.headers["authorization"] == "Bearer access" }) { _ in
            .json(#"{"status":503}"#, status: 503)
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

        let progress = ProgressRecorder()

        let result = await ApplePushDisplayClient(session: stub.makeSession())
            .fetchDisplay(deliveryID: "01JZ8T7QK3VX2W4M5N6P7R8S9T", state: state) { progress.record("\($0) \($1)") }
        let response = try result.outcome.get()

        XCTAssertEqual(result.attempts, 2)
        XCTAssertEqual(result.credential, "access")
        XCTAssertEqual(progress.events, ["1 display", "1 access", "2 access"])
        XCTAssertEqual(response.title, "Your request was approved")
        XCTAssertEqual(response.category, "request_approved")
        XCTAssertEqual(response.url, "/notifications")
        let requests = stub.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET"])
        XCTAssertEqual(requests.map(\.path), [displayPath, displayPath, displayPath])
        XCTAssertEqual(requests.map { $0.headers["authorization"] },
                       ["Bearer display-token", "Bearer access", "Bearer access"])
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

        let result = await ApplePushDisplayClient(session: stub.makeSession())
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        switch result.outcome {
        case .success:
            XCTFail("A 404 must not produce display content")
        case .failure(let error):
            XCTAssertEqual(error as? ApplePushDisplayClientError, .badStatus(404))
        }
        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertNil(stub.requests.first?.headers["x-profile-token"])
    }

    /// A push usually wakes an idle phone: the first request can lose its
    /// connection, and the server, or Cloudflare in front of it, can be
    /// briefly busy. Each is worth another try inside the extension's budget
    /// rather than the generic text, but not a Retry-After past that budget
    /// (Cloudflare asks for 60 or 120 s).
    func testDisplayFetchRetriesTransientFailuresUntilItGetsContent() async throws {
        let displayPath = "/api/v2/notifications/push/apple/display/delivery-1"
        let stub = StubURLProtocol.Handler()
        stub.expect(StubURLProtocol.path(displayPath)) { _ in
            throw URLError(.networkConnectionLost)
        }
        stub.expect(StubURLProtocol.path(displayPath)) { _ in
            .json(
                #"{"type":"https://siloserver.org/docs/api/v2/problems/service_unavailable","title":"Service unavailable","status":503}"#,
                status: 503,
                headers: ["Content-Type": "application/problem+json", "Retry-After": "1"]
            )
        }
        stub.expect(StubURLProtocol.path(displayPath)) { _ in
            .json("", status: 522, headers: ["Retry-After": "1"])
        }
        let display = APIv2FixtureTestSupport.text(named: "notification_apple_push_display", bundleClass: Self.self)
        stub.route(StubURLProtocol.path(displayPath)) { _ in .json(display) }
        let state = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "",
            profileToken: "",
            displayToken: "display-token"
        )

        let result = await ApplePushDisplayClient(session: stub.makeSession())
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        XCTAssertEqual(try result.outcome.get().title, "Your request was approved")
        XCTAssertEqual(result.attempts, 4)
        XCTAssertEqual(stub.requests.count, 4)
        XCTAssertTrue(stub.unmatched.isEmpty)

        let originTimedOut = StubURLProtocol.Handler()
        originTimedOut.route(StubURLProtocol.path(displayPath)) { _ in
            .json("", status: 524, headers: ["Retry-After": "120"])
        }

        let waitedOut = await ApplePushDisplayClient(session: originTimedOut.makeSession())
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        XCTAssertEqual(waitedOut.outcome.failureValue as? ApplePushDisplayClientError,
                       .badStatus(524, retryAfter: 120))
        XCTAssertEqual(waitedOut.attempts, 1)
    }

    /// The extension gets about 30 s per push, and the fetch ends inside its
    /// budget. A 503 whose Retry-After still leaves time admits one more
    /// attempt, and that request is cut off at the budget rather than at its
    /// own timeout. A Retry-After longer than the time left starts nothing,
    /// and a refused display token too close to the end does not start a
    /// fallback request.
    func testDisplayFetchEndsAtTheBudget() async throws {
        let displayPath = "/api/v2/notifications/push/apple/display/delivery-1"
        let state = ApplePushDisplayAuthState(serverURL: "https://silo.example.test", profileID: "profile-1",
            accessToken: "access", profileToken: "", displayToken: "display-token")
        let busyThenHung = StubURLProtocol.Handler()
        busyThenHung.expect(StubURLProtocol.path(displayPath)) { _ in
            .json(#"{"status":503}"#, status: 503, headers: ["Retry-After": "1"])
        }
        let gate = StubURLProtocol.Gate()
        busyThenHung.route(StubURLProtocol.path(displayPath)) { _ in
            await gate.wait()
            return .json("{}")
        }
        let started = Date()

        let cutOff = await ApplePushDisplayClient(session: busyThenHung.makeSession(), budget: 3.5)
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        XCTAssertEqual(cutOff.attempts, 2)
        XCTAssertEqual((cutOff.outcome.failureValue as? URLError)?.code, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)

        let waitTooLong = StubURLProtocol.Handler()
        waitTooLong.route(StubURLProtocol.path(displayPath)) { _ in
            .json(#"{"status":503}"#, status: 503, headers: ["Retry-After": "5"])
        }

        let waitedOut = await ApplePushDisplayClient(session: waitTooLong.makeSession(), budget: 3.5)
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        XCTAssertEqual(waitedOut.attempts, 1)
        XCTAssertEqual(waitTooLong.requests.count, 1)

        let refusing = StubURLProtocol.Handler()
        refusing.route(StubURLProtocol.path(displayPath)) { _ in .json(#"{"status":401}"#, status: 401) }

        let refused = await ApplePushDisplayClient(session: refusing.makeSession(), budget: 1)
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        XCTAssertEqual(refused.outcome.failureValue as? ApplePushDisplayClientError, .badStatus(401))
        XCTAssertEqual(refusing.requests.map { $0.headers["authorization"] }, ["Bearer display-token"])
    }

    /// A busy server or proxy may give `Retry-After` as an HTTP date. One
    /// past the budget is not waited for, so the extension stops at once.
    func testDisplayFetchHonorsAnHTTPDateRetryAfter() async {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.path("/api/v2/notifications/push/apple/display/delivery-1")) { _ in
            .json(#"{"status":503}"#, status: 503, headers: ["Retry-After": "Fri, 01 Jan 2100 00:00:00 GMT"])
        }
        let state = ApplePushDisplayAuthState(serverURL: "https://silo.example.test", profileID: "profile-1",
            accessToken: "", profileToken: "", displayToken: "display-token")

        let result = await ApplePushDisplayClient(session: stub.makeSession())
            .fetchDisplay(deliveryID: "delivery-1", state: state)

        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(stub.requests.count, 1)
    }

    /// Time running out hands the system the content once and records
    /// `expired` with how far the fetch got, even when stopping the fetch
    /// makes it finish with its own outcome at that same moment.
    func testDisplayCompletionRecordsExpiryWhenStoppingTheFetchEndsIt() async {
        let recorded = ProgressRecorder()
        let delivered = ProgressRecorder()
        let completion = ApplePushDisplayCompletion { recorded.record("\($0.kind.rawValue) \($0.attempts) \($0.credential ?? "-")") }
        completion.begin(handler: { delivered.record($0.title) }, startedAt: Date())
        let content = UNMutableNotificationContent()
        content.title = "New notification available"
        completion.setFallback(content)
        completion.progress(attempts: 2, credential: "access")
        let (started, signal) = AsyncStream<Void>.makeStream()
        let fetch = Task {
            await withTaskCancellationHandler {
                signal.yield()
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                completion.complete(with: content, outcome: ApplePushDisplayOutcome(kind: .network,
                    reason: "url_error_-999", attempts: 2, credential: "access", startedAt: Date()))
            }
        }
        for await _ in started { break }
        completion.attach(fetch)

        completion.expire()
        await fetch.value

        XCTAssertEqual(recorded.events, ["expired 2 access"])
        XCTAssertEqual(delivered.events, ["New notification available"])
    }

    /// The extension and the app share these records. The app must read
    /// back what the extension wrote, once, including outcomes recorded at
    /// the same moment, and a phone that rarely opens Silo keeps only the
    /// newest pushes.
    func testDisplayOutcomeLogHandsTheNewestExtensionOutcomesToTheAppOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplePushDisplayOutcomeLogTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let outcomes = (0...ApplePushDisplayOutcomeLog.capacity).map { index in
            ApplePushDisplayOutcome(
                kind: index.isMultiple(of: 2) ? .network : .enriched,
                reason: index.isMultiple(of: 2) ? "url_error_-1001" : nil,
                attempts: 2,
                credential: "display",
                startedAt: startedAt,
                recordedAt: startedAt.addingTimeInterval(TimeInterval(index))
            )
        }

        for outcome in outcomes {
            ApplePushDisplayOutcomeLog.append(outcome, in: directory)
        }

        XCTAssertEqual(ApplePushDisplayOutcomeLog.drain(from: directory), Array(outcomes.dropFirst()))
        XCTAssertEqual(ApplePushDisplayOutcomeLog.drain(from: directory), [])

        // Several pushes can finish at once in one extension process.
        DispatchQueue.concurrentPerform(iterations: ApplePushDisplayOutcomeLog.capacity) { index in
            ApplePushDisplayOutcomeLog.append(outcomes[index], in: directory)
        }
        XCTAssertEqual(Set(ApplePushDisplayOutcomeLog.drain(from: directory).map(\.recordedAt)),
                       Set(outcomes.prefix(ApplePushDisplayOutcomeLog.capacity).map(\.recordedAt)))
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
        let plain = try XCTUnwrap(ApplePushDisplayTarget.parseExpiry("2026-10-03T00:00:00Z"))
        let fractional = try XCTUnwrap(ApplePushDisplayTarget.parseExpiry("2026-10-03T00:00:00.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.25, accuracy: 0.001)
        XCTAssertNil(ApplePushDisplayTarget.parseExpiry("not-a-date"))
    }

    /// A push that names its server and profile is fetched with exactly that
    /// target, whichever server is active. One this device keeps no target
    /// for is not fetched at all, and one that names nothing (an older
    /// server or relay) keeps the active server and profile. An install
    /// updated without the app launching still holds the legacy token and
    /// no targets; its keyed pushes keep the active state until migration.
    func testDisplayRouteUsesExactlyThePushTarget() throws {
        let (defaults, keychain) = try isolatedStorage()
        defaults.set("registry-a", forKey: SharedStorage.activeServerIdKey)
        defaults.set("https://a.example", forKey: SharedStorage.serverUrlKey)
        defaults.set("profile-a", forKey: SharedStorage.profileIdKey)
        defaults.set("registry-a", forKey: SharedStorage.applePushDisplayTokenServerIdKey)
        XCTAssertTrue(keychain.set("access-a", for: SharedStorage.mirroredAccessTokenAccount))
        XCTAssertTrue(keychain.set("proof-a", for: SharedStorage.mirroredProfileTokenAccount))
        XCTAssertTrue(keychain.set("display-a", for: SharedStorage.applePushDisplayTokenAccount))
        let reader = ApplePushDisplayStateReader(defaults: defaults, keychain: keychain)
        func route(_ serverID: String?, _ profileID: String?) -> ApplePushDisplayRoute {
            var userInfo: [AnyHashable: Any] = ["silo_delivery_id": "delivery-1"]
            if let serverID { userInfo["silo_server_id"] = serverID }
            if let profileID { userInfo["silo_profile_id"] = profileID }
            return reader.route(for: userInfo)
        }
        let active = ApplePushDisplayRoute.fetch(ApplePushDisplayAuthState(serverURL: "https://a.example",
            profileID: "profile-a", accessToken: "access-a", profileToken: "proof-a", displayToken: "display-a"))

        // Updated but not yet launched: no targets, only the legacy token.
        XCTAssertEqual(route("deployment-b", "profile-b"), active)
        XCTAssertEqual(route("deployment-a", nil), .unknownTarget)

        let store = ApplePushDisplayTargetStore(keychain: keychain)
        store.migrateLegacyToken(defaults: defaults) {
            ServerEntry(id: $0, url: "https://a.example", fetchedName: nil, lastUsedAt: Date(),
                verifiedServerId: "deployment-a")
        }
        XCTAssertEqual(store.targets(), [Self.target("a", profileID: "profile-a")])
        XCTAssertTrue(store.save(Self.target("b", profileID: "profile-b")))

        // A keyed push carries only its target's token. The mirrored access
        // and profile tokens follow the active server, which can change
        // between two reads, so not even the active target takes them.
        XCTAssertEqual(route("deployment-b", "profile-b"), .fetch(ApplePushDisplayAuthState(
            serverURL: "https://b.example", profileID: "profile-b", accessToken: "", profileToken: "",
            displayToken: "display-b")))
        XCTAssertEqual(route("deployment-a", "profile-a"), .fetch(ApplePushDisplayAuthState(
            serverURL: "https://a.example", profileID: "profile-a", accessToken: "", profileToken: "",
            displayToken: "display-a")))
        XCTAssertEqual(route("deployment-a", "profile-b"), .unknownTarget)
        XCTAssertEqual(route("deployment-c", "profile-a"), .unknownTarget)
        XCTAssertEqual(route("deployment-a", nil), .unknownTarget)
        XCTAssertEqual(route(nil, nil), active)

        // Caught mid-switch, the active target's token stays with the
        // address it was minted for.
        defaults.set("https://c.example", forKey: SharedStorage.serverUrlKey)
        XCTAssertEqual(route(nil, nil), .fetch(ApplePushDisplayAuthState(serverURL: "https://c.example",
            profileID: "profile-a", accessToken: "access-a", profileToken: "proof-a", displayToken: "")))
    }

    /// A tap opens a push's item only under the server and profile the push
    /// belongs to: never under ones a display URL names, and never under a
    /// server that merely reports the identity of a target another saved
    /// server holds. Pushes from older servers name neither and open as
    /// before.
    func testPushLinkOpensOnlyUnderItsServerAndProfile() throws {
        let link = try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "/item/movie-1", "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
        ]))
        let legacyLink = try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: ["silo_url": "/item/movie-1"]))
        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "/item/movie-1", "silo_server_id": "deployment-a",
        ]))
        let (_, keychain) = try isolatedStorage()
        let noTargets = ApplePushDisplayTargetStore(keychain: keychain)
        func server(_ verifiedServerID: String?) -> ServerEntry {
            ServerEntry(id: "registry-a", url: "https://a.example", fetchedName: nil, lastUsedAt: Date(),
                verifiedServerId: verifiedServerID)
        }
        func opens(_ url: URL, _ server: ServerEntry?, _ profileID: String?) -> Bool {
            ApplePushDeepLinkCoordinator.opensUnderActiveIdentity(url, activeServer: server,
                activeProfileID: profileID, targets: noTargets)
        }

        let disguised = try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "silo://item/movie-1?push_server_id=deployment-b&push_profile_id=profile-b",
            "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
        ]))
        let doubled = try XCTUnwrap(URL(string:
            "silo://item/movie-1?push_server_id=deployment-a&push_profile_id=profile-a&push_server_id=deployment-b"))

        XCTAssertTrue(opens(link, server("deployment-a"), "profile-a"))
        XCTAssertTrue(opens(disguised, server("deployment-a"), "profile-a"))
        XCTAssertFalse(opens(disguised, server("deployment-b"), "profile-b"))
        XCTAssertFalse(opens(doubled, server("deployment-a"), "profile-a"))
        XCTAssertFalse(opens(link, server("deployment-a"), "profile-b"))
        XCTAssertFalse(opens(link, server("deployment-a"), nil))
        XCTAssertFalse(opens(link, server("deployment-b"), "profile-a"))
        XCTAssertFalse(opens(link, nil, "profile-a"))
        // A server whose identity was never verified is recognised by the
        // target it registered, and by nothing else.
        XCTAssertFalse(opens(link, server(nil), "profile-a"))
        XCTAssertTrue(noTargets.save(Self.target("a", profileID: "profile-a")))
        XCTAssertTrue(opens(link, server(nil), "profile-a"))
        XCTAssertTrue(opens(legacyLink, server("deployment-b"), nil))

        let (_, otherKeychain) = try isolatedStorage()
        let heldElsewhere = ApplePushDisplayTargetStore(keychain: otherKeychain)
        XCTAssertTrue(heldElsewhere.save(ApplePushDisplayTarget(serverID: "deployment-a", profileID: "profile-a",
            registryServerID: "registry-b", serverURL: "https://b.example", displayToken: "display-b", expiresAt: nil)))
        XCTAssertFalse(ApplePushDeepLinkCoordinator.opensUnderActiveIdentity(link,
            activeServer: server("deployment-a"), activeProfileID: "profile-a", targets: heldElsewhere))
    }

    /// The dispatcher asks before any of its own branches, whatever kind of
    /// link a push carries: a TV approval or a Watch Party invitation from a
    /// push waits for a profile, then opens only under the push's own server
    /// and profile. A link that names no push keeps its own rules.
    func testPushLinksOfEveryKindWaitForAProfileAndOpenOnlyUnderTheirOwn() throws {
        let (_, keychain) = try isolatedStorage()
        let targets = ApplePushDisplayTargetStore(keychain: keychain)
        let server = ServerEntry(id: "registry-a", url: "https://a.example", fetchedName: nil, lastUsedAt: Date(),
            verifiedServerId: "deployment-a")
        func pushLink(_ displayURL: String) throws -> URL {
            try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
                "silo_url": displayURL, "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
            ]))
        }
        func admission(_ url: URL, profileInUse: Bool, profileID: String = "profile-a")
            -> ApplePushDeepLinkCoordinator.Admission {
            ApplePushDeepLinkCoordinator.admission(for: url, profileInUse: profileInUse, activeServer: server,
                activeProfileID: profileID, targets: targets)
        }
        let approval = try pushLink("silo://device?server=deployment-z&code=ABCD2345")
        let party = try pushLink("silo://watch-party?server=https%3A%2F%2Fz.example&token=join-1")
        XCTAssertNotNil(DeviceApprovalLink(url: approval))
        XCTAssertNotNil(WatchPartyInvitation(url: party))

        for link in [approval, party] {
            XCTAssertEqual(admission(link, profileInUse: false), .wait)
            XCTAssertEqual(admission(link, profileInUse: true), .open)
            XCTAssertEqual(admission(link, profileInUse: true, profileID: "profile-b"), .drop)
        }
        let plainApproval = try XCTUnwrap(URL(string: "silo://device?server=deployment-z&code=ABCD2345"))
        XCTAssertEqual(admission(plainApproval, profileInUse: false), .open)
    }

    /// At Who's Watching nothing asks for permission, but with permission
    /// already granted the APNs token that saved servers' maintenance needs
    /// is fetched.
    @MainActor
    func testWithoutAProfileMaintenanceFetchesTheTokenButNeverAsks() async {
        let cases: [(UNAuthorizationStatus, [String])] = [(.authorized, ["token"]), (.notDetermined, []), (.denied, [])]
        for (status, expected) in cases {
            let calls = ProgressRecorder()
            let coordinator = ApplePushRegistrationCoordinator(authorization: ApplePushAuthorizationClient(
                hasAuthenticatedProfile: { false },
                authorizationStatus: { status },
                requestAuthorization: {
                    calls.record("ask")
                    return false
                },
                registerForRemoteNotifications: { calls.record("token") }
            ))

            await coordinator.maintainWithoutProfile()

            XCTAssertEqual(calls.events, expected)
        }
    }

    private func isolatedStorage() throws -> (SharedDefaults, SharedKeychain) {
        let name = "ApplePushRegistrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            for account in [SharedStorage.applePushDisplayTargetsAccount, SharedStorage.applePushDisplayTokenAccount,
                            SharedStorage.mirroredAccessTokenAccount, SharedStorage.mirroredProfileTokenAccount] {
                keychain.delete(account)
            }
        }
        return (SharedDefaults(suite: suite, standard: suite), keychain)
    }

    private static func target(_ server: String, profileID: String) -> ApplePushDisplayTarget {
        ApplePushDisplayTarget(serverID: "deployment-\(server)", profileID: profileID,
            registryServerID: "registry-\(server)", serverURL: "https://\(server).example",
            displayToken: "display-\(server)", expiresAt: nil)
    }

    func testNotificationDisplayURLMapsToAppDeepLink() throws {
        let itemURL = try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "/item/episode-1"
        ]))
        XCTAssertEqual(itemURL.absoluteString, "silo://item/episode-1")

        let absoluteURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "https://silo.example.test/item/movie-123?from=push")
        )
        XCTAssertEqual(absoluteURL.absoluteString, "silo://item/movie-123")

        let existingURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "silo://play/episode-1")
        )
        XCTAssertEqual(existingURL.absoluteString, "silo://play/episode-1")
        let legacyURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "continuum://play/episode-1")
        )
        XCTAssertEqual(legacyURL.absoluteString, "continuum://play/episode-1")

        // Routes are forwarded without an allowlist — ContentView's
        // handleDeepLink owns validity and ignores unknown hosts — so new
        // push destinations can't silently drift out of sync here.
        let forwardedURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "/settings/notifications")
        )
        XCTAssertEqual(forwardedURL.absoluteString, "silo://settings/notifications")

        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "/item"))
        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "   "))
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var events: [String] { lock.withLock { recorded } }
        func record(_ event: String) { lock.withLock { recorded.append(event) } }
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

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
