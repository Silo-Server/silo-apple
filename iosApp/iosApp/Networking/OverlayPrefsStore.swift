//
//  OverlayPrefsStore.swift
//  Continuum (iOS + tvOS)
//
//  Cached card-overlay configuration for the signed-in profile.
//  Resolves a single rendered `CardOverlayPrefs` from one of two
//  sources, in this priority:
//    1. The user's saved prefs — the contract key `ui.card_overlays`
//       at profile scope, read through the canonical
//       `GET /settings/values/effective` endpoint. If present, this is
//       the entire source of truth.
//    2. Otherwise, the admin-configured baseline JSON from
//       `GET /settings/overlay-config` (`defaults` field).
//    3. Otherwise, registry defaults (`OverlaySchema.buildDefaults()`).
//
//  The contract stores the document as a JSON object (jsonb), not the
//  JSON string the retired legacy endpoint carried, so reads and
//  writes bridge between `SettingJSONValue` and `OverlaySchema`'s
//  string codec here. Servers that predate the canonical settings API
//  are detected via `SettingsAPIError.serverUpgradeRequired` and fall
//  back to the legacy `card_overlays` user setting, which those
//  servers still accept.
//
//  This is winner-take-all, not layered merging — `setPrefs(_:)`
//  always saves a full document (not a diff), and the matching
//  behavior in the web's `useOverlayPrefs.ts` hook keeps the wire
//  format compatible across clients. Hydrated lazily on first read
//  and refreshed after every save so card views always see the shape
//  they just persisted.
//
//  Mirrors the `PlaybackPrefsStore` pattern: a `@MainActor`
//  observable singleton, idempotent hydration, and a `clear()` hook
//  for sign-out so the next user doesn't briefly see the previous
//  user's badge layout.
//

import Foundation
import SwiftUI

@MainActor
final class OverlayPrefsStore: ObservableObject {

    static let shared = OverlayPrefsStore()

    /// `true` when the server allows overlays at all. An admin can
    /// flip this off globally via the `overlays.enabled` server
    /// setting; when `false`, `CardOverlays` should not be rendered
    /// even if the user has prefs configured.
    @Published private(set) var enabled: Bool = true
    /// Resolved prefs (user value > admin defaults > registry
    /// defaults). Card views read this directly.
    @Published private(set) var prefs: CardOverlayPrefs = OverlaySchema.buildDefaults()
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    /// Raw user-setting value from the server, kept around so the
    /// settings UI can tell when the user has any override vs. when
    /// they're still on the admin defaults.
    private(set) var hasUserOverride: Bool = false

    private var hasHydrated = false
    private var adminDefaultsRaw: String?
    /// `true` once a read established that this server predates the
    /// canonical settings API. Writes then target the legacy endpoint
    /// the old server still accepts instead of failing every save.
    private var usesLegacyAPI = false
    /// Invalidates an older refresh when the active server changes or a newer
    /// refresh starts, preventing late responses from repopulating stale prefs.
    private var refreshGeneration: UInt = 0

    /// In-flight write task, if any. While non-nil, additional
    /// `setPrefs(_:)` calls just replace `pendingSnapshot` instead of
    /// issuing a parallel HTTP request — see `flushPendingWrites()` for
    /// the drain logic.
    private var pendingWrite: Task<Void, Never>?
    /// Most recent snapshot the user wants persisted. Cleared by the
    /// drain task right before it serializes; replaced by any new
    /// `setPrefs` that arrives during the PUT.
    private var pendingSnapshot: CardOverlayPrefs?
    /// Monotonically-increasing token associated with the current
    /// `pendingWrite`. When `clear()` or `resetToDefaults()` cancels
    /// the in-flight task and a new `setPrefs` immediately starts a
    /// fresh one, this lets the *old* task's `defer` recognize it's
    /// no longer the current drain and skip clobbering
    /// `pendingWrite` — without it, the stale defer could nil out
    /// the new task and allow parallel drains to start.
    private var pendingWriteGeneration: UInt = 0

    /// Idempotent first-load. Safe to call from `.task {}` on every
    /// view that wants overlays — subsequent invocations are no-ops
    /// until `clear()` runs.
    ///
    /// Returns `true` only when this call actually ran the fetch, so a
    /// caller that instruments the outcome can tell "I hydrated and it
    /// resolved" apart from "somebody else's hydration was already
    /// hydrated or still in flight". Without that distinction a
    /// short-circuited call reads the *next* refresh's freshly-cleared
    /// `lastError` and reports a success it never observed.
    @discardableResult
    func hydrateIfNeeded() async -> Bool {
        guard !hasHydrated, !isLoading else { return false }
        await refresh()
        return true
    }

