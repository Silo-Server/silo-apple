import Foundation
import XCTest
@testable import Silo

/// Decodes every vendored API v2 fixture with the production decoder and
/// checks the members the app consumes, the deliberate null/absence
/// semantics, and forward-compatible decoding of unknown members and enum
/// values.
final class APIv2ContractTests: XCTestCase {
    private typealias Support = APIv2FixtureTestSupport

    private var decoder: JSONDecoder { Support.decoder }

    private func fixture(_ name: String) throws -> Data {
        try Support.data(named: name, bundleClass: Self.self)
    }

    private func entry(_ name: String) throws -> Support.IndexEntry {
        try Support.entry(named: name, bundleClass: Self.self)
    }

    // MARK: Index routing

    /// Every vendored fixture: its index entry names the status and media
    /// type the model layer routes on, and the body decodes as that type.
    func testEveryVendoredFixtureRoutesByStatusAndMediaType() throws {
        let entries = try Support.index(bundleClass: Self.self)
        XCTAssertEqual(entries.count, 34, "vendored index must list exactly the selected fixtures")
        for entry in entries {
            let data = try fixture(entry.name)
            XCTAssertEqual(entry.responseHeaders["Content-Type"], entry.responseMediaType, entry.name)
            XCTAssertTrue(entry.request.path.hasPrefix("/api/v2/"), "\(entry.name) is not a v2 path")
            if (200..<300).contains(entry.expectedStatus) {
                XCTAssertEqual(entry.responseMediaType, "application/json", entry.name)
                XCTAssertFalse(entry.schema.hasSuffix("/Problem"), entry.name)
            } else {
                XCTAssertEqual(entry.responseMediaType, "application/problem+json", entry.name)
                XCTAssertEqual(entry.schema, "#/components/schemas/Problem", entry.name)
                let problem = try decoder.decode(APIv2Problem.self, from: data)
                XCTAssertEqual(problem.status, entry.expectedStatus, entry.name)
            }
        }
    }

    // MARK: getSetupStatus

    func testSetupStatusFixture() throws {
        let entry = try entry("get_setup_status_ok")
        XCTAssertEqual(entry.operationId, "getSetupStatus")
        XCTAssertEqual(entry.request.method, "GET")
        XCTAssertEqual(entry.request.path, "/api/v2/system/setup")
        XCTAssertNil(entry.request.headers?["Authorization"], "public operation")
        let status = try decoder.decode(APIv2SetupStatus.self, from: fixture("get_setup_status_ok"))
        XCTAssertFalse(status.needsSetup)
    }

    // MARK: getCurrentUser

    func testCurrentUserFixture() throws {
        let entry = try entry("get_current_user_ok")
        XCTAssertEqual(entry.operationId, "getCurrentUser")
        XCTAssertEqual(entry.request.path, "/api/v2/account/me")
        XCTAssertNotNil(entry.request.headers?["Authorization"], "authenticated operation")
        let account = try decoder.decode(APIv2Account.self, from: fixture("get_current_user_ok"))
        XCTAssertEqual(account.id, "1")
        XCTAssertEqual(account.username, "laura")
        XCTAssertEqual(account.email, "laura@example.test")
        XCTAssertEqual(account.role, .user)
        XCTAssertEqual(account.permissions, ["marker_edit"])
        XCTAssertTrue(account.downloadAllowed)
        XCTAssertNil(account.impersonation, "impersonation is absent outside an impersonation session")
    }

    func testCurrentUserImpersonationDecodesWhenPresent() throws {
        let data = try Support.mutatedBody(named: "get_current_user_ok", bundleClass: Self.self) {
            $0["impersonation"] = [
                "active": true,
                "impersonator_user_id": "7",
                "impersonator_username": "root",
            ]
        }
        let account = try decoder.decode(APIv2Account.self, from: data)
        XCTAssertEqual(
            account.impersonation,
            APIv2Impersonation(active: true, impersonatorUserId: "7", impersonatorUsername: "root")
        )
    }

