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
            hasLoaded = true
            // The server's list now shows each held cancel's result.
            if !unconfirmedCancelIds.isEmpty {
                unconfirmedCancelIds.removeAll()
                actionErrorMessage = nil
            }
        } catch {
            if buckets.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Whether the row may offer cancel again; a held cancel may not.
    func isCancelUnconfirmed(_ request: MediaRequest) -> Bool {
        unconfirmedCancelIds.contains(request.id)
    }

    func cancel(_ request: MediaRequest) async {
        guard cancellingId == nil, !unconfirmedCancelIds.contains(request.id) else { return }
        cancellingId = request.id
        actionErrorMessage = nil
        do {
            let updated = try await api.cancelRequest(id: request.id)
            RequestsEventBus.shared.publish(updated)
            await load()
        } catch where RequestMutationFailure.isUncertain(error) {
            unconfirmedCancelIds.insert(request.id)
            cancellingId = nil
            // A read under a replaced owner says nothing about this cancel.
            if !RequestMutationFailure.isOwnerChanged(error) {
                await load()
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
