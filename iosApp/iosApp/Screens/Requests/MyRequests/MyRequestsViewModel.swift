import Foundation

@Observable
@MainActor
final class MyRequestsViewModel {
    private(set) var buckets: [(bucket: MyRequestsBucket, requests: [MediaRequest])] = []
    var isLoading = false
    var error: ErrorState?
    /// Id of the request whose cancel or remove is running (disables its
    /// row). One action runs at a time.
    private var actingId: String?
    /// Inline message for a failed cancel or remove; cleared on the next
    /// action.
    private(set) var actionErrorMessage: String?
    /// Short confirmation after a remove; clears itself after a few
    /// seconds, or on the next action.
    private(set) var notice: String? {
        didSet { scheduleNoticeClear() }
    }
    /// Requests whose cancel or remove was sent without a usable answer, each
    /// with the serial of its hold. Both are `non_retryable`, so these stay
    /// held until a list read that started after the hold succeeds.
    private var unconfirmedActions: [String: Int] = [:]
    private var holdSerial = 0
    /// Bumped by every list read and by a removal, so only the newest read
    /// installs its answer: an older one could bring back a removed row.
    private var listGeneration = 0

    private var hasLoaded = false
    /// In-flight bus-triggered reload; cancelled and replaced on the next
    /// event so a slow earlier response can't overwrite a newer one.
    private var reloadTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    var isEmpty: Bool {
        hasLoaded && buckets.isEmpty
    }

    func load() async {
        listGeneration &+= 1
        let generation = listGeneration
        let coveredHolds = holdSerial
        isLoading = buckets.isEmpty
        error = nil
        defer { if generation == listGeneration { isLoading = false } }
        do {
            let requests = try await api.myRequests()
            guard generation == listGeneration else { return }
            buckets = MyRequestsBucket.bucket(requests)
            RequestDetailCache.shared.storeOwnRecords(requests)
            RequestDetailCache.shared.prefetch(buckets.flatMap(\.requests), api: api)
            hasLoaded = true
            releaseHeldActions(through: coveredHolds)
        } catch {
            if generation == listGeneration, buckets.isEmpty {
                self.error = ErrorState(error)
            }
        }
    }

    /// A read that started after these holds now shows their results; a
    /// hold made while the read was running stays.
    private func releaseHeldActions(through serial: Int) {
        let before = unconfirmedActions.count
        unconfirmedActions = unconfirmedActions.filter { $0.value > serial }
        if unconfirmedActions.count < before, unconfirmedActions.isEmpty { actionErrorMessage = nil }
    }

    /// Whether the row may offer cancel or remove again; a held action may
    /// not.
    func isActionUnconfirmed(_ request: MediaRequest) -> Bool {
        unconfirmedActions[request.id] != nil
    }

    /// Whether the row may offer cancel: the request can still be withdrawn,
    /// and `canAct` holds.
    func canCancel(_ request: MediaRequest) -> Bool {
        RequestDisplayState(record: request).isCancelable && canAct(request)
    }

    /// Whether the row may offer remove: the server supports it, the request
    /// failed and delivered nothing, and `canAct` holds.
    func canRemove(_ request: MediaRequest) -> Bool {
        RequestsFeatureStore.shared.removeFailedSupported && request.isRemovable && canAct(request)
    }

    /// No action is running (another would be refused without a word) and
    /// none is held for this request.
    private func canAct(_ request: MediaRequest) -> Bool {
        actingId == nil && unconfirmedActions[request.id] == nil
    }

    /// Whether the row is waiting on its own cancel or remove.
    func isBusy(_ request: MediaRequest) -> Bool {
        actingId == request.id
    }

