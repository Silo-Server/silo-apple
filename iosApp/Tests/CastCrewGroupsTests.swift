import XCTest
@testable import Silo

final class CastCrewGroupsTests: XCTestCase {
    private func crew(_ name: String, job: String?, personId: String? = nil) -> CrewMember {
        CrewMember(
            name: name,
            job: job,
            personId: personId,
            tmdbId: nil,
            tvdbId: nil,
            imdbId: nil,
            photoUrl: nil,
            photoThumbhash: nil
        )
    }

    private func cast(_ name: String, order: Int?, character: String? = nil, personId: String? = nil) -> CastMember {
        CastMember(
            name: name,
            character: character,
            order: order,
            personId: personId,
            tmdbId: nil,
            tvdbId: nil,
            imdbId: nil,
            photoUrl: nil,
            photoThumbhash: nil
        )
    }

    private func names(_ group: CastCrewGroup) -> [String] {
        group.entries.map(\.name)
    }

    func testGroupsRunLeadThenWritersThenCastWithDividersAfterTheFirst() {
        let groups = CastCrewGroups.build(
            cast: [cast("Actor", order: 0, character: "Hero")],
            crew: [
                crew("Writer A", job: "Writer"),
                crew("Producer", job: "Producer"),
                crew("Director A", job: "Director"),
            ],
            leadRole: .director
        )

        XCTAssertEqual(groups.map(\.kind), [.lead, .writers, .cast])
        XCTAssertEqual(groups.map(\.dividerLabel), [nil, "Writers", "Cast"])
        XCTAssertEqual(groups[0].entries.map(\.caption), ["Director"])
        XCTAssertEqual(groups[1].entries.map(\.caption), ["Writer"])
        XCTAssertEqual(groups[2].entries.map(\.caption), ["Hero"])
    }

    func testCapsApplyAfterDeduplication() {
        let directors = (0..<4).map { crew("Director \($0)", job: "Director", personId: "d\($0)") }
        let writers = (0..<5).map { crew("Writer \($0)", job: $0.isMultiple(of: 2) ? "Writer" : "Screenplay", personId: "w\($0)") }
        let actors = (0..<20).map { cast("Actor \($0)", order: $0) }
        let groups = CastCrewGroups.build(
            cast: actors,
            crew: [directors[0], directors[0]] + directors + [writers[0]] + writers,
            leadRole: .director
        )

        XCTAssertEqual(names(groups[0]), ["Director 0", "Director 1"])
        XCTAssertEqual(names(groups[1]), ["Writer 0", "Writer 1", "Writer 2"])
        XCTAssertEqual(groups[2].entries.count, CastCrewGroups.maxCast)
    }

