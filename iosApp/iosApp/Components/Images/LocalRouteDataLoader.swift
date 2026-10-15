import Foundation
import Nuke

/// Loads artwork over the active server's local route (`LocalRoute`) when
/// one is active. Image requests and their cache keys keep the saved address;
/// only the transfer moves. A failure on the route drops it, and the
/// artwork's own retry then loads from the saved address.
final class LocalRouteDataLoader: DataLoading {
    private let loader: DataLoader

    init(loader: DataLoader) {
        self.loader = loader
        loader.delegate = LocalRouteTrustDelegate.shared
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        guard let route = LocalRoute.active, let routed = route.routed(request) else {
            return loader.loadData(with: request, didReceiveData: didReceiveData, completion: completion)
        }
        let cancellation = LocalRouteCancellation()
        let task = loader.loadData(
            with: routed,
            didReceiveData: { data, response in didReceiveData(data, route.relabeled(response)) },
            completion: { error in
                if let error, LocalRoute.isRouteFailure(error, taskCancelled: cancellation.isCancelled) {
                    LocalRouteController.reportFailure(of: route)
                }
                completion(error)
            }
        )
        cancellation.task = task
        return cancellation
    }
}

/// Tells a cancelled load from a refused TLS challenge, which also surfaces
/// as a cancellation.
private final class LocalRouteCancellation: Cancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var inner: (any Cancellable)?

    var task: (any Cancellable)? {
        get { lock.withLock { inner } }
        set { lock.withLock { inner = newValue } }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let task = lock.withLock { () -> (any Cancellable)? in
            cancelled = true
            return inner
        }
        task?.cancel()
    }
}
