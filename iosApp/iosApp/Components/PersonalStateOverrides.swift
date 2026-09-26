import Observation

/// Personal-state values a card shows while its own change is in flight.
/// When the request ends, the card reads its inputs again, so an old tap
/// never masks a later change made elsewhere.
@Observable
@MainActor
final class PersonalStateOverrides {
    private struct Key: Hashable {
        let target: PersonalStateTarget
        let contentId: String
    }

    private var values: [Key: Bool] = [:]

    /// The requested value while a change to this flag and item is in
    /// flight; otherwise `incoming`.
    func value(_ target: PersonalStateTarget, for contentId: String, incoming: Bool) -> Bool {
        values[Key(target: target, contentId: contentId)] ?? incoming
    }

    /// Shows `value` while `update` runs, then drops it whatever the outcome.
    /// The caller's inputs must already hold the confirmed state when
    /// `update` returns `.applied`; otherwise the card shows the old value
    /// until those inputs refresh. Run one change per flag and item at a
    /// time (`MediaActionFeedback.perform` does this for a card): an earlier
    /// run that ends last would drop a newer run's value.
    func run(
        _ target: PersonalStateTarget,
        contentId: String,
        value: Bool,
        update: @MainActor () async -> PersonalStateOutcome
    ) async -> PersonalStateOutcome {
        let key = Key(target: target, contentId: contentId)
        values[key] = value
        let outcome = await update()
        values[key] = nil
        return outcome
    }
}
