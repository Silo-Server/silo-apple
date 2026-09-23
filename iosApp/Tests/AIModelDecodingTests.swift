//
//  AIModelDecodingTests.swift
//  SiloTests
//
//  Tests for the stored-subtitle handoff values in `AIModels.swift`: the
//  synthesized player descriptor (URL, combined ordinal, extension) and the
//  plan's downloaded-subtitle ordinals, plus which job states are terminal.
//  The v2 wire decoding lives in `APIv2SubtitleTests`.
//

import XCTest
import Foundation
@testable import Silo

final class AIModelDecodingTests: XCTestCase {

    // MARK: - Handoff descriptor synthesis (URL + combined index + ext)

    /// The descriptor takes the given ordinal, and the stream URL is on the
    /// session-scoped mount `/api/v2/stream/{session}/subtitles/{ordinal}<ext>`.
    func testSynthesizedDescriptorURLIndexAndExtSrt() {
        let sub = DownloadedSubtitle(
            id: "77", mediaFileId: 42, provider: "opensubtitles",
            language: "es", format: "subrip", releaseName: "Movie.2020.1080p"
        )
        let descriptor = sub.synthesizedDescriptor(
            sessionId: "sess-1",
            ordinal: 3,
            resolveURL: { path in URL(string: "https://host\(path)") }
        )
        XCTAssertNotNil(descriptor)
        XCTAssertTrue(descriptor?.index == 3)
        XCTAssertTrue(descriptor?.url.absoluteString
            == "https://host/api/v2/stream/sess-1/subtitles/3.vtt?file_id=42&downloaded_subtitle_id=77")
        XCTAssertTrue(descriptor?.source == "downloaded")
        XCTAssertTrue(descriptor?.codec == "subrip")
        XCTAssertTrue(descriptor?.language == "es")
        XCTAssertTrue(descriptor?.label == "Movie.2020.1080p (opensubtitles)")
    }

    /// ASS/SSA keep the raw `.ass` extension.
    func testSynthesizedDescriptorPositionAndAssExt() {
        let sub = DownloadedSubtitle(
            id: "88", mediaFileId: 7, provider: "subdl", language: "de", format: "ass", releaseName: "Show.S01E01"
        )
        let descriptor = sub.synthesizedDescriptor(
            sessionId: "sess-9",
            ordinal: 3,
            resolveURL: { path in URL(string: "https://host\(path)") }
        )
        XCTAssertTrue(descriptor?.index == 3)
        XCTAssertTrue(descriptor?.url.absoluteString
            == "https://host/api/v2/stream/sess-9/subtitles/3.ass?file_id=7&downloaded_subtitle_id=88")
    }

    /// The v2 listing omits rows the server cannot canonicalize, while the
    /// stream handler's unpinned ordinal counts them. A row after an omitted
    /// one must still be fetched as itself, so the URL pins it by ID.
    func testSynthesizedURLNamesTheRowWhenTheListingOmitsAnEarlierOne() throws {
        // Server rows 11, 12, 13; the listing leaves out 11.
        let listing = [
            DownloadedSubtitle(id: "12", mediaFileId: 42, format: "srt"),
            DownloadedSubtitle(id: "13", mediaFileId: 42, format: "srt"),
        ]
        let ordinals = DownloadedSubtitleOrdinals(published: ["11": 2, "12": 3], next: 4)
        let position = try XCTUnwrap(listing.firstIndex { $0.id == "13" })
        let descriptor = try XCTUnwrap(listing[position].synthesizedDescriptor(
            sessionId: "s", ordinal: ordinals.ordinal(at: position, in: listing),
            resolveURL: { URL(string: "https://host\($0)") }
        ))
        XCTAssertEqual(descriptor.index, 4)
        XCTAssertEqual(descriptor.url.path, "/api/v2/stream/s/subtitles/4.vtt")
        let query = try XCTUnwrap(URLComponents(url: descriptor.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [
            URLQueryItem(name: "file_id", value: "42"),
            URLQueryItem(name: "downloaded_subtitle_id", value: "13"),
        ])
        XCTAssertTrue(StreamRequest.hasAllowedHeaderAuthenticatedMediaQuery(
            path: descriptor.url.path, items: query
        ))
    }

    /// The plan's inventory counts every stored row, the v2 listing does not.
    /// A row the plan published keeps its ordinal; a new row follows every
    /// published ordinal and earlier unpublished listing rows, never taking
    /// the slot of a row the listing left out.
    func testOrdinalsFollowThePlanNotTheListingPosition() {
        // Base 2; the plan published rows 11 (ordinal 2, omitted from the
        // listing) and 12 (ordinal 3). Rows 13 and 14 were stored since.
        let ordinals = DownloadedSubtitleOrdinals(published: ["11": 2, "12": 3], next: 4)
        let listing = ["12", "13", "14"].map { DownloadedSubtitle(id: $0, mediaFileId: 42) }
        XCTAssertEqual((0..<listing.count).map { ordinals.ordinal(at: $0, in: listing) }, [3, 4, 5])
    }

    /// The server's pin accepts only a positive integer row and file; any
    /// other ID yields no track rather than an unpinned ordinal.
    func testSynthesizedDescriptorNeedsAPinnableRow() {
        for sub in [
            DownloadedSubtitle(id: "abc", mediaFileId: 42),
            DownloadedSubtitle(id: "0", mediaFileId: 42),
            DownloadedSubtitle(id: "007", mediaFileId: 42),
            DownloadedSubtitle(id: "7", mediaFileId: 0),
        ] {
            XCTAssertNil(sub.synthesizedDescriptor(
                sessionId: "s", ordinal: 0, resolveURL: { URL(string: "https://host\($0)") }
            ), sub.id)
        }
    }

    /// PGS maps to `.sup`; an unresolvable URL yields `nil` (no track).
    func testSynthesizedDescriptorPgsExtAndUnresolvable() {
        let pgs = DownloadedSubtitle(id: "1", provider: "p", format: "pgs", releaseName: "r")
        XCTAssertTrue(pgs.streamURLExtension == ".sup")
        let nilDescriptor = pgs.synthesizedDescriptor(
            sessionId: "s", ordinal: 0, resolveURL: { (_: String) -> URL? in nil }
        )
        XCTAssertNil(nilDescriptor)
    }

    // MARK: - AIJobStatus.isTerminal

    func testJobStatusTerminalSet() {
        XCTAssertFalse(AIJobStatus.pending.isTerminal)
        XCTAssertFalse(AIJobStatus.running.isTerminal)
        XCTAssertTrue(AIJobStatus.completed.isTerminal)
        XCTAssertTrue(AIJobStatus.failed.isTerminal)
        XCTAssertTrue(AIJobStatus.cancelled.isTerminal)
    }
}
