import Foundation
import XCTest
@testable import Silo

/// The `TrackSelection` model's own resolution rules (Stage 2 wave 4).
///
/// `TrackSelectionCoordinatorTests` drives the two apply funnels end to end;
/// this file pins the value semantics they depend on — which field each funnel
/// consumes, that consuming one leaves the others armed, and that the index
/// space a field names is the one it hands back.
final class TrackSelectionTests: XCTestCase {

    // MARK: - Fields are independent

    /// A resume that carries an explicit sidecar pick arms two fields at once:
    /// the embedded plane must go "Off" (so the container default does not
    /// surface while the sidecar rows are still loading) and the sidecar has to
    /// be re-selected once they arrive. The eight `pending*` optionals did this
    /// by being eight separate fields; the selection does it in one value.
    func testSidecarResumeArmsEmbeddedOffAndTheSidecarFieldTogether() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 4)
        let selection = SubtitleSelection(
            embedded: .wireIndex(-1),
            sidecarTrackId: sidecarId
        )

        XCTAssertEqual(selection.embedded, .off)
        XCTAssertEqual(selection.sidecarTrackId, sidecarId)
        XCTAssertNil(selection.serverRenderedTrackId)
        XCTAssertNil(selection.recovered)
    }

    /// The track-list funnel consumes the embedded field and the sidecar-append
    /// funnel the sidecar field; neither may take the other's.
    func testConsumingOneFieldLeavesTheOthersArmed() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 4)
        let snapshot = TrackSelectionSnapshot(track: subtitleTrack(trackId: 20, ffIndex: 2))
        var selection = SubtitleSelection(
            embedded: .wireIndex(7),
            sidecarTrackId: sidecarId,
            recovered: snapshot
        )

        selection.embedded = nil
        XCTAssertNil(selection.embedded)
        XCTAssertEqual(selection.sidecarTrackId, sidecarId)
        XCTAssertEqual(selection.recovered, snapshot)

        selection.sidecarTrackId = nil
        XCTAssertNil(selection.sidecarTrackId)
        XCTAssertEqual(selection.recovered, snapshot)

        selection.recovered = nil
        XCTAssertEqual(selection, .unset)
    }

    /// The `-1` wire sentinel is the explicit "Off" rung, and only negative
    /// values are: index 0 is a real embedded stream.
    func testNegativeEmbeddedIndexIsTheExplicitOffRung() {
        XCTAssertEqual(SubtitleSelection.EmbeddedRung.wireIndex(-1), .off)
        XCTAssertEqual(SubtitleSelection.EmbeddedRung.wireIndex(0), .stream(ffIndex: 0))
        XCTAssertEqual(SubtitleSelection.EmbeddedRung.wireIndex(3), .stream(ffIndex: 3))
        XCTAssertNil(SubtitleSelection.EmbeddedRung.wireIndex(nil))
    }

    // MARK: - Audio axis

    /// A route recovery seeds the plan index *and* the pre-rebuild snapshot:
    /// the exact index is tried first and the snapshot is the fallback for the
    /// case where the replacement stream no longer publishes it.
    func testAudioSelectionKeepsThePlanIndexAndTheRecoverySnapshot() {
        let snapshot = TrackSelectionSnapshot(track: audioTrack(trackId: 99, srcId: 1))
        var audio = AudioSelection(planIndex: 1, recovered: snapshot)

        XCTAssertEqual(audio.planIndex, 1)
        XCTAssertEqual(audio.recovered, snapshot)

        audio.planIndex = nil
        XCTAssertEqual(
            audio,
            AudioSelection(recovered: snapshot),
            "the fuzzy fallback survives the exact match"
        )
    }

    // MARK: - Plan-named selections

    /// The plan's `subtitle.mode` decides which index space the selection lands
    /// in: `render` hands the client a sidecar to open, `burn_in` leaves it a
    /// picker row only, and everything else selects nothing.
    func testPlannedSubtitleNamesTheModesIndexSpace() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
        XCTAssertEqual(
            SubtitleSelection.planned(selectedSubtitleIndex: 3, subtitleMode: "render"),
            SubtitleSelection(sidecarTrackId: sidecarId)
        )
        XCTAssertEqual(
            SubtitleSelection.planned(selectedSubtitleIndex: 3, subtitleMode: "burn_in"),
            SubtitleSelection(serverRenderedTrackId: sidecarId)
        )
        XCTAssertEqual(
            SubtitleSelection.planned(selectedSubtitleIndex: 3, subtitleMode: "off"),
            .unset
        )
        XCTAssertEqual(
            SubtitleSelection.planned(selectedSubtitleIndex: nil, subtitleMode: "render"),
            .unset
        )
    }

    /// A route that does not extract embedded streams itself registers every
    /// text sidecar URL the server delivered, untouched.
    func testRouteWithoutEmbeddedExtractionKeepsEverySidecarUrl() {
        let urls = [
            subtitleUrl(index: 3, source: "external"),
            subtitleUrl(index: 9, source: "embedded"),
        ]
        XCTAssertEqual(
            SubtitleSelection.subtitleUrlsForCurrentRoute(
                urls,
                routeUsesEmbeddedExtraction: false,
                protocolV3PlanActive: true,
                planned: .planned(selectedSubtitleIndex: 9, subtitleMode: "burn_in")
            ),
            urls
        )
    }

    /// A bitmap sidecar is never renderable here, so it is worth a picker row
    /// only while a V3 plan is live to burn it in after a replan. Without a
    /// plan it is dropped rather than registered as a text sidecar (which
    /// decodes a `.sup` as VTT and installs a checked-but-blank track).
    func testBitmapSidecarSurvivesOnlyWhileAProtocolV3PlanCanBurnItIn() {
        let text = subtitleUrl(index: 3, source: "external")
        let bitmap = subtitleUrl(index: 4, source: "external", codec: "hdmv_pgs_subtitle")

        XCTAssertEqual(
            SubtitleSelection.subtitleUrlsForCurrentRoute(
                [text, bitmap],
                routeUsesEmbeddedExtraction: false,
                protocolV3PlanActive: true,
                planned: .unset
            ).map(\.index),
            [3, 4]
        )
        XCTAssertEqual(
            SubtitleSelection.subtitleUrlsForCurrentRoute(
                [text, bitmap],
                routeUsesEmbeddedExtraction: false,
                protocolV3PlanActive: false,
                planned: .unset
            ).map(\.index),
            [3],
            "no plan means no replan, so an undrawable row is dropped"
        )
    }

    // MARK: - Fuzzy restore scoring

    /// The weights, and the two rules that decide whether they are counted at
    /// all: title 4, language 3, codec 2, layout 2, forced/external/HI 1 each,
    /// but only for a candidate that agrees on a positive anchor — the same
    /// language, the same title, or the same codec *and* layout.
    func testSnapshotScoreWeightsEveryComparedAttribute() {
        let snapshot = TrackSelectionSnapshot(track: audioTrack(trackId: 1, srcId: 0))

        XCTAssertEqual(snapshot.score(against: audioTrack(trackId: 2, srcId: 0)), 14)
        XCTAssertEqual(
            snapshot.score(against: audioTrack(trackId: 2, srcId: 0, title: "Other")),
            10
        )
        XCTAssertEqual(
            snapshot.score(
                against: audioTrack(trackId: 2, srcId: 0, title: "Other", codec: "aac", layout: "stereo")
            ),
            6,
            "language alone anchors the candidate and clears the >= 3 floor"
        )
        XCTAssertEqual(
            snapshot.score(
                against: audioTrack(
                    trackId: 2,
                    srcId: 0,
                    title: "Other",
                    lang: "fra",
                    codec: "aac",
                    layout: "stereo"
                )
            ),
            0,
            "agreement on forced + external + hearing-impaired alone is not a match"
        )
    }

    /// Absent metadata is not agreement: two tracks that both say nothing about
    /// their title or layout have said nothing about each other.
    func testSnapshotScoresNothingForAttributesNeitherTrackReports() {
        let snapshot = TrackSelectionSnapshot(
            track: audioTrack(trackId: 1, srcId: 0, title: nil, lang: "eng", layout: nil)
        )

        XCTAssertEqual(
            snapshot.score(
                against: audioTrack(trackId: 2, srcId: 0, title: nil, lang: "eng", layout: nil)
            ),
            8,
            "language (3) + codec (2) + the three flags; the two nil attributes score nothing"
        )
        XCTAssertEqual(
            snapshot.score(
                against: audioTrack(trackId: 2, srcId: 0, title: nil, lang: "fra", layout: nil)
            ),
            0,
            "a shared codec with no layout on either side is not an anchor"
        )
    }

    /// Attribute comparison is case- and whitespace-insensitive, so a server
    /// that re-cases a codec between plans does not lose the selection.
    func testSnapshotComparesNormalizedAttributes() {
        let snapshot = TrackSelectionSnapshot(track: audioTrack(trackId: 1, srcId: 0, codec: "AC3"))
        XCTAssertEqual(
            snapshot.score(against: audioTrack(trackId: 2, srcId: 0, codec: " ac3 ")),
            14
        )
    }

    // MARK: - Helpers

    private func audioTrack(
        trackId: Int64,
        srcId: Int?,
        title: String? = "Director",
        lang: String? = "eng",
        codec: String? = "ac3",
        layout: String? = "5.1"
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: .audio,
            title: title,
            lang: lang,
            codec: codec,
            audioChannelsLayout: layout,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: nil,
            srcId: srcId
        )
    }

    private func subtitleTrack(trackId: Int64, ffIndex: Int?) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: .sub,
            title: "English",
            lang: "eng",
            codec: "subrip",
            audioChannelsLayout: nil,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: ffIndex,
            srcId: nil
        )
    }

    private func subtitleUrl(index: Int, source: String, codec: String = "subrip") -> SubtitleUrl {
        SubtitleUrl(
            index: index,
            language: "eng",
            codec: codec,
            label: "English",
            source: source,
            forced: false,
            url: "/subtitles/\(index).srt"
        )
    }
}
