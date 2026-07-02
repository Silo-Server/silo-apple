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

    private var hasLoaded = false
    /// In-flight bus-triggered reload; cancelled and replaced on the next
    /// event so a slow earlier response can't overwrite a newer one.
    private var reloadTask: Task<Void, Never>?
    private let api: ContinuumAPI

    init(api: ContinuumAPI = .shared) {
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
        } catch {
            if buckets.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    func cancel(_ request: MediaRequest) async {
        guard cancellingId == nil else { return }
        cancellingId = request.id
        actionErrorMessage = nil
        do {
            let updated = try await api.cancelRequest(id: request.id)
            RequestsEventBus.shared.publish(updated)
            await load()
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
