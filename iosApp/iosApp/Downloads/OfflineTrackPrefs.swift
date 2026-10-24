import Foundation

/// The per-series audio and subtitle preferences downloaded playback reads
/// and writes, kept in the scope's `DownloadStoreFile` so they work offline.
///
/// For each kind the store keeps the server row as this device last saw it
/// apart from the deliberate picks still waiting to reach the server. A
/// pending pick wins over the observed row when playback reads, and a read
/// from the server never replaces a pending pick.
///
/// A pick is sent only if the server has not been given a newer choice in
/// the meantime. The flush reads the row first: unchanged since the pick was
/// made (same `updated_at`, or still absent) sends it. Otherwise the pick
/// time, moved onto the server's clock by the offset the read's `Date`
/// header shows, must be later than the row's `updated_at`. The write is a
/// plain upsert, so a change landing between that read and the write is
/// still overwritten.
struct TrackPrefsStore: Codable, Equatable, Sendable {
    var audio = TrackPrefLedger<AudioPrefRequest>()
    var subtitle = TrackPrefLedger<SubtitlePrefRequest>()
    /// The subtitle cascade (`WatchDetail.effective_subtitle_*`) last seen
    /// streaming, per key with a download: what applies without a series row.
    var effectiveSubtitle: [String: EffectiveSubtitlePrefs] = [:]

    var hasPending: Bool { !audio.pending.isEmpty || !subtitle.pending.isEmpty }

    /// The series audio row downloaded playback starts with, pending or observed.
    func audioPref(forKey key: String) -> AudioPrefRequest? {
        audio.current(key) ?? nil
    }

    /// The subtitle preference downloaded playback starts with: a series row
    /// (pending or observed) over the last cascade seen. An empty member of
    /// the row means no preference at that level, as on the server.
    func subtitlePrefs(forKey key: String) -> EffectiveSubtitlePrefs? {
        let inherited = effectiveSubtitle[key]
        guard case .some(.some(let row)) = subtitle.current(key) else { return inherited }
        return EffectiveSubtitlePrefs(
            language: row.subtitleLanguage.isEmpty ? inherited?.language : row.subtitleLanguage,
            mode: row.subtitleMode.isEmpty ? inherited?.mode : row.subtitleMode,
            showForced: row.showForcedSubtitles ?? inherited?.showForced,
            signature: row.trackSignature
        )
    }
}

struct EffectiveSubtitlePrefs: Codable, Equatable, Sendable {
    var language: String?
    var mode: String?
    var showForced: Bool?
    var signature: SubtitleTrackSignature?
}

extension EffectiveSubtitlePrefs {
    init(_ detail: WatchDetail) {
        self.init(language: detail.effectiveSubtitleLanguage, mode: detail.effectiveSubtitleMode,
                  showForced: detail.effectiveShowForcedSubtitles, signature: detail.effectiveSubtitleTrackSignature)
    }
}

/// The server row for one key as this device last saw it.
struct ObservedTrackPref<Body: TrackPrefBody>: Codable, Equatable, Sendable {
    /// Nil when the key has no row (a 404, or a clear this device sent).
    var body: Body?
    /// The row's server time. Nil when this device wrote the row and has not
    /// read it back.
    var updatedAt: Date?
}

extension ObservedTrackPref {
    /// What a read returned; nil is the 404 for a key with no row.
    init(_ row: TrackPrefRow<Body>?) {
        self.init(body: row?.body, updatedAt: row?.updatedAt)
    }
}

/// A deliberate pick waiting to reach the server.
struct PendingTrackPref<Body: TrackPrefBody>: Codable, Equatable, Sendable {
    /// What the device knew of the server row when the pick was made.
    enum Baseline: Codable, Equatable, Sendable {
        case unknown
        case absent
        case updatedAt(Date)
    }

    var id = UUID()
    /// Nil clears the series row (Auto).
    var body: Body?
    var pickedAt: Date
    var baseline: Baseline
}

struct TrackPrefLedger<Body: TrackPrefBody>: Codable, Equatable, Sendable {
    var observed: [String: ObservedTrackPref<Body>] = [:]
    var pending: [String: PendingTrackPref<Body>] = [:]

    /// The row playback should use: nil when nothing is known, `.some(nil)`
    /// when the key has no row.
    func current(_ key: String) -> Body?? {
        if let pick = pending[key] { return .some(pick.body) }
        return observed[key].map(\.body)
    }

    /// Queues a pick, replacing any earlier one for the key.
    @discardableResult
    mutating func record(_ body: Body?, key: String, at time: Date) -> PendingTrackPref<Body> {
        let baseline: PendingTrackPref<Body>.Baseline =
            if let seen = observed[key]?.updatedAt { .updatedAt(seen) }
            else if let row = observed[key], row.body == nil { .absent }
            else { .unknown }
        let pick = PendingTrackPref(body: body, pickedAt: time, baseline: baseline)
        pending[key] = pick
        return pick
    }

    /// Records a write this device sent outside the queue. It supersedes
    /// any pick still queued for the key.
    mutating func wrote(_ body: Body?, key: String) {
        pending[key] = nil
        observed[key] = ObservedTrackPref(body: body)
    }

    /// Ends `pick` once the server has it. A newer pick for the key stays.
    mutating func acknowledge(_ pick: PendingTrackPref<Body>, key: String) {
        guard pending[key]?.id == pick.id else { return }
        pending[key] = nil
        observed[key] = ObservedTrackPref(body: pick.body)
    }

    /// Ends `pick` without sending it: the server row is newer.
    mutating func discard(_ pick: PendingTrackPref<Body>, key: String) {
        guard pending[key]?.id == pick.id else { return }
        pending[key] = nil
    }

