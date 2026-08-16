import XCTest
@testable import Silo

/// Pins the VOD serving mode's restart timeline continuity (plan 1d): a
/// segment produced by a restarted producer must be byte-identical to the
/// same segment produced by the continuous run, modulo the per-muxer mfhd
/// sequence number. Runs the real LoopbackSegmentWriter over a committed 20 s
/// H.264+EAC3 MP4 fixture (keyframe every 2 s, so the 4 s plan cuts on
/// keyframes and the plan is keyframe-trusted).
///
/// The fixture is MP4 deliberately: MP4 stores the decode timeline, so a
/// post-seek demuxer session reproduces the continuous run's DTS exactly.
/// Matroska carries no DTS — FFmpeg synthesizes it after a seek, which
/// scatters the DTS decomposition (and hence segment byte layout) by a
/// frame or two while presentation timestamps stay epoch-invariant, so
/// byte-identity is not the right contract there.
final class LoopbackSegmentWriterVODContinuityTests: XCTestCase {
    private static let progressiveFlagKey = "player.apple.loopback_progressive_anchor_enabled"

    /// Byte-identity is the contract of SINGLE-fragment production.
    /// Progressive anchor serving deliberately splits a session's first
    /// segment into interim fragments (streamed while producing), so these
    /// tests pin the non-progressive machinery with the kill switch;
    /// `testProgressiveAnchorPreservesTimelineAndContent` pins the
    /// progressive shape's own invariants.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(false, forKey: Self.progressiveFlagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.progressiveFlagKey)
        super.tearDown()
    }

    // MARK: - Harness

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(
            bundle.url(forResource: "loopback_continuity_h264_eac3", withExtension: "mp4"),
            "fixture missing from test bundle — check Tests/Fixtures resources"
        )
    }

    private func makeSpec(sourceURL: URL, startSeconds: Double) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: [:],
            sourceStartTimeSeconds: startSeconds,
            sourceBitrateBps: nil,
            videoMode: .passthroughH264,
            sourceVideoFrameRate: 24,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 0,
                ffIndex: 1,
                sourceCodec: "eac3",
                sourceChannelCount: 2,
                sourceChannelLayout: "stereo",
                outputMode: .copy,
                preservesAtmos: false
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            ),
            servingMode: .vodPlan
        )
    }

    private struct WriterRun {
        let plan: LoopbackSegmentPlan?
        let outputDirectory: URL
        let error: Error?
    }

    private func runWriter(
        spec: LoopbackSessionSpec,
        vodPlan: LoopbackSegmentPlan? = nil,
        vodBaseIndex: Int = 0
    ) -> WriterRun {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vod-continuity-\(UUID().uuidString)", isDirectory: true)
        let writer = LoopbackSegmentWriter(
            sessionSpec: spec,
            outputDirectory: dir,
            vodPlan: vodPlan,
            vodBaseIndex: vodBaseIndex
        )
        let lock = NSLock()
        var resolvedPlan: LoopbackSegmentPlan? = vodPlan
        var finishedError: Error?
        let finished = expectation(description: "writer finished")
        writer.onSegmentPlanResolved = { plan in
            lock.lock()
            resolvedPlan = plan
            lock.unlock()
        }
        writer.onFinished = { error in
            lock.lock()
            finishedError = error
            lock.unlock()
            finished.fulfill()
        }
        writer.start()
        wait(for: [finished], timeout: 120)
        lock.lock()
        defer { lock.unlock() }
        return WriterRun(plan: resolvedPlan, outputDirectory: dir, error: finishedError)
    }

    private func segmentData(_ run: WriterRun, _ index: Int) throws -> Data {
        let name = String(format: "seg_%06d.m4s", index)
        let url = run.outputDirectory.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    // MARK: - ISO box helpers

    private func readU32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 4 <= data.endIndex else { return 0 }
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private func fourCC(_ data: Data, at offset: Int) -> String {
        let i = data.startIndex + offset
        guard i + 4 <= data.endIndex else { return "" }
        return String(bytes: [data[i], data[i + 1], data[i + 2], data[i + 3]], encoding: .ascii) ?? ""
    }

    /// Zeroes every moof's mfhd sequence_number — the one field allowed to
    /// differ between a continuous and a restarted producer (it counts
    /// fragments per muxer instance).
    private func normalizingFragmentSequence(_ data: Data) -> Data {
        var out = data
        var cursor = 0
        while cursor + 8 <= out.count {
            let size = Int(readU32(out, at: cursor))
            guard size >= 8, cursor + size <= out.count else { break }
            if fourCC(out, at: cursor + 4) == "moof",
               fourCC(out, at: cursor + 12) == "mfhd",
               cursor + 24 <= out.count {
                // mfhd: size(4) type(4) version+flags(4) sequence_number(4)
                for i in 0..<4 {
                    out[out.startIndex + cursor + 20 + i] = 0
                }
            }
            cursor += size
        }
        return out
    }

    private func tfdtBaseDecodeTimes(_ data: Data) -> [UInt64] {
        var result: [UInt64] = []
        collectTfdt(data, from: 0, to: data.count, into: &result)
        return result
    }

    private func collectTfdt(_ data: Data, from: Int, to: Int, into result: inout [UInt64]) {
        var cursor = from
        while cursor + 8 <= to {
            let size = Int(readU32(data, at: cursor))
            guard size >= 8, cursor + size <= to else { return }
            switch fourCC(data, at: cursor + 4) {
            case "moof", "traf":
                collectTfdt(data, from: cursor + 8, to: cursor + size, into: &result)
            case "tfdt":
                let version = data[data.startIndex + cursor + 8]
                if version == 1, cursor + 20 <= to {
                    var value: UInt64 = 0
                    for i in 0..<8 {
                        value = (value << 8) | UInt64(data[data.startIndex + cursor + 12 + i])
                    }
                    result.append(value)
                } else if cursor + 16 <= to {
                    result.append(UInt64(readU32(data, at: cursor + 12)))
                }
            default:
                break
            }
            cursor += size
        }
    }

    // MARK: - Tests

    func testContinuousVODRunPlansAndProducesAllSegments() throws {
        let run = runWriter(spec: makeSpec(sourceURL: try fixtureURL(), startSeconds: 0))
        XCTAssertNil(run.error)
        let plan = try XCTUnwrap(run.plan)
        XCTAssertTrue(plan.usedKeyframeIndex, "2 s keyframe cadence must pass the trust gates")
        XCTAssertEqual(plan.segmentCount, 5, "20 s at 4 s target")

        for index in 0..<plan.segmentCount {
            let name = String(format: "seg_%06d.m4s", index)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: run.outputDirectory.appendingPathComponent(name).path
                ),
                "\(name) missing"
            )
        }
        let playlist = try String(
            contentsOf: run.outputDirectory.appendingPathComponent("playlist.m3u8"),
            encoding: .utf8
        )
        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(playlist.contains("seg_000004.m4s"), "full title advertised up front")

        // Non-vacuous continuity precondition: a mid-title segment's tfdt
        // carries the absolute session timeline, not a zero-based one.
        let tfdts = tfdtBaseDecodeTimes(try segmentData(run, 2))
        XCTAssertFalse(tfdts.isEmpty)
        XCTAssertTrue(tfdts.contains { $0 > 0 }, "seg 2 must not be zero-based")
    }

    func testResumeFirstSessionAnchorsAtResumeSegment() throws {
        // The living-room resume bug: a FIRST session (no pre-resolved plan,
        // base 0) with a mid-title start time must anchor at the resume
        // segment — producing the identical bytes an explicit restart would
        // — and must not produce leading segments it was never asked for.
        let source = try fixtureURL()
        let continuous = runWriter(spec: makeSpec(sourceURL: source, startSeconds: 0))
        let plan = try XCTUnwrap(continuous.plan)

        let resumeIndex = 2
        let resumed = runWriter(
            spec: makeSpec(
                sourceURL: source,
                startSeconds: plan.sourceStartSeconds(ofSegment: resumeIndex)
            ),
            vodPlan: nil,
            vodBaseIndex: 0
        )
        XCTAssertNil(resumed.error)
        XCTAssertEqual(
            normalizingFragmentSequence(try segmentData(continuous, resumeIndex)),
            normalizingFragmentSequence(try segmentData(resumed, resumeIndex)),
            "resume-anchored production must match the continuous timeline"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resumed.outputDirectory.appendingPathComponent("seg_000000.m4s").path
            ),
            "a resume-anchored session must not produce leading segments"
        )
    }

    func testRestartedProducerReproducesContinuousSegmentByteIdentically() throws {
        let source = try fixtureURL()
        let continuous = runWriter(spec: makeSpec(sourceURL: source, startSeconds: 0))
        XCTAssertNil(continuous.error)
        let plan = try XCTUnwrap(continuous.plan)

        let restartIndex = 2
        let restarted = runWriter(
            spec: makeSpec(
                sourceURL: source,
                startSeconds: plan.sourceStartSeconds(ofSegment: restartIndex)
            ),
            vodPlan: plan,
            vodBaseIndex: restartIndex
        )
        XCTAssertNil(restarted.error)

        let continuousSegment = try segmentData(continuous, restartIndex)
        let restartedSegment = try segmentData(restarted, restartIndex)

        XCTAssertEqual(
            tfdtBaseDecodeTimes(continuousSegment),
            tfdtBaseDecodeTimes(restartedSegment),
            "restarted segment must continue the session timeline"
        )
        XCTAssertEqual(
            normalizingFragmentSequence(continuousSegment),
            normalizingFragmentSequence(restartedSegment),
            "restarted segment must be byte-identical modulo mfhd sequence"
        )
    }

    func testProgressiveAnchorPreservesTimelineAndContent() throws {
        // With progressive serving ON, a restarted producer's anchor segment
        // is multi-fragment (interim flushes streamed while producing). The
        // byte layout legitimately differs from the continuous twin; what
        // must hold: the first fragment continues the session timeline
        // (same leading tfdts) and the segment carries the identical media
        // payload volume.
        UserDefaults.standard.set(true, forKey: Self.progressiveFlagKey)
        let source = try fixtureURL()
        let continuous = runWriter(spec: makeSpec(sourceURL: source, startSeconds: 0))
        XCTAssertNil(continuous.error)
        let plan = try XCTUnwrap(continuous.plan)

        let restartIndex = 2
        let restarted = runWriter(
            spec: makeSpec(
                sourceURL: source,
                startSeconds: plan.sourceStartSeconds(ofSegment: restartIndex)
            ),
            vodPlan: plan,
            vodBaseIndex: restartIndex
        )
        XCTAssertNil(restarted.error)

        let continuousSegment = try segmentData(continuous, restartIndex)
        let restartedSegment = try segmentData(restarted, restartIndex)

        let continuousTfdts = tfdtBaseDecodeTimes(continuousSegment)
        let restartedTfdts = tfdtBaseDecodeTimes(restartedSegment)
        XCTAssertEqual(
            Array(restartedTfdts.prefix(continuousTfdts.count)),
            continuousTfdts,
            "progressive anchor's first fragment must continue the session timeline"
        )
        XCTAssertGreaterThan(
            restartedTfdts.count,
            continuousTfdts.count,
            "anchor must actually be multi-fragment with progressive serving on"
        )
        XCTAssertEqual(
            totalMdatPayloadBytes(restartedSegment),
            totalMdatPayloadBytes(continuousSegment),
            "fragmentation must not change the media payload volume"
        )

        // Steady-state segments past the anchor stay single-fragment and
        // byte-identical to the continuous run.
        XCTAssertEqual(
            normalizingFragmentSequence(try segmentData(continuous, restartIndex + 1)),
            normalizingFragmentSequence(try segmentData(restarted, restartIndex + 1)),
            "post-anchor segments must keep byte-identity"
        )
    }

    // MARK: - Well-formed-fragment regression

    /// Regression guard for the finalize-time segment discard. The discard used
    /// to key on the `pendingSegmentHasMoof` status flag; the fix keys on the
    /// buffer's box STRUCTURE (`pendingSegmentContainsMediaBox`) so that only a
    /// media-less tail (`av_write_trailer`'s `mfra`/`mfro`, or a stray
    /// `styp`/`sidx`) is dropped, and a fragment carrying real media is never
    /// silently discarded into a plan-indexed hole. A dropped mid-title segment
    /// is exactly what makes AVPlayer reject playback with CoreMedia -17223.
    ///
    /// Every finalized media segment must therefore be a well-formed fragment:
    /// a `moof` paired with an `mdat`, and never the trailer index tail. The
    /// per-segment duration is also bounded so a coalesced/merged segment can't
    /// silently balloon past the target without the playlist noticing.
    ///
    /// Coverage gap: the committed fixtures are small H.264/EAC3 clips that
    /// cut cleanly and never hit the 4K-HEVC producer-backpressure/restart
    /// window where the on-device -17223 was captured. This pins the structural
    /// invariant the fix restores across every path the fixtures can drive
    /// (continuous, and a mid-stream producer restart); reproducing the exact
    /// device timeline would need a committed 4K-HEVC fixture.
    func testEveryFinalizedSegmentIsWellFormedFragment() throws {
        let source = try fixtureURL()
        let continuous = runWriter(spec: makeSpec(sourceURL: source, startSeconds: 0))
        XCTAssertNil(continuous.error)
        let plan = try XCTUnwrap(continuous.plan)
        let durationCeiling = LoopbackSegmentPlan.defaultTargetSegmentDurationSeconds * 1.5

        try assertSegmentsWellFormed(continuous, count: plan.segmentCount, from: 0)
        for (index, duration) in try segmentDurations(continuous).enumerated() {
            XCTAssertLessThanOrEqual(
                duration, durationCeiling,
                "continuous seg \(index) duration \(duration)s exceeds 1.5x target"
            )
        }

        // The restart path is the one closest to the on-device failure: a
        // producer re-anchored mid-title must still finalize well-formed
        // fragments (and never leave the anchor as a media-less tail).
        let restartIndex = 2
        let restarted = runWriter(
            spec: makeSpec(
                sourceURL: source,
                startSeconds: plan.sourceStartSeconds(ofSegment: restartIndex)
            ),
            vodPlan: plan,
            vodBaseIndex: restartIndex
        )
        XCTAssertNil(restarted.error)
        try assertSegmentsWellFormed(
            restarted, count: plan.segmentCount, from: restartIndex
        )
    }

    private func assertSegmentsWellFormed(
        _ run: WriterRun, count: Int, from firstIndex: Int
    ) throws {
        for index in firstIndex..<count {
            let name = String(format: "seg_%06d.m4s", index)
            let path = run.outputDirectory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else {
                XCTFail("seg \(index) was not produced (dropped into a plan-indexed hole)")
                continue
            }
            let types = topLevelBoxTypes(try segmentData(run, index))
            XCTAssertTrue(types.contains("moof"), "seg \(index) has no moof: \(types)")
            XCTAssertTrue(types.contains("mdat"), "seg \(index) has no mdat: \(types)")
            XCTAssertFalse(
                types.contains("mfra") || types.contains("mfro"),
                "seg \(index) leaked the av_write_trailer index tail: \(types)"
            )
        }
    }

    private func topLevelBoxTypes(_ data: Data) -> [String] {
        var types: [String] = []
        var cursor = 0
        while cursor + 8 <= data.count {
            let size = Int(readU32(data, at: cursor))
            guard size >= 8, cursor + size <= data.count else { break }
            types.append(fourCC(data, at: cursor + 4))
            cursor += size
        }
        return types
    }

    private func segmentDurations(_ run: WriterRun) throws -> [Double] {
        let playlist = try String(
            contentsOf: run.outputDirectory.appendingPathComponent("playlist.m3u8"),
            encoding: .utf8
        )
        return playlist.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("#EXTINF:") else { return nil }
            return Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
        }
    }

    private func totalMdatPayloadBytes(_ data: Data) -> Int {
        var total = 0
        var cursor = 0
        while cursor + 8 <= data.count {
            let size = Int(readU32(data, at: cursor))
            guard size >= 8, cursor + size <= data.count else { break }
            if fourCC(data, at: cursor + 4) == "mdat" {
                total += size - 8
            }
            cursor += size
        }
        return total
    }
}
