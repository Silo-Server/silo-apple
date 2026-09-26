import Foundation
import XCTest
@testable import Silo

/// Metadata AI on v2: the profile-scoped capability read and the on-view
/// description translation, including the owner the translation runs for.
final class MetadataAIV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    private static let job = #"{"id":"job-1","target_kind":"item","content_id":"movie/heat?1995","include_children":false,"source_language":"en","target_language":"de","engine":"llm","model":"m","status":"pending","progress":0,"progress_message":"","fields_done":0,"fields_total":2,"force":false,"created_at":"2026-01-02T03:04:05.000Z","updated_at":"2026-01-02T03:04:05.000Z"}"#

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client(profile: String? = "profile-one") async throws -> (APIv2Client, TokenStore) {
        let name = "MetadataAIV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://metadata.example")
        if let profile { await tokens.setProfileId(profile) }
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    // MARK: getMetadataAICapability

    func testCapabilityReadsTheProfileScopedV2Document() async throws {
        let (api, _) = try await client()
        stub.reply(200, #"{"allowed":true,"on_view":"auto","revision":"r1","state":"available"}"#)
        let status = try await api.metadataAIStatus()
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.onView, .auto)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/capabilities/metadata-ai")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
    }

    func testCapabilityIsOffUnlessAllowedAndAvailable() async throws {
        let (api, _) = try await client()
        for body in [
            #"{"allowed":false,"on_view":"button","revision":"r","state":"available"}"#,
            #"{"allowed":true,"on_view":"button","revision":"r","state":"not_configured"}"#,
        ] {
            stub.reply(200, body)
            let status = try await api.metadataAIStatus()
            XCTAssertFalse(status.enabled, body)
            XCTAssertEqual(status.onView, .off, body)
        }
    }

    func testCapabilityErrorsThrowInsteadOfReportingDisabled() async throws {
        let (api, _) = try await client()
        stub.reply(503, #"{"type":"https://siloserver.org/docs/api/v2/problems/unavailable","title":"T","status":503,"detail":"down","instance":"urn:x"}"#)
        do { _ = try await api.metadataAIStatus(); XCTFail("503 reported a capability") } catch APIv2Error.problem { }
        stub.reply(200, #"{"allowed":true,"on_view":"button","revision":"","state":"available"}"#)
        do { _ = try await api.metadataAIStatus(); XCTFail("empty revision accepted") } catch APIv2Error.incompleteCatalogRead { }
    }

    func testCapabilityNeedsASelectedProfile() async throws {
        let (api, _) = try await client(profile: nil)
        do { _ = try await api.metadataAIStatus(); XCTFail("read without a profile") } catch SettingsAPIError.profileRequired { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: translateCatalogItemDescription

    func testTranslatePostsTheTargetLanguageToTheEncodedItemPath() async throws {
        let (api, _) = try await client()
        stub.reply(202, Self.job)
        let auth = try await api.captureRequestOwner()
        let job = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
        XCTAssertEqual(job.id, "job-1")
        XCTAssertFalse(job.failed)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.absoluteString,
            "https://metadata.example/api/v2/catalog/items/movie%2Fheat%3F1995/translate-description")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body, ["target_language": "de"])
    }

    func testTranslateReportsAReusedFailedJob() async throws {
        let (api, _) = try await client()
        stub.reply(202, Self.job.replacingOccurrences(of: #""status":"pending""#, with: #""status":"failed""#))
        let auth = try await api.captureRequestOwner()
        let job = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
        XCTAssertTrue(job.failed)
    }

    func testTranslateRefusesAnyStatusButAccepted() async throws {
        let (api, _) = try await client()
        let auth = try await api.captureRequestOwner()
        stub.reply(200, Self.job)
        do {
            _ = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
            XCTFail("200 accepted")
        } catch APIv2Error.httpStatus(200) { }
        stub.reply(409, #"{"type":"https://siloserver.org/docs/api/v2/problems/conflict","title":"T","status":409,"detail":"busy","instance":"urn:x"}"#)
        do {
            _ = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
            XCTFail("409 accepted")
        } catch APIv2Error.problem { }
    }

    func testTranslateRejectsAJobForAnotherItem() async throws {
        let (api, _) = try await client()
        stub.reply(202, Self.job)
        let auth = try await api.captureRequestOwner()
        do {
            _ = try await api.translateDescription(contentID: "movie:other", language: "de", auth: auth)
            XCTFail("job for another item accepted")
        } catch APIv2Error.incompleteCatalogRead { }
    }

    func testTranslateIsNotSentAfterTheProfileChanged() async throws {
        let (api, tokens) = try await client()
        let auth = try await api.captureRequestOwner()
        await tokens.setProfileId("profile-two")
        let stillCurrent = await api.isCurrentOwner(auth)
        XCTAssertFalse(stillCurrent)
        do {
            _ = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
            XCTFail("sent for a previous profile")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
    }
}
