import Foundation

/// Attribute snapshot of a track that has to survive a backend rebuild.
///
/// Track ids are not stable across a stream swap (a quality switch, a route
/// fallback, a transcode restart), so a selection that cannot be re-established
/// by id is re-established by scoring the replacement list against these
/// normalized attributes. `TrackSelectionCoordinator.bestTrackMatch` takes the
/// best-scoring candidate at `>= 3`; `score(against:)` owns which agreements
/// can reach that floor.
struct TrackSelectionSnapshot: Equatable {
    let normalizedTitle: String?
    let normalizedLanguageCode: String?
    let normalizedCodec: String?
    let normalizedAudioLayout: String?
    let isForced: Bool
    let isExternal: Bool
    let isHearingImpaired: Bool

    init(track: PlayerTrack) {
        normalizedTitle = track.normalizedTitle?.lowercased()
        normalizedLanguageCode = track.normalizedLanguageCode?.lowercased()
        normalizedCodec = Self.normalized(track.codec)
        normalizedAudioLayout = Self.normalized(track.audioChannelsLayout)
        isForced = track.isForced
        isExternal = track.isExternal
        isHearingImpaired = track.isHearingImpaired
    }

    /// How well `track` matches the snapshotted attributes, or `0` when it is
    /// not a candidate at all. Two rules make the result safe to restore from:
    ///
    /// 1. **Absent metadata never scores.** `nil == nil` is not agreement, it
    ///    is two tracks that both said nothing — which is true of every row in
    ///    a sparsely described replacement list.
    /// 2. **A positive anchor is required**: the same language, the same
    ///    title, or the same codec *and* channel layout. Without one, the
    ///    three boolean flags on their own reached `bestTrackMatch`'s `>= 3`
    ///    floor (they are `false` on most tracks), so "English AC3 5.1
    ///    Director" restored onto "French AAC stereo Other". Language (3) and
    ///    title (4) each clear that floor by themselves; the flags (1 each)
    ///    never do, because an unanchored candidate scores nothing at all.
    func score(against track: PlayerTrack) -> Int {
        let titleMatches = Self.agree(normalizedTitle, track.normalizedTitle?.lowercased())
        let languageMatches = Self.agree(
            normalizedLanguageCode,
            track.normalizedLanguageCode?.lowercased()
        )
        let codecMatches = Self.agree(normalizedCodec, Self.normalized(track.codec))
        let layoutMatches = Self.agree(
            normalizedAudioLayout,
            Self.normalized(track.audioChannelsLayout)
        )
        guard titleMatches || languageMatches || (codecMatches && layoutMatches) else {
            return 0
        }

        var score = 0
        if titleMatches { score += 4 }
        if languageMatches { score += 3 }
        if codecMatches { score += 2 }
        if layoutMatches { score += 2 }
        if isForced == track.isForced { score += 1 }
        if isExternal == track.isExternal { score += 1 }
        if isHearingImpaired == track.isHearingImpaired { score += 1 }
        return score
    }

    /// Two normalized attributes agree only when both are present and equal.
    private static func agree(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs
    }

