import Foundation
import Nuke

/// Loads artwork over the active server's local route (`LocalRoute`) when
/// one is active. Image requests and their cache keys keep the saved address;
/// only the transfer moves. A load that fails on the route before any data
/// arrived goes once more to the saved address, and a connection failure
/// drops the route.
final class LocalRouteDataLoader: DataLoading {
    private let loader: DataLoader
    private let localRoute: @Sendable () -> LocalRoute?

    init(loader: DataLoader, localRoute: @escaping @Sendable () -> LocalRoute? = { LocalRoute.active }) {
        self.loader = loader
        self.localRoute = localRoute
        loader.delegate = LocalRouteTrustDelegate.shared
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        guard let route = localRoute(), let routed = route.routed(request) else {
            return loader.loadData(with: request, didReceiveData: didReceiveData, completion: completion)
        }
        let load = RoutedLoad(route: route)
        load.start(loader.loadData(
            with: routed,
            didReceiveData: { data, response in
                load.markReceived()
                didReceiveData(data, load.saved(for: response))
            },
            completion: { [loader] error in
                guard let error, load.shouldFallBack(after: error) else {
                    completion(error)
                    return
                }
                if LocalRoute.isRouteFailure(error) { LocalRouteController.reportFailure(of: route) }
                load.start(loader.loadData(with: request, didReceiveData: didReceiveData, completion: completion))
            }
        ))
        return load
    }
}

/// One artwork load on the local route: the task in flight (the routed one,
/// then possibly its fallback), the response relabeled once, and whether the
/// caller cancelled.
private final class RoutedLoad: Cancellable, @unchecked Sendable {
    private let route: LocalRoute
    private let lock = NSLock()
    private var task: (any Cancellable)?
    private var cancelled = false
    private var received = false
    private var original: URLResponse?
    private var relabeled: URLResponse?

    init(route: LocalRoute) {
        self.route = route
    }

    func start(_ next: any Cancellable) {
        let cancelNow = lock.withLock { () -> Bool in
            task = next
            return cancelled
        }
        if cancelNow { next.cancel() }
    }

    func cancel() {
        let current = lock.withLock { () -> (any Cancellable)? in
            cancelled = true
            return task
        }
        current?.cancel()
    }

    func markReceived() {
        lock.withLock { received = true }
    }

    /// A load the caller did not cancel, that delivered nothing and failed at
    /// the transport (a refused key surfaces as a cancellation), may go once
    /// more to the saved address.
    func shouldFallBack(after error: Error) -> Bool {
        guard error is URLError else { return false }
        return lock.withLock { !cancelled && !received }
    }

    func saved(for response: URLResponse) -> URLResponse {
        lock.withLock {
            if let relabeled, original === response { return relabeled }
            let saved = route.relabeled(response)
            original = response
            relabeled = saved
            return saved
        }
    }
}