    func testDeduplicatesByPersonIdThenByNameWhenIdMissing() {
        let groups = CastCrewGroups.build(
            cast: nil,
            crew: [
                crew("Same Person", job: "Writer", personId: "p1"),
                crew("Same Person (credited)", job: "Screenplay", personId: "p1"),
                crew("No Id", job: "Writer"),
                crew("No Id", job: "Screenplay"),
            ],
            leadRole: .director
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(names(groups[0]), ["Same Person", "No Id"])
    }

    func testWriterDirectorAppearsOnlyInLeadGroup() {
        let groups = CastCrewGroups.build(
            cast: nil,
            crew: [
                crew("Auteur", job: "Director", personId: "a"),
                crew("Auteur", job: "Screenplay", personId: "a"),
                crew("Nameless Auteur", job: "Director"),
                crew("Nameless Auteur", job: "Writer"),
                crew("Co-writer", job: "Writer", personId: "c"),
            ],
            leadRole: .director
        )

        XCTAssertEqual(names(groups[0]), ["Auteur", "Nameless Auteur"])
        XCTAssertEqual(names(groups[1]), ["Co-writer"])
    }

    func testSeriesCaptionsLeadAsCreator() {
        let groups = CastCrewGroups.build(
            cast: nil,
            crew: [crew("Showrunner", job: "Director")],
            leadRole: .creator
        )

        XCTAssertEqual(groups.first?.entries.first?.caption, "Creator")
        XCTAssertNil(groups.first?.dividerLabel)
    }

    func testTitleWithoutCrewShowsOnlyCastWithNoDivider() {
        let groups = CastCrewGroups.build(
            cast: [cast("Actor", order: 0)],
            crew: [crew("Producer", job: "Producer")],
            leadRole: .director
        )

        XCTAssertEqual(groups.map(\.kind), [.cast])
        XCTAssertNil(groups[0].dividerLabel)
    }

    func testJobMatchingIgnoresCaseAndKeepsStoryWriters() {
        let groups = CastCrewGroups.build(
            cast: [],
            crew: [
                crew("Lower Director", job: "director", personId: "1"),
                crew("Story Writer", job: "Story", personId: "2"),
                crew("Spaced Writer", job: " WRITER ", personId: "3"),
                crew("Director of Photography", job: "Director of Photography", personId: "4"),
            ],
            leadRole: .director
        )

        XCTAssertEqual(groups.map(\.kind), [.lead, .writers])
        XCTAssertEqual(names(groups[0]), ["Lower Director"])
        XCTAssertEqual(names(groups[1]), ["Story Writer", "Spaced Writer"])
    }

    func testWritersLeadWithNoDividerWhenThereIsNoDirector() {
        let groups = CastCrewGroups.build(
            cast: [cast("Actor", order: 0)],
            crew: [crew("Writer", job: "Writer")],
            leadRole: .director
        )

        XCTAssertEqual(groups.map(\.kind), [.writers, .cast])
        XCTAssertEqual(groups.map(\.dividerLabel), [nil, "Cast"])
    }

    func testCastSortsByOrderWithMissingOrdersLastAndTiesStable() {
        let groups = CastCrewGroups.build(
            cast: [
                cast("Unbilled", order: nil),
                cast("Third", order: 2),
                cast("First", order: 0),
                cast("Second A", order: 1),
                cast("Second B", order: 1),
            ],
            crew: nil,
            leadRole: .director
        )

        XCTAssertEqual(names(groups[0]), ["First", "Second A", "Second B", "Third", "Unbilled"])
    }

    func testEntryIdsStayUniqueWhenADirectorAlsoActs() {
        let groups = CastCrewGroups.build(
            cast: [cast("Auteur", order: 0, character: "Cameo", personId: "a")],
            crew: [crew("Auteur", job: "Director", personId: "a")],
            leadRole: .director
        )

        let ids = groups.flatMap(\.entries).map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testEmptyCreditsProduceNoGroups() {
        XCTAssertTrue(CastCrewGroups.build(cast: [], crew: [], leadRole: .director).isEmpty)
        XCTAssertTrue(CastCrewGroups.castOnly([]).isEmpty)
    }

    func testCastOnlyKeepsServerOrderAndOriginalCap() {
        let actors = (0..<30).map { cast("Actor \($0)", order: 30 - $0) }
        let groups = CastCrewGroups.castOnly(actors)

        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].dividerLabel)
        XCTAssertEqual(groups[0].entries.count, CastCrewGroups.maxCastOnlyEntries)
        XCTAssertEqual(groups[0].entries.first?.name, "Actor 0")
    }

    func testDetailFactsDropCreditsOnlyWhenAsked() throws {
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data("""
        {"contentId":"m1","type":"movie","title":"Synthetic movie",
         "crew":[{"name":"Director A","job":"Director"},{"name":"Writer A","job":"Writer"}],
         "studios":["Studio A"]}
        """.utf8))

        XCTAssertEqual(
            DetailFacts(detail: detail).assembleFacts().map(\.label),
            ["Director", "Written by", "Studio"]
        )
        XCTAssertEqual(
            DetailFacts(detail: detail, includesCredits: false).assembleFacts().map(\.label),
            ["Studio"]
        )
    }
}
