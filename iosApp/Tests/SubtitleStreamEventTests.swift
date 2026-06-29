//
//  SubtitleStreamEventTests.swift
//  SiloTests
//
//  Decoding tests for the five AI subtitle live-streaming events that ride the
//  playback control websocket (Milestone 4). Each event is parsed exactly the
//  way production does it: the raw `{type:"event", session_id, name, payload}`
//  JSON is decoded by `parsePlaybackRealtimeInboundMessage` into a
//  `PlaybackRealtimeEventEnvelope`, then `PlaybackRealtimeSubtitleEvent(name:payload:)`
//  maps the loose payload tree into the typed event.
//
//  Coverage: the `cues` array, absolute media-time seconds carried through
//  verbatim, multi-line `\n` cue text preserved (escaping is the renderer's
//  job, not the decoder's), the enum tolerance fallback, and the per-event
//  field extraction.
//

import XCTest
import Foundation
@testable import Silo

final class SubtitleStreamEventTests: XCTestCase {

    // MARK: - Helpers

    /// Decode a raw websocket event frame into the typed subtitle event,
    /// exercising the real envelope parser + the tolerant event-name enum.
    private func decodeEvent(_ json: String) -> PlaybackRealtimeSubtitleEvent? {
        guard let inbound = parsePlaybackRealtimeInboundMessage(Data(json.utf8)) else {
            XCTFail("envelope failed to parse: \(json)")
            return nil
        }
        guard case .event(let envelope) = inbound else {
            XCTFail("expected an event envelope")
            return nil
        }
        return PlaybackRealtimeSubtitleEvent(name: envelope.name, payload: envelope.payload)
    }

    // MARK: - started

    func testStartedDecodes() {
        let event = decodeEvent("""
        {
          "type": "event",
          "session_id": "sess-1",
          "name": "subtitle_translation_started",
          "payload": {
            "file_id": 42,
            "job_id": "job-7",
            "track_key": "ai-job-7",
            "language": "es",
            "label": "Spanish (AI)",
            "total_cues": 128
          }
        }
        """)
        guard case .started(let started)? = event else {
            return XCTFail("expected .started, got \(String(describing: event))")
        }
        XCTAssertEqual(started.fileId, 42)
        XCTAssertEqual(started.jobId, "job-7")
        XCTAssertEqual(started.trackKey, "ai-job-7")
        XCTAssertEqual(started.language, "es")
        XCTAssertEqual(started.label, "Spanish (AI)")
        XCTAssertEqual(started.totalCues, 128)
        XCTAssertEqual(event?.trackKey, "ai-job-7")
    }

