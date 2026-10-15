import Foundation
import Nuke

/// Loads artwork over the active server's local route (`LocalRoute`) when
/// one is active. Image requests and their cache keys keep the saved address;
/// only the transfer moves. A connection failure on the route drops it, and
/// the artwork's own retry then loads from the saved address.
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
        let relabeled = RelabeledResponse(route: route)
        return loader.loadData(
            with: routed,
            didReceiveData: { data, response in didReceiveData(data, relabeled.saved(for: response)) },
            completion: { error in
                if let error, LocalRoute.isRouteFailure(error) {
                    LocalRouteController.reportFailure(of: route)
                }
                completion(error)
            }
        )
    }
}

/// Every chunk of one load carries the same response; relabel it once.
private final class RelabeledResponse: @unchecked Sendable {
    private let route: LocalRoute
    private let lock = NSLock()
    private var original: URLResponse?
    private var saved: URLResponse?

    init(route: LocalRoute) {
        self.route = route
    }

    func saved(for response: URLResponse) -> URLResponse {
        lock.withLock {
            if let saved, original === response { return saved }
            let relabeled = route.relabeled(response)
            original = response
            saved = relabeled
            return relabeled
        }
    }
}
