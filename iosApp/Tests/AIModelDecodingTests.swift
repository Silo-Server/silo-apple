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

    func testMetadataAIStatusTolerantOnView() {
        // Known mode.
        let auto = decode(MetadataAIStatus.self, """
        { "enabled": true, "on_view": "auto" }
        """)
        XCTAssertTrue(auto.enabled)
        XCTAssertTrue(auto.onView == .auto)

        // Unknown mode → `.off`.
        let unknown = decode(MetadataAIStatus.self, """
        { "enabled": true, "on_view": "sometimes" }
        """)
        XCTAssertTrue(unknown.onView == .off)

        // Omitted → `.off`, enabled defaults false.
        let empty = decode(MetadataAIStatus.self, "{}")
        XCTAssertFalse(empty.enabled)
        XCTAssertTrue(empty.onView == .off)
    }

    // MARK: - Downloaded subtitles (handoff source)

    /// Decodes the REAL server shape (`internal/subtitles.DownloadedSubtitle`):
    /// a DB `id` plus metadata, **no** combined `index` and **no** stream
    /// `url`. The earlier model decoded this as `subtitle_urls[]` (which
    /// requires `index`+`url`), so the decode threw and `try?` silently
    /// dropped every completed AI track.
    func testDownloadedSubtitlesResponse() {
        let response = decode(DownloadedSubtitlesResponse.self, """
        {
          "subtitles": [
            {
              "id": 77,
              "media_file_id": 42,
              "provider": "opensubtitles",
              "language": "es",
              "format": "subrip",
              "release_name": "Movie.2020.1080p",
              "score": 9.5,
              "hearing_impaired": false,
              "created_at": "2026-06-29T00:00:00Z"
            }
          ]
        }
        """)
        XCTAssertTrue(response.subtitles.count == 1)
        let sub = response.subtitles[0]
        XCTAssertTrue(sub.id == 77)
        XCTAssertTrue(sub.mediaFileId == 42)
        XCTAssertTrue(sub.provider == "opensubtitles")
        XCTAssertTrue(sub.language == "es")
        XCTAssertTrue(sub.format == "subrip")
        XCTAssertTrue(sub.releaseName == "Movie.2020.1080p")
        XCTAssertTrue(sub.hearingImpaired == false)
    }

    /// Tolerant: only `id` is required; missing optional fields default.
    func testDownloadedSubtitleTolerantOmittedFields() {
        let sub = decode(DownloadedSubtitle.self, """
        { "id": 5, "language": "fr", "format": "webvtt", "release_name": "x", "provider": "subdl" }
        """)
        XCTAssertTrue(sub.id == 5)
        XCTAssertTrue(sub.mediaFileId == 0)
        XCTAssertNil(sub.score)
        XCTAssertNil(sub.createdAt)
        XCTAssertNil(sub.hearingImpaired)
    }

    func testDownloadedSubtitlesResponseMissingArray() {
        let response = decode(DownloadedSubtitlesResponse.self, "{}")
        XCTAssertTrue(response.subtitles.isEmpty)
    }

    // MARK: - Handoff descriptor synthesis (URL + combined index + ext)

    /// Synthesizing the player descriptor mirrors Android's `SubtitleTrackMerge`:
    /// combined index = `baseTrackCount + position`, and the stream URL is on
    /// the session-scoped combined-index mount `/stream/{session}/subtitles/{idx}<ext>`.
    func testSynthesizedDescriptorURLIndexAndExtSrt() {
        let sub = DownloadedSubtitle(
            id: 77, mediaFileId: 42, provider: "opensubtitles",
            language: "es", format: "subrip", releaseName: "Movie.2020.1080p"
        )
        // 3 existing non-downloaded tracks (max combined index 2) → base 3.
        let descriptor = sub.synthesizedDescriptor(
            sessionId: "sess-1",
            baseTrackCount: 3,
            position: 0,
            resolveURL: { path in URL(string: "https://host\(path)") }
        )
        XCTAssertNotNil(descriptor)
        XCTAssertTrue(descriptor?.index == 3)
        XCTAssertTrue(descriptor?.url.absoluteString == "https://host/stream/sess-1/subtitles/3.vtt")
        XCTAssertTrue(descriptor?.source == "downloaded")
        XCTAssertTrue(descriptor?.codec == "subrip")
        XCTAssertTrue(descriptor?.language == "es")
        XCTAssertTrue(descriptor?.label == "Movie.2020.1080p (opensubtitles)")
    }

    /// Position offsets the combined index past earlier downloaded entries,
    /// and ASS/SSA keep the raw `.ass` extension.
    func testSynthesizedDescriptorPositionAndAssExt() {
        let sub = DownloadedSubtitle(
            id: 88, provider: "subdl", language: "de", format: "ass", releaseName: "Show.S01E01"
        )
        let descriptor = sub.synthesizedDescriptor(
            sessionId: "sess-9",
            baseTrackCount: 2,
            position: 1,
            resolveURL: { path in URL(string: "https://host\(path)") }
        )
        XCTAssertTrue(descriptor?.index == 3)
        XCTAssertTrue(descriptor?.url.absoluteString == "https://host/stream/sess-9/subtitles/3.ass")
    }

    /// PGS maps to `.sup`; an unresolvable URL yields `nil` (no track).
    func testSynthesizedDescriptorPgsExtAndUnresolvable() {
        let pgs = DownloadedSubtitle(id: 1, provider: "p", format: "pgs", releaseName: "r")
        XCTAssertTrue(pgs.streamURLExtension == ".sup")
        let nilDescriptor = pgs.synthesizedDescriptor(
            sessionId: "s", baseTrackCount: 0, position: 0, resolveURL: { (_: String) -> URL? in nil }
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
