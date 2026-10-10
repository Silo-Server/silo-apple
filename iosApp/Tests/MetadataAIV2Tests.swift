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
        let auth = try await api.captureAIAuthority()
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
        let auth = try await api.captureAIAuthority()
        let job = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
        XCTAssertTrue(job.failed)
    }

    func testTranslateRefusesAnyStatusButAccepted() async throws {
        let (api, _) = try await client()
        let auth = try await api.captureAIAuthority()
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
        let auth = try await api.captureAIAuthority()
        do {
            _ = try await api.translateDescription(contentID: "movie:other", language: "de", auth: auth)
            XCTFail("job for another item accepted")
        } catch APIv2Error.incompleteCatalogRead { }
    }

    func testTranslateIsNotSentAfterTheProfileChanged() async throws {
        let (api, tokens) = try await client()
        let auth = try await api.captureAIAuthority()
        await tokens.setProfileId("profile-two")
        let stillCurrent = await api.matchesAIAuthority(auth)
        XCTAssertFalse(stillCurrent)
        do {
            _ = try await api.translateDescription(contentID: "movie/heat?1995", language: "de", auth: auth)
            XCTFail("sent for a previous profile")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Machine-translated text and pending languages

    private static func detail(_ extra: String) throws -> ItemDetail {
        let json = #"{"content_id":"series-1","type":"series","status":"available","title":"Show","overview":"Eine Serie","genres":[],"cast":[],"crew":[],"subtitles":[],"versions":[]"# + extra + "}"
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: Data(json.utf8))
        return try ItemDetail(catalog: wire)
    }

    private static func episode(_ number: Int, season: Int = 1, extra: String = "") throws -> EpisodeListItem {
        let json = #"{"content_id":"ep-\#(season)-\#(number)","episode_number":\#(number),"season_number":\#(season),"runtime":42,"title":"E\#(number)","overview":"Text""# + extra + "}"
        return try EpisodeListItem(catalog: HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.Episode.self, from: Data(json.utf8)))
    }

    private static func season(_ number: Int, extra: String = "") throws -> Season {
        let json = #"{"content_id":"season-\#(number)","season_number":\#(number),"episode_count":2,"title":"Season \#(number)""# + extra + "}"
        return try Season(catalog: HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.Season.self, from: Data(json.utf8)))
    }

    func testCatalogReadsCarryMachineTranslatedFieldsAndPendingLanguages() throws {
        let marked = try Self.detail(#","machine_translated_fields":["overview","tagline"]"#)
        XCTAssertEqual(marked.machineTranslatedFields, ["overview", "tagline"])
        XCTAssertNil(try Self.detail("").machineTranslatedFields)

        let episode = try Self.episode(1, extra: #","machine_translated_fields":["overview"],"pending_translation_language":"de""#)
        XCTAssertEqual(episode.machineTranslatedFields, ["overview"])
        XCTAssertEqual(episode.pendingTranslationLanguage, "de")
        XCTAssertEqual(try Self.season(1, extra: #","machine_translated_fields":["overview"]"#).machineTranslatedFields, ["overview"])

        let card = try HTTPClient.makeJSONDecoder().decode(SectionItem.self, from: Data(
            #"{"content_id":"movie-1","type":"movie","title":"Film","overview":"Ein Film","pending_translation_language":"de","machine_translated_fields":["tagline"]}"#.utf8))
        XCTAssertEqual(card.pendingTranslationLanguage, "de")
        XCTAssertEqual(card.machineTranslatedFields, ["tagline"])

        // Cached copies written before these fields existed still decode.
        let cached = try JSONDecoder().decode(EpisodeListItem.self, from: JSONEncoder().encode(try Self.episode(2)))
        XCTAssertNil(cached.machineTranslatedFields)
        XCTAssertNil(cached.pendingTranslationLanguage)
    }

    func testStatusPrefersARunningTranslationOverTheLabel() {
        XCTAssertEqual(DescriptionTranslationStatus.resolve(translating: true, machineTranslatedFields: ["overview"]), .translating)
        XCTAssertEqual(DescriptionTranslationStatus.resolve(translating: false, machineTranslatedFields: ["overview", "tagline"]), .machineTranslated)
        // Only the tagline was machine-translated: the provider or hand-written
        // overview on screen carries no label.
        XCTAssertNil(DescriptionTranslationStatus.resolve(translating: false, machineTranslatedFields: ["tagline"]))
        XCTAssertFalse(MachineTranslation.isOverviewMarked(["tagline"]))
        XCTAssertNil(DescriptionTranslationStatus.resolve(translating: false, machineTranslatedFields: []))
        XCTAssertEqual(DescriptionTranslationStatus.machineTranslated.text, "Translated by AI")
    }

    @MainActor
    func testSeriesPageTranslatesTheSelectedSeasonWhenAnEpisodeIsMissing() throws {
        let series = try Self.detail(#","pending_translation_language":"de""#)
        let selected = try Self.season(1)
        let targets = ItemDetailViewModel.DescriptionTranslationTargets.make(
            detail: series,
            selectedSeason: selected,
            episodes: [try Self.episode(1), try Self.episode(2, extra: #","pending_translation_language":"de""#),
                       try Self.episode(1, season: 2, extra: #","pending_translation_language":"fr""#)]
        )
        XCTAssertEqual(targets.item, .init(contentId: "series-1", targetLanguage: "de"))
        XCTAssertEqual(targets.season, .init(contentId: "season-1", targetLanguage: "de"))

        // Nothing pending: nothing to translate.
        let settled = ItemDetailViewModel.DescriptionTranslationTargets.make(
            detail: try Self.detail(""), selectedSeason: selected, episodes: [try Self.episode(1)])
        XCTAssertTrue(settled.isEmpty)
    }

    @MainActor
    func testHeroCardIgnoresATaglineOnlyMark() {
        let store = CardDescriptionTranslation(onViewMode: { .auto })
        let card = store.presentation(contentId: "movie-1", overview: "Anbieter: Text", pendingLanguage: nil,
                                      machineTranslatedFields: ["tagline"])
        XCTAssertNil(card.status)
    }

    @MainActor
    func testSeasonJobLeavesTheSeriesDescriptionStatusAlone() async throws {
        let (api, _) = try await client()
        stub.reply(202, Self.job.replacingOccurrences(of: "movie/heat?1995", with: "season-1"))
        let season = DescriptionTranslationCoordinator(api: SiloAI(v2: api), schedule: [.seconds(60)],
                                                       sleep: { try await Task.sleep(for: $0) })
        let viewModel = ItemDetailViewModel(seasonDescriptionTranslation: season)
        viewModel.detail = try Self.detail(#","machine_translated_fields":["overview"]"#)
        viewModel.selectedSeason = try Self.season(1)
        viewModel.episodes = [try Self.episode(1, extra: #","pending_translation_language":"de""#)]

        let key = try XCTUnwrap(viewModel.descriptionTranslationTargets.season)
        XCTAssertTrue(season.translate(key, fetch: { 0 }, apply: { _ in true }))
        XCTAssertTrue(viewModel.isTranslatingSeasonEpisodes)
        XCTAssertFalse(viewModel.isTranslatingItemDescription)
        // The localized series overview keeps its label while only episodes translate.
        XCTAssertEqual(viewModel.descriptionTranslationStatus, .machineTranslated)
        season.cancel()
    }

    // MARK: On-view translation runs

    @MainActor
    private func coordinator(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in await Task.yield() }
    ) async throws -> DescriptionTranslationCoordinator {
        let (api, _) = try await client()
        return DescriptionTranslationCoordinator(api: SiloAI(v2: api), schedule: [.zero, .zero, .zero], sleep: sleep)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    private var translatePosts: Int {
        stub.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/translate-description") }.count
    }

    private static let heatKey = DescriptionTranslationCoordinator.Key(contentId: "movie/heat?1995", targetLanguage: "de")

    @MainActor
    func testAutomaticTranslationStartsOncePerItemAndLanguage() async throws {
        let coordinator = try await coordinator()
        stub.reply(202, Self.job)
        var reads = 0
        XCTAssertTrue(coordinator.translateAutomatically(Self.heatKey, fetch: { reads += 1; return reads }, apply: { $0 >= 2 }))
        XCTAssertTrue(coordinator.isTranslating(Self.heatKey))
        try await waitUntil { !coordinator.isRunning }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(reads, 2, "re-read until the pending language cleared")
        XCTAssertEqual(translatePosts, 1)

        // The same item and language never starts a second automatic job.
        XCTAssertFalse(coordinator.translateAutomatically(Self.heatKey, fetch: { 0 }, apply: { _ in true }))
        XCTAssertEqual(translatePosts, 1)

        // The Translate action may run it again.
        XCTAssertTrue(coordinator.translate(Self.heatKey, fetch: { 0 }, apply: { _ in true }))
        try await waitUntil { !coordinator.isRunning }
        XCTAssertEqual(translatePosts, 2)
    }

    @MainActor
    func testCancelledAutomaticRunMayStartAgain() async throws {
        let coordinator = try await coordinator(sleep: { try await Task.sleep(for: $0 + .seconds(60)) })
        stub.reply(202, Self.job)
        XCTAssertTrue(coordinator.translateAutomatically(Self.heatKey, fetch: { 0 }, apply: { _ in true }))
        try await waitUntil { self.translatePosts == 1 }
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(coordinator.translateAutomatically(Self.heatKey, fetch: { 0 }, apply: { _ in true }))
        coordinator.cancel()
    }

    @MainActor
    func testRefusedTranslationChecksOnceWhetherTheTextArrived() async throws {
        let coordinator = try await coordinator()
        let refused = #"{"type":"https://siloserver.org/docs/api/v2/problems/validation","title":"T","status":422,"detail":"nothing to translate","instance":"urn:x"}"#
        stub.reply(422, refused)
        var reads = 0
        coordinator.translate(Self.heatKey, fetch: { reads += 1; return true }, apply: { $0 })
        try await waitUntil { !coordinator.isRunning }
        XCTAssertEqual(coordinator.phase, .idle, "another job already translated it")
        XCTAssertEqual(reads, 1)

        coordinator.translate(Self.heatKey, fetch: { false }, apply: { $0 })
        try await waitUntil { !coordinator.isRunning }
        XCTAssertTrue(coordinator.hasFailed(Self.heatKey))
    }

    @MainActor
    func testTranslationGivesUpWhenThePendingLanguageNeverClears() async throws {
        let coordinator = try await coordinator()
        stub.reply(202, Self.job)
        var reads = 0
        coordinator.translate(Self.heatKey, fetch: { reads += 1; return reads }, apply: { _ in false })
        try await waitUntil { !coordinator.isRunning }
        XCTAssertTrue(coordinator.hasFailed(Self.heatKey))
        XCTAssertEqual(reads, 3, "one read per scheduled pass")
    }

    @MainActor
    func testHeroCardShowsItsTranslationOnceItLands() async throws {
        let (api, _) = try await client()
        stub.reply(202, Self.job)
        var mode = MetadataAIStatus.OnViewMode.button
        let landed = try Self.detail(#","machine_translated_fields":["overview"]"#)
        let store = CardDescriptionTranslation(
            makeCoordinator: { DescriptionTranslationCoordinator(api: SiloAI(v2: api), schedule: [.zero], sleep: { _ in }) },
            fetchDetail: { _, _ in landed },
            onViewMode: { mode }
        )
        let id = Self.heatKey.contentId
        let before = store.presentation(contentId: id, overview: "A film", pendingLanguage: "de", machineTranslatedFields: nil)
        XCTAssertEqual(before.pendingLanguage, "de")
        XCTAssertNil(before.status)
        XCTAssertTrue(store.offersTranslation(contentId: id, pendingLanguage: "de"))

        // `button` mode never starts on view.
        store.cardDidAppear(contentId: id, pendingLanguage: "de", libraryId: nil)
        XCTAssertEqual(translatePosts, 0)

        store.translate(contentId: id, pendingLanguage: "de", libraryId: nil)
        try await waitUntil {
            store.presentation(contentId: id, overview: "A film", pendingLanguage: "de", machineTranslatedFields: nil).pendingLanguage == nil
        }
        let after = store.presentation(contentId: id, overview: "A film", pendingLanguage: "de", machineTranslatedFields: nil)
        XCTAssertEqual(after.overview, "Eine Serie")
        XCTAssertEqual(after.status, .machineTranslated)
        XCTAssertFalse(store.offersTranslation(contentId: id, pendingLanguage: "de"))
        XCTAssertEqual(translatePosts, 1)

        // A new profile or metadata language forgets the landed text; `auto`
        // then translates the card on view.
        store.reset()
        mode = .auto
        XCTAssertEqual(store.presentation(contentId: id, overview: "A film", pendingLanguage: "de", machineTranslatedFields: nil).overview, "A film")
        store.cardDidAppear(contentId: id, pendingLanguage: "de", libraryId: nil)
        try await waitUntil { self.translatePosts == 2 }
    }
}
