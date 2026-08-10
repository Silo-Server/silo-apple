import XCTest
@testable import Silo

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
