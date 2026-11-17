import Foundation
import XCTest
@testable import Silo

/// Rows of collections (`section_type` `collection_posters`): their cards
/// arrive, survive caching and every pass over Home and library rows, and
/// open the right collection.
final class SectionCollectionRowsTests: XCTestCase {
    private enum TestError: Error {
        case failed
    }

    private static let marvelId = "01J9Z8C3W4R5T6Y7U8I9O0P1Q2"

    /// The row as the server sends it (silo-server#4410, with the server
    /// collection's backdrop from silo-server#4415).
    private static let franchisesJSON = #"{"id":"franchises","section_type":"collection_posters","title":"Franchises","featured":false,"item_limit":20,"total_count":2,"is_custom":false,"customized":false,"items":[],"collections":[{"id":"01J9Z8C3W4R5T6Y7U8I9O0P1Q2","source":"library","title":"Marvel","poster_url":"https://s3.example.test/marvel.jpg","poster_is_collage":false,"backdrop_url":"https://s3.example.test/marvel-backdrop.jpg","backdrop_thumbhash":"3OcRJYB4d3h/iIeHeEh3eIhw+j2w","item_count":12,"library_id":"1"},{"id":"c-ghibli","source":"user","title":"Ghibli nights","poster_url":"https://s3.example.test/collage.jpg","poster_is_collage":true,"item_count":5,"creator_profile_id":"p-owner"}]}"#

    private static let titleRowJSON = #"{"id":"recent","section_type":"recently_added","title":"Recently Added","items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}]}"#

    // MARK: - Wire