    /// Cancels one of the user's requests. `refresh` re-reads the list that
    /// shows the row when it isn't this model's (the tvOS hub) and returns
    /// whether the read succeeded. The bus patches that list on success, so
    /// it runs only to settle an uncertain cancel.
    func cancel(_ request: MediaRequest, refresh: (() async -> Bool)? = nil) async {
        guard begin(request) else { return }
        defer { release(request) }
        do {
            let updated = try await api.cancelRequest(id: request.id)
            RequestsEventBus.shared.publish(updated)
            if refresh == nil { await load() }
        } catch where RequestMutationFailure.isUncertain(error) {
            await hold(request, after: error, refresh: refresh, message: RequestErrorCopy.unconfirmedCancelMessage)
        } catch {
            actionErrorMessage = RequestErrorCopy.message(for: error)
        }
    }

    /// Removes one of the user's failed requests that delivered nothing
    /// (`MediaRequest.isRemovable`). Every answer reads the list again: the
    /// row goes, or shows what an admin or the library did to it meanwhile.
    /// An uncertain outcome under a replaced owner skips the read, which
    /// would run under the new owner.
    /// `refresh` re-reads the list that shows the row when it isn't this
    /// model's (the tvOS hub) and returns whether the read succeeded.
    func remove(_ request: MediaRequest, refresh: (() async -> Bool)? = nil) async {
        guard begin(request) else { return }
        defer { release(request) }
        var message: String?
        do {
            try await api.removeFailedRequest(id: request.id)
            removed(request)
        } catch where RequestMutationFailure.isAlreadyRemoved(error) {
            removed(request)
        } catch where RequestMutationFailure.isUncertain(error) {
            await hold(request, after: error, refresh: refresh, message: RequestErrorCopy.unconfirmedRemoveMessage)
            return
        } catch where RequestMutationFailure.isRemoveConflict(error) {
            message = RequestErrorCopy.removeConflictMessage
        } catch {
            message = RequestErrorCopy.message(for: error)
        }
        await reread(refresh)
        if let message { actionErrorMessage = message }
    }

    /// Claims the single action slot for `request` and clears the last
    /// action's messages; false when the row may not act.
    private func begin(_ request: MediaRequest) -> Bool {
        guard canAct(request) else { return false }
        actingId = request.id
        actionErrorMessage = nil
        notice = nil
        return true
    }

    /// Frees the action slot if `request` still holds it. An uncertain
    /// action gives the slot up before its re-read, and another action may
    /// claim it meanwhile.
    private func release(_ request: MediaRequest) {
        if actingId == request.id { actingId = nil }
    }

    /// A `non_retryable` action got no usable answer: hold the row's actions
    /// and read the list again, which settles the hold when it succeeds. A
    /// read under a replaced owner says nothing about the action, so it is
    /// skipped.
    private func hold(_ request: MediaRequest, after error: Error,
                      refresh: (() async -> Bool)?, message: String) async {
        holdSerial &+= 1
        unconfirmedActions[request.id] = holdSerial
        release(request)
        if !RequestMutationFailure.isOwnerChanged(error) { await reread(refresh) }
        if unconfirmedActions[request.id] != nil { actionErrorMessage = message }
    }

    /// The server answered that the request is gone. Its row goes now, so a
    /// failed re-read cannot leave it on screen with its action.
    private func removed(_ request: MediaRequest) {
        listGeneration &+= 1
        buckets = MyRequestsBucket.bucket(buckets.flatMap(\.requests).filter { $0.id != request.id })
        RequestsEventBus.shared.publishRemoval(request)
        notice = RequestErrorCopy.removedNotice
    }

    private func scheduleNoticeClear() {
        noticeTask?.cancel()
        guard notice != nil else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    /// Reads the list that shows the rows again; a successful read settles
    /// the holds made before it started.
    private func reread(_ refresh: (() async -> Bool)?) async {
        if let refresh {
            let coveredHolds = holdSerial
            if await refresh() { releaseHeldActions(through: coveredHolds) }
        } else {
            await load()
        }
    }

    /// Bus consumer: a mutation elsewhere (detail submit) while this screen
    /// is mounted — the list is short, so a full refetch is the simplest
    /// correct response.
    func applyRequestUpdate(_ record: MediaRequest) {
        guard actingId == nil else { return }
        reloadTask?.cancel()
        reloadTask = Task { await load() }
    }
}
