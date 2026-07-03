import XCTest
@testable import Silo

/// Pins the VOD serving mode's restart timeline continuity (plan 1d): a
/// segment produced by a restarted producer must be byte-identical to the
/// same segment produced by the continuous run, modulo the per-muxer mfhd
/// sequence number. Runs the real DVSegmentWriter over a committed 20 s
/// H.264+EAC3 MP4 fixture (keyframe every 2 s, so the 4 s plan cuts on
/// keyframes and the plan is keyframe-trusted).
///
/// The fixture is MP4 deliberately: MP4 stores the decode timeline, so a
/// post-seek demuxer session reproduces the continuous run's DTS exactly.
/// Matroska carries no DTS — FFmpeg synthesizes it after a seek, which
/// scatters the DTS decomposition (and hence segment byte layout) by a
/// frame or two while presentation timestamps stay epoch-invariant, so
/// byte-identity is not the right contract there.
final class DVSegmentWriterVODContinuityTests: XCTestCase {
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
        let writer = DVSegmentWriter(
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
}
