import XCTest
@testable import Silo

// SiloTests currently runs on iOS. The tvOS branch documents its expected
// storage policy but only becomes executable coverage in a tvOS test bundle.
final class DiagnosticsStorageRootTests: XCTestCase {
    func testBaseDirectoryMatchesPlatformStorageDirectory() {
        let fileManager = FileManager.default
#if os(tvOS)
        let platformDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
#else
        let platformDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
#endif
        let expected = platformDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        XCTAssertEqual(DiagnosticsStorageRoot.baseDirectory(fileManager: fileManager), expected)
    }
}