    private func client(stub: APIv2TestStub) async throws -> SiloAPI {
        let name = "SectionCollectionRowsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "collections-test")
        await tokens.setServerUrl("https://home.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens)
    }

    func testHomeReadKeepsBothCollectionCardsInOrder() async throws {
        let stub = APIv2TestStub()
        let api = try await client(stub: stub)
        stub.reply(path: "/api/v2/home/sections", 200,
                   #"{"sections":[\#(Self.franchisesJSON),\#(Self.titleRowJSON)]}"#)

        let read = try await api.homeSections()

        XCTAssertEqual(read.sections.map(\.id), ["franchises", "recent"])
        let row = read.sections[0]
        XCTAssertTrue(row.holdsCollections)
        XCTAssertTrue(row.items.isEmpty)
        XCTAssertEqual(row.collections.map(\.id), [Self.marvelId, "c-ghibli"])

        let marvel = row.collections[0]
        XCTAssertEqual(marvel.source, .library(libraryId: 1))
        XCTAssertEqual(marvel.title, "Marvel")
        XCTAssertEqual(marvel.itemCount, 12)
        XCTAssertEqual(marvel.posterUrl, "https://s3.example.test/marvel.jpg")
        XCTAssertEqual(marvel.backdropUrl, "https://s3.example.test/marvel-backdrop.jpg")
        XCTAssertEqual(marvel.backdropThumbhash, "3OcRJYB4d3h/iIeHeEh3eIhw+j2w")

        let ghibli = row.collections[1]
        XCTAssertEqual(ghibli.source, .user(creatorProfileId: "p-owner"))
        XCTAssertEqual(ghibli.title, "Ghibli nights")
        XCTAssertEqual(ghibli.itemCount, 5)
        XCTAssertEqual(ghibli.posterUrl, "https://s3.example.test/collage.jpg")
        // A personal collection has no backdrop.
        XCTAssertNil(ghibli.backdropUrl)
        XCTAssertNil(ghibli.backdropThumbhash)

        let titles = read.sections[1]
        XCTAssertFalse(titles.holdsCollections)
        XCTAssertEqual(titles.items.map(\.contentId), ["movie:heat"])
        XCTAssertTrue(titles.collections.isEmpty)
    }

    func testRelativeCollectionPosterResolvesAgainstTheServer() async throws {
        let stub = APIv2TestStub()
        let api = try await client(stub: stub)
        let path = "/api/v2/artwork/collections/c%2F1.jpg?exp=1&sig=a%2Bb"
        stub.reply(path: "/api/v2/home/sections", 200,
                   #"{"sections":[{"id":"mine","section_type":"collection_posters","title":"Mine","items":[],"collections":[{"id":"c-1","source":"user","title":"Mine","poster_url":"\#(path)","item_count":1}]}]}"#)

        let read = try await api.homeSections()

        XCTAssertEqual(read.sections.first?.collections.first?.posterUrl, "https://home.example" + path)
    }

    func testCardsThatNoPageCouldOpenAreDroppedAndTheRowKept() throws {
        let json = #"""
        {"sections":[{"id":"mixed","section_type":"collection_posters","title":"Mixed","items":[],"collections":[
          {"id":"first","source":"library","title":"First","poster_url":"","item_count":3,"library_id":"7"},
          {"id":"numeric","source":"library","title":"Numeric id","item_count":1,"library_id":9},
          {"id":"unknown","source":"smart","title":"Unknown source","item_count":1},
          {"id":"no-library","source":"library","title":"No library","item_count":1},
          {"id":"no-title","source":"user","item_count":1,"creator_profile_id":"p"},
          {"id":"last","source":"user","title":"Last","item_count":2}
        ]},\#(Self.titleRowJSON)]}
        """#

        let response = try HTTPClient.makeJSONDecoder().decode(SectionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sections.map(\.id), ["mixed", "recent"])
        let cards = response.sections[0].collections
        XCTAssertEqual(cards.map(\.id), ["first", "numeric", "last"])
        XCTAssertEqual(cards[0].source, .library(libraryId: 7))
        // An empty poster draws the collection placeholder.
        XCTAssertNil(cards[0].posterUrl)
        XCTAssertEqual(cards[1].source, .library(libraryId: 9))
        XCTAssertEqual(cards[2].source, .user(creatorProfileId: nil))
    }

    // MARK: - Row kind

    func testRowsOfCollectionsAreNeverFeaturedAndCountCardsByCollection() throws {
        let featuredCollections = ResolvedSection(
            id: "franchises", sectionType: ResolvedSection.collectionPostersType, title: "Franchises",
            featured: true, itemLimit: 20, totalCount: 2, isCustom: false, customized: false,
            items: [], collections: [libraryCard("a"), userCard("b")]
        )
        XCTAssertTrue(featuredCollections.holdsCollections)
        XCTAssertTrue(featuredCollections.hasCards)
        XCTAssertFalse(featuredCollections.isFeatured)

        let emptyCollections = section(id: "empty", type: ResolvedSection.collectionPostersType)
        XCTAssertTrue(emptyCollections.holdsCollections)
        XCTAssertFalse(emptyCollections.hasCards)

        let featuredTitles = ResolvedSection(
            id: "hero", sectionType: "recently_added", title: "Hero", featured: true, itemLimit: 20,
            totalCount: 1, isCustom: false, customized: false, items: [try item("movie:heat")]
        )
        XCTAssertFalse(featuredTitles.holdsCollections)
        XCTAssertTrue(featuredTitles.hasCards)
        XCTAssertTrue(featuredTitles.isFeatured)
        XCTAssertFalse(section(id: "none", type: "recently_added").hasCards)
    }

    /// A server without backdrops, or a malformed one, leaves the card
    /// without a backdrop rather than dropping it.
    func testMissingOrMalformedBackdropKeepsTheCard() throws {
        let json = #"""
        {"sections":[{"id":"mixed","section_type":"collection_posters","title":"Mixed","items":[],"collections":[
          {"id":"none","source":"library","title":"No backdrop","poster_url":"https://s3.example.test/p.jpg","item_count":3,"library_id":"1"},
          {"id":"bad","source":"library","title":"Bad backdrop","backdrop_url":7,"backdrop_thumbhash":false,"item_count":2,"library_id":"1"},
          {"id":"empty","source":"library","title":"Empty backdrop","backdrop_url":"","backdrop_thumbhash":"","item_count":1,"library_id":"1"}
        ]}]}
        """#

        let response = try HTTPClient.makeJSONDecoder().decode(SectionsResponse.self, from: Data(json.utf8))

        let cards = try XCTUnwrap(response.sections.first?.collections)
        XCTAssertEqual(cards.map(\.id), ["none", "bad", "empty"])
        for card in cards {
            XCTAssertNil(card.backdropUrl, card.id)
            XCTAssertNil(card.backdropThumbhash, card.id)
        }
        XCTAssertEqual(cards[0].posterUrl, "https://s3.example.test/p.jpg")
    }

    // MARK: - Snapshots

    func testSnapshotKeepsCollectionsOfBothSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectionCollectionRowsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let scope = ResponseSnapshotStore.Scope(
            serverId: "server-a", localAccountId: "6F9619FF-8B86-D011-B42D-00C04FC964FF", profileId: "adult"
        )
        let cards = [
            libraryCard("lib", libraryId: 4, posterUrl: "https://s3.example.test/p.jpg", thumbhash: "abc",
                        backdropUrl: "https://s3.example.test/b.jpg", backdropThumbhash: "def"),
            userCard("mine", creator: "p-owner"),
        ]
        let response = SectionsResponse(sections: [
            section(id: "franchises", type: ResolvedSection.collectionPostersType, collections: cards),
            section(id: "recent", type: "recently_added", items: [try item("movie:heat")]),
        ])

        ResponseSnapshotStore.store(response, forKey: CacheKey.homeSections, scope: scope, in: root)
        let restored = try XCTUnwrap(
            ResponseSnapshotStore.load(scope: scope, in: root)
                .first { $0.key == CacheKey.homeSections }?.value as? SectionsResponse
        )

        XCTAssertEqual(restored.sections.map(\.id), ["franchises", "recent"])
        XCTAssertEqual(restored.sections[0].collections, cards)
        XCTAssertTrue(restored.sections[1].collections.isEmpty)
    }

    func testSnapshotWrittenBeforeCollectionsStillDecodes() throws {
        let older = #"{"sections":[{"id":"recent","sectionType":"recently_added","title":"Recent","items":[{"contentId":"movie:heat","type":"movie","title":"Heat"}]}]}"#

        let response = try JSONDecoder().decode(SectionsResponse.self, from: Data(older.utf8))

        XCTAssertEqual(response.sections.first?.items.map(\.contentId), ["movie:heat"])
        XCTAssertEqual(response.sections.first?.collections, [])
        XCTAssertEqual(response.sections.first?.hasCards, true)
    }

    // MARK: - Home

    @MainActor
    func testHomeKeepsCollectionRowsInServerOrderAndDropsEmptyOnes() async throws {
        ResponseCache.shared.remove(CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let heat = try item("movie:heat")
        let response = SectionsResponse(sections: [
            section(id: "recent", type: "recently_added", items: [heat]),
            section(id: "franchises", type: ResolvedSection.collectionPostersType,
                    collections: [libraryCard("a"), userCard("b")]),
            section(id: "nothing-visible", type: ResolvedSection.collectionPostersType),
            section(id: "trending", type: "trending", items: [heat]),
        ])
        let viewModel = HomeViewModel(fetchHomeSections: { response })

        await viewModel.loadSections()

        XCTAssertEqual(viewModel.sections.map(\.id), ["recent", "franchises", "trending"])
        XCTAssertEqual(viewModel.sections[1].collections.map(\.id), ["a", "b"])
    }

    @MainActor
    func testRemovingContinueWatchingCardsLeavesCollectionRows() async throws {
        let dismissed = try item("movie:dismissed")
        let finished = try item("movie:finished")
        let cards = [libraryCard("a"), userCard("b")]
        let sections = [
            section(id: "continue", type: "continue_watching", items: [dismissed, finished]),
            section(id: "franchises", type: ResolvedSection.collectionPostersType, collections: cards),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let viewModel = HomeViewModel(
            dismissContinueWatching: { _, _ in },
            setWatched: { _, _ in },
            // Keep the local update: reconciliation cannot be fetched.
            fetchHomeSections: { throw TestError.failed }
        )

        await viewModel.dismissContinueWatchingItem(dismissed)
        XCTAssertEqual(viewModel.sections.map(\.id), ["continue", "franchises"])
        XCTAssertEqual(viewModel.sections[1].collections, cards)

        let succeeded = await viewModel.setWatched(finished, played: true)
        XCTAssertTrue(succeeded)
        // The emptied Continue Watching row goes; the collections stay.
        XCTAssertEqual(viewModel.sections.map(\.id), ["franchises"])
        XCTAssertEqual(viewModel.sections[0].collections, cards)
        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(cached?.sections.first { $0.id == "franchises" }?.collections, cards)
    }

    // MARK: - Row limit and library scope

    func testRowLimitLeavesEveryCollectionCard() throws {
        let items = try (1...30).map { try item("movie:\($0)") }
        let cards = (1...25).map { libraryCard("c\($0)") }
        let response = SectionsResponse(sections: [
            section(id: "recent", type: "recently_added", itemLimit: 100, items: items),
            section(id: "franchises", type: ResolvedSection.collectionPostersType, itemLimit: 20, collections: cards),
        ])

        let capped = SectionRowLimit.capped(response)

        XCTAssertEqual(capped.sections[0].items.count, SectionRowLimit.cards)
        XCTAssertEqual(capped.sections[1].collections, cards)
    }

    func testLibraryScopeLeavesCollectionRowsAndRefillsTitleRows() async throws {
        let film = try item("film")
        let show = try item("show", type: "series")
        let cards = [libraryCard("a"), userCard("b")]
        let rows = [
            section(id: "franchises", type: ResolvedSection.collectionPostersType, collections: cards),
            section(id: "recent", type: "recently_added", totalCount: 2, items: [film]),
        ]
        let pages = PageLog()

        let results = try await LibraryVideoScope.series.refillSections(rows) { (row: ResolvedSection, _: Int?) -> LibraryScopedPage<Int> in
            await pages.record(row.id)
            return LibraryScopedPage(items: [show], next: nil)
        }

        XCTAssertEqual(results.map { $0.section.id }, ["franchises", "recent"])
        XCTAssertEqual(results[0].section.collections, cards)
        XCTAssertFalse(results[0].incomplete)
        XCTAssertEqual(results[1].section.items.map(\.id), ["show"])
        XCTAssertFalse(results[1].incomplete)
        let paged = await pages.rowIds
        XCTAssertEqual(paged, ["recent"])
    }

    // MARK: - Cards

    func testCardsOpenTheirCollectionAndDrawAsCollectionPosters() {
        let library = libraryCard("lib-1", libraryId: 3, posterUrl: "https://s3.example.test/p.jpg", thumbhash: "hash")
        XCTAssertEqual(library.route(), .libraryCollection(libraryId: 3, collectionId: "lib-1", title: "Title lib-1", kind: .regular))
        // A library page filtered to Shows opens the collection filtered too.
        XCTAssertEqual(
            library.route(mediaScope: .series),
            .libraryCollection(libraryId: 3, collectionId: "lib-1", title: "Title lib-1", kind: .regular, mediaScope: .series)
        )
        let drawnLibrary = library.libraryCollection
        XCTAssertEqual(drawnLibrary.id, "lib-1")
        XCTAssertEqual(drawnLibrary.name, "Title lib-1")
        XCTAssertEqual(drawnLibrary.itemCount, 4)
        XCTAssertEqual(drawnLibrary.posterUrl, "https://s3.example.test/p.jpg")
        XCTAssertEqual(drawnLibrary.posterThumbhash, "hash")
        XCTAssertEqual(drawnLibrary.kind, .regular)
        XCTAssertNil(drawnLibrary.creatorProfileId)

        let personal = userCard("mine", creator: "p-owner")
        XCTAssertEqual(personal.route(), .collectionDetail(collectionId: "mine", title: personal.title))
        // A personal collection's page has no library filter to keep.
        XCTAssertEqual(personal.route(mediaScope: .movie), .collectionDetail(collectionId: "mine", title: personal.title))
        let drawnPersonal = personal.libraryCollection
        XCTAssertEqual(drawnPersonal.name, "Title mine")
        XCTAssertEqual(drawnPersonal.kind, .userCollections)
        XCTAssertEqual(drawnPersonal.creatorProfileId, "p-owner")
        XCTAssertNil(drawnPersonal.posterUrl)

        // A server and a personal collection sharing an id stay apart in a row.
        XCTAssertNotEqual(libraryCard("same").rowKey, userCard("same").rowKey)
    }

    func testOwnerNameShowsOnlyForAnotherKnownProfile() {
        let profiles = [
            UserProfile(id: "me", name: "Me", avatarEmoji: nil, hasPin: false, isChild: false),
            UserProfile(id: "sam", name: "Sam", avatarEmoji: nil, hasPin: false, isChild: false),
        ]

        XCTAssertNil(CollectionOwnerName.otherProfile("me", actingProfileId: "me", profiles: profiles))
        XCTAssertEqual(CollectionOwnerName.otherProfile("sam", actingProfileId: "me", profiles: profiles), "Sam")
        XCTAssertNil(CollectionOwnerName.otherProfile("gone", actingProfileId: "me", profiles: profiles))
        XCTAssertNil(CollectionOwnerName.otherProfile(nil, actingProfileId: "me", profiles: profiles))
        XCTAssertNil(CollectionOwnerName.otherProfile("sam", actingProfileId: "me", profiles: nil))
    }

    // MARK: - Helpers

    private func item(_ contentId: String, type: String = "movie") throws -> SectionItem {
        let fields: [String: Any] = [
            "contentId": contentId,
            "type": type,
            "title": contentId,
            "progressUpdatedAt": "2026-07-10T12:00:00Z",
        ]
        return try JSONDecoder().decode(SectionItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func section(
        id: String,
        type: String,
        itemLimit: Int? = 20,
        totalCount: Int? = nil,
        items: [SectionItem] = [],
        collections: [SectionCollectionCard] = []
    ) -> ResolvedSection {
        ResolvedSection(
            id: id, sectionType: type, title: id, featured: false, itemLimit: itemLimit,
            totalCount: totalCount ?? max(items.count, collections.count), isCustom: false, customized: false,
            items: items, collections: collections
        )
    }

    private func libraryCard(
        _ id: String,
        libraryId: Int = 1,
        posterUrl: String? = nil,
        thumbhash: String? = nil,
        backdropUrl: String? = nil,
        backdropThumbhash: String? = nil
    ) -> SectionCollectionCard {
        SectionCollectionCard(id: id, source: .library(libraryId: libraryId), title: "Title \(id)",
                              posterUrl: posterUrl, posterThumbhash: thumbhash,
                              backdropUrl: backdropUrl, backdropThumbhash: backdropThumbhash, itemCount: 4)
    }

    private func userCard(_ id: String, creator: String? = "p-owner") -> SectionCollectionCard {
        SectionCollectionCard(id: id, source: .user(creatorProfileId: creator), title: "Title \(id)", itemCount: 2)
    }
}

/// The rows whose pages a refill asked for.
private actor PageLog {
    private(set) var rowIds: [String] = []

    func record(_ id: String) {
        rowIds.append(id)
    }
}
