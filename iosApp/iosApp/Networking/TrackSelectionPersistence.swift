//
//  TrackSelectionPersistence.swift
//  Continuum (iOS + tvOS)
//
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
//  Writes are best-effort fire-and-forget: a failed PUT costs the user
//  a remembered preference, never playback. Reads never happen here —
//  the server folds saved prefs into `WatchDetail.effective_*` /
//  `FileVersion.effectiveAudioTrackIndex`, which the detail page and
//  player already consume.
//

import Foundation
import os

enum TrackSelectionPersistence {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
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

    /// Subtitle pick against server file metadata. `ffIndex` matches
    /// `version.subtitleTracks[].index`; a negative value is the detail
    /// page's explicit "Off".
    static func subtitleRequest(
        version: FileVersion,
        ffIndex: Int,
        showForced: Bool?
    ) -> SubtitlePrefRequest? {
        if ffIndex < 0 {
            return subtitleOffRequest(showForced: showForced)
        }
        guard let track = version.subtitleTracks?.first(where: { $0.index == ffIndex }) else {
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
            ),
            showForcedSubtitles: showForced
        )
    }

    /// Subtitle pick from a live player track (sidecar / downloaded /
    /// embedded rows the watch detail can't describe).
    static func subtitleRequest(track: PlayerTrack, showForced: Bool?) -> SubtitlePrefRequest {
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
            ),
            showForcedSubtitles: showForced
        )
    }

    /// Explicit "subtitles off" — same payload the web writes for a
    /// null selection: empty language, index -1, mode "off".
    static func subtitleOffRequest(showForced: Bool?) -> SubtitlePrefRequest {
        SubtitlePrefRequest(
            subtitleLanguage: "",
            subtitleTrackIndex: -1,
            externalSubtitlePath: "",
            subtitleMode: SubtitleMode.off.rawValue,
            trackSignature: nil,
            showForcedSubtitles: showForced
        )
    }

    // MARK: - Fire-and-forget writers

    static func saveAudio(prefKey: String, request: AudioPrefRequest) {
        Task {
            do {
                try await ContinuumAPI.shared.setAudioPref(seriesId: prefKey, body: request)
            } catch {
                logger.warning(
                    "audio pref save failed key=\(prefKey, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    static func saveSubtitle(prefKey: String, request: SubtitlePrefRequest) {
        Task {
            do {
                try await ContinuumAPI.shared.setSubtitlePref(seriesId: prefKey, body: request)
            } catch {
                logger.warning(
                    "subtitle pref save failed key=\(prefKey, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// The detail selectors' "Auto" choice — remove the sticky override
    /// so the library/profile cascade applies again. A 404 just means
    /// no override existed.
    static func clearAudio(prefKey: String) {
        Task {
            do {
                try await ContinuumAPI.shared.deleteAudioPref(seriesId: prefKey)
            } catch HTTPError.http(let code, _) where code == 404 {
                // Nothing to clear.
            } catch {
                logger.warning(
                    "audio pref clear failed key=\(prefKey, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    static func clearSubtitle(prefKey: String) {
        Task {
            do {
                try await ContinuumAPI.shared.deleteSubtitlePref(seriesId: prefKey)
            } catch HTTPError.http(let code, _) where code == 404 {
                // Nothing to clear.
            } catch {
                logger.warning(
                    "subtitle pref clear failed key=\(prefKey, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