    private static func normalized(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// Who decided the current subtitle selection. `origin == .user` is the latch
/// the auto-resolver, the appearance funnels and the sidecar restores yield to.
/// Every non-user decider (a server plan, the system/server caption policy, a
/// carried-across rebuild) is interchangeable everywhere that gate is applied,
/// so they share one case.
enum SelectionOrigin: Equatable {
    /// An explicit pick: the user's, or a caller-supplied index that stands in
    /// for one (a detail-screen/route argument, a resumed explicit choice).
    case user
    /// Anything else decided it.
    case automatic
}

/// Which audio track a load or a rebuild is still trying to land on.
///
/// Both fields can be armed at once, in the order the track-list funnel runs
/// them: a route recovery seeds the plan index *and* the pre-rebuild snapshot,
/// and the snapshot is what lands when the exact index is gone from the
/// replacement stream. A funnel consumes a field by setting it back to nil.
struct AudioSelection: Equatable {
    /// The plan's / request's audio selection index, matched against
    /// `ApplePlaybackRoutePlanner.audioSelectionIndex(for:)`. It is named in
    /// that index space, not in ffmpeg's — `audioSelectionIndex(for:)` is
    /// `srcId ?? ffIndex`, i.e. the audio-array ordinal for server-described
    /// tracks and the stream index only as a fallback.
    var planIndex: Int?
    /// The pre-rebuild track's attributes, fuzzy-matched against the
    /// replacement list.
    var recovered: TrackSelectionSnapshot?

    /// Nothing armed: whatever the engine reports selected stands.
    static let unset = AudioSelection()
}

/// Which subtitle a load or a rebuild is still trying to land on.
///
/// One field per index space: an embedded stream is named by its ffmpeg stream
/// index, a sidecar row by the synthesized track id over the server's
/// *combined* ordinal (`SubtitleTrackIdSpace.sidecarBase`), and the two are
/// never the same number. No decision site names a subtitle by a bare `srcId`
/// int, because that int does not say which space it is in.
///
/// Several fields can be armed at once, in the order the two apply funnels run
/// them: the embedded field is consumed by the track-list funnel, the sidecar
/// and server-rendered fields by the sidecar-append funnel, and the fuzzy
/// field by whichever of the two matches it first. A load that resumes a
/// sidecar pick arms "embedded off" *and* "restore this sidecar", so the
/// container default is switched off before the sidecar rows arrive. A funnel
/// consumes a field by setting it back to nil.
struct SubtitleSelection: Equatable {
    /// What the embedded plane is waiting for.
    enum EmbeddedRung: Equatable {
        /// Explicit "Off": the embedded plane must end up with no track
        /// selected. This is the `-1` sentinel the load request and the resume
        /// resolvers carry on the wire.
        case off
        /// An embedded stream, by ffmpeg stream index.
        case stream(ffIndex: Int)

        /// Wire index → rung. `nil` arms nothing, a negative value is the
        /// explicit "Off" sentinel, and index 0 is a real stream.
        static func wireIndex(_ ffIndex: Int?) -> EmbeddedRung? {
            ffIndex.map { $0 < 0 ? .off : .stream(ffIndex: $0) }
        }
    }

    var embedded: EmbeddedRung?
    /// A sidecar row the client opens locally, by synthesized track id.
    var sidecarTrackId: Int64?
    /// A sidecar row the server renders into the stream: the picker keeps the
    /// row selected, nothing is opened locally.
    var serverRenderedTrackId: Int64?
    /// The pre-rebuild track's attributes, fuzzy-matched against whatever the
    /// replacement stream publishes (embedded rows first, then sidecar rows).
    var recovered: TrackSelectionSnapshot?

    /// Nothing armed on any plane.
    static let unset = SubtitleSelection()
}

extension SubtitleSelection {
    /// The subtitle the server's V3 plan selected, named in the space the
    /// plan's `subtitle.mode` puts it in: a `render` plan hands the client a
    /// sidecar to open locally, a `burn_in` plan renders it into the stream and
    /// leaves the client only the picker row, and anything else (`off`, absent)
    /// selects nothing.
    static func planned(selectedSubtitleIndex: Int?, subtitleMode: String?) -> SubtitleSelection {
        // A negative plan index is not a sidecar ordinal (the id space masks it
        // into a meaningless value); the legacy comparison never matched one
        // either, so it selects nothing rather than a mis-masked sidecar.
        guard let selectedSubtitleIndex, selectedSubtitleIndex >= 0 else { return .unset }
        let trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: selectedSubtitleIndex)
        switch subtitleMode {
        case "render":
            return SubtitleSelection(sidecarTrackId: trackId)
        case "burn_in":
            return SubtitleSelection(serverRenderedTrackId: trackId)
        default:
            return .unset
        }
    }

    /// Re-establish the subtitle selection the caller snapshotted before the
    /// server replaced the plan. Sidecar ids are stable (urlIndex-derived) and
    /// restore by id; a server-rendered choice is latched separately so the
    /// track list doesn't fight the server. A snapshot that is not the sidecar
    /// the replacement plan selected yields `.unset` — the adopted plan's own
    /// intent stands — and an AI-live or embedded selection is intentionally
    /// never restored through this path.
    static func sidecarRestore(
        snapshot: Int64?,
        selectedSubtitleIndex: Int?,
        subtitleMode: String?
    ) -> SubtitleSelection {
        guard let snapshot,
              SubtitleTrackIdSpace.isSidecar(snapshot),
              SubtitleTrackIdSpace.sidecarIndex(from: snapshot) == selectedSubtitleIndex else {
            return .unset
        }
        return planned(selectedSubtitleIndex: selectedSubtitleIndex, subtitleMode: subtitleMode)
    }

    /// Drop the sidecar URLs the active route must not register.
    ///
    /// A route that extracts embedded subtitle streams itself would publish the
    /// same subtitle twice if the server also delivered it as a sidecar; the
    /// one exception is the embedded subtitle the plan selected and asked the
    /// client to render, which reaches the player only as a sidecar artifact.
    ///
    /// The second rule is about what the client can *draw*: there is no bitmap
    /// sidecar renderer on Apple, so a `.sup`/VobSub sidecar is only ever a
    /// picker row the server burns in after a replan. Without a live V3 plan
    /// there is no replan to make, so registering it could only produce a
    /// checked-but-blank track — it is dropped instead of shown.
    static func subtitleUrlsForCurrentRoute(
        _ urls: [SubtitleUrl],
        routeUsesEmbeddedExtraction: Bool,
        protocolV3PlanActive: Bool,
        planned: SubtitleSelection
    ) -> [SubtitleUrl] {
        let selectedRenderedSidecarIndex = planned.sidecarTrackId
            .flatMap(SubtitleTrackIdSpace.sidecarIndex(from:))
        return urls.filter { subtitle in
            let isEmbeddedSource =
                subtitle.source?.localizedCaseInsensitiveCompare("embedded") == .orderedSame
            if routeUsesEmbeddedExtraction, isEmbeddedSource {
                // This route renders embedded tracks natively (loopback/native
                // bitmap tap or text extractor), so the server's
                // embedded-source sidecars are redundant — drop them. The one
                // exception is a text sidecar the plan explicitly rendered
                // server-side, kept so a user's chosen server-rendered copy
                // survives the route.
                //
                // A bitmap (PGS/DVD/DVB) embedded sidecar is never kept, even
                // when planned: the text sidecar path cannot draw a `.sup`, and
                // keeping it shadowed the natively-renderable embedded row and
                // stranded the picker on an unrenderable sidecar (blank
                // subtitles on loopback).
                return subtitle.index == selectedRenderedSidecarIndex && !subtitle.isBitmapCodec
            }
            // A bitmap sidecar the client cannot draw is worth a row only while
            // a V3 plan is live: selecting it there replans and the server
            // burns it into the stream.
            if subtitle.isBitmapCodec { return protocolV3PlanActive }
            return true
        }
    }

    /// True for a bitmap subtitle codec (PGS/DVD/DVB/XSUB). The single owner of
    /// the "no Apple renderer can draw this" predicate; `SubtitleUrl` and every
    /// track/descriptor test goes through here.
    static func isBitmapCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return codec.contains("pgs") || codec.contains("hdmv")
            || codec.contains("dvdsub") || codec.contains("dvd_sub")
            || codec.contains("dvbsub") || codec.contains("dvb_sub")
            || codec.contains("xsub")
    }
}

