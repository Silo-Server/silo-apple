import Foundation

struct PlaybackMarkerSegment: Codable, Hashable, Sendable {
    let kind: String
    let startSeconds: Double
    let endSeconds: Double

    var range: TimeRange? {
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds > startSeconds else {
            return nil
        }
        return TimeRange(start: startSeconds, end: endSeconds)
    }
}
