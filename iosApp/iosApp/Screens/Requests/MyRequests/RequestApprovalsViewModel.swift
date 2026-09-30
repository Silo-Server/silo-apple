import Foundation

/// Where one row's admin action is, so the row can animate it: the button
/// spins while `working`, shows its result while `succeeded`, then the row
/// leaves the list.
enum RequestRowActionPhase: Equatable {
    case working(AdminRequestAction)
    case succeeded(AdminRequestAction)
}

/// The admin approval queue: everyone's requests waiting on a decision, and
/// failed ones that can be retried. Only reachable when
/// `RequestsFeatureStore.canModerate` is true.
@Observable
@MainActor
final class RequestApprovalsViewModel {
    private(set) var awaitingApproval: [MediaRequest] = []
    private(set) var failed: [MediaRequest] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var error: ErrorState?
    /// Inline message for a failed action; cleared on the next action.
    private(set) var actionErrorMessage: String?
    /// Bumped on every accepted action, for the success haptic.
    private(set) var completedActions = 0
    /// Requests whose decision was sent without a usable answer. Moderation
    /// is `non_retryable`, so these offer no action until a fresh read.
    private(set) var unconfirmedIds: Set<String> = []
    /// Per-row animation state for actions in flight or just finished.
    private(set) var phases: [String: RequestRowActionPhase] = [:]
    /// Per-row count of outright failures; a row's button shakes when its
    /// count changes. `failedActions` is the total, for the error haptic.
    private(set) var failureCounts: [String: Int] = [:]
    private(set) var failedActions = 0
    /// A failed action's message, shown on its own row so the list never
    /// shifts under the user's finger. Cleared by the row's next action.
    private(set) var rowErrors: [String: String] = [:]

    /// How long a finished row shows its result before leaving the list.
    static let resultHold: Duration = .milliseconds(900)

    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    var isEmpty: Bool {
        hasLoaded && awaitingApproval.isEmpty && failed.isEmpty
    }

    var pendingCount: Int { awaitingApproval.count }

    func load() async {
        isLoading = !hasLoaded
        error = nil
        async let pending = api.adminRequests(status: .pending, outcome: .active)
        async let broken = api.adminRequests(outcome: .failed)
        do {
            let (pendingItems, failedItems) = try await (pending, broken)
            awaitingApproval = pendingItems.sorted { $0.createdAt < $1.createdAt }
            failed = failedItems.sorted { $0.updatedAt > $1.updatedAt }
            hasLoaded = true
            RequestDetailCache.shared.storeModerationRecords(awaitingApproval + failed)
            RequestDetailCache.shared.prefetch(awaitingApproval + failed, api: api)
            // The server's list now shows each held decision's result.
            if !unconfirmedIds.isEmpty {
                unconfirmedIds.removeAll()
                actionErrorMessage = nil
            }
        } catch {
            if !hasLoaded {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Whether a row may offer its decision: not while its own action runs
    /// or is held. Rows act independently of each other.
    func canAct(on request: MediaRequest) -> Bool {
        phases[request.id] == nil && !unconfirmedIds.contains(request.id)
    }

    func phase(for request: MediaRequest) -> RequestRowActionPhase? {
        phases[request.id]
    }

    func perform(_ action: AdminRequestAction, on request: MediaRequest) async {
        guard canAct(on: request) else { return }
        phases[request.id] = .working(action)
        rowErrors[request.id] = nil
        actionErrorMessage = nil
        do {
            let updated = try await api.adminRequestAction(id: request.id, action: action)
            // Show the result on the row, free the list for the next action,
            // then let the row leave.
            phases[request.id] = .succeeded(action)
            completedActions += 1
            RequestsEventBus.shared.publishModeration(updated)
            try? await Task.sleep(for: Self.resultHold)
            awaitingApproval.removeAll { $0.id == request.id }
            failed.removeAll { $0.id == request.id }
            phases[request.id] = nil
            return
        } catch where RequestMutationFailure.isUncertain(error) {
            phases[request.id] = nil
            // Never resend: hold the row until a fresh read shows the result.
            unconfirmedIds.insert(request.id)
            if !RequestMutationFailure.isOwnerChanged(error) { await load() }
            if !unconfirmedIds.isEmpty {
                actionErrorMessage = RequestErrorCopy.unconfirmedModerationMessage
            }
        } catch {
            phases[request.id] = nil
            failureCounts[request.id, default: 0] += 1
            failedActions += 1
            rowErrors[request.id] = RequestErrorCopy.message(for: error)
        }
    }

    /// Bus consumer: a decision made elsewhere (the detail page) takes the
    /// request out of whichever queue still lists it.
    func applyModeration(_ record: MediaRequest) {
        // This list's own action removes its row after the result shows.
        guard phases[record.id] == nil else { return }
        let pendingNow = RequestDisplayState(record: record) == .pending
        awaitingApproval.removeAll { $0.id == record.id && !pendingNow }
        failed.removeAll { $0.id == record.id }
    }
}
