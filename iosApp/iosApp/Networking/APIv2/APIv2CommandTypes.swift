import Foundation

// Wire types for sequenced playback progress (`sequenced_progress_v1`).

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
    case invalidSample, invalidResponse, invalidSession, authorityChanged, controlUnavailable
    var errorDescription: String? {
        switch self {
        case .controlUnavailable: return AppLanguage.string(.errorsApplePlaybackControlUnavailable)
        case .invalidSample: return AppLanguage.string(.errorsApplePlaybackInvalidSample)
        case .invalidResponse: return AppLanguage.string(.errorsApplePlaybackInvalidResponse)
        case .invalidSession: return AppLanguage.string(.errorsApplePlaybackInvalidSession)
        case .authorityChanged: return AppLanguage.string(.errorsApplePlaybackAuthorityChanged)
        }
    }
}