    func testCurrentUserToleratesUnknownMemberAndUnknownRole() throws {
        let data = try Support.mutatedBody(named: "get_current_user_ok", bundleClass: Self.self) {
            $0["future_member"] = ["nested": 1]
            $0["role"] = "auditor"
        }
        let account = try decoder.decode(APIv2Account.self, from: data)
        XCTAssertEqual(account.role, .unknown("auditor"))
        XCTAssertNotEqual(account.role, .admin)
        XCTAssertEqual(account.username, "laura")
    }

    // MARK: listProgress

    func testListProgressFixture() throws {
        let entry = try entry("list_progress_ok")
        XCTAssertEqual(entry.operationId, "listProgress")
        XCTAssertEqual(entry.request.path, "/api/v2/progress?limit=1")
        XCTAssertNotNil(entry.request.headers?["X-Profile-Id"], "profile-scoped operation")
        let page = try decoder.decode(APIv2ProgressPage.self, from: fixture("list_progress_ok"))
        XCTAssertEqual(page.items.count, 1)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.mediaItemId, "movie-8f2c1a")
        XCTAssertEqual(item.positionSeconds, 1325.5)
        XCTAssertEqual(item.durationSeconds, 5400)
        XCTAssertFalse(item.completed)
        // UTC-millisecond instant decoded by the production date strategy.
        XCTAssertEqual(item.updatedAt.timeIntervalSince1970, 1_767_323_045, accuracy: 0.0005)
        XCTAssertTrue(page.page.hasMore)
        XCTAssertEqual(
            page.page.nextCursor,
            "eyJ2IjoxLCJwIjp7InUiOiIyMDI2LTAxLTAyVDAzOjA0OjA1WiIsIm0iOiJtb3ZpZS04ZjJjMWEifX0.7fNOMpzpMssIVUy2sr5knHSZhSdx8HPH7x4WWFoLLDQ"
        )
    }

    func testListProgressLastPageHasNoCursor() throws {
        let data = try Support.mutatedBody(named: "list_progress_ok", bundleClass: Self.self) {
            $0["page"] = ["has_more": false]
        }
        let page = try decoder.decode(APIv2ProgressPage.self, from: data)
        XCTAssertFalse(page.page.hasMore)
        XCTAssertNil(page.page.nextCursor, "next_cursor is absent on the last page")
    }

    func testListProgressToleratesUnknownMembers() throws {
        let data = try Support.mutatedBody(named: "list_progress_ok", bundleClass: Self.self) {
            $0["totals"] = ["count": 99]
            var items = $0["items"] as? [[String: Any]] ?? []
            items[0]["status"] = "paused"
            items[0]["extra"] = ["a": "b"]
            $0["items"] = items
        }
        let page = try decoder.decode(APIv2ProgressPage.self, from: data)
        XCTAssertEqual(page.items.first?.mediaItemId, "movie-8f2c1a")
        // The status filter enum the client sends stays open too.
        XCTAssertEqual(APIv2ProgressStatus(wireValue: "paused"), .unknown("paused"))
        XCTAssertEqual(APIv2ProgressStatus(wireValue: "in_progress"), .inProgress)
    }

    func testListProgressProblemFixtures() throws {
        let header = try decoder.decode(APIv2Problem.self, from: fixture("list_progress_profile_header_required"))
        XCTAssertEqual(header.status, 422)
        XCTAssertEqual(header.identifier, "validation_failed")
        XCTAssertEqual(header.errors?.first?.location, "header.x-profile-id")
        XCTAssertEqual(header.errors?.first?.code, "required")

        let offset = try decoder.decode(APIv2Problem.self, from: fixture("list_progress_offset_rejected"))
        XCTAssertEqual(offset.errors?.first?.location, "query.offset")
        XCTAssertEqual(offset.errors?.first?.code, "unknown_parameter")
    }

    // MARK: updateProfile

    func testUpdateProfileFixture() throws {
        let entry = try entry("update_profile_ok")
        XCTAssertEqual(entry.operationId, "updateProfile")
        XCTAssertEqual(entry.request.method, "PATCH")
        XCTAssertTrue(entry.request.path.hasPrefix("/api/v2/profiles/"))
        let requestBody = try Support.jsonObject(Data(try XCTUnwrap(entry.request.body).utf8))
        XCTAssertTrue(
            requestBody.contains { $0.value is NSNull },
            "the fixture request mixes set, omitted and null members"
        )

        let profile = try decoder.decode(APIv2Profile.self, from: fixture("update_profile_ok"))
        XCTAssertEqual(profile.id, "p-owner")
        XCTAssertEqual(profile.name, "Laura")
        XCTAssertFalse(profile.hasPin)
        XCTAssertFalse(profile.isChild)
        XCTAssertTrue(profile.isPrimary)
        XCTAssertEqual(profile.allowedLibraryIds, ["3"])
        XCTAssertEqual(profile.avatarSource, .preset)
        XCTAssertEqual(profile.avatarUrl, "/avatars/presets/fox.png")
        XCTAssertEqual(profile.maxContentRating, "", "cleared string member is emitted empty")
        XCTAssertEqual(profile.updatedAt.timeIntervalSince1970, 1_767_323_045, accuracy: 0.0005)
        XCTAssertEqual(profile.createdAt, profile.updatedAt)
    }

    func testUpdateProfileToleratesUnknownMembersAndEnums() throws {
        let data = try Support.mutatedBody(named: "update_profile_ok", bundleClass: Self.self) {
            $0["theme"] = "midnight"
            $0["subtitle_mode"] = "forced_only"
            $0["avatar_source"] = "gravatar"
            $0.removeValue(forKey: "avatar_url")
        }
        let profile = try decoder.decode(APIv2Profile.self, from: data)
        XCTAssertEqual(profile.avatarSource, .unknown("gravatar"))
        XCTAssertEqual(APIv2SubtitleMode(wireValue: profile.subtitleMode), .unknown("forced_only"))
        XCTAssertNil(profile.avatarUrl, "avatar_url is the one member the server may omit")
    }

    func testUpdateProfileNullNotClearableProblem() throws {
        let problem = try decoder.decode(APIv2Problem.self, from: fixture("update_profile_null_not_clearable"))
        XCTAssertEqual(problem.status, 422)
        XCTAssertEqual(problem.errors?.first?.location, "body.is_child")
        XCTAssertEqual(problem.errors?.first?.code, "invalid_type")
    }

    func testUpdateProfilePatchEncodesOmittedVersusNull() throws {
        var patch = APIv2ProfilePatch()
        patch.name = "Laura"
        patch.subtitleMode = .always
        patch.subtitleLanguage = .clear
        patch.maxPlaybackQuality = .set(.p2160)
        patch.autoSkipIntro = false
        patch.allowedLibraryIds = []

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try Support.jsonObject(encoder.encode(patch))

        XCTAssertEqual(object["name"] as? String, "Laura")
        XCTAssertEqual(object["subtitle_mode"] as? String, "always")
        XCTAssertTrue(object["subtitle_language"] is NSNull, "cleared member is JSON null")
        XCTAssertEqual(object["max_playback_quality"] as? String, "2160p")
        XCTAssertEqual(object["auto_skip_intro"] as? Bool, false)
        XCTAssertEqual(object["allowed_library_ids"] as? [String], [])
        for omitted in ["avatar", "pin", "is_child", "language", "quality_preference",
                        "preferred_metadata_language", "max_content_rating", "auto_skip_credits"] {
            XCTAssertNil(object[omitted], "\(omitted) must be absent, not null")
        }
        XCTAssertEqual(object.count, 6)
    }

    func testLegacyUpdateProfileBodyConvertsWithoutNulls() throws {
        var body = UpdateProfileBody()
        body.subtitleMode = "off"
        body.autoSkipCredits = true
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try Support.jsonObject(encoder.encode(body.asAPIv2Patch))
        XCTAssertEqual(object["subtitle_mode"] as? String, "off")
        XCTAssertEqual(object["auto_skip_credits"] as? Bool, true)
        XCTAssertEqual(object.count, 2, "nil in the legacy shape means omitted, never null")
    }

    func testLegacyEmptyLanguageSentinelBecomesAClear() throws {
        var body = UpdateProfileBody()
        body.preferredMetadataLanguage = ""
        body.subtitleLanguage = "de"
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try Support.jsonObject(encoder.encode(body.asAPIv2Patch))
        XCTAssertTrue(object.keys.contains("preferred_metadata_language"), "inherit must be sent, not omitted")
        XCTAssertTrue(object["preferred_metadata_language"] is NSNull, "the legacy \"\" sentinel clears on v2")
        XCTAssertEqual(object["subtitle_language"] as? String, "de")
        XCTAssertEqual(object.count, 2)
    }

    // MARK: Problems

    func testGenericProblemFixtures() throws {
        let expectations: [(String, Int, String)] = [
            ("authentication_required", 401, "authentication_required"),
            ("validation_failed_body", 422, "validation_failed"),
            ("not_found", 404, "not_found"),
            ("rate_limited", 429, "rate_limited"),
            ("profile_verification_required", 403, "profile_verification_required"),
            ("not_acceptable", 406, "not_acceptable"),
        ]
        for (name, status, identifier) in expectations {
            let problem = try decoder.decode(APIv2Problem.self, from: fixture(name))
            XCTAssertEqual(problem.status, status, name)
            XCTAssertEqual(problem.identifier, identifier, name)
            XCTAssertEqual(try entry(name).expectedStatus, status, name)
            XCTAssertFalse(problem.title.isEmpty, name)
        }
        let validation = try decoder.decode(APIv2Problem.self, from: fixture("validation_failed_body"))
        XCTAssertEqual(validation.errors?.map(\.code), ["out_of_range", "required"])
        let notFound = try decoder.decode(APIv2Problem.self, from: fixture("not_found"))
        XCTAssertNil(notFound.errors, "errors is omitted when there are none")
    }

    // MARK: System info

    func testSystemInfoFixture() throws {
        let info = try decoder.decode(APIv2SystemInfo.self, from: fixture("get_system_info_ok"))
        XCTAssertEqual(info.apiMajor, 2)
        XCTAssertEqual(info.links.openapi, "/api/v2/openapi.json")
        XCTAssertEqual(info.links.capabilities, "/api/v2/capabilities")
        XCTAssertFalse(info.contractDigest.isEmpty)
        XCTAssertEqual(try entry("get_system_info_ok").responseHeaders["Cache-Control"], "no-cache")
    }

    // MARK: getCatalogSearchCapabilities

    func testCatalogSearchCapabilitiesFixture() throws {
        XCTAssertEqual(try entry("get_catalog_search_capabilities_ok").operationId, "getCatalogSearchCapabilities")
        let capabilities = try decoder.decode(APIv2CatalogSearchCapabilities.self,
                                              from: fixture("get_catalog_search_capabilities_ok"))
        XCTAssertTrue(capabilities.isAvailable)
        XCTAssertEqual(capabilities.provider, "meilisearch")
        XCTAssertEqual(capabilities.resultWindowLimit, 1000)
        XCTAssertEqual(capabilities.peopleMediaScope, true)
        XCTAssertEqual(capabilities.personPrefetch, true)

        // Only revision, state and allowed are required: an unconfigured
        // server omits the provider and its limits.
        let unconfigured = try Support.mutatedBody(named: "get_catalog_search_capabilities_ok", bundleClass: Self.self) {
            for key in ["provider", "result_window_limit", "session_ttl_seconds", "max_sessions_per_account",
                        "people_media_scope", "person_prefetch"] { $0.removeValue(forKey: key) }
            $0["state"] = "not_configured"
        }
        let minimal = try decoder.decode(APIv2CatalogSearchCapabilities.self, from: unconfigured)
        XCTAssertNil(minimal.provider)
        XCTAssertFalse(minimal.isAvailable)

        let denied = try Support.mutatedBody(named: "get_catalog_search_capabilities_ok", bundleClass: Self.self) {
            $0["allowed"] = false
        }
        XCTAssertFalse(try decoder.decode(APIv2CatalogSearchCapabilities.self, from: denied).isAvailable)
        let missingAllowed = try Support.mutatedBody(named: "get_catalog_search_capabilities_ok", bundleClass: Self.self) {
            $0.removeValue(forKey: "allowed")
        }
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogSearchCapabilities.self, from: missingAllowed))
    }

    // MARK: getMetadataAICapability

    func testMetadataAICapabilityFixture() throws {
        XCTAssertEqual(try entry("get_metadata_ai_capability_ok").operationId, "getMetadataAICapability")
        let status = try decoder.decode(APIv2MetadataAICapability.self, from: fixture("get_metadata_ai_capability_ok")).playerValue
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.onView, .button)

        // `on_view` is an open string: a new mode keeps the feature enabled
        // with the affordance hidden instead of failing the read.
        let future = try Support.mutatedBody(named: "get_metadata_ai_capability_ok", bundleClass: Self.self) {
            $0["on_view"] = "summarize"
        }
        let tolerant = try decoder.decode(APIv2MetadataAICapability.self, from: future).playerValue
        XCTAssertTrue(tolerant.enabled)
        XCTAssertEqual(tolerant.onView, .off)

        let denied = try Support.mutatedBody(named: "get_metadata_ai_capability_ok", bundleClass: Self.self) {
            $0["allowed"] = false
        }
        let refused = try decoder.decode(APIv2MetadataAICapability.self, from: denied).playerValue
        XCTAssertFalse(refused.enabled, "a principal the server does not allow cannot translate")
        XCTAssertEqual(refused.onView, .off)
    }

    // MARK: getPlaybackControlSocketCapabilities

    /// Client-authored: the server publishes no fixture for this operation.
    /// Its test asserts the body never carries an owner-lease member.
    func testPlaybackControlCapabilitiesFixture() throws {
        let capability = try decoder.decode(APIv2PlaybackControlCapabilities.self,
                                            from: fixture("playback_control_capabilities"))
        XCTAssertTrue(capability.servesControlHandshake)
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("not allowed", { $0["allowed"] = false }),
            ("disabled", { $0["state"] = "disabled" }),
            ("not served", { $0["available"] = false; $0["protocol"] = "" }),
            ("other protocol", { $0["protocol"] = "silo.playback-control.v3" }),
        ]
        for (name, mutate) in mutations {
            let data = try Support.mutatedBody(named: "playback_control_capabilities", bundleClass: Self.self, mutate: mutate)
            XCTAssertFalse(try decoder.decode(APIv2PlaybackControlCapabilities.self, from: data).servesControlHandshake, name)
        }
    }

    func testPlaybackControlRequestMintsOnlyWhenTheServerServesTheHandshake() async throws {
        let name = "APIv2ContractTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://control.example")
        await tokens.setProfileId("profile-one")
        let stub = APIv2TestStub()
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        let session = UUID().uuidString
        let capabilities = String(decoding: try fixture("playback_control_capabilities"), as: UTF8.self)
        stub.sequence([
            .json(200, capabilities),
            .json(200, #"{"ticket":"abc-123","expires_in":30,"max_connection_seconds":600,"protocol":"silo.playback-control.v2"}"#),
        ])
        let request = try await api.playbackControlRequest(sessionID: session, installationID: UUID().uuidString, auth: auth)
        XCTAssertEqual(request.url?.path, "/api/v2/playback/sessions/\(session)/control/ws")
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/playback/sessions/control/capabilities",
                                             "/api/v2/playback/sessions/\(session)/control/ws-ticket"])

        stub.reset()
        let denied = try Support.mutatedBody(named: "playback_control_capabilities", bundleClass: Self.self) {
            $0["allowed"] = false
        }
        stub.reply(200, String(decoding: denied, as: UTF8.self))
        do {
            _ = try await api.playbackControlRequest(sessionID: session, installationID: UUID().uuidString, auth: auth)
            XCTFail("a capability that does not allow this owner cannot mint a ticket")
        } catch PlaybackSequencedError.invalidResponse { }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/playback/sessions/control/capabilities"])
    }
}
