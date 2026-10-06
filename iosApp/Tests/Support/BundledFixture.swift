import XCTest

/// A vendored fixture in the test bundle, by file name. XcodeGen copies the
/// files under `Tests/Fixtures` flat into the bundle root, so the name alone
/// finds it. A missing fixture fails the test rather than skipping it.
func bundledFixtureURL(
    _ fileName: String,
    bundleClass: AnyClass,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> URL {
    let name = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    return try XCTUnwrap(
        Bundle(for: bundleClass).url(forResource: name, withExtension: ext),
        "fixture missing from the test bundle: \(fileName)",
        file: file,
        line: line
    )
}
