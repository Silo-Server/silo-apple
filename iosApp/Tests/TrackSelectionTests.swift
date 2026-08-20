import Foundation
import XCTest
@testable import Silo

/// The `TrackSelection` model's own resolution rules (Stage 2 wave 4).
///
/// `TrackSelectionCoordinatorTests` drives the two apply funnels end to end;
/// this file pins the value semantics they depend on — which rung each setter
/// touches, that consuming one rung leaves the others armed, and that the
/// index space a case names is the one it hands back.
final class TrackSelectionTests: XCTestCase {

    // MARK: - Rungs are independent

    /// A resume that carries an explicit sidecar pick arms two rungs at once:
    /// the embedded plane must go "Off" (so the container default does not
    /// surface while the sidecar rows are still loading) and the sidecar has to
    /// be re-selected once they arrive. The eight `pending*` fields did this by
    /// being eight fields; the ladder does it in one value.
    func testSidecarResumeArmsEmbeddedOffAndTheSidecarRungTogether() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 4)
        let selection = SubtitleSelection.unset
            .settingEmbedded(ffIndex: -1)
            .settingSidecar(trackId: sidecarId)

        XCTAssertEqual(selection, .ladder([.off, .sidecar(trackId: sidecarId)]))
        XCTAssertEqual(selection.embeddedRung, .off)
        XCTAssertEqual(selection.sidecarTrackId, sidecarId)
        XCTAssertNil(selection.serverRenderedTrackId)
        XCTAssertNil(selection.recoveredSnapshot)
    }

    /// The track-list funnel consumes the embedded rung and the sidecar-append
    /// funnel the sidecar rung; neither may take the other's.
    func testConsumingOneRungLeavesTheOthersArmed() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 4)
        let snapshot = TrackSelectionSnapshot(track: subtitleTrack(trackId: 20, ffIndex: 2))
        var selection = SubtitleSelection.unset
            .settingEmbedded(ffIndex: 7)
            .settingSidecar(trackId: sidecarId)
            .settingRecovered(snapshot)

        selection = selection.settingEmbedded(ffIndex: nil)
        XCTAssertNil(selection.embeddedRung)
        XCTAssertEqual(selection.sidecarTrackId, sidecarId)
        XCTAssertEqual(selection.recoveredSnapshot, snapshot)

        selection = selection.settingSidecar(trackId: nil)
        XCTAssertNil(selection.sidecarTrackId)
        XCTAssertEqual(selection.recoveredSnapshot, snapshot)

        selection = selection.settingRecovered(nil)
        XCTAssertEqual(selection, .unset)
        XCTAssertTrue(selection.rungs.isEmpty)
    }

    /// A single armed rung is that case, not a one-element ladder — otherwise
    /// two equal selections would compare unequal depending on how they were
    /// built.
    func testSettersNormalizeToASingleRungCase() {
        XCTAssertEqual(SubtitleSelection.unset.settingEmbedded(ffIndex: 3), .embedded(ffIndex: 3))
        XCTAssertEqual(
            SubtitleSelection.embedded(ffIndex: 3).settingEmbedded(ffIndex: 5),
            .embedded(ffIndex: 5),
            "arming the same plane twice replaces the rung rather than stacking it"
        )
        XCTAssertEqual(AudioSelection.unset.settingPlanIndex(2), .planIndex(2))
        XCTAssertEqual(AudioSelection.planIndex(2).settingPlanIndex(nil), .unset)
    }

    /// The `-1` wire sentinel is the explicit "Off" case, and only negative
    /// values are: index 0 is a real embedded stream.
    func testNegativeEmbeddedIndexIsTheExplicitOffRung() {
        XCTAssertEqual(SubtitleSelection.unset.settingEmbedded(ffIndex: -1), .off)
        XCTAssertEqual(SubtitleSelection.unset.settingEmbedded(ffIndex: 0), .embedded(ffIndex: 0))
        XCTAssertEqual(SubtitleSelection.unset.settingEmbedded(ffIndex: nil), .unset)
    }

    // MARK: - Audio ladder

    /// A route recovery seeds the plan index *and* the pre-rebuild snapshot:
    /// the exact index is tried first and the snapshot is the fallback for the
    /// case where the replacement stream no longer publishes it.
    func testAudioLadderKeepsThePlanIndexAndTheRecoverySnapshot() {
        let snapshot = TrackSelectionSnapshot(track: audioTrack(trackId: 99, srcId: 1))
        var audio = AudioSelection.unset
            .settingPlanIndex(1)
            .settingRecovered(snapshot)

        XCTAssertEqual(audio, .ladder([.planIndex(1), .recovered(snapshot)]))
        XCTAssertEqual(audio.planIndex, 1)
        XCTAssertEqual(audio.recoveredSnapshot, snapshot)

        audio = audio.settingPlanIndex(nil)
        XCTAssertNil(audio.planIndex)
        XCTAssertEqual(audio, .recovered(snapshot), "the fuzzy fallback survives the exact match")
    }

    // MARK: - Plan-named selections

    /// The plan's `subtitle.mode` decides which index space the selection lands
    /// in: `render` hands the client a sidecar to open, `burn_in` leaves it a
    /// picker row only, and everything else selects nothing.
    func testPlannedSubtitleNamesTheModesIndexSpace() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
        XCTAssertEqual(
            SubtitleSelection.planned(selectedSubtitleIndex: 3, subtitleMode: "render"),
            .sidecar(trackId: sidecarId)
        )
        XCTAssertEqual(
            SubtitleSelection.planned(selectedSubtitleIndex: 3, subtitleMode: "burn_in"),
            .serverRendered(trackId: sidecarId)
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
    /// sidecar URL the server delivered, untouched.
    func testRouteWithoutEmbeddedExtractionKeepsEverySidecarUrl() {
        let urls = [
            subtitleUrl(index: 3, source: "external"),
            subtitleUrl(index: 9, source: "embedded"),
        ]
        XCTAssertEqual(
            SubtitleSelection.subtitleUrlsForCurrentRoute(
                urls,
                routeUsesEmbeddedExtraction: false,
                planned: .planned(selectedSubtitleIndex: 9, subtitleMode: "burn_in")
            ),
            urls
        )
    }

    // MARK: - Fuzzy restore scoring

    /// The weights and the `>= 3` acceptance floor `bestTrackMatch` applies:
    /// title 4, language 3, codec 2, layout 2, forced/external/HI 1 each.
    func testSnapshotScoreWeightsEveryComparedAttribute() {
        let snapshot = TrackSelectionSnapshot(track: audioTrack(trackId: 1, srcId: 0))

        XCTAssertEqual(snapshot.score(against: audioTrack(trackId: 2, srcId: 0)), 14)
        XCTAssertEqual(
            snapshot.score(against: audioTrack(trackId: 2, srcId: 0, title: "Other")),
            10
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
            3,
            "the accepted floor is agreement on forced + external + hearing-impaired alone"
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

    private func subtitleUrl(index: Int, source: String) -> SubtitleUrl {
        SubtitleUrl(
            index: index,
            language: "eng",
            codec: "subrip",
            label: "English",
            source: source,
            forced: false,
            url: "/subtitles/\(index).srt"
        )
    }
}
