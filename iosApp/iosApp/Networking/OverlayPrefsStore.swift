//
//  OverlayPrefsStore.swift
//  Continuum (iOS + tvOS)
//
//  Cached card-overlay configuration for the signed-in profile.
//  Resolves a single rendered `CardOverlayPrefs` from one of two
//  sources, in this priority:
//    1. The user's saved prefs (`GET /settings/card_overlays`) — if
//       present, this is the entire source of truth.
//    2. Otherwise, the admin-configured baseline JSON from
//       `GET /settings/overlay-config` (`defaults` field).
//    3. Otherwise, registry defaults (`OverlaySchema.buildDefaults()`).
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
    func hydrateIfNeeded() async {
        guard !hasHydrated, !isLoading else { return }
        await refresh()
    }

    /// Re-fetch both the admin config and the user setting from the
    /// server, then recompute `prefs`. Called after every save so
    /// local state matches what the server just stored.
    ///
    /// Failure semantics:
    /// - A 404 on the user setting means "not set yet" and is treated
    ///   as success — `userRaw` stays nil and we render from admin
    ///   defaults or registry defaults.
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
        do {
            let entry = try await api.getUserSetting(key: OverlayPrefsStore.settingKey)
            userRaw = entry.value
        } catch HTTPError.http(let code, _) where code == 404 {
            userRaw = nil
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
            let json = OverlaySchema.serialize(snapshot)
            do {
                try await ContinuumAPI.shared.setSetting(
                    key: OverlayPrefsStore.settingKey,
                    value: json
                )
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
            try await ContinuumAPI.shared.deleteSetting(key: OverlayPrefsStore.settingKey)
            hasUserOverride = false
        } catch HTTPError.http(let code, _) where code == 404 {
            // Already gone.
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
        hasUserOverride = false
        hasHydrated = false
        lastError = nil
    }

    static let settingKey = "card_overlays"
}