    /// Re-fetch both the admin config and the user setting from the
    /// server, then recompute `prefs`. Called after every save so
    /// local state matches what the server just stored.
    ///
    /// Failure semantics:
    /// - "No value stored yet" (a contract default answer, or a legacy
    ///   404) is success — `userRaw` stays nil and we render from
    ///   admin defaults or registry defaults.
    /// - Any other transport error (on either endpoint) leaves
    ///   `hasHydrated` false so the next `hydrateIfNeeded()` retries.
    ///   This matters most for the admin kill switch: if
    ///   `/settings/overlay-config` errors but the user setting
    ///   resolves, we MUST NOT mark the store hydrated, because
    ///   `enabled` would be stuck at its default `true` and the next
    ///   view appearance would not retry — the admin's "disable
    ///   overlays globally" toggle would be silently ignored for the
    ///   rest of the session.
    /// - We still update `prefs` and `enabled` with what we know so
    ///   cards render *something* (registry defaults at worst) rather
    ///   than blocking the UI on the retry.
    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        lastError = nil
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }

        let api = ContinuumAPI.shared
        var resolvedEnabled = true
        var resolvedAdminDefaults: String?
        var resolvedError: String?
        var configFetchFailed = false
        do {
            let config = try await api.overlayConfig()
            resolvedEnabled = config.enabled
            resolvedAdminDefaults = config.defaults
        } catch {
            resolvedError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            configFetchFailed = true
        }

        var userRaw: String?
        var userFetchFailed = false
        var resolvedLegacyAPI = usesLegacyAPI
        do {
            let response = try await api.getEffectiveValues(keys: [.uiCardOverlays])
            if let entry = response.value(for: .uiCardOverlays),
               entry.source == .scope(.profile),
               entry.value != .null {
                userRaw = Self.jsonString(from: entry.value)
            }
            resolvedLegacyAPI = false
        } catch SettingsAPIError.serverUpgradeRequired {
            // Pre-contract server: the canonical routes don't exist.
            // Read the legacy string-valued user setting instead, where
            // a 404 is the documented "not set yet".
            resolvedLegacyAPI = true
            do {
                let entry = try await api.getUserSetting(key: Self.legacySettingKey)
                userRaw = entry.value
            } catch HTTPError.http(let code, _) where code == 404 {
                userRaw = nil
            } catch {
                resolvedError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                userFetchFailed = true
            }
        } catch {
            resolvedError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            userFetchFailed = true
        }

        guard generation == refreshGeneration else { return }
        lastError = resolvedError

        // Preserve cached config state on transient failures. The
        // sentinel `resolvedEnabled = true` is only valid when the
        // fetch actually succeeded — otherwise writing it back would
        // re-enable overlays the admin had previously disabled and
        // wipe the cached `adminDefaultsRaw`, dropping the baseline
        // for users who haven't customized.
        if !configFetchFailed {
            self.enabled = resolvedEnabled
            self.adminDefaultsRaw = resolvedAdminDefaults
        }
        if !userFetchFailed {
            self.usesLegacyAPI = resolvedLegacyAPI
        }
        self.hasUserOverride = userFetchFailed ? hasUserOverride : (userRaw != nil)
        if !userFetchFailed {
            // Use the freshly-resolved admin defaults when we have them;
            // fall back to the cached value when the config fetch failed
            // this round but a prior refresh had captured it.
            let defaults = configFetchFailed ? adminDefaultsRaw : resolvedAdminDefaults
            self.prefs = OverlaySchema.parse(userRaw ?? defaults)
        }
        // Only complete hydration when BOTH endpoints gave a definitive
        // answer. Either failure leaves `hasHydrated` false so the
        // next `.task { await hydrateIfNeeded() }` retries.
        if !configFetchFailed && !userFetchFailed {
            self.hasHydrated = true
        }
    }

    /// Optimistically update local state, then persist. Writes are
    /// serialized and coalesced: if the user makes several rapid
    /// changes (e.g. flipping through presets), only one PUT runs at
    /// a time and intermediate snapshots are dropped. This prevents
    /// the stale-overwrite race where a slower earlier PUT lands
    /// after a faster later one and reverts the user's most recent
    /// choice — raised by Codex on #41.
    ///
    /// The method stays `async` for source compatibility with existing
    /// `Task { await store.setPrefs(next) }` call sites, but in practice
    /// returns as soon as the snapshot is queued.
    func setPrefs(_ next: CardOverlayPrefs) async {
        prefs = next
        hasUserOverride = true
        pendingSnapshot = next

        if pendingWrite == nil {
            pendingWriteGeneration &+= 1
            let myGeneration = pendingWriteGeneration
            pendingWrite = Task { [weak self] in
                await self?.flushPendingWrites(generation: myGeneration)
            }
        }
    }

    /// Drain `pendingSnapshot` to the server. Loops so a snapshot
    /// updated while an earlier PUT was in flight is picked up without
    /// spinning up a new task. Exits cleanly when the queue is empty;
    /// `pendingWrite = nil` is the signal that future `setPrefs` calls
    /// must launch a fresh task.
    ///
    /// The `generation` parameter guards the cleanup against a race:
    /// `clear()` / `resetToDefaults()` can cancel us and a follow-up
    /// `setPrefs` can start a new drain before this one finishes
    /// unwinding. The new drain bumps `pendingWriteGeneration`, and
    /// we only nil out `pendingWrite` if it's still ours.
    private func flushPendingWrites(generation: UInt) async {
        defer {
            if pendingWriteGeneration == generation {
                pendingWrite = nil
            }
        }
        while let snapshot = pendingSnapshot {
            if Task.isCancelled { return }
            pendingSnapshot = nil
            do {
                try await persist(snapshot)
            } catch {
                // `clear()` was called mid-write (e.g. sign-out). Bail
                // before touching state that no longer belongs to this
                // session.
                if Task.isCancelled { return }
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                await refresh()
                // refresh() may have raced with another `setPrefs`; the
                // next loop iteration handles a queued snapshot, or
                // exits if pendingSnapshot is still nil.
            }
        }
    }

    /// One full-document write, routed to whichever settings API this
    /// server speaks. A canonical attempt that discovers a legacy
    /// server mid-session (`serverUpgradeRequired`) retries the legacy
    /// endpoint once rather than surfacing an error for a save the old
    /// API can still honor.
    private func persist(_ snapshot: CardOverlayPrefs) async throws {
        let json = OverlaySchema.serialize(snapshot)
        if usesLegacyAPI {
            try await ContinuumAPI.shared.setSetting(key: Self.legacySettingKey, value: json)
            return
        }
        guard let value = Self.jsonValue(from: json) else {
            throw SettingsAPIError.invalidValue(message: "Overlay prefs did not serialize to JSON.")
        }
        do {
            try await ContinuumAPI.shared.putValue(
                key: .uiCardOverlays,
                scope: .profile,
                value: value,
                mutationId: newSettingMutationId()
            )
        } catch SettingsAPIError.serverUpgradeRequired {
            usesLegacyAPI = true
            try await ContinuumAPI.shared.setSetting(key: Self.legacySettingKey, value: json)
        }
    }

    /// Drop the user's override and fall back to the admin baseline.
    /// Equivalent to "reset to defaults" in the settings UI.
    ///
    /// Cancels and awaits any in-flight `setPrefs` PUT before issuing
    /// the DELETE. Without that sequencing, a slower earlier PUT can
    /// land server-side AFTER the DELETE and recreate the override
    /// document the user just asked us to drop. Awaiting the cancelled
    /// task lets URLSession either complete its in-flight request or
    /// cancel the data task before we move on.
    func resetToDefaults() async {
        if let task = pendingWrite {
            pendingSnapshot = nil
            task.cancel()
            await task.value
            // Bump the generation so the cancelled task's deferred
            // cleanup doesn't clobber any drain that future setPrefs
            // calls might spin up.
            pendingWrite = nil
            pendingWriteGeneration &+= 1
        }

        do {
            if usesLegacyAPI {
                try await ContinuumAPI.shared.deleteSetting(key: Self.legacySettingKey)
            } else {
                try await ContinuumAPI.shared.deleteValue(key: .uiCardOverlays, scope: .profile)
            }
            hasUserOverride = false
        } catch SettingsAPIError.noValueAtScope {
            // Already gone.
            hasUserOverride = false
        } catch HTTPError.http(let code, _) where code == 404 {
            // Already gone (legacy endpoint).
            hasUserOverride = false
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
        await refresh()
    }

    /// Wipe local state on sign-out. The next user gets a clean
    /// hydration cycle when they open a card or the settings screen.
    ///
    /// Cancels any in-flight `setPrefs` so a queued PUT for the
    /// previous user can't land after the session boundary. The
    /// network task may already be on the wire; URLSession will
    /// complete it but the catch block in `flushPendingWrites`
    /// checks `Task.isCancelled` before touching state.
    func clear() {
        // Let a new server start hydrating immediately while any old network
        // request winds down; its generation guard prevents stale application.
        refreshGeneration &+= 1
        isLoading = false
        pendingWrite?.cancel()
        pendingWrite = nil
        pendingSnapshot = nil
        // Invalidate any generation token captured by an in-flight
        // drain so its deferred cleanup can't nil out a new task
        // started by a post-`clear()` `setPrefs`.
        pendingWriteGeneration &+= 1
        enabled = true
        prefs = OverlaySchema.buildDefaults()
        adminDefaultsRaw = nil
        usesLegacyAPI = false
        hasUserOverride = false
        hasHydrated = false
        lastError = nil
    }

    // MARK: - Wire bridging

    /// The contract stores the document as a JSON object; `OverlaySchema`
    /// speaks JSON strings (shared with the admin `overlay-config`
    /// baseline, which still travels as a string). These two hops keep
    /// one codec — `OverlaySchema` — as the single interpreter of the
    /// document shape.
    private static func jsonString(from value: SettingJSONValue) -> String? {
        guard let data = try? SettingsWireCoding.makeEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonValue(from raw: String) -> SettingJSONValue? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: data)
    }

    /// The pre-contract account-scoped user-setting key. Only used
    /// against servers that predate the canonical settings API; new
    /// servers reject it (the contract renamed it `ui.card_overlays`
    /// and migrates stored rows server-side).
    static let legacySettingKey = "card_overlays"
}