/// The player's whole track intent: what audio, primary subtitle and secondary
/// subtitle this load or rebuild is trying to land on, and who decided it.
///
/// One value instead of a bag of `pending*` optionals plus an explicit-choice
/// flag. Each axis holds the fields still waiting for a matching track to
/// appear; the two apply funnels consume the field they own and leave the
/// rest.
struct TrackSelection: Equatable {
    var audio: AudioSelection = .unset
    var primary: SubtitleSelection = .unset
    var secondary: SubtitleSelection = .unset
    /// `origin == .user` is the latch every automatic subtitle decision yields
    /// to.
    var origin: SelectionOrigin = .automatic

    /// Arm the V3 plan's authoritative track intent over the adopted request.
    ///
    /// The plan is authoritative for the tracks actually rendered, so this runs
    /// before the new source publishes a track list — container defaults and
    /// the post-open Auto resolver must not drift away from the selection the
    /// server will preserve through replans and renewals. A plan that does not
    /// render subtitles locally arms the explicit "Off" sentinel and no
    /// sidecar. `origin` is deliberately untouched: adopting a plan never
    /// converts an automatic choice into a user's, and never demotes the
    /// user's.
    mutating func armAdoptedProtocolV3Intent(plan: PlaybackV3Plan, request: LoadRequest) {
        let rendersSubtitleLocally = plan.subtitle.mode == "render"
        audio.planIndex = request.preferredAudioTrackIndex
        primary.embedded = .wireIndex(
            rendersSubtitleLocally ? request.preferredSubtitleTrackIndex : -1
        )
        primary.sidecarTrackId = rendersSubtitleLocally
            ? request.preferredSidecarSubtitleTrackId
            : nil
    }
}
