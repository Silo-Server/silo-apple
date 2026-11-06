@testable import Silo
import XCTest

/// Server text with a catalog key: section `title_key` (5.6), problem details
/// (D33) and manifest labels. English shows exactly what the server sent; other
/// languages show the catalog's translation when their own table has the key.
final class ServerTextTests: XCTestCase {
    private var savedLookup: ((String, String) -> String?)!
    private var savedDisplayed: Any?
    private let displayedKey = "appLanguage.displayed.v1"

    override func setUp() {
        super.setUp()
        savedLookup = AppLanguage.catalogLookup
        savedDisplayed = SharedStorage.suite.object(forKey: displayedKey)
        // A Spanish table with two section titles and two problem keys.
        let es = [
            "home.section.continueWatching": "Seguir viendo",
            "home.section.recentlyAddedIn": "Añadido recientemente en %1$@",
            "error.not_found": "No se encontró.",
            "error.field.required": "Este campo es obligatorio.",
        ]
        AppLanguage.catalogLookup = { key, language in language == "es" ? es[key] : nil }
    }

    override func tearDown() {
        AppLanguage.catalogLookup = savedLookup
        SharedStorage.suite.set(savedDisplayed, forKey: displayedKey)
        super.tearDown()
    }

    private func section(_ json: String) throws -> ResolvedSection {
        try HTTPClient.makeJSONDecoder().decode(ResolvedSection.self, from: Data(json.utf8))
    }

    // MARK: Section titles

