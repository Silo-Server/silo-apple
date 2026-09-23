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

/// One progress sample of a playback session. `sequence` orders the samples
/// of one session: a higher sequence wins even when the position moves back.
struct PlaybackSequencedSample: Codable, Equatable, Sendable {
    let sequence: Int64
    let position: Double
    let isPaused: Bool

    init(sequence: Int64, position: Double, isPaused: Bool) throws {
        guard sequence > 0, position.isFinite, position >= 0 else { throw PlaybackSequencedError.invalidSample }
        self.sequence = sequence
        self.position = position
        self.isPaused = isPaused
    }

    enum CodingKeys: String, CodingKey { case sequence, position, isPaused = "is_paused" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sequence: values.decode(Int64.self, forKey: .sequence),
            position: values.decode(Double.self, forKey: .position), isPaused: values.decode(Bool.self, forKey: .isPaused))
    }
}

/// The strictly increasing `sequence` of each server session this client
/// reports progress for. The server keeps the highest sequence per session
/// and answers a lower one with `stale_sample`, so every sample of one
/// session, including the final one a stop carries, draws from one counter.
struct PlaybackProgressSequence: Sendable {
    private var last: [String: Int64] = [:]

    mutating func next(for sessionID: String) -> Int64 {
        let value = (last[sessionID] ?? 0) + 1
        last[sessionID] = value
        return value
    }

    mutating func forget(_ sessionID: String) {
        last[sessionID] = nil
    }
}

enum PlaybackSequencedError: LocalizedError {
    case invalidSample, invalidResponse, invalidSession, authorityChanged, pendingStart, controlUnavailable
    var errorDescription: String? {
        switch self {
        case .controlUnavailable: return "Remote playback control is not available on this server."
        case .pendingStart: return "A previous playback start is unresolved. Retry it before starting another item."
        case .invalidSample: return "Playback progress could not be recorded."
        case .invalidResponse: return "The server returned an invalid playback response."
        case .invalidSession: return "This playback session is no longer available."
        case .authorityChanged: return "The account or profile changed. Playback was not retried."
        }
    }
}
