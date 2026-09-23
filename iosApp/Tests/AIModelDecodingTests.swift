//
//  AIModelDecodingTests.swift
//  SiloTests
//
//  Wire-decoding tests for the AI subtitle/metadata models. Decodes raw
//  snake_case JSON exactly as `HTTPClient` does (`.convertFromSnakeCase`),
//  covering: the `transcribe_translate` raw value, omitted optionals, and the
//  tolerant status/quota decoders.
//

import XCTest
import Foundation
@testable import Silo

final class AIModelDecodingTests: XCTestCase {

    /// Build a decoder configured the way `HTTPClient` configures its own —
    /// `.convertFromSnakeCase` (the AI models have no `Date` fields, so the
    /// custom date strategy is not needed here).
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! decoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - SubtitleJob + envelopes

    func testSubtitleJobFullDecode() {
        // REAL server wire shape: `id` is a JSON number (`ID int64`, serialized
        // bare), not a string. The tolerant decoder normalizes it to "123".
        let job = decode(SubtitleJob.self, """
        {
          "id": 123,
          "media_file_id": 42,
          "kind": "translate",
          "source_index": 3,
          "source_language": "en",
          "target_language": "es",
          "engine": "openai",
          "model": "gpt-x",
          "status": "running",
          "progress": 0.5,
          "progress_message": "Translating…",
          "result_subtitle_id": null,
          "error_message": null,
          "created_at": "2026-06-29T10:00:00Z",
          "updated_at": "2026-06-29T10:01:00Z"
        }
        """)
        XCTAssertTrue(job.id == "123")
        XCTAssertTrue(job.mediaFileId == 42)
        XCTAssertTrue(job.kind == .translate)
        XCTAssertTrue(job.sourceIndex == 3)
        XCTAssertTrue(job.sourceLanguage == "en")
        XCTAssertTrue(job.targetLanguage == "es")
        XCTAssertTrue(job.status == .running)
        XCTAssertTrue(job.progress == 0.5)
        XCTAssertTrue(job.progressMessage == "Translating…")
        XCTAssertNil(job.resultSubtitleId)
        XCTAssertFalse(job.status.isTerminal)
    }

    func testSubtitleJobOmittedOptionals() {
        // Only the required `id` present; everything else omitted. The tolerant
        // decoder must fill defaults rather than throw.
        let job = decode(SubtitleJob.self, """
        { "id": "job-min" }
        """)
        XCTAssertTrue(job.id == "job-min")
        XCTAssertTrue(job.mediaFileId == 0)
        XCTAssertTrue(job.kind == .translate)       // default kind
        XCTAssertTrue(job.sourceIndex == -1)        // default source index
        XCTAssertTrue(job.status == .pending)       // default status
        XCTAssertTrue(job.progress == 0)
        XCTAssertNil(job.sourceLanguage)
        XCTAssertNil(job.targetLanguage)
        XCTAssertNil(job.resultSubtitleId)
        XCTAssertNil(job.errorMessage)
    }

    func testSubtitleJobTranscribeTranslateRawValue() {
        let job = decode(SubtitleJob.self, """
        {
          "id": 5150,
          "media_file_id": 7,
          "kind": "transcribe_translate",
          "source_index": -1,
          "status": "completed",
          "progress": 1.0,
          "result_subtitle_id": 99
        }
        """)
        XCTAssertTrue(job.id == "5150")
        XCTAssertTrue(job.kind == .transcribeTranslate)
        XCTAssertTrue(job.status == .completed)
        XCTAssertTrue(job.status.isTerminal)
        XCTAssertTrue(job.resultSubtitleId == 99)
    }

    func testSubtitleJobTranscribeKind() {
        let job = decode(SubtitleJob.self, """
        { "id": "j", "kind": "transcribe", "source_index": -1, "status": "failed", "progress": 0, "error_message": "no audio" }
        """)
        XCTAssertTrue(job.kind == .transcribe)
        XCTAssertTrue(job.status == .failed)
        XCTAssertTrue(job.status.isTerminal)
        XCTAssertTrue(job.errorMessage == "no audio")
    }

    func testSubtitleJobTolerantUnknownStatus() {
        // An unrecognized status must decode to `.pending` so the poller never
        // false-terminates on a new transient server state.
        let job = decode(SubtitleJob.self, """
        { "id": "j", "status": "queued", "progress": 0 }
        """)
        XCTAssertTrue(job.status == .pending)
        XCTAssertFalse(job.status.isTerminal)
    }

    /// Regression for the critical decode bug: the server's 202 / `jobs/{id}`
    /// response is `{"job":{"id":42,...}}` where `id` is a JSON **number**. The
    /// old `decode(String.self)` threw on this, so `translateSubtitle` /
    /// `subtitleJob` failed on every real response and the live/poller pipeline
    /// never ran. Decoding must succeed and normalize the id to "42", and the
    /// `"ai-<id>"` track key must match the server's `liveTrackKey("ai-42")`.
    @MainActor
    func testSubtitleJobEnvelopeWithIntegerIdDecodesAndJoinsTrackKey() {
        let env = decode(SubtitleJobEnvelope.self, """
        { "job": { "id": 42, "kind": "translate", "source_index": 0, "status": "pending", "progress": 0 } }
        """)
        XCTAssertTrue(env.job.id == "42")
        XCTAssertTrue(env.job.status == .pending)
        // The track key must match the server's `liveTrackKey("ai-42")`.
        XCTAssertEqual(SubtitleAIController.trackKey(for: env.job.id), "ai-42")
    }

    /// The decoder is still tolerant of a string id (defensive; the helpers in
    /// other suites encode string ids).
    func testSubtitleJobEnvelopeWithStringIdStillDecodes() {
        let env = decode(SubtitleJobEnvelope.self, """
        { "job": { "id": "j1", "kind": "translate", "source_index": 0, "status": "pending", "progress": 0 } }
        """)
        XCTAssertTrue(env.job.id == "j1")
        XCTAssertTrue(env.job.status == .pending)
    }

    // MARK: - Quota

    func testSubtitleAIQuotaFull() {
        let quota = decode(SubtitleAIQuota.self, """
        { "limited": true, "limit": 100, "used": 40, "remaining": 60, "period": "month" }
        """)
        XCTAssertTrue(quota.limited)
        XCTAssertTrue(quota.limit == 100)
        XCTAssertTrue(quota.used == 40)
        XCTAssertTrue(quota.remaining == 60)
        XCTAssertTrue(quota.period == "month")
    }

    func testSubtitleAIQuotaUnlimitedOmitsFields() {
        // When not limited the numeric fields are typically absent.
        let quota = decode(SubtitleAIQuota.self, """
        { "limited": false }
        """)
        XCTAssertFalse(quota.limited)
        XCTAssertNil(quota.limit)
        XCTAssertNil(quota.used)
        XCTAssertNil(quota.remaining)
        XCTAssertNil(quota.period)
    }

    func testSubtitleAIQuotaEmptyObjectDefaults() {
        let quota = decode(SubtitleAIQuota.self, "{}")
        XCTAssertFalse(quota.limited)
    }

    // MARK: - Status

    func testSubtitleAIStatus() {
        let status = decode(SubtitleAIStatus.self, """
        { "enabled": true, "transcribe_enabled": true }
        """)
        XCTAssertTrue(status.enabled)
        XCTAssertTrue(status.transcribeEnabled)
    }

    func testSubtitleAIStatusOmittedDefaultsFalse() {
        let status = decode(SubtitleAIStatus.self, "{}")
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.transcribeEnabled)
    }

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
