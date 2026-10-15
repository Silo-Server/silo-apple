import Foundation

/// Which open Requests screens close when the server turns requests off.
/// Matches the Android shells: only the run of Requests pages on top of a
/// stack closes, back to whatever opened them.
enum RequestsRouteVisibility {
    /// The Requests screens: hub, My Requests, request detail.
    static func isRequestsRoute(_ route: Route) -> Bool {
        switch route {
        case .requestsHub, .myRequests, .requestDetail:
            return true
        default:
            return false
        }
    }

    /// How many routes to pop, top first, to leave the Requests pages on top
    /// of `routes` (oldest first). A page opened from Requests, such as a
    /// library title, stops the run, so it stays in view.
    static func requestsRoutesOnTop(_ routes: [Route]) -> Int {
        routes.reversed().prefix(while: isRequestsRoute).count
    }
}
