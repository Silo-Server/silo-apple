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

    /// `true` when cards should render overlays at all. The profile's
    /// `ui.card_overlays_enabled` choice wins in either direction; a
    /// profile that has not chosen inherits the server-wide
    /// `overlays.enabled` default. When `false`, `CardOverlays` should
    /// not be rendered even if the profile has prefs configured.
    @Published private(set) var enabled: Bool = true
    /// Resolved prefs (user value > admin defaults > registry
    /// defaults). Card views read this directly.
    @Published private(set) var prefs: CardOverlayPrefs = OverlaySchema.buildDefaults()
    // Every mounted card observes this store, so only `enabled` and `prefs`
    // publish, and only when they change. These two are read imperatively.
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    private var hasHydrated = false
    private var adminDefaultsRaw: String?
    /// The two inputs to `enabled`, cached separately so a failed read of
    /// one keeps the last answer for that half without discarding the other.
    private var serverEnabled = true
    private var profileEnabled: Bool?
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

    /// Re-fetch both the admin config and the user settings from the
    /// server, then recompute `prefs` and `enabled`.
    ///
    /// Failure semantics:
    /// - "No value stored yet" (a contract default answer) is success —
    ///   `userRaw` stays nil and we render from admin defaults or
    ///   registry defaults.
    /// - Any other transport error (on either endpoint) leaves
    ///   `hasHydrated` false so the next `hydrateIfNeeded()` retries.
    ///   This matters most for the server-wide overlay default: if
    ///   `/settings/overlay-config` errors but the user settings
    ///   resolve, we MUST NOT mark the store hydrated, because
    ///   `enabled` would be stuck at its default `true` for a profile
    ///   that has not chosen, and the next view appearance would not
    ///   retry — the admin's "off for everyone" default would be
    ///   silently ignored for the rest of the session.
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

        // The two reads are independent, so they run together.
        let api = self.api
        async let configRead = Self.result { try await api.overlayConfig() }
        async let valuesRead = Self.result {
            try await api.getEffectiveValues(keys: [.uiCardOverlays, .uiCardOverlaysEnabled])
        }
        let (configResult, valuesResult) = await (configRead, valuesRead)

        var resolvedEnabled = true
        var resolvedAdminDefaults: String?
        var resolvedError: String?
        var configFetchFailed = false
        do {
            let config = try configResult.get()
            resolvedEnabled = config.enabled
            resolvedAdminDefaults = config.defaults
        } catch {
            resolvedError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            configFetchFailed = true
        }

        var userRaw: String?
        var userEnabled: Bool?
        var userFetchFailed = false
        var userUpgradeRequired = false
        do {
            let response = try valuesResult.get()
            if let entry = response.value(for: .uiCardOverlays),
               entry.source == .scope(.profile),
               entry.value != .null {
                userRaw = Self.jsonString(from: entry.value)
            }
            if let entry = response.value(for: .uiCardOverlaysEnabled),
               entry.source == .scope(.profile) {
                userEnabled = entry.value.boolValue
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
            self.serverEnabled = resolvedEnabled
            self.adminDefaultsRaw = resolvedAdminDefaults
        }
        // Same rule for the profile half: a transient failure keeps the
        // last choice, and an unreadable value means no choice.
        if !userFetchFailed || userUpgradeRequired {
            self.profileEnabled = userEnabled
        }
        // An explicit profile choice overrides the server-wide default in
        // either direction, matching the web's `useOverlayPrefs.ts`.
        let effectiveEnabled = profileEnabled ?? serverEnabled
        if enabled != effectiveEnabled { enabled = effectiveEnabled }
        // A transient user-read failure keeps the prior prefs. An
        // update-required answer is not transient and the user value can't
        // be read at all, so render the admin baseline instead (`userRaw`
        // is nil on that path).
        if !userFetchFailed || userUpgradeRequired {
            // Use the freshly-resolved admin defaults when we have them;
            // fall back to the cached value when the config fetch failed
            // this round but a prior refresh had captured it.
            let defaults = configFetchFailed ? adminDefaultsRaw : resolvedAdminDefaults
            let resolvedPrefs = OverlaySchema.parse(userRaw ?? defaults)
            if prefs != resolvedPrefs { prefs = resolvedPrefs }
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
        serverEnabled = true
        profileEnabled = nil
        enabled = true
        prefs = OverlaySchema.buildDefaults()
        adminDefaultsRaw = nil
        hasHydrated = false
        lastError = nil
    }

    nonisolated private static func result<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
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
