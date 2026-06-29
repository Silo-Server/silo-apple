import Foundation

/// Drives the on-view "translate this description" flow for a single item.
///
/// The server has no job-status endpoint for description translation: you
/// `POST /items/{id}/translate-description` and then observe completion by
/// re-fetching the item detail until `pendingTranslationLanguage` clears
/// (the localized overview lands within seconds). This coordinator owns
/// that POST-then-poll loop, the bounded backoff, and the `idle /
/// translating / failed` UI state. Each refreshed `ItemDetail` is written
/// back into the owning `ItemDetailViewModel` (so the overview re-renders)
/// and into `ResponseCache` (so a returning visit shows the translation).
///
/// One in-flight task at a time; `cancel()` on disappear.
@MainActor
@Observable
final class DescriptionTranslationCoordinator {
    enum Phase: Equatable {
        case idle
        case translating
        case failed
    }

    private(set) var phase: Phase = .idle

    private let api: ContinuumAI
    private let catalog: ContinuumAPI
    private var task: Task<Void, Never>?

    /// Re-poll schedule (seconds). The overview typically lands within the
    /// first couple of passes; the tail covers a slow translation. The sum
    /// is the hard cap (~31s) after which we give up and surface `.failed`.
    private let backoff: [UInt64] = [1, 2, 3, 5, 5, 5, 5, 5]

    init(api: ContinuumAI = .shared, catalog: ContinuumAPI = .shared) {
        self.api = api
        self.catalog = catalog
    }

    /// Kick off a translation for `contentId` into `targetLanguage`,
    /// writing each refreshed detail back through `apply`. No-op if a
    /// translation is already in flight.
    func translate(
        contentId: String,
        targetLanguage: String,
        apply: @escaping (ItemDetail) -> Void
    ) {
        guard task == nil else { return }
        phase = .translating
        task = Task { [weak self] in
            await self?.run(contentId: contentId, targetLanguage: targetLanguage, apply: apply)
        }
    }

    /// Cancel any in-flight translation and reset to idle. Safe to call
    /// from `onDisappear`.
    func cancel() {
        task?.cancel()
        task = nil
        if phase == .translating { phase = .idle }
    }

    private func run(
        contentId: String,
        targetLanguage: String,
        apply: @escaping (ItemDetail) -> Void
    ) async {
        defer { task = nil }

        do {
            try await api.translateDescription(contentId: contentId, targetLanguage: targetLanguage)
        } catch {
            phase = .failed
            return
        }

        for delay in backoff {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            if Task.isCancelled { return }

            guard let refreshed = try? await catalog.itemDetail(contentId: contentId) else {
                continue
            }
            apply(refreshed)
            ResponseCache.shared.set(refreshed, for: CacheKey.itemDetail(contentId))

            if refreshed.pendingTranslationLanguage == nil {
                phase = .idle
                return
            }
        }

        // Cap hit without the pending flag clearing.
        phase = .failed
    }
}
