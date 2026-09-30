import Foundation

/// An approve, decline, or retry sent without a usable answer. Moderation
/// is `non_retryable`, and a timed-out call can still be running on the
/// server when the next read comes back, so an unchanged request proves
/// nothing: the hold lasts until the request changes or leaves the queue.
/// It lapses after `lifetime`, read or not, so a call that never arrived
/// doesn't lock the row forever. Releasing it can't double an action: the
/// server applies each decision only from the state it expects, so a
/// second send after a late first one is refused.
struct ModerationHold: Equatable {
    let requestId: String
    let updatedAt: Date
    let since: Date

    static let lifetime: TimeInterval = 60

    init(request: MediaRequest, since: Date = Date()) {
        requestId = request.id
        updatedAt = request.updatedAt
        self.since = since
    }

    /// Whether a complete read (`current` is the request's entry in it, or
    /// nil when it's gone) shows what the held call did.
    func isSettled(by current: MediaRequest?, now: Date = Date()) -> Bool {
        guard let current, current.id == requestId else { return true }
        return current.updatedAt != updatedAt || now.timeIntervalSince(since) >= Self.lifetime
    }
}

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
    /// Decisions sent without a usable answer, by request id; those rows
    /// offer no action until a read shows the result (`ModerationHold`).
    private(set) var holds: [String: ModerationHold] = [:]
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
    private let holdLifetime: Duration

    init(api: SiloAPI = .shared, holdLifetime: Duration = .seconds(ModerationHold.lifetime)) {
        self.api = api
        self.holdLifetime = holdLifetime
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
            // Release the holds this read settles; an unchanged request
            // keeps its hold.
            if !holds.isEmpty {
                let listed = awaitingApproval + failed
                holds = holds.filter { id, hold in
                    !hold.isSettled(by: listed.first { $0.id == id })
                }
                clearUnconfirmedMessageIfSettled()
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
        phases[request.id] == nil && holds[request.id] == nil
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
            hold(request)
            if !RequestMutationFailure.isOwnerChanged(error) { await load() }
            if !holds.isEmpty {
                actionErrorMessage = RequestErrorCopy.unconfirmedModerationMessage
            }
        } catch {
            phases[request.id] = nil
            failureCounts[request.id, default: 0] += 1
            failedActions += 1
            rowErrors[request.id] = RequestErrorCopy.message(for: error)
        }
    }

    /// Holds the row, and ends the hold when its lifetime runs out even if
    /// no read comes back to settle it. Only this hold: a newer one for the
    /// same request keeps its own clock.
    private func hold(_ request: MediaRequest) {
        let hold = ModerationHold(request: request)
        holds[request.id] = hold
        Task { [weak self, holdLifetime] in
            try? await Task.sleep(for: holdLifetime)
            guard let self, self.holds[hold.requestId] == hold else { return }
            self.holds[hold.requestId] = nil
            self.clearUnconfirmedMessageIfSettled()
            await self.load()
        }
    }

    private func clearUnconfirmedMessageIfSettled() {
        if holds.isEmpty, actionErrorMessage == RequestErrorCopy.unconfirmedModerationMessage {
            actionErrorMessage = nil
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
