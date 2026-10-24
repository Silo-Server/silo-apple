//  Persists the user's explicit audio / subtitle track choices to the
//  server's per-series preference endpoints so they survive exiting
//  the player and revisiting the item — matching the web app. The web
//  player PUTs `/subtitle-prefs/{key}` on every subtitle change and
//  relies on its audio-change PATCH to persist audio server-side;
//  Apple's track switches are engine-local (no wire call), so both
//  kinds are written here explicitly.
//
//  Key semantics mirror the web's `seriesContext?.seriesId ?? contentId`:
//  episodes persist under their series id (one choice applies to the
//  whole series), movies under their own content id — which is exactly
//  the key the server's detail resolver reads movie prefs back from.
//
//  Writes go to `/api/v2/{audio,subtitle}-prefs/{key}` and are
//  best-effort: a failed PUT costs the user a remembered preference,
//  never playback. These explicit writes are the only way a pick
//  persists; automatic selections never call them. The server folds
//  saved prefs into `WatchDetail.effective_*` /
//  `FileVersion.effectiveAudioTrackIndex`; `SiloAPI.watchDetail` passes
//  `settlePendingWrites` first so a read right after a pick (Next Up,
//  the detail page) neither races the write nor loses it.
//

import Foundation
import os
import Synchronization

