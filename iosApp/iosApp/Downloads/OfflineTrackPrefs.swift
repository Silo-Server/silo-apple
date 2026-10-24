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
/// header shows, must be later than the row's `updated_at`. A row this
/// device wrote itself never counts as a newer choice. The write is a plain
/// upsert, so a change landing between that read and the write is still
/// overwritten.
struct TrackPrefsStore: Codable, Equatable, Sendable {
    var audio = TrackPrefLedger<AudioPrefRequest>()
    var subtitle = TrackPrefLedger<SubtitlePrefRequest>()
    /// The subtitle cascade (`WatchDetail.effective_subtitle_*`) last seen
    /// streaming, per key with a download: what applies without a series row.
    /// It may include the series row's own choices, so it is dropped when
    /// the row is cleared, until streaming shows the cascade again.
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

    // The ledger changes the store makes, each dropping the cascade along
    // with a series subtitle row it clears.

    /// Queues a pick made during downloaded playback.
    @discardableResult
    mutating func record<Body>(_ body: Body?, key: String, in ledger: WritableKeyPath<Self, TrackPrefLedger<Body>>,
                               at time: Date) -> PendingTrackPref<Body> {
        if body == nil { clearedRow(Body.self, key: key) }
        return self[keyPath: ledger].record(body, key: key, at: time)
    }

    /// Ends `pick` once the server has it. `serverDate` is the response's
    /// `Date` header.
    mutating func acknowledge<Body>(_ pick: PendingTrackPref<Body>, key: String,
                                    in ledger: WritableKeyPath<Self, TrackPrefLedger<Body>>, serverDate: Date?) {
        self[keyPath: ledger].acknowledge(pick, key: key, serverDate: serverDate)
        if pick.body == nil { clearedRow(Body.self, key: key) }
    }

    /// Records a write this device sent outside the queue at `sentAt`,
    /// stored or not. `serverDate` is the response's `Date` header.
    mutating func wrote<Body>(_ body: Body?, key: String, in ledger: WritableKeyPath<Self, TrackPrefLedger<Body>>,
                              sentAt: Date, stored: Bool, serverDate: Date?) {
        self[keyPath: ledger].wrote(body, key: key, sentAt: sentAt, stored: stored, serverDate: serverDate)
        if stored, body == nil { clearedRow(Body.self, key: key) }
    }

    /// Records what a read of the server row found, unless the key changed
    /// since `revision` was taken as the read began.
    mutating func observe<Body>(_ row: TrackPrefRow<Body>?, key: String,
                                in ledger: WritableKeyPath<Self, TrackPrefLedger<Body>>,
                                since revision: TrackPrefLedger<Body>.Revision) {
        let hadRow = self[keyPath: ledger].observed[key]?.body != nil
        guard self[keyPath: ledger].observe(row, key: key, since: revision) else { return }
        if hadRow, row == nil { clearedRow(Body.self, key: key) }
    }

    private mutating func clearedRow<Body: TrackPrefBody>(_: Body.Type, key: String) {
        if Body.kind == .subtitle { effectiveSubtitle[key] = nil }
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
    /// For a row this device wrote: a server time the write is stamped
    /// before (its response's `Date` header, plus the header's one-second
    /// resolution).
    var writtenBefore: Date?
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
        /// The row was this device's own write, stamped before this server
        /// time.
        case ownWrite(stampedBefore: Date)
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
        if let pick = pending[key] { return .some(pick.body.map { $0.applied(over: observed[key]?.body) }) }
        return observed[key].map(\.body)
    }

    /// What a read of a key must find unchanged to be applied: a write
    /// stored or a pick queued after the read began makes its answer stale.
    struct Revision: Equatable {
        fileprivate let observed: ObservedTrackPref<Body>?
        fileprivate let pick: UUID?
    }

    func revision(_ key: String) -> Revision {
        Revision(observed: observed[key], pick: pending[key]?.id)
    }

    /// Records what a read found; false when it was stale.
    fileprivate mutating func observe(_ row: TrackPrefRow<Body>?, key: String, since revision: Revision) -> Bool {
        guard self.revision(key) == revision else { return false }
        observed[key] = ObservedTrackPref(row)
        return true
    }

    /// Queues a pick, replacing any earlier one for the key.
    @discardableResult
    fileprivate mutating func record(_ body: Body?, key: String, at time: Date) -> PendingTrackPref<Body> {
        let pick = PendingTrackPref(body: body, pickedAt: time, baseline: baseline(key))
        pending[key] = pick
        return pick
    }

    private func baseline(_ key: String) -> PendingTrackPref<Body>.Baseline {
        guard let row = observed[key] else { return .unknown }
        if let seen = row.updatedAt { return .updatedAt(seen) }
        if let bound = row.writtenBefore { return .ownWrite(stampedBefore: bound) }
        return row.body == nil ? .absent : .unknown
    }

    /// Ends `pick` once the server has it. A newer pick for the key stays,
    /// rebased onto this write.
    fileprivate mutating func acknowledge(_ pick: PendingTrackPref<Body>, key: String, serverDate: Date?) {
        stored(pick.body, key: key, serverDate: serverDate) { $0.id == pick.id }
    }

