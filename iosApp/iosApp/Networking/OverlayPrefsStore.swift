//
//  OverlayPrefsStore.swift
//  Silo (iOS + tvOS)
//
//  Cached card-overlay configuration for the signed-in profile.
//  Resolves a single rendered `CardOverlayPrefs` from one of three
//  sources, in this priority:
//    1. The user's saved prefs — the contract key `ui.card_overlays`
//       at profile scope, read through the canonical
//       `GET /settings/values/effective` endpoint. If present, this is
//       the entire source of truth.
//    2. Otherwise, the admin-configured baseline JSON from
//       `GET /settings/overlay-config` (`defaults` field).
//    3. Otherwise, registry defaults (`OverlaySchema.buildDefaults()`).
//
//  The contract stores the document as a JSON object (jsonb), not a
//  JSON string, so reads bridge from `SettingJSONValue` to
//  `OverlaySchema`'s string codec here. A server that predates the
//  canonical settings API has no other place to read the document
//  from: the store reports that the server needs an update and
//  renders the admin baseline (or registry defaults without one).
//
//  This is winner-take-all, not layered merging, matching the web's
//  `useOverlayPrefs.ts` hook. This app only reads the document.
//
//  A `@MainActor` observable singleton, idempotent hydration, and a
//  `clear()` hook for sign-out and profile switches so the next
//  profile doesn't briefly see the previous profile's badge layout.
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

    private var hasHydrated = false
    private var adminDefaultsRaw: String?
    /// Invalidates an older refresh when the active server changes or a newer
    /// refresh starts, preventing late responses from repopulating stale prefs.
    private var refreshGeneration: UInt = 0
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

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
    /// server, then recompute `prefs`.
    ///
    /// Failure semantics:
    /// - "No value stored yet" (a contract default answer) is success —
    ///   `userRaw` stays nil and we render from admin defaults or
    ///   registry defaults.
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
    /// - A server without the canonical settings API, or one whose settings
    ///   revision is behind this app's contract, is a failure that reports
    ///   the server-update message and leaves `hasHydrated` false. The
    ///   user value is unreadable, so cards render from the admin baseline
    ///   (or registry defaults). There is no legacy fallback.
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
        var userUpgradeRequired = false
        do {
            let response = try await api.getEffectiveValues(keys: [.uiCardOverlays])
            if let entry = response.value(for: .uiCardOverlays),
               entry.source == .scope(.profile),
               entry.value != .null {
                userRaw = Self.jsonString(from: entry.value)
            }
        } catch SettingsAPIError.serverUpgradeRequired {
            resolvedError = UpdateRequirement.serverMessage
            userFetchFailed = true
            userUpgradeRequired = true
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
        // A transient user-read failure keeps the prior prefs. An
        // update-required answer is not transient and the user value can't
        // be read at all, so render the admin baseline instead (`userRaw`
        // is nil on that path).
        if !userFetchFailed || userUpgradeRequired {
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

    /// Wipe local state on sign-out or a profile switch. The next
    /// profile gets a clean hydration cycle when it opens a card.
    func clear() {
        // Let a new server start hydrating immediately while any old network
        // request winds down; its generation guard prevents stale application.
        refreshGeneration &+= 1
        isLoading = false
        enabled = true
        prefs = OverlaySchema.buildDefaults()
        adminDefaultsRaw = nil
        hasHydrated = false
        lastError = nil
    }

    // MARK: - Wire bridging

    /// The contract stores the document as a JSON object; `OverlaySchema`
    /// speaks JSON strings (shared with the admin `overlay-config`
    /// baseline, which still travels as a string). This hop keeps one
    /// codec — `OverlaySchema` — as the single interpreter of the
    /// document shape.
    private static func jsonString(from value: SettingJSONValue) -> String? {
        guard let data = try? SettingsWireCoding.makeEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
