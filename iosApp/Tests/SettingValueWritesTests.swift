import Foundation
import XCTest
@testable import Silo

/// The v2 settings value writes on the wire: request shape without mutation
/// ids, the exact success status and receipt checks, the owner fence, and how
/// each failure maps onto the D4 write-failure classes.
final class SettingValueWritesTests: XCTestCase {
    private static let profile = "profile-under-test"
    private static let validationProblem = "https://siloserver.org/docs/api/v2/problems/validation_failed"

    private var stub: APIv2TestStub!
    private var tokenStore: TokenStore!
    private var api: SiloAPI!

    override func setUp() async throws {
        try await super.setUp()
        let name = "SettingValueWritesTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        tokenStore = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server-a")
        await tokenStore.setServerUrl("https://settings.example")
        await tokenStore.setProfileId(Self.profile)
        stub = APIv2TestStub()
        api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokenStore), tokenStore: tokenStore)
    }

    private func receipt(
        key: String,
        scope: String,
        value: String,
        revision: Int = 4,
        deviceId: String? = nil,
        clientFamily: String? = nil,
        libraryId: String? = nil
    ) -> String {
        var fields = [
            #""key":"\#(key)""#,
            #""scope":"\#(scope)""#,
            #""profile_id":"\#(Self.profile)""#,
            #""value":\#(value)"#,
            #""revision":\#(revision)"#,
        ]
        if let deviceId { fields.append(#""device_id":"\#(deviceId)""#) }
        if let clientFamily { fields.append(#""client_family":"\#(clientFamily)""#) }
        if let libraryId { fields.append(#""library_id":"\#(libraryId)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func problem(_ status: Int, type: String? = nil, location: String? = nil) -> String {
        let errors = location.map { #","errors":[{"location":"\#($0)","code":"invalid","detail":"rejected"}]"# } ?? ""
        let type = type ?? "https://siloserver.org/docs/api/v2/problems/status_\(status)"
        return #"{"type":"\#(type)","title":"Problem","status":\#(status),"detail":"rejected"\#(errors)}"#
    }

    // MARK: - Request shape

    func testPutValueSendsTheDesiredValueWithoutAMutationId() async throws {
        let device = AppleDeviceIdentity.current
        stub.reply(200, receipt(
            key: "playback.subtitle_appearance",
            scope: "profile_device",
            value: #"{"backgroundOpacity":75,"fontSize":"large"}"#,
            deviceId: device.id
        ))

        let stored = try await api.putValue(
            key: .playbackSubtitleAppearance,
            scope: .profileDevice,
            value: ["fontSize": "large", "backgroundOpacity": 75]
        )

        XCTAssertEqual(stored.settingKey, .playbackSubtitleAppearance)
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v2/settings/values/playback.subtitle_appearance")
        XCTAssertEqual(request.query, ["scope": "profile_device"], "profile_id is never sent")
        XCTAssertEqual(request.header("X-Profile-Id"), Self.profile)
        XCTAssertEqual(request.header("X-Silo-Device-Id"), device.id)
        XCTAssertEqual(request.header("X-Silo-Client-Family"), device.clientFamily)
        XCTAssertNil(request.header("X-Silo-Mutation-Id"))
        // The body schema is closed: exactly `value`, with the value's own
        // camelCase keys untouched.
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"value":{"backgroundOpacity":75,"fontSize":"large"}}"#
        )
    }

    func testLibraryScopedWriteSendsAndChecksTheStringLibraryId() async throws {
        stub.reply(200, receipt(
            key: "playback.subtitle_language", scope: "profile_library", value: #""ja""#, libraryId: "7"
        ))

        let stored = try await api.putValue(
            key: .playbackSubtitleLanguage,
            scope: .profileLibrary(libraryId: 7),
            value: "ja"
        )

        XCTAssertEqual(stored.libraryId, "7")
        XCTAssertEqual(stub.requests.last?.query, ["scope": "profile_library", "library_id": "7"])
    }

    func testShortcutWriteSendsItemAndPresenceOnly() async throws {
        let item = PrimaryMenuItem.section(libraryId: 7, sectionId: "recently-added", label: "Recently Added")
        stub.reply(200, receipt(key: "nav.shortcuts", scope: "profile", value: #"{"items":[]}"#))

        try await api.putNavigationShortcutItem(item, present: true)

        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v2/settings/values/nav.shortcuts/item")
        XCTAssertTrue(request.query.isEmpty)
        XCTAssertNil(request.header("X-Silo-Mutation-Id"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["item", "present"])
        XCTAssertEqual(object["present"] as? Bool, true)
        let encoded = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(encoded["type"] as? String, "section")
        XCTAssertEqual(encoded["section_id"] as? String, "recently-added")
    }

    func testBuiltinShortcutIsRefusedBeforeSending() async throws {
        do {
            try await api.putNavigationShortcutItem(.builtin(.home), present: true)
            XCTFail("built-in destinations are not shortcuts")
        } catch let error as SettingsAPIError {
            guard case .invalidValue = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testDeleteExpectsNoContentAndTreatsAMissingRowAsCleared() async throws {
        stub.reply(204, "")
        try await api.deleteValue(key: .navPrimaryMenu, scope: .profileClient)
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/api/v2/settings/values/nav.primary_menu")
        XCTAssertEqual(request.query, ["scope": "profile_client"])

        stub.reply(404, problem(404, type: "https://siloserver.org/docs/api/v2/problems/not_found"))
        do {
            try await api.deleteValue(key: .navPrimaryMenu, scope: .profileClient)
            XCTFail("a delete with nothing stored must report .noValueAtScope")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .noValueAtScope)
        }
    }

    // MARK: - Status and receipt checks

    func testWriteAcceptsOnlyItsDeclaredStatus() async throws {
        stub.reply(201, receipt(key: "ui.card_presentation", scope: "profile", value: "{}"))
        do {
            try await api.putValue(key: .uiCardPresentation, scope: .profile, value: [:])
            XCTFail("only 200 is a successful write")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .server(status: 201, code: nil, message: nil))
        }

        stub.reply(200, "")
        do {
            try await api.deleteValue(key: .uiCardPresentation, scope: .profile)
            XCTFail("only 204 is a successful delete")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .server(status: 200, code: nil, message: nil))
        }
    }

    func testReceiptForAnotherRowIsAnUncertainOutcome() async throws {
        let device = AppleDeviceIdentity.current
        let mismatches = [
            receipt(key: "playback.hdr_enabled", scope: "profile_device", value: "false", deviceId: device.id),
            receipt(key: "player.hdr_enabled", scope: "profile", value: "false"),
            receipt(key: "player.hdr_enabled", scope: "profile_device", value: "false", deviceId: "another-device"),
            receipt(key: "player.hdr_enabled", scope: "profile_device", value: "false", revision: 0, deviceId: device.id),
        ]
        for body in mismatches {
            stub.reply(200, body)
            do {
                try await api.putValue(key: .playerHdrEnabled, scope: .profileDevice, value: false)
                XCTFail("accepted a receipt for another row: \(body)")
            } catch let error as SettingsAPIError {
                guard case .transport = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(error.writeFailure, .retry, "the write may or may not have landed")
            }
        }
    }

    // MARK: - Owner fence

    func testWriteForAnotherProfileIsNeverSent() async throws {
        do {
            try await api.putValue(
                key: .playerHdrEnabled, scope: .profileDevice, value: false, profileId: "captured-earlier"
            )
            XCTFail("a write captured for another profile must not be sent")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .ownerChanged)
            XCTAssertEqual(error.writeFailure, .ownerChanged)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testAnswerArrivingAfterAProfileSwitchIsDiscarded() async throws {
        let device = AppleDeviceIdentity.current
        stub.reply(200, receipt(key: "player.hdr_enabled", scope: "profile_device", value: "false", deviceId: device.id))
        stub.hold()
        let write = Task {
            try await api.putValue(key: .playerHdrEnabled, scope: .profileDevice, value: false)
        }
        await stub.waitUntilHeld()
        await tokenStore.setProfileId("someone-else")
        stub.release()

        do {
            _ = try await write.value
            XCTFail("an answer for the previous profile must not be applied")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .ownerChanged)
        }
    }

    // MARK: - Expired bearer

    /// Value writes are `natural_idempotent`: an expired bearer refreshes once
    /// and the same write goes out again, so it never enters the D4 backoff
    /// resending the stale token.
    func testExpiredBearerRefreshesAndResendsTheWriteOnce() async throws {
        await tokenStore.saveTokens(accessToken: "expired-access", refreshToken: "refresh-a")
        let device = AppleDeviceIdentity.current
        stub.sequence([
            .json(401, problem(401, type: "https://siloserver.org/docs/api/v2/problems/unauthorized")),
            .json(200, #"{"access_token":"fresh-access","refresh_token":"refresh-b","expires_in":3600}"#),
            .json(200, receipt(key: "player.hdr_enabled", scope: "profile_device", value: "false", deviceId: device.id)),
        ])

        let stored = try await api.putValue(key: .playerHdrEnabled, scope: .profileDevice, value: false)

        XCTAssertEqual(stored.settingKey, .playerHdrEnabled)
        XCTAssertEqual(stub.requests.map { "\($0.method) \($0.path)" }, [
            "PUT /api/v2/settings/values/player.hdr_enabled",
            "POST /api/v2/auth/refresh",
            "PUT /api/v2/settings/values/player.hdr_enabled",
        ])
        XCTAssertEqual(stub.requests.first?.header("Authorization"), "Bearer expired-access")
        XCTAssertEqual(stub.requests.last?.header("Authorization"), "Bearer fresh-access")
    }

    // MARK: - Failure classes (owner decision D4)

    func testProblemsMapOntoSettingsErrorsAndWriteFailures() async throws {
        let cases: [(reply: APIv2TestStub.Reply, expected: SettingsAPIError, failure: SettingWriteFailure)] = [
            (.json(422, problem(422, type: Self.validationProblem, location: "path.key")),
             .unknownSetting(key: "player.hdr_enabled"), .release),
            (.json(422, problem(422, type: Self.validationProblem, location: "query.scope")),
             .scopeNotAllowed(key: "player.hdr_enabled", scope: .profileDevice), .release),
            (.json(422, problem(422, type: Self.validationProblem, location: "body.value")),
             .invalidValue(message: "rejected"), .release),
            (.json(403, problem(403, type: "https://siloserver.org/docs/api/v2/problems/forbidden")),
             .server(status: 403, code: "forbidden", message: "rejected"), .release),
            (.json(429, problem(429, type: "https://siloserver.org/docs/api/v2/problems/rate_limited")),
             .server(status: 429, code: "rate_limited", message: "rejected"), .retry),
            (.json(503, problem(503, type: "https://siloserver.org/docs/api/v2/problems/unavailable")),
             .server(status: 503, code: "unavailable", message: "rejected"), .retry),
            (.text(404, "404 page not found", contentType: "text/plain"), .serverUpgradeRequired, .waitForCondition),
        ]
        for (reply, expected, failure) in cases {
            stub.reply(reply)
            do {
                try await api.putValue(key: .playerHdrEnabled, scope: .profileDevice, value: false)
                XCTFail("expected \(expected)")
            } catch let error as SettingsAPIError {
                XCTAssertEqual(error, expected)
                XCTAssertEqual(error.writeFailure, failure, "\(expected)")
            }
        }

        stub.fail(.networkConnectionLost)
        do {
            try await api.putValue(key: .playerHdrEnabled, scope: .profileDevice, value: false)
            XCTFail("a lost connection must throw")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error.writeFailure, .retry, "a write lost in flight is retried within the bound")
        }
    }

    func testShortcutConflictIsRetryable() async throws {
        stub.reply(409, problem(409, type: "https://siloserver.org/docs/api/v2/problems/conflict"))
        do {
            try await api.putNavigationShortcutItem(
                .library(libraryId: 3, label: "Films"), present: true
            )
            XCTFail("a 409 must throw")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error.writeFailure, .retry, "the server's compare-and-set lost; the request may be sent again")
        }
    }

    func testRetryScheduleIsBounded() {
        let policy = SettingWriteRetryPolicy.default
        XCTAssertEqual(policy.maximumAutomaticRetries, 5)
        XCTAssertEqual((1...8).map(policy.delay(forAttempt:)), [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60),
        ])
    }
}
