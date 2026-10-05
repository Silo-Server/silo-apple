import XCTest
@testable import Silo

final class ResponseSnapshotStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResponseSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let adult = ResponseSnapshotStore.Scope(serverId: "server-a", profileId: "adult")
    private let child = ResponseSnapshotStore.Scope(serverId: "server-a", profileId: "child")

    func testStoredResponsesComeBackForTheirOwnProfileOnly() throws {
        let libraries = LibrariesResponse(libraries: [
            Library(id: 1, name: "Movies", type: "movies", sortOrder: 0),
            Library(id: 2, name: "TV Shows", type: "series", sortOrder: 1),
        ])
        ResponseSnapshotStore.store(libraries, forKey: CacheKey.userLibraries, scope: adult, in: root)
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: adult, in: root)

        let restored = ResponseSnapshotStore.load(scope: adult, in: root)
        let restoredLibraries = try XCTUnwrap(
            restored.first { $0.key == CacheKey.userLibraries }?.value as? LibrariesResponse
        )
        XCTAssertEqual(restoredLibraries.libraries.map(\.id), [1, 2])
        XCTAssertTrue(restored.contains { $0.key == CacheKey.homeSections && $0.value is SectionsResponse })
        XCTAssertTrue(ResponseSnapshotStore.load(scope: child, in: root).isEmpty)
    }

    func testOnlyFirstScreenKeysAreKept() {
        XCTAssertNotNil(ResponseSnapshotStore.snapshotType(forKey: CacheKey.librarySections(4)))
        XCTAssertNotNil(ResponseSnapshotStore.snapshotType(forKey: CacheKey.browse(libraryId: 4, filterKey: "sort=title/asc")))
        XCTAssertNotNil(ResponseSnapshotStore.snapshotType(forKey: CacheKey.tvLibrary(libraryId: 4, filterKey: "sort=title/asc")))
        XCTAssertNil(ResponseSnapshotStore.snapshotType(forKey: CacheKey.itemDetail("movie-1")))
        XCTAssertNil(ResponseSnapshotStore.snapshotType(forKey: CacheKey.profiles))
    }

    /// Invalidating a key family also drops its snapshots, so a later seed
    /// cannot restore what was invalidated.
    func testRemovingMatchingKeysLeavesTheRestAndOtherProfiles() {
        let browseKey = CacheKey.browse(libraryId: 4, filterKey: "sort=title/asc")
        ResponseSnapshotStore.store(CatalogResponse(items: [], total: 0, totalExact: true, hasMore: false), forKey: browseKey, scope: adult, in: root)
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: adult, in: root)
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: child, in: root)

        ResponseSnapshotStore.remove(scope: adult, in: root) { $0.hasPrefix("browse:") || $0 == CacheKey.homeSections }

        XCTAssertTrue(ResponseSnapshotStore.load(scope: adult, in: root).isEmpty)
        XCTAssertEqual(ResponseSnapshotStore.load(scope: child, in: root).map(\.key), [CacheKey.homeSections])
    }

    func testRemoveAllDropsEveryScope() {
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: adult, in: root)
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: child, in: root)

        ResponseSnapshotStore.removeAll(in: root)

        XCTAssertTrue(ResponseSnapshotStore.load(scope: adult, in: root).isEmpty)
        XCTAssertTrue(ResponseSnapshotStore.load(scope: child, in: root).isEmpty)
    }
}
