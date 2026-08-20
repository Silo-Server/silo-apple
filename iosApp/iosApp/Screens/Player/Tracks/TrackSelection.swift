import Foundation

/// Attribute snapshot of a track that has to survive a backend rebuild.
///
/// Track ids are not stable across a stream swap (a quality switch, a route
/// fallback, a transcode restart), so a selection that cannot be re-established
/// by id is re-established by scoring the replacement list against these
/// normalized attributes. Moved here from `TrackSelectionCoordinator` unchanged
/// — `score(against:)`'s weights and `bestTrackMatch`'s `>= 3` threshold are
/// the ones that were there before.
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

    func score(against track: PlayerTrack) -> Int {
        var score = 0
        if normalizedTitle == track.normalizedTitle?.lowercased() { score += 4 }
        if normalizedLanguageCode == track.normalizedLanguageCode?.lowercased() { score += 3 }
        if normalizedCodec == Self.normalized(track.codec) { score += 2 }
        if normalizedAudioLayout == Self.normalized(track.audioChannelsLayout) { score += 2 }
        if isForced == track.isForced { score += 1 }
        if isExternal == track.isExternal { score += 1 }
        if isHearingImpaired == track.isHearingImpaired { score += 1 }
        return score
    }

    private static func normalized(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// Who decided the current subtitle selection. Only `.user` is read as a
/// behaviour gate — it is the latch the auto-resolver, the appearance funnels
/// and the sidecar restores yield to — `origin == .user` is what the retired
/// explicit-subtitle-choice flag meant (review §8). The other three cases
/// record which non-user decider was last, and are deliberately
/// interchangeable everywhere that gate is applied.
enum SelectionOrigin: Equatable {
    /// An explicit pick: the user's, or a caller-supplied index that stands in
    /// for one (a detail-screen/route argument, a resumed explicit choice).
    case user
    /// The server's V3 plan is the authority for this selection.
    case serverPlan
    /// The system-caption or server subtitle policy resolved it.
    case autoPolicy
    /// Carried across a backend rebuild from the pre-rebuild selection.
    case recovered
}

/// Which audio track a load or a rebuild is still trying to land on.
///
/// Cases name the index space they arrived in, so the untyped `Int?` this
/// replaced cannot be confused with an ffmpeg stream index
/// (`ApplePlaybackRoutePlanner.audioSelectionIndex(for:)` is `srcId ?? ffIndex`,
/// i.e. the audio-array ordinal for server-described tracks and the stream
/// index only as a fallback).
enum AudioSelection: Equatable {
    /// Nothing armed: whatever the engine reports selected stands.
    case unset
    /// The plan's / request's audio selection index, matched against
    /// `ApplePlaybackRoutePlanner.audioSelectionIndex(for:)`.
    case planIndex(Int)
    /// The pre-rebuild track's attributes, fuzzy-matched against the
    /// replacement list.
    case recovered(TrackSelectionSnapshot)
    /// Both rungs armed at once, in the order the track-list funnel runs them:
    /// a route recovery seeds the plan index *and* restores the snapshot, and
    /// the snapshot is what lands when the exact index is gone from the
    /// replacement stream. Never nested and never holds two rungs of the same
    /// kind — every value is built through the setters below.
    case ladder([AudioSelection])
}

extension AudioSelection {
    /// The armed rungs in ladder order. A single-rung value is a one-element
    /// list; `.unset` is empty.
    var rungs: [AudioSelection] {
        switch self {
        case .unset: return []
        case .ladder(let rungs): return rungs
        default: return [self]
        }
    }

    /// The plan-index rung, if armed.
    var planIndex: Int? {
        for rung in rungs {
            if case .planIndex(let index) = rung { return index }
        }
        return nil
    }

    /// The fuzzy-restore rung, if armed.
    var recoveredSnapshot: TrackSelectionSnapshot? {
        for rung in rungs {
            if case .recovered(let snapshot) = rung { return snapshot }
        }
        return nil
    }

    /// Arm (or, with `nil`, disarm) the plan-index rung, leaving the other one
    /// alone. Disarming is how a rung is consumed once it has been applied.
    func settingPlanIndex(_ index: Int?) -> AudioSelection {
        Self.make(planIndex: index, recovered: recoveredSnapshot)
    }

    /// Arm (or, with `nil`, disarm) the fuzzy-restore rung.
    func settingRecovered(_ snapshot: TrackSelectionSnapshot?) -> AudioSelection {
        Self.make(planIndex: planIndex, recovered: snapshot)
    }

    private static func make(
        planIndex: Int?,
        recovered: TrackSelectionSnapshot?
    ) -> AudioSelection {
        var rungs: [AudioSelection] = []
        if let planIndex { rungs.append(.planIndex(planIndex)) }
        if let recovered { rungs.append(.recovered(recovered)) }
        switch rungs.count {
        case 0: return .unset
        case 1: return rungs[0]
        default: return .ladder(rungs)
        }
    }
}

/// Which subtitle a load or a rebuild is still trying to land on.
///
/// One case per index space (review §8): an embedded stream is named by its
/// ffmpeg stream index, a sidecar row by the synthesized track id over the
/// server's *combined* ordinal (`SubtitleTrackIdSpace.sidecarBase`), and the
/// two are never the same number. That is what retires the bare `srcId` int
/// from every decision site.
enum SubtitleSelection: Equatable {
    /// Nothing armed on this axis.
    case unset
    /// Explicit "Off": the embedded plane must end up with no track selected.
    /// This is the `-1` sentinel the load request and the resume resolvers
    /// carry on the wire.
    case off
    /// An embedded stream, by ffmpeg stream index.
    case embedded(ffIndex: Int)
    /// A sidecar row the client opens locally, by synthesized track id.
    case sidecar(trackId: Int64)
    /// A sidecar row the server renders into the stream: the picker keeps the
    /// row selected, nothing is opened locally.
    case serverRendered(trackId: Int64)
    /// The pre-rebuild track's attributes, fuzzy-matched against whatever the
    /// replacement stream publishes (embedded rows first, then sidecar rows).
    case recovered(TrackSelectionSnapshot)
    /// Several rungs armed at once, in the order the two apply funnels run
    /// them: the embedded rung is consumed by the track-list funnel, the
    /// sidecar and server-rendered rungs by the sidecar-append funnel, and the
    /// fuzzy rung by whichever of the two matches it first. A load that resumes
    /// a sidecar pick arms "embedded off" *and* "restore this sidecar", so the
    /// container default is switched off before the sidecar rows arrive. Never
    /// nested and never holds two rungs of the same kind — every value is built
    /// through the setters below.
    case ladder([SubtitleSelection])
}

extension SubtitleSelection {
    /// The armed rungs in ladder order. A single-rung value is a one-element
    /// list; `.unset` is empty.
    var rungs: [SubtitleSelection] {
        switch self {
        case .unset: return []
        case .ladder(let rungs): return rungs
        default: return [self]
        }
    }

    /// The embedded-plane rung (`.off` or `.embedded`), if armed.
    var embeddedRung: SubtitleSelection? {
        rungs.first { rung in
            switch rung {
            case .off, .embedded: return true
            default: return false
            }
        }
    }

    /// The locally-opened sidecar rung's track id, if armed.
    var sidecarTrackId: Int64? {
        for rung in rungs {
            if case .sidecar(let trackId) = rung { return trackId }
        }
        return nil
    }

    /// The server-rendered sidecar rung's track id, if armed.
    var serverRenderedTrackId: Int64? {
        for rung in rungs {
            if case .serverRendered(let trackId) = rung { return trackId }
        }
        return nil
    }

    /// The fuzzy-restore rung, if armed.
    var recoveredSnapshot: TrackSelectionSnapshot? {
        for rung in rungs {
            if case .recovered(let snapshot) = rung { return snapshot }
        }
        return nil
    }

    /// Arm (or, with `nil`, disarm) the embedded-plane rung, leaving the other
    /// planes alone. A negative index is the explicit "Off" sentinel.
    /// Disarming is how a rung is consumed once it has been applied.
    func settingEmbedded(ffIndex: Int?) -> SubtitleSelection {
        let rung: SubtitleSelection? = ffIndex.map { $0 < 0 ? .off : .embedded(ffIndex: $0) }
        return Self.make(
            embedded: rung,
            sidecar: sidecarTrackId,
            serverRendered: serverRenderedTrackId,
            recovered: recoveredSnapshot
        )
    }

    /// Arm (or, with `nil`, disarm) the locally-opened sidecar rung.
    func settingSidecar(trackId: Int64?) -> SubtitleSelection {
        Self.make(
            embedded: embeddedRung,
            sidecar: trackId,
            serverRendered: serverRenderedTrackId,
            recovered: recoveredSnapshot
        )
    }

    /// Arm (or, with `nil`, disarm) the server-rendered sidecar rung.
    func settingServerRendered(trackId: Int64?) -> SubtitleSelection {
        Self.make(
            embedded: embeddedRung,
            sidecar: sidecarTrackId,
            serverRendered: trackId,
            recovered: recoveredSnapshot
        )
    }

    /// Arm (or, with `nil`, disarm) the fuzzy-restore rung.
    func settingRecovered(_ snapshot: TrackSelectionSnapshot?) -> SubtitleSelection {
        Self.make(
            embedded: embeddedRung,
            sidecar: sidecarTrackId,
            serverRendered: serverRenderedTrackId,
            recovered: snapshot
        )
    }

    private static func make(
        embedded: SubtitleSelection?,
        sidecar: Int64?,
        serverRendered: Int64?,
        recovered: TrackSelectionSnapshot?
    ) -> SubtitleSelection {
        var rungs: [SubtitleSelection] = []
        if let embedded { rungs.append(embedded) }
        if let sidecar { rungs.append(.sidecar(trackId: sidecar)) }
        if let serverRendered { rungs.append(.serverRendered(trackId: serverRendered)) }
        if let recovered { rungs.append(.recovered(recovered)) }
        switch rungs.count {
        case 0: return .unset
        case 1: return rungs[0]
        default: return .ladder(rungs)
        }
    }
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
            return .sidecar(trackId: trackId)
        case "burn_in":
            return .serverRendered(trackId: trackId)
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
    static func subtitleUrlsForCurrentRoute(
        _ urls: [SubtitleUrl],
        routeUsesEmbeddedExtraction: Bool,
        planned: SubtitleSelection
    ) -> [SubtitleUrl] {
        guard routeUsesEmbeddedExtraction else { return urls }
        let selectedRenderedSidecarIndex: Int? = {
            guard case .sidecar(let trackId) = planned else { return nil }
            return SubtitleTrackIdSpace.sidecarIndex(from: trackId)
        }()
        return urls.filter { subtitle in
            subtitle.source?.localizedCaseInsensitiveCompare("embedded") != .orderedSame
                || subtitle.index == selectedRenderedSidecarIndex
        }
    }
}

/// The player's whole track intent: what audio, primary subtitle and secondary
/// subtitle this load or rebuild is trying to land on, and who decided it.
///
/// Replaces the eight `pending*` optionals plus the explicit-choice flag
/// (review §8). Each axis holds the rungs still waiting for a matching track to
/// appear; the two apply funnels consume the rung they own and leave the rest,
/// which is exactly what the separate optionals did.
struct TrackSelection: Equatable {
    var audio: AudioSelection = .unset
    var primary: SubtitleSelection = .unset
    var secondary: SubtitleSelection = .unset
    /// `origin == .user` is the latch every automatic subtitle decision yields
    /// to.
    var origin: SelectionOrigin = .autoPolicy

    /// Arm the V3 plan's authoritative track intent over the adopted request.
    ///
    /// The plan is authoritative for the tracks actually rendered, so this runs
    /// before the new source publishes a track list — container defaults and
    /// the post-open Auto resolver must not drift away from the selection the
    /// server will preserve through replans and renewals. A plan that does not
    /// render subtitles locally arms the explicit "Off" sentinel and no
    /// sidecar. Adopting a plan never converts an automatic choice into a
    /// user's, and never demotes the user's.
    mutating func armAdoptedProtocolV3Intent(plan: PlaybackV3Plan, request: LoadRequest) {
        let rendersSubtitleLocally = plan.subtitle.mode == "render"
        audio = audio.settingPlanIndex(request.preferredAudioTrackIndex)
        primary = primary
            .settingEmbedded(ffIndex: rendersSubtitleLocally ? request.preferredSubtitleTrackIndex : -1)
            .settingSidecar(trackId: rendersSubtitleLocally ? request.preferredSidecarSubtitleTrackId : nil)
        if origin != .user { origin = .serverPlan }
    }
}
