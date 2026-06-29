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
        let job = decode(SubtitleJob.self, """
        {
          "id": "job-123",
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
        XCTAssertTrue(job.id == "job-123")
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
          "id": "job-tt",
          "media_file_id": 7,
          "kind": "transcribe_translate",
          "source_index": -1,
          "status": "completed",
          "progress": 1.0,
          "result_subtitle_id": 99
        }
        """)
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

    func testSubtitleJobEnvelope() {
        let env = decode(SubtitleJobEnvelope.self, """
        { "job": { "id": "j1", "kind": "translate", "source_index": 0, "status": "pending", "progress": 0 } }
        """)
        XCTAssertTrue(env.job.id == "j1")
        XCTAssertTrue(env.job.status == .pending)
    }

    func testSubtitleJobsEnvelope() {
        let env = decode(SubtitleJobsEnvelope.self, """
        {
          "jobs": [
            { "id": "a", "kind": "translate", "source_index": 0, "status": "completed", "progress": 1, "result_subtitle_id": 5 },
            { "id": "b", "kind": "transcribe", "source_index": -1, "status": "running", "progress": 0.2 }
          ]
        }
        """)
        XCTAssertTrue(env.jobs.count == 2)
        XCTAssertTrue(env.jobs[0].id == "a")
        XCTAssertTrue(env.jobs[0].resultSubtitleId == 5)
        XCTAssertTrue(env.jobs[1].kind == .transcribe)
    }

    func testSubtitleJobsEnvelopeMissingArray() {
        // Tolerant: an envelope with no `jobs` key decodes to an empty array.
        let env = decode(SubtitleJobsEnvelope.self, "{}")
        XCTAssertTrue(env.jobs.isEmpty)
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

    func testDownloadedSubtitlesResponse() {
        let response = decode(DownloadedSubtitlesResponse.self, """
        {
          "subtitles": [
            { "index": 5, "language": "es", "codec": "subrip", "label": "Spanish (AI)", "source": "downloaded", "forced": false, "url": "/api/v1/subtitles/file/5.vtt" }
          ]
        }
        """)
        XCTAssertTrue(response.subtitles.count == 1)
        let sub = response.subtitles[0]
        XCTAssertTrue(sub.index == 5)
        XCTAssertTrue(sub.language == "es")
        XCTAssertTrue(sub.source == "downloaded")
        XCTAssertTrue(sub.url == "/api/v1/subtitles/file/5.vtt")
    }

    func testDownloadedSubtitlesResponseMissingArray() {
        let response = decode(DownloadedSubtitlesResponse.self, "{}")
        XCTAssertTrue(response.subtitles.isEmpty)
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
