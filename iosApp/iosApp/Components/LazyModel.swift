/// Holds a view's model, creating it on first use.
///
/// A `@State` initial value is evaluated on every init of its view, although
/// SwiftUI keeps only the first; a parent that redraws often would build and
/// discard an expensive model each time. Hold this cheap slot in `@State`
/// instead and read the model through it:
///
///     @State private var modelSlot = LazyModel<FeedModel>()
///     private var model: FeedModel { modelSlot.value { FeedModel(id: id) } }
@MainActor
final class LazyModel<Model> {
    private var model: Model?

    func value(_ make: () -> Model) -> Model {
        if let model { return model }
        let made = make()
        model = made
        return made
    }
}
