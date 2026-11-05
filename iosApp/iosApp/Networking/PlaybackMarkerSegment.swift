import Foundation

/// One entry of `marker_segments`: a single marker occurrence in source-file
/// seconds. A file can hold several occurrences of the same kind.
struct PlaybackMarkerSegment: Codable, Hashable, Sendable {
    let kind: String
    let startSeconds: Double
    let endSeconds: Double
}
