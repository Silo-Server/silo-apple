import XCTest
@testable import Silo

@MainActor
final class BrowseViewModelTests: XCTestCase {
    override func tearDown() {
        ResponseCache.shared.remove(CacheKey.userLibraries)
        super.tearDown()
    }

    func testConfigureUsesInitialMixedLibraryType() async {
        let viewModel = BrowseViewModel()

        await viewModel.configure(libraryId: 8, libraryType: "mixed")

        XCTAssertEqual(viewModel.mediaType, .mixed)
    }

    func testConfigureUsesCachedLibraryTypeBeforeItemsLoad() async {
        ResponseCache.shared.set(
            LibrariesResponse(libraries: [
                Library(id: 8, name: "Mixed Media", type: "mixed", sortOrder: nil, posterUrl: nil),
            ]),
            for: CacheKey.userLibraries
        )
        let viewModel = BrowseViewModel()

        await viewModel.configure(libraryId: 8)

        XCTAssertEqual(viewModel.mediaType, .mixed)
    }
}
