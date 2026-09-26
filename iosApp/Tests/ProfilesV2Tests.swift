import Foundation
import XCTest
@testable import Silo

/// The `SiloAPI` profile and user-library calls on `/api/v2`: the wire shape
/// each one sends, the status it accepts, and what the new-profile form
/// reports for each way the `non_retryable` create can fail. Owner fencing
/// for these client methods is covered by `CatalogV2Tests`.
final class ProfilesV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func api(profileId: String? = nil) async throws -> SiloAPI {
        try await client(profileId: profileId).api
    }

    private func client(profileId: String? = nil) async throws -> (api: SiloAPI, tokens: TokenStore) {
        let name = "ProfilesV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://profiles.example")
        if let profileId { await tokens.setProfileId(profileId) }
        return (SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens), tokens)
    }

    private func profileJSON(id: String = "p-owner") throws -> String {
        let data = try APIv2FixtureTestSupport.mutatedBody(named: "update_profile_ok", bundleClass: Self.self) {
            $0["id"] = id
        }
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func body(_ request: StubURLProtocol.Request) throws -> [String: Any] {
        try APIv2FixtureTestSupport.jsonObject(XCTUnwrap(request.body))
    }

    private static func problem(_ type: String, status: Int, detail: String, errors: String = "") -> String {
        let extra = errors.isEmpty ? "" : #","errors":\#(errors)"#
        return #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"\#(type)","status":\#(status),"detail":"\#(detail)"\#(extra)}"#
    }

    // MARK: User libraries

    func testLibrariesReadTheV2CollectionAndKeepOnlySupportedTypes() async throws {
        let api = try await api()
        stub.reply(200, """
            {"items":[
              {"id":"1","name":"Movies","type":"movies","sort_order":0},
              {"id":"4","name":"Music","type":"music","sort_order":1},
              {"id":"8","name":"Mixed","type":"mixed","sort_order":2,"poster_url":"/posters/8.jpg"}
            ]}
            """)

        let response = try await api.libraries()

        XCTAssertEqual(response.libraries.map(\.id), [1, 8])
        XCTAssertEqual(response.libraries.map(\.sortOrder), [0, 2])
        XCTAssertEqual(stub.methods, ["GET"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/user/libraries"])
    }

    func testLibrariesFailInsteadOfDroppingARowWithANonNumericID() async throws {
        let api = try await api()
        stub.reply(200, #"{"items":[{"id":"lib-a","name":"Movies","type":"movies","sort_order":0}]}"#)
        do {
            _ = try await api.libraries()
            XCTFail("A library the app cannot address must fail the read, not vanish from it")
        } catch APIv2Error.unsupportedCatalogReadValue { }
    }

    func testLibrariesFailOnAnUnexpectedStatus() async throws {
        let api = try await api()
        stub.reply(503, Self.problem("dependency_unavailable", status: 503, detail: "Try later"))
        do {
            _ = try await api.libraries()
            XCTFail("A failed read must throw, never read as an empty list")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 503)
        }
    }

    // MARK: Profiles

    func testListProfilesReadsTheV2Collection() async throws {
        let api = try await api()
        stub.reply(200, #"{"avatar_upload_enabled":true,"items":[\#(try profileJSON())]}"#)

        let profiles = try await api.listProfiles()

        XCTAssertEqual(profiles.map(\.id), ["p-owner"])
        XCTAssertEqual(profiles.first?.avatarEmoji, "preset:fox")
        XCTAssertEqual(profiles.first?.isPrimary, true)
        XCTAssertEqual(stub.methods, ["GET"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/profiles"])
    }

    func testVerifyPINPostsToTheV2RouteAndReturnsTheProof() async throws {
        let api = try await api()
        stub.reply(200, #"{"valid":true,"profile_token":"pvt_one","expires_at":null}"#)

        let token = try await api.verifyProfileSelection(profileId: "p/2", pin: "1234")

        XCTAssertEqual(token, "pvt_one")
        XCTAssertEqual(stub.methods, ["POST"])
        XCTAssertEqual(stub.requests.first?.url?.absoluteString,
                       "https://profiles.example/api/v2/profiles/p%2F2/verify-pin")
        XCTAssertEqual(try body(XCTUnwrap(stub.requests.first)) as? [String: String], ["pin": "1234"])
    }

    func testWrongPINIsReportedAsAnIncorrectPINNotAnExpiredSession() async throws {
        let api = try await api()
        stub.reply(200, #"{"valid":false,"expires_at":null}"#)
        do {
            _ = try await api.verifyProfileSelection(profileId: "p-2", pin: "0000")
            XCTFail("A PIN the server rejected must throw")
        } catch ProfileTransitionError.incorrectPIN {
            XCTAssertNil(ErrorState(ProfileTransitionError.incorrectPIN).statusCode)
        }
    }

    func testProfileWithoutAPINIsSelectedWithoutARequest() async throws {
        let api = try await api()
        let token = try await api.verifyProfileSelection(profileId: "p-2", pin: nil)
        XCTAssertNil(token)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testCreateProfileSendsStringLibraryIDsAndAccepts201() async throws {
        let api = try await api(profileId: "p-owner")
        stub.reply(201, try profileJSON(id: "p-new"), headers: ["Location": "/api/v2/profiles/p-new"])

        let created = try await api.createProfile(
            name: "Kid", avatarEmoji: "preset:fox", pin: nil, isChild: true, maxContentRating: "PG",
            libraryRestrictionsEnabled: true, allowedLibraryIds: [3, 12]
        )

        XCTAssertEqual(created.id, "p-new")
        XCTAssertEqual(stub.methods, ["POST"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/profiles"])
        let sent = try body(XCTUnwrap(stub.requests.first))
        XCTAssertEqual(sent["allowed_library_ids"] as? [String], ["3", "12"])
        XCTAssertEqual(sent["max_content_rating"] as? String, "PG")
        XCTAssertEqual(sent["library_restrictions_enabled"] as? Bool, true)
        XCTAssertNil(sent["pin"], "an unset PIN is omitted; create does not accept null")
    }

    func testCreateProfileRejectsASuccessStatusOtherThan201() async throws {
        let api = try await api(profileId: "p-owner")
        stub.reply(200, try profileJSON(id: "p-new"))
        do {
            _ = try await api.createProfile(name: "Kid", avatarEmoji: nil, pin: nil, isChild: false)
            XCTFail("Create requires exactly 201")
        } catch APIv2Error.httpStatus(200) { }
    }

    func testUpdateProfilePatchesTheActiveProfileWithClearingNulls() async throws {
        let api = try await api(profileId: "p-owner")
        stub.reply(200, try profileJSON())
        var update = UpdateProfileBody()
        update.subtitleLanguage = ""
        update.autoSkipIntro = true

        try await api.updateProfile(profileId: "p-owner", body: update)

        XCTAssertEqual(stub.methods, ["PATCH"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/profiles/p-owner"])
        let sent = try body(XCTUnwrap(stub.requests.first))
        XCTAssertEqual(Set(sent.keys), ["subtitle_language", "auto_skip_intro"])
        XCTAssertTrue(sent["subtitle_language"] is NSNull)
    }

    // MARK: Create failure outcomes

    func testCreateConflictShowsTheServerReasonAndKeepsTheFormOpen() async throws {
        let api = try await api(profileId: "p-owner")
        stub.reply(409, Self.problem("conflict", status: 409, detail: "This account has reached its profile limit (5)"))
        let failure = await createFailure(api)
        XCTAssertEqual(failure, CreateProfileFailure(
            title: "Can't Create Profile", message: "This account has reached its profile limit (5)"))
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testCreateValidationFailureShowsTheMemberReason() async throws {
        let api = try await api(profileId: "p-owner")
        stub.reply(422, Self.problem("validation_failed", status: 422,
            detail: "The request did not pass validation; see errors.",
            errors: #"[{"location":"body.allowed_library_ids","code":"invalid","detail":"unknown library identifier: 9"}]"#))
        let failure = await createFailure(api)
        XCTAssertEqual(failure.message, "unknown library identifier: 9")
        XCTAssertFalse(failure.closesForm)
    }

    func testCreateThatNeverConnectedIsADefiniteFailure() async throws {
        let api = try await api(profileId: "p-owner")
        stub.fail(.cannotConnectToHost)
        let failure = await createFailure(api)
        XCTAssertEqual(failure.title, "Couldn't Create Profile")
        XCTAssertFalse(failure.closesForm)
    }

    /// Sent without an answer: the profile may exist, so the form is closed
    /// to show the refreshed list and the request is not sent again.
    func testUnansweredCreateIsNotResentAndClosesTheForm() async throws {
        let api = try await api(profileId: "p-owner")
        stub.fail(.networkConnectionLost)
        let failure = await createFailure(api)
        XCTAssertEqual(failure.title, "Profile May Have Been Created")
        XCTAssertTrue(failure.closesForm)
        XCTAssertEqual(stub.requests.count, 1)
    }

    /// The owner fence discards a 201 that arrives after the profile changed.
    /// The server has already created the profile, so the form must close
    /// rather than invite a retry, and nothing is re-sent.
    func testCreateAnsweredAfterAnOwnerChangeIsNotResentAndClosesTheForm() async throws {
        let (api, tokens) = try await client(profileId: "p-owner")
        stub.reply(201, try profileJSON(id: "p-new"), headers: ["Location": "/api/v2/profiles/p-new"])
        stub.hold()
        let create = Task { await createFailure(api) }
        await stub.waitUntilHeld()
        await tokens.setProfileId("p-other")
        stub.release()

        let failure = await create.value
        XCTAssertEqual(failure.title, "Profile May Have Been Created")
        XCTAssertTrue(failure.closesForm)
        XCTAssertEqual(stub.requests.count, 1)
    }

    /// A 2xx other than the declared 201 means the server acted: the profile
    /// may exist, so the form closes instead of inviting a duplicate.
    func testCreateAnsweredWithAnUnexpectedSuccessStatusClosesTheForm() {
        let failure = CreateProfileFailure(APIv2Error.httpStatus(200))
        XCTAssertEqual(failure.title, "Profile May Have Been Created")
        XCTAssertTrue(failure.closesForm)
        XCTAssertEqual(MutationDelivery(APIv2Error.httpStatus(204)), .unconfirmed)
        XCTAssertEqual(MutationDelivery(APIv2Error.httpStatus(500)), .definite)
    }

    /// v2 refuses profile writes from non-admins on a demo-mode server with a
    /// 403 `permission_denied` whose detail says so; the form shows it rather
    /// than a generic or session-expired message.
    func testCreateRefusedOnADemoServerShowsTheServerReason() async throws {
        let api = try await api(profileId: "p-owner")
        stub.reply(403, Self.problem("permission_denied", status: 403,
            detail: "This action is not available in demo mode."))
        let failure = await createFailure(api)
        XCTAssertEqual(failure, CreateProfileFailure(
            title: "Can't Create Profile", message: "This action is not available in demo mode."))
        XCTAssertEqual(stub.requests.count, 1)
    }

    private func createFailure(_ api: SiloAPI) async -> CreateProfileFailure {
        do {
            _ = try await api.createProfile(name: "Kid", avatarEmoji: nil, pin: nil, isChild: false)
            XCTFail("Expected the create to fail")
            return CreateProfileFailure(message: "")
        } catch {
            return CreateProfileFailure(error)
        }
    }
}