    func testSectionTitleKeyShowsTheTranslation() throws {
        let row = try section(#"{"id":"cw","section_type":"continue_watching","title":"Continue Watching","title_key":"home.section.continueWatching"}"#)
        XCTAssertEqual(row.displayTitle(language: "es"), "Seguir viendo")
    }

    func testSectionTitleArgumentFillsThePlaceholder() throws {
        let row = try section(#"{"id":"ra","section_type":"recently_added","title":"Recently Added in Films","title_key":"home.section.recentlyAddedIn","title_args":{"library":"Films"}}"#)
        XCTAssertEqual(row.displayTitle(language: "es"), "Añadido recientemente en Films")
    }

    func testSectionTitleFallsBackToTheServerTitle() throws {
        // English: the server's text, even where the catalog differs.
        let keyed = try section(#"{"id":"cw","section_type":"continue_watching","title":"Continue Watching!","title_key":"home.section.continueWatching"}"#)
        XCTAssertEqual(keyed.displayTitle(language: "en"), "Continue Watching!")
        // A renamed row carries no key.
        let renamed = try section(#"{"id":"cw","section_type":"continue_watching","title":"Keep Watching"}"#)
        XCTAssertEqual(renamed.displayTitle(language: "es"), "Keep Watching")
        // A key this language doesn't translate.
        let missing = try section(#"{"id":"tr","section_type":"top_rated","title":"Top Rated","title_key":"home.section.topRated"}"#)
        XCTAssertEqual(missing.displayTitle(language: "es"), "Top Rated")
        // A placeholder without its one value.
        let noArgs = try section(#"{"id":"ra","section_type":"recently_added","title":"Recently Added in Films","title_key":"home.section.recentlyAddedIn"}"#)
        XCTAssertEqual(noArgs.displayTitle(language: "es"), "Recently Added in Films")
        // Malformed arguments drop to the title instead of failing the row.
        let badArgs = try section(#"{"id":"ra","section_type":"recently_added","title":"Recently Added in Films","title_key":"home.section.recentlyAddedIn","title_args":{"library":7}}"#)
        XCTAssertNil(badArgs.titleArgs)
        XCTAssertEqual(badArgs.displayTitle(language: "es"), "Recently Added in Films")
    }

    func testSectionTitleArgumentIsIsolatedOnlyRightToLeft() {
        AppLanguage.catalogLookup = { key, _ in key == "home.section.recentlyAddedIn" ? "%1$@ ←" : nil }
        XCTAssertEqual(
            AppLanguage.serverText("x", key: "home.section.recentlyAddedIn", args: ["library": "Films"], language: "ar"),
            "\u{2068}Films\u{2069} ←"
        )
        XCTAssertEqual(
            AppLanguage.serverText("x", key: "home.section.recentlyAddedIn", args: ["library": "Films"], language: "de"),
            "Films ←"
        )
    }

    func testLiteralPercentAndARepeatedPlaceholderStillTranslate() {
        AppLanguage.catalogLookup = { key, _ in
            ["a": "Mejores 10 %", "b": "Vuelve a %1$@: más de %1$@", "c": "Sube un 5 %% en %1$@"][key]
        }
        XCTAssertEqual(AppLanguage.serverText("x", key: "a", language: "es"), "Mejores 10 %")
        XCTAssertEqual(AppLanguage.serverText("x", key: "b", args: ["title": "Dune"], language: "es"), "Vuelve a Dune: más de Dune")
        XCTAssertEqual(AppLanguage.serverText("x", key: "c", args: ["library": "Films"], language: "es"), "Sube un 5 % en Films")
        // Two different slots can't be filled from a named map.
        AppLanguage.catalogLookup = { _, _ in "%1$@ y %2$@" }
        XCTAssertEqual(AppLanguage.serverText("x", key: "d", args: ["a": "1"], language: "es"), "x")
    }

    // MARK: Problem details (D33)

    private func problem(_ id: String, detail: String, fieldCode: String? = nil) -> APIv2Problem {
        let errors = fieldCode.map { #","errors":[{"location":"body.name","code":"\#($0)","detail":"name is required"}]"# } ?? ""
        let json = #"{"type":"https://siloserver.org/problems/\#(id)","title":"T","status":404,"detail":"\#(detail)"\#(errors)}"#
        return try! JSONDecoder().decode(APIv2Problem.self, from: Data(json.utf8))
    }

    func testProblemDetailIsTranslatedByTypeInAnotherLanguage() {
        SharedStorage.suite.set("es", forKey: displayedKey)
        let error = APIv2Error.problem(problem("not_found", detail: "Library 12 was not found."))
        XCTAssertEqual(error.errorDescription, "No se encontró.")
    }

    func testFieldCodeWinsOverTheProblemType() {
        SharedStorage.suite.set("es", forKey: displayedKey)
        let error = APIv2Error.problem(problem("not_found", detail: "Library 12 was not found.", fieldCode: "required"))
        XCTAssertEqual(error.errorDescription, "Este campo es obligatorio.")
    }

    func testTheShownFieldErrorPicksTheFieldKey() throws {
        let json = #"{"type":"https://siloserver.org/problems/validation_failed","title":"T","status":422,"detail":"Invalid.","errors":[{"location":"body.pin","code":"invalid","detail":""},{"location":"body.name","code":"required","detail":"name is required"}]}"#
        let problem = try JSONDecoder().decode(APIv2Problem.self, from: Data(json.utf8))
        XCTAssertEqual(problem.localized("name is required", field: problem.errors?[1], language: "es"), "Este campo es obligatorio.")
    }

    func testProblemDetailStaysTheServersInEnglishOrWithoutAKey() {
        SharedStorage.suite.set("en", forKey: displayedKey)
        XCTAssertEqual(APIv2Error.problem(problem("not_found", detail: "Library 12 was not found.")).errorDescription,
                       "Library 12 was not found.")
        SharedStorage.suite.set("es", forKey: displayedKey)
        XCTAssertEqual(APIv2Error.problem(problem("conflict", detail: "Already requested.")).errorDescription,
                       "Already requested.")
    }

    // MARK: Manifest labels

    func testManifestUnsetLabelFallsBackToTheManifestEnglish() {
        XCTAssertEqual(SettingPresentationMetadata.unsetLabel(for: .playbackSubtitleLanguage, fallback: "x", language: "es"), "None")
        XCTAssertEqual(SettingPresentationMetadata.unsetLabel(for: .playbackSubtitleLanguage, fallback: "x", language: "en"), "None")
    }
}
