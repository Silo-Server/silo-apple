import XCTest
@testable import Silo

final class SourceCacheAdoptionPolicyTests: XCTestCase {
    private func adopt(
        handoffFileId: Int = 42,
        planFileId: Int? = 42,
        handoffBudgetBytes: Int = 256 << 20,
        planBudgetBytes: Int = 256 << 20,
        handoffDiskSpill: Bool = true,
        planDiskSpill: Bool = true,
        cachedTotalLength: Int64? = 4_000_000_000,
        expectedFileSize: Int64? = 4_000_000_000
    ) -> Bool {
        SourceCacheAdoptionPolicy.shouldAdopt(
            handoffFileId: handoffFileId,
            planFileId: planFileId,
            handoffBudgetBytes: handoffBudgetBytes,
            planBudgetBytes: planBudgetBytes,
            handoffDiskSpill: handoffDiskSpill,
            planDiskSpill: planDiskSpill,
            cachedTotalLength: cachedTotalLength,
            expectedFileSize: expectedFileSize
        )
    }

    func testSameFileSameConfigAdopts() {
        XCTAssertTrue(adopt())
    }

    func testDifferentFileRejects() {
        XCTAssertFalse(adopt(planFileId: 43))
    }

    func testUnknownPlanFileRejects() {
        XCTAssertFalse(adopt(planFileId: nil))
    }

    func testBudgetMismatchRejects() {
        // Loopback (256 MiB) cache offered to a 128 MiB route.
        XCTAssertFalse(adopt(planBudgetBytes: 128 << 20))
    }

    func testDiskSpillToggleRejects() {
        XCTAssertFalse(adopt(planDiskSpill: false))
    }

    func testReplacedFileUnderSameIdRejects() {
        // The cache learned one total; the catalog now reports another —
        // the file was swapped and the cached bytes are stale.
        XCTAssertFalse(adopt(expectedFileSize: 4_000_000_001))
    }

    func testUnknownSizesStillAdopt() {
        // Total never learned, or catalog size missing: fileId equality is
        // the operative guarantee.
        XCTAssertTrue(adopt(cachedTotalLength: nil))
        XCTAssertTrue(adopt(expectedFileSize: nil))
        XCTAssertTrue(adopt(cachedTotalLength: nil, expectedFileSize: nil))
    }
}
