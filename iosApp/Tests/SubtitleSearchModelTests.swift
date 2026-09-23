//
//  SubtitleSearchModelTests.swift
//  SiloTests
//
//  Focused tests for the subtitle provider-search models: the download body
//  echoing the chosen result (the server re-fetches by provider +
//  subtitle_id — a silently-wrong echo would no-op the download), result
//  identity, and the score-tier thresholds shared with Android/web.
//

import XCTest
@testable import Silo

final class SubtitleSearchModelTests: XCTestCase {
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    func testDownloadBodyEchoesChosenResult() throws {
        let result = SubtitleSearchResult(
            id: "os-123",
            provider: "opensubtitles",
            language: "en",
            releaseName: "Some.Movie.2024.1080p.WEB",
            format: "srt",
            score: 87.5,
            downloads: 4321,
            hearingImpaired: true
        )
        let body = APIv2SubtitleDownloadBody(SubtitleDownloadBody(from: result, mediaFileId: 42))
        let encoded = try encoder.encode(body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["provider"] as? String, "opensubtitles")
        // The result's provider-scoped `id` must land on the `subtitle_id`
        // key — the pair the server uses to re-fetch the bytes.
        XCTAssertEqual(object["subtitle_id"] as? String, "os-123")
        XCTAssertEqual(object["language"] as? String, "en")
        XCTAssertEqual(object["release_name"] as? String, "Some.Movie.2024.1080p.WEB")
        // The contract forbids extra keys; `format` would be a 422.
        XCTAssertNil(object["format"])
        XCTAssertEqual(object["score"] as? Double, 87.5)
        XCTAssertEqual(object["hearing_impaired"] as? Bool, true)
        XCTAssertEqual(object.count, 7)
    }

    func testUniqueKeyCombinesProviderAndId() {
        // Provider-local ids can collide across providers; row identity must
        // key on the (provider, id) pair.
        let a = SubtitleSearchResult(id: "123", provider: "opensubtitles")
        let b = SubtitleSearchResult(id: "123", provider: "subdl")
        XCTAssertEqual(a.uniqueKey, "opensubtitles:123")
        XCTAssertNotEqual(a.uniqueKey, b.uniqueKey)
    }

    func testScoreTierThresholds() {
        XCTAssertEqual(SubtitleSearchScoreTier(score: 100), .good)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 70), .good)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 69.9), .fair)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 40), .fair)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 39.9), .poor)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 0), .poor)
    }

    // MARK: - Download outcome

    private struct Refused: Error {}

    private func stored(_ id: String) -> DownloadedSubtitle {
        DownloadedSubtitle(id: id, mediaFileId: 42, provider: "opensubtitles", language: "en", format: "srt")
    }

    /// Runs `resolve` with a download that returns row "8", counting the
    /// steps after it.
    @MainActor
    private func resolveStored(
        listing: Result<[DownloadedSubtitle], Error> = .success([]),
        stillCurrent: Bool = true,
        registers: Bool = true
    ) async -> (outcome: SubtitleDownloadOutcome, registered: [(String, Int)]) {
        var registered: [(String, Int)] = []
        let outcome = await SubtitleDownloadOutcome.resolve(
            download: { ("owner", self.stored("8")) },
            relist: { owner in XCTAssertEqual(owner, "owner"); return try listing.get() },
            isStillCurrent: { _ in stillCurrent },
            register: { listing, position in
                registered.append((listing[position].id, position))
                return registers
            }
        )
        return (outcome, registered)
    }

    /// A download that threw is sorted without listing or registering
    /// anything: only a definite refusal is `.failed`, and a 200 row the
    /// player cannot use is still stored on the server.
    @MainActor
    func testThrownDownloadIsSortedWithoutRelisting() async {
        let problem = APIv2Problem(type: "https://silo.dev/problems/not_found", title: "Not Found",
                                   status: 404, detail: "The provider no longer has that subtitle.",
                                   instance: nil, errors: nil)
        let cases: [(Error, SubtitleDownloadOutcome)] = [
            (APIv2Error.problem(problem), .failed("The provider no longer has that subtitle.")),
            (URLError(.cannotConnectToHost), .failed(SubtitleDownloadOutcome.genericFailure)),
            (HTTPError.requestIdentityChanged, .failed(SubtitleDownloadOutcome.genericFailure)),
            (APIv2Error.invalidSubtitleResponse, .stored),
            (URLError(.timedOut), .unconfirmed),
            (APIv2Error.httpStatus(202), .unconfirmed),
            (APIv2SubtitleRequestError.outcomeUnknownOwnerChanged, .unconfirmed),
        ]
        for (error, expected) in cases {
            var laterSteps = 0
            let outcome = await SubtitleDownloadOutcome.resolve(
                download: { () async throws -> (String, DownloadedSubtitle) in throw error },
                relist: { _ in laterSteps += 1; return [] },
                isStillCurrent: { _ in laterSteps += 1; return true },
                register: { _, _ in laterSteps += 1; return true }
            )
            XCTAssertEqual(outcome, expected, "\(error)")
            XCTAssertEqual(laterSteps, 0, "\(error)")
        }
    }

    /// Once the server has answered 200, every way the live handoff can stop
    /// is `.stored`, never an invitation to download again.
    @MainActor
    func testStoredDownloadThatCannotBeAddedIsStored() async {
        let relistFailed = await resolveStored(listing: .failure(Refused()))
        XCTAssertEqual(relistFailed.outcome, .stored)
        XCTAssertTrue(relistFailed.registered.isEmpty)

        let moved = await resolveStored(listing: .success([stored("8")]), stillCurrent: false)
        XCTAssertEqual(moved.outcome, .stored)
        XCTAssertTrue(moved.registered.isEmpty)

        let missing = await resolveStored(listing: .success([stored("5"), stored("6")]))
        XCTAssertEqual(missing.outcome, .stored)
        XCTAssertTrue(missing.registered.isEmpty)

        let unregistrable = await resolveStored(listing: .success([stored("8")]), registers: false)
        XCTAssertEqual(unregistrable.outcome, .stored)
    }

    @MainActor
    func testStoredDownloadIsRegisteredAtItsListingPosition() async {
        let result = await resolveStored(listing: .success([stored("5"), stored("8"), stored("9")]))
        XCTAssertEqual(result.outcome, .added)
        XCTAssertEqual(result.registered.map(\.0), ["8"])
        XCTAssertEqual(result.registered.map(\.1), [1])
    }

    /// The menu keeps a result it must not send again: one the server stored
    /// or may have stored. Only a definite failure may be picked again.
    func testOnlyStoredOrUnconfirmedResultsAreHeld() {
        XCTAssertTrue(SubtitleDownloadOutcome.stored.holdsResult)
        XCTAssertTrue(SubtitleDownloadOutcome.unconfirmed.holdsResult)
        XCTAssertFalse(SubtitleDownloadOutcome.failed("No").holdsResult)
        XCTAssertFalse(SubtitleDownloadOutcome.added.holdsResult)
        XCTAssertNil(SubtitleDownloadOutcome.added.message)
        XCTAssertEqual(SubtitleDownloadOutcome.failed("No").message, "No")
    }
}
