import Foundation

/// An optimistic season watched value plus the request that produced it.
/// Season chips and tabs keep one per season while a context-menu mutation
/// is in flight, so an older completion cannot clear a newer value and a
/// refreshed payload only reconciles the season it describes.
struct SeasonWatchedOverride: Equatable {
    let played: Bool
    let request: UUID
}