enum TrackSelectionPersistence {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "TrackPrefs"
    )

    /// Server pref key: the series id for episodes, the item's own
    /// content id otherwise. Nil when neither is known (e.g. offline
    /// playback with no server-backed identity).
    static func prefKey(seriesId: String?, contentId: String?) -> String? {
        if let seriesId, !seriesId.isEmpty { return seriesId }
        if let contentId, !contentId.isEmpty { return contentId }
        return nil
    }

    // MARK: - Request builders (pure)

    /// Audio pick against server file metadata. `ordinal` indexes
    /// `version.audioTracks` — the same space the server's
    /// `audio_track_index` uses. Building the signature from the
    /// server's own probed fields guarantees an exact match when the
    /// preference is re-resolved.
    static func audioRequest(version: FileVersion, ordinal: Int) -> AudioPrefRequest? {
        guard let tracks = version.audioTracks, tracks.indices.contains(ordinal) else {
            return nil
        }
        let track = tracks[ordinal]
        return AudioPrefRequest(
            audioTrackIndex: ordinal,
            audioLanguage: track.language ?? "",
            trackSignature: AudioTrackSignature(
                language: track.language,
                title: track.title,
                embeddedTitle: track.embeddedTitle,
                codec: track.codec,
                layout: track.channelLayout,
                channels: track.channels,
                isDefault: track.isDefault ?? false
            )
        )
    }

    /// Audio pick from a live player track, for selections the watch
    /// detail can't describe (recovered tracks, ordinal unknown). The
    /// server matches signature first and treats a negative index as
    /// "no index" — language and signature still apply.
    static func audioRequest(track: PlayerTrack, ordinal: Int?) -> AudioPrefRequest {
        AudioPrefRequest(
            audioTrackIndex: ordinal ?? -1,
            audioLanguage: track.normalizedLanguageCode ?? "",
            trackSignature: AudioTrackSignature(
                language: track.normalizedLanguageCode,
                title: track.normalizedTitle,
                embeddedTitle: track.normalizedTitle,
                codec: track.codec,
                channels: track.audioChannelCount,
                isDefault: track.isDefault
            )
        )
    }

    // Ordinary picks never carry `show_forced_subtitles`. The server stores a
    // present member as a deliberate per-series forced-subtitle override that
    // outranks the profile toggle, so echoing the resolved value from the
    // watch detail would pin it on every pick (silo-apple#870). The builders
    // take no forced argument so no caller can pass an inherited value.

    /// Subtitle pick against server file metadata. `ffIndex` matches
    /// `version.subtitleTracks[].selectionIndex` (an embedded track with no
    /// wire index is stream 0); a negative value is the detail page's
    /// explicit "Off".
    static func subtitleRequest(version: FileVersion, ffIndex: Int) -> SubtitlePrefRequest? {
        if ffIndex < 0 {
            return subtitleOffRequest()
        }
        guard let track = version.subtitleTracks?.first(where: { $0.selectionIndex == ffIndex }) else {
            return nil
        }
        let isExternal = track.external ?? false
        return SubtitlePrefRequest(
            subtitleLanguage: track.language ?? "",
            subtitleTrackIndex: ffIndex,
            externalSubtitlePath: isExternal ? (track.externalPath ?? "") : "",
            subtitleMode: SubtitleMode.always.rawValue,
            trackSignature: SubtitleTrackSignature(
                source: isExternal ? "external" : "embedded",
                language: track.language,
                codec: track.codec,
                label: track.title ?? track.embeddedTitle,
                forced: track.forced ?? false,
                hearingImpaired: track.hearingImpaired ?? false
            )
        )
    }

    /// Subtitle pick from a live player track (sidecar / downloaded /
    /// embedded rows the watch detail can't describe).
    static func subtitleRequest(track: PlayerTrack) -> SubtitlePrefRequest {
        SubtitlePrefRequest(
            subtitleLanguage: track.normalizedLanguageCode ?? "",
            subtitleTrackIndex: track.ffIndex ?? -1,
            externalSubtitlePath: "",
            subtitleMode: SubtitleMode.always.rawValue,
            trackSignature: SubtitleTrackSignature(
                source: track.isExternal ? "external" : "embedded",
                language: track.normalizedLanguageCode,
                codec: track.codec,
                label: track.normalizedTitle,
                forced: track.isForced,
                hearingImpaired: track.isHearingImpaired
            )
        )
    }

    /// Explicit "subtitles off" — same payload the web writes for a
    /// null selection: empty language, index -1, mode "off".
    static func subtitleOffRequest() -> SubtitlePrefRequest {
        SubtitlePrefRequest(
            subtitleLanguage: "",
            subtitleTrackIndex: -1,
            externalSubtitlePath: "",
            subtitleMode: SubtitleMode.off.rawValue,
            trackSignature: nil
        )
    }

    // MARK: - Fire-and-forget writers

    // Each writer captures the signed-in owner when it is dispatched and the
    // v2 client sends the write only while that owner is still current, so a
    // pick made under one profile never lands on another. Writes for the same
    // kind and key run one at a time in dispatch order, so a pick followed by
    // "Auto" cannot be overtaken by the earlier PUT and leave a stale
    // override; a write still queued when a newer one arrives is skipped,
    // because the newer one names the state the viewer wants. The writes are
    // `natural_idempotent`, but a failed or unanswered write is logged and
    // not retried: the next explicit pick sends a fresh one. Until then, for
    // up to `failedPickLifetime`, reads under the same owner carry it (see
    // `settlePendingWrites`).

    @discardableResult
    static func saveAudio(prefKey: String, request: AudioPrefRequest,
                          client: APIv2Client = SiloAPI.shared.apiV2Client,
                          tokenStore: TokenStore = .shared) -> Task<Void, Never> {
        dispatch("audio pref save", kind: .audio, prefKey: prefKey, intent: .audio(request),
                 tokenStore: tokenStore) { auth in
            try await client.writeTrackPreference(kind: .audio, seriesId: prefKey, body: request, auth: auth)
        }
    }

    @discardableResult
    static func saveSubtitle(prefKey: String, request: SubtitlePrefRequest,
                             client: APIv2Client = SiloAPI.shared.apiV2Client,
                             tokenStore: TokenStore = .shared) -> Task<Void, Never> {
        dispatch("subtitle pref save", kind: .subtitle, prefKey: prefKey, intent: .subtitle(request),
                 tokenStore: tokenStore) { auth in
            try await client.writeTrackPreference(kind: .subtitle, seriesId: prefKey, body: request, auth: auth)
        }
    }

    /// The detail selectors' "Auto" choice — remove the sticky override
    /// so the library/profile cascade applies again. The server answers
    /// 204 whether or not an override existed.
    @discardableResult
    static func clearAudio(prefKey: String,
                           client: APIv2Client = SiloAPI.shared.apiV2Client,
                           tokenStore: TokenStore = .shared) -> Task<Void, Never> {
        dispatch("audio pref clear", kind: .audio, prefKey: prefKey, intent: .cleared,
                 tokenStore: tokenStore) { auth in
            try await client.deleteTrackPreference(kind: .audio, seriesId: prefKey, auth: auth)
        }
    }

    @discardableResult
    static func clearSubtitle(prefKey: String,
                              client: APIv2Client = SiloAPI.shared.apiV2Client,
                              tokenStore: TokenStore = .shared) -> Task<Void, Never> {
        dispatch("subtitle pref clear", kind: .subtitle, prefKey: prefKey, intent: .cleared,
                 tokenStore: tokenStore) { auth in
            try await client.deleteTrackPreference(kind: .subtitle, seriesId: prefKey, auth: auth)
        }
    }

    private static let pendingWrites = PendingWrites()

    private static func dispatch(
        _ action: String,
        kind: TrackPreferenceKind,
        prefKey: String,
        intent: Intent,
        tokenStore: TokenStore,
        operation: @escaping @Sendable (CapturedOrdinaryRequestAuth) async throws -> Void
    ) -> Task<Void, Never> {
        let pending = pendingWrites
        // The owner the pick was made under, read now rather than when the
        // write's task first runs: a profile switch or a new remote-playback
        // scope in between must not send the pick under the next owner.
        let pickedBy = tokenStore.ownerSnapshot
        return pending.enqueue(.init(kind: kind, prefKey: prefKey), profile: pickedBy.profileId, intent: intent) { write, previous in
            let owner = writeOwner(captured: await tokenStore.captureOrdinaryRequestAuth(), pickedBy: pickedBy)
            pending.bind(write, owner: owner)
            await previous?.value
            guard pending.isLatest(write) else { return }
            do {
                guard let owner else { throw HTTPError.requestIdentityChanged }
                try await operation(owner)
                pending.finish(write, stored: true)
            } catch {
                pending.finish(write, stored: false)
                logger.warning(
                    "\(action, privacy: .public) failed key=\(prefKey, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// The owner a write goes out under: the one captured for it, provided
    /// it is exactly the owner the pick was made under (same credentials,
    /// remote-playback scope included, and same profile).
    static func writeOwner(
        captured: CapturedOrdinaryRequestAuth?,
        pickedBy: CredentialOwnerSnapshot
    ) -> CapturedOrdinaryRequestAuth? {
        guard let captured, pickedBy.matches(captured) else { return nil }
        return captured
    }

    // MARK: - Pending-write barrier

    /// What the newest write for one kind and key asks the server to store.
    enum Intent: Sendable {
        case audio(AudioPrefRequest)
        case subtitle(SubtitlePrefRequest)
        /// "Auto": remove the series override.
        case cleared
    }

    /// How long a read waits for in-flight writes to its key before it goes
    /// ahead and carries their intent instead.
    static let pendingWriteWait: Duration = .milliseconds(2500)

    /// How long a failed pick is carried into reads. After that the server's
    /// state wins again, so a choice made since on another device is not
    /// overridden indefinitely. Matches Android's queued-write expiry.
    static let failedPickLifetime: Duration = .seconds(600)

    /// Taken before a read is sent: which writes had already been stored.
    struct ReadMark: Sendable {
        fileprivate let storedThrough: UInt64
    }

    /// The writes a read of `prefKey` could not see stored.
    struct Settlement: Sendable {
        /// A write to the key was stored after the read's mark, so a response
        /// fetched since the mark may predate it and must be read again.
        let rereads: Bool
        /// Latest intent per kind that has not been stored: still in flight
        /// after the wait, or failed within `failedPickLifetime`.
        let unsettled: [TrackPreferenceKind: Intent]

        /// `detail` with every unsettled pick folded into the server-resolved
        /// fields that detail selectors and playback start read. An unsettled
        /// "Auto" cannot be folded in: the profile defaults it falls back to
        /// are only resolved by the server. Nor can a subtitle track picked
        /// without a language unless its title identifies it: the start's
        /// resolver finds a subtitle by its language or title, and in mode
        /// `always` an unidentified pick falls back to whichever track ranks
        /// first. The server's state stands for those.
        func applied(to detail: WatchDetail) -> WatchDetail {
            var detail = detail
            if case .subtitle(let request)? = unsettled[.subtitle] {
                let language = TrackSelectionPersistence.taggedLanguage(request.subtitleLanguage)
                if language != nil || request.subtitleMode == SubtitleMode.off.rawValue
                    || TrackSelectionPersistence.identifiesUntaggedSubtitle(request, on: detail.versions) {
                    detail.effectiveSubtitleLanguage = language
                    detail.effectiveSubtitleMode = request.subtitleMode
                    // An undefined language (`und`) in the signature would
                    // score as a language match for any other `und` track.
                    detail.effectiveSubtitleTrackSignature = request.trackSignature.map { signature in
                        SubtitleTrackSignature(
                            source: signature.source,
                            language: TrackSelectionPersistence.taggedLanguage(signature.language),
                            codec: signature.codec,
                            label: signature.label,
                            forced: signature.forced,
                            hearingImpaired: signature.hearingImpaired
                        )
                    }
                }
            }
            if case .audio(let request)? = unsettled[.audio] {
                detail.versions = detail.versions.map { version in
                    guard let ordinal = TrackSelectionPersistence.audioOrdinal(matching: request, in: version) else {
                        return version
                    }
                    var version = version
                    version.effectiveAudioTrackIndex = ordinal
                    // The matched track's own language, nil included: the
                    // start judges Auto subtitles by the audio's language.
                    version.effectiveAudioLanguage = version.audioTracks?[ordinal].language
                    return version
                }
            }
            return detail
        }
    }

    /// Mark taken before a read of server track state is sent, for
    /// `settlePendingWrites`. A write stored after it may or may not be in
    /// the read's response.
    static func pendingWriteMark() -> ReadMark {
        pendingWrites.mark()
    }

    /// The barrier a read of server track state passes before it trusts the
    /// response. Waits up to `timeout` for this owner's in-flight writes to
    /// `prefKey` (returning early if the caller is cancelled), then reports
    /// whether one was stored after `mark`, so the response must be read
    /// again, and what is still not stored, so the caller can carry it
    /// rather than block on it. Writes under another owner are neither
    /// waited on nor reported.
    static func settlePendingWrites(
        prefKey: String,
        owner: CapturedOrdinaryRequestAuth,
        since mark: ReadMark,
        timeout: Duration = pendingWriteWait,
        now: ContinuousClock.Instant = .now
    ) async -> Settlement {
        let inFlight = pendingWrites.inFlightTasks(prefKey: prefKey, owner: owner)
        if !inFlight.isEmpty, timeout > .zero {
            await waitForAll(inFlight, timeout: timeout)
        }
        let unsettled = pendingWrites.unsettled(
            prefKey: prefKey, owner: owner, failedSince: now - failedPickLifetime
        )
        for kind in unsettled.keys {
            logger.info(
                "carrying unsaved \(kind.rawValue, privacy: .public) pref key=\(prefKey, privacy: .public)"
            )
        }
        return Settlement(
            rereads: pendingWrites.storedAfter(mark, prefKey: prefKey),
            unsettled: unsettled
        )
    }

    /// A watch-detail read made safe against track writes for its item.
    /// Marks before each GET; after the first it waits (bounded) for this
    /// owner's in-flight writes, after a later one it only looks. It reads
    /// again while a write was stored after the GET's mark, at most
    /// `maxReads` GETs in all, and folds the picks still unsaved as of the
    /// last GET, so a newer pick is carried and a pick the response already
    /// reflects is not.
    static func settledRead(
        owner: CapturedOrdinaryRequestAuth,
        maxReads: Int = 3,
        wait: Duration = pendingWriteWait,
        read: () async throws -> WatchDetail
    ) async throws -> WatchDetail {
        var reads = 0
        while true {
            let mark = pendingWriteMark()
            let detail = try await read()
            reads += 1
            guard let prefKey = prefKey(seriesId: detail.seriesId, contentId: detail.contentId) else {
                return detail
            }
            let settlement = await settlePendingWrites(
                prefKey: prefKey, owner: owner, since: mark, timeout: reads == 1 ? wait : .zero
            )
            if !settlement.rereads || reads >= maxReads {
                return settlement.applied(to: detail)
            }
        }
    }

    /// A language code that names a language: nil for empty and `und`.
    fileprivate static func taggedLanguage(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty,
              code.lowercased() != "und" else { return nil }
        return code
    }

    /// Whether an untagged subtitle pick's title finds it on every version:
    /// the start's resolver (`SubtitleAutoResolver.bestSignatureMatch`)
    /// identifies a track without a language only by a title containing the
    /// signature's label, so exactly one track may carry it, and that track
    /// must be untagged.
    fileprivate static func identifiesUntaggedSubtitle(_ request: SubtitlePrefRequest, on versions: [FileVersion]) -> Bool {
        guard let label = request.trackSignature?.label, !label.isEmpty, !versions.isEmpty else { return false }
        return versions.allSatisfy { version in
            let titled = SubtitleTrackCandidates.playerTracks(from: version.subtitleTracks ?? [])
                .filter { $0.title?.localizedCaseInsensitiveContains(label) == true }
            return titled.count == 1 && taggedLanguage(titled[0].lang) == nil
        }
    }

    /// The ordinal in `version.audioTracks` an audio pick names on another
    /// file of the series. A pick in a language matches the track with its
    /// signature, then its own ordinal when that track has the language,
    /// then the first track in the language; languages compare by meaning,
    /// so `en` finds `eng`. An untagged pick matches only an untagged track
    /// with the same codec, channels, layout and titles. Nil leaves the
    /// server's choice alone.
    static func audioOrdinal(matching request: AudioPrefRequest, in version: FileVersion) -> Int? {
        let tracks = version.audioTracks ?? []
        func same(_ lhs: String?, _ rhs: String?) -> Bool {
            let normalize = { (value: String?) in value?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" }
            return normalize(lhs) == normalize(rhs)
        }
        func inLanguage(_ track: AudioTrack, _ language: String) -> Bool {
            taggedLanguage(track.language).map { SubtitleAutoResolver.languagesMatch($0, language) } ?? false
        }
        // The signature's two titles are compared separately: tracks that
        // differ only in their embedded title ("Main audio" / "Commentary")
        // are different picks. A player-built signature carries one title in
        // both fields, so each may match either of the track's titles.
        func matchesTitle(_ track: AudioTrack, _ title: String?) -> Bool {
            title == nil || same(track.title, title) || same(track.embeddedTitle, title)
        }
        func matchesDetails(_ track: AudioTrack, _ signature: AudioTrackSignature) -> Bool {
            (signature.codec == nil || same(track.codec, signature.codec))
                && (signature.channels == nil || track.channels == signature.channels)
                && (signature.layout == nil || same(track.channelLayout, signature.layout))
                && matchesTitle(track, signature.title)
                && matchesTitle(track, signature.embeddedTitle)
        }
        // Among tracks that all match, the picked ordinal wins (the same file,
        // or one laid out alike), then the one whose default flag agrees.
        // The flag only breaks ties: the server's own match ignores it.
        func best(_ signature: AudioTrackSignature, where matches: (AudioTrack) -> Bool) -> Int? {
            let candidates = tracks.indices.filter { matches(tracks[$0]) && matchesDetails(tracks[$0], signature) }
            if candidates.contains(request.audioTrackIndex) { return request.audioTrackIndex }
            return candidates.first { (tracks[$0].isDefault ?? false) == signature.isDefault } ?? candidates.first
        }
        guard let language = taggedLanguage(request.audioLanguage) else {
            guard let signature = request.trackSignature,
                  signature.codec != nil || signature.channels != nil || signature.layout != nil
                    || signature.title != nil || signature.embeddedTitle != nil else { return nil }
            return best(signature) { taggedLanguage($0.language) == nil }
        }
        if let signature = request.trackSignature,
           let ordinal = best(signature, where: { inLanguage($0, language) }) {
            return ordinal
        }
        if tracks.indices.contains(request.audioTrackIndex),
           inLanguage(tracks[request.audioTrackIndex], language) {
            return request.audioTrackIndex
        }
        return tracks.firstIndex { inLanguage($0, language) }
    }

    /// Returns when every task has finished, `timeout` has passed, or the
    /// calling task is cancelled, whichever comes first. The tasks keep
    /// running either way.
    private static func waitForAll(_ tasks: [Task<Void, Never>], timeout: Duration) async {
        let gate = OneShot()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.fire()
        }
        let waiter = Task {
            for task in tasks { await task.value }
            gate.fire()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.install($0) }
        } onCancel: {
            gate.fire()
        }
        timer.cancel()
        waiter.cancel()
    }

    /// Resumes one continuation once, whether it fires before or after the
    /// continuation is installed.
    private final class OneShot: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Never>?
            var fired = false
        }

        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<Void, Never>) {
            let firedAlready = state.withLock { state -> Bool in
                if state.fired { return true }
                state.continuation = continuation
                return false
            }
            if firedAlready { continuation.resume() }
        }

        func fire() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard !state.fired else { return nil }
                state.fired = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }
    }

    /// The latest write per profile, kind and key. Writes for one kind and
    /// key run one at a time in dispatch order, whoever made them: each
    /// starts only after the one dispatched before it has finished, whatever
    /// its outcome, and callers dispatch synchronously, so dispatch order is
    /// pick order. The latest intent is kept per profile, so one profile's
    /// pick never replaces or skips another's. An entry is bound to the owner
    /// its write captured and leaves once that write is stored. A failed one
    /// stays until a newer write from that profile replaces it, and reads
    /// under that owner carry it for `failedPickLifetime`. Each store also
    /// bumps a sequence number, which read marks compare against.
    private final class PendingWrites: Sendable {
        struct Slot: Hashable {
            let kind: TrackPreferenceKind
            let prefKey: String
        }

        /// A slot for the profile a pick was made under.
        struct OwnedSlot: Hashable {
            let slot: Slot
            let profile: String?
        }

        struct WriteID: Sendable {
            let owned: OwnedSlot
            let id: UInt64
        }

        private struct Entry {
            let id: UInt64
            let intent: Intent
            let task: Task<Void, Never>
            /// Nil until the write has captured its owner; `.some(nil)` when
            /// it has none to go out under.
            var owner: CapturedOrdinaryRequestAuth??
            var failedAt: ContinuousClock.Instant?

            func belongs(to reader: CapturedOrdinaryRequestAuth, includingUnbound: Bool) -> Bool {
                switch owner {
                case .none: includingUnbound
                case .some(.none): false
                case .some(.some(let owner)): owner.sameCredentialIdentity(as: reader)
                }
            }
        }

        private struct State {
            var latest: [OwnedSlot: Entry] = [:]
            /// The last write dispatched for each kind and key, which the
            /// next one waits for.
            var tails: [Slot: (id: UInt64, task: Task<Void, Never>)] = [:]
            var nextId: UInt64 = 0
            var storeSequence: UInt64 = 0
            /// The store sequence of each slot's last stored write.
            var lastStored: [Slot: UInt64] = [:]
        }

        private let state = Mutex(State())

        func enqueue(
            _ slot: Slot,
            profile: String?,
            intent: Intent,
            _ body: @escaping @Sendable (_ write: WriteID, _ previous: Task<Void, Never>?) async -> Void
        ) -> Task<Void, Never> {
            state.withLock { state -> Task<Void, Never> in
                state.nextId += 1
                let write = WriteID(owned: OwnedSlot(slot: slot, profile: profile), id: state.nextId)
                let previous = state.tails[slot]?.task
                let task = Task {
                    await body(write, previous)
                    self.releaseTail(slot, write.id)
                }
                state.tails[slot] = (write.id, task)
                state.latest[write.owned] = Entry(id: write.id, intent: intent, task: task)
                return task
            }
        }

        func bind(_ write: WriteID, owner: CapturedOrdinaryRequestAuth?) {
            state.withLock { state in
                guard state.latest[write.owned]?.id == write.id else { return }
                state.latest[write.owned]?.owner = .some(owner)
            }
        }

        func isLatest(_ write: WriteID) -> Bool {
            state.withLock { $0.latest[write.owned]?.id == write.id }
        }

        func finish(_ write: WriteID, stored: Bool) {
            state.withLock { state in
                if stored {
                    state.storeSequence += 1
                    state.lastStored[write.owned.slot] = state.storeSequence
                }
                guard state.latest[write.owned]?.id == write.id else { return }
                if stored {
                    state.latest[write.owned] = nil
                } else {
                    state.latest[write.owned]?.failedAt = .now
                }
            }
        }

        func mark() -> ReadMark {
            state.withLock { ReadMark(storedThrough: $0.storeSequence) }
        }

        func storedAfter(_ mark: ReadMark, prefKey: String) -> Bool {
            state.withLock { state in
                Self.slots(prefKey).contains { (state.lastStored[$0] ?? 0) > mark.storedThrough }
            }
        }

        func inFlightTasks(prefKey: String, owner: CapturedOrdinaryRequestAuth) -> [Task<Void, Never>] {
            state.withLock { state in
                Self.entries(state, prefKey: prefKey).compactMap { owned, entry in
                    guard entry.failedAt == nil,
                          entry.belongs(to: owner, includingUnbound: owned.profile == owner.profileId)
                    else { return nil }
                    return entry.task
                }
            }
        }

        func unsettled(
            prefKey: String,
            owner: CapturedOrdinaryRequestAuth,
            failedSince cutoff: ContinuousClock.Instant
        ) -> [TrackPreferenceKind: Intent] {
            state.withLock { state in
                var result: [TrackPreferenceKind: (id: UInt64, intent: Intent)] = [:]
                for (owned, entry) in Self.entries(state, prefKey: prefKey) {
                    guard entry.belongs(to: owner, includingUnbound: false) else { continue }
                    if let failedAt = entry.failedAt, failedAt < cutoff { continue }
                    // One owner's newest pick wins if a temporary scope and
                    // the persistent selection both wrote for it.
                    if let kept = result[owned.slot.kind], kept.id > entry.id { continue }
                    result[owned.slot.kind] = (entry.id, entry.intent)
                }
                return result.mapValues { $0.intent }
            }
        }

        private func releaseTail(_ slot: Slot, _ id: UInt64) {
            state.withLock { state in
                if state.tails[slot]?.id == id { state.tails[slot] = nil }
            }
        }

        private static func entries(_ state: State, prefKey: String) -> [(OwnedSlot, Entry)] {
            state.latest.filter { $0.key.slot.prefKey == prefKey }.map { ($0.key, $0.value) }
        }

        private static func slots(_ prefKey: String) -> [Slot] {
            [Slot(kind: .audio, prefKey: prefKey), Slot(kind: .subtitle, prefKey: prefKey)]
        }
    }
}
