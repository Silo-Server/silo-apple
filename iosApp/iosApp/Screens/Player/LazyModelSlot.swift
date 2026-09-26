import Observation

/// View-owned reference model built on first read, not in `View.init`.
/// `State(initialValue:)` evaluates its argument on every init of the owning
/// view and keeps only the first; wrapping the model here makes a discarded
/// init cost one small allocation instead of a full model.
@MainActor
@Observable
final class LazyModelSlot<Model: AnyObject> {
    private let makeModel: @MainActor () -> Model
    @ObservationIgnored private var storage: Model?
    /// Observed stand-in for `storage`. Only `replace(with:)` bumps it, so the
    /// lazy build inside `body` never invalidates the view that is rendering.
    private var generation: UInt64 = 0

    init(_ makeModel: @escaping @MainActor () -> Model) { self.makeModel = makeModel }

    var model: Model {
        _ = generation
        if let storage { return storage }
        let created = makeModel()
        storage = created
        return created
    }

    func replace(with model: Model) {
        guard storage !== model else { return }
        storage = model
        generation &+= 1
    }
}
