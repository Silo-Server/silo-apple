import Foundation

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
        guard sequence > 0, position.isFinite, position >= 0 else { throw PlaybackSequencedError.invalidSample }
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

struct PlaybackSequencedStop: Codable, Equatable, Sendable {
    let stopID: UUID
    let sample: PlaybackSequencedSample?
    let timelineId: String?

    enum CodingKeys: String, CodingKey { case stopID = "stop_id", sequence, position, isPaused = "is_paused", timelineId = "timeline_id" }

    init(stopID: UUID, sample: PlaybackSequencedSample?, timelineId: String? = nil) {
        self.stopID = stopID
        self.sample = sample
        self.timelineId = timelineId ?? sample?.timelineId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timelineId = try values.decodeIfPresent(String.self, forKey: .timelineId)
        stopID = try values.decode(UUID.self, forKey: .stopID)
        let sequence = try values.decodeIfPresent(Int64.self, forKey: .sequence)
        let position = try values.decodeIfPresent(Double.self, forKey: .position)
        let paused = try values.decodeIfPresent(Bool.self, forKey: .isPaused)
        if let sequence, let position, let paused {
            sample = try PlaybackSequencedSample(sequence: sequence, position: position, isPaused: paused, timelineId: timelineId)
        } else if sequence == nil && position == nil && paused == nil { sample = nil }
        else { throw PlaybackSequencedError.invalidSample }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(stopID.uuidString.lowercased(), forKey: .stopID)
        try values.encodeIfPresent(timelineId, forKey: .timelineId)
        if let sample {
            try values.encode(sample.sequence, forKey: .sequence)
            try values.encode(sample.position, forKey: .position)
            try values.encode(sample.isPaused, forKey: .isPaused)
        }
    }
}

struct PlaybackSequencedProgressReceipt: Decodable, Sendable {
    enum Outcome: String, Decodable { case applied, replayed, staleSample = "stale_sample" }
    let outcome: Outcome
    let accepted: PlaybackSequencedSample?
}

struct PlaybackSequencedStopReceipt: Decodable, Sendable {
    enum Outcome: String, Decodable { case draining, stopped, replayed }
    let outcome: Outcome
    let stopId: UUID
    let accepted: PlaybackSequencedSample?
    let historyId: String?
    enum CodingKeys: String, CodingKey { case outcome, accepted, stopId = "stop_id", historyId = "history_id" }
}

enum PlaybackSequencedError: LocalizedError {
    case invalidSample, invalidResponse, invalidSession, authorityChanged, pendingStart
    var errorDescription: String? {
        switch self {
        case .pendingStart: return "A previous playback start is unresolved. Retry it before starting another item."
        case .invalidSample: return "Playback progress could not be recorded."
        case .invalidResponse: return "The server returned an invalid playback response."
        case .invalidSession: return "This playback session is no longer available."
        case .authorityChanged: return "The account or profile changed. Playback was not retried."
        }
    }
}

extension SiloAPI {
    func reportSequencedPlaybackProgress(sessionID: String, sample: PlaybackSequencedSample,
                                        auth: CapturedOrdinaryRequestAuth, installationID: String? = nil) async throws -> PlaybackSequencedProgressReceipt {
        let response = try await playbackMutation(method: "POST", sessionID: sessionID, suffix: "/progress",
            body: Self.playbackMutationBody(sample), auth: auth, installationID: installationID)
        guard response.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        return try JSONDecoder().decode(PlaybackSequencedProgressReceipt.self, from: response.data)
    }

    func stopSequencedPlayback(sessionID: String, stop: PlaybackSequencedStop,
                              auth: CapturedOrdinaryRequestAuth, installationID: String? = nil) async throws -> PlaybackSequencedStopReceipt {
        let response = try await playbackMutation(method: "DELETE", sessionID: sessionID, suffix: "",
            body: Self.playbackMutationBody(stop), auth: auth, installationID: installationID)
        let receipt = try JSONDecoder().decode(PlaybackSequencedStopReceipt.self, from: response.data)
        guard receipt.stopId == stop.stopID,
              (response.statusCode == 202 && receipt.outcome == .draining) ||
                (response.statusCode == 200 && (receipt.outcome == .stopped || receipt.outcome == .replayed)) else {
            throw PlaybackSequencedError.invalidResponse
        }
        return receipt
    }

    static func playbackMutationBody<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func playbackMutation(method: String, sessionID: String, suffix: String, body: Data,
                                  auth: CapturedOrdinaryRequestAuth, installationID: String?) async throws -> HTTPRawResponse {
        guard !sessionID.isEmpty, sessionID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw PlaybackSequencedError.invalidSession
        }
        if let installationID {
            var object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            object["installation_id"] = installationID
            return try await v2.playbackRequest(method: method, suffix: "/\(sessionID)\(suffix)",
                body: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), auth: auth)
        }
        guard let profileID = auth.profileId, !profileID.isEmpty else { throw PlaybackSequencedError.authorityChanged }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profileID, clientFamily: AppleDeviceIdentity.current.clientFamily)
        // A rejected 401 may refresh under the exact captured identity. No transport
        // retry follows an uncertain response; the durable owner retains this body.
        return try await http.requestData(method: method, path: "/api/v1/playback/\(sessionID)\(suffix)",
            body: body, requestIdentity: identity, expectedAccount: auth.account)
    }
}