    /// Whether `pick` should overwrite `row`, read from the server at
    /// `serverDate` (its `Date` header) when this device's clock read `readAt`.
    static func shouldSend(_ pick: PendingTrackPref<Body>, over row: TrackPrefRow<Body>?,
                           serverDate: Date?, readAt: Date) -> Bool {
        // No row: still absent, or cleared at a time the read can't tell,
        // and a deliberate pick is the more specific choice.
        guard let row else { return true }
        if case .updatedAt(let seen) = pick.baseline, seen == row.updatedAt { return true }
        let offset = serverDate.map { $0.timeIntervalSince(readAt) } ?? 0
        return pick.pickedAt.addingTimeInterval(offset) > row.updatedAt
    }
}

enum OfflineTrackPrefs {
    /// The series-pref key for a download, as streaming keys it: the parent
    /// series for an episode (specials included), the item itself otherwise.
    /// Nil for an episode whose series is unknown: its own id is never a key.
    /// `recordSeriesId` is the download record's, for a manifest without one.
    static func prefKey(manifest: OfflineManifest, recordSeriesId: String?) -> String? {
        let seriesId = [manifest.seriesId, recordSeriesId].compactMap { $0 }.first { !$0.isEmpty }
        if manifest.episodeId != nil { return seriesId }
        return TrackSelectionPersistence.prefKey(seriesId: seriesId, contentId: manifest.contentId)
    }

    // MARK: - Audio selection

    /// The manifest audio ordinal downloaded playback starts with: the
    /// server's `SelectAudioTrack` series steps over the delivered file's
    /// tracks, then the track the server chose when the download was made
    /// (its profile-language and file-default steps).
    ///
    /// `sourceOrdinals` says the manifest list is the source file's, in
    /// order (an original download), so the saved index means the same
    /// track. A prepared file's list is filtered and reordered.
    static func audioOrdinal(tracks: [OfflineAudioTrack], pref: AudioPrefRequest?,
                             sourceOrdinals: Bool, fallback: Int?) -> Int? {
        guard let pref, !tracks.isEmpty else { return fallback }
        if let signature = pref.trackSignature,
           let match = bestLanguageTrack(tracks.indices.filter { matches(tracks[$0], signature) },
                                         in: tracks, language: signature.language ?? "") {
            return match
        }
        if sourceOrdinals, tracks.indices.contains(pref.audioTrackIndex),
           languageRank(tracks[pref.audioTrackIndex].language, pref.audioLanguage) != nil {
            return pref.audioTrackIndex
        }
        return bestLanguageTrack(Array(tracks.indices), in: tracks, language: pref.audioLanguage) ?? fallback
    }

    /// The manifest folds a track's title and embedded title into `title`,
    /// so the signature's are folded the same way before comparing.
    private static func matches(_ track: OfflineAudioTrack, _ signature: AudioTrackSignature) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            (a ?? "").trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare((b ?? "").trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
        let title = [signature.title, signature.embeddedTitle].compactMap { $0 }.first { !$0.isEmpty }
        return languageRank(track.language, signature.language ?? "") != nil
            && same(track.title, title) && same(track.codec, signature.codec)
            && same(track.layout, signature.layout) && (track.channels ?? 0) == (signature.channels ?? 0)
    }

    private static func bestLanguageTrack(_ candidates: [Int], in tracks: [OfflineAudioTrack],
                                          language: String) -> Int? {
        candidates
            .compactMap { index in languageRank(tracks[index].language, language).map { (index, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    /// The server's language ranking: an exact tag, then a bare language,
    /// then another variant of it. Nil when either side has no language.
    private static func languageRank(_ candidate: String?, _ preferred: String) -> Int? {
        guard let candidate else { return nil }
        let have = PlaybackLanguageOption.languageIdentity(candidate.trimmingCharacters(in: .whitespaces))
        let want = PlaybackLanguageOption.languageIdentity(preferred.trimmingCharacters(in: .whitespaces))
        guard !["", "und"].contains(have), !["", "und"].contains(want),
              SubtitleAutoResolver.languagesMatch(have, want) else { return nil }
        if have == want { return 0 }
        return have.contains("-") ? 2 : 1
    }

    // MARK: - Picks during downloaded playback

    /// An audio pick against the manifest track at `ordinal`. Only an
    /// original download's ordinal is the source index the server stores; a
    /// prepared file's sends -1, which the server's selection skips. The
    /// manifest folds the two titles, so no signature is sent.
    static func audioRequest(tracks: [AudioTrack], ordinal: Int, sourceOrdinals: Bool) -> AudioPrefRequest? {
        guard tracks.indices.contains(ordinal) else { return nil }
        return AudioPrefRequest(
            audioTrackIndex: sourceOrdinals ? ordinal : -1,
            audioLanguage: tracks[ordinal].language ?? "",
            trackSignature: nil
        )
    }

    /// A subtitle pick from the local file or one of its sidecars. Neither
    /// index is the source's, and the probed or sidecar metadata may differ
    /// from the server's, so it sends the language and flags only.
    static func subtitleRequest(track: PlayerTrack) -> SubtitlePrefRequest {
        let language = track.normalizedLanguageCode
        return SubtitlePrefRequest(
            subtitleLanguage: language ?? "",
            subtitleTrackIndex: -1,
            externalSubtitlePath: "",
            subtitleMode: SubtitleMode.always.rawValue,
            trackSignature: SubtitleTrackSignature(
                language: language,
                forced: track.isForced,
                hearingImpaired: track.isHearingImpaired
            ),
            showForcedSubtitles: nil
        )
    }
}
