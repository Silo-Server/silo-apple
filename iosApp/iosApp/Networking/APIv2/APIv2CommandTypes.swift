import Foundation

// Type definitions the v2 wire layer needs for sequenced playback mutations.
// Only the shapes that cross the wire or name a wire outcome live here. The
// journals, stores, and coordinators that sequence these commands belong to
// the write-surface PRs and build on `DurableCommandStore`; their barrier
// logic (target matching, held states) is deliberately not part of these
// definitions.

// MARK: Sequenced playback

/// The negotiated feature changes mutation semantics, not the playback URL prefix.
enum PlaybackSequencedContract {
    static let feature = "sequenced_progress_v1"
}

struct PlaybackSequencedSample: Codable, Equatable, Sendable {
    let sequence: Int64
    let position: Double
    let isPaused: Bool
    let timelineId: String?
    let itemPosition: Double?

    init(sequence: Int64, position: Double, isPaused: Bool, timelineId: String? = nil, itemPosition: Double? = nil) throws {
        guard sequence > 0, position.isFinite, position >= 0,
              itemPosition.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw PlaybackSequencedError.invalidSample }
        self.sequence = sequence
        self.position = position
        self.isPaused = isPaused
        self.timelineId = timelineId
        self.itemPosition = itemPosition
    }

    enum CodingKeys: String, CodingKey { case sequence, position, isPaused = "is_paused", timelineId = "timeline_id", itemPosition = "item_position" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sequence: values.decode(Int64.self, forKey: .sequence),
            position: values.decode(Double.self, forKey: .position), isPaused: values.decode(Bool.self, forKey: .isPaused),
            timelineId: values.decodeIfPresent(String.self, forKey: .timelineId),
            itemPosition: values.decodeIfPresent(Double.self, forKey: .itemPosition))
    }
}

enum PlaybackSequencedError: LocalizedError {
    case invalidSample, invalidResponse, invalidSession, authorityChanged, pendingStart, controlRequiresTLS
    var errorDescription: String? {
        switch self {
        case .controlRequiresTLS: return "Remote playback control needs an HTTPS server connection."
        case .pendingStart: return "A previous playback start is unresolved. Retry it before starting another item."
        case .invalidSample: return "Playback progress could not be recorded."
        case .invalidResponse: return "The server returned an invalid playback response."
        case .invalidSession: return "This playback session is no longer available."
        case .authorityChanged: return "The account or profile changed. Playback was not retried."
        }
    }
}
