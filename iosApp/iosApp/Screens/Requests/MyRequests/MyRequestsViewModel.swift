import Foundation

@Observable
@MainActor
final class MyRequestsViewModel {
    private(set) var buckets: [(bucket: MyRequestsBucket, requests: [MediaRequest])] = []
    var isLoading = false
    var error: ErrorState?
    /// Id of the request currently being cancelled (disables its row).
    private(set) var cancellingId: String?
    /// Inline message for a failed cancel; cleared on the next action.
    private(set) var actionErrorMessage: String?
    /// Requests whose cancel was sent without a usable answer. Cancel is
    /// `non_retryable`, so these stay held until a fresh list read.
    private(set) var unconfirmedCancelIds: Set<String> = []

    private var hasLoaded = false
    /// In-flight bus-triggered reload; cancelled and replaced on the next
    /// event so a slow earlier response can't overwrite a newer one.
    private var reloadTask: Task<Void, Never>?
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    var isEmpty: Bool {
        hasLoaded && buckets.isEmpty
    }

    func load() async {
        isLoading = buckets.isEmpty
        error = nil
        do {
            let requests = try await api.myRequests()
            buckets = MyRequestsBucket.bucket(requests)
            RequestDetailCache.shared.storeOwnRecords(requests)
            RequestDetailCache.shared.prefetch(buckets.flatMap(\.requests), api: api)
            hasLoaded = true
            releaseHeldCancels()
        } catch {
            if buckets.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// The server's list now shows each held cancel's result.
    private func releaseHeldCancels() {
        guard !unconfirmedCancelIds.isEmpty else { return }
        unconfirmedCancelIds.removeAll()
        actionErrorMessage = nil
    }

    /// Whether the row may offer cancel again; a held cancel may not.
    func isCancelUnconfirmed(_ request: MediaRequest) -> Bool {
        unconfirmedCancelIds.contains(request.id)
    }

    /// Cancels one of the user's requests. `refresh` re-reads the list that
    /// shows the row when it isn't this model's (the tvOS hub) and returns
    /// whether the read succeeded. The bus patches that list on success, so
    /// it runs only to settle an uncertain cancel.
    func cancel(_ request: MediaRequest, refresh: (() async -> Bool)? = nil) async {
        guard cancellingId == nil, !unconfirmedCancelIds.contains(request.id) else { return }
        cancellingId = request.id
        actionErrorMessage = nil
        do {
            let updated = try await api.cancelRequest(id: request.id)
            RequestsEventBus.shared.publish(updated)
            if refresh == nil { await load() }
        } catch where RequestMutationFailure.isUncertain(error) {
            unconfirmedCancelIds.insert(request.id)
            cancellingId = nil
            // A read under a replaced owner says nothing about this cancel.
            if !RequestMutationFailure.isOwnerChanged(error) {
                if let refresh {
                    if await refresh() { releaseHeldCancels() }
                } else {
                    await load()
                }
            }
            if !unconfirmedCancelIds.isEmpty {
                actionErrorMessage = RequestErrorCopy.unconfirmedCancelMessage
            }
        } catch {
            actionErrorMessage = RequestErrorCopy.message(for: error)
        }
        cancellingId = nil
    }

    /// Bus consumer: a mutation elsewhere (detail submit) while this screen
    /// is mounted — the list is short, so a full refetch is the simplest
    /// correct response.
    func applyRequestUpdate(_ record: MediaRequest) {
        guard cancellingId == nil else { return }
        reloadTask?.cancel()
        reloadTask = Task { await load() }
    }
}
