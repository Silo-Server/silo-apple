//
//  PlaybackPrefsStore.swift
//  Silo (iOS + tvOS)
//
//  In-memory cache of the user's per-library playback preferences,
//  hydrated lazily on first access and refreshed when the Settings UI
//  mutates a row. The settings UI is the only consumer that needs the
//  full list — playback time reads `effective_*` straight off the
//  WatchDetail response, so this store doesn't need to participate in
//  the hot path.
//
//  Per-series subtitle / audio overrides are not cached: they're
//  fetched on demand by the player (when the user picks "Remember for
//  this series") and re-fetched from `WatchDetail.effective_*` on the
//  next playback, so caching them here would just duplicate authority.
//

import Foundation

@MainActor
final class PlaybackPrefsStore: ObservableObject {

    static let shared = PlaybackPrefsStore()

    @Published private(set) var libraryPrefs: [Int: LibraryPlaybackPref] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private var hasHydrated = false

    /// Fetch the full set if we haven't yet. Idempotent — repeated
    /// calls within the same session no-op unless `refresh()` was
    /// called explicitly.
    func hydrateIfNeeded() async {
        guard !hasHydrated, !isLoading else { return }
        await refresh()
    }

    /// Force a re-fetch. Settings UI calls this after a successful PUT
    /// or DELETE so the local copy reflects what the server now holds.
    func refresh() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let prefs = try await SiloAPI.shared.libraryPlaybackPrefs()
            var byId: [Int: LibraryPlaybackPref] = [:]
            for p in prefs { byId[p.libraryId] = p }
            libraryPrefs = byId
            hasHydrated = true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }

    /// Look up the cached pref row for a library. Returns nil if the
    /// user hasn't configured anything for that library yet — caller
    /// should treat that as "use the profile default".
    func pref(forLibrary libraryId: Int) -> LibraryPlaybackPref? {
        libraryPrefs[libraryId]
    }

    /// PUT to the server, then refresh local cache. Throws on network
    /// / HTTP failure so the UI can surface a toast or retry control.
    func setPref(
        libraryId: Int,
        audioLanguage: String?,
        subtitleLanguage: String?,
        subtitleMode: String?,
        showForcedSubtitles: Bool?
    ) async throws {
        try await SiloAPI.shared.setLibraryPlaybackPref(
            libraryId: libraryId,
            audioLanguage: audioLanguage,
            subtitleLanguage: subtitleLanguage,
            subtitleMode: subtitleMode,
            showForcedSubtitles: showForcedSubtitles
        )
        await refresh()
    }

    func deletePref(libraryId: Int) async throws {
        try await SiloAPI.shared.deleteLibraryPlaybackPref(libraryId: libraryId)
        await refresh()
    }

    /// Drop in-memory state. Called on sign-out so the next user
    /// doesn't see the previous user's prefs flash onto the screen
    /// before the fresh fetch lands.
    func clear() {
        libraryPrefs = [:]
        lastError = nil
        hasHydrated = false
    }
}