    func testStartedWithoutTrackKeyIsRejected() {
        // A track-scoped event with no track_key is malformed → nil.
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_started",
          "payload": { "file_id": 1 } }
        """)
        XCTAssertNil(event)
    }

    // MARK: - cues (absolute media-time seconds → kept as seconds; multi-line)

    func testCuesArrayDecodesWithAbsoluteSecondsAndMultiline() {
        let event = decodeEvent("""
        {
          "type": "event",
          "session_id": "sess-1",
          "name": "subtitle_translation_cues",
          "payload": {
            "track_key": "ai-job-7",
            "done": false,
            "total": 3,
            "cues": [
              { "start": 12.5, "end": 14.0, "text": "First line." },
              { "start": 14.25, "end": 17.75, "text": "Two lines:\\nsecond line." },
              { "start": 900.0, "end": 902.5, "text": "Way later." }
            ]
          }
        }
        """)
        guard case .cues(let batch)? = event else {
            return XCTFail("expected .cues, got \(String(describing: event))")
        }
        XCTAssertEqual(batch.trackKey, "ai-job-7")
        XCTAssertFalse(batch.done)
        XCTAssertEqual(batch.total, 3)
        XCTAssertEqual(batch.cues.count, 3)

        // Absolute media-time seconds carried through verbatim.
        XCTAssertEqual(batch.cues[0].start, 12.5, accuracy: 0.0001)
        XCTAssertEqual(batch.cues[0].end, 14.0, accuracy: 0.0001)
        XCTAssertEqual(batch.cues[2].start, 900.0, accuracy: 0.0001)

        // Multi-line text preserved (the renderer escapes \n → \N downstream).
        XCTAssertEqual(batch.cues[1].text, "Two lines:\nsecond line.")
    }

    func testCuesDoneHeartbeatWithEmptyArray() {
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_cues",
          "payload": { "track_key": "ai-1", "done": true, "total": 0, "cues": [] } }
        """)
        guard case .cues(let batch)? = event else {
            return XCTFail("expected .cues")
        }
        XCTAssertTrue(batch.done)
        XCTAssertTrue(batch.cues.isEmpty)
    }

    func testCuesSkipsMalformedEntries() {
        // Entries missing finite start/end are skipped; valid ones kept.
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_cues",
          "payload": { "track_key": "ai-1", "cues": [
            { "start": 1.0, "end": 2.0, "text": "kept" },
            { "end": 5.0, "text": "no start — dropped" },
            { "start": 6.0, "text": "no end — dropped" }
          ] } }
        """)
        guard case .cues(let batch)? = event else {
            return XCTFail("expected .cues")
        }
        XCTAssertEqual(batch.cues.count, 1)
        XCTAssertEqual(batch.cues.first?.text, "kept")
    }

    /// `done` may arrive as a numeric 0/1 rather than a JSON bool.
    func testCuesDoneToleratesNumericBoolean() {
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_cues",
          "payload": { "track_key": "ai-1", "done": 1, "cues": [] } }
        """)
        guard case .cues(let batch)? = event else {
            return XCTFail("expected .cues")
        }
        XCTAssertTrue(batch.done)
    }

    // MARK: - completed

    func testCompletedDecodes() {
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_completed",
          "payload": { "track_key": "ai-job-7", "subtitle_id": 555, "language": "es", "label": "Spanish" } }
        """)
        guard case .completed(let completed)? = event else {
            return XCTFail("expected .completed, got \(String(describing: event))")
        }
        XCTAssertEqual(completed.trackKey, "ai-job-7")
        XCTAssertEqual(completed.subtitleId, 555)
        XCTAssertEqual(completed.language, "es")
        XCTAssertEqual(completed.label, "Spanish")
    }

    // MARK: - failed

    func testFailedDecodes() {
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_failed",
          "payload": { "track_key": "ai-job-7", "message": "model unavailable" } }
        """)
        guard case .failed(let failed)? = event else {
            return XCTFail("expected .failed, got \(String(describing: event))")
        }
        XCTAssertEqual(failed.trackKey, "ai-job-7")
        XCTAssertEqual(failed.message, "model unavailable")
    }

    func testFailedWithoutMessageStillDecodes() {
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_translation_failed",
          "payload": { "track_key": "ai-job-7" } }
        """)
        guard case .failed(let failed)? = event else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(failed.trackKey, "ai-job-7")
        XCTAssertNil(failed.message)
    }

    // MARK: - ready (file-scoped, no track_key)

    func testReadyDecodes() {
        let event = decodeEvent("""
        { "type": "event", "session_id": "s", "name": "subtitle_ready",
          "payload": { "file_id": 42, "subtitle_id": 999, "language": "fr", "label": "French" } }
        """)
        guard case .ready(let ready)? = event else {
            return XCTFail("expected .ready, got \(String(describing: event))")
        }
        XCTAssertEqual(ready.fileId, 42)
        XCTAssertEqual(ready.subtitleId, 999)
        XCTAssertEqual(ready.language, "fr")
        XCTAssertEqual(ready.label, "French")
        // `ready` is file-scoped — no track key.
        XCTAssertNil(event?.trackKey)
    }

    // MARK: - Enum tolerance / non-subtitle names

    func testUnknownEventNameDecodesToUnknownAndIsNotASubtitleEvent() {
        // The tolerant enum must decode an unknown name rather than failing the
        // whole envelope (the old strict enum silently dropped it).
        guard let inbound = parsePlaybackRealtimeInboundMessage(Data("""
        { "type": "event", "session_id": "s", "name": "brand_new_server_event", "payload": {} }
        """.utf8)) else {
            return XCTFail("tolerant enum should still parse an unknown event name")
        }
        guard case .event(let envelope) = inbound else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(envelope.name, .unknown("brand_new_server_event"))
        XCTAssertEqual(envelope.name.rawValue, "brand_new_server_event")
        // It is not a subtitle event.
        XCTAssertNil(PlaybackRealtimeSubtitleEvent(name: envelope.name, payload: envelope.payload))
    }

    func testNonSubtitleKnownEventIsNotASubtitleEvent() {
        guard let inbound = parsePlaybackRealtimeInboundMessage(Data("""
        { "type": "event", "session_id": "s", "name": "markers_updated", "payload": { "file_id": 1 } }
        """.utf8)), case .event(let envelope) = inbound else {
            return XCTFail("expected markers event")
        }
        XCTAssertEqual(envelope.name, .markersUpdated)
        XCTAssertNil(PlaybackRealtimeSubtitleEvent(name: envelope.name, payload: envelope.payload))
    }
}
