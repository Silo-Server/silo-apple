import Foundation
import XCTest
@testable import Silo

/// Stage-0 characterization: the `LoopbackSessionSpec` copy helpers must
/// preserve every field they do not deliberately change.
///
/// The spec has no `Equatable` conformance, so nothing today catches a copy
/// helper that quietly drops a stored property. This matters because the
/// review found exactly that failure mode elsewhere: the source proxy rebuilt
/// a spec field-by-field and lost carried execution decisions. These
/// assertions pin the helper that gets it right, so a second one has a
/// contract to match.
final class LoopbackSessionSpecCopyHelperTests: XCTestCase {

    private static let sourceURL = URL(string: "https://example.invalid/movie.mkv")!

    private func audioTrack(id: Int64, srcId: Int, ffIndex: Int) -> PlayerTrack {
        PlayerTrack(
            trackId: id,
            kind: .audio,
            title: "Track \(srcId)",
            lang: "eng",
            codec: "eac3",
            audioChannelsLayout: "5.1",
            audioChannelCount: 6,
            bitrate: 640_000,
            isDefault: srcId == 0,
            isForced: false,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: ffIndex,
            srcId: srcId
        )
    }

    /// Deliberately populates every optional so a dropped field shows up as a
    /// nil rather than as an equal default.
    private func makeSpec() -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: Self.sourceURL,
            headers: ["Authorization": "Bearer spec", "Range": "bytes=0-"],
            sourceStartTimeSeconds: 42.5,
            sourceBitrateBps: 18_000_000,
            videoMode: .passthroughProfile8(.hlg),
            sourceVideoFrameRate: 23.976,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 1,
                ffIndex: 3,
                sourceCodec: "truehd",
                sourceChannelCount: 8,
                sourceChannelLayout: "7.1",
                outputMode: .requireFLAC,
                preservesAtmos: true
            ),
            availableAudioTracks: [
                audioTrack(id: 100, srcId: 0, ffIndex: 2),
                audioTrack(id: 101, srcId: 1, ffIndex: 3)
            ],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: 8,
                compatibilityBrand: "db4h",
                videoRange: "HLG",
                mayClaimAtmos: true
            )
        )
    }

    /// Every field except the ones the helper is allowed to change.
    private func assertCarriesEverything(
        _ copy: LoopbackSessionSpec,
        from original: LoopbackSessionSpec,
        exceptStartTime: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(copy.sourceURL, original.sourceURL, "sourceURL", file: file, line: line)
        XCTAssertEqual(copy.headers, original.headers, "headers", file: file, line: line)
        if !exceptStartTime {
            XCTAssertEqual(
                copy.sourceStartTimeSeconds,
                original.sourceStartTimeSeconds,
                "sourceStartTimeSeconds", file: file, line: line
            )
        }
        XCTAssertEqual(
            copy.sourceBitrateBps, original.sourceBitrateBps,
            "sourceBitrateBps", file: file, line: line
        )
        XCTAssertEqual(copy.videoMode, original.videoMode, "videoMode", file: file, line: line)
        XCTAssertEqual(
            copy.sourceVideoFrameRate, original.sourceVideoFrameRate,
            "sourceVideoFrameRate", file: file, line: line
        )
        XCTAssertEqual(
            copy.selectedAudio, original.selectedAudio,
            "selectedAudio", file: file, line: line
        )
        XCTAssertEqual(
            copy.availableAudioTracks.map(\.trackId),
            original.availableAudioTracks.map(\.trackId),
            "availableAudioTracks", file: file, line: line
        )
        XCTAssertEqual(
            copy.availableAudioTracks.map(\.isSelected),
            original.availableAudioTracks.map(\.isSelected),
            "availableAudioTracks selection", file: file, line: line
        )
        XCTAssertEqual(
            copy.manifestMetadata, original.manifestMetadata,
            "manifestMetadata", file: file, line: line
        )
    }

    // MARK: - Every stored property is covered

    /// If a property is added to the spec, this fails and the assertions above
    /// have to be extended — otherwise a new field would silently escape both
    /// copy helpers.
    func testAssertionsCoverEveryStoredProperty() {
        let mirrored = Set(Mirror(reflecting: makeSpec()).children.compactMap(\.label))
        XCTAssertEqual(mirrored, [
            "sourceURL",
            "headers",
            "sourceStartTimeSeconds",
            "sourceBitrateBps",
            "videoMode",
            "sourceVideoFrameRate",
            "selectedAudio",
            "availableAudioTracks",
            "manifestMetadata"
        ])
    }

    // MARK: - reanchored(at:)

    func testReanchoredChangesOnlyTheStartTime() {
        let original = makeSpec()
        let copy = original.reanchored(at: 900)

        XCTAssertEqual(copy.sourceStartTimeSeconds, 900)
        XCTAssertEqual(original.sourceStartTimeSeconds, 42.5, "the original must not mutate")
        assertCarriesEverything(copy, from: original, exceptStartTime: true)
    }

    /// The designated initializer sanitizes the anchor, and the copy helper
    /// routes through it, so a recovery reanchor computed from a NaN or
    /// negative playhead cannot produce a spec the writer will seek with.
    func testReanchoredSanitizesTheAnchor() {
        let original = makeSpec()

        XCTAssertEqual(original.reanchored(at: -5).sourceStartTimeSeconds, 0)
        XCTAssertEqual(original.reanchored(at: .nan).sourceStartTimeSeconds, 0)
        XCTAssertEqual(original.reanchored(at: .infinity).sourceStartTimeSeconds, 0)
    }

    func testReanchoringIsIdempotentInItsCarriedFields() {
        let original = makeSpec()
        let twice = original.reanchored(at: 100).reanchored(at: 200)

        XCTAssertEqual(twice.sourceStartTimeSeconds, 200)
        assertCarriesEverything(twice, from: original, exceptStartTime: true)
    }

}