    /// Records a write this device sent outside the queue at `sentAt`. It
    /// supersedes the picks made before it was sent, stored or not; a later
    /// pick stays, rebased onto the write once it is stored.
    fileprivate mutating func wrote(_ body: Body?, key: String, sentAt: Date, stored: Bool, serverDate: Date?) {
        let superseded = { (pick: PendingTrackPref<Body>) in pick.pickedAt <= sentAt }
        if stored {
            self.stored(body, key: key, serverDate: serverDate, ending: superseded)
        } else if let pick = pending[key], superseded(pick) {
            pending[key] = nil
        }
    }

    /// The server stored `body` from this device. A queued pick `ending`
    /// selects is done; a newer one must not take this write for a newer
    /// choice made elsewhere, so it is rebased onto it.
    private mutating func stored(_ body: Body?, key: String, serverDate: Date?,
                                 ending: (PendingTrackPref<Body>) -> Bool) {
        observed[key] = ObservedTrackPref(body: body.map { $0.applied(over: observed[key]?.body) },
                                          writtenBefore: serverDate?.addingTimeInterval(1))
        guard let pick = pending[key] else { return }
        if ending(pick) {
            pending[key] = nil
        } else {
            let rebased = baseline(key)
            pending[key]?.baseline = rebased
        }
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
        switch pick.baseline {
        case .updatedAt(let seen) where seen == row.updatedAt: return true
        case .ownWrite(let bound) where row.updatedAt < bound: return true
        default: break
        }
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
    ///
    /// Like the server, every step skips tracks no decoder can play while
    /// the file has one that can.
    static func audioOrdinal(tracks: [OfflineAudioTrack], pref: AudioPrefRequest?,
                             sourceOrdinals: Bool, fallback: Int?) -> Int? {
        guard let pref, !tracks.isEmpty else { return fallback }
        let decodable = tracks.indices.filter { isDecodable(tracks[$0]) }
        let candidates = decodable.isEmpty ? Array(tracks.indices) : decodable
        if let signature = pref.trackSignature,
           let match = soleBestLanguageTrack(candidates.filter { matches(tracks[$0], signature) },
                                             in: tracks, language: signature.language ?? "") {
            return match
        }
        if sourceOrdinals, candidates.contains(pref.audioTrackIndex),
           languageRank(tracks[pref.audioTrackIndex].language, pref.audioLanguage) != nil {
            return pref.audioTrackIndex
        }
        return bestLanguageTrack(candidates, in: tracks, language: pref.audioLanguage) ?? fallback
    }

    /// The server's `AudioTrackDecodable` without the file-level codec,
    /// which the manifest doesn't carry: ffprobe names no codec, or
    /// `unknown`, for a stream FFmpeg can't decode. When no track names a
    /// codec, every track fails here and the caller keeps them all, as the
    /// server does when every track gets the same verdict.
    private static func isDecodable(_ track: OfflineAudioTrack) -> Bool {
        let codec = (track.codec ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return !codec.isEmpty && codec != "unknown"
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

    /// The best language match among signature matches, or nil when two
    /// share the best rank. Folding the titles can make the saved track and
    /// another one look the same (title `English`, embedded titles `Main`
    /// and `Commentary`); the saved index or language decides then.
    private static func soleBestLanguageTrack(_ candidates: [Int], in tracks: [OfflineAudioTrack],
                                              language: String) -> Int? {
        let ranked = candidates.compactMap { index in languageRank(tracks[index].language, language).map { (index, $0) } }
        guard let best = ranked.map(\.1).min() else { return nil }
        let top = ranked.filter { $0.1 == best }
        return top.count == 1 ? top[0].0 : nil
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

    /// An audio pick against the track the player shows at `ordinal`. The
    /// probe's ordinal names a manifest track only when both list the same
    /// tracks; otherwise (an older download without the list) the pick
    /// carries the played track's language alone.
    static func audioRequest(track: PlayerTrack, ordinal: Int?, shownTrackCount: Int,
                             manifestTracks: [AudioTrack]?, sourceOrdinals: Bool) -> AudioPrefRequest? {
        if let ordinal, let manifestTracks, manifestTracks.count == shownTrackCount {
            return audioRequest(tracks: manifestTracks, ordinal: ordinal, sourceOrdinals: sourceOrdinals)
        }
        guard let language = track.normalizedLanguageCode else { return nil }
        return AudioPrefRequest(audioTrackIndex: -1, audioLanguage: language, trackSignature: nil)
    }

    /// Whether the server refused a pick for good. Kept queued, it would
    /// hold up the picks behind it; an auth, timeout or rate-limit answer
    /// can pass later.
    static func isRefusedForGood(_ error: Error) -> Bool {
        let status: Int
        switch error {
        case APIv2Error.problem(let problem): status = problem.status
        case APIv2Error.httpStatus(let code): status = code
        default: return false
        }
        return (400..<500).contains(status) && ![401, 408, 425, 429].contains(status)
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
