//
//  ProfilePrefsStore.swift
//  Silo (iOS + tvOS + macOS)
//
//  In-memory cache of the signed-in profile's preferred subtitle
//  language, hydrated lazily on first read. The detail-page subtitle
//  selector reads this to float the preferred language to the top of its
//  grouped track list — matching what the player does at playback time
//  via `WatchDetail.effective_subtitle_language`.
//
//  Scope is deliberately tiny: playback already reads the precise
//  per-item `effective_*` values off the WatchDetail response, so this
//  store exists only for the pre-playback detail screen, which sees the
//  catalog `ItemDetail` (no effective fields) and would otherwise have no
//  cheap source for the preference. The profile default is a close-enough
//  approximation for ordering.
//
//  Mirrors the `OverlayPrefsStore` pattern: a
//  `@MainActor` observable singleton, idempotent hydration, and a
//  `clear()` hook for sign-out / profile switch.
//

import Foundation

@MainActor
final class ProfilePrefsStore: ObservableObject {

    static let shared = ProfilePrefsStore()

    /// The active profile's preferred subtitle language (ISO code), or nil
    /// when the profile hasn't set one. Read by the detail-page selector.
    @Published private(set) var preferredSubtitleLanguage: String?

    private var hasHydrated = false
    private var hydrationTask: Task<Void, Never>?
    private var hydrationGeneration = 0

    /// Idempotent first-load. Safe to call from `.task {}` on every view
    /// that wants the preference — subsequent invocations are no-ops until
    /// `clear()` runs.
    func hydrateIfNeeded() async {
        guard !hasHydrated else { return }
        await refresh()
    }

    /// Re-fetch the profile list and resolve the active profile's
    /// subtitle language. A transient failure leaves `hasHydrated` false
    /// so the next `hydrateIfNeeded()` retries.
    func refresh() async {
        if let hydrationTask {
            await hydrationTask.value
            return
        }
        guard let profileId = ServerRegistry.shared.activeProfileId else {
            // No active profile yet — nothing to resolve, but don't mark
            // hydrated so a later sign-in retries.
            return
        }

        let generation = hydrationGeneration
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.hydrationGeneration == generation {
                    self?.hydrationTask = nil
                }
            }
            do {
                let profiles = try await AuthService.shared.getProfiles()
                guard !Task.isCancelled,
                      self?.hydrationGeneration == generation,
                      ServerRegistry.shared.activeProfileId == profileId else {
                    return
                }
                self?.preferredSubtitleLanguage = profiles
                    .first(where: { $0.id == profileId })?
                    .subtitleLanguage
                self?.hasHydrated = true
            } catch {
                // Leave state untouched; next hydrateIfNeeded() retries.
            }
        }
        hydrationTask = task
        await task.value
    }

    /// Push a known value without a round-trip. Settings calls this after
    /// successfully saving a new subtitle-language preference so the
    /// detail ordering reflects the change immediately.
    func setPreferredSubtitleLanguage(_ language: String?) {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredSubtitleLanguage = (trimmed?.isEmpty ?? true) ? nil : trimmed
        hasHydrated = true
    }

    /// Wipe local state on sign-out / profile switch so the next profile
    /// gets a clean hydration cycle.
    func clear() {
        hydrationGeneration &+= 1
        hydrationTask?.cancel()
        hydrationTask = nil
        preferredSubtitleLanguage = nil
        hasHydrated = false
    }
}
