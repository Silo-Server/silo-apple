import XCTest
@testable import Silo

final class LanguageCanonicalizationTests: XCTestCase {
    func testCanonicalWireTags() {
        XCTAssertEqual(LanguageCanonicalization.wireTag("ar"), "ar")
        XCTAssertEqual(LanguageCanonicalization.wireTag("ara"), "ar")
        XCTAssertEqual(LanguageCanonicalization.wireTag("Arabic"), "ar")
        XCTAssertEqual(LanguageCanonicalization.wireTag("pt_BR"), "pt-BR")
        XCTAssertEqual(LanguageCanonicalization.wireTag("zh-Hant"), "zh-Hant")
        XCTAssertNil(LanguageCanonicalization.wireTag("Klingon"))
    }

    func testPrimaryMatchingDropsOnlyVariantSubtags() {
        XCTAssertEqual(LanguageCanonicalization.primary("pt-BR"), "pt")
        XCTAssertEqual(LanguageCanonicalization.primary("zh-Hant"), "zh")
        XCTAssertEqual(LanguageCanonicalization.primary("Arabic"), "ar")
        XCTAssertEqual(LanguageCanonicalization.primary("xyz"), "xyz")
    }

    func testSubtitleSearchBodyEncodesCanonicalTags() throws {
        let body = SubtitleSearchBody(mediaFileId: 42, languages: ["ara", "pt_BR", "zh-Hant", "Arabic"])
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mediaFileId"] as? Int, 42)
        XCTAssertEqual(object["languages"] as? [String], ["ar", "pt-BR", "zh-Hant", "ar"])
    }
}
