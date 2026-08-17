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

    private let api: SiloAI
    private let catalog: SiloAPI
    private var task: Task<Void, Never>?
    private var activeRunID: UUID?

    /// Re-poll schedule (seconds). The overview typically lands within the
    /// first couple of passes; the tail covers a slow translation. The sum
    /// is the hard cap (~31s) after which we give up and surface `.failed`.
    private let backoff: [TimeInterval] = [1, 2, 3, 5, 5, 5, 5, 5]

    init(api: SiloAI = .shared, catalog: SiloAPI = .shared) {
        self.api = api
        self.catalog = catalog
    }

    /// Kick off a translation for `contentId` into `targetLanguage`,
    /// writing each refreshed detail back through `apply`. No-op if a
    /// translation is already in flight.
    func translate(
        contentId: String,
        targetLanguage: String,
        apply: @MainActor @escaping (ItemDetail) -> Void
    ) {
        guard task == nil else { return }
        phase = .translating
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            await self?.run(contentId: contentId, targetLanguage: targetLanguage, runID: runID, apply: apply)
        }
    }

    /// Cancel any in-flight translation and reset to idle. Safe to call
    /// from `onDisappear`.
    func cancel() {
        activeRunID = nil
        task?.cancel()
        task = nil
        if phase == .translating { phase = .idle }
    }

    private func run(
        contentId: String,
        targetLanguage: String,
        runID: UUID,
        apply: @MainActor @escaping (ItemDetail) -> Void
    ) async {
        defer {
            if activeRunID == runID {
                activeRunID = nil
                task = nil
            }
        }

        do {
            try await api.translateDescription(contentId: contentId, targetLanguage: targetLanguage)
        } catch {
            guard isCurrentRun(runID) else { return }
            phase = .failed
            return
        }

        for delay in backoff {
            guard isCurrentRun(runID) else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard isCurrentRun(runID) else { return }

            guard let refreshed = try? await catalog.itemDetail(contentId: contentId) else {
                continue
            }
            // A cancellation (disappear / item change) may have landed during
            // the fetch above; bail before applying so a stale poll can't
            // clobber the view model / cache with the previous item's detail.
            guard isCurrentRun(runID) else { return }
            apply(refreshed)
            ResponseCache.shared.set(refreshed, for: CacheKey.itemDetail(contentId))

            if refreshed.pendingTranslationLanguage == nil {
                guard isCurrentRun(runID) else { return }
                phase = .idle
                return
            }
        }

        // Cap hit without the pending flag clearing.
        guard isCurrentRun(runID) else { return }
        phase = .failed
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        activeRunID == runID && !Task.isCancelled
    }
}
