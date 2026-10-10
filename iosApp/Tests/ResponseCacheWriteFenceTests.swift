import XCTest
@testable import Silo

@MainActor
final class ResponseCacheWriteFenceTests: XCTestCase {
    private let cache = ResponseCache.shared

    /// A response fetched before an invalidation must not restore the
    /// invalidated value; one fetched after it is cached normally.
    func testResponseFetchedBeforeAnInvalidationIsDropped() {
        let key = "fence-test:\(UUID().uuidString)"
        let before = cache.writeToken
        cache.remove(key)

        cache.set("stale", for: key, fetchedAt: before)
        XCTAssertNil(cache.get(key, as: String.self))

        cache.set("fresh", for: key, fetchedAt: cache.writeToken)
        XCTAssertEqual(cache.get(key, as: String.self), "fresh")
        cache.remove(key)
    }

    func testPrefixInvalidationFencesEveryKeyInTheFamily() {
        let family = "fence-family-\(UUID().uuidString):"
        let unrelated = "fence-other-\(UUID().uuidString)"
        let before = cache.writeToken
        cache.removeAll(withPrefix: family)

        cache.set("stale", for: family + "page-1", fetchedAt: before)
        cache.set("other", for: unrelated, fetchedAt: before)

        XCTAssertNil(cache.get(family + "page-1", as: String.self))
        XCTAssertEqual(cache.get(unrelated, as: String.self), "other", "keys outside the family are not fenced")
        cache.remove(unrelated)
    }
}
