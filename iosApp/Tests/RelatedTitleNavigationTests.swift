import XCTest
@testable import Silo

#if !os(iOS)
/// On Apple TV and the Mac, titles push onto the shell's stack instead of an
/// iOS detail card. "More like this" hops still leave in two Backs.
@MainActor
final class RelatedTitleNavigationTests: XCTestCase {
    func testMoreLikeThisHopsReplaceEachOtherSoBackLeavesInTwoSteps() {
        let router = AppRouter()
        router.navigate(to: .itemDetail(contentId: "a"))
        for contentId in ["b", "c", "d"] {
            router.openRelatedTitle(contentId: contentId)
        }
        XCTAssertEqual(router.visiblePushedRoutes, [.itemDetail(contentId: "a"), .itemDetail(contentId: "d")])

        router.openRelatedTitle(contentId: "a")
        XCTAssertEqual(router.visiblePushedRoutes, [.itemDetail(contentId: "a")])
    }

    func testATitleOpenedAnotherWayKeepsItsPage() {
        let router = AppRouter()
        router.navigate(to: .itemDetail(contentId: "a"))
        router.navigate(to: .itemDetail(contentId: "b"))
        router.openRelatedTitle(contentId: "c")
        router.openRelatedTitle(contentId: "d")
        XCTAssertEqual(router.visiblePushedRoutes, [
            .itemDetail(contentId: "a"),
            .itemDetail(contentId: "b"),
            .itemDetail(contentId: "d"),
        ])
    }
}
#endif
