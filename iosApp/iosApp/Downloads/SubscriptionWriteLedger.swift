import Foundation

/// The monitor writes that landed while other monitor requests were in
/// flight. A monitor list read describes the server as it was when the read
/// started, so a DELETE or create answered during the read is missing from
/// it. And a create can answer with a monitor whose DELETE is already on the
/// wire; when that DELETE lands, the monitor the create returned is gone.
struct SubscriptionWriteLedger: Equatable {
    /// Bumped by every DELETE that landed and every create that answered.
    private(set) var generation = 0
    /// Monitor id → generation at which its DELETE landed.
    private var deleted: [String: Int] = [:]
    /// Monitor id → generation at which a create answered with it.
    private var created: [String: Int] = [:]
    /// The monitor whose DELETE is on the wire.
    private var deleteInFlight: String?
    /// Monitors a create answered with while their DELETE was on the wire.
    private var revived: Set<String> = []

    mutating func deleteSent(_ id: String) {
        deleteInFlight = id
    }

    /// Records the answer to the DELETE on the wire; `landed` means the
    /// server no longer has the monitor. Returns true when a create answered
    /// with the monitor meanwhile, so that create's monitor is gone.
    mutating func deleteAnswered(_ id: String, landed: Bool) -> Bool {
        if deleteInFlight == id { deleteInFlight = nil }
        let wasRevived = revived.remove(id) != nil
        guard landed else { return false }
        generation += 1
        deleted[id] = generation
        created[id] = nil
        return wasRevived
    }

    /// Records a create's answer. `cancelledPendingDelete` means the user
    /// had stopped this monitor and its DELETE was still pending.
    mutating func createAnswered(_ id: String, cancelledPendingDelete: Bool) {
        generation += 1
        created[id] = generation
        deleted[id] = nil
        if cancelledPendingDelete, deleteInFlight == id { revived.insert(id) }
    }

    /// Whether a create answered with `id` while its DELETE is still on the
    /// wire, so the create's outcome depends on that DELETE.
    func awaitsDelete(_ id: String) -> Bool {
        revived.contains(id)
    }

    /// Whether this device's DELETE for `id` landed and no create answered
    /// with it since.
    func wasDeleted(_ id: String) -> Bool {
        deleted[id] != nil
    }

    /// What a list read that started at `start` cannot show: monitors whose
    /// DELETE landed (the read may still list them) and monitors a create
    /// answered with during the read (the read may not list them yet).
    func landed(since start: Int) -> (deleted: Set<String>, created: Set<String>) {
        (Set(deleted.keys), Set(created.filter { $0.value > start }.keys))
    }

    /// Forgets the writes that a complete list read started at `start`
    /// already reflects.
    mutating func listCompleted(startedAt start: Int) {
        deleted = deleted.filter { $0.value > start }
        created = created.filter { $0.value > start }
    }
}
